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
expect(Cleanup.rules("push the launch to Tuesday. No wait Wednesday.", tone: .casual), "Push the launch to Wednesday.", "rules: correction across a full stop")
expect(Cleanup.rules("meet at 5, no wait, 6 pm", tone: .casual), "Meet at 6 pm", "rules: number correction")
expect(Cleanup.rules("lunch at one pm no wait one thirty pm", tone: .casual), "Lunch at one thirty pm", "rules: correction with pm")
expect(Cleanup.rules("send it to the the team", tone: .casual), "Send it to the team", "rules: repeated word")
expect(Cleanup.rules("so basically we need to fix it", tone: .casual), "We need to fix it", "rules: leading so/basically")
expect(Cleanup.rules("I had had enough", tone: .casual), "I had had enough", "rules: keeps grammatical 'had had'")
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

// MARK: - Updates & built-in engine

section("Updates")
MainActor.assumeIsolated {
    expectTrue(Updater.isNewer("0.9.5", than: "0.9.0"), "patch is newer")
    expectTrue(Updater.isNewer("0.10.0", than: "0.9.5"), "numeric, not alphabetical")
    expectTrue(Updater.isNewer("1.0", than: "0.9.9"), "major bump")
    expect(Updater.isNewer("0.9.5", than: "0.9.5"), false, "same version isn't newer")
    expect(Updater.isNewer("0.9", than: "0.9.0"), false, "missing parts count as zero")
}
section("Built-in engine")
var minute = [Float](repeating: 0, count: 16_000 * 130)
for i in minute.indices where (i / 16_000) % 47 != 46 {
    let phase = Double(i) * 0.05
    minute[i] = Float(sin(phase) * 0.3)
}
let pieces = LocalSpeech.chunks(minute)
expect(pieces.count, 3, "130 s splits into three pieces")
expectTrue(pieces.allSatisfy { Double($0.samples.count) / 16_000 <= 55 }, "every piece under Apple's one-minute limit")
expect(pieces.map { $0.samples.count }.reduce(0, +), minute.count, "no audio lost between pieces")
expectTrue(abs(pieces[1].offset - Double(pieces[0].samples.count) / 16_000) < 0.001, "offsets line up")
expect(LocalSpeech.chunks([Float](repeating: 0.1, count: 16_000 * 10)).count, 1, "short clips stay whole")
expectTrue(Tips.all.allSatisfy { !$0.isEmpty }, "tips present")
expectTrue(Tips.today(key: "Fn").contains("%@") == false, "tip placeholders filled")

// MARK: - Clean and correct

section("Repeats & stutters")
expect(TextPolish.removeStutters("th- the meeting moved"), "the meeting moved", "stutter fragment")
expect(TextPolish.removeRepeats("I think I think we should"), "I think we should", "repeated phrase")
expect(TextPolish.removeRepeats("send it to the the team."), "send it to the team.", "repeated word")
expect(TextPolish.removeRepeats("we we we need it"), "we need it", "triple repeat")
expect(TextPolish.removeRepeats("on Friday, Friday at 5."), "on Friday at 5.", "repeat keeps the later punctuation")
expect(TextPolish.removeRepeats("Go. Go."), "Go. Go.", "intentional repeat across a full stop")
expect(TextPolish.removeRepeats("I had had enough"), "I had had enough", "grammatical had had")
expect(TextPolish.removeRepeats("what it is is a problem"), "what it is is a problem", "grammatical is is")
expect(TextPolish.removeRepeats("the plan is is ready"), "the plan is ready", "stuttered is")
expect(TextPolish.removeRepeats("very very good"), "very very good", "emphasis kept")

section("Swear words")
expect(TextPolish.filterProfanity("this is fucking broken", mode: .cleanUp), "this is  broken", "intensifier removed")
expect(TextPolish.apply("What the fuck is this?", .init()), "What is this?", "what the f… → what")
expect(TextPolish.apply("this is bullshit", .init()), "this is nonsense", "polite swap")
expect(TextPolish.apply("Damn, that's nice", .init()), "That's nice", "leading swear removed and capitalized")
expect(TextPolish.apply("oh shit we're late", .init()), "oh no we're late", "oh no")
expect(TextPolish.apply("this shitty build", .init()), "this bad build", "adjective swap")
expect(TextPolish.apply("the deploy is f*** broken", .init()), "the deploy is broken", "recognizer-masked word removed")
expect(TextPolish.filterProfanity("this is fucking broken", mode: .mask), "this is f****** broken", "masked")
expect(TextPolish.filterProfanity("this is fucking broken", mode: .keep), "this is fucking broken", "kept")
expect(TextPolish.apply("mera manager chutiya hai", .init()), "mera manager idiot hai", "Hinglish insult")
expect(TextPolish.apply("Scunthorpe and assessment", .init()), "Scunthorpe and assessment", "no false positives inside words")

