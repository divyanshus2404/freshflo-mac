import CoreGraphics
import SwiftUI
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

// MARK: - Lists
section("Lists")
func list(_ s: String, _ bullet: String = "• ") -> String { ListFormat.apply(s, bullet: bullet) }
expect(list("For the trip I need three things. First my charger, second my passport, and third sunscreen."),
       "For the trip I need three things:\n1. My charger\n2. My passport\n3. Sunscreen", "ordinals → numbered list with lead-in")
expect(list("first eggs second milk third bread"), "1. Eggs\n2. Milk\n3. Bread", "unpunctuated ordinals")
expect(list("Step one, open settings. Step two, turn on captions. Step three, start talking."),
       "1. Open settings\n2. Turn on captions\n3. Start talking", "step one / step two")
expect(list("Agenda for today. Bullet point budget review. Next point hiring plan. Next point launch date."),
       "Agenda for today:\n- Budget review\n- Hiring plan\n- Launch date".replacingOccurrences(of: "- ", with: "• "), "bullet point / next point")
expect(list("Agenda bullet point budget bullet point hiring", "- "), "Agenda:\n- Budget\n- Hiring", "markdown bullets for AI and editor apps")
expect(list("I need three things: eggs, milk and bread."), "I need three things:\n• Eggs\n• Milk\n• Bread", "spoken count matches the items")
expect(list("First, update the API. Second, write the tests. Finally, ship it. Let me know if that works."),
       "1. Update the API\n2. Write the tests\n3. Ship it\n\nLet me know if that works.", "finally ends the list, closing sentence kept")
expect(list("Here's the plan:\n1. Draft\n2. Review\n3. Send"), "Here's the plan:\n1. Draft\n2. Review\n3. Send", "already a list stays a list")
expect(list("Notes:\n* one\n* two", "- "), "Notes:\n- One\n- Two", "model's markers normalised")
expect(list("Wait a second, I'll be there in a minute."), "Wait a second, I'll be there in a minute.", "'a second' isn't a list")
expect(list("I came first in the race and my friend came second."), "I came first in the race and my friend came second.", "ordinals in prose aren't a list")
expect(list("We have two options, but I'm not sure which one is better."), "We have two options, but I'm not sure which one is better.", "count without items isn't a list")
expect(list("Buy eggs, milk and bread on the way home."), "Buy eggs, milk and bread on the way home.", "a comma list in a sentence stays a sentence")
expect(list("First of all, thanks for coming."), "First of all, thanks for coming.", "a lone 'first' isn't a list")
expect(ListFormat.detect("um so first eggs uh second milk"), ListFormat.Detection(kind: .numbered, items: 2), "live detection: numbered")
expect(ListFormat.detect("okay for the trip I need first my charger second my passport and third"), ListFormat.Detection(kind: .numbered, items: 2), "live detection mid-list")
expect(list("i came first in the race and my friend came second"), "i came first in the race and my friend came second", "unpunctuated prose ordinals aren't a list")
expect(ListFormat.detect("OK, so for the trip I need three things first my charger second, my passport and third"), ListFormat.Detection(kind: .numbered, items: 2), "live captions with stray commas")
expect(ListFormat.detect("OK, so for the trip I need three things first my charger second my passport and third sunscreen"), ListFormat.Detection(kind: .numbered, items: 3), "live captions, list complete")
expect(ListFormat.detect("I came first, and my friend came second"), .sentences, "commas but prose")
expect(ListFormat.detect("bullet point budget"), ListFormat.Detection(kind: .bulleted, items: 1), "live detection: bullets")
expect(ListFormat.detect("so I was thinking we could meet on Wednesday"), .sentences, "live detection: sentences")
expect(ListFormat.bullet(for: "com.tinyspeck.slackmacgap"), "• ", "Slack gets round bullets")
expect(ListFormat.bullet(for: "com.todesktop.230313mzl4w4u92"), "- ", "Cursor gets Markdown bullets")
expect(TextPolish.apply("first eggs second milk third bread", .init(lists: false)), "first eggs second milk third bread", "Smart lists off keeps sentences")
expect(TextPolish.apply("um so first eggs, second milk", .init()), "1. Eggs\n2. Milk", "polish pass formats lists")

// MARK: - Spoken English
section("Spoken English")
func se(_ s: String) -> String { SpokenEnglish.fix(s) }
expect(se("I am having two brothers and one sister."), "I have two brothers and one sister.", "possessive having")
expect(se("He is knowing the answer."), "He knows the answer.", "stative knowing")
expect(se("We will discuss about the budget."), "We will discuss the budget.", "discuss about")
expect(se("He is having fever since two days."), "He has fever for two days.", "since + duration")
expect(se("I am staying here since 2019."), "I have been staying here since 2019.", "ongoing since a year")
expect(se("Today morning I had a call."), "This morning I had a call.", "today morning")
expect(se("Where you are going after office?"), "Where are you going after office?", "question inversion")
expect(se("Why you didn't call me?"), "Why didn't you call me?", "why didn't you")
expect(se("What you want for dinner?"), "What do you want for dinner?", "what do you want")
expect(se("Me and him are going to the gym."), "He and I are going to the gym.", "me and him")
expect(se("Him and his wife came."), "He and his wife came.", "him and his")
expect(se("Between you and I, it won't work."), "Between you and me, it won't work.", "between you and me")
expect(se("I didn't went there."), "I didn't go there.", "didn't went")
expect(se("Did you finished the report?"), "Did you finish the report?", "did you finished")
expect(se("He has went home."), "He has gone home.", "has went")
expect(se("I will called you."), "I will call you.", "will called")
expect(se("We should of left earlier."), "We should have left earlier.", "should of")
expect(se("Lets meet at the cafe."), "Let's meet at the cafe.", "Lets → Let's")
expect(se("Myself Rahul from sales."), "I'm Rahul from sales.", "Myself Rahul")
expect(se("Your welcome to join."), "You're welcome to join.", "your welcome")
expect(se("This laptop is faster then mine."), "This laptop is faster than mine.", "faster than")
expect(se("Don't loose your passport."), "Don't lose your passport.", "loose → lose")
expect(se("The policy will effect everyone."), "The policy will affect everyone.", "will affect")
expect(se("I need a information."), "I need information.", "a information")
expect(se("I will not able to attend."), "I will not be able to attend.", "not able to")
expect(se("I don't know weather we should go."), "I don't know whether we should go.", "weather → whether")
expect(se("The dog wagged it's tail."), "The dog wagged its tail.", "it's tail")
expect(se("We have two report and many thing to fix."), "We have two reports and many things to fix.", "plurals after numbers")
// Correct sentences are left alone
for ok in ["He left office in 2019.", "I'm going home since it's late.", "There always seems to be a bug.", "We have launch on Monday.",
           "Fill in a feedback form.", "I am having lunch.", "I am having a problem with the build.", "I've worked here since Monday.",
           "He lets me drive.", "Turn to the left.", "Their never-ending meetings.", "See you later then.", "Me and my team are on it.",
           "Let's discuss it tomorrow.", "The meeting depends on the client.", "We need to effect change.", "Ready for launch.", "It's way too expensive.", "The weather is nice.", "a two report summary", "I have 3 reports."] {
    expect(se(ok), ok, "unchanged: \(ok)")
}

