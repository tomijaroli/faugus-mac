import AVFAudio
import FaugusCore
import Foundation

/// Decodes Ogg Vorbis with `stb_vorbis` and plays through `AVAudioEngine`. Volume uses the
/// Gtk.MediaFile curve `percent^(1/3)`. Calls are coalesced like `play_ui_sound`.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    weak var model: AppModel?
    /// Live draft while the Interface Sounds dialog is open (`preview_ui_sound_config`).
    var previewSettings: InterfaceSoundsSettings?

    private var queue = UISoundQueue()
    private var cache: [String: VorbisPCM] = [:]
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var didStartEngine = false

    private init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    var assetsDirectory: String {
        Bundle.main.resourceURL?.appendingPathComponent("assets").path ?? ""
    }

    func play(_ kind: UISoundKind) {
        if queue.enqueue(kind) {
            DispatchQueue.main.async { self.flush() }
        }
    }

    func clearQueue() {
        queue.clear()
    }

    /// Preview button: plays the file immediately, ignoring the coalesce queue.
    func preview(kind: UISoundKind, settings: InterfaceSoundsSettings) {
        clearQueue()
        let path = settings.filePath(kind: kind, assetsDirectory: assetsDirectory) { model?.paths.expand($0) ?? $0 }
        playFile(path: path, gain: settings.playbackGain)
    }

    private func flush() {
        let kind = queue.flush(now: ProcessInfo.processInfo.systemUptime)
        guard let kind else { return }
        let settings = currentSettings
        guard settings.isEnabled else { return }
        let path = settings.filePath(kind: kind, assetsDirectory: assetsDirectory) { model?.paths.expand($0) ?? $0 }
        playFile(path: path, gain: settings.playbackGain)
    }

    private var currentSettings: InterfaceSoundsSettings {
        if let previewSettings {
            return previewSettings
        }
        if let configuration = model?.activeConfig {
            return InterfaceSoundsSettings(configuration: configuration)
        }
        return InterfaceSoundsSettings()
    }

    func playFile(path: String, gain: Double) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        guard let pcm = cache[path] ?? VorbisPCM.decode(path: path) else { return }
        cache[path] = pcm
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(pcm.sampleRate),
            channels: AVAudioChannelCount(pcm.channelCount)
        ) else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.frameCount))
        else { return }
        buffer.frameLength = AVAudioFrameCount(pcm.frameCount)
        guard let channels = buffer.floatChannelData else { return }
        for frame in 0 ..< pcm.frameCount {
            for channel in 0 ..< pcm.channelCount {
                let sample = Float(pcm.samples[frame * pcm.channelCount + channel]) / 32768
                channels[channel][frame] = sample
            }
        }
        startEngineIfNeeded()
        playerNode.volume = Float(min(1, max(0, gain)))
        if playerNode.isPlaying {
            playerNode.stop()
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        playerNode.play()
    }

    private func startEngineIfNeeded() {
        guard !didStartEngine else { return }
        do {
            try engine.start()
            didStartEngine = true
        } catch {
            // No output device: stay silent.
        }
    }
}