section("Names & grammar")
expect(TextPolish.snapToDictionary("send it to devianchu today", dictionary: ["Divyanshu"]), "send it to Divyanshu today", "near-miss name")
expect(TextPolish.snapToDictionary("ask sharmar", dictionary: ["Sharma"]), "ask Sharma", "extra letter")
expect(TextPolish.snapToDictionary("the prior plan", dictionary: ["Priya"]), "the prior plan", "different-sounding word untouched")
expect(TextPolish.snapToDictionary("push to github", dictionary: ["GitHub"]), "push to GitHub", "dictionary casing")
expect(TextPolish.snapToDictionary("mail rahul.sharmar@gmail.com", dictionary: ["Sharma"]), "mail rahul.sharmar@gmail.com", "emails untouched")
expect(TextPolish.grammarBasics("i think its a apple and an car", tone: .casual), "I think its an apple and a car", "a/an and I")
expect(TextPolish.grammarBasics("dont worry, im here", tone: .casual), "don't worry, I'm here", "apostrophes")
expect(TextPolish.grammarBasics("a hour, a university, an MBA", tone: .casual), "an hour, a university, an MBA", "a/an exceptions")
expect(TextPolish.grammarBasics("meet at 5 p.m. at the office. then lunch", tone: .casual), "meet at 5 p.m. at the office. Then lunch", "capitals, not after p.m.")
expect(TextPolish.grammarBasics("i think so", tone: .veryCasual), "i think so", "very casual keeps lowercase")
expect(TextPolish.grammarBasics("he don't know nothing about it", tone: .casual), "he doesn't know anything about it", "agreement + double negative")
expect(TextPolish.grammarBasics("they was there but I didn't see nobody", tone: .casual), "they were there but I didn't see anybody", "was/were + nobody")
expect(TextPolish.grammarBasics("I don't know", tone: .casual), "I don't know", "correct sentence untouched")
expect(TextPolish.grammarBasics("there is nothing to do", tone: .casual), "there is nothing to do", "plain nothing untouched")
expect(TextPolish.grammarBasics("if you were here", tone: .casual), "if you were here", "were untouched")
expect(TextPolish.apply("I I think the the deploy is fucking broken, its a issue", .init()), "I think the deploy is broken, its an issue", "everything together")

// MARK: - Prompt mode

section("Prompt mode")
expectTrue(PromptMode.isAITarget(bundleID: "com.todesktop.230313mzl4w4u92", windowTitle: "main.swift"), "Cursor")
expectTrue(PromptMode.isAITarget(bundleID: "com.google.Chrome", windowTitle: "ChatGPT"), "ChatGPT tab")
expectTrue(PromptMode.isAITarget(bundleID: "com.apple.Safari", windowTitle: "Refactor plan - Claude"), "Claude tab")
expectTrue(PromptMode.isAITarget(bundleID: "com.googlecode.iterm2", windowTitle: "✳ Claude Code — ~/app"), "Claude Code in a terminal")
expect(PromptMode.isAITarget(bundleID: "com.google.Chrome", windowTitle: "Inbox (3) - Gmail"), false, "ordinary tab")
expect(PromptMode.isAITarget(bundleID: "com.apple.Terminal", windowTitle: "zsh — 80×24"), false, "ordinary terminal")
expect(PromptMode.isAITarget(bundleID: "com.tinyspeck.slackmacgap", windowTitle: "Claude (DM)"), false, "Slack DM named Claude stays chat")
expectTrue(Cleanup.sanitize("Explain why my React component re-renders twice.", raw: "can you explain why my react component re-renders twice", promptStyle: true) != nil, "prompt may rephrase a question")
expect(Cleanup.sanitize("Explain why my React component re-renders twice.", raw: "can you explain why my react component re-renders twice"), nil, "chat style still guards questions")
expect(Cleanup.sanitize("Because the effect runs twice in development strict mode when components mount.", raw: "why does my react component render twice", promptStyle: true), nil, "an answer is still rejected")

// MARK: - Result

if failures.isEmpty {
    print("✓ All \(passed) checks passed")
    exit(0)
} else {
    print("✗ \(failures.count) failed, \(passed) passed\n")
    failures.forEach { print($0 + "\n") }
    exit(1)
}
