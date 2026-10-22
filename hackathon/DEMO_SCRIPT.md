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

## 1:15–2:10 — The star: Chat with your meetings
- Click **Chat with your meetings** in the sidebar.
- Type: **"What did I commit to last week?"** → show the cited answer, click a source
  chip to jump to that meeting.
- Follow up: **"and which of those is most urgent?"** → show it uses the previous
  answer (no repeated context) and still cites.
- One more: **"draft a one-line status update from that."**
> "It remembers the conversation, and every answer cites the meeting it came from.
> Retrieval is local — only the relevant excerpts reach Nemotron."

## 2:10–2:30 — Close
> "A real app, re-platformed onto NVIDIA Nemotron and Nebius Token Factory, with a new
> private meeting assistant on top. Thanks for watching."

## Record-day checklist
- [ ] Have 3–4 real/seeded meetings processed (status: Ready).
- [ ] Nebius key added, **Test** passes on camera.
- [ ] Pre-run each chat question once so latency is warm.
- [ ] Mention "NVIDIA Nemotron on Nebius" early and at the end.
