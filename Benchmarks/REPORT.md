# Dictation benchmark — Oct 11, 2026 at 13:24

| | ExcuseMe | wispr |
|---|---|---|
| Cases compared | 0 | 0 |
| Formatting checks passed | – | – |
| Mean word error rate (audio cases) | – | – |
| Median latency (release → final text) | 349 ms | n/a |

## Per case

**fillers** — reference: So I was thinking we could meet tomorrow morning.
- ExcuseMe (2/2, WER 0%): So I was thinking we could meet tomorrow morning.
- wispr: _not filled in yet_

**self-correction** — reference: Let's meet at 6 pm at the office.
- ExcuseMe (3/3, WER 0%): Let's meet at 6 p.m. at the office.
- wispr: _not filled in yet_

**names** — reference: Please send the contract to Divyanshu and Priyanka from Zerodha.
- ExcuseMe (3/3, WER 0%): Please send the contract to Divyanshu and Priyanka from Zerodha.
- wispr: _not filled in yet_

**jargon** — reference: We deployed the Kubernetes cluster and fixed the GraphQL resolver in the Next.js app.
- ExcuseMe (2/2, WER 0%): We deployed the Kubernetes cluster and fixed the GraphQL resolver in the Next.js app.
- wispr: _not filled in yet_

**rupees** — reference: The invoice is for ₹2,50,000, due on the 15th.
- ExcuseMe (1/1, WER 0%): The invoice is for ₹2,50,000 due on the 15th.
- wispr: _not filled in yet_

**email** — reference: My email is rahul.sharma@gmail.com.
- ExcuseMe (0/1, WER 11%): My email is rahul.sharmar@gmail.com. ⚠︎ missing “rahul.sharma@gmail.com”
- wispr: _not filled in yet_

**question** — reference: Can you review the pull request before lunch?
- ExcuseMe (1/1, WER 12%): Can you review the pull request before launch?
- wispr: _not filled in yet_

**list** — reference: For the trip I need to pack three things: a charger, my passport, and sunscreen.
- ExcuseMe (3/3, WER 0%): For the trip I need to pack three things, a charger, my passport, and sunscreen.
- wispr: _not filled in yet_

**casual-chat** — reference: haha yeah, sounds good, see you there
- ExcuseMe (1/1, WER 0%): haha yeah, sounds good, see you there
- wispr: _not filled in yet_

**hindi-to-english** — reference: There is a meeting at 10 a.m. tomorrow morning, please keep the report ready.
- ExcuseMe (1/2, WER 64%): Tomorrow morning at 10 a.m. we have a meeting, please keep the record ready. ⚠︎ missing “report”
- wispr: _not filled in yet_

**long-form** — reference: Hi team, here is the weekly update. On the product side, we shipped the new onboarding flow and the pricing page is finally live. Conversion on the signup page went up by about 12%, which is great news. On engineering, we fixed the payment bugs and reduced the crash rate on iOS. Next week we will focus on the referral program and the Android beta. Please send me your blockers by Thursday so we can plan the sprint.
- ExcuseMe (0/0, WER 1%): Hi team, here is the weekly update.

On the product side, we shipped the new onboarding flow and the pricing page is finally live. Conversion on the Cignut page went up by about 12%, which is great news.

On engineering, we fixed the payment bugs and reduced the crash rate on iOS.

Next week we will focus on the referral program and the Android beta.

Please send me your blockers by Thursday so we can plan the sprint.
- wispr: _not filled in yet_

**command-formal** — reference: Could you please send me the report as soon as possible? Thank you.
- ExcuseMe (3/3, WER 0%): Could you please send me the report as soon as possible? Thank you.
- wispr: _not filled in yet_

