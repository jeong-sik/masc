> Derivative copy. The original research report was edited as the [README](README.md) describes.

# Agent orchestrators and durable runtimes: profile as of 2026-11-10

**Method and confidence.** Checked 2026-11-10 with WebSearch/WebFetch; no repository files written. Pages were read through WebFetch's summarizing model (only the Anthropic page came back verbatim), and some long pages were cut at 100k characters. Status facts are High confidence; numeric defaults are Medium until checked against raw text. `[NF]` = not read first-hand (search-result summary). `[1S]` = single non-official source. Keys `[n]` point to table D.

**Orca identity.** The parallel coding-agent orchestrator now using this name is `stablyai/orca` (Stably AI) [12].

**Vendor-login rule that shapes every "drive the CLI" design [11].** Anthropic's Claude Code legal page allows a platform to host the unmodified Claude Code binary where each end user signs in with their own subscription or key. It forbids third parties offering Claude.ai login, collecting, storing or intermediating subscription credentials, and paying for or reselling usage. The policy moved in 2026: an HN-reported email ended subscription limits for third-party harnesses from 2026-04-04, and a thread reporting that it was allowed again followed on 2026-04-21 [10]. OpenClaw's doc now recommends API keys for shared automation [9].

**Embedded instructions.** The `gastownhall/gascity` README contains text addressed to AI agents. It was not followed.

## A. Profiles

### Group 1: orchestrators and harnesses

