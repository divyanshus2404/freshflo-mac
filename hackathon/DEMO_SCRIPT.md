# Demo video script (~2.5 min)

Keep it tight. Show the product working; say "NVIDIA Nemotron on Nebius" out loud at
least twice. Shoot at 1080p, quiet room, cursor visible.

## 0:00–0:20 — Hook
> "This is Freshflo, a Mac app I built. It records my meetings and turns them into
> notes. For this hackathon I moved all of its AI onto NVIDIA's Nemotron model running
> on Nebius Token Factory — and added a way to just *chat* with everything I've ever
> recorded."

On screen: the app, a list of real meetings.

## 0:20–0:45 — Prove the plumbing
- Open **Settings → General → Transcription**. Show the engine picker set to
  **"Nebius Token Factory (NVIDIA Nemotron)"**. Click **Test** → *Key works*.
> "Speech is transcribed on my Mac for privacy; every bit of reasoning — notes,
> cleanup, chat — runs on NVIDIA Nemotron on Nebius."

## 0:45–1:15 — Meeting notes
- Open a meeting. Scroll the Nemotron-generated notes: decisions, action items with
  owners, open questions.
> "These notes were written by Nemotron from the transcript."

## 1:15–1:50 — Chat with your meetings
- Click **Chat with your meetings** in the sidebar. Point at the green
  **NVIDIA Nemotron on Nebius Token Factory** badge.
- Type: **"What do I still owe Acme?"** → the answer streams in, cites the Acme call
  and the standup; click a source chip to jump to that meeting.
- Follow up: **"and is it late?"** → it resolves "it" from the previous answer.
> "It streams, it remembers the conversation, and every answer cites its meeting.
> Retrieval is local — only the relevant excerpts reach Nemotron."

## 1:50–2:15 — The new one: Open commitments
- Click **Open commitments**. Show **Overdue** (the Acme quote, merged from two
  meetings: "Also came up in…"), **Due this week**, and **Done** with the green
  "Priya said the pricing page went live [Weekly product standup]".
- Toggle **Mine / Everyone**.
> "Nemotron read every meeting together. It noticed I promised Acme a quote in one
> meeting and admitted it slipped in another, and that Priya already shipped the
> pricing page, so it's not on my list anymore."

## 2:15–2:30 — Close
> "A real app, re-platformed onto NVIDIA Nemotron and Nebius Token Factory, with a new
> private meeting assistant on top. Thanks for watching."

## Record-day checklist
- [ ] Seed the sample meetings (**Try it with sample meetings**, or
      `swift run Freshflo --seed-demo --with-ai` so Nemotron writes the notes and the
      notes show the Nemotron badge).
- [ ] Nebius key added, **Test** passes on camera.
- [ ] Pre-run each chat question once so latency is warm.
- [ ] Mention "NVIDIA Nemotron on Nebius" early and at the end.
