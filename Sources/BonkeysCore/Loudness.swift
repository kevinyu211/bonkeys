import Foundation

/// Holds keys at one real-world loudness by cancelling out the Mac's own volume.
public enum Loudness {
    /// Slider ends, as decibels after the Mac's volume has been applied.
    public static let range = -60.0 ... -6.0
    /// The most a key is ever amplified. Bounds both distortion and any surprise if a device misreports.
    public static let maxGain = 4.0

    public static func decibels(slider: Double) -> Double {
        range.lowerBound + max(0, min(1, slider)) * (range.upperBound - range.lowerBound)
    }
    public static func slider(decibels: Double) -> Double {
        max(0, min(1, (decibels - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
    /// `limited` means the Mac is turned down too far for the keys to reach the chosen level.
    public static func gain(slider: Double, systemDB: Double) -> (gain: Double, limited: Bool) {
        guard slider > 0 else { return (0, false) }
        let wanted = pow(10, (decibels(slider: slider) - systemDB) / 20)
        return (min(wanted, maxGain), wanted > maxGain * 1.01)
    }
    /// The slider position that sounds the same as `gain` does at this system volume.
    public static func slider(matching gain: Double, systemDB: Double) -> Double {
        slider(decibels: systemDB + 20 * log10(max(gain, 0.0001)))
    }
}
