import Foundation

struct AdaptiveWaveformLeveler {
    private enum Constants {
        static let idleLevel: Float = 0.022
        static let minimumDynamicRange: Float = 0.12
        static let gateOffset: Float = 0.018
        static let activityThreshold: Float = 0.012
        static let historySize = 18
    }

    private var recentLevels = Array(repeating: Constants.idleLevel, count: Constants.historySize)
    private var noiseFloor = Constants.idleLevel
    private var speechCeiling = Constants.idleLevel + Constants.minimumDynamicRange
    private var envelope = Constants.idleLevel

    mutating func push(inputLevel: Float) -> Float {
        let level = min(max(inputLevel, 0), 1)

        recentLevels.append(level)
        if recentLevels.count > Constants.historySize {
            recentLevels.removeFirst(recentLevels.count - Constants.historySize)
        }

        let floorTarget = percentile(of: recentLevels, fraction: 0.22)
        let ceilingTarget = max(level, percentile(of: recentLevels, fraction: 0.94))

        noiseFloor += (floorTarget - noiseFloor) * 0.16

        let ceilingBlend: Float = ceilingTarget > speechCeiling ? 0.42 : 0.08
        let minimumCeiling = noiseFloor + Constants.minimumDynamicRange
        speechCeiling += (max(ceilingTarget, minimumCeiling) - speechCeiling) * ceilingBlend
        speechCeiling = max(speechCeiling, minimumCeiling)

        let gate = min(noiseFloor + Constants.gateOffset, 0.96)
        let dynamicRange = max(speechCeiling - noiseFloor, Constants.minimumDynamicRange)
        let normalized = min(max((level - gate) / dynamicRange, 0), 1)
        let emphasized = pow(normalized, 0.72)
        let isActive = level > gate + Constants.activityThreshold

        let target: Float
        if isActive {
            target = max(Constants.idleLevel, emphasized)
        } else {
            let residual = min(max((level - noiseFloor) / max(dynamicRange, 0.001), 0), 1)
            target = Constants.idleLevel + (residual * 0.03)
        }

        let smoothing: Float = target > envelope ? 0.58 : 0.22
        envelope += (target - envelope) * smoothing
        return max(Constants.idleLevel, min(envelope, 1))
    }

    mutating func reset() {
        recentLevels = Array(repeating: Constants.idleLevel, count: Constants.historySize)
        noiseFloor = Constants.idleLevel
        speechCeiling = Constants.idleLevel + Constants.minimumDynamicRange
        envelope = Constants.idleLevel
    }

    static var idleLevel: Float {
        Constants.idleLevel
    }

    private func percentile(of values: [Float], fraction: Float) -> Float {
        guard let first = values.first else {
            return Constants.idleLevel
        }

        let sorted = values.sorted()
        let index = Int(round(Float(sorted.count - 1) * min(max(fraction, 0), 1)))
        return sorted.indices.contains(index) ? sorted[index] : first
    }
}