// MARK: - Email and code
section("Email and code")
expect(EmailFormat.apply("Hi Marcus can you let the team know the launch is slipping to Monday? Thanks, Divyanshu."),
       "Hi Marcus,\n\nCan you let the team know the launch is slipping to Monday?\n\nThanks,\nDivyanshu", "greeting and sign-off")
expect(EmailFormat.apply("Hi sir, I will not be able to attend the meeting tomorrow. Regards."),
       "Hi sir,\n\nI will not be able to attend the meeting tomorrow.\n\nRegards,", "sir + regards")
expect(EmailFormat.apply("Thanks for the update, I'll take a look tomorrow."), "Thanks for the update, I'll take a look tomorrow.", "thanks in a sentence isn't a sign-off")
expect(EmailFormat.apply("Hey."), "Hey.", "too short to format")
expect(EmailFormat.apply("Hello team, one. Two is here. Three is here. Four is here. Best, Ana"),
       "Hello team,\n\nOne. Two is here.\n\nThree is here. Four is here.\n\nBest,\nAna", "paragraphs every two sentences")
expectTrue(EmailFormat.isMailTarget(bundleID: "com.apple.mail", windowTitle: ""), "Mail is a mail app")
expectTrue(EmailFormat.isMailTarget(bundleID: "com.google.Chrome", windowTitle: "Inbox (3) - me@gmail.com - Gmail"), "Gmail tab")
expect(EmailFormat.isMailTarget(bundleID: "com.tinyspeck.slackmacgap", windowTitle: "general"), false, "Slack isn't mail")
expect(CodeTerms.apply("rename it to camel case user id please"), "rename it to userId please", "camel case")
expect(CodeTerms.apply("call it snake case max retry count"), "call it max_retry_count", "snake case")
expect(CodeTerms.apply("make it pascal case user profile card."), "make it UserProfileCard.", "pascal case")
expect(CodeTerms.apply("constant case api base url and kebab case nav bar"), "API_BASE_URL and nav-bar", "constant + kebab")
expect(CodeTerms.apply("open package dot json and the dot env file"), "open package.json and the .env file", "file names")
expect(CodeTerms.apply("the user underscore id column"), "the user_id column", "underscore")
expect(CodeTerms.apply("In any case we should ship it"), "In any case we should ship it", "'in any case' untouched")
expect(CodeTerms.apply("visit example dot com"), "visit example dot com", "dot com left to the URL rules")

