# Freshflo accuracy · 0.22.0 · 2026-10-24

**Overall: 94.9%** (337/355 cases)

| Suite | Passed | Score | Typical time |
|---|---|---|---|
| Everyday dictation | 93/98 | 95% | 616 ms |
| Grammar | 75/76 | 99% | 466 ms |
| Hindi/Hinglish → English | 50/50 | 100% | 476 ms |
| Other languages | 80/82 | 98% | 399 ms |
| Spoken clips | 39/49 | 80% | 1725 ms |

Spoken clips: mean word error rate 15.7% (lower is better).

## By category

| Suite | Category | Passed |
|---|---|---|
| Everyday dictation | chat | 10/10 |
| Everyday dictation | correction | 9/10 ⚠︎ |
| Everyday dictation | email | 5/6 ⚠︎ |
| Everyday dictation | fillers | 10/10 |
| Everyday dictation | keep | 8/8 |
| Everyday dictation | list | 6/6 |
| Everyday dictation | long | 3/4 ⚠︎ |
| Everyday dictation | names | 8/8 |
| Everyday dictation | numbers | 10/12 ⚠︎ |
| Everyday dictation | prompt | 6/6 |
| Everyday dictation | question | 8/8 |
| Everyday dictation | tech | 10/10 |
| Grammar | agreement | 7/8 ⚠︎ |
| Grammar | articles | 5/5 |
| Grammar | combined | 5/5 |
| Grammar | hinglish | 3/3 |
| Grammar | homophones | 11/11 |
| Grammar | indian | 16/16 |
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
| Hindi/Hinglish → English | faithful | 6/6 |
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
| Other languages | ru | 1/2 ⚠︎ |
| Other languages | ta | 3/3 |
| Other languages | te | 3/3 |
| Other languages | tr | 1/1 |
| Other languages | ur | 2/2 |
| Other languages | zh | 2/2 |

## What failed

- **Everyday dictation · correction** the budget is 5 lakh sorry 6 lakh  
  → The budget is 6 lakh.
- **Everyday dictation · numbers** we have about one point five million users  
  → We have about 1.5 million users.
- **Everyday dictation · numbers** five crore rupees is the target  
  → ₹5,00,00,000 is the target.
- **Everyday dictation · email** hello mr gupta thank you for your time today I'll send the contract by friday best regards  
  → Hello Mr, ⏎  ⏎ Gupta, ⏎  ⏎ Thank you for your time today. I'll send the contract by Friday. ⏎  ⏎ Best regards, ⏎ Meera
- **Everyday dictation · long** so the update for this week is that we shipped the new onboarding flow and the signup rate  
  → So the update for this week is that we shipped the new onboarding flow and the signup rate went up by about 12%. We also fixed the payment bug that was affectin
- **Grammar · agreement** He have two meetings today.  
  → He has 2 meetings today.
- **Other languages · ru** Завтра в десять у нас встреча с клиентом  
  → Tomorrow at ten we have a meeting with the client
- **Spoken clips · email**   
  → My email is rahul.sharmar@gmail.com.
- **Spoken clips · in-meeting**   
  → Can we postpone the meeting to Monday morning? Please revert by this evening.
- **Spoken clips · hi-meeting**   
  → The meeting post for today is done, and it needs to be sent to the client.
- **Spoken clips · hi-question**   
  → Have you sent me the idea I asked for yesterday?
- **Spoken clips · hi-money**   
  → The pen costs ₹500.
- **Spoken clips · ml-bn**   
  → Today is a holiday, so I'll be working from home.
- **Spoken clips · ml-ta**   
  → Today is October 10th.
- **Spoken clips · ml-kn**   
  → Today is Friday.
- **Spoken clips · ml-pt**   
  → Amanhã, we have a meeting at 10 o'clock.
- **Spoken clips · ml-zh**   
  → We will meet tomorrow morning at 10 a.m.
