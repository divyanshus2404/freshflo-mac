# Freshflo — your meetings, answered. On NVIDIA Nemotron + Nebius.

**Tracks:** Personal AI (primary) · Best Apps & Agents

## Elevator pitch
Freshflo is a real, shipping macOS dictation + meeting-notes app. For the hackathon
we moved its entire intelligence layer onto **NVIDIA Nemotron served by Nebius Token
Factory**, and built **Chat with your meetings** — a private, cited, multi-turn
assistant over everything you've ever recorded. Speech stays on your Mac; only the
few most relevant text excerpts reach the cloud.

## Inspiration
Everyone records meetings; nobody re-reads the notes. The value is locked in a pile
of transcripts you never open again. We wanted to turn that pile into something you
can simply *ask* — "what did I commit to last week?", "and when is it due?" — without
shipping your private audio to anyone.

## What it does
- **Dictation & meeting capture** — transcribed on-device with WhisperKit.
- **AI meeting notes** — Nemotron extracts decisions, action items (with owners),
  and open questions.
- **Chat with your meetings** *(new)* — a conversational assistant over all your
  notes. Answers stream in token by token, follow-ups keep context, every answer
  cites the source meeting, and retrieval is local keyword search, so only a handful
  of excerpts ever leave the device.
- **Open commitments** *(new)* — every action item from every meeting in one list.
  Nemotron reads all your meetings together: it merges a commitment restated in a
  later meeting, and marks items done when a later meeting says they shipped
  ("Priya said the pricing page went live [Weekly standup]"). Items are grouped into
  Overdue / Due this week / Later, filtered to *Mine* or *Everyone*, and each one
  links back to the meeting it came from.
- **Shows its work** — every note, chat answer and commitment list carries a
  "NVIDIA Nemotron on Nebius Token Factory" badge with the exact model id (and the
  answer's latency), so you can see what produced it.
- **MCP server** — exposes your meetings to Claude/Cursor read-only, locally.

## How we built it
- **Native Swift / SwiftUI** macOS app.
- **Nebius Token Factory** as an OpenAI-compatible provider — one new case in the
  `Provider` enum wired the whole AI stack (cleanup, notes, Ask, Command, chat) to
  Nebius with zero other call-site changes.
- **NVIDIA Nemotron** for all reasoning. A resolver queries Token Factory's live
  `/models` catalog and always prefers a Nemotron model, so the app can't silently
  drift off an NVIDIA model when ids change.
- **On-device Whisper** for speech — Token Factory serves LLMs, not audio, so we keep
  transcription local, which is also a privacy win.
- **Local RAG** — keyword retrieval + transcript excerpting over meetings stored on
  disk; the model only sees what's relevant to the question.
- **Streaming** — server-sent events from Token Factory's OpenAI-compatible
  `/chat/completions`, with reasoning blocks hidden while they stream. If streaming
  can't start, it falls back to a normal call that still handles rate limits and
  retired models.
- **Hybrid reasoning for commitments** — action items are parsed and deadlines like
  "by next Wednesday" are dated on the Mac, deterministically. Nemotron does what
  rules can't: deciding that two items across meetings are the same commitment, and
  that a later conversation finished one. A malformed reply can merge items or mark
  them done, but never drop one.

## Satisfying the requirements
- ✅ **Runs on Nebius Token Factory** — every LLM call goes to
  `api.tokenfactory.nebius.com`.
- ✅ **Uses an NVIDIA open model** — Nemotron for cleanup, meeting notes, Ask, and the
  new chat; enforced by the model resolver.

## Challenges
- Token Factory is LLM-only, so we split the pipeline: on-device ASR + cloud Nemotron.
- Model ids change; we made the app self-heal by discovering a working Nemotron from
  the live catalog instead of hardcoding one.
- LLMs are bad at calendar math ("by Monday" from a Friday came back as that same
  Friday), so dates are resolved locally and the model only handles judgment calls.

## Accomplishments
- Re-platformed a mature, real-world app onto NVIDIA + Nebius with a tiny, clean diff.
- Shipped two genuinely new, demoable features on top: streaming multi-turn cited
  chat, and cross-meeting commitment tracking.

## What's next
- A weekly digest of open commitments, delivered as a notification.
- Nemotron function-calling to act on items (draft the follow-up email, add the task).

## Try it
See `hackathon/SETUP.md`. `swift build` then pick the Nebius provider in Settings.
No meetings yet? Click **Try it with sample meetings**, or run
`swift run Freshflo --seed-demo`.
