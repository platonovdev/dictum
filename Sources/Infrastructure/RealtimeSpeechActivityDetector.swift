import Foundation

struct SpeechActivityDecision {
    let confidence: Float
    let isSpeechDetected: Bool
}

struct RealtimeSpeechActivityDetector {
    private enum Constants {
        static let floorUpdate: Float = 0.16
        static let floorHoldUpdate: Float = 0.025
        static let minimumStartDuration: Float = 0.12
        static let minimumStopDuration: Float = 0.42
        static let startThreshold: Float = 0.60
        static let continueThreshold: Float = 0.36
    }

    private var broadbandFloorDB: Float = -58
    private var lowFloorDB: Float = -60
    private var midFloorDB: Float = -60
    private var highFloorDB: Float = -60
    private var confidence: Float = 0
    private var speechAccumulated: Float = 0
    private var silenceAccumulated: Float = 0
    private var isSpeechDetected = false

    mutating func process(
        rmsDB: Float,
        peakDB: Float,
        lowDB: Float,
        midDB: Float,
        highDB: Float,
        frameDuration: Float
    ) -> SpeechActivityDecision {
        let snr = max(rmsDB - broadbandFloorDB, 0)
        let lowLift = max(lowDB - lowFloorDB, 0)
        let midLift = max(midDB - midFloorDB, 0)
        let highLift = max(highDB - highFloorDB, 0)
        let crest = peakDB - rmsDB

        let looksLikeNoiseBed =
            !isSpeechDetected &&
            snr < 9 &&
            midLift < 8 &&
            highLift < 10

        let floorBlend = looksLikeNoiseBed ? Constants.floorUpdate : Constants.floorHoldUpdate
        broadbandFloorDB += (rmsDB - broadbandFloorDB) * floorBlend
        lowFloorDB += (lowDB - lowFloorDB) * floorBlend
        midFloorDB += (midDB - midFloorDB) * floorBlend
        highFloorDB += (highDB - highFloorDB) * floorBlend

        let snrScore = normalized(snr, from: 4, to: 18)
        let midScore = normalized(midLift, from: 3, to: 16)
        let highScore = normalized(highLift, from: 2, to: 14)
        let lowDominancePenalty = normalized(lowLift - midLift, from: 2, to: 10)
        let hissPenalty = normalized(highLift - midLift - 5, from: 0, to: 10)
        let transientPenalty = normalized(crest - 18, from: 0, to: 10) * normalized(highLift, from: 5, to: 16)

        var score =
            (snrScore * 0.45) +
            (midScore * 0.35) +
            (highScore * 0.20) -
            (lowDominancePenalty * 0.18) -
            (hissPenalty * 0.10) -
            (transientPenalty * 0.17)

        score = min(max(score, 0), 1)

        if isSpeechDetected {
            if score < Constants.continueThreshold {
                silenceAccumulated += frameDuration
            } else {
                silenceAccumulated = 0
            }

            if silenceAccumulated >= Constants.minimumStopDuration {
                isSpeechDetected = false
                speechAccumulated = 0
            }
        } else {
            if score > Constants.startThreshold {
                speechAccumulated += frameDuration
            } else {
                speechAccumulated = max(0, speechAccumulated - frameDuration * 0.5)
            }

            if speechAccumulated >= Constants.minimumStartDuration {
                isSpeechDetected = true
                silenceAccumulated = 0
            }
        }

        let targetConfidence = isSpeechDetected ? max(score, 0.72) : score * 0.45
        let confidenceBlend: Float = targetConfidence > confidence ? 0.42 : 0.12
        confidence += (targetConfidence - confidence) * confidenceBlend

        return SpeechActivityDecision(
            confidence: min(max(confidence, 0), 1),
            isSpeechDetected: isSpeechDetected
        )
    }

    mutating func reset() {
        broadbandFloorDB = -58
        lowFloorDB = -60
        midFloorDB = -60
        highFloorDB = -60
        confidence = 0
        speechAccumulated = 0
        silenceAccumulated = 0
        isSpeechDetected = false
    }

    private func normalized(_ value: Float, from lower: Float, to upper: Float) -> Float {
        guard upper > lower else {
            return 0
        }

        return min(max((value - lower) / (upper - lower), 0), 1)
    }
}
