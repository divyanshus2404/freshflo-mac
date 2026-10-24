import Foundation

/// Deterministic fixes for grammar slips that are common in speech, especially Indian English, and that a language model
/// sometimes leaves alone (Apple's on-device model in particular). Each rule is narrow on purpose: it only fires on
/// phrasings that are never right in written English, so correct sentences pass through untouched.
/// Runs before the model (so it starts from better text) and again after every engine.
enum SpokenEnglish {
    static func fix(_ text: String) -> String {
        var s = text
        for (pattern, template) in replacements { s = replaceKeepingCase(pattern, template, in: s) }
        s = pronounCase(s)
        s = verbForms(s)
        s = statives(s)
        s = questions(s)
        return s
    }

    /// Sentence start: beginning of text or after . ! ? (and a space).
    private static let start = #"(^|[.!?]\s+|\n)"#

    private static let replacements: [(String, String)] = [
        // "discuss about", "revert back", "very much excited", "do my graduation"
        (#"\b(discuss|discussed|discussing|discusses)\s+about\b"#, "$1"),
        (#"\brevert\s+back\b"#, "reply"),
        (#"\bvery\s+much\s+(excited|happy|interested|sorry|thankful|grateful|pleased|worried|tired)\b"#, "very $1"),
        (#"\b(I|we|he|she|they)\s+(?:have|has)\s+done\s+(?:my|our|his|her|their)\s+graduation\b"#, "$1 graduated"),
        // "today morning" → "this morning", "yesterday night" → "last night"
        (#"\btoday\s+(morning|afternoon|evening)\b"#, "this $1"),
        (#"\btoday\s+night\b"#, "tonight"),
        (#"\byesterday\s+night\b"#, "last night"),
        // "since two days" → "for two days" (a point in time, "since Monday", is left alone)
        (#"\bsince\s+((?:one|two|three|four|five|six|seven|eight|nine|ten|a few|many|several|\d+)\s+(?:minutes?|hours?|days?|weeks?|months?|years?))\b"#, "for $1"),
        // "reach office" → "reach the office"; "reached to the airport" → "reached the airport"
        (#"\b(reach|reached|reaching|go|going|went|come|coming|came)\s+(to\s+)?office\b"#, "$1 $2the office"),
        (#"\b(reach|reached|reaching|reaches)\s+to\s+(?=the\b|[A-Z])"#, "$1 "),
        // Prepositions that are never right
        (#"\bmarried\s+with\b"#, "married to"),
        (#"\bdepends?\s+of\b"#, "depends on"),
        (#"\bgood\s+in\s+(maths|math|english|science|sports|cooking|coding|drawing|singing)\b"#, "good at $1"),
        // "should of" → "should have"
        (#"\b(should|could|would|must|might)\s+of\b"#, "$1 have"),
        // Sound-alikes that are only ever one thing
        (#"\byour\s+welcome\b"#, "you're welcome"),
        (#"\btheir\s+(going|gonna|coming|doing|getting|looking|trying)\b"#, "they're $1"),
        (#"\bthere\s+(gonna|doing|getting|looking|trying)\b"#, "they're $1"),
        (#"\bthere\s+going\s+(?!to\s+be\b)"#, "they're going "),
        (#"\b(faster|slower|bigger|smaller|better|worse|cheaper|easier|harder|higher|lower|longer|shorter|older|younger|more|less|rather|larger|quicker|greater|smarter|stronger|cleaner|simpler|safer|nicer)\s+then\b"#, "$1 than"),
        (#"\bloose\s+(your|my|his|her|their|our|the|it|weight|money|time|track|touch|sleep)\b"#, "lose $1"),
        // "send me the dock": a document, unless boats are involved.
        (#"\b(send|share|forward|check|review|open|update|edit|read|attach|sign)(\s+(?:me|us|him|her|them))?\s+the\s+dock\b"#, "$1$2 the doc"),
        (#"\b(will|would|can|could|may|might|does|did|won't|doesn't|didn't)\s+effect\s+(?!change)"#, "$1 affect "),
        (#"\b(grab|grabbing|eat|ate|eating)\s+launch\b"#, "$1 lunch"),
        (#"\blaunch\s+break\b"#, "lunch break"),
        (#"\bbetween\s+you\s+and\s+I\b"#, "between you and me"),
        (#"\b(will|won't|would|should|may|might|shall)\s+(not\s+)?able\s+to\b"#, "$1 $2be able to"),
        (#"\bweather\s+(we|I|you|they|he|she|or not|to)\b"#, "whether $1"),
        (#"\bit's\s+(own|tail|name|colou?r|size|price|value|purpose|owner|battery|screen|logo|title)\b"#, "its $1"),
        // A number then a countable noun: "two report" → "two reports" (not "a two day trip")
        (#"(?<!\ba\s)\b(two|three|four|five|six|seven|eight|nine|ten|many|several|multiple|few|\d+)\s+(report|thing|phone|issue|file|email|bug|task|item|ticket|document|slide|idea|question|meeting|change|update|laptop|request|customer|client|friend|book)\b(?!s)"#, "$1 $2s"),
        // "a information" → "information" (uncountable), but "a feedback form" stays
        (#"\b(?:a|an)\s+(information|advice|furniture|equipment|luggage|baggage|homework)\b"#, "$1"),
        (#"\b(?:a|an)\s+feedback\b(?!\s+(?:form|loop|session|call|meeting|survey))"#, "feedback"),
    ]

    /// "Lets go" at a sentence start → "Let's go"; "Myself Rahul" → "I'm Rahul"; "Me and him are…" → "He and I are…".
    private static func pronounCase(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: start + #"([Ll])ets\b(?=\s+[a-z])"#, with: "$1$2et's", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(^|[.!?]\s+|\bso\s+|\bokay,?\s+)lets\s+(?=(?:go|meet|do|start|try|see|talk|get|grab|have|make|take|move|plan|keep|wait|check|discuss|finish|ship)\b)"#,
                                   with: "$1let's ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: start + #"Myself\s+([A-Z][\w-]+)\b"#, with: "$1I'm $2", options: .regularExpression)
        let nominative = ["me": "I", "him": "he", "her": "she", "them": "they", "us": "we"]
        // "Me and him are" → "He and I are"
        let pair = try! NSRegularExpression(pattern: start + #"(Me|Him|Her|Them|Us)\s+and\s+(me|him|her|them|us|I)\b"#, options: [.caseInsensitive])
        for m in pair.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let lead = Range(m.range(at: 1), in: s),
                  let a = Range(m.range(at: 2), in: s), let b = Range(m.range(at: 3), in: s) else { continue }
            let first = s[a].lowercased(), second = s[b].lowercased()
            let x = nominative[first] ?? first, y = nominative[second] ?? (second == "i" ? "I" : second)
            // The speaker goes last: "me and him" → "he and I".
            let ordered = x == "I" ? [y, "I"] : [x, y]
            let phrase = ordered[0].prefix(1).uppercased() + ordered[0].dropFirst() + " and " + ordered[1]
            s.replaceSubrange(whole, with: String(s[lead]) + phrase)
        }
        // "Him and his wife came" → "He and his wife came"
        s = s.replacingOccurrences(of: start + #"Him\s+and\s+(his|her|their|my)\b"#, with: "$1He and $2", options: .regularExpression)
        s = s.replacingOccurrences(of: start + #"Her\s+and\s+(his|her|their|my)\b"#, with: "$1She and $2", options: .regularExpression)
        s = s.replacingOccurrences(of: start + #"Them\s+and\s+(his|her|their|my)\b"#, with: "$1They and $2", options: .regularExpression)
        return s
    }

    private static let past: [String: String] = [
        "went": "go", "came": "come", "saw": "see", "did": "do", "ate": "eat", "took": "take", "gave": "give", "told": "tell",
        "wrote": "write", "bought": "buy", "brought": "bring", "got": "get", "made": "make", "sent": "send", "said": "say",
        "knew": "know", "thought": "think", "met": "meet", "left": "leave", "forgot": "forget", "spoke": "speak", "began": "begin",
        "called": "call", "finished": "finish", "asked": "ask", "worked": "work", "wanted": "want", "started": "start",
        "completed": "complete", "checked": "check", "reached": "reach", "joined": "join", "attended": "attend",
        "submitted": "submit", "received": "receive", "replied": "reply", "shared": "share", "reviewed": "review",
        "updated": "update", "fixed": "fix", "tried": "try", "talked": "talk", "planned": "plan", "booked": "book",
        "informed": "inform", "mentioned": "mention", "uploaded": "upload", "deployed": "deploy", "tested": "test",
    ]
    private static let participle: [String: String] = [
        "went": "gone", "came": "come", "saw": "seen", "did": "done", "ate": "eaten", "took": "taken", "gave": "given",
        "wrote": "written", "spoke": "spoken", "began": "begun", "forgot": "forgotten", "knew": "known", "drove": "driven",
    ]

    /// "didn't went" → "didn't go", "will called" → "will call", "did you finished" → "did you finish", "has went" → "has gone".
    private static func verbForms(_ text: String) -> String {
        var s = text
        let pastWords = past.keys.joined(separator: "|")
        let afterAux = try! NSRegularExpression(
            pattern: #"\b(didn't|did not|doesn't|does not|don't|do not|can't|cannot|can not|couldn't|won't|will|shall|should|would|must|can|could|may|might)\s+(\#(pastWords))\b"#,
            options: [.caseInsensitive])
        s = replaceGroup(2, in: s, regex: afterAux) { past[$0.lowercased()] }
        let question = try! NSRegularExpression(pattern: #"\b(did|does|do)\s+(you|he|she|they|we|I|it)\s+(\#(pastWords))\b"#, options: [.caseInsensitive])
        s = replaceGroup(3, in: s, regex: question) { past[$0.lowercased()] }
        let perfect = try! NSRegularExpression(pattern: #"\b(have|has|had|haven't|hasn't|hadn't|I've|you've|we've|they've)\s+(\#(participle.keys.joined(separator: "|")))\b"#,
                                               options: [.caseInsensitive])
        s = replaceGroup(2, in: s, regex: perfect) { participle[$0.lowercased()] }
        return s
    }

    /// "I am knowing" → "I know", "he is having two brothers" → "he has two brothers",
    /// "I am staying here since 2019" → "I have been staying here since 2019".
    private static func statives(_ text: String) -> String {
        var s = text
        let thirdPerson = #"(he|she|it|this|that|my \w+|[A-Z][a-z]+)"#
        for (ing, base, third) in [("knowing", "know", "knows"), ("understanding", "understand", "understands"),
                                   ("believing", "believe", "believes"), ("owning", "own", "owns"), ("belonging", "belong", "belongs")] {
            s = s.replacingOccurrences(of: #"\b(I)\s+am\s+\#(ing)\b"#, with: "$1 \(base)", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: #"\b(we|you|they)\s+are\s+\#(ing)\b"#, with: "$1 \(base)", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: #"\b\#(thirdPerson)\s+is\s+\#(ing)\b"#, with: "$1 \(third)", options: .regularExpression)
        }
        // Possession, not an activity: "having two brothers", "having fever", "having a doubt".
        let owned = #"(?=(?:a |an |two |three |four |one |no )?(?:brothers?|sisters?|siblings|kids|children|sons?|daughters?|car|bike|laptop|fever|cold|headache|cough|doubt|doubts)\b)"#
        s = s.replacingOccurrences(of: #"\b(I)\s+am\s+having\s+"# + owned, with: "$1 have ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\b(we|you|they)\s+are\s+having\s+"# + owned, with: "$1 have ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\b\#(thirdPerson)\s+is\s+having\s+"# + owned, with: "$1 has ", options: .regularExpression)
        // Ongoing since a point in time needs the perfect: "I am staying here since 2019". ("since" meaning "because" is left alone.)
        let since = #"([^.!?]{0,40}?\bsince\s+(?:\d|morning|yesterday|last\b|this\b|monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|may|june|july|august|september|october|november|december|childhood|school|college|then\b))"#
        s = s.replacingOccurrences(of: #"\b(I)\s+am\s+(\w+ing)\b"# + since, with: "$1 have been $2$3", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\b(we|you|they)\s+are\s+(\w+ing)\b"# + since, with: "$1 have been $2$3", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\b\#(thirdPerson)\s+is\s+(\w+ing)\b"# + since, with: "$1 has been $2$3", options: .regularExpression)
        return s
    }

    /// Spoken questions without the inversion: "Where you are going?" → "Where are you going?", "What you want?" → "What do you want?"
    private static func questions(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: start + #"(What|Where|When|Why|How|Who)\s+(you|he|she|they|we)\s+(didn't|don't|doesn't|can't|won't|haven't|hasn't|aren't|isn't|did|do|does|can|will|are|is|were|was|have|has)\b"#,
                                   with: "$1$2 $4 $3", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: start + #"(What|Where|When|Why|How)\s+you\s+(want|need|think|mean|like|say|know|have|prefer)\b"#,
                                   with: "$1$2 do you $3", options: [.regularExpression, .caseInsensitive])
        return s
    }

    /// Case-insensitive replace that keeps a capital first letter: "Your welcome" → "You're welcome".
    private static func replaceKeepingCase(_ pattern: String, _ template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        var s = text
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            var replacement = regex.replacementString(for: m, in: s, offset: 0, template: template)
            if s[r].first?.isUppercase == true, let first = replacement.first, first.isLowercase {
                replacement = first.uppercased() + replacement.dropFirst()
            }
            s.replaceSubrange(r, with: replacement)
        }
        return s
    }

    private static func replaceGroup(_ group: Int, in text: String, regex: NSRegularExpression, with map: (String) -> String?) -> String {
        var s = text
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range(at: group), in: s), let fixed = map(String(s[r])) else { continue }
            s.replaceSubrange(r, with: fixed)
        }
        return s
    }
}
