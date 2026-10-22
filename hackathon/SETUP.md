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
| Chat with your meetings (streamed) | **NVIDIA Nemotron** | **Nebius Token Factory** |
| Open commitments (merge, done-detection) | **NVIDIA Nemotron** | **Nebius Token Factory** |
| Due dates ("by next Wednesday") | Deterministic rules | Your Mac |
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

## Also built for the hackathon

- **Open commitments** (sidebar of Meeting Notes): every action item across every
  meeting, merged and dated, with items a later meeting finished marked done. See
  `Commitments.swift` and `CommitmentsView.swift`.
- **Streaming chat**: answers arrive token by token (`Cleanup.chatStream`).
- **Model badge**: notes, answers and commitments show "NVIDIA Nemotron on Nebius
  Token Factory" plus the exact model id (`ModelCredit.swift`).

## Demo data

Four connected sample meetings (pricing → customer call → standup → hiring) whose
commitments carry across meetings: one finished later, one overdue, one restated.

```bash
swift run Freshflo --seed-demo            # add them (written notes included)
swift run Freshflo --seed-demo --with-ai  # same, but Nemotron rewrites the notes from the transcripts
swift run Freshflo --remove-demo          # take them out again
```

The app's empty Meeting Notes window also has a **Try it with sample meetings** link.
Note: `swift run` reads the CLI's own settings, not the app's. Set the Nebius key for
the CLI too, or use the in-app link so the app's settings are used.

## Build & verify

```bash
swift build                 # builds the app + CLI
swift run FreshfloChecks    # 379 logic checks
swift run Freshflo --commitments --demo                                   # organise the sample commitments
swift run Freshflo --ask-meetings "What do I owe Acme?" --demo --stream   # streamed, cited answer
```
