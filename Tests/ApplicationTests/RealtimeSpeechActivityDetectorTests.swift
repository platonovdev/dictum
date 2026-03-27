#if canImport(Testing)
import Foundation
@testable import Infrastructure
import Testing

@Test
func realtimeSpeechActivityDetectorRejectsSteadyHum() {
    var detector = RealtimeSpeechActivityDetector()
    var lastDecision = SpeechActivityDecision(confidence: 0, isSpeechDetected: false)

    for _ in 0..<32 {
        lastDecision = detector.process(
            rmsDB: -30,
            peakDB: -21,
            lowDB: -28,
            midDB: -43,
            highDB: -48,
            frameDuration: 0.02
        )
    }

    #expect(!lastDecision.isSpeechDetected)
    #expect(lastDecision.confidence < 0.25)
}

@Test
func realtimeSpeechActivityDetectorFindsSpeechOverNoise() {
    var detector = RealtimeSpeechActivityDetector()

    for _ in 0..<20 {
        _ = detector.process(
            rmsDB: -38,
            peakDB: -28,
            lowDB: -39,
            midDB: -44,
            highDB: -46,
            frameDuration: 0.02
        )
    }

    var decision = SpeechActivityDecision(confidence: 0, isSpeechDetected: false)
    for _ in 0..<12 {
        decision = detector.process(
            rmsDB: -24,
            peakDB: -11,
            lowDB: -33,
            midDB: -20,
            highDB: -27,
            frameDuration: 0.02
        )
    }

    #expect(decision.isSpeechDetected)
    #expect(decision.confidence > 0.65)
}
#endif
