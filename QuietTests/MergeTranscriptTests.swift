import Testing

// Live transcript merge: finalized lines first, then per-source volatiles
// (system before mic), each with its Me:/Them: speaker prefix.
@MainActor
struct MergeTranscriptTests {
    @Test func finalsThenVolatilesInSystemMicOrder() {
        let merged = AppState.mergeTranscript(
            finalized: ["Them: Hello", "Me: Hi"],
            volatile: [.mic: "I was thin", .system: "and then we"]
        )
        #expect(merged == "Them: Hello\nMe: Hi\nThem: and then we\nMe: I was thin")
    }

    @Test func volatileReplacesPerSourceInsteadOfAccumulating() {
        // ingest() overwrites volatileBySource[source] on every partial —
        // the merge must show only the latest partial per source.
        var volatile: [TranscriptSource: String] = [:]
        volatile[.mic] = "I was"
        volatile[.mic] = "I was thinking"
        let merged = AppState.mergeTranscript(finalized: [], volatile: volatile)
        #expect(merged == "Me: I was thinking")
    }

    @Test func finalClearsItsSourcesVolatile() {
        // ingest() sets volatileBySource[source] = nil when a final arrives;
        // the merged output then contains only the finalized line.
        var volatile: [TranscriptSource: String] = [.system: "so the plan"]
        var finalized: [String] = []
        finalized.append(TranscriptSource.system.speakerLabel + ": so the plan is set")
        volatile[.system] = nil
        let merged = AppState.mergeTranscript(finalized: finalized, volatile: volatile)
        #expect(merged == "Them: so the plan is set")
    }

    @Test func emptyVolatileTextIsSkipped() {
        #expect(AppState.mergeTranscript(finalized: ["Me: done"], volatile: [.system: ""]) == "Me: done")
    }

    @Test func emptyStateMergesToEmptyString() {
        #expect(AppState.mergeTranscript(finalized: [], volatile: [:]) == "")
    }

    @Test func speakerLabels() {
        #expect(TranscriptSource.system.speakerLabel == "Them")
        #expect(TranscriptSource.mic.speakerLabel == "Me")
    }
}
