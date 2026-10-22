# Your agent keeps your promises: Hermes + NemoClaw + Freshflo

Freshflo remembers what you promised in meetings. A **Hermes Agent** running on **NVIDIA Nemotron 3 Ultra on Nebius Token Factory** reads those commitments every morning and drafts what moves each one forward: the follow-up email, a reminder, a research note. Every draft waits in Freshflo for your approval. Nothing is sent without you.

```
 Your Mac                                                           Nebius Token Factory
 ┌───────────────────────────────┐   MCP (stdio or HTTPS+token)   ┌──────────────────────┐
 │ Freshflo                      │ ◀────────────────────────────▶ │ Hermes Agent         │──▶ NVIDIA Nemotron 3 Ultra
 │  meetings, commitments        │   list_commitments             │  skill: keep-my-     │
 │  "Waiting for your approval"  │   get_meeting                  │  promises, daily cron│──▶ Tavily (optional)
 │  you approve → Mail/Reminders │   propose_action (queue only)  │  (optionally in a    │
 └───────────────────────────────┘                                │  NemoClaw/OpenShell  │
   audio never leaves the Mac                                     │  sandbox)            │
                                                                  └──────────────────────┘
```

What the agent can do, and what it can't:

| Can | Can't |
|---|---|
| Read meeting notes and the organised commitments list | Read what you dictate (the tool is filtered out) |
| Queue a draft email, reminder or note | Send email, create reminders, or change notes |
| Search the web with Tavily, if you enable it | See your audio: it never leaves the Mac |

## Freshflo's MCP tools

| Tool | What it does |
|---|---|
| `list_commitments` | Open commitments grouped Overdue / Due this week / Later / No date, each with a `commitment_id`, owner, due date and source meeting. Uses the list Nemotron organised in the app (duplicates merged, finished items marked done). |
| `get_meeting`, `search_meetings`, `list_meetings` | Meeting notes and transcripts. |
| `propose_action` | Queues an `email`, `reminder` or `note` for one commitment. Marked non-destructive: it only adds to Freshflo's approval list. |

## Path A: Hermes on your Mac (simplest)

Status: config keys checked against the Hermes Agent docs and source (`nebius-token-factory` provider, `mcp_servers`, skills, cron). Run it once with your own key before you rely on it.

1. Install Hermes: `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`
2. Add your Token Factory key to `~/.hermes/.env`:
   ```
   NEBIUS_API_KEY=...
   ```
3. Merge [`hermes-config.yaml`](hermes-config.yaml) into `~/.hermes/config.yaml`. It selects the `nebius-token-factory` provider with Nemotron 3 Ultra and starts Freshflo as an MCP server. Freshflo can copy this block for you: Settings → Meetings → Agents and research → Hermes Agent → Copy config.
4. Install the skill: `cp -R skills/keep-my-promises ~/.hermes/skills/`
5. Try it: `hermes chat`, then `/keep-my-promises`.
6. Run it every weekday morning:
   ```bash
   hermes cron create "30 8 * * 1-5" "Check my open commitments and queue drafts for anything overdue or due this week" --skill keep-my-promises
   ```

Open Freshflo → Meeting Notes → **Open commitments**. The agent's drafts appear under **Waiting for your approval**, labelled with the agent's name. Review, edit, approve or dismiss each one.

Optional web research: add `TAVILY_API_KEY` to `~/.hermes/.env` and turn on Tavily web search in `hermes tools`.

## Path B: Hermes inside an NVIDIA NemoClaw / OpenShell sandbox

This runs the same agent in OpenShell's sandbox. Network egress is denied by default, credentials are injected at the gateway (the agent never holds them), and you can deny tools at the MCP proxy.

Status: commands taken from the NemoClaw documentation (alpha). Not yet run end to end with Freshflo. NemoClaw supports macOS on Apple Silicon with Docker Desktop or Colima.

1. **Serve Freshflo's MCP over HTTP** on loopback, with a token:
   ```bash
   export FRESHFLO_MCP_TOKEN="$(openssl rand -hex 32)"
   /Applications/Freshflo.app/Contents/MacOS/Freshflo --mcp-http --port 8765
   ```
   Freshflo refuses to listen beyond loopback without a token, rejects requests with a foreign browser `Origin`, and checks `Authorization: Bearer …` on every request.
2. **Put HTTPS in front of it** on your Mac's private IP. NemoClaw rejects loopback MCP URLs. Edit the IP in [`nemoclaw/Caddyfile`](nemoclaw/Caddyfile), then:
   ```bash
   caddy run --config nemoclaw/Caddyfile
   ```
   Limit the listener with the macOS firewall if you're on a shared network.
3. **Install NemoClaw with Hermes**, trusting Caddy's local CA:
   ```bash
   export NEMOCLAW_CORPORATE_CA_BUNDLE="$HOME/Library/Application Support/Caddy/pki/authorities/local/root.crt"
   curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_AGENT=hermes NEMOCLAW_SANDBOX_NAME=promises bash -s -- --defer-onboarding
   ```
4. **Onboard with Nemotron on Token Factory** as an OpenAI-compatible endpoint:
   ```bash
   NEMOCLAW_PROVIDER=custom \
     NEMOCLAW_ENDPOINT_URL=https://api.tokenfactory.nebius.com/v1 \
     NEMOCLAW_MODEL=nvidia/nemotron-3-ultra-550b-a55b \
     COMPATIBLE_API_KEY="$NEBIUS_API_KEY" \
     nemohermes onboard --non-interactive
   ```
   Use the exact id from `curl -s https://api.tokenfactory.nebius.com/v1/models -H "Authorization: Bearer $NEBIUS_API_KEY"`. Run `nemohermes onboard` without `--non-interactive` instead if you also want to enable Tavily (it prompts for `TAVILY_API_KEY`).
5. **Register Freshflo's MCP endpoint**, denying the dictation-history tool at the proxy:
   ```bash
   nemohermes promises mcp add freshflo \
     --url https://192.168.1.20/mcp \
     --env FRESHFLO_MCP_TOKEN \
     --trusted-private-host 192.168.1.20 \
     --deny-tool search_dictations
   nemohermes promises mcp status freshflo
   ```
   OpenShell stores the token and adds it at egress; the sandbox only sees a placeholder.
6. **Add the skill and schedule** inside the sandbox (`nemohermes promises connect`), as in Path A steps 4–6.

## Why this design

- **Approval, not autonomy.** The agent's only write is `propose_action`. Sending email or creating reminders happens in Freshflo, on the Mac, after you click Approve.
- **Least privilege.** Hermes is given notes and commitments, not dictation history. In Path B, OpenShell also enforces that at the MCP proxy, and egress is limited to Token Factory, Freshflo and (if enabled) Tavily.
- **One model family end to end.** Nemotron organises the commitments in the app, and Nemotron powers the agent that acts on them.
