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
   - Fast model (cleanup, everyday dictation): `nvidia/nemotron-3-super-120b-a12b` (Nemotron 3 **Super**)
   - Smart model (chat, notes, commitments, Ask): `nvidia/nemotron-3-ultra-550b-a55b` (Nemotron 3 **Ultra**)

   This follows Nebius' guidance: **Super** handles the fast, everyday calls and
   **Ultra** handles the serious reasoning (multi-turn meeting chat, cross-meeting
   commitment merging). Both are NVIDIA open models on Token Factory.

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

## Next step: Nemotron acts on a commitment (with your approval)

In **Open commitments**, every open item has a **Next step** button. Freshflo sends the commitment, the meeting it
was agreed in (notes plus the transcript lines about it) and any later mentions to Nemotron with three tools:

| Tool | When Nemotron picks it | What approving does |
|------|------------------------|---------------------|
| `draft_email` | The commitment is owed to someone | Opens the draft in Mail; you press Send |
| `add_reminder` | You just have to do it at a certain time | Adds it to Reminders with the due date |
| `research` | It needs facts the notes don't have | Tavily searches the web, Nemotron writes a brief citing [1], [2]… (copy it) |

The draft appears under **Waiting for your approval**. Review edits it; nothing is sent or saved until you approve.
`CommitmentAgent` reads OpenAI-style `tool_calls` and also Nemotron's text form (`<TOOLCALL>[…]</TOOLCALL>`), so it
works whether or not the endpoint parses tool calls.

**Tavily:** add a key in **Settings → Meetings → Agents and research** (or set `TAVILY_API_KEY`). Only the search
question is sent to Tavily. Without a key, the research tool isn't offered.

```bash
swift run Freshflo --next-step "acme quote" --demo      # Nemotron's next step for a sample commitment
swift run Freshflo --research "Stripe annual plan pricing"
```

## Your agent keeps your promises (Hermes Agent + NemoClaw / OpenShell)

Freshflo's MCP server now has `list_commitments` and `propose_action`. A Hermes Agent on Nemotron 3 Ultra (Token
Factory) can read your commitments every morning and queue drafts into the same approval list, labelled with the
agent's name. For sandboxed agents, `Freshflo --mcp-http` serves the same tools over HTTP with a bearer token.
Setup for both paths (on the Mac, or inside an NVIDIA NemoClaw / OpenShell sandbox): [`agent/README.md`](agent/README.md).

## Measuring it: the commitments eval

`Benchmarks/commitments-eval.json` holds 7 hand-labelled scenarios, each aimed at one failure mode: a promise
restated after it slipped, similar items that must stay apart, "done" mentioned in passing, half done (not done),
an owner change, and deadlines the local rules can't date ("by the 20th").

```bash
swift run Freshflo --commitments-eval Benchmarks/commitments-eval.json --runs 3
swift run Freshflo --commitments-eval Benchmarks/commitments-eval.json --runs 3 --smart-model nvidia/nemotron-3-super-120b-a12b
```

It reports merge precision and recall, done / not-done accuracy, due-date accuracy, items lost (always 0 by design)
and latency, so Super and Ultra can be compared on numbers.

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
swift run FreshfloChecks    # 460 logic checks
swift run Freshflo --commitments --demo                                   # organise the sample commitments
swift run Freshflo --ask-meetings "What do I owe Acme?" --demo --stream   # streamed, cited answer
swift run Freshflo --next-step "pricing page" --demo                     # tool-calling next step
FRESHFLO_MCP_TOKEN=test swift run Freshflo --mcp-http                      # MCP over HTTP on 127.0.0.1:8765/mcp
```
