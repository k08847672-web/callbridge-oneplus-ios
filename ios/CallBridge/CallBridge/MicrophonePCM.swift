import Foundation

/// +6 dB for quiet speech, with a whole-buffer peak ceiling instead of clipping samples.
/// Runs after Voice Processing/AEC; changes neither the audio route nor system volume.
enum MicrophonePCM {
    static let targetGain: Float = 2
    static let peakCeiling: Float = 0.95

    static func gain(forPeak peak: Float) -> Float {
        guard peak.isFinite, peak > 0 else { return targetGain }
        return min(targetGain, peakCeiling / peak)
    }

    static func encode(_ sample: Float, gain: Float) -> Int16 {
        let bounded = min(peakCeiling, max(-peakCeiling, sample * gain))
        return Int16(clamping: Int((bounded * 32767).rounded()))
    }
}
