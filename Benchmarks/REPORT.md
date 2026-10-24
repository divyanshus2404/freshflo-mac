# Dictation benchmark — Oct 24, 2026 at 16:11

| | Freshflo |
|---|---|
| Cases compared | 49 |
| Formatting checks passed | 108/117 |
| Mean word error rate (audio cases) | 45% |
| Median latency (release → final text) | 1288 ms |

## Per case

**fillers** — reference: So I was thinking we could meet tomorrow morning.
- Freshflo (2/2, WER 0%): So I was thinking we could meet tomorrow morning.

**self-correction** — reference: Let's meet at 6 pm at the office.
- Freshflo (3/3, WER 0%): Let's meet at 6 p.m. at the office.

**names** — reference: Please send the contract to Divyanshu and Priyanka from Zerodha.
- Freshflo (3/3, WER 0%): Please send the contract to Divyanshu and Priyanka from Zerodha.

**jargon** — reference: We deployed the Kubernetes cluster and fixed the GraphQL resolver in the Next.js app.
- Freshflo (2/2, WER 0%): We deployed the Kubernetes cluster and fixed the GraphQL resolver in the Next.js app.

**rupees** — reference: The invoice is for ₹2,50,000, due on the 15th.
- Freshflo (1/1, WER 0%): The invoice is for ₹2,50,000 due on the 15th.

**email** — reference: My email is rahul.sharma@gmail.com.
- Freshflo (0/1, WER 11%): My email is rahul.sharmar@gmail.com. ⚠︎ missing “rahul.sharma@gmail.com”

**question** — reference: Can you review the pull request before lunch?
- Freshflo (1/1, WER 12%): Can you review the pull request before launch?

**list** — reference: For the trip I need to pack three things: a charger, my passport, and sunscreen.
- Freshflo (3/3, WER 7%): For the trip, I need to pack three things:
• A charger
• My passport
• Sunscreen

**casual-chat** — reference: haha yeah, sounds good, see you there
- Freshflo (1/1, WER 0%): haha yeah, sounds good, see you there

**hindi-to-english** — reference: There is a meeting at 10 a.m. tomorrow morning, please keep the report ready.
- Freshflo (1/2, WER 36%): There is a meeting tomorrow morning at 10 a.m.; please keep the record ready. ⚠︎ missing “report”

**long-form** — reference: Hi team, here is the weekly update. On the product side, we shipped the new onboarding flow and the pricing page is finally live. Conversion on the signup page went up by about 12%, which is great news. On engineering, we fixed the payment bugs and reduced the crash rate on iOS. Next week we will focus on the referral program and the Android beta. Please send me your blockers by Thursday so we can plan the sprint.
- Freshflo (0/0, WER 1%): Hi team, here is the weekly update. On the product side, we shipped the new onboarding flow and the pricing page is finally live. Conversion on the Cignut page went up by about 12%, which is great news. On engineering, we fixed the payment bugs and reduced the crash rate on iOS. Next week we will focus on the referral program and the Android beta. Please send me your blockers by Thursday so we can plan the sprint.

**command-formal** — reference: Could you please send me the report as soon as possible? Thank you.
- Freshflo (3/3, WER 8%): Hello, could you please send me the report as soon as possible? Thank you.

**in-chat** — reference: Okay, I'm reaching in 10 minutes, please wait at the gate.
- Freshflo (2/2, WER 27%): Okay, I am arriving in 10 minutes. Please wait at the gate.

**in-meeting** — reference: Can we prepone the meeting to Monday morning? Please revert by this evening.
- Freshflo (3/3, WER 0%): Can we prepone the meeting to Monday morning? Please revert by this evening.

**in-names** — reference: Please loop in Aishwarya, Karthik and Siddharth from the Hyderabad office.
- Freshflo (3/4, WER 9%): Please loop in Aishwarya, Karthik, and Siddhath from the Hyderabad office. ⚠︎ missing “Siddharth”

**in-money** — reference: The total comes to ₹1,20,000 including GST.
- Freshflo (2/2, WER 0%): The total comes to ₹1,20,000 including GST.

**in-correction** — reference: Book the cab for 7:30.
- Freshflo (2/2, WER 83%): Book the cab for 7:00. Wait, make it 7:30.

**in-fillers** — reference: The deployment failed because the config was wrong.
- Freshflo (4/4, WER 25%): So basically, the deployment failed because the config was wrong.

**in-tech** — reference: Push the changes to GitHub and trigger the Jenkins pipeline.
- Freshflo (2/2, WER 0%): Push the changes to GitHub and trigger the Jenkins pipeline.

