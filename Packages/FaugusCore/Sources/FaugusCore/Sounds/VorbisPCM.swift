import Foundation
import VorbisDecoder

/// PCM decoded from an Ogg Vorbis file (`stb_vorbis`).
public struct VorbisPCM: Sendable {
    public var channelCount: Int
    public var sampleRate: Int
    public var frameCount: Int
    public var samples: [Int16]

    public init(channelCount: Int, sampleRate: Int, frameCount: Int, samples: [Int16]) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.samples = samples
    }

    public static func decode(path: String) -> VorbisPCM? {
        var decoded = FaugusVorbisPCM()
        guard faugus_vorbis_decode_file(path, &decoded) == 0, let pointer = decoded.samples else { return nil }
        defer { faugus_vorbis_free(&decoded) }
        let sampleCount = Int(decoded.frameCount) * Int(decoded.channelCount)
        let samples = Array(UnsafeBufferPointer(start: pointer, count: sampleCount))
        return VorbisPCM(
            channelCount: Int(decoded.channelCount),
            sampleRate: Int(decoded.sampleRate),
            frameCount: Int(decoded.frameCount),
            samples: samples
        )
    }
}