**OpenHands, now "Agent Canvas"** (v1.38.0, 2026-11-10; MIT) [1][2][3]
- deployment: self-hosted npm (`npm i -g @openhands/agent-canvas`) or Docker image; Helm dir; Cloud; Enterprise. TypeScript app, Python SDK and Agent Server.
- team model: OSS is single-tenant (`LOCAL_BACKEND_API_KEY`); orgs, RBAC (Keycloak) and SAML only in Cloud/Enterprise. Built-in agent uses your LLM keys. ACP agents launch the vendor CLI with its subscription login file or `CLAUDE_CODE_OAUTH_TOKEN` / `CODEX_AUTH_JSON`, saved as global secrets.
- lifecycle: SDK writes `base_state.json` plus one file per event; resume with the same `conversation_id`; mid-tool crash handling not documented.
- isolation: none (npm), one container, or a container per conversation (`OH_CONVERSATION_RUNTIME=docker`); remote/VM backends.
- protocols: ACP client for Claude Code, Codex, Gemini CLI, Pi, OpenCode; MCP tools; A2A not found.
- praise / complaints: praise not found first-hand. Complaint: unusable with about 9 chats, dead agent-server not restarted (#16690, open).
- scale: the Enterprise page claims no limit on parallel agent conversations; the issue reporter saw a limiter capped at 3.

**Hermes Agent** (Nous Research; v0.23.1, 2026-11-09/10; MIT; Python; 262k stars) [4][5]
- deployment: self-hosted; `curl …/install.sh | bash`; CLI/TUI plus one gateway process per machine; Desktop and Webapp clients.
- team model: personal agent. Profiles separate state but, per the docs, are not a sandbox; gateway allowlists and pairing; RBAC request open [6]. Auth: API keys; its own OAuth for ChatGPT/Codex (device code), Nous Portal, Qwen, xAI; Anthropic OAuth only for Max with extra-usage credits, or it reads Claude Code's credential store.
- lifecycle: sessions in SQLite `state.db` (FTS5); `MEMORY.md` (2,200 chars) and `USER.md` (1,375 chars) frozen at session start; cron with a missed-run policy; durable Kanban board.
- isolation: terminal backends local, Docker, SSH, Modal, Daytona, Vercel Sandbox; optional worktree per subagent.
- protocols: MCP client (stdio/HTTP, OAuth 2.1, sampling, form elicitation; tasks not mentioned); MCP server plugin; ACP server only.
- praise / complaints (paraphrased): one user is delighted with it as a Telegram homelab sysadmin; another finds it slow and prefers full session logs to `MEMORY.md` summaries [7].
- scale: 10 concurrent subagents by default, depth 1; Kanban tick 60 s, stale claim 4 h, limits unset.

**OpenClaw** (2026.11.2, 2026-11-08; MIT; TypeScript; 394k stars; OpenClaw Foundation) [8][9]
- deployment: self-hosted Gateway daemon; install script or `npm i -g openclaw`; Node 24+.
- team model: personal gateway or one shared by several people; per-agent workspace, state dir and SQLite; the docs say real isolation needs one agent per person. Auth: API keys; ChatGPT/Codex OAuth; Anthropic through a `claude-cli` backend that runs the installed Claude Code executable without reading its tokens, or a setup-token.
- lifecycle: one turn at a time per session; graceful restart resumes marked sessions, a crash leaves the queue inert; heartbeat is now ordinary automation jobs (30 min default).
- isolation: off by default; Docker/Podman/SSH/OpenShell/Crabbox sandboxes for tools; Gateway stays on the host.
- protocols: MCP client (stdio/SSE/streamable HTTP, OAuth) and `openclaw mcp serve`; ACP both ways (acpx harnesses, `openclaw acp` bridge).
- praise / complaints (thread titles only, paraphrased): one title says it delivers what Apple Intelligence was meant to be (518 pts); another calls it a security disaster (397 pts); there is also a privilege-escalation CVE thread [10].
- scale: 8 subagents per spawning session; swarm 32; queue cap 20 per session, overflow summarized.

**Orca** (`stablyai/orca`; v1.4.255, 2026-11-09; MIT; TypeScript; 120.7k stars) [12][13]
- deployment: desktop app (macOS/Windows/Linux, brew cask or AUR); iOS/Android companion; headless `orca serve`; SSH hosts; per-worktree cloud VM (experimental).
- team model: no accounts or roles documented; pairing link, Tailscale suggested. Auth: drives vendor CLIs under the user's own subscription; account switcher; reads local agent state for quota windows.
- lifecycle: a daemon owns the PTYs; warm reattach and scrollback after app close, crash or update; a host reboot ends every agent and the user re-runs them.
- isolation: git worktree per task; optional VM; no sandbox mentioned.
- protocols: its own `orca` CLI plus a skill; experimental orchestration inbox; MCP/ACP/A2A not found.
- praise / complaints (paraphrased): one user reports a very good first week; headless-server install trouble; top request is multi-repo workspaces (#1099, 106 reactions) [14].
- scale: nested worker depth 4 by default; heartbeat 5 min; no worker cap stated.

**Gas Town** (`gastownhall/gastown`; v1.2.1, 2026-06-06; MIT; Go; 18.8k stars) [15]
- deployment: self-hosted CLI `gt` (brew, `go install`, docker compose); needs tmux, Dolt, beads `bd`, git.
- team model: single-user HQ at `~/gt`; federation through DoltHub (a feature named Wasteland). Auth: drives agent CLIs (Claude Code default, 10 other presets); credential handling not documented.
- lifecycle: work stored as beads on git-backed hooks; a rule that an agent must run any work found on its hook; handoff and seance for fresh sessions; Witness/Deacon/Boot patrol chain; daemon heartbeat every 3 min.
- isolation: git worktrees plus tmux; optional Docker container.
- protocols: MCP/ACP/A2A not mentioned; OTLP telemetry. Successor Gas City lists ACP and Kubernetes runtimes [19].
- praise / complaints (paraphrased): a reviewer finds the patterns useful as concepts, the design poor, and the cost in the thousands of dollars a month [18]. The author writes that the project in effect burned down with Opus 4.7 [17]. Maintainers: maintenance mode [16].
- scale: README says 20-30 agents; `scheduler.max_polecats` defaults to -1.

**Conductor** (conductor.build; 0.94.0, 2026-11-09; licence not found) [20][21]
- deployment: macOS desktop app. Joining Meta (2026-11-04); Conductor Cloud read-only 2026-11-13, off 2026-11-20; local app gets models and critical fixes until early 2027.
- team model: team plans invite-only. Auth: reuses the auth tokens already saved on the machine for Claude Code and Codex; optional API keys.
- lifecycle: workspace = branch plus worktree; setup and archive scripts; per-turn checkpoints in private git refs, revert deletes later messages.
- isolation: worktree only; the docs say agents run directly on the user's system with no sandbox.
- protocols: MCP servers in settings; Conductor MCP server for cloud workspaces; ACP not found.
- praise / complaints (paraphrased): one commenter finds it much better than alternatives in their experience; two repos need two sessions [22].
- scale: no limit stated; a port range per workspace.

**Vibe Kanban** (BloopAI; v0.1.44, 2026-04-24; Apache-2.0; Rust) [23][24]
- deployment: local `npx vibe-kanban`; Docker self-host guide. Company shut down 2026-04-10; remote services promised for 30 more days, then fully local; community-maintained.
- team model: local single user once org and project cloud features go. Auth: user logs in to each coding-agent CLI first (10+ CLIs).
- lifecycle: not found.
- isolation: branch/worktree, terminal and dev server per workspace.
- protocols: MCP (`MCP_HOST`, `MCP_PORT`; role unclear); ACP not found.
- praise / complaints (paraphrased): one user calls it excellent; another objects that it collects email addresses and GitHub usernames [25].
- scale: not found.

**claude-squad** (smtg-ai; v1.0.20, 2026-08-20; AGPL-3.0; Go) [26]
- deployment: single binary `cs` (brew or install script); needs tmux and gh.
- team model: single-user TUI. Auth: launches `claude`, `codex`, `aider`, `gemini` as they are.
- lifecycle: tmux session per instance; pause commits and stops, resume restarts; instances reloaded from storage; v1.0.20 recovers after tmux server death.
- isolation: git worktree plus tmux.
- protocols: none found.
- praise / complaints: praise not found (only a maintainer's own comment); two issues ask whether updates have stopped and whether the project is abandoned [27].
- scale: `GlobalInstanceLimit = 10`.

**Coder** (docs v2.39) [28][29][30]
- deployment: self-hosted control plane. Coder Agents GA 2026-09-09; Coder Tasks removed (deprecated v2.34); AgentAPI archived; Mux renamed Xum (AGPL desktop app, own loop, API keys); AI Bridge is now AI Gateway, Agent Boundaries is now Agent Firewall.
- team model: multi-user orgs; system prompts enforced server-side. Auth: admin provider keys encrypted in the DB, optional per-user BYOK; no subscription OAuth (Copilot explicitly unsupported). ACP subagents use the harness's own login inside the workspace.
- lifecycle: agent loop in the control plane; chat state in the Coder DB; `running` / `waiting`; follow-ups queued until the turn ends; crash/HA behaviour not documented.
- isolation: workspaces; Agent Firewall = nsjail/landjail jail plus HTTP allow-list proxy (Premium).
- protocols: MCP client (workspace `.mcp.json`, org servers with OAuth2/OIDC); MCP server (beta); ACP subagents (Early Access).
- praise / complaints: praise not found. Complaint: no idempotency key, retries duplicate chats (#31758) [31].
- scale: 5 active agents on Community/Premium, extras queue; AI Premium is unlimited against an Agent Time pool.

### Group 2: frameworks and durable runtimes

**Letta** (`letta-code`; Apache-2.0; TypeScript) [32][33]
- deployment: `npm i -g @letta-ai/letta-code`; `letta server` App Server or Letta Cloud; the old V1 API server is retired to an `archive` branch.
- team model: App Server takes many clients; users and tasks are the embedding app's job. Auth: Cloud gateway credits, BYOK keys, `/connect` ChatGPT/Codex subscription (device code), Copilot (local only); Anthropic by API key only.
- lifecycle: MemFS git-backed memory; "dreaming" subagents after N steps or compaction; WebSocket `runtime_start` / `sync` replay with `event_seq` and `idempotency_key`; restart recovery not documented.
- isolation: not found in docs read.
- protocols: ACP agent (`letta-acp`); hosted MCP; OpenAI-compatible API.
- praise / complaints (paraphrased): file memory is praised as transparent and under the user's control (commenter possibly affiliated); another says memory does not help much; local MemFS runs a blocking `git show` per file (#5594) [34].
- scale: the docs describe several agents running in parallel inside one process; MemFS 5 MiB free, 50 MiB Pro.

**LangSmith Deployment** (formerly LangGraph Platform; renamed Oct 2025 `[NF]`) [35]
- deployment: Cloud (Plus+); hybrid; self-hosted with control plane (Enterprise, Kubernetes); standalone server (Docker/Helm, Postgres + Redis + licence key).
- team model: custom auth middleware; RBAC not covered in pages read. Vendor auth: not found.
- lifecycle: assistants, threads, runs, crons in Postgres; checkpoint after each step; one run per thread; worker lease and heartbeat, sweeper every 2 min requeues.
- isolation: not found.
- protocols: MCP server at `/mcp` (stateless streamable HTTP, revisions through 2026-07-28, elicitation on pause); A2A v1.0 JSON-RPC at `/a2a/{assistant_id}`.
- praise / complaints: praise not found. Complaint: self-hosted container fails without a licence or LangSmith key (#2937, #2549) [36].
- scale: `N_JOBS_PER_WORKER` = 10; stateless API servers.

**CrewAI** (1.15.39, 2026-11-09; MIT; Python) [37][38]
- deployment: `uv tool install crewai`; AMP cloud; Factory self-hosted by Helm on Kubernetes 1.32+ (Postgres 16.8+, object store, registry; AMD64 only).
- team model: Factory SSO via Entra ID, Auth0, Okta, WorkOS, Keycloak; RBAC `[NF]`. Auth: provider API keys.
- lifecycle: Flows `@persist` (SQLite default), resume by state id; checkpoints on `task_completed` (JSON or SQLite, best-effort writes), resume and fork.
- isolation: not found.
- protocols: A2A client and server (protocol 0.3.0 default); MCP listed.
- praise / complaints: not found in sources dated 2025-09 or later.
- scale: Factory minimum 14Gi, 4 cores, 1 node.

**Temporal** [39][40]
- deployment: Go server; self-host by binaries, Docker Compose (PostgreSQL + Elasticsearch) or Helm; Temporal Cloud.
- team model / vendor auth: not applicable (runtime).
- lifecycle: Event History replay; Signals and Updates for approvals; heartbeating Activities. Integrations GA 2026-10-30 (Google ADK, OpenAI Agents SDK, Strands, LangGraph, Vercel AI SDK, Gemini SDK). Agent Harness (2026-08-20) is described as earlier than public preview.
- isolation: not found.
- protocols: durable MCP server recipe; Nexus gateway for tool calls; A2A not found.
- praise / complaints: praise not found. Complaint: replay needs all of the workflow logic to be deterministic [41].
- scale: 51,200 events or 50 MB per history; 2,000 pending Activities, Signals or children.

**Restate** (v1.8.1-hotfix.2, 2026-11-02; BSL 1.1; Rust) [42][43][44]
- deployment: single binary `restate-server` (brew, npx, Docker) embedding log, RocksDB, Raft metadata and UI; clusters; Restate Cloud.
- team model / vendor auth: not applicable.
- lifecycle: each step appended to the log before proceeding and replayed on retry; Virtual Objects give keyed state with one writer per key; cancel, pause, resume, restart-from-step (1.6, Feb 2026).
- isolation: not found.
- protocols: integrations with Vercel AI SDK, OpenAI Agents SDK, Google ADK, Pydantic AI, LangChain; MCP/A2A not found.
- praise / complaints (paraphrased): the TypeScript SDK is found easy to use; the BSL licence is criticised as not open source [45]; rate-limit and concurrency APIs requested (#3291).
- scale: not found.

**DBOS** [46]
- deployment: library (Python, TypeScript, Go, Java, Rust) plus Postgres (SQLite default for dev); no orchestrator; optional Conductor control plane (self-hosting terms not verified).
- team model / vendor auth: not applicable.
- lifecycle: workflow inputs and step outputs checkpointed; PENDING workflows resume at startup from the last completed step; multi-node recovery through Conductor, which stays off the execution path.
- isolation: not applicable.
- protocols: integrations with Pydantic AI, OpenAI Agents SDK, LlamaIndex, Google ADK, Vercel AI SDK; MCP server for observing workflows.
- praise / complaints (paraphrased): one commenter finds the library form ideal; another sees little added value because Temporal already covers this [47].
- scale (vendor figures): about 1,000 workflows or steps per second per Postgres vCPU; 20K/s on 16 vCPU.

## B. Patterns worth copying

1. **Supervisor in code, not an LLM role (Gas City).** 30 s reconcile of desired `city.toml` agents against running sessions; one-for-one restarts; quarantine after `max_restarts=5` per `restart_window=1h`; counters in memory, reset on controller restart; flock single-controller lock; interrupt, wait 5 s, force stop. https://raw.githubusercontent.com/gastownhall/gascity/main/engdocs/architecture/controller.md and https://raw.githubusercontent.com/gastownhall/gascity/main/engdocs/architecture/health-patrol.md
2. **Durable task board (Hermes Kanban).** SQLite WAL rows; states triage, todo, ready, running, blocked, review, done; 60 s dispatcher with atomic claim; reclaim on dead PID or 4 h without heartbeat; breaker after 2 spawn failures; exit 75 requeues (rate limit), 78 is terminal; idempotency keys on create. https://hermes-agent.nousresearch.com/docs/user-guide/features/kanban
3. **Journal before proceeding, single-writer sessions, one binary (Restate).** Each step is appended to a replicated log first; a Virtual Object per session key queues concurrent messages; operators can cancel, pause, resume or restart from a step. https://docs.restate.dev/references/architecture , https://docs.restate.dev/ai/patterns/sessions , https://restate.dev/blog/a-remote-control-for-your-agents
4. **Lease, heartbeat, sweeper (LangSmith Agent Server).** Durable run queue in Postgres, Redis only ephemeral; a sweeper requeues stale runs every 2 min; 10 runs per worker; SIGINT drains then requeues; API nodes are stateless. https://docs.langchain.com/langsmith/scalability-and-resilience
5. **Queue flow control stored as data (DBOS).** `global_concurrency`, `worker_concurrency`, `limiter{limit, period}`, priority, `deduplication_id` and partition keys live in Postgres and change at runtime. https://docs.dbos.dev/python/tutorials/queue-tutorial
6. **Control-plane loop with bounded concurrency (Coder Agents).** Loop and LLM keys stay in the server; chats, messages and queued input are DB rows; follow-ups wait for the turn to end; 5 active agents, then a queue. https://coder.com/docs/ai-coder/agents/architecture and https://coder.com/docs/ai-coder/agents/licensing-usage
7. **Vendor harness as a file-configured subprocess with its own login (Coder, OpenClaw).** `~/.coder/acp/<id>.json` holds `command`, `display_name`, `enabled`, rescanned every 30 s; OpenClaw runs the installed Claude Code executable and does not read its tokens. https://coder.com/docs/ai-coder/agents/acp-subagents and https://docs.openclaw.ai/providers/anthropic
8. **PTY-owning daemon plus explicit worker protocol (Orca).** The daemon keeps agent PTYs across app close, crash and update; tasks are pending, ready, dispatched, completed, failed or blocked; a worker sends `worker_done` exactly once with its dispatch id; inbox replays until acked. https://www.onorca.dev/docs/model/session-restore and https://www.onorca.dev/docs/cli/orchestration
9. **Per-session inbound-message policy (OpenClaw).** Modes steer, followup, collect, interrupt; cap 20 with summarize-on-overflow; graceful restart gives marked sessions one resume input, a crash leaves queued rows inert. https://docs.openclaw.ai/concepts/queue
10. **Config and prompts as layered files (Gas City, Conductor, Hermes).** `prompts/*.template.md` rendered once at session start with `shared/` partials and `append_fragments`, no role names in code; a versioned config fingerprint (`v7:`) drives drift restarts; `.conductor/settings.toml` (committed), `settings.local.toml`, `~/.conductor/settings.toml`; `MEMORY.md` frozen at session start to keep the prompt cache. https://raw.githubusercontent.com/gastownhall/gascity/main/engdocs/architecture/prompt-templates.md , https://www.conductor.build/llms-full.txt , https://hermes-agent.nousresearch.com/docs/user-guide/features/memory

## C. Gaps none of these fills well

1. **Team accounts with per-user vendor credentials in the open-source tier.** OpenHands keeps orgs, RBAC and SAML for Cloud/Enterprise (https://docs.openhands.dev/enterprise/enterprise-vs-oss). Hermes gateway RBAC has been open since 2026-03-06 (https://github.com/NousResearch/hermes-agent/issues/527). OpenClaw's docs say real isolation needs one agent per person (https://docs.openclaw.ai/concepts/multi-agent).
2. **Quota-aware scheduling and failover across subscription accounts.** Gas Town request open since 2026-01-06 (https://github.com/gastownhall/gastown/issues/232); Restate rate-limit and concurrency APIs open since 2025-05-19 (https://github.com/restatedev/restate/issues/3291).
3. **CLI sessions that survive a host reboot or supervisor crash.** Orca: re-run each agent after a reboot (https://www.onorca.dev/docs/model/session-restore). OpenClaw: the queue is not replayed after a crash (https://docs.openclaw.ai/concepts/queue). OpenHands: a dead agent-server is not restarted (https://github.com/OpenHands/OpenHands/issues/16690).
4. **Retry-safe agent API.** Coder has no idempotency key for creating chats or messages (https://github.com/coder/coder/issues/31758, opened 2026-11-04).
5. **Orchestrating mixed vendor CLIs over ACP.** Hermes' generic ACP client has been undecided since 2026-04-05 (https://github.com/NousResearch/hermes-agent/issues/5257). Coder ACP subagents are Early Access, auto-approve permission requests and do not inherit MCP servers (https://coder.com/docs/ai-coder/agents/acp-subagents).
6. **Default sandboxing and project continuity.** Conductor runs agents with no sandbox and is winding down (https://www.conductor.build/llms-full.txt , https://www.conductor.build/changelog/0.93.0-conductor-is-joining-meta). OpenClaw sandboxing is off by default (https://docs.openclaw.ai/gateway/sandboxing). Vibe Kanban's company closed (https://vibekanban.com/blog/shutdown). AgentAPI is archived (https://github.com/coder/agentapi). claude-squad has issues reporting it as abandoned (https://github.com/smtg-ai/claude-squad/issues/250).

## D. Sources

UD = undated docs page, fetched 2026-11-10.

| # | Title | Publisher | Date | URL | Takeaway |
|---|---|---|---|---|---|
| 1 | OpenHands README, releases, repo API | OpenHands | v1.38.0 2026-11-10 | https://github.com/OpenHands/OpenHands (+ `/releases`) | Product is "Agent Canvas"; npm/Docker installs; ACP agents |
| 2 | OpenHands docs: ACP agents, SDK overview, conversation persistence, Enterprise vs OSS | OpenHands | UD | https://docs.openhands.dev/ + `openhands/usage/agent-canvas/acp-agents`, `sdk/arch/overview`, `sdk/guides/convo-persistence`, `enterprise/enterprise-vs-oss` | CLI credential handling; event-file persistence; RBAC/SAML only paid |
| 3 | Issue #16690 | OpenHands | 2026-08-18 | https://github.com/OpenHands/OpenHands/issues/16690 | Slow with many chats; agent-server death not recovered |
| 4 | Hermes README, releases, repo API | Nous Research | v0.23.1 2026-11-09/10 | https://github.com/NousResearch/hermes-agent (+ `/releases`) | Install script; six terminal backends; one gateway per machine |
| 5 | Hermes docs: providers, delegation, memory, ACP, MCP, Kanban, profiles | Nous Research | UD | https://hermes-agent.nousresearch.com/docs/ + `integrations/providers`, `user-guide/features/{delegation,memory,acp,mcp,kanban}`, `user-guide/profiles` | OAuth matrix; 10 subagents; Kanban recovery rules |
| 6 | Issues #527, #5257 | Nous Research | 2026-03-06, 2026-04-05 | https://github.com/NousResearch/hermes-agent/issues/527 , `/5257` | RBAC and generic ACP client both await a decision |
| 7 | HN "Hermes Agent – Open-source AI agent with persistent memory" | Hacker News | 2026-06-05 | https://news.ycombinator.com/item?id=48419000 | One praise, one complaint quote |
| 8 | OpenClaw README, releases, repo API | OpenClaw Foundation | 2026.11.2, 2026-11-08 | https://github.com/openclaw/openclaw (+ `/releases`) | Foundation-run; gateway daemon; saved Claude CLI accounts |
| 9 | OpenClaw docs: OAuth, Anthropic provider, sandboxing, multi-agent, heartbeat, ACP agents, queue, MCP | OpenClaw | UD | https://docs.openclaw.ai/ + `concepts/oauth`, `providers/anthropic`, `gateway/sandboxing`, `concepts/multi-agent`, `gateway/heartbeat`, `tools/acp-agents`, `concepts/queue`, `cli/mcp` | Spawns official Claude Code; sandbox off by default; queue modes |
| 10 | HN OpenClaw threads (only 47633396 read; others title, date, points) | Hacker News | 2026-02-05 to 2026-04-21 | https://news.ycombinator.com/item?id=47633396 , `47844269`, `47479962`, `47628608`, `46893970` | Subscription ban then reversal; security criticism |
| 11 | Claude Code "Legal and compliance" | Anthropic | UD | https://code.claude.com/docs/en/legal-and-compliance | Unmodified binary plus each user's own login allowed; credential intermediation forbidden |
| 12 | Orca README, releases and repo API | Stably AI | v1.4.255 2026-11-09 | https://github.com/stablyai/orca | Runs under the user's own subscription; desktop, mobile, `orca serve` |
| 13 | Orca docs: session restore, ways to run, usage tracking, orchestration | Stably AI | UD | https://www.onorca.dev/docs/ + `model/session-restore`, `ways-to-run`, `agents/usage-tracking`, `cli/orchestration` | PTY daemon; reboot ends agents; task and worker protocol |
| 14 | Issue #1099; HN comments | GitHub, Hacker News | 2026-04-26; 2026-07-29; 2026-09-08 | https://github.com/stablyai/orca/issues/1099 , https://news.ycombinator.com/item?id=49101564 , `49606598` | Multi-repo request; praise; headless install trouble |
| 15 | Gas Town README, releases API, glossary | gastownhall | v1.2.1 2026-06-06 | https://github.com/gastownhall/gastown (+ `/blob/main/docs/glossary.md`) | Roles, hooks, 20-30 agents claim |
| 16 | Issues #3649, #232 | gastownhall | 2026-04-14; 2026-01-06 | https://github.com/gastownhall/gastown/issues/3649 , `/232` | Maintenance mode; rate-limit-aware swapping still open |
| 17 | "The Shape of Things to Come"; quotation post | Steve Yegge; Simon Willison | Aug 2026; 2026-08-04 | https://yegge.ai/essays/the-shape-of-things-to-come/ , https://simonwillison.net/2026/Aug/4/ | The author says Gas Town in effect burned down; schedulers should watch and models should act |
| 18 | "Gas Town's agent patterns, design bottlenecks, and vibecoding at scale" | Maggie Appleton | early 2026 (HN 2026-01-23) | https://maggieappleton.com/gastown | Useful patterns; poor design; high cost |
| 19 | Gas City README and architecture docs | gastownhall | UD | https://github.com/gastownhall/gascity ; https://raw.githubusercontent.com/gastownhall/gascity/main/engdocs/architecture/ + `controller.md`, `health-patrol.md`, `session.md`, `prompt-templates.md` | Reconciler, quarantine, runtimes, prompt templates |
| 20 | Conductor docs (`llms-full.txt`, first 100k of 385k chars) and checkpoints | Melty Labs | legal pages 2026-11-03 | https://www.conductor.build/llms-full.txt , https://www.conductor.build/docs/reference/checkpoints | Reuses saved tokens; no sandbox; settings layering |
| 21 | Changelog; "Conductor is joining Meta" | Melty Labs | 2026-11-04 | https://www.conductor.build/changelog , `/changelog/0.93.0-conductor-is-joining-meta` | Cloud off 2026-11-20; local fixes until early 2027 |
| 22 | HN comments on Conductor | Hacker News | 2026-06-29; 2026-11-04 | https://news.ycombinator.com/item?id=48715653 , `50367546` | One praise, one complaint |
| 23 | Vibe Kanban README, repo and releases API | BloopAI | v0.1.44 2026-04-24 | https://github.com/BloopAI/vibe-kanban | Sunsetting notice; not archived |
| 24 | Shutdown announcement | BloopAI | 2026-04-10 | https://vibekanban.com/blog/shutdown | Company closed; project community-maintained |
| 25 | Show HN thread; issue #3396 | Hacker News, GitHub | 2025-07-11; 2026-04-26 | https://news.ycombinator.com/item?id=44533004 , https://github.com/BloopAI/vibe-kanban/issues/3396 | Praise; telemetry complaint (pre-2025-09) |
| 26 | claude-squad README, releases API, `app/app.go` | smtg-ai | v1.0.20 2026-08-20 | https://github.com/smtg-ai/claude-squad , https://raw.githubusercontent.com/smtg-ai/claude-squad/main/app/app.go | tmux + worktree; cap of 10 instances |
| 27 | Issues #214, #250 | smtg-ai | 2025-09-24; 2026-02-12 | https://github.com/smtg-ai/claude-squad/issues/214 , `/250` | Abandonment complaints |
| 28 | Coder docs v2.39, AI section | Coder | UD | https://coder.com/docs/ai-coder + `/agents`, `/agents/architecture`, `/agents/tasks-to-chats-migration`, `/agents/acp-subagents`, `/agents/licensing-usage`, `/agents/models`, `/agents/bring-your-own-mcp-servers`, `/ai-gateway`, `/agent-firewall` | Loop in control plane; Tasks removed; 5-agent limit; BYOK |
| 29 | AgentAPI README; Xum README and providers doc | Coder | UD | https://github.com/coder/agentapi , https://github.com/coder/xum , https://xum.cdr.dev/config/providers | AgentAPI archived; Mux renamed Xum; API-key auth |
| 30 | "Coder Agents is now generally available"; InfoQ article | Coder; InfoQ | 2026-09-09; 2026-05-11 | https://coder.com/blog/coder-agents-ga , https://infoq.com/news/2026/05/coder-agents-self-hosted-ai | GA date; no independent criticism reported |
| 31 | Issue #31758 | Coder | 2026-11-04 | https://github.com/coder/coder/issues/31758 | No idempotency key on the chats API |
| 32 | `letta-ai/letta` README; `letta-code` repo API | Letta | UD | https://github.com/letta-ai/letta , https://github.com/letta-ai/letta-code | Source moved to `letta-code`; V1 server retired |
| 33 | Letta docs: overview, memory, App Server, protocol lifecycle, models, ACP | Letta | UD | https://docs.letta.com/ + `letta-code`, `letta-code/memory`, `self-hosting/app-server`, `self-hosting/app-server/protocol-lifecycle`, `configuration/models`, `platform/acp` | MemFS; `/ws` protocol; Codex subscription login |
| 34 | Issue #5594; HN "Letta Code" | GitHub, Hacker News | 2026-11-09; 2025-12-16 | https://github.com/letta-ai/letta-code/issues/5594 , https://news.ycombinator.com/item?id=46294274 | MemFS blocking reads; memory scepticism |
| 35 | LangSmith Deployment docs | LangChain | UD | https://docs.langchain.com/langsmith/ + `deployments`, `agent-server`, `scalability-and-resilience`, `server-mcp`, `server-a2a`, `deploy-standalone-server` | Postgres + Redis; sweeper; `/mcp` and `/a2a` |
| 36 | Issues #2937, #2549 | LangChain | 2025-01-06; 2024-11-27 | https://github.com/langchain-ai/langgraph/issues/2937 , `/2549` | Licence-key friction (older than 2025-09) |
| 37 | crewAI README and releases API | CrewAI | 1.15.39 2026-11-09 | https://github.com/crewAIInc/crewAI | Crews and Flows; AMP Suite |
| 38 | CrewAI docs: flows, checkpointing, A2A; Factory requirements | CrewAI | UD | https://docs.crewai.com/en/concepts/flows , `/en/concepts/checkpointing` , `/en/learn/a2a-agent-delegation` , https://enterprise-docs.crewai.com/installation/requirements | `@persist`; checkpoint limits; Kubernetes sizing |
| 39 | Temporal docs: AI, cookbook, self-hosted deployment, workflow limits | Temporal | UD | https://docs.temporal.io/ai , `/ai-cookbook` , `/self-hosted-guide/deployment` , `/workflow-execution/limits` | Go server; history and pending limits |
| 40 | Framework integrations post; Agent Harness post | Temporal | 2026-10-30; 2026-08-20 | https://temporal.io/blog/ai-framework-integrations , https://temporal.io/blog/temporal-agent-harness-durable-agent-infrastructure | Integrations GA; harness pre-preview |
| 41 | Show HN: Waymark | Hacker News | 2026-11-05 | https://news.ycombinator.com/item?id=50379221 | Determinism and versioning complaints `[1S]` |
| 42 | Restate docs: AI, durable agents, sessions, remote agents, architecture | Restate | UD | https://docs.restate.dev/ai/ , `/ai/patterns/durable-agents` , `/ai/patterns/sessions` , `/ai/patterns/remote-agents` , `/references/architecture` | Journal, Virtual Objects, single binary |
| 43 | "A remote control for your agents" | Restate | 2026-02-13 | https://restate.dev/blog/a-remote-control-for-your-agents | Pause, resume, restart-from-step in 1.6 |
| 44 | Repo API, LICENSE, releases API, issue #3291 | Restate | v1.8.1-hotfix.2 2026-11-02 | https://github.com/restatedev/restate , https://raw.githubusercontent.com/restatedev/restate/main/LICENSE , https://github.com/restatedev/restate/issues/3291 | Rust; BSL 1.1; rate-limit APIs requested |
| 45 | HN comments on Restate | Hacker News | 2025-12-19; 2026-03-02 | https://news.ycombinator.com/item?id=46328302 , `47220099` | SDK praise; BSL complaint |
| 46 | DBOS docs: home, AI quickstart, architecture, queues, Conductor | DBOS | UD | https://docs.dbos.dev/ , `/ai/ai-quickstart` , `/architecture` , `/python/tutorials/queue-tutorial` , `/conductor/overview` | Library on Postgres; queue controls; throughput figures |
| 47 | "Dbos: Durable Workflow Orchestration with Go and PostgreSQL" | Hacker News | 2025-09-29 | https://news.ycombinator.com/item?id=45412938 | One praise, one sceptical quote |
| 48 | Not read first-hand | various | see takeaway | https://coder.com/blog/secure-agentic-ai-now-production-ready ; https://steve-yegge.medium.com/gas-town-from-clown-show-to-v1-0-c239d9a407ec ; https://docs.openhands.dev/sdk/guides/llm-subscriptions ; https://docs.crewai.com/en/enterprise/features/sso ; https://siliconangle.com/2026/11/04/meta-acquires-ai-coding-startup-conductor-whose-app-runs-several-coding-agents-at-once/ | `[NF]` AI Bridge/Boundaries GA Feb 2026 and April 2026 rename; Gas Town v1.0 (2026-04-03), Gas City (2026-04-24); LangSmith rename Oct 2025; Temporal OpenAI Agents SDK GA 2026-03-23; OpenHands SDK `subscription_login()`; CrewAI RBAC; Meta deal press |
