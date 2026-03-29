#if canImport(Testing)
import Foundation
@testable import Infrastructure
import Testing

@Test
func cloudStreamEventParsesDeltaPayload() {
    let event = CloudTranscriptionEngine.parseStreamEvent(
        name: "transcript.text.delta",
        data: #"{"delta":"Привет, "} "#
    )

    #expect(event == .delta("Привет, "))
}

@Test
func cloudStreamEventParsesDonePayload() {
    let event = CloudTranscriptionEngine.parseStreamEvent(
        name: "transcript.text.done",
        data: #"{"text":"Привет, мир"}"#
    )

    #expect(event == .done("Привет, мир"))
}

@Test
func cloudStreamEventIgnoresDoneSentinel() {
    let event = CloudTranscriptionEngine.parseStreamEvent(
        name: "transcript.text.done",
        data: "[DONE]"
    )

    #expect(event == .ignore)
}
#endif
