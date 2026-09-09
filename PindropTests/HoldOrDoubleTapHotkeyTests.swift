//
//  HoldOrDoubleTapHotkeyTests.swift
//  PindropTests
//
//  Created on 2026-09-09.
//

import Foundation
import Testing
@testable import Pindrop

/// Captures the timers the gesture schedules so tests can fire them on demand
/// instead of waiting on the main queue.
private final class ManualScheduler {
    private(set) var pending: [(delay: TimeInterval, item: DispatchWorkItem)] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: work)
        pending.append((delay, item))
        return item
    }

    /// Fires every timer scheduled so far; cancelled ones are inert.
    func fireAll() {
        let items = pending
        pending.removeAll()
        items.forEach { $0.item.perform() }
    }
}

@Suite(.serialized)
struct HoldOrDoubleTapHotkeyTests {
    private static let identifier = "push-to-talk"

    private final class Recorder {
        var activations: [HotkeyManager.HotkeyActivation] = []
    }

    private func makeFixture() -> (manager: HotkeyManager, scheduler: ManualScheduler, recorder: Recorder) {
        let scheduler = ManualScheduler()
        let recorder = Recorder()
        let manager = HotkeyManager(
            registration: MockHotkeyRegistration(),
            scheduler: { delay, work in scheduler.schedule(delay, work) }
        )
        _ = manager.registerHotkey(
            keyCode: 59,
            modifiers: [.control],
            identifier: Self.identifier,
            mode: .holdOrDoubleTap,
            onActivation: { recorder.activations.append($0) }
        )
        return (manager, scheduler, recorder)
    }

    private func down(_ manager: HotkeyManager) {
        manager.handleHoldOrDoubleTapEvent(identifier: Self.identifier, isKeyDown: true)
    }

    private func up(_ manager: HotkeyManager) {
        manager.handleHoldOrDoubleTapEvent(identifier: Self.identifier, isKeyDown: false)
    }

    @Test func holdingPastTheGraceStartsAndReleaseStops() {
        let fixture = makeFixture()

        down(fixture.manager)
        #expect(fixture.recorder.activations.isEmpty)

        fixture.scheduler.fireAll()
        #expect(fixture.recorder.activations == [.holdStart])

        up(fixture.manager)
        #expect(fixture.recorder.activations == [.holdStart, .holdStop])
    }

    @Test func singleShortTapNeverRecords() {
        let fixture = makeFixture()

        down(fixture.manager)
        up(fixture.manager)
        // The grace timer was cancelled by the release, and the double-tap timer
        // simply expires.
        fixture.scheduler.fireAll()

        #expect(fixture.recorder.activations.isEmpty)
    }

    @Test func doubleTapLatchesAndALaterPressStops() {
        let fixture = makeFixture()

        down(fixture.manager)
        up(fixture.manager)
        down(fixture.manager)
        #expect(fixture.recorder.activations == [.latchStart])

        // The second tap's release must not end the latched session.
        up(fixture.manager)
        fixture.scheduler.fireAll()
        #expect(fixture.recorder.activations == [.latchStart])

        down(fixture.manager)
        fixture.scheduler.fireAll()
        #expect(fixture.recorder.activations == [.latchStart, .latchStop])

        up(fixture.manager)
        #expect(fixture.recorder.activations == [.latchStart, .latchStop])
    }

    @Test func quickTapAlsoEndsALatchedSession() {
        let fixture = makeFixture()

        down(fixture.manager)
        up(fixture.manager)
        down(fixture.manager)
        up(fixture.manager)
        #expect(fixture.recorder.activations == [.latchStart])

        down(fixture.manager)
        up(fixture.manager)
        #expect(fixture.recorder.activations == [.latchStart, .latchStop])
    }

    @Test func chordInsideTheGraceNeverStartsDictation() {
        let fixture = makeFixture()

        down(fixture.manager)
        fixture.manager.handleForeignKeyDown()
        fixture.scheduler.fireAll()
        up(fixture.manager)

        #expect(fixture.recorder.activations.isEmpty)
    }

    @Test func chordDuringAHoldCancelsTheSession() {
        let fixture = makeFixture()

        down(fixture.manager)
        fixture.scheduler.fireAll()
        #expect(fixture.recorder.activations == [.holdStart])

        fixture.manager.handleForeignKeyDown()
        #expect(fixture.recorder.activations == [.holdStart, .cancel])

        // The release after a cancelled chord must not emit a second stop.
        up(fixture.manager)
        #expect(fixture.recorder.activations == [.holdStart, .cancel])
    }

    @Test func chordDuringALatchedPressKeepsTheSessionLatched() {
        let fixture = makeFixture()

        down(fixture.manager)
        up(fixture.manager)
        down(fixture.manager)
        up(fixture.manager)
        #expect(fixture.recorder.activations == [.latchStart])

        down(fixture.manager)
        fixture.manager.handleForeignKeyDown()
        fixture.scheduler.fireAll()
        up(fixture.manager)
        #expect(fixture.recorder.activations == [.latchStart])

        // Still latched, so the next press ends the session.
        down(fixture.manager)
        fixture.scheduler.fireAll()
        #expect(fixture.recorder.activations == [.latchStart, .latchStop])
    }

    @Test func chordGuardIsArmedOnlyWhileAPressIsLive() {
        let fixture = makeFixture()
        #expect(fixture.manager.hasArmedHoldOrDoubleTapGesture == false)

        down(fixture.manager)
        #expect(fixture.manager.hasArmedHoldOrDoubleTapGesture)

        fixture.scheduler.fireAll()
        #expect(fixture.manager.hasArmedHoldOrDoubleTapGesture)

        up(fixture.manager)
        #expect(fixture.manager.hasArmedHoldOrDoubleTapGesture == false)
    }

    @Test func suppressingDispatchEndsALatchedSession() {
        let fixture = makeFixture()

        down(fixture.manager)
        up(fixture.manager)
        down(fixture.manager)
        up(fixture.manager)
        #expect(fixture.recorder.activations == [.latchStart])

        fixture.manager.setEventDispatchSuppressed(true)
        #expect(fixture.recorder.activations == [.latchStart, .latchStop])
    }
}
