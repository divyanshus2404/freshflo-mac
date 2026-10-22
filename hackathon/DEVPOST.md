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
  notes. Follow-ups keep context; every answer cites the source meeting; retrieval is
  local keyword search, so only a handful of excerpts ever leave the device.
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

## Satisfying the requirements
- ✅ **Runs on Nebius Token Factory** — every LLM call goes to
  `api.tokenfactory.nebius.com`.
- ✅ **Uses an NVIDIA open model** — Nemotron for cleanup, meeting notes, Ask, and the
  new chat; enforced by the model resolver.

## Challenges
- Token Factory is LLM-only, so we split the pipeline: on-device ASR + cloud Nemotron.
- Model ids change; we made the app self-heal by discovering a working Nemotron from
  the live catalog instead of hardcoding one.

## Accomplishments
- Re-platformed a mature, real-world app onto NVIDIA + Nebius with a tiny, clean diff.
- Shipped a genuinely new, demoable feature (multi-turn cited chat) on top.

## What's next
- Weekly cross-meeting digests (open action items across every meeting).
- Nemotron function-calling to act on items (draft the follow-up email, add the task).

## Try it
See `hackathon/SETUP.md`. `swift build` then pick the Nebius provider in Settings.
