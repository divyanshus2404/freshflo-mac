# Running Freshflo on Nebius Token Factory + NVIDIA Nemotron

This adds a **Nebius Token Factory** provider so all of Freshflo's AI runs on an
**NVIDIA open model (Nemotron)**, served on Nebius' GPU infrastructure — the two
hard requirements for the Nebius x NVIDIA Global AI Hackathon.

## What runs where

| Step | Engine | Where |
|------|--------|-------|
| Speech → text (dictation, meetings) | WhisperKit (on-device) | Your Mac — private, offline, free |
| Cleanup / grammar / tone | **NVIDIA Nemotron** | **Nebius Token Factory** |
| Meeting notes (decisions, action items) | **NVIDIA Nemotron** | **Nebius Token Factory** |
| Chat with your meetings | **NVIDIA Nemotron** | **Nebius Token Factory** |
| Ask / Command / translate | **NVIDIA Nemotron** | **Nebius Token Factory** |

Token Factory serves LLMs, not audio, so transcription stays on-device and only
**text** is sent to the cloud. That keeps the raw audio private and still puts an
NVIDIA model at the center of every intelligent feature.

## One-time setup

1. Create an API key at <https://tokenfactory.nebius.com> (Token Factory → API keys).
2. Launch Freshflo → **Settings → General → Transcription → Engine** and pick
   **"Nebius Token Factory (NVIDIA Nemotron)"**.
3. Paste the key and press **Test** — it should say *Key works*.
4. That's it. Defaults:
   - Base URL: `https://api.tokenfactory.nebius.com/v1`
     (if your account is pinned to a region, use the URL shown in your dashboard,
     e.g. `https://api.tokenfactory.us-central1.nebius.com/v1`)
   - Fast model (cleanup): `nvidia/llama-3.1-nemotron-70b-instruct`
   - Smart model (chat, notes, Ask): `nvidia/nemotron-3-super-120b-a12b`

If a default model id has been retired, Freshflo auto-discovers a replacement from
Token Factory's live `/models` catalog and **prefers any NVIDIA Nemotron model**, so
the app stays on an NVIDIA open model without manual edits
(see `ModelResolver.best`).

## New feature built for the hackathon: Chat with your meetings

The existing one-shot "Ask your meetings" is now a true **multi-turn chat**:
follow-ups like *"and who owns that?"* resolve against the previous answers, every
reply cites the meeting it came from, and retrieval stays 100% local — only the few
most relevant excerpts reach Nemotron. See `Knowledge.converse` and
`AskMeetingsView` in `Sources/FreshfloKit`.

## Build & verify

```bash
swift build            # builds the app + CLI
swift run FreshfloChecks   # 339 logic checks
```
