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
- **Next step** *(new)* — one click on a commitment and Nemotron chooses what moves it
  forward by **tool calling**: draft the follow-up email, add a reminder, or research
  what the notes don't say. The draft waits under *Waiting for your approval*;
  approving opens it in Mail or adds it to Reminders. Nothing is sent without you.
- **Research with Tavily** *(new)* — when a commitment needs outside facts, Tavily
  searches the web (only the question leaves the Mac) and Nemotron writes a short
  brief that cites its sources.
- **Your agent keeps your promises** *(new)* — a **Hermes Agent** on Nemotron 3 Ultra
  (Token Factory), optionally sandboxed by **NVIDIA NemoClaw / OpenShell**, reads your
  commitments through Freshflo's MCP server every morning and queues drafts into the
  same approval list. Its only write is `propose_action`.
- **Shows its work** — every note, chat answer, commitment list and draft carries a
  "NVIDIA Nemotron on Nebius Token Factory" badge with the exact model id (and the
  answer's latency), so you can see what produced it.
- **MCP server** — exposes your meetings and commitments to Hermes, Claude and Cursor,
  locally over stdio or over HTTP with a bearer token for sandboxed agents.

## How we built it
- **Native Swift / SwiftUI** macOS app.
- **Nebius Token Factory** as an OpenAI-compatible provider — one new case in the
  `Provider` enum wired the whole AI stack (cleanup, notes, Ask, Command, chat) to
  Nebius with zero other call-site changes.
- **NVIDIA Nemotron** for all reasoning, tiered the way Nebius recommends: **Nemotron
  3 Super** handles the fast, everyday calls (dictation cleanup, grammar, tone) and
  **Nemotron 3 Ultra** handles the serious reasoning (multi-turn meeting chat,
  cross-meeting commitment merging). A resolver queries Token Factory's live `/models`
  catalog and always prefers a Nemotron model, so the app can't silently drift off an
  NVIDIA model when ids change.
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

- **Tool calling that works with any Token Factory setup** — `CommitmentAgent` sends
  OpenAI-style `tools` and reads `tool_calls`, and also parses Nemotron's text form
  (`<TOOLCALL>[…]</TOOLCALL>`) when the endpoint doesn't parse calls itself.
- **Approval by design** — in-app drafts and agent drafts share one `ActionProposal`
  type and one approval list; only an approved draft reaches Mail or Reminders.
- **Agent integration** — new MCP tools `list_commitments` and `propose_action`, and a
  Streamable HTTP transport (`--mcp-http`: bearer token, loopback by default, browser
  origins refused) so a NemoClaw sandbox can reach Freshflo through an HTTPS proxy.
  The Hermes kit (config, `keep-my-promises` skill, daily cron) is in `hackathon/agent/`.
- **Measured, not guessed** — `--commitments-eval` scores merge precision/recall,
  done detection, due dates and latency on 7 labelled scenarios, so Nemotron 3 Super
  and Ultra can be compared on numbers.

## Satisfying the requirements
- ✅ **Runs on Nebius Token Factory** — every LLM call goes to
  `api.tokenfactory.nebius.com`.
- ✅ **Uses an NVIDIA open model** — Nemotron for cleanup, meeting notes, Ask, the
  new chat, commitments and tool calling; enforced by the model resolver, which keeps
  the tier (Ultra stays Ultra) if an id changes.
- ✅ **Personal AI track tools** — persistent memory (meetings on the Mac), reusable
  skills and tool access (Freshflo's MCP tools and the `keep-my-promises` Hermes
  skill), tasks carried out across your day (daily Hermes job), with a kit for
  **Hermes Agent** and **NVIDIA NemoClaw / OpenShell**.

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
- More approved actions: calendar holds and Slack messages from the same approval list.
- Run the agent on Nebius Serverless for people who don't want it on their Mac.

## Try it
See `hackathon/SETUP.md`. `swift build` then pick the Nebius provider in Settings.
No meetings yet? Click **Try it with sample meetings**, or run
`swift run Freshflo --seed-demo`.
