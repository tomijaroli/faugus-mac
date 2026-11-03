@testable import FaugusCore
import Foundation
import Testing

@Suite("InterfaceSounds")
struct InterfaceSoundsTests {
    @Test func volumeUsesTheCubeRootOfTheSlider() {
        var settings = InterfaceSoundsSettings(volumePercent: 0)
        #expect(settings.playbackGain == 0)
        settings.volumePercent = 100
        #expect(abs(settings.playbackGain - 1) < 1e-9)
        settings.volumePercent = 50
        #expect(abs(settings.playbackGain - pow(0.5, 1.0 / 3.0)) < 1e-9)
        settings.volumePercent = 8
        #expect(abs(settings.playbackGain - pow(0.08, 1.0 / 3.0)) < 1e-9)
    }

    @Test func bundledPathUsesThemeAndKind() {
        let settings = InterfaceSoundsSettings(theme: .glass)
        #expect(
            settings.filePath(kind: .confirm, assetsDirectory: "/a", expand: { $0 })
                == "/a/sounds/glass-confirm.ogg"
        )
    }

    @Test func customThemeUsesTheExpandedCustomPath() {
        var settings = InterfaceSoundsSettings(theme: .custom)
        settings.customPaths[.navigate] = "~/beep.ogg"
        #expect(
            settings.filePath(
                kind: .navigate,
                assetsDirectory: "/a",
                expand: { $0.replacingOccurrences(of: "~", with: "/h") }
            )
                == "/h/beep.ogg"
        )
        #expect(settings.filePath(kind: .confirm, assetsDirectory: "/a", expand: { $0 }).isEmpty)
    }

    @Test func queueKeepsTheHighestKindAndDebouncesNavigate() {
        var queue = UISoundQueue()
        let firstNavigate = queue.enqueue(.navigate)
        let confirmOverNavigate = queue.enqueue(.confirm)
        let ignoredNavigate = queue.enqueue(.navigate)
        #expect(firstNavigate)
        #expect(!confirmOverNavigate)
        #expect(!ignoredNavigate)
        let coalesced = queue.flush(now: 1)
        #expect(coalesced == .confirm)

        _ = queue.enqueue(.navigate)
        let afterConfirm = queue.flush(now: 1.01)
        #expect(afterConfirm == .navigate)
        _ = queue.enqueue(.navigate)
        let debounced = queue.flush(now: 1.04)
        #expect(debounced == nil)
        _ = queue.enqueue(.navigate)
        let afterDebounce = queue.flush(now: 1.07)
        #expect(afterDebounce == .navigate)
        _ = queue.enqueue(.warning)
        let warning = queue.flush(now: 1.07)
        #expect(warning == .warning)
    }

    @Test func vorbisDecoderReadsABundledOgg() {
        let path = TestSupport.repoRoot
            .appendingPathComponent("upstream/assets/sounds/cloud-navigate.ogg").path
        let decoded = VorbisPCM.decode(path: path)
        #expect(decoded != nil)
        #expect((decoded?.channelCount ?? 0) >= 1)
        #expect((decoded?.sampleRate ?? 0) >= 8000)
        #expect((decoded?.frameCount ?? 0) > 0)
        #expect((decoded?.samples.count ?? 0) == (decoded?.frameCount ?? 0) * (decoded?.channelCount ?? 0))
    }

    @Test func settingsRoundTripThroughConfig() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        var configuration = try FaugusConfig.load(paths: paths)
        let settings = InterfaceSoundsSettings(
            isEnabled: true, theme: .kalimba, volumePercent: 80,
            customPaths: [.cancel: "/tmp/c.ogg"]
        )
        settings.write(to: &configuration)
        let loaded = InterfaceSoundsSettings(configuration: configuration)
        #expect(loaded.isEnabled)
        #expect(loaded.theme == .kalimba)
        #expect(loaded.volumePercent == 80)
        #expect(loaded.customPaths[.cancel] == "/tmp/c.ogg")
    }
}