**in-question** — reference: Have you shared the minutes of the meeting with the client?
- Freshflo (3/3, WER 0%): Have you shared the minutes of the meeting with the client?

**in-email** — reference: Hi Anjali,

Please find the revised quotation attached.

Thanks and regards,
Mohit
- Freshflo (3/3, WER 0%): Hi Anjali,

Please find the revised quotation attached.

Thanks and regards,

Mohit

**in-list** — reference: For tomorrow:
1. Call the vendor
2. Update the sheet
3. Send the invoice
- Freshflo (0/3, WER 71%): For tomorrow, first call the vent. ⚠︎ missing “vendor”; missing “sheet”; missing “invoice”

**hi-meeting** — reference: Tomorrow's meeting has been postponed, please let the client know.
- Freshflo (3/3, WER 70%): The meeting scheduled for tomorrow has been postponed; inform the client.

**hi-report** — reference: I'll send the report by evening, a little work is left.
- Freshflo (2/2, WER 27%): I will submit the report by evening; a little work is left.

**hi-question** — reference: Did you send the file I asked for yesterday?
- Freshflo (3/3, WER 33%): Did you send the file that I requested yesterday?

**hi-resolve** — reference: We will try to resolve this.
- Freshflo (3/3, WER 17%): We will try to resolve it.

**hi-money** — reference: The payment is ₹5,000.
- Freshflo (2/2, WER 0%): The payment is ₹5,000.

**hi-devanagari** — reference: आज बहुत अच्छा दिन था, सबने मिलकर काम किया।
- Freshflo (2/2, WER 0%): आज बहुत अच्छा दिन था, सबने मिलकर काम किया।

**us-fast** — reference: Hey, can you grab coffee on your way in? I'm stuck in back-to-back calls till noon.
- Freshflo (3/3, WER 0%): Hey, can you grab coffee on your way in? I'm stuck in back‑to‑back calls till noon.

**uk-formal** — reference: I'd like to schedule a review of the quarterly figures for next Thursday afternoon.
- Freshflo (2/2, WER 0%): I'd like to schedule a review of the quarterly figures for next Thursday afternoon.

**prompt-claude** — reference: Write a SQL query that finds the top 10 customers by revenue last month.
- Freshflo (3/3, WER 0%): Write a SQL query that finds the top 10 customers by revenue last month.

**time-date** — reference: The webinar is on the 24th of November at 4:30 PM.
- Freshflo (3/3, WER 33%): The webinar is on 24 November at 4:30 am.

**ml-bn** — reference: 
- Freshflo (2/3, WER 100%): Hey, I’ll prepare the report for you tomorrow. ⚠︎ missing “meeting”

**ml-ta** — reference: 
- Freshflo (2/2, WER 100%): There is a meeting tomorrow at 10 a.m.

**ml-te** — reference: 
- Freshflo (1/2, WER 100%): Rapu, send a meeting invite to the team. ⚠︎ missing “tomorrow”

**ml-kn** — reference: 
- Freshflo (1/2, WER 100%): We'll schedule the meeting later. ⚠︎ missing “tomorrow”

**ml-hi2** — reference: 
- Freshflo (3/3, WER 100%): I am working from home today, I will call in the evening.

**ml-es** — reference: 
- Freshflo (3/3, WER 100%): Tomorrow we have a meeting with the client at 10.

**ml-es-mx** — reference: 
- Freshflo (3/3, WER 100%): Can you send me the report before Friday?

**ml-fr** — reference: 
- Freshflo (3/3, WER 100%): We have a meeting tomorrow at 10 a.m. with the team.

**ml-de** — reference: 
- Freshflo (3/3, WER 100%): Can you send me the report by Friday?

**ml-pt** — reference: 
- Freshflo (2/2, WER 100%): Tomorrow we have a meeting at 10 a.m.

**ml-it** — reference: 
- Freshflo (2/2, WER 100%): Can you send me the report by Friday?

**ml-ja** — reference: 
- Freshflo (2/2, WER 100%): There is a meeting at 10 a.m. tomorrow.

**ml-zh** — reference: 
- Freshflo (2/2, WER 100%): We have a meeting at 10 a.m. tomorrow.

**ml-ko** — reference: 
- Freshflo (2/2, WER 100%): There is a meeting at 10 a.m. tomorrow.

**ml-ru** — reference: 
- Freshflo (3/3, WER 100%): Tomorrow at 10 we have a meeting with the client.

**ml-tr** — reference: 
- Freshflo (2/2, WER 100%): We have a meeting with the client tomorrow at 10 a.m.

**ml-nl** — reference: 
- Freshflo (2/2, WER 100%): Tomorrow at 10 a.m. we have a meeting.

