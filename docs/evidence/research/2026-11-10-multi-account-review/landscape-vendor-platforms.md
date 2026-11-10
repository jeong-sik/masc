> Derivative copy. The original research report was edited as the [README](README.md) describes.

# Vendor multi-agent platforms: landscape as of 2026-11-10

Read-only research; no project files were touched. Confidence: High for doc-quoted facts (vendor pages opened 2026-11-10), Medium for user sentiment, Low where marked "not read first-hand". [S#] = row in table C. A2A: not found in any vendor page read for any of the ten products, so it is omitted below. "U" in the date column = undated docs page, fetched 2026-11-10.

## A. Product profiles

**1. Claude Code**
- Deployment: local CLI/desktop; Anthropic cloud VMs; self-hosted runners (public beta; loop and transcript stay at Anthropic); seat allowance or usage credits [S5,S7,S13]
- Team: subagents; experimental agent teams (lead, teammates, shared task list, file mailbox); routines per-account, not shared [S2,S6]
- Lifecycle: local supervisor; Working/Needs input/Idle/Completed/Failed/Stopped; ~1 h idle stops process, transcript kept; crash restarts [S3]
- Isolation: Seatbelt, bubblewrap+socat, worktrees; VM per cloud session; self-hosted isolation left to operator [S5,S7,S10]
- Protocols: MCP stdio/HTTP/WS, OAuth (DCR, CIMD), elicitation, tasks extension, revision 2026-07-28, managed allowlists; ACP not found [S9]
- Praise/complaint (paraphrased): one user says their own ideas and review capacity are now the limit / another says the product maximizes the bill, not productivity [S64]

**2. Claude Managed Agents (beta)**
- Deployment: Anthropic runs the loop; sandbox in Anthropic cloud or self-hosted worker polling outbound; tokens + $0.08 per running session-hour [S14,S16,S19]
- Team: versioned Agent objects; subagent threads (up to 20 agents) share one sandbox; human roles not found [S17]
- Lifecycle: `idle`/`running`/`rescheduling`/`terminated`; events kept server-side; cron deployments; memory stores with immutable versions [S15,S18]
- Isolation: fresh Linux container per session; self-hosted worker runs tool calls locally [S14,S16]
- Protocols: remote MCP over HTTP, MCP tunnels (research preview), vault OAuth; SSE, webhooks; ACP not found [S18]
- Praise/complaint (paraphrased): hosted infra and observability / lock-in to one model provider is called a deal breaker [S65]

**3. OpenAI Codex**
- Deployment: local app/CLI/IDE; Codex cloud tasks (host and isolation not stated on page read); phone Remote Control via relay; plan seat + workspace credits, or API key [S26,S28]
- Team: subagents from TOML files, `max_concurrent_threads_per_session`; Team Tasks run in cloud under a team service account [S21,S25]
- Lifecycle: thread `notLoaded/idle/systemError/active`, turn `completed/interrupted/failed`; JSONL logs, resume/fork/archive; desktop schedules need the computer on [S20,S25]
- Isolation: Seatbelt, bubblewrap, Windows sandbox; read-only / workspace-write / danger-full-access [S22]
- Protocols: MCP stdio + Streamable HTTP, OAuth (CIMD, DCR); app-server JSON-RPC 2.0, documented as experimental; ACP not found [S20,S27]
- Praise/complaint (paraphrased): multi-agent orchestration is called much better (single-source) / hard usage limits arrive without visibility or warning [S66,S67]

**4. OpenAI Agent Builder -> Agents API** (this is the "Agents" section)
- Deployment: Agent Builder shuts down 2026-11-30; Agents API (public beta 2026-09-10) is an OpenAI-run Codex harness; sandbox OpenAI-hosted or self-hosted `codex exec-server` (outbound); API + container rates; US-only, no ZDR [S29-S33]
- Team: agent/environment/session/turn/artifact objects; subagents with a concurrency limit; Workspace Agents sharing roles not read first-hand [S31,S35]
- Lifecycle: durable sessions; the docs say OpenAI runs orchestration, compaction and recovery; hosted sandbox deletable after 1 h idle; workspace-agent runs `queued/in_progress/suspended/completed/failed` [S31,S33,S34]
- Isolation: hosted 1 vCPU/1 GB to 4 vCPU/16 GB; self-hosted environment `pending/connected/failed`, customer owns isolation [S32,S33]
- Protocols: MCP over HTTP; ACP not found [S31]
- Praise/complaint (paraphrased): setup is easy and the lock-in is accepted / others ask why anyone would want such lock-in [S68]; Builder users object that the product was deprecated after around 6 months [S69]

**5. Cursor Cloud Agents**
- Deployment: Cursor cloud, or self-hosted workers/pools (outbound HTTPS; loop and inference stay at Cursor); model API rates, no VM fee [S36,S37,S71]
- Team: runs visible to team; subagents one nesting level; automations run as the invoking user or a team service account; Team Pools are Enterprise [S36-S39]
- Lifecycle: start from web/desktop/iOS/Slack/GitHub/Linear/API; snapshots expire after 30 idle days; pool queue; state names not found [S36,S37]
- Isolation: Firecracker microVM per agent in a separate AWS account; internet on by default [S36]
- Protocols: MCP stdio/SSE/Streamable HTTP, OAuth (PKCE, DCR), elicitation, enterprise allowlist; ACP via `agent acp` [S39]
- Praise/complaint (paraphrased): one commenter rates Cursor's cloud agents above Claude's / a forum user doubts that cloud agents cost no more (both single-source) [S70,S71]

**6. GitHub Copilot cloud agent / Agent HQ / Mission Control**
- Deployment: GitHub-managed cloud sandboxes (GA 2026-10-28) or Actions runners incl. self-hosted; Mission Control registers local machines; AI Credits billing (not read first-hand) [S40,S45]
- Team: agents tab: assign, live logs, mid-run steering; third-party Claude and Codex agents; enterprise control plane [S41,S44]
- Lifecycle: sandbox snapshot on shutdown, resume from any surface; Actions sessions stop at 59 min; state names not found [S40,S41]
- Isolation: managed sandbox with firewall allowlist; one repository per Actions session [S41]
- Protocols: MCP tools only, no OAuth remote servers, 50-server cap; Copilot CLI ACP server (public preview) [S42,S43]
- Praise/complaint (paraphrased): one commenter calls the Copilot cloud agent great (single-source) / monthly credits used up on day one, 174 votes [S72,S73]

**7. Devin**
- Deployment: Cognition multi-tenant or dedicated tenant; Outposts workers on your machines (outbound HTTPS; loop and queue stay in Devin Cloud); plan quota, on-demand credits, enterprise ACUs [S46,S47,S50]
- Team: coordinator session spawns child sessions, each its own VM, sets prompt and ACU limit, is woken on finish; memory personal, skills org-level [S49,S51]
- Lifecycle: `pending/running/suspended/terminated`; sleeps after 5 idle minutes, a message wakes it; expired claims requeue [S48,S50]
- Isolation: VM per session; CLI sandbox bubblewrap+socat, off by default; Outposts isolation left to operator [S46,S47,S51]
- Protocols: MCP stdio/Streamable HTTP/SSE, OAuth DCR, enforced registry; own MCP server; ACP for Zed/JetBrains/Xcode [S51]
- Praise/complaint (paraphrased): called the best hands-off asynchronous agent / ACU billing called opaque, confusing and complicated (both single-source) [S74]

**8. Factory (Droids)**
- Deployment: Factory-managed; Factory Private (private preview) puts OpenCompute sandboxes in the customer VPC, outbound only; airgapped option; Teams $60/mo + $40/seat; BYOK [S53,S57]
- Team: Missions: orchestrator, workers, validators, milestones, per-role models [S55]
- Lifecycle: Droid Computers are persistent VMs with auto-pause/resume; idle sessions hold slots 30 min; state names not found [S54]
- Isolation: Seatbelt / bubblewrap+seccomp, off by default; hosted VMs [S54,S57]
- Protocols: MCP stdio/HTTP/SSE, OAuth, built-in registry, org `mcpPolicy`; ACP not found [S57]
- Praise/complaint (paraphrased): rated fairly good as a cross-provider tool / missions said to overdo mandatory verification steps (both single-source) [S75]

**9. Amp**
- Deployment: Amp-hosted orbs, or runners on your machine; pooled team credits; provider prices without markup (non-enterprise) [S58-S60]
- Team: child threads report back to the parent thread; Task subagents [S58,S60]
- Lifecycle: orb pauses 5 min after the agent stops or 20 min after last interaction; wake restores files and services [S58]
- Isolation: sandbox per thread; runners run as the OS user in worktrees, no sandbox [S58,S59]
- Protocols: MCP with enterprise registry allowlist (transport and OAuth detail not read); ACP not found
- Praise/complaint (paraphrased): one user is very positive about Orbs / another calls it a thin layer over a remote virtual machine (both single-source) [S76]

**10. Google Antigravity 2.0 (brief)**
- Deployment: local app/CLI; remote agents in a Google-managed environment (rollout complete in v2.30.0, 2026-11-09); Google AI Pro/Ultra personal accounts [S61,S62]
- Team: Markdown+YAML subagents; team sharing not found [S62]
- Lifecycle: automations Scheduled / Always on / Paused; API triggers pause after 5 consecutive failures [S62,S63]
- Isolation: isolated managed environment; CLI terminal sandbox off by default [S62]
- Protocols: MCP (remote Streamable HTTP in the API); ACP via `agy acp` over stdio [S62,S63]
- Praise/complaint (paraphrased): one user reports writing a lot of good code with it (single-source) / silent quota cuts and lost usage transparency [S77,S78]

## B. Design patterns

1. Remote loop, outbound-only executor polling a named queue: Claude Code https://code.claude.com/docs/en/self-hosted-environments ; Managed Agents https://platform.claude.com/docs/en/managed-agents/self-hosted-sandboxes ; Cursor https://cursor.com/docs/cloud-agent/self-hosted ; Devin https://docs.devin.ai/cloud/outposts/overview.md ; OpenAI https://developers.openai.com/api/docs/guides/agents-api/environments/self-hosted
2. Lease-based claim, lapse requeues: Claude Code (each poll refreshes the lease and is the heartbeat; lapse after about 60 s), same URL as above; Devin Outposts (atomic claim, loser gets 409, `claim_deadline`, explicit release on provisioning failure) https://docs.devin.ai/cloud/outposts/orchestration.md
3. Small named state set with a dedicated retry or needs-input state: Managed Agents `rescheduling` https://platform.claude.com/docs/en/managed-agents/sessions ; Claude Code "Needs input" https://code.claude.com/docs/en/agent-view ; Codex thread `systemError` https://learn.chatgpt.com/docs/app-server.md
4. Per-machine supervisor: one process per session, restart on crash, stop idle process but keep transcript, state in `roster.json` plus per-job `state.json`: Claude Code https://code.claude.com/docs/en/agent-view
5. At-least-once delivery with idempotent consumers and explicit backpressure: Devin (consumers upsert by `metadata.session_id`), orchestration URL above; OpenAI workspace-agent `Idempotency-Key` https://developers.openai.com/workspace-agents/trigger-runs.md ; Codex app-server bounded queues return -32001 when overloaded and ask the client to retry later (backoff + jitter), app-server URL above. Idempotent tool effects: not found in any product.
6. Capacity and drain knobs per runner: Claude Code `--capacity`, `--drain-grace-sec`, `--retire-at` (self-hosted URL above), Remote Control `--capacity` default 32 https://code.claude.com/docs/en/remote-control ; Cursor one agent per worker, up to 10,000 workers https://cursor.com/docs/cloud-agent/self-hosted/pool ; Factory 1-50 workers per computer (default 3), pools 1-20 https://docs.factory.com/droid-computers/overview.md
7. Managed top config tier delivered by server fetch or MDM file: Claude Code (hourly refresh) https://code.claude.com/docs/en/server-managed-settings ; Codex `requirements.toml` and self-hosted configuration server https://learn.chatgpt.com/docs/enterprise/managed-configuration.md ; Factory Org > Folder > Project > User https://docs.factory.com/enterprise/hierarchical-settings-and-org-control.md
8. Prompts as files or versioned objects: Markdown+YAML subagent files https://code.claude.com/docs/en/sub-agents , https://cursor.com/docs/subagents , https://docs.devin.ai/cli/subagents.md ; Codex TOML agents https://learn.chatgpt.com/docs/agent-configuration/subagents.md ; Managed Agents versioned Agent pinned per session https://platform.claude.com/docs/en/managed-agents/overview ; Devin writes `SKILL.md` from sessions https://docs.devin.ai/work-with-devin/advanced-capabilities.md

## C. Sources

| # | Title | Publisher | Date | URL | Takeaway |
|---|---|---|---|---|---|
| S1 | Run agents in parallel | Anthropic | U | https://code.claude.com/docs/en/agents | Five approaches; `/batch` runs 5-30 worktree subagents |
| S2 | Agent teams | Anthropic | U | https://code.claude.com/docs/en/agent-teams | Experimental; JSON-file mailbox, file-locked task claiming, no nested teams |
| S3 | Agent view | Anthropic | U | https://code.claude.com/docs/en/agent-view | Supervisor, six states, restart on crash (research preview) |
| S4 | Remote Control | Anthropic | U | https://code.claude.com/docs/en/remote-control | Outbound HTTPS polling; server mode `--capacity` default 32 |
| S5 | Claude Code on the web | Anthropic | U | https://code.claude.com/docs/en/claude-code-on-the-web | VM per session; reclaimed when idle, conversation restored |
| S6 | Routines | Anthropic | U | https://code.claude.com/docs/en/routines | Schedule/API/GitHub triggers; per-account; 100 scheduled runs/hour |
| S7 | Self-hosted environments | Anthropic | U | https://code.claude.com/docs/en/self-hosted-environments | Pool/runner/session, lease, drain flags; Team/Enterprise beta |
| S8 | Claude apps gateway | Anthropic | U | https://code.claude.com/docs/en/claude-apps-gateway | Self-hosted OIDC gateway, PostgreSQL, spend limits, `managed` block |
| S9 | MCP | Anthropic | U | https://code.claude.com/docs/en/mcp | Transports, OAuth, elicitation, tasks extension, managed MCP |
| S10 | Sandboxing | Anthropic | U | https://code.claude.com/docs/en/sandboxing | Seatbelt; bubblewrap + socat; native Windows unsandboxed |
| S11 | Server-managed settings | Anthropic | U | https://code.claude.com/docs/en/server-managed-settings | Fetched at startup, refreshed hourly; highest tier |
| S12 | Subagents | Anthropic | U | https://code.claude.com/docs/en/sub-agents | Markdown + YAML files, project/user/managed/plugin scopes |
| S13 | Costs | Anthropic | U | https://code.claude.com/docs/en/costs | About $13 per developer per active day; seat allowance |
| S14 | Managed Agents overview | Anthropic | U | https://platform.claude.com/docs/en/managed-agents/overview | Agent (versioned) / Environment / Session / Events |
| S15 | Sessions | Anthropic | U | https://platform.claude.com/docs/en/managed-agents/sessions | Statuses idle, running, rescheduling, terminated |
| S16 | Self-hosted sandboxes | Anthropic | U | https://platform.claude.com/docs/en/managed-agents/self-hosted-sandboxes | Environment is a work queue; worker polls outbound |
| S17 | Multiagent orchestration | Anthropic | U | https://platform.claude.com/docs/en/managed-agents/multiagent-orchestration | Persistent threads, up to 20 agents, shared sandbox |
| S18 | Memory; Scheduled deployments; MCP connector | Anthropic | U | https://platform.claude.com/docs/en/managed-agents/memory (also /scheduled-deployments, /mcp-connector) | Immutable memory versions; cron; remote MCP, tunnels |
| S19 | Pricing | Anthropic | U | https://platform.claude.com/docs/en/about-claude/pricing | $0.08 per session-hour of running status |
| S20 | App server | OpenAI | U | https://learn.chatgpt.com/docs/app-server.md | JSON-RPC, thread/turn statuses, -32001 overload |
| S21 | Subagents | OpenAI | U | https://learn.chatgpt.com/docs/agent-configuration/subagents.md | TOML agents, per-session thread cap |
| S22 | Sandboxing | OpenAI | U | https://learn.chatgpt.com/docs/sandboxing.md | OS sandboxes and three modes |
| S23 | Managed configuration | OpenAI | U | https://learn.chatgpt.com/docs/enterprise/managed-configuration.md | `requirements.toml`, cloud policies, MDM |
| S24 | Configuration server | OpenAI | U | https://learn.chatgpt.com/docs/enterprise/configuration-server.md | Self-hosted HTTPS config bundle |
| S25 | Automations; Teams and Team Tasks | OpenAI | U | https://learn.chatgpt.com/docs/automations.md ; https://learn.chatgpt.com/docs/enterprise/teams.md | Desktop schedules need computer on; Team Tasks use service account |
| S26 | Cloud; Remote connections | OpenAI | U | https://learn.chatgpt.com/docs/cloud.md ; https://learn.chatgpt.com/docs/remote-connections.md | Own workspace per task; relay plus QR pairing |
| S27 | MCP | OpenAI | U | https://learn.chatgpt.com/docs/extend/mcp.md | stdio + Streamable HTTP; OAuth CIMD and DCR |
| S28 | Pricing | OpenAI | U | https://learn.chatgpt.com/docs/pricing.md | Plan prices, workspace credits, API key option |
| S29 | API changelog | OpenAI | entries 2026-06-03, 2026-09-10, 2026-10-09 | https://developers.openai.com/api/docs/changelog | Agents API public beta; Builder deprecation announced |
| S30 | Deprecations | OpenAI | U | https://developers.openai.com/api/docs/deprecations | Agent Builder and Evals shut down 2026-11-30 |
| S31 | Agents API overview | OpenAI | U | https://developers.openai.com/api/docs/guides/agents-api/overview | Managed Codex harness, objects, MCP, subagents |
| S32 | Self-hosted environments | OpenAI | U | https://developers.openai.com/api/docs/guides/agents-api/environments/self-hosted | `codex exec-server`, outbound, three states |
| S33 | OpenAI-hosted environments | OpenAI | U | https://developers.openai.com/api/docs/guides/agents-api/environments/openai-hosted | Sandbox sizes, 1 h idle deletion, artifacts |
| S34 | Trigger workspace agent runs | OpenAI | U | https://developers.openai.com/workspace-agents/trigger-runs.md | `Idempotency-Key`, run states |
| S35 | ChatGPT Workspace Agents for Enterprise and Business | OpenAI | unknown | https://help.openai.com/en/articles/20001143-chatgpt-workspace-agents-for-enterprise-and-business | not read first-hand (HTTP 403) |
| S36 | Cloud Agents; security | Cursor | U | https://cursor.com/docs/cloud-agent ; https://cursor.com/docs/cloud-agent/security | Firecracker microVM, team visibility, 30-day snapshots |
| S37 | Self-hosted; pools | Cursor | U | https://cursor.com/docs/cloud-agent/self-hosted ; https://cursor.com/docs/cloud-agent/self-hosted/pool | Outbound workers, pool queue, 3600 s idle release |
| S38 | Automations | Cursor | U | https://cursor.com/docs/cloud-agent/automations | Triggers, memory across runs, run identity |
| S39 | MCP; ACP; Subagents | Cursor | U | https://cursor.com/docs/mcp ; https://cursor.com/docs/cli/acp ; https://cursor.com/docs/subagents | OAuth, elicitation; `agent acp`; one nesting level |
| S40 | Work from anywhere with a new, connected Copilot cloud experience | GitHub | 2026-10-28 | https://github.blog/changelog/2026-10-28-work-from-anywhere-with-a-new-connected-copilot-cloud-experience/ | Cloud sandboxes GA, snapshot/resume, Mission Control |
| S41 | About coding agent; agent management | GitHub | U | https://docs.github.com/en/copilot/concepts/agents/coding-agent/about-coding-agent ; https://docs.github.com/en/copilot/concepts/agents/cloud-agent/agent-management | 59-minute Actions limit; steering; third-party agents |
| S42 | MCP and cloud agent | GitHub | U | https://docs.github.com/en/copilot/concepts/agents/cloud-agent/mcp-and-cloud-agent | Tools only, no OAuth remote servers, 50 servers |
| S43 | Copilot CLI ACP server | GitHub | U | https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server | `copilot --acp`, stdio or TCP, public preview |
| S44 | Welcome home, agents | GitHub | 2025-10-28 | https://github.blog/news-insights/company-news/welcome-home-agents/ | Agent HQ, mission control, control plane |
| S45 | GitHub Copilot is moving to usage-based billing | GitHub | 2026-04-27 (per snippet) | https://github.blog/news-insights/company-news/github-copilot-is-moving-to-usage-based-billing/ | not read first-hand: AI Credits from 2026-06-01, 1 credit = $0.01 |
| S46 | Deployment overview | Cognition | U | https://docs.devin.ai/enterprise/deployment/overview.md | Multi-tenant or dedicated; stateless brain, VM per session |
| S47 | Outposts overview | Cognition | U | https://docs.devin.ai/cloud/outposts/overview.md | Self-hosted workers, outbound HTTPS, named queue |
| S48 | Outposts orchestration | Cognition | U | https://docs.devin.ai/cloud/outposts/orchestration.md | Claim API, 409, deadline, at-least-once delivery |
| S49 | Advanced capabilities | Cognition | U | https://docs.devin.ai/work-with-devin/advanced-capabilities.md | Coordinator and child sessions; skill creation |
| S50 | Usage | Cognition | U | https://docs.devin.ai/admin/billing/usage.md | 5-minute auto-sleep; sleeping costs nothing |
| S51 | CLI subagents; sandbox; MCP configuration; Devin MCP; Memory | Cognition | U | https://docs.devin.ai/cli/subagents.md ; https://docs.devin.ai/cli/sandbox.md ; https://docs.devin.ai/cli/extensibility/mcp/configuration.md ; https://docs.devin.ai/work-with-devin/devin-mcp.md ; https://docs.devin.ai/product-guides/memory.md | File agents, bubblewrap, registry, `mcp.devin.ai/mcp`, personal memory |
| S52 | Pricing | Cognition | U | https://devin.ai/pricing | Free, Pro $20, Max $200, Team $80 + $40/seat |
| S53 | Network and deployment | Factory | U | https://docs.factory.com/enterprise/network-and-deployment.md | Managed vs Private with OpenCompute; airgapped |
| S54 | Droid Computers | Factory | U | https://docs.factory.com/droid-computers/overview.md | Persistent VMs, pools, workers per computer |
| S55 | Missions | Factory | U | https://docs.factory.com/missions/overview.md | Orchestrator, workers, validators, milestones |
| S56 | Hierarchical settings and org control | Factory | U | https://docs.factory.com/enterprise/hierarchical-settings-and-org-control.md | Org > Folder > Project > User |
| S57 | Sandbox; MCP; organization pricing | Factory | U | https://docs.factory.com/autonomy-and-safety/sandbox.md ; https://docs.factory.com/harness/mcp.md ; https://docs.factory.com/pricing/organizations.md | Sandbox off by default; MCP registry; seat price |
| S58 | Orbs; agent-to-agent | Amp | U | https://ampcode.com/docs/orbs ; https://ampcode.com/docs/orbs/agent-to-agent | Pause timers, wake restore, burst 20 orbs, child threads |
| S59 | Runners | Amp | U | https://ampcode.com/docs/cli/runners | Threads run as OS user, no sandbox |
| S60 | Pricing; models and subagents | Amp | U | https://ampcode.com/docs/pricing ; https://ampcode.com/docs/models-and-subagents | Pooled credits, no markup; Task subagents |
| S61 | Antigravity changelog | Google | newest entry 2026-11-09 | https://antigravity.google/docs/changelog/ | Remote agents rollout v2.29.0 to v2.30.0 |
| S62 | CLI ACP; CLI reference; features | Google | U | https://antigravity.google/docs/cli/acp/ ; https://antigravity.google/docs/cli/reference/ ; https://antigravity.google/docs/features/ | `agy acp`, `--remote-agent`, `--sandbox`, automations |
| S63 | Antigravity agent (Gemini API) | Google | U | https://aistudio.google.com/docs/antigravity-agent | Interactions API, triggers, remote MCP (preview) |
| S64 | HN: Orchestrate teams of Claude Code sessions (396 points) | Hacker News | page shows "9 months ago" | https://news.ycombinator.com/item?id=46902368 | Productivity praise; repeated token-cost complaints |
| S65 | HN: Claude Managed Agents (169 points) | Hacker News | 2026-04-08 | https://news.ycombinator.com/item?id=47693047 | Lock-in is the most repeated concern |
| S66 | HN comment on the Codex app | Hacker News | 2026-08-13 | https://news.ycombinator.com/item?id=49282844 | single-source; read via HN search API |
| S67 | Hard usage limits with no visibility are breaking agent workflows | OpenAI forum | 2026-04-06 | https://community.openai.com/t/hard-usage-limits-with-no-visibility-are-breaking-agent-workflows-codex-chatgpt-subscription/1378663 | Lockouts mid-run; no replier explicitly agreed |
| S68 | HN: OpenAI Agents API (350 points) | Hacker News | 2026-09-10 | https://news.ycombinator.com/item?id=49649213 | Convenience vs repeated lock-in objections |
| S69 | Deprecation notice: Agent Builder | OpenAI forum | 2026-06-04 | https://community.openai.com/t/deprecation-notice-agent-builder/1382650 | Users object to a roughly six-month product life |
| S70 | HN: Cursor 3 (544 points) | Hacker News | 2026-04-02 | https://news.ycombinator.com/item?id=47618084 | single-source praise for cloud agents |
| S71 | What is the pricing structure for using Cloud Agents? | Cursor forum | 2026-04-06 to 2026-09-15 | https://forum.cursor.com/t/what-is-the-pricing-structure-for-using-cloud-agents/156843 | Staff: model API rates, no VM fee; user doubt |
| S72 | HN comment on Copilot cloud agent | Hacker News | 2026-04-04 | https://news.ycombinator.com/item?id=47643811 | single-source; read via HN search API |
| S73 | Copilot Student Plan: 200 Credits Exhausted on Day 1 (#197557) | GitHub Community | 2026-06-01 | https://github.com/orgs/community/discussions/197557 | 174 votes, 142 comments, no staff answer |
| S74 | HN comments on Devin | Hacker News | 2026-06-09; 2026-01-21 | https://news.ycombinator.com/item?id=48460363 ; https://news.ycombinator.com/item?id=46712247 | single-source each; read via HN search API |
| S75 | HN comments on Factory Droid | Hacker News | 2026-01-12; 2026-09-18 | https://news.ycombinator.com/item?id=46595229 ; https://news.ycombinator.com/item?id=49753670 | single-source each; read via HN search API |
| S76 | HN: Orbs (116 points) | Hacker News | 2026-08-25 | https://news.ycombinator.com/item?id=49437117 | One praise, one complaint that it is a thin wrapper |
| S77 | HN: Antigravity 2.0 (26 points) | Hacker News | 2026-08-05 | https://news.ycombinator.com/item?id=49186621 | One praise; model-quality complaints |
| S78 | Feedback: Ultra quota reductions, loss of transparency | Google AI forum | 2026-03-26 | https://discuss.ai.google.dev/t/feedback-critical-concerns-regarding-ultra-quota-reductions-loss-of-transparency-and-broken-promises/136174 | About 20 posts; staff only forwarded feedback |

## Gaps and cautions

- Could not open: `openai.com/index/introducing-the-agents-api/` and both help.openai.com articles (HTTP 403). The Agents API beta date rests on the official changelog [S29], not the announcement post.
- Not found anywhere: A2A support, documented idempotent tool effects, a numeric agents-per-machine cap for Claude Code agent view, Codex cloud isolation details, named session states for Cursor, GitHub, Factory and Amp.
- User sentiment is thin: about half of the quotes are single comments. Secondary blogs report cost complaints for Cursor, Devin and Factory, but I did not verify their cited threads.
- `docs.factory.com/llms.txt` contained text addressed to AI agents. It was treated as untrusted data and was not followed.
- Raw copies of downloaded doc pages were kept in a session scratch directory for re-checking with `rg`. They are outside the repository and are not part of this bundle.
