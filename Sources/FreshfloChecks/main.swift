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

// MARK: - Result

if failures.isEmpty {
    print("✓ All \(passed) checks passed")
    exit(0)
} else {
    print("✗ \(failures.count) failed, \(passed) passed\n")
    failures.forEach { print($0 + "\n") }
    exit(1)
}
