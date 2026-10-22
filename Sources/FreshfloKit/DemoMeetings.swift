import Foundation

/// Four connected sample meetings (a small team over two weeks) so "Chat with your meetings" and Open commitments
/// have something worth asking about. Commitments carry across meetings on purpose: one gets done in a later meeting,
/// one slips past its date, and one changes owner.
///   Freshflo --seed-demo [--with-ai]   adds them (--with-ai rewrites the notes with your model, as a real meeting would)
///   Freshflo --remove-demo             removes them
enum DemoMeetings {
    static let idPrefix = "demo-"

    static func isDemo(_ meeting: Meeting) -> Bool { meeting.id.hasPrefix(idPrefix) }

    static func all(now: Date = Date()) -> [Meeting] {
        func m(_ id: String, _ title: String, daysAgo: Double, hour: Int, minutes: Double, app: String, notes: String, transcript: String) -> Meeting {
            let day = Calendar.current.startOfDay(for: now.addingTimeInterval(-daysAgo * 86_400))
            return Meeting(id: idPrefix + id, title: title, date: day.addingTimeInterval(Double(hour) * 3_600), duration: minutes * 60,
                           status: .ready, appName: app, notes: notes, transcript: transcript, error: nil, onDevice: nil)
        }
        return [
            m("hiring", "Backend hiring: final loop debrief", daysAgo: 1, hour: 16, minutes: 28, app: "Google Meet", notes: hiringNotes, transcript: hiringTranscript),
            m("standup", "Weekly product standup", daysAgo: 3, hour: 10, minutes: 24, app: "Zoom", notes: standupNotes, transcript: standupTranscript),
            m("acme", "Acme customer call: SSO and invoicing", daysAgo: 6, hour: 18, minutes: 41, app: "Google Meet", notes: acmeNotes, transcript: acmeTranscript),
            m("pricing", "Pricing sync: Pro plan", daysAgo: 9, hour: 11, minutes: 32, app: "Zoom", notes: pricingNotes, transcript: pricingTranscript),
        ]
    }

    @MainActor
    static func seed(store: MeetingStore = .shared, rewriteNotes: Bool = false) async -> [Meeting] {
        var seeded: [Meeting] = []
        for var meeting in all() {
            if rewriteNotes, let written = try? await MeetingProcessor.writeNotes(transcript: meeting.transcript, settings: .shared) {
                meeting.notes = written.notes
                meeting.writtenBy = written.writtenBy
            }
            store.save(meeting)
            seeded.append(meeting)
        }
        store.reload()
        return seeded
    }

    @MainActor
    static func remove(store: MeetingStore = .shared) -> Int {
        let demo = store.meetings.filter(isDemo)
        demo.forEach(store.delete)
        return demo.count
    }

    // MARK: Pricing sync (9 days ago)

    static let pricingTranscript = """
    [00:04] You: Okay, let's lock pricing today. We've gone back and forth for two weeks.
    [00:21] Priya: The survey says people anchor on competitors at twelve dollars. I'd go eight a month for Pro.
    [01:10] Rahul: Eight works. Annual should feel like a real discount, so seventy two a year, that's six a month.
    [01:42] You: Agreed, eight monthly and seventy two annual. What about the free tier?
    [02:05] Priya: Keep it, but cap it at two thousand words a week. Unlimited free kills the upgrade.
    [02:51] You: Fine, two thousand words a week. Students get Pro free with a school email.
    [04:30] Rahul: Stripe doesn't have the annual plan yet. I can wire it up by next Wednesday.
    [05:02] You: Priya, can you get the new pricing page live by Friday?
    [05:09] Priya: Yes, Friday.
    [06:40] You: And I'll write the launch email. I'll have a draft to you both by Monday.
    [07:15] Priya: Open question: do existing beta users keep free Pro, and for how long?
    [07:31] You: Let's decide that next week. Good meeting.
    """

    static let pricingNotes = """
    ## Summary
    The team settled Pro pricing at $8 a month or $72 a year, kept a capped free tier and made Pro free for students. Stripe, the pricing page and the launch email each have an owner.
    ## Decisions
    - Pro costs $8/month or $72/year ($6/month).
    - Free tier stays, capped at 2,000 words a week.
    - Students get Pro free with a school email.
    ## Who said what
    - **Priya**: Survey anchors on $12 competitors; argued for $8 and for capping the free tier.
    - **Rahul**: Proposed $72 annual; Stripe needs the annual plan added.
    - **You**: Confirmed the prices and the student offer; owns the launch email.
    ## Action items
    - [ ] Get the new pricing page live — Priya, by Friday
    - [ ] Add the annual plan in Stripe — Rahul, by next Wednesday
    - [ ] Send the launch email draft to Priya and Rahul — You, by Monday
    ## Open questions
    - Do existing beta users keep free Pro, and for how long?
    """

    // MARK: Acme customer call (6 days ago)

