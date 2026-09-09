//
//  HotkeyManager.swift
//  Pindrop
//
//  Created on 2026-01-25.
//

import Foundation
import Carbon
import CoreGraphics

// MARK: - Hotkey Registration Protocol

protocol HotkeyRegistrationProtocol {
    func registerHotkey(id: UInt32, keyCode: UInt32, modifiers: UInt32) -> Bool
    func unregisterHotkey(id: UInt32) -> Bool
}

// MARK: - Carbon Events Implementation

final class CarbonHotkeyRegistration: HotkeyRegistrationProtocol {
    private var registeredRefs: [UInt32: EventHotKeyRef] = [:]
    
    func registerHotkey(id: UInt32, keyCode: UInt32, modifiers: UInt32) -> Bool {
        var eventHotKeyID = EventHotKeyID()
        eventHotKeyID.signature = OSType(("PNDR" as NSString).utf8String!.withMemoryRebound(to: UInt8.self, capacity: 4) { ptr in
            return UInt32(ptr[0]) << 24 | UInt32(ptr[1]) << 16 | UInt32(ptr[2]) << 8 | UInt32(ptr[3])
        })
        eventHotKeyID.id = id
        
        var eventHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            eventHotKeyID,
            GetApplicationEventTarget(),
            0,
            &eventHotKeyRef
        )
        
        guard status == noErr, let hotKeyRef = eventHotKeyRef else {
            return false
        }
        
        registeredRefs[id] = hotKeyRef
        return true
    }
    
    func unregisterHotkey(id: UInt32) -> Bool {
        guard let hotKeyRef = registeredRefs[id] else {
            return false
        }
        
        let status = UnregisterEventHotKey(hotKeyRef)
        
        guard status == noErr else {
            return false
        }
        
        registeredRefs.removeValue(forKey: id)
        return true
    }
}

// MARK: - Chord Guard

/// Shared, thread-safe flag telling the CGEvent tap whether a `.holdOrDoubleTap`
/// gesture is currently mid-press. The tap reads it on every keystroke, so it must be
/// readable off the main queue without hopping actors.
final class HotkeyChordGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var armedGestureCount = 0

    var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return armedGestureCount > 0
    }

    func setArmedGestureCount(_ count: Int) {
        lock.lock()
        armedGestureCount = count
        lock.unlock()
    }
}

// MARK: - HotkeyManager

final class HotkeyManager {
    private static let hotkeyCaptureStateDidChangeNotification = Notification.Name("tech.watzon.pindrop.hotkeyCaptureStateDidChange")
    private static let hotkeyCaptureStateUserInfoKey = "isCapturing"

    static func setHotkeyCaptureInProgress(_ isCapturing: Bool) {
        NotificationCenter.default.post(
            name: hotkeyCaptureStateDidChangeNotification,
            object: nil,
            userInfo: [hotkeyCaptureStateUserInfoKey: isCapturing]
        )
    }
    
    enum HotkeyMode {
        case toggle
        case pushToTalk
        /// One key, two gestures: hold it to dictate push-to-talk, tap it twice to
        /// latch a hands-free session that a later tap ends.
        case holdOrDoubleTap
    }

    /// Semantic events emitted by `.holdOrDoubleTap`. Exactly one `*Start` is followed
    /// by exactly one `*Stop` or `cancel`, so callers never have to de-duplicate.
    enum HotkeyActivation: Equatable {
        /// The key was held past the chord grace period.
        case holdStart
        /// A held key was released.
        case holdStop
        /// A second tap arrived inside the double-tap window.
        case latchStart
        /// A latched session was ended by a later press.
        case latchStop
        /// A regular key was pressed while the hotkey was held — the press was a
        /// chord (⌃C and friends), not dictation.
        case cancel
    }
    
    struct ModifierFlags: OptionSet {
        let rawValue: UInt32
        
        static let command = ModifierFlags(rawValue: UInt32(cmdKey))
        static let option = ModifierFlags(rawValue: UInt32(optionKey))
        static let shift = ModifierFlags(rawValue: UInt32(shiftKey))
        static let control = ModifierFlags(rawValue: UInt32(controlKey))
        static let function = ModifierFlags(rawValue: UInt32(kEventKeyModifierFnMask))
    }
    
