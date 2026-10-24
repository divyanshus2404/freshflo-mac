# Freshflo accuracy · 0.22.0 · 2026-10-24

**Overall: 93.2%** (331/355 cases)

| Suite | Passed | Score | Typical time |
|---|---|---|---|
| Everyday dictation | 84/98 | 86% | 401 ms |
| Grammar | 74/76 | 97% | 403 ms |
| Hindi/Hinglish → English | 49/50 | 98% | 606 ms |
| Other languages | 82/82 | 100% | 623 ms |
| Spoken clips | 42/49 | 86% | 1288 ms |

Spoken clips: mean word error rate 14.7% (lower is better).

## By category

| Suite | Category | Passed |
|---|---|---|
| Everyday dictation | chat | 10/10 |
| Everyday dictation | correction | 4/10 ⚠︎ |
| Everyday dictation | email | 5/6 ⚠︎ |
| Everyday dictation | fillers | 8/10 ⚠︎ |
| Everyday dictation | keep | 8/8 |
| Everyday dictation | list | 6/6 |
| Everyday dictation | long | 1/4 ⚠︎ |
| Everyday dictation | names | 8/8 |
| Everyday dictation | numbers | 10/12 ⚠︎ |
| Everyday dictation | prompt | 6/6 |
| Everyday dictation | question | 8/8 |
| Everyday dictation | tech | 10/10 |
| Grammar | agreement | 8/8 |
| Grammar | articles | 5/5 |
| Grammar | combined | 5/5 |
| Grammar | hinglish | 3/3 |
| Grammar | homophones | 10/11 ⚠︎ |
| Grammar | indian | 15/16 ⚠︎ |
| Grammar | keep | 7/7 |
| Grammar | order | 3/3 |
| Grammar | plurals | 3/3 |
| Grammar | prepositions | 4/4 |
| Grammar | pronouns | 3/3 |
| Grammar | tense | 8/8 |
| Hindi/Hinglish → English | correction | 2/2 |
| Hindi/Hinglish → English | email | 1/1 |
| Hindi/Hinglish → English | english | 2/2 |
| Hindi/Hinglish → English | english-question | 1/1 |
| Hindi/Hinglish → English | faithful | 5/6 ⚠︎ |
| Hindi/Hinglish → English | filler | 2/2 |
| Hindi/Hinglish → English | hindi | 6/6 |
| Hindi/Hinglish → English | hinglish | 12/12 |
| Hindi/Hinglish → English | list | 3/3 |
| Hindi/Hinglish → English | message | 1/1 |
| Hindi/Hinglish → English | mixed | 3/3 |
| Hindi/Hinglish → English | money | 2/2 |
| Hindi/Hinglish → English | names | 1/1 |
| Hindi/Hinglish → English | no-answer | 1/1 |
| Hindi/Hinglish → English | numbers | 1/1 |
| Hindi/Hinglish → English | polite | 1/1 |
| Hindi/Hinglish → English | question | 1/1 |
| Hindi/Hinglish → English | tech | 2/2 |
| Hindi/Hinglish → English | time | 1/1 |
| Hindi/Hinglish → English | urdu-script | 1/1 |
| Other languages | ar | 2/2 |
| Other languages | bn | 3/3 |
| Other languages | de | 3/3 |
| Other languages | es | 3/3 |
| Other languages | fr | 3/3 |
| Other languages | gu | 2/2 |
| Other languages | hi-devanagari | 8/8 |
| Other languages | hi-hinglish | 15/15 |
| Other languages | hi-mixed | 2/2 |
| Other languages | it | 2/2 |
| Other languages | ja | 2/2 |
| Other languages | kn | 2/2 |
| Other languages | ko | 2/2 |
| Other languages | ml | 2/2 |
| Other languages | mr | 3/3 |
| Other languages | nl | 1/1 |
| Other languages | pa | 2/2 |
| Other languages | pt | 2/2 |
| Other languages | ru | 2/2 |
| Other languages | ta | 3/3 |
| Other languages | te | 3/3 |
| Other languages | tr | 1/1 |
| Other languages | ur | 2/2 |
| Other languages | zh | 2/2 |

## What failed

- **Everyday dictation · fillers** um so I was thinking we could uh move the call to four  
  → I was thinking we could move the call to four.
- **Everyday dictation · fillers** you know I think we should just ship it  
  → You know, I think we should just ship it.
- **Everyday dictation · correction** send it to rahul actually send it to priya  
  → Send it to Rahul, actually send it to Priya.
- **Everyday dictation · correction** the budget is 5 lakh sorry 6 lakh  
  → The budget is 5 lakh, sorry 6 lakh.
- **Everyday dictation · correction** the deadline is friday or rather monday  
  → The deadline is Friday, or rather Monday.
- **Everyday dictation · correction** book a table for six no make it eight  
  → Book a table for six, no, make it eight.
- **Everyday dictation · correction** it's in the marketing folder sorry the sales folder  
  → It's in the marketing folder, sorry, the sales folder.
- **Everyday dictation · correction** the file is called report v2 no v3  
  → The file is called report v2, not v3.
- **Everyday dictation · numbers** we grew forty five percent this quarter  
  → We grew forty‑5 percent this quarter.
- **Everyday dictation · numbers** it takes ten to fifteen minutes  
  → It takes ten to 15 minutes
- **Everyday dictation · email** hello mr gupta thank you for your time today I'll send the contract by friday best regards  
  → Hi Mr Gupta, ⏎  ⏎ Thank you for your time today. I'll send the contract by Friday. ⏎  ⏎ Best regards, ⏎ Meera
- **Everyday dictation · long** so the update for this week is that we shipped the new onboarding flow and the signup rate  
  → So the update for this week is that we shipped the new onboarding flow and the signup rate went up by about 12 percent. We also fixed the payment bug that was a
- **Everyday dictation · long** quick recap from the call they liked the demo they want a pilot with fifty users starting   
  → Quick recap from the call: they liked the demo, want a pilot with fifty users starting next month, and asked for the pricing by Friday.
- **Everyday dictation · long** hey just a heads up I'll be out tomorrow for a doctor's appointment I'll check messages in  
  → Hey, just a heads up—I’ll be out tomorrow for a doctor’s appointment. I’ll check messages in the evening, and if anything urgent comes up, call me.
- **Grammar · indian** He is having fever since two days.  
  → He has had a fever for 2 days.
- **Grammar · homophones** Can you send me the dock before the call?  
  → Can you send me the dock before the call?
- **Hindi/Hinglish → English · faithful** main sync check kar raha hoon lekin isme thoda sa issue bhi aa sakta hai, hum dekhte hain,  
  → I am doing a sync check, but there could be a small issue. We'll see; if any issue arises, we will resolve it.
- **Spoken clips · email**   
  → My email is rahul.sharmar@gmail.com.
- **Spoken clips · hindi-to-english**   
  → There is a meeting tomorrow morning at 10 a.m.; please keep the record ready.
- **Spoken clips · in-names**   
  → Please loop in Aishwarya, Karthik, and Siddhath from the Hyderabad office.
- **Spoken clips · in-list**   
  → For tomorrow, first call the vent.
- **Spoken clips · ml-bn**   
  → Hey, I’ll prepare the report for you tomorrow.
- **Spoken clips · ml-te**   
  → Rapu, send a meeting invite to the team.
- **Spoken clips · ml-kn**   
  → We'll schedule the meeting later.