    static let acmeTranscript = """
    [00:03] You: Thanks for making time, Dana. You mentioned the sales team wants to roll this out?
    [00:18] Dana: Forty seats to start. But two blockers: we need SSO, SAML through Okta, and we can't pay by card.
    [01:02] You: Invoicing we can do. SSO isn't built yet. How hard a requirement is it?
    [01:20] Dana: Security won't sign off without it. If it's on a roadmap with a date, that might be enough for now.
    [02:44] You: Understood. I'll send you a quote for forty seats with annual invoicing by Wednesday.
    [03:10] Dana: Great. Our budget closes at the end of the month, so the sooner the better.
    [03:35] You: Rahul on our side will scope SAML SSO, and I'll come back with a realistic date.
    [04:12] Dana: I'll send over our security questionnaire today.
    [05:30] Dana: One more thing, do you have a data processing agreement? Legal will ask.
    [05:41] You: We do, I'll attach it to the quote.
    """

    static let acmeNotes = """
    ## Summary
    Acme wants 40 seats for its sales team but needs SAML SSO (Okta) and invoice billing. Their budget closes at the end of the month, so the quote is time-sensitive.
    ## Key points
    - 40 seats to start; paid by annual invoice, not card.
    - Security requires SAML SSO through Okta; a dated roadmap commitment may be enough for now.
    - Legal will need a data processing agreement.
    ## Who said what
    - **Dana**: Needs SSO and invoicing; budget closes at month end; will send the security questionnaire.
    - **You**: Committed to a quote with the DPA attached and an SSO date after Rahul scopes it.
    ## Action items
    - [ ] Send Acme a quote for 40 seats with annual invoicing, DPA attached — You, by Wednesday
    - [ ] Scope SAML SSO with Okta and estimate the work — Rahul
    - [ ] Send the security questionnaire — Dana, today
    ## Open questions
    - Is a roadmap date for SSO enough for Acme's security team to approve?
    """

    // MARK: Weekly product standup (3 days ago)

    static let standupTranscript = """
    [00:05] You: Quick round. Priya?
    [00:09] Priya: Pricing page went live on Friday, and the student discount page too. Signups from students are already up.
    [00:40] Rahul: Annual plan is in Stripe, tested end to end. I scoped SSO for Acme: SAML with Okta is about three weeks.
    [01:15] You: Three weeks. Then SSO goes on the roadmap for mid-November and I'll tell Acme that. I still owe them the quote, it slipped.
    [01:38] Meera: The Windows installer is crashing on first launch for some beta users. About forty reports this week.
    [01:55] Rahul: I'll take that. Fix out by Friday.
    [02:20] You: Launch date, are we still on for next Tuesday?
    [02:31] Priya: I'd push a week. The onboarding video isn't recorded and the installer bug is live.
    [02:50] You: Okay, we move launch to November 4th. Meera, can you record the onboarding video by Thursday?
    [02:58] Meera: Yes, Thursday.
    [03:20] You: And beta users keep free Pro for three months after launch. That settles last week's question.
    """

    static let standupNotes = """
    ## Summary
    The pricing page and Stripe annual plan shipped. Launch moves to November 4 because the onboarding video isn't done and a Windows installer crash is affecting beta users. SSO for Acme is scoped at about three weeks.
    ## Decisions
    - Launch moves to November 4.
    - SSO goes on the roadmap for mid-November.
    - Beta users keep free Pro for three months after launch.
    ## Who said what
    - **Priya**: Pricing and student pages are live; argued for delaying launch a week.
    - **Rahul**: Stripe annual plan done; SAML SSO is about three weeks; owns the installer fix.
    - **Meera**: Reported ~40 Windows installer crashes; owns the onboarding video.
    - **You**: Moved launch; still owes Acme the quote and an SSO date.
    ## Action items
    - [ ] Fix the Windows installer crash on first launch — Rahul, by Friday
    - [ ] Record the onboarding video — Meera, by Thursday
    - [ ] Send Acme the quote and tell them SSO is planned for mid-November — You
    """

    // MARK: Hiring debrief (yesterday)

    static let hiringTranscript = """
    [00:02] You: Ananya's loop. Rahul, how was the system design round?
    [00:10] Rahul: Strongest we've seen. She designed the sync service better than what we shipped.
    [00:48] Meera: Culture round was great too. She asked sharp questions about how we handle user privacy.
    [01:20] You: Then let's make an offer. Same band as we discussed, plus the standard equity.
    [01:41] Rahul: Agreed. I'll write up my feedback today so it's on file.
    [02:05] You: I'll send Ananya the offer by Monday.
    [02:30] Meera: I'll schedule her two reference calls this week.
    [03:02] You: The other candidate, Karan, is a no for now. Meera, can you send him a kind note?
    [03:10] Meera: Will do.
    """

    static let hiringNotes = """
    ## Summary
    The team agreed to make Ananya an offer for the backend role after a strong system design and culture loop. Karan is a no for now.
    ## Decisions
    - Make Ananya an offer in the agreed band, with standard equity.
    - Karan is not moving forward for now.
    ## Who said what
    - **Rahul**: Ananya's system design was the strongest so far; will file written feedback.
    - **Meera**: Strong culture round; will run reference calls and close the loop with Karan.
    - **You**: Decided to make the offer and will send it.
    ## Action items
    - [ ] Send Ananya the offer — You, by Monday
    - [ ] Write up interview feedback — Rahul, today
    - [ ] Schedule Ananya's two reference calls — Meera, this week
    - [ ] Send Karan a kind rejection note — Meera
    """
}