    struct HotkeyConfiguration {
        let keyCode: UInt32
        let modifiers: ModifierFlags
        let identifier: String
        let mode: HotkeyMode
        let onKeyDown: (() -> Void)?
        let onKeyUp: (() -> Void)?
        /// Only used by `.holdOrDoubleTap`.
        let onActivation: ((HotkeyActivation) -> Void)?
        
        // Convenience initializer for toggle mode (backward compatibility)
        init(keyCode: UInt32, modifiers: ModifierFlags, identifier: String, callback: @escaping () -> Void) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.identifier = identifier
            self.mode = .toggle
            self.onKeyDown = callback
            self.onKeyUp = nil
            self.onActivation = nil
        }
        
        // Initializer for push-to-talk mode
        init(
            keyCode: UInt32,
            modifiers: ModifierFlags,
            identifier: String,
            mode: HotkeyMode,
            onKeyDown: (() -> Void)?,
            onKeyUp: (() -> Void)?,
            onActivation: ((HotkeyActivation) -> Void)? = nil
        ) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.identifier = identifier
            self.mode = mode
            self.onKeyDown = onKeyDown
            self.onKeyUp = onKeyUp
            self.onActivation = onActivation
        }
    }
    
    private struct RegisteredHotkey {
        let configuration: HotkeyConfiguration
        let eventHotKeyID: EventHotKeyID
        let usesCarbonRegistration: Bool
        var isKeyCurrentlyPressed: Bool = false
    }
    
    private var registeredHotkeys: [String: RegisteredHotkey] = [:]
    /// Collision-free source for Carbon `EventHotKeyID.id` values.
    private var nextCarbonHotkeyID: UInt32 = 1
    private var eventHandlerRef: EventHandlerRef?
    private let registration: HotkeyRegistrationProtocol
    private var hotkeyCaptureStateObserver: NSObjectProtocol?
    private var isEventDispatchSuppressed = false

    /// How long the hotkey must stay down before a hold starts dictating. Doubles as
    /// the chord guard: ⌃C and friends abort inside this window, so a modifier-only
    /// hotkey never records while the user is typing shortcuts.
    private let holdActivationGrace: TimeInterval
    /// How long after a short tap a second tap still counts as a double tap.
    private let doubleTapWindow: TimeInterval
    private let scheduler: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
    private var holdOrDoubleTapPhases: [String: HoldOrDoubleTapPhase] = [:]
    /// Read from the CGEvent tap thread on every keystroke: the tap only dispatches to
    /// the main queue while a press is live.
    let chordGuard = HotkeyChordGuard()
    
    init(
        registration: HotkeyRegistrationProtocol = CarbonHotkeyRegistration(),
        holdActivationGrace: TimeInterval = 0.18,
        doubleTapWindow: TimeInterval = 0.30,
        scheduler: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = { delay, work in
            let item = DispatchWorkItem(block: work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    ) {
        self.registration = registration
        self.holdActivationGrace = holdActivationGrace
        self.doubleTapWindow = doubleTapWindow
        self.scheduler = scheduler
        setupEventHandler()
        observeHotkeyCaptureState()
    }
    deinit {
        unregisterAll()
        removeHotkeyCaptureStateObserver()
        removeEventHandler()
    }
    
    func registerHotkey(
        keyCode: UInt32,
        modifiers: ModifierFlags,
        identifier: String,
        mode: HotkeyMode = .toggle,
        onKeyDown: (() -> Void)? = nil,
        onKeyUp: (() -> Void)? = nil,
        onActivation: ((HotkeyActivation) -> Void)? = nil
    ) -> Bool {
        if registeredHotkeys[identifier] != nil {
            Log.hotkey.error("Hotkey with identifier '\(identifier)' is already registered")
            return false
        }
        
        let configuration = HotkeyConfiguration(
            keyCode: keyCode,
            modifiers: modifiers,
            identifier: identifier,
            mode: mode,
            onKeyDown: onKeyDown,
            onKeyUp: onKeyUp,
            onActivation: onActivation
        )
        
        // Monotonic counter: IDs only need to be unique within this launch (the
        // event handler matches against stored registrations). `String.hashValue`
        // was used before, but truncating it to 32 bits can collide between
        // identifiers, mis-routing or failing registration.
        let hotkeyID = nextCarbonHotkeyID
        nextCarbonHotkeyID &+= 1
        
        let usesCarbonRegistration = modifierMask(for: keyCode) == nil
        if usesCarbonRegistration {
            let success = registration.registerHotkey(
                id: hotkeyID,
                keyCode: keyCode,
                modifiers: modifiers.rawValue
            )
            
            guard success else {
                Log.hotkey.error("Failed to register hotkey '\(identifier)'")
                return false
            }
        }
        
        var eventHotKeyID = EventHotKeyID()
        eventHotKeyID.signature = OSType(("PNDR" as NSString).utf8String!.withMemoryRebound(to: UInt8.self, capacity: 4) { ptr in
            return UInt32(ptr[0]) << 24 | UInt32(ptr[1]) << 16 | UInt32(ptr[2]) << 8 | UInt32(ptr[3])
        })
        eventHotKeyID.id = hotkeyID
        
        let registeredHotkey = RegisteredHotkey(
            configuration: configuration,
            eventHotKeyID: eventHotKeyID,
            usesCarbonRegistration: usesCarbonRegistration
        )
        
        registeredHotkeys[identifier] = registeredHotkey
        if usesCarbonRegistration {
            Log.hotkey.info("Successfully registered hotkey '\(identifier)'")
        } else {
            Log.hotkey.info("Registered modifier-only hotkey '\(identifier)' with keyCode=\(keyCode)")
        }
        
        return true
    }
    
    func unregisterHotkey(identifier: String) -> Bool {
        guard let registeredHotkey = registeredHotkeys[identifier] else {
            Log.hotkey.warning("Attempted to unregister nonexistent hotkey '\(identifier)'")
            return false
        }

        if registeredHotkey.usesCarbonRegistration {
            let hotkeyID = registeredHotkey.eventHotKeyID.id
            let success = registration.unregisterHotkey(id: hotkeyID)
            
            guard success else {
                Log.hotkey.error("Failed to unregister hotkey '\(identifier)'")
                return false
            }
        }

        resetHoldOrDoubleTapPhase(identifier: identifier)
        registeredHotkeys.removeValue(forKey: identifier)
        Log.hotkey.info("Successfully unregistered hotkey '\(identifier)'")
        
        return true
    }
    
    func unregisterAll() {
        let identifiers = Array(registeredHotkeys.keys)
        for identifier in identifiers {
            _ = unregisterHotkey(identifier: identifier)
        }
    }
    
    func isHotkeyRegistered(identifier: String) -> Bool {
        return registeredHotkeys[identifier] != nil
    }
    
    func getHotkeyConfiguration(identifier: String) -> HotkeyConfiguration? {
        return registeredHotkeys[identifier]?.configuration
    }

    func setEventDispatchSuppressed(_ suppressed: Bool) {
        guard isEventDispatchSuppressed != suppressed else { return }
        isEventDispatchSuppressed = suppressed

        guard suppressed else { return }

        for identifier in Array(holdOrDoubleTapPhases.keys) {
            let phase = holdOrDoubleTapPhases[identifier]
            resetHoldOrDoubleTapPhase(identifier: identifier)
            guard let phase, let config = registeredHotkeys[identifier]?.configuration else { continue }
            switch phase {
            case .holding:
                emit(.cancel, for: config)
            case .latched, .latchedPending, .latchedChorded, .latchedIgnoringUp:
                emit(.latchStop, for: config)
            case .idle, .pending, .chorded, .awaitingSecondTap, .latchedHeld:
                break
            }
        }

        var keyUpCallbacks: [() -> Void] = []

        for identifier in Array(registeredHotkeys.keys) {
            guard var registeredHotkey = registeredHotkeys[identifier],
                  registeredHotkey.isKeyCurrentlyPressed else {
                continue
            }

            registeredHotkey.isKeyCurrentlyPressed = false
            registeredHotkeys[identifier] = registeredHotkey

            if registeredHotkey.configuration.mode == .pushToTalk,
               let onKeyUp = registeredHotkey.configuration.onKeyUp {
                keyUpCallbacks.append(onKeyUp)
            }
        }

        guard !keyUpCallbacks.isEmpty else { return }

        DispatchQueue.main.async {
            keyUpCallbacks.forEach { $0() }
        }
    }

    private func observeHotkeyCaptureState() {
        hotkeyCaptureStateObserver = NotificationCenter.default.addObserver(
            forName: Self.hotkeyCaptureStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isCapturing = notification.userInfo?[Self.hotkeyCaptureStateUserInfoKey] as? Bool else { return }
            self?.setEventDispatchSuppressed(isCapturing)
        }
    }

    private func removeHotkeyCaptureStateObserver() {
        guard let observer = hotkeyCaptureStateObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        hotkeyCaptureStateObserver = nil
    }
    
    func convertToCarbonModifiers(_ modifiers: ModifierFlags) -> UInt32 {
        return modifiers.rawValue
    }

    func handleModifierFlagsChanged(event: CGEvent) {
        guard !isEventDispatchSuppressed else { return }
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        guard let modifierMask = modifierMask(for: keyCode) else { return }

        let isKeyDown = event.flags.contains(modifierMask)
        let eventModifiers = modifierFlagsFrom(event.flags)

        DispatchQueue.main.async { [weak self] in
            self?.handleModifierKeyEvent(
                keyCode: keyCode,
                eventModifiers: eventModifiers,
                isKeyDown: isKeyDown
            )
        }
    }
    
    private func setupEventHandler() {
        let eventSpec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        
        let callback: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            return manager.handleHotkeyEvent(event: event)
        }
        
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            eventSpec.count,
            eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        
        if status == noErr {
            eventHandlerRef = handlerRef
            Log.hotkey.info("Event handler installed successfully")
        } else {
            Log.hotkey.error("Failed to install event handler: OSStatus \(status)")
        }
    }
    
    private func removeEventHandler() {
        guard let handlerRef = eventHandlerRef else { return }
        
        let status = RemoveEventHandler(handlerRef)
        if status == noErr {
            eventHandlerRef = nil
            Log.hotkey.info("Event handler removed successfully")
        } else {
            Log.hotkey.error("Failed to remove event handler: OSStatus \(status)")
        }
    }
    
    private func handleHotkeyEvent(event: EventRef?) -> OSStatus {
        guard let event = event else { return OSStatus(eventNotHandledErr) }
        guard !isEventDispatchSuppressed else { return noErr }
        
        let eventKind = GetEventKind(event)
        let isKeyDown = (eventKind == UInt32(kEventHotKeyPressed))
        let isKeyUp = (eventKind == UInt32(kEventHotKeyReleased))
        
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        
        guard status == noErr else {
            Log.hotkey.error("Failed to get event parameter: OSStatus \(status)")
            return OSStatus(eventNotHandledErr)
        }
        
        for (identifier, var registeredHotkey) in registeredHotkeys {
            if registeredHotkey.eventHotKeyID.signature == hotKeyID.signature &&
               registeredHotkey.eventHotKeyID.id == hotKeyID.id {
                
                let config = registeredHotkey.configuration
                
                if isKeyDown && registeredHotkey.isKeyCurrentlyPressed {
                    return noErr
                }
                
                if isKeyDown {
                    registeredHotkey.isKeyCurrentlyPressed = true
                    registeredHotkeys[identifier] = registeredHotkey
                } else if isKeyUp {
                    registeredHotkey.isKeyCurrentlyPressed = false
                    registeredHotkeys[identifier] = registeredHotkey
                }
                
                DispatchQueue.main.async { [weak self] in
                    switch config.mode {
                    case .toggle:
                        if isKeyDown {
                            config.onKeyDown?()
                        }
                    case .pushToTalk:
                        if isKeyDown {
                            config.onKeyDown?()
                        } else if isKeyUp {
                            config.onKeyUp?()
                        }
                    case .holdOrDoubleTap:
                        guard isKeyDown || isKeyUp else { return }
                        self?.handleHoldOrDoubleTapEvent(identifier: identifier, isKeyDown: isKeyDown)
                    }
                }
                
                return noErr
            }
        }
        
        return OSStatus(eventNotHandledErr)
    }

    private func handleModifierKeyEvent(
        keyCode: UInt32,
        eventModifiers: ModifierFlags,
        isKeyDown: Bool
    ) {
        for (identifier, var registeredHotkey) in registeredHotkeys {
            guard !registeredHotkey.usesCarbonRegistration else { continue }
            guard registeredHotkey.configuration.keyCode == keyCode else { continue }

            let config = registeredHotkey.configuration

            if isKeyDown {
                guard eventModifiers == config.modifiers else { continue }
                guard !registeredHotkey.isKeyCurrentlyPressed else { continue }

                registeredHotkey.isKeyCurrentlyPressed = true
                registeredHotkeys[identifier] = registeredHotkey

                if config.mode == .holdOrDoubleTap {
                    handleHoldOrDoubleTapEvent(identifier: identifier, isKeyDown: true)
                } else {
                    config.onKeyDown?()
                }
            } else if registeredHotkey.isKeyCurrentlyPressed {
                registeredHotkey.isKeyCurrentlyPressed = false
                registeredHotkeys[identifier] = registeredHotkey

                switch config.mode {
                case .pushToTalk:
                    config.onKeyUp?()
                case .holdOrDoubleTap:
                    handleHoldOrDoubleTapEvent(identifier: identifier, isKeyDown: false)
                case .toggle:
                    break
                }
            }
        }
    }


    // MARK: - Hold-or-Double-Tap State Machine

    /// Phases of the `.holdOrDoubleTap` gesture. Work items are the pending timers and
    /// are always cancelled before a phase is replaced.
    private enum HoldOrDoubleTapPhase {
        /// Nothing in flight.
        case idle
        /// Key is down; waiting out the chord grace before dictation starts.
        case pending(DispatchWorkItem)
        /// Hold dictation is running and the key is still down.
        case holding
        /// A chord aborted the press; swallow everything until the key comes back up.
        case chorded
        /// A short tap landed; waiting to see whether a second one follows.
        case awaitingSecondTap(DispatchWorkItem)
        /// A latched session started on this press; ignore its release.
        case latchedIgnoringUp
        /// A latched session is running and no key is down.
        case latched
        /// Key is down during a latched session; waiting out the chord grace.
        case latchedPending(DispatchWorkItem)
        /// The latched session was ended by this press; waiting for the release.
        case latchedHeld
        /// A chord happened during a latched session; the session stays latched.
        case latchedChorded

        var holdsKeyDown: Bool {
            switch self {
            case .pending, .holding, .chorded, .latchedIgnoringUp,
                 .latchedPending, .latchedHeld, .latchedChorded:
                return true
            case .idle, .awaitingSecondTap, .latched:
                return false
            }
        }

        /// Phases in which a regular keystroke means "this was a chord, not dictation".
        var isChordSensitive: Bool {
            switch self {
            case .pending, .holding, .awaitingSecondTap, .latchedPending:
                return true
            case .idle, .chorded, .latchedIgnoringUp, .latched, .latchedHeld, .latchedChorded:
                return false
            }
        }

        var pendingWorkItem: DispatchWorkItem? {
            switch self {
            case .pending(let item), .awaitingSecondTap(let item), .latchedPending(let item):
                return item
            default:
                return nil
            }
        }
    }

    /// Whether any `.holdOrDoubleTap` hotkey is mid-gesture. The CGEvent tap reads this
    /// on every keystroke and only hops to the main queue when it is true.
    var hasArmedHoldOrDoubleTapGesture: Bool { chordGuard.isArmed }

    /// Called for every regular (non-modifier) key press so chords abort the gesture.
    func handleForeignKeyDown() {
        for (identifier, phase) in holdOrDoubleTapPhases where phase.isChordSensitive {
            guard let config = registeredHotkeys[identifier]?.configuration else { continue }

            switch phase {
            case .pending:
                // Dictation never started — abort silently.
                setPhase(.chorded, for: identifier)
            case .holding:
                setPhase(.chorded, for: identifier)
                emit(.cancel, for: config)
            case .awaitingSecondTap:
                setPhase(.idle, for: identifier)
            case .latchedPending:
                setPhase(.latchedChorded, for: identifier)
            default:
                break
            }
        }
    }

    /// Internal rather than private so tests can drive the gesture without
    /// synthesizing CGEvents.
    func handleHoldOrDoubleTapEvent(identifier: String, isKeyDown: Bool) {
        guard let config = registeredHotkeys[identifier]?.configuration else { return }
        let phase = holdOrDoubleTapPhases[identifier] ?? .idle

        if isKeyDown {
            switch phase {
            case .idle:
                setPhase(.pending(scheduler(holdActivationGrace) { [weak self] in
                    guard let self, case .pending = self.holdOrDoubleTapPhases[identifier] else { return }
                    self.setPhase(.holding, for: identifier)
                    self.emit(.holdStart, for: config)
                }), for: identifier)
            case .awaitingSecondTap:
                setPhase(.latchedIgnoringUp, for: identifier)
                emit(.latchStart, for: config)
            case .latched:
                setPhase(.latchedPending(scheduler(holdActivationGrace) { [weak self] in
                    guard let self, case .latchedPending = self.holdOrDoubleTapPhases[identifier] else { return }
                    self.setPhase(.latchedHeld, for: identifier)
                    self.emit(.latchStop, for: config)
                }), for: identifier)
            default:
                break
            }
            return
        }

        switch phase {
        case .pending:
            // Released inside the grace window: a tap, which only counts in pairs.
            setPhase(.awaitingSecondTap(scheduler(doubleTapWindow) { [weak self] in
                guard let self, case .awaitingSecondTap = self.holdOrDoubleTapPhases[identifier] else { return }
                self.setPhase(.idle, for: identifier)
            }), for: identifier)
        case .holding:
            setPhase(.idle, for: identifier)
            emit(.holdStop, for: config)
        case .latchedPending:
            // A quick tap ends a latched session just as a held press does.
            setPhase(.idle, for: identifier)
            emit(.latchStop, for: config)
        case .latchedIgnoringUp, .latchedChorded:
            setPhase(.latched, for: identifier)
        case .chorded, .latchedHeld:
            setPhase(.idle, for: identifier)
        case .idle, .awaitingSecondTap, .latched:
            break
        }
    }

    private func setPhase(_ newPhase: HoldOrDoubleTapPhase, for identifier: String) {
        holdOrDoubleTapPhases[identifier]?.pendingWorkItem?.cancel()
        if case .idle = newPhase {
            holdOrDoubleTapPhases.removeValue(forKey: identifier)
        } else {
            holdOrDoubleTapPhases[identifier] = newPhase
        }
        refreshChordGuardArmedCount()
    }

    private func resetHoldOrDoubleTapPhase(identifier: String) {
        holdOrDoubleTapPhases[identifier]?.pendingWorkItem?.cancel()
        holdOrDoubleTapPhases.removeValue(forKey: identifier)
        refreshChordGuardArmedCount()
    }

    private func refreshChordGuardArmedCount() {
        chordGuard.setArmedGestureCount(
            holdOrDoubleTapPhases.values.filter { $0.isChordSensitive }.count
        )
    }

    private func emit(_ activation: HotkeyActivation, for config: HotkeyConfiguration) {
        Log.hotkey.info("Hold-or-double-tap '\(config.identifier)' -> \(String(describing: activation))")
        config.onActivation?(activation)
    }

    private func modifierMask(for keyCode: UInt32) -> CGEventFlags? {
        switch keyCode {
        case 54, 55:
            return .maskCommand
        case 58, 61:
            return .maskAlternate
        case 56, 60:
            return .maskShift
        case 59, 62:
            return .maskControl
        case UInt32(kVK_Function):
            return .maskSecondaryFn
        default:
            return nil
        }
    }

    private func modifierFlagsFrom(_ flags: CGEventFlags) -> ModifierFlags {
        var modifiers: ModifierFlags = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        return modifiers
    }
}
