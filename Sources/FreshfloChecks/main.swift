// Logic checks for Freshflo. Run with:  swift run FreshfloChecks
// (Plain executable so it works with only the Command Line Tools installed.)
import Foundation
@testable import FreshfloKit

var failures: [String] = []
var passed = 0
var suite = ""

func section(_ name: String) { suite = name }

func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    if actual == expected {
        passed += 1
    } else {
        failures.append("[\(suite)] \(name) (line \(line))\n    got:      \(String(reflecting: actual))\n    expected: \(String(reflecting: expected))")
    }
}

func expectTrue(_ condition: Bool, _ name: String, line: Int = #line) {
    expect(condition, true, name, line: line)
}

// MARK: - Snippets

section("Snippets")
let snippets = [Snippet(trigger: "my email", expansion: "me@x.com"), Snippet(trigger: "sign off", expansion: "Best,\nD")]
expect(SnippetExpander.wholeMatch("My email.", snippets: snippets), "me@x.com", "whole-utterance match")
expect(SnippetExpander.wholeMatch("send my email to bob", snippets: snippets), nil, "no match inside sentence")
expect(SnippetExpander.applyInline("Send it to my email, thanks.", snippets: snippets), "Send it to me@x.com, thanks.", "inline expansion")
expect(SnippetExpander.applyInline("Thanks. Sign off.", snippets: snippets), "Thanks. Best,\nD", "inline at end")
expect(SnippetExpander.applyInline("my emails are full", snippets: snippets), "my emails are full", "no partial-word match")
let fixedDate = Date(timeIntervalSince1970: 1_791_700_000)
expect(SnippetExpander.fill("Link: {clipboard}", now: fixedDate, clipboard: { "https://x.y" }), "Link: https://x.y", "{clipboard}")
expect(SnippetExpander.fill("no vars", now: fixedDate, clipboard: { nil }), "no vars", "passthrough")

// MARK: - Cleanup

section("Cleanup")
expect(Cleanup.rules("um so I was thinking uh we should meet", tone: .formal), "So I was thinking we should meet.", "rules formal")
expect(Cleanup.rules("Hey, are you free tomorrow.", tone: .veryCasual), "hey, are you free tomorrow", "rules very casual")
expect(Cleanup.rules("first line new line second line", tone: .casual), "First line\nsecond line", "spoken new line")
expect(Cleanup.rules("what is the capital of France", tone: .casual), "What is the capital of France?", "question mark")
expect(Cleanup.sanitize("\"Hello there.\"", raw: "hello there"), "Hello there.", "strip quotes")
expect(Cleanup.sanitize(String(repeating: "x", count: 200), raw: "short"), nil, "reject runaway output")
expect(Cleanup.sanitize("Paris is the capital of France.", raw: "what is the capital of France"), nil, "reject answered question")
expect(Cleanup.sanitize("divyanshu@gmail.com", raw: "my email is divyanshu at gmail dot com today ok"), nil, "reject summarised output")
expectTrue(Cleanup.sanitize("Please have the report ready.", raw: "कृपया रिपोर्ट तैयार रखना", translating: true) != nil, "translation allowed")
expect(Transcriber.stripHallucinations("See you soon. Thanks for watching!"), "See you soon.", "strip Whisper hallucination")

func fast(_ raw: String, _ tone: Tone, before: String? = nil) -> String? {
    var ctx = FocusContext()
    ctx.textBefore = before
    return Cleanup.fastPath(CleanupInput(raw: raw, tone: tone, context: ctx, vocabulary: [], keepPhrases: []))
}
expect(fast("Sounds good.", .casual), "Sounds good", "fast path casual")
expect(fast("Sounds good", .formal), "Sounds good.", "fast path formal")
expect(fast("Um, sounds good.", .casual), nil, "filler needs LLM")
expect(fast("Meet at 5, no wait, 6.", .casual), nil, "correction needs LLM")
expect(fast("And then we left.", .casual, before: "We ate dinner"), "and then we left", "fast path continues sentence")
expect(fast(String(repeating: "word ", count: 30), .casual), nil, "long text needs LLM")

// MARK: - Context

section("Context")
var c = FocusContext()
c.textBefore = "Hello"
expect(c.spaced("world", fallbackTrailingSpace: true), " world", "space after word")
expect(c.spaced(", world", fallbackTrailingSpace: true), ", world", "no space before comma")
c.textBefore = "Hello "
expect(c.spaced("world", fallbackTrailingSpace: true), "world", "no double space")
c.textBefore = "("
expect(c.spaced("note", fallbackTrailingSpace: true), "note", "no space after paren")
c.textBefore = ""
expect(c.spaced("Hi", fallbackTrailingSpace: true), "Hi", "start of field")
c.textBefore = nil
expect(c.spaced("Hi", fallbackTrailingSpace: true), "Hi ", "unknown context → trailing space")
c.textBefore = "I wanted to ask"
expect(c.continued("What time is it?"), "what time is it?", "lowercase continuation")
expect(c.continued("Sarah said yes."), "Sarah said yes.", "keep names")
expect(c.continued("I think so."), "I think so.", "keep I")
c.textBefore = "Done."
expect(c.continued("The end."), "The end.", "new sentence keeps case")