// MARK: - Meetings knowledge and MCP
section("Knowledge and MCP")
func meeting(_ id: String, _ title: String, _ notes: String, daysAgo: Double, transcript: String = "") -> Meeting {
    Meeting(id: id, title: title, date: Date().addingTimeInterval(-daysAgo * 86_400), duration: 1800, status: .ready, appName: "Zoom",
            notes: notes, transcript: transcript, error: nil, onDevice: nil)
}
let sample = [
    meeting("a", "Pricing sync", "Decided: Pro at $8/month. Owner: Priya.", daysAgo: 2),
    meeting("b", "Hiring plan", "Two backend roles open. Rahul screens candidates.", daysAgo: 1),
    meeting("c", "Old pricing chat", "Talked about pricing tiers, nothing decided.", daysAgo: 60),
]
let hits = Knowledge.search("what did we decide about pricing", in: sample)
expect(hits.first?.meeting.id, "a", "recent, on-topic meeting ranks first")
expect(hits.count, 2, "only meetings that mention the topic")
expect(Knowledge.search("hiring", in: sample).first?.meeting.id, "b", "title match")
expect(Knowledge.excerpt("Them: hello\nYou: the pricing is fine\nThem: ok\nYou: bye\nThem: x", for: "pricing"), "Them: hello\nYou: the pricing is fine\nThem: ok", "excerpt keeps neighbouring lines")
let initReply = try! MCPServer.handle(method: "initialize", params: ["protocolVersion": "2025-03-26"])
expect(initReply["protocolVersion"] as? String, "2025-03-26", "MCP echoes the client's protocol version")
let toolNames = ((try! MCPServer.handle(method: "tools/list", params: [:]))["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
expectTrue(toolNames.contains("search_meetings") && toolNames.contains("get_meeting"), "MCP lists meeting tools")
expectTrue((try? MCPServer.handle(method: "bogus", params: [:])) == nil, "MCP rejects unknown methods")
let cfg = FileManager.default.temporaryDirectory.appendingPathComponent("freshflo-mcp-test-\(UUID().uuidString).json")
try! #"{"mcpServers":{"other":{"command":"x"}},"theme":"dark"}"#.write(to: cfg, atomically: true, encoding: .utf8)
try! MCPServer.connect(cfg)
let merged = try! JSONSerialization.jsonObject(with: Data(contentsOf: cfg)) as! [String: Any]
expectTrue((merged["mcpServers"] as? [String: Any])?["other"] != nil && merged["theme"] as? String == "dark", "connect keeps the client's other settings")
expectTrue(MCPServer.isConnected(cfg), "connected")
try! MCPServer.disconnect(cfg)
expect(MCPServer.isConnected(cfg), false, "disconnected")
try? FileManager.default.removeItem(at: cfg)

// MARK: - Sync
section("Sync")
let mine = FolderSync.Payload(dictionary: ["Divyanshu", "Freshflo"], snippets: [Snippet(trigger: "my email", expansion: "me@a.com")],
                              toneRules: [AppToneRule(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", tone: .casual)])
let theirs = FolderSync.Payload(dictionary: ["freshflo", "Priya"], snippets: [Snippet(trigger: "My Email", expansion: "other@b.com"), Snippet(trigger: "address", expansion: "1 Main St")],
                                toneRules: [AppToneRule(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", tone: .formal), AppToneRule(bundleID: "com.apple.mail", appName: "Mail", tone: .formal)])
let both = FolderSync.merge(local: mine, remote: theirs)
expect(both.dictionary, ["Divyanshu", "Freshflo", "Priya"], "words merge, case-insensitive")
expect(both.snippets.map(\.expansion), ["me@a.com", "1 Main St"], "my snippet wins; new ones added")
expect(both.toneRules.map(\.tone), [.casual, .formal], "my app style wins; new app added")
let syncFile = FileManager.default.temporaryDirectory.appendingPathComponent("freshflo-sync-\(UUID().uuidString).json")
try! FolderSync.write(both, to: syncFile)
expect(FolderSync.read(syncFile)?.dictionary, both.dictionary, "shared file round-trips")
try? FileManager.default.removeItem(at: syncFile)

// MARK: - Speakers and Scratchpad
section("Speakers and Scratchpad")
let voices: [[Float]] = [[10, 2, 1], [10.3, 2.2, 0.8], [2, 8, 5], [9.8, 1.9, 1.2], [2.2, 8.3, 4.9]]
expect(Diarization.cluster(voices, threshold: 1.5, maxClusters: 6), [0, 0, 1, 0, 1], "two voices grouped")
expect(Set(Diarization.cluster([[1, 1, 1], [1.1, 0.9, 1], [0.95, 1.05, 1]], threshold: 1.5, maxClusters: 6)).count, 1, "one voice stays one")
expect(Diarization.speakers(samples: [Float](repeating: 0, count: 16_000 * 10), starts: [0, 5]), nil, "silence isn't two speakers")
expectTrue(MeetingProcessor.loudness([Float](repeating: 0.1, count: 32_000), from: 0, seconds: 1) > 0.09, "loudness of speech")
expect(MeetingProcessor.loudness([Float](repeating: 0, count: 32_000), from: 0, seconds: 1), 0, "loudness of silence")
var desktop = FocusContext(); desktop.bundleID = "com.apple.finder"; desktop.role = "AXList"
expectTrue(desktop.hasNoTextTarget, "Finder file list has nothing to type into")
desktop.role = "AXTextField"
expect(desktop.hasNoTextTarget, false, "renaming a file in Finder is a text field")
var slack = FocusContext(); slack.bundleID = "com.tinyspeck.slackmacgap"; slack.role = nil
expect(slack.hasNoTextTarget, false, "apps that hide their fields still get a normal paste")
expect(ScratchNote(text: "\nGroceries\nmilk").title, "Groceries", "note title is the first line")

section("Numbers survive the safety check")
expectTrue(Cleanup.sanitize("Send the invoice for ₹2,50,000.", raw: "send the invoice for two lakh fifty thousand rupees") != nil, "spoken amount → digits is not a summary")
expect(Cleanup.sanitize("Send it.", raw: "send the invoice for the new office chairs to rahul and priya today"), nil, "real summaries are still rejected")

section("Meeting tools")
var mt = Meeting(id: "m", title: "Sync", date: Date(), duration: 60, status: .ready, appName: "Zoom",
                 notes: "- **Speaker 2**: will send mockups\n- [ ] Mockups — Speaker 2", transcript: "[00:00] Priya: hi\n[00:03] Speaker 2: I'll send mockups\n[00:05] You: great\n[00:07] Speaker 2: by Wednesday",
                 error: nil, onDevice: nil)
expect(mt.speakers, ["Priya", "Speaker 2", "You"], "speakers in order of first appearance")
mt.cleanTranscript = "[00:03] Speaker 2: I will send the mockups."
let named = MeetingTools.rename(mt, from: "Speaker 2", to: "Arjun")
expect(named.speakers, ["Priya", "Arjun", "You"], "rename updates the transcript")
expectTrue(named.notes.contains("**Arjun**") && !named.notes.contains("Speaker 2"), "rename updates the notes")
expect(named.cleanTranscript, "[00:03] Arjun: I will send the mockups.", "rename updates the clean transcript")
expect(MeetingTools.rename(mt, from: "Speaker 2", to: "  ").speakers, mt.speakers, "blank name changes nothing")
expect(MeetingTools.prefix("[01:02] Rahul: yes"), "[01:02] Rahul:", "line prefix")
expect(MeetingTools.prefix("no prefix here"), "", "no prefix")

section("Microphones")
expect(AudioDevices.kind(AudioDevice(id: 0, uid: "bh", name: "BlackHole 2ch")), .loopback, "BlackHole is a loopback, never auto-picked")
expect(AudioDevices.kind(AudioDevice(id: 0, uid: "z", name: "ZoomAudioDevice")), .loopback, "Zoom's virtual device is a loopback")
expect(AudioDevices.kind(AudioDevice(id: 0, uid: "m", name: "Multi-Output Device")), .loopback, "multi-output is a loopback")
expectTrue(AudioDevices.Kind.external < .builtIn && .builtIn < .bluetooth && .bluetooth < .virtual, "external > built-in > Bluetooth > virtual")
expect(AudioDevices.preferredUID(chosen: "no-such-mic-uid", preferBuiltIn: true) == "no-such-mic-uid", false, "a disconnected chosen mic falls back to automatic")
_ = AudioDevices.someoneIsRecording()

section("Recap and names")
var monday9 = DateComponents(); monday9.year = 2026; monday9.month = 10; monday9.day = 19; monday9.hour = 9; monday9.minute = 30
let mon = Calendar.current.date(from: monday9)!
expectTrue(WeeklyRecap.isDue(now: mon, lastSent: nil, wordsLastWeek: 500), "Monday 9:30 with words: due")
expect(WeeklyRecap.isDue(now: mon, lastSent: nil, wordsLastWeek: 0), false, "no words, no recap")
expect(WeeklyRecap.isDue(now: mon, lastSent: mon.addingTimeInterval(-3600), wordsLastWeek: 500), false, "once a week")
expect(WeeklyRecap.isDue(now: mon.addingTimeInterval(86_400), lastSent: nil, wordsLastWeek: 500), false, "only on Mondays")
expect(WeeklyRecap.message(words: 8420, minutesSaved: 162, streak: 9), "8,420 words, 2 h 42 min saved · 9-day streak", "recap text")
expectTrue(NameBook.isName("Priya Raghunathan"), "a real name")
expect(NameBook.isName("Conference Room 4B"), false, "rooms aren't names")
expect(NameBook.isName("noreply@zoom.us"), false, "emails aren't names")

section("Languages")
expectTrue(LanguageID.isHinglish("yaar kal meeting hai toh please report ready rakhna"), "Hinglish in Latin letters")
expect(LanguageID.isHinglish("Can you send me the deck before the call tomorrow"), false, "English isn't Hinglish")
expect(LanguageID.detect(text: "Können wir das Meeting auf Donnerstag verschieben? Ich bin morgen leider krank.", whisperGuess: "en", hints: ["en", "hi"])?.code, "de", "clear German beats a wrong guess")
expect(LanguageID.detect(text: "मुझे कल सुबह मीटिंग में जाना है", whisperGuess: nil, hints: ["en", "hi"])?.code, "hi", "Hindi text")
expectTrue(LanguageID.shouldRetry(text: "Hot TK.", detected: "en", hints: ["en", "hi"]), "short nonsense English is retried in Hindi")
expect(LanguageID.shouldRetry(text: "Sounds good to me", detected: "en", hints: ["en", "hi"]), false, "real short English is kept")
expect(LanguageID.shouldRetry(text: "Hola equipo, mañana la reunión empieza a las diez", detected: "es", hints: ["en", "hi"]), false, "clear Spanish is kept even if not in your list")
expectTrue(LanguageID.matches("क्या आप मुझे कल कॉल से पहले अपडेटेड डेक भेज सकते हैं?", target: "Hindi"), "Hindi output matches Hindi")
expect(LanguageID.matches("Can you send me the updated deck before the call tomorrow?", target: "Hindi"), false, "English output doesn't match Hindi")
expectTrue(LanguageID.matches("Kya aap mujhe updated deck kal ke call se pehle bhej sakte ho?", target: "Hinglish (Hindi in Latin letters)"), "Hinglish output")
expect(LanguageID.matches("क्या आप मुझे डेक भेज सकते हैं कल कॉल से पहले", target: "Hinglish (Hindi in Latin letters)"), false, "Devanagari isn't Hinglish")

section("Themes and keys")
expect(Color(hex: "#FF6FB5").hexString, "#FF6FB5", "theme colour round-trips through hex")
expectTrue(Color.parseHex("12345") == nil && Color.parseHex("#GGGGGG") == nil, "bad hex rejected")
expect(UserTheme.decode(Data(##"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"  Neon ","accent":"#00FF88","command":"#AA00FF","ask":"#00AAFF"}"##.utf8))?.name, "Neon", "shared theme file imports")
expectTrue(UserTheme.decode(Data(##"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"x","accent":"red","command":"#AA00FF","ask":"#00AAFF"}"##.utf8)) == nil, "theme with a bad colour is refused")
expect(Set(HotkeyKey.allCases.flatMap(\.keyCodes)).count, HotkeyKey.allCases.reduce(0) { $0 + $1.keyCodes.count }, "every talk key has its own key code")
expect(Set(HotkeyKey.allCases.map(\.flagMask)).count, HotkeyKey.allCases.count, "every talk key has its own modifier bit")

expect(IndicatorAccent.fluid(0.2).hexString, IndicatorAccent.fluid(1.2).hexString, "Fluid loops seamlessly")
expect(IndicatorAccent.fluid(-0.8).hexString, IndicatorAccent.fluid(0.2).hexString, "Fluid handles any phase")
expect(IndicatorTheme.allCases.first, .fluid, "Fluid is the first theme")

section("Shortcuts and tap modes")
let cmd = CGEventFlags.maskCommand.rawValue, ctl = CGEventFlags.maskControl.rawValue, opt = CGEventFlags.maskAlternate.rawValue, sh = CGEventFlags.maskShift.rawValue
let space = KeyCombo(keyCode: 49, modifiers: ctl | opt, key: "Space")
expect(space.label, "⌃⌥Space", "combo label in Mac order")
expectTrue(space.matches(keyCode: 49, flags: ctl | opt | 0x100), "matches with device bits present")
expect(space.matches(keyCode: 49, flags: ctl | opt | sh), false, "extra Shift doesn't match")
expectTrue(KeyCombo(keyCode: 2, modifiers: 0, key: "D").problem(allowBare: false) != nil, "a bare letter is refused")
expectTrue(KeyCombo(keyCode: 105, modifiers: 0, key: "F13").problem(allowBare: false) == nil, "a bare F-key is fine")
expectTrue(KeyCombo(keyCode: 9, modifiers: cmd, key: "V").problem(allowBare: false) != nil, "⌘V is protected")
expectTrue(KeyCombo(keyCode: 2, modifiers: sh, key: "D").problem(allowBare: false) != nil, "Shift+letter is refused")
expectTrue(KeyCombo(keyCode: 2, modifiers: cmd | opt, key: "D").problem(allowBare: false) == nil, "⌥⌘D is fine")
expect(TalkKeyLogic.onRelease(mode: .holdOrTap, held: 0.1, locked: false), .lock, "tap locks hands-free")
expect(TalkKeyLogic.onRelease(mode: .holdOrTap, held: 1.2, locked: false), .finish, "hold then release inserts")
expect(TalkKeyLogic.onRelease(mode: .hold, held: 0.1, locked: false), .cancelQuietly, "hold-only ignores taps")
expect(TalkKeyLogic.onRelease(mode: .toggle, held: 2, locked: true), .ignore, "toggle ignores release")
expect(TalkKeyLogic.onRelease(mode: .doubleTap, held: 0.1, locked: false), .cancelQuietly, "first tap of a double-tap")
expect(TalkKeyLogic.onRelease(mode: .doubleTap, held: 0.1, locked: true), .ignore, "release while hands-free does nothing")
let now = Date()
expectTrue(TalkKeyLogic.startsLocked(mode: .doubleTap, lastTap: now.addingTimeInterval(-0.2), now: now), "second tap starts hands-free")
expect(TalkKeyLogic.startsLocked(mode: .doubleTap, lastTap: now.addingTimeInterval(-1), now: now), false, "slow taps don't")
expectTrue(TalkKeyLogic.startsLocked(mode: .toggle, lastTap: nil), "toggle always starts hands-free")
expect(TalkKeyLogic.startsLocked(mode: .holdOrTap, lastTap: now, now: now), false, "default mode starts held")

expect(UserTheme.from(url: URL(string: "freshflo://theme?n=Holi&a=ff5fa2&c=FFD23F&k=3BCEAC")!)?.accent, "#FF5FA2", "install link reads the theme")
expectTrue(UserTheme.from(url: URL(string: "freshflo://theme?n=x&a=zzzzzz&c=FFD23F&k=3BCEAC")!) == nil, "install link with a bad colour is refused")
expectTrue(UserTheme.from(url: URL(string: "freshflo://other?a=ff5fa2&c=FFD23F&k=3BCEAC")!) == nil, "other freshflo links aren't themes")
expect(UserTheme.from(url: URL(string: "freshflo://theme?a=ff5fa2&c=FFD23F&k=3BCEAC")!)?.name, "Shared theme", "unnamed theme gets a name")

section("Voice detection")
// A voice-like signal: a 140 Hz harmonic tone with pitch drift, shaped into 4 syllables a second.
let vox: [Float] = (0..<32_000).map { i in
    let t = Double(i) / 16_000, f0 = 140 + 15 * sin(2 * .pi * 0.7 * t)
    let syl = max(0, sin(2 * .pi * 4 * t))
    return Float(0.12 * syl * (sin(2 * .pi * f0 * t) + 0.6 * sin(4 * .pi * f0 * t) + 0.3 * sin(6 * .pi * f0 * t)))
}
var lcg: UInt64 = 42
let hiss: [Float] = (0..<32_000).map { _ in lcg = lcg &* 6364136223846793005 &+ 1; return Float(Int64(bitPattern: lcg >> 11) % 2000) / 2000 * 0.08 }
var tv = VoiceSense.Tracker(); tv.feed(vox)
var tn = VoiceSense.Tracker(); tn.feed(hiss)
expectTrue(tv.voicedSeconds > 0.5, "a pitched, syllabic voice is heard as voice")
expectTrue(tn.voicedSeconds < 0.1, "hiss is not a voice")
expectTrue(VoiceSense.decide(voiced: 0, speech: 0.9, music: 0), "classifier speech alone is enough (whispers)")
expect(VoiceSense.decide(voiced: 0.6, speech: 0.05, music: 0.9), false, "music with no speech isn't a person")
expectTrue(VoiceSense.decide(voiced: 0.6, speech: -1, music: 0), "pitch alone works without the classifier")
expect(VoiceSense.decide(voiced: 0.1, speech: 0.1, music: 0), false, "a cough isn't a dictation")
let gap = vox + [Float](repeating: 0, count: 16_000 * 3) + vox
let tight = VoiceSense.tightenPauses(gap)
expectTrue(tight.count < gap.count - 16_000 * 2 && tight.count > vox.count * 2, "a 3 s pause shrinks, speech stays")
expect(VoiceSense.tightenPauses(vox).count, vox.count, "speech without long pauses is untouched")
expect(VoiceSense.endPause(after: "Send it to Priya and", base: 2.5), 4.5, "trailing 'and' waits longer")
expect(VoiceSense.endPause(after: "Send it to Priya.", base: 2.5), 2.125, "a finished sentence ends sooner")
expect(VoiceSense.endPause(after: "kal meeting hai toh", base: 2.5), 4.5, "Hinglish 'toh' waits too")

section("Licences")
// Signed with a throwaway test key (not the real one).
let testPub = "lOKbjPPS9p/KQFUqVov5q3qct8WlLK8EftUI0SnPsYo="
if case .success(let l) = License.verify("FF1-eyJpZCI6InQxIiwidG8iOiJUZXN0IEJ1eWVyIiwicGxhbiI6ImxpZmV0aW1lIiwic2VhdHMiOjEsImlzc3VlZCI6MTc5MDAwMDAwMCwiZXhwaXJlcyI6MH0.UAnK8fPOJXN1JHK9kIPyOw6bOMBEfkzrrNowc3MztDqx3I_FLBEP3IF4BZheD2nrqDDYYtRgREwz8XuqyD59AQ", publicKey: testPub) {
    expect(l.plan, .lifetime, "a lifetime key verifies")
    expect(l.to, "Test Buyer", "it shows who it belongs to")
} else { expectTrue(false, "a lifetime key verifies") }
expect(License.verify("FF1-eyJpZCI6InQxIiwidG8iOiJUZXN0IEJ1eWVyIiwicGxhbiI6ImxpZmV0aW1lIiwic2VhdHMiOjEsImlzc3VlZCI6MTc5MDAwMDAwMCwiZXhwaXJlcyI6MH0.UAnK8fPOJXN1JHK9kIPyOw6bOMBEfkzrrNowc3MztDqx3I_FLBEP3IF4BZheD2nrqDDYYtRgREwz8XuqAD59AQ", publicKey: testPub), .failure(.signature), "a tampered key is refused")
expect(License.verify("FF1-eyJpZCI6InQyIiwidG8iOiJPbGQiLCJwbGFuIjoicHJvIiwic2VhdHMiOjEsImlzc3VlZCI6MTYwMDAwMDAwMCwiZXhwaXJlcyI6MTYwMDAwMDEwMH0.nXYOK0QoQrchi2SAicNHODWUiSCO0x5CzOVO3b9IIsieNlx7ga41gpSrvp_139RQndDl1rBqCSX8nEKoQuQ9AQ", publicKey: testPub), .failure(.expired), "an expired key is refused")
expect(License.verify("hello", publicKey: testPub), .failure(.format), "junk is refused")
expect(License.verify("FF1-eyJpZCI6InQxIiwidG8iOiJUZXN0IEJ1eWVyIiwicGxhbiI6ImxpZmV0aW1lIiwic2VhdHMiOjEsImlzc3VlZCI6MTc5MDAwMDAwMCwiZXhwaXJlcyI6MH0.UAnK8fPOJXN1JHK9kIPyOw6bOMBEfkzrrNowc3MztDqx3I_FLBEP3IF4BZheD2nrqDDYYtRgREwz8XuqyD59AQ"), .failure(.signature), "a key from another signer is refused")
expectTrue(!Pro.enforced, "beta: every Pro feature stays free")

// Talking from the first moment to the last (no quiet start or end) must not be trimmed away.
let nonstop: [Float] = (0..<64_000).map { i in
    let t = Double(i) / 16_000
    return Float(0.05 * (0.6 + 0.4 * sin(2 * .pi * 3 * t)) * sin(2 * .pi * 160 * t))
}
let kept = AudioRecorder.trimSilence(nonstop)
expectTrue(Double(kept.samples.count) >= Double(nonstop.count) * 0.9 && kept.voicedSeconds >= 3, "non-stop speech is kept, not trimmed as background")
let padded = [Float](repeating: 0.0005, count: 16_000) + nonstop + [Float](repeating: 0.0005, count: 16_000)
expectTrue(AudioRecorder.trimSilence(padded).samples.count < padded.count - 16_000, "silence around speech is still trimmed")

section("Growth prompts")
expectTrue(EnjoyPrompt.shouldAsk(days: 15, dictations: 60, asked: false), "asks after two weeks of real use")
expect(EnjoyPrompt.shouldAsk(days: 3, dictations: 200, asked: false), false, "not in the first two weeks")
expect(EnjoyPrompt.shouldAsk(days: 30, dictations: 10, asked: false), false, "not for light users")
expect(EnjoyPrompt.shouldAsk(days: 30, dictations: 500, asked: true), false, "never twice")

expect(WeeklyRecap.referralCode.count, 8, "referral code is short")
expectTrue(WeeklyRecap.referralLink.absoluteString.hasPrefix("https://freshflo.vercel.app/?r=") && WeeklyRecap.referralCode.allSatisfy(\.isHexDigit), "referral link carries only the anonymous code")

section("Indian scripts")
expect(Indic.dominantScript("मुझे कल मीटिंग में जाना है"), .devanagari, "Hindi text is Devanagari")
expect(Indic.dominantScript("আমি কাল যাব"), .bengali, "Bengali script")
expectTrue(Indic.wrongScript("مجھے کل میٹنگ میں جانا ہے", lang: "hi"), "Hindi in Urdu letters is the wrong script")
expect(Indic.wrongScript("mujhe kal meeting mein jaana hai", lang: "hi"), false, "romanised Hindi is Hinglish, not wrong")
expect(Indic.wrongScript("मुझे कल जाना है", lang: "hi"), false, "Devanagari Hindi is right")
expect(Indic.punctuate("मुझे कल मीटिंग में जाना है. फिर घर जाऊंगा.", lang: "hi"), "मुझे कल मीटिंग में जाना है। फिर घर जाऊंगा।", "Hindi sentences end with ।")
expect(Indic.punctuate("मी उद्या मीटिंगला जाणार आहे.", lang: "mr"), "मी उद्या मीटिंगला जाणार आहे.", "Marathi keeps the full stop")
expect(Indic.punctuate("আমি কাল যাব.", lang: "bn"), "আমি কাল যাব।", "Bengali uses ।")
expect(Indic.punctuate("Meet at 5 p.m. tomorrow.", lang: "hi"), "Meet at 5 p.m. tomorrow.", "English inside stays untouched")
expect(Indic.punctuate("कीमत 2.5 लाख है.", lang: "hi"), "कीमत 2.5 लाख है।", "decimals stay, the sentence end changes")
expectTrue(Indic.scriptPrompt("hi")?.contains("।") == true && Indic.scriptPrompt("en") == nil, "script prompt only for Indian languages")

section("Hackathon: demo meetings")
let demo = DemoMeetings.all()
expect(demo.count, 4, "four sample meetings")
expectTrue(demo.allSatisfy { $0.status == .ready && DemoMeetings.isDemo($0) }, "samples are ready and marked as demo")
expect(demo.first { $0.id == "demo-standup" }?.speakers, ["You", "Priya", "Rahul", "Meera"], "sample transcript speakers parse")
expectTrue(zip(demo, demo.dropFirst()).allSatisfy { $0.date > $1.date }, "samples newest first")

section("Hackathon: model credit")
expect(ModelCredit.label(model: "nvidia/nemotron-3-super-120b-a12b", baseURL: "https://api.tokenfactory.nebius.com/v1"),
       "nvidia/nemotron-3-super-120b-a12b · Nebius Token Factory", "credit names model and host")
expect(ModelCredit.parts("nvidia/nemotron-3-super-120b-a12b · Nebius Token Factory"),
       ModelCredit.Parts(headline: "NVIDIA Nemotron on Nebius Token Factory", model: "nvidia/nemotron-3-super-120b-a12b", nvidia: true), "Nemotron badge")
expect(ModelCredit.parts("openai/gpt-oss-120b · Groq").headline, "openai/gpt-oss-120b on Groq", "other models named as-is")
expect(ModelCredit.parts(ModelCredit.appleOnDevice).nvidia, false, "Apple model is not NVIDIA")
expect(ModelCredit.host("http://localhost:8000/v1"), "localhost", "custom host")

section("Hackathon: streaming")
expect(Cleanup.sseDelta(#"data: {"id":"x","choices":[{"index":0,"delta":{"content":"Hel"}}]}"#), "Hel", "SSE delta text")
expect(Cleanup.sseDelta(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), nil, "role-only delta has no text")
expect(Cleanup.sseDelta("data: [DONE]"), nil, "done marker")
expect(Cleanup.sseDelta(": keep-alive"), nil, "SSE comment")
expect(Cleanup.visibleText("<think>plan the answer"), "", "unfinished thinking hidden")
expect(Cleanup.visibleText("<think>plan</think>\nYou owe Acme a quote"), "You owe Acme a quote", "finished thinking removed")
expect(Cleanup.visibleText("Two items <think>hm"), "Two items", "thinking cut mid-reply")

let acme = demo.first { $0.id == "demo-acme" }!
expectTrue(Knowledge.cites("late [Acme customer call (Oct 16, 2026)]", acme), "shortened title still cites")
expect(Knowledge.cites("Acme mentioned in passing", acme), false, "a bare word is not a citation")

section("Hackathon: commitments")
let cal = Calendar.current
let tuesday = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 11))!
func ymd(_ d: Date?) -> String { d.map { let c = cal.dateComponents([.year, .month, .day], from: $0); return "\(c.year!)-\(c.month!)-\(c.day!)" } ?? "nil" }
expect(ymd(Commitments.resolveDue("by Friday", from: tuesday)), "2026-10-16", "by Friday from a Tuesday")
expect(ymd(Commitments.resolveDue("by next Wednesday", from: tuesday)), "2026-10-21", "next Wednesday")
expect(ymd(Commitments.resolveDue("today", from: tuesday)), "2026-10-13", "today")
expect(ymd(Commitments.resolveDue("tomorrow", from: tuesday)), "2026-10-14", "tomorrow")
expect(ymd(Commitments.resolveDue("this week", from: tuesday)), "2026-10-16", "this week ends Friday")
expect(ymd(Commitments.resolveDue("end of the month", from: tuesday)), "2026-10-31", "end of the month")
expect(ymd(Commitments.resolveDue("2026-11-04", from: tuesday)), "2026-11-4", "ISO date")
expect(ymd(Commitments.resolveDue("soon-ish", from: tuesday)), "nil", "vague stays undated")

let notesMeeting = Meeting(id: "m1", title: "Sync", date: tuesday, duration: 60, status: .ready, appName: "", notes: """
## Decisions
- Ship it.
## Action items
- [ ] Get the new pricing page live — Priya, by Friday
- [x] Add the annual plan in Stripe — Rahul
- [ ] Scope SSO — Owner: none
- Meera: record the onboarding video by Thursday.
## Open questions
- [ ] Not an action item — You
""", transcript: "", error: nil, onDevice: nil)
let parsedItems = Commitments.parse(notesMeeting)
expect(parsedItems.map(\.task), ["Get the new pricing page live", "Add the annual plan in Stripe", "Scope SSO", "record the onboarding video"], "only the action items section")
expect(parsedItems.map(\.owner), ["Priya", "Rahul", "", "Meera"], "owners")
expect(parsedItems.map(\.due), ["by Friday", "", "", "by Thursday"], "due as written")
expect(parsedItems[1].doneNote, "Ticked in the notes", "ticked box is done")
expect(Commitments.parse(demo).filter(\.isMine).count, 4, "sample meetings give you four commitments")

let reply = #"Sure: {"items":[{"ids":[0,3],"task":"Pricing page live","owner":"Priya","due":"2026-10-16","done":"Priya said it went live [Standup]"},{"ids":[2],"owner":"none","due":null,"done":null},{"ids":[99]}]}"#
let applied = Commitments.apply(reply, to: parsedItems)
expect(applied?.count, 3, "merged pair, kept the rest")
expect(applied?.first?.doneNote, "Priya said it went live [Standup]", "done from a later meeting")
expect(applied?.first?.task, "Pricing page live", "model wording")
expect(applied?.contains { $0.task == "Add the annual plan in Stripe" && $0.doneNote == "Ticked in the notes" }, true, "items the reply left out are kept")
expect(Commitments.apply("I can't do that", to: parsedItems) == nil, true, "non-JSON reply rejected")
let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 22))!
var overdueItem = parsedItems[0]
expect(Commitments.bucket(overdueItem, ticked: false, today: today), .overdue, "past due is overdue")
expect(Commitments.bucket(overdueItem, ticked: true, today: today), .done, "ticked is done")
overdueItem.dueDate = cal.date(byAdding: .day, value: 3, to: today)
expect(Commitments.bucket(overdueItem, ticked: false, today: today), .thisWeek, "due in three days")
overdueItem.dueDate = nil
expect(Commitments.bucket(overdueItem, ticked: false, today: today), .noDate, "no date")

section("Hackathon: commitments for agents")
expect(Commitments.cacheKey(demo), Commitments.cacheKey(Array(demo.reversed())), "cache key ignores order")
expect(Commitments.cacheKey(demo).count, 64, "cache key is a SHA-256 hex string, stable across processes")
var editedDemo = demo
editedDemo[0].notes += "\n- [ ] One more thing — You"
expectTrue(Commitments.cacheKey(editedDemo) != Commitments.cacheKey(demo), "edited notes change the key")
let mineText = Commitments.agentText(parsedItems, model: nil, ticked: [], everyone: false, includeDone: false, today: today)
expectTrue(mineText.contains("## No date (1)") && mineText.contains("Scope SSO") && mineText.contains("commitment_id: m1|scope sso"), "mine: unowned item with its id")
expect(mineText.contains("Priya"), false, "mine leaves out other people's items")
expectTrue(mineText.hasPrefix("As written in the meeting notes"), "says when the list isn't organised yet")
let everyoneText = Commitments.agentText(parsedItems, model: "nvidia/nemotron-3-ultra-550b-a55b · Nebius Token Factory", ticked: [], everyone: true, includeDone: false, today: today)
expectTrue(everyoneText.contains("## Overdue (2)") && everyoneText.contains("due: 2026-10-16 (\"by Friday\")"), "everyone: overdue items with dates")
expect(everyoneText.contains("## Done"), false, "done items hidden by default")
expectTrue(everyoneText.hasPrefix("Organised by nvidia/nemotron-3-ultra-550b-a55b"), "names the model that organised it")
expectTrue(Commitments.agentText(parsedItems, model: nil, ticked: [], everyone: true, includeDone: true, today: today).contains("done: Ticked in the notes"), "done items on request")

let ssoID = "m1|scope sso"
let (emailProposal, emailMessage) = MCPServer.proposal(from: ["commitment_id": ssoID, "kind": "email", "title": "SSO scope", "body": "Hi Acme,", "to": "dana@acme.com"], items: parsedItems, by: "hermes-agent")
expect(emailProposal?.kind, .email, "agent proposes an email")
expect(emailProposal?.commitmentTask, "Scope SSO", "proposal names its commitment")
expect(emailProposal?.proposedBy, "hermes-agent", "proposal names the agent")
expectTrue(emailMessage.contains("nothing is sent"), "agent is told it needs approval")
expect(MCPServer.proposal(from: ["commitment_id": "nope", "kind": "email", "title": "x"], items: parsedItems, by: "a").0 == nil, true, "unknown commitment rejected")
expect(MCPServer.proposal(from: ["commitment_id": ssoID, "kind": "research", "title": "x"], items: parsedItems, by: "a").0 == nil, true, "agents can't queue research briefs")
expect(MCPServer.proposal(from: ["commitment_id": ssoID, "kind": "email", "title": "  "], items: parsedItems, by: "a").0 == nil, true, "title required")
expect(MCPServer.proposal(from: ["commitment_id": ssoID, "kind": "reminder", "title": "x", "due": "Friday"], items: parsedItems, by: "a").0 == nil, true, "reminder due must be a date")
let pricingID = "m1|get the new pricing page live"
expect(ymd(MCPServer.proposal(from: ["commitment_id": pricingID, "kind": "reminder", "title": "Pricing page"], items: parsedItems, by: "a").0?.due), "2026-10-16", "reminder defaults to the commitment's date")

_ = try! MCPServer.handle(method: "initialize", params: ["protocolVersion": "2025-06-18", "clientInfo": ["name": "hermes-agent", "version": "1"]])
expect(MCPServer.clientName, "hermes-agent", "MCP remembers which agent connected")
let mcpTools = (try! MCPServer.handle(method: "tools/list", params: [:]))["tools"] as? [[String: Any]] ?? []
let proposeTool = mcpTools.first { $0["name"] as? String == "propose_action" }
expectTrue(mcpTools.contains { $0["name"] as? String == "list_commitments" }, "MCP lists commitments")
expect((proposeTool?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, false, "propose_action is marked as writing")
expect((proposeTool?["annotations"] as? [String: Any])?["destructiveHint"] as? Bool, false, "propose_action is not destructive")

section("Hackathon: model resolver")
let catalog = ["nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B", "nvidia/Nemotron-3-Ultra-550b-a55b", "nvidia/nemotron-3-super-120b-a12b-v2", "meta-llama/Llama-3.3-70B-Instruct"]
expect(ModelResolver.pick(.chat, replacing: "nvidia/nemotron-3-ultra-550b-a55b", from: catalog), "nvidia/Nemotron-3-Ultra-550b-a55b", "same id in the provider's capitalisation")
expect(ModelResolver.pick(.chat, replacing: "nvidia/nemotron-3-super-120b-a12b", from: catalog), "nvidia/nemotron-3-super-120b-a12b-v2", "retired Super → another Super")
expect(ModelResolver.pick(.chat, replacing: "nvidia/nemotron-nano-old", from: catalog), "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B", "retired Nano → Nano, not Ultra")
expect(ModelResolver.pick(.chat, replacing: "some/model", from: catalog), "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B", "any Nemotron before other families")
expect(ModelResolver.pick(.chat, replacing: "qwen/gone", from: ["openai/gpt-oss-120b", "whisper-large-v3"]), "openai/gpt-oss-120b", "no Nemotron: known good chat model")
expect(ModelResolver.pick(.chat, replacing: "nvidia/Nemotron-3-Ultra-550b-a55b", from: ["nvidia/Nemotron-3-Ultra-550b-a55b"]), nil, "never 'replaces' a model with itself")
expect(ModelResolver.pick(.transcription, replacing: "whisper-1", from: ["llama", "whisper-large-v3"]), "whisper-large-v3", "transcription fallback")

section("Hackathon: next step (tool calling)")
let openAICall: [String: Any] = ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "c1", "type": "function",
    "function": ["name": "draft_email", "arguments": #"{"to":"dana@acme.com","subject":"Revised quote","body":"Hi Dana,\n\nHere is the revised quote."}"#]]]]
expect(CommitmentAgent.toolCall(from: openAICall), CommitmentAgent.ToolCall(name: "draft_email", arguments: ["to": "dana@acme.com", "subject": "Revised quote", "body": "Hi Dana,\n\nHere is the revised quote."]), "OpenAI tool_calls")
let nemotronText: [String: Any] = ["content": #"<think>owed to Acme</think><TOOLCALL>[{"name": "add_reminder", "arguments": {"title": "Book the venue", "due_date": "2026-10-20"}}]</TOOLCALL>"#]
expect(CommitmentAgent.toolCall(from: nemotronText), CommitmentAgent.ToolCall(name: "add_reminder", arguments: ["title": "Book the venue", "due_date": "2026-10-20"]), "Nemotron's text tool call")
expect(CommitmentAgent.toolCall(inText: #"{"tool": "research", "parameters": {"query": "SSO pricing", "why": null}}"#), CommitmentAgent.ToolCall(name: "research", arguments: ["query": "SSO pricing"]), "bare JSON call, nulls dropped")
expect(CommitmentAgent.toolCall(from: ["content": "I suggest emailing Dana."]), nil, "plain prose is not a call")
expect(CommitmentAgent.arguments(#"{"n": 3, "ok": true}"#), ["n": "3", "ok": "1"], "non-string arguments flattened")
let ssoItem = parsedItems[2]
let emailStep = CommitmentAgent.proposal(.init(name: "draft_email", arguments: ["subject": "", "body": "Hi team"]), item: ssoItem, by: "nemotron · Nebius Token Factory")
expect(emailStep?.kind, .email, "email proposal")
expect(emailStep?.title, "Scope SSO", "empty subject falls back to the task")
expect(CommitmentAgent.proposal(.init(name: "draft_email", arguments: ["subject": "x"]), item: ssoItem, by: "m") == nil, true, "email needs a body")
let pricingItem = parsedItems[0]
expect(ymd(CommitmentAgent.proposal(.init(name: "add_reminder", arguments: ["title": "Pricing page"]), item: pricingItem, by: "m")?.due), "2026-10-16", "reminder without a date uses the commitment's")
expect(ymd(CommitmentAgent.proposal(.init(name: "add_reminder", arguments: ["title": "x", "due_date": "2026-10-18"]), item: pricingItem, by: "m")?.due), "2026-10-18", "reminder date from the model")
expect(CommitmentAgent.proposal(.init(name: "research", arguments: ["query": "Stripe annual plans"]), item: pricingItem, by: "m")?.kind, .research, "research proposal")
expect(CommitmentAgent.proposal(.init(name: "delete_everything", arguments: [:]), item: pricingItem, by: "m") == nil, true, "unknown tools ignored")
let toolNamesWithResearch = CommitmentAgent.tools(research: true).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
expect(toolNamesWithResearch, ["draft_email", "add_reminder", "research"], "three tools with Tavily")
expect(CommitmentAgent.tools(research: false).count, 2, "no research tool without a Tavily key")
expectTrue(CommitmentAgent.prompt(for: pricingItem, meetings: [notesMeeting]).contains("where it was agreed"), "prompt carries the source meeting")

section("Hackathon: MCP over HTTP")
func httpRequest(_ method: String = "POST", path: String = "/mcp", headers: [String: String] = [:], body: String = "") -> MCPHTTP.Request {
    var h = headers
    h["content-length"] = String(body.utf8.count)
    return MCPHTTP.Request(method: method, path: path, headers: h, body: Data(body.utf8))
}
let rawPost = "POST /mcp?x=1 HTTP/1.1\r\nHost: 10.0.0.5\r\nAuthorization: Bearer s3cret\r\nContent-Length: 5\r\n\r\n{\"a\""
expect(MCPHTTP.parse(Data(rawPost.utf8)), .incomplete, "waits for the rest of the body")
if case .request(let r) = MCPHTTP.parse(Data((rawPost + "}").utf8)) {
    expect(r.path, "/mcp", "query string dropped")
    expect(r.headers["authorization"], "Bearer s3cret", "headers by lowercase name")
    expect(String(data: r.body, encoding: .utf8), "{\"a\"}", "body by Content-Length")
} else { expectTrue(false, "complete request parses") }
expect(MCPHTTP.parse(Data("GARBAGE\r\n\r\n".utf8)), .bad, "malformed request line")
expect(MCPHTTP.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)), .bad, "chunked bodies refused")
let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"nemohermes"}}}"#
let ok = MCPHTTP.respond(to: httpRequest(headers: ["authorization": "Bearer s3cret"], body: initBody), token: "s3cret")
expect(ok.status, 200, "authorised initialize")
expect((try? JSONSerialization.jsonObject(with: ok.body) as? [String: Any])?["id"] as? Int, 1, "reply carries the request id")
expect(MCPHTTP.respond(to: httpRequest(body: initBody), token: "s3cret").status, 401, "missing token")
expect(MCPHTTP.respond(to: httpRequest(headers: ["authorization": "Bearer s3cres"], body: initBody), token: "s3cret").status, 401, "wrong token")
expect(MCPHTTP.respond(to: httpRequest(body: initBody), token: "").status, 200, "no token configured (loopback only)")
expect(MCPHTTP.respond(to: httpRequest(headers: ["origin": "https://evil.example"], body: initBody), token: "").status, 403, "foreign browser origin refused")
expect(MCPHTTP.respond(to: httpRequest(headers: ["origin": "http://localhost:3000"], body: initBody), token: "").status, 200, "local origin allowed")
expect(MCPHTTP.respond(to: httpRequest("GET"), token: "").status, 405, "no event stream")
expect(MCPHTTP.respond(to: httpRequest(path: "/"), token: "").status, 404, "only /mcp")
expect(MCPHTTP.respond(to: httpRequest(body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), token: "").status, 202, "notification accepted without a body")
expect(MCPHTTP.respond(to: httpRequest(body: "{nope"), token: "").status, 400, "bad JSON")
let batchReply = MCPHTTP.respond(to: httpRequest(body: #"[{"jsonrpc":"2.0","id":7,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#), token: "")
expect((try? JSONSerialization.jsonObject(with: batchReply.body) as? [[String: Any]])?.count, 1, "batch: one reply per request")
expectTrue(MCPHTTP.sameSecret("abc", "abc") && !MCPHTTP.sameSecret("abc", "abd") && !MCPHTTP.sameSecret("abc", "abcd"), "secret comparison")
expect(MCPHTTP.isLoopback("0.0.0.0"), false, "all interfaces is not loopback")
let wire = String(data: MCPHTTP.serialize(.init(status: 202)), encoding: .utf8) ?? ""
expectTrue(wire.hasPrefix("HTTP/1.1 202 Accepted\r\n") && wire.contains("Content-Length: 0\r\n") && wire.hasSuffix("\r\n\r\n"), "response on the wire")

section("Hackathon: Tavily")
let tavilyReply: [String: Any] = ["answer": " Stripe supports annual prices. ", "results": [
    ["title": "Prices", "url": "https://docs.stripe.com/prices", "content": "Create a yearly price."], ["title": "", "url": "https://x.dev/a"], ["title": "no url"]]]
expect(Tavily.parse(tavilyReply), Tavily.Response(answer: "Stripe supports annual prices.", results: [
    .init(title: "Prices", url: "https://docs.stripe.com/prices", content: "Create a yearly price."), .init(title: "https://x.dev/a", url: "https://x.dev/a", content: "")]), "answer and pages")
expect(Tavily.parse(["detail": "bad key"]), nil, "error body is not a response")
expect(Tavily.parse(["answer": "", "results": []])?.answer, nil, "empty answer is no answer")

section("Hackathon: commitments eval")
let evalItems = Commitments.parse(notesMeeting)
let evalExpect = CommitmentsEval.Scenario.Expect(groups: [["pricing page", "onboarding video"], ["annual plan"], ["scope sso"]],
                                                 done: ["annual plan"], open: ["pricing page"], due: ["scope sso": "2026-10-30"])
var mergedOut = [evalItems[0]]
mergedOut[0].sourceIDs = [evalItems[0].id, evalItems[3].id]
mergedOut += [evalItems[1], evalItems[2]]
let perfect = CommitmentsEval.score(parsed: evalItems, output: mergedOut, expect: evalExpect)
expect(perfect.mergePrecision, 1, "right merge: precision")
expect(perfect.mergeRecall, 1, "right merge: recall")
expect(perfect.doneCorrect, 2, "done and open both right")
expect(perfect.dueCorrect, 0, "undated item misses its due date")
expect(perfect.lost, 0, "nothing lost")
let unmerged = CommitmentsEval.score(parsed: evalItems, output: evalItems, expect: evalExpect)
expect(unmerged.mergeRecall, 0, "missed merge: recall 0")
expect(unmerged.mergePrecision, 1, "no merges: nothing wrongly merged")
var overMerged = [evalItems[0]]
overMerged[0].sourceIDs = evalItems.map(\.id)
expect(CommitmentsEval.score(parsed: evalItems, output: overMerged, expect: evalExpect).mergePrecision, 1.0 / 6, "everything merged: precision 1/6")
expect(CommitmentsEval.score(parsed: evalItems, output: [evalItems[0]], expect: evalExpect).lost, 3, "dropped items counted")
expect(CommitmentsEval.labels(evalItems, groups: [["stripe"]]), [nil, 0, nil, nil], "labels by phrase")
let evalFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Benchmarks/commitments-eval.json")
let scenarios = (try? JSONDecoder().decode(CommitmentsEval.File.self, from: Data(contentsOf: evalFile)))?.scenarios ?? []
expect(scenarios.count, 7, "eval file loads")
expectTrue(scenarios.allSatisfy { s in
    let parsed = Commitments.parse(CommitmentsEval.meetings(s))
    return CommitmentsEval.labels(parsed, groups: s.expect.groups).allSatisfy { $0 != nil } && Set(CommitmentsEval.labels(parsed, groups: s.expect.groups).compactMap { $0 }).count == s.expect.groups.count
}, "every eval item is labelled and every group has an item")

section("Streamed pieces")
expectTrue(LanguageID.looksForeign("Cái bệnh hình hồi đó", hints: ["en", "hi"]), "Vietnamese from a misheard Hindi piece is caught")
expect(LanguageID.looksForeign("check karo kya isme sara paste ho raha hai", hints: ["en", "hi"]), false, "Hinglish is yours when you speak Hindi")
expect(LanguageID.looksForeign("I want you to let me know if it's working", hints: ["en", "hi"]), false, "English is fine")
expect(LanguageID.looksForeign("कल सुबह मीटिंग है", hints: ["en", "hi"]), false, "Hindi in Devanagari is fine")
expectTrue(LanguageID.looksForeign("কাল সকালে মিটিং আছে", hints: ["en", "hi"]), "Bengali script when you speak only English and Hindi")
expect(LanguageID.looksForeign("Cái bệnh hình hồi đó", hints: ["en", "vi"]), false, "Vietnamese is fine if you speak it")

// MARK: - Result

if failures.isEmpty {
    print("✓ All \(passed) checks passed")
    exit(0)
} else {
    print("✗ \(failures.count) failed, \(passed) passed\n")
    failures.forEach { print($0 + "\n") }
    exit(1)
}
