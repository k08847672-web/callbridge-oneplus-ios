import Foundation

@main
struct MicrophonePCMSelfTests {
    static func main() throws {
        func check(_ value: Bool) throws { if !value { throw Failure.failed } }
        let quiet: [Float] = (0..<320).map { Float(sin(2 * Double.pi * 400 * Double($0) / 16000)) * 0.05 }
        let gain = MicrophonePCM.gain(forPeak: quiet.map { abs($0) }.max()!)
        try check(gain == 2)
        var before = 0.0, after = 0.0
        for sample in quiet {
            let encoded = Double(MicrophonePCM.encode(sample, gain: gain)) / 32767
            before += Double(sample) * Double(sample)
            after += encoded * encoded
        }
        let ratio = sqrt(after / before)
        try check(abs(ratio - 2) < 0.001)
        try check(MicrophonePCM.encode(0, gain: gain) == 0)
        let fullScaleGain = MicrophonePCM.gain(forPeak: 1)
        try check(abs(fullScaleGain - 0.95) < 0.00001)
        for value: Float in [-1, -0.5, 0, 0.5, 1] {
            let encoded = MicrophonePCM.encode(value, gain: fullScaleGain)
            try check(abs(Int(encoded)) <= 31129)
            try check(value == 0 || (encoded > 0) == (value > 0))
        }
        try check(MicrophonePCM.encode(0.1, gain: gain) > 0)
        try check(MicrophonePCM.encode(-0.1, gain: gain) < 0)
        print("PJZ_MICROPHONE_PCM passed=true quiet_rms_ratio=\(ratio) target_gain=2 peak_ceiling=0.95 silence_preserved=true full_scale_clipping=false synthetic_only=true")
    }
    enum Failure: Error { case failed }
}