// MARK: - Learning

section("Learning")
func learn(_ inserted: String, _ anchor: String, _ current: String) -> [String] {
    CorrectionLearner.learnedWords(inserted: inserted, anchor: anchor, current: current).sorted()
}
expect(learn("Send the deck to Devianchu.", "Hi team. ", "Hi team. Send the deck to Divyanshu."), ["Divyanshu"], "learn name")
expect(learn("Push it to github today.", "", "Push it to GitHub today."), ["GitHub"], "learn brand casing")
expect(learn("Ping Kubernetis", "", "Ping Kubernetes"), ["Kubernetes"], "learn last word")
expect(learn("the build passed.", "Done. ", "Done. The build passed."), [], "ignore sentence-start case")
expect(learn("Meet on Tuesday at noon.", "", "Meet on Wednesday at noon."), [], "ignore rewrite")
expect(learn("Put it over there.", "", "Put it over their."), [], "ignore common-word swap")
expect(learn("Thanks for the update.", "Hey. ", "Hey. Completely different text now written here instead."), [], "ignore unrelated edits")

// MARK: - Regional

section("Regional")
expect(Regional.apply("Pay 1500 rupees now.", .india), "Pay ₹1,500 now.", "rupees")
expect(Regional.apply("Send 5 lakh rupees.", .india), "Send ₹5 lakh.", "lakh")
expect(Regional.apply("It costs Rs. 250000", .india), "It costs ₹2,50,000", "Indian grouping")
expect(Regional.apply("Pay 1500 rupees.", .us), "Pay 1500 rupees.", "only for India")
expect(Regional.apply("The invoice is for ₹250,000 due.", .india), "The invoice is for ₹2,50,000 due.", "regroup Western ₹ amounts")
expect(Regional.apply("₹1,50,000 already Indian", .india), "₹1,50,000 already Indian", "keep Indian grouping")
expect(Regional.apply("mail rahul at the rate gmail dot com", .none), "mail rahul@gmail.com", "spoken email (at the rate)")
expect(Regional.apply("it's divyanshu at gmail dot com.", .none), "it's divyanshu@gmail.com.", "spoken email (at)")
expect(Regional.apply("meet me at home", .none), "meet me at home", "not an email")

// MARK: - Ask & meetings

section("Ask & meetings")
MainActor.assumeIsolated {
    if case .reminder(let title, let due) = Ask.parse(#"{"type":"reminder","title":"Call","due":"2026-10-11T17:00:00"}"#) {
        expect(title, "Call", "reminder title")
        expectTrue(due != nil, "reminder due date")
    } else {
        expectTrue(false, "parse reminder")
    }
    if case .open(let target) = Ask.parse("```json\n{\"type\":\"open\",\"target\":\"Figma\"}\n```") {
        expect(target, "Figma", "fenced JSON")
    } else {
        expectTrue(false, "parse fenced open")
    }
    expectTrue(Ask.parse("just text") == nil, "plain text isn't an intent")
    let lines = MeetingProcessor.removeEcho([
        (10, "Them", "we still have two bugs in payments"),
        (11, "You", "we still have two bugs in payments"),
        (20, "You", "let's ship on Friday"),
    ])
    expect(lines.map(\.speaker), ["Them", "You"], "speaker echo removed")
}

// MARK: - Audio

section("Audio")
let wav = AudioRecorder.wav(from: [Float](repeating: 0.1, count: 16_000))
expect(wav.count, 44 + 32_000, "WAV size")
expect(String(data: wav.prefix(4), encoding: .ascii), "RIFF", "WAV header")
let silence = [Float](repeating: 0, count: 16_000)
let tone = (0..<16_000).map { Float(sin(Double($0) * 0.1) * 0.3) }
let (trimmed, voiced) = AudioRecorder.trimSilence(silence + tone + silence)
expectTrue(voiced > 0.8 && voiced < 1.2, "voiced duration ≈ 1 s")
expectTrue(trimmed.count < 16_000 * 2, "silence trimmed")
expect(AudioRecorder.trimSilence(silence).voicedSeconds, 0, "pure silence → nothing")

// MARK: - Result

if failures.isEmpty {
    print("✓ All \(passed) checks passed")
    exit(0)
} else {
    print("✗ \(failures.count) failed, \(passed) passed\n")
    failures.forEach { print($0 + "\n") }
    exit(1)
}
