---
name: keep-my-promises
description: Check the user's open commitments from their Freshflo meeting notes and queue drafts (follow-up emails, reminders, research notes) for their approval.
version: 1.0.0
author: Freshflo
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [Meetings, Commitments, Freshflo, Personal]
    related_skills: []
---

# Keep my promises

Use this skill to make sure nothing the user promised in a meeting slips. Freshflo (a Mac app) keeps the user's meeting notes and an organised list of every commitment across meetings. You read that list, decide what would move each overdue or due-soon commitment forward, and queue a draft for the user to approve in Freshflo. You never send anything yourself.

## Tools

These come from the `freshflo` MCP server:

- `mcp_freshflo_list_commitments`: open commitments grouped Overdue / Due this week / Later / No date, each with a `commitment_id`, owner, due date and source meeting. Default is the user's own items (`owner: "mine"`).
- `mcp_freshflo_get_meeting`: the full notes of a meeting, and the transcript with `include_transcript: true`.
- `mcp_freshflo_search_meetings`: keyword search across all notes.
- `mcp_freshflo_propose_action`: queue a draft for one commitment. `kind` is `email`, `reminder` or `note`. The user reviews it in Freshflo → Open commitments → Waiting for your approval.

If web search is available (Tavily), you may use it for facts the notes don't contain, such as prices or comparisons. Never search for the user's private meeting content.

## Procedure

1. Call `mcp_freshflo_list_commitments`. Work only on **Overdue** and **Due this week** items. Skip anything already done.
2. For each item, call `mcp_freshflo_get_meeting` with its `meeting_id` and read what was agreed: who it is owed to, what exactly was promised, any numbers or dates.
3. Choose the one most useful next step:
   - Owed to someone (send, share, reply, confirm): `propose_action` with `kind: "email"`. Write it from the user: greeting, 2–5 short sentences, sign-off without a name. Put the recipient in `to` only if the notes name them.
   - Just needs doing (prepare, book, review, build): `propose_action` with `kind: "reminder"` and a `due` date (YYYY-MM-DD).
   - Needs outside facts first: research, then `propose_action` with `kind: "note"` holding a short brief with source links.
4. Propose at most one draft per commitment, and at most five per run.
5. Finish with a short summary for the user: what you queued and why, and anything that looked stuck.

## Rules

- Use only facts from the meeting notes and pages you actually read. Never invent names, prices, dates or promises.
- "You" in the notes is the user. Items owned by other people are theirs; don't draft for them unless the user asks.
- Don't repeat a draft you already queued this week for the same commitment.
- Nothing you propose is sent or created until the user approves it in Freshflo. Say so in your summary.
