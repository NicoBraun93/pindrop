//
//  ParakeetEngine.swift
//  Pindrop
//
//  Created on 2026-01-30.
//

import Foundation
import FluidAudio

@MainActor
public final class ParakeetEngine: TranscriptionEngine, CapabilityReporting {
    
    public static var capabilities: AudioEngineCapabilities {
        [.transcription, .streamingTranscription, .voiceActivityDetection, .speakerDiarization]
    }
    
    public enum EngineError: Error, LocalizedError {
        case modelNotLoaded
        case invalidAudioData
        case transcriptionFailed(String)
        case downloadFailed(String)
        case initializationFailed(String)
        
        public var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "Model is not loaded"
            case .invalidAudioData:
                return "Invalid audio data"
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            case .downloadFailed(let message):
                return "Model download failed: \(message)"
            case .initializationFailed(let message):
                return "Initialization failed: \(message)"
            }
        }
    }
    
    public private(set) var state: TranscriptionEngineState = .unloaded
    public private(set) var error: Error?
    
    private var asrManager: AsrManager?
    private var transcribingTask: Task<String, Error>?
    
    public init() {}
    
    public func loadModel(path: String) async throws {
        guard state != .loading else { return }
        
        state = .loading
        error = nil
        
        do {
            throw EngineError.initializationFailed("Loading from path not supported for Parakeet. Use loadModel(name:downloadBase:) instead.")
        } catch {
            self.error = error
            state = .error
            throw error
        }
    }
    
    public func loadModel(name: String, downloadBase: URL? = nil) async throws {
        guard state != .loading else { return }
        
        state = .loading
        error = nil
        
        do {
            let version: AsrModelVersion = name.contains("v3") ? .v3 : .v2
            // ModelManager downloads into <downloadBase>/FluidInference/parakeet-coreml/<repo>.
            // Without passing that directory here FluidAudio falls back to its own
            // ~/Library/Application Support/FluidAudio/Models cache and downloads a
            // second copy of the model.
            let repo: Repo = version == .v3 ? .parakeetV3 : .parakeetV2
            let targetDirectory = downloadBase?
                .appendingPathComponent("FluidInference", isDirectory: true)
                .appendingPathComponent("parakeet-coreml", isDirectory: true)
                .appendingPathComponent(repo.folderName, isDirectory: true)
            let models = try await AsrModels.downloadAndLoad(
                to: targetDirectory,
                version: version,
                encoderPrecision: Self.encoderPrecision
            )

            // FluidAudio 0.15+: AsrManager takes models at init (or via loadModels),
            // replacing the retired `initialize(models:)` entry point.
            let manager = AsrManager(config: .default, models: models)
            try await manager.loadModels(models)

            asrManager = manager
            state = .ready
        } catch {
            self.error = error
            state = .error
            throw EngineError.downloadFailed(error.localizedDescription)
        }
    }
    
    public func transcribe(audioData: Data, options: TranscriptionOptions) async throws -> String {
        guard state == .ready else {
            throw EngineError.modelNotLoaded
        }
        
        guard !audioData.isEmpty else {
            throw EngineError.invalidAudioData
        }
        
        guard transcribingTask == nil else {
            throw EngineError.transcriptionFailed("Transcription already in progress")
        }
        
        guard let asrManager = asrManager else {
            throw EngineError.modelNotLoaded
        }
        
        state = .transcribing
        
        do {
            let samples = audioData.withUnsafeBytes { bytes in
                Array(bytes.bindMemory(to: Float.self))
            }

            // FluidAudio 0.15+: batch transcribe requires an explicit TDT decoder state.
            let decoderLayers = await asrManager.decoderLayerCount
            var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
            let result = try await asrManager.transcribe(
                samples,
                decoderState: &decoderState,
                language: Self.fluidAudioLanguage(for: options.language)
            )

            state = .ready
            return result.text
        } catch {
            state = .ready
            self.error = error
            throw EngineError.transcriptionFailed(error.localizedDescription)
        }
    }
    
    public func unloadModel() async {
        transcribingTask?.cancel()
        transcribingTask = nil
        
        asrManager = nil
        error = nil
        state = .unloaded
    }
    
    public func loadModel(modelName: String) async throws {
        try await loadModel(name: modelName, downloadBase: nil)
    }
    
    public func loadModel(modelPath: String) async throws {
        try await loadModel(path: modelPath)
    }

    /// Encoder weight format for Parakeet v3. `.int8` is the default 425 MB
    /// encoder; `.int4` trades a little accuracy for a 285 MB download and a
    /// smaller ANE footprint. Ignored by v2, which ships a single encoder.
    static let encoderPrecision: ParakeetEncoderPrecision = .int8

    /// Maps the app's transcription language onto FluidAudio's script-aware
    /// token filter. Parakeet v3's multilingual joint can emit Cyrillic tokens
    /// in the middle of Latin-script output (FluidAudio issue #512); passing the
    /// language constrains top-K candidates to the right script. Returns nil for
    /// "Automatic" and for languages the filter does not model — the decoder
    /// then behaves exactly as before. Silently ignored by v2.
    static func fluidAudioLanguage(for language: AppLanguage) -> Language? {
        switch language {
        case .english: return .english
        case .german: return .german
        case .spanish: return .spanish
        case .french: return .french
        case .italian: return .italian
        case .dutch: return .dutch
        case .portugueseBrazil: return .portuguese
        case .polish: return .polish
        case .russian: return .russian
        case .ukrainian: return .ukrainian
        case .automatic, .simplifiedChinese, .turkish, .japanese, .korean, .hindi, .malayalam:
            return nil
        }
    }
}
