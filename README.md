# MASC

[![OCaml](https://img.shields.io/badge/OCaml-5.5-orange.svg)](https://ocaml.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[한국어](README.ko.md)

MASC (Multi-Agent Shared Context) is a workspace that several coding agents can
share. It runs on your own machine, holds the goals, tasks, ownership, board
posts, and execution evidence for one project in a `.masc/` directory, and
serves that state over MCP so any MCP client can join it.

The problem it addresses is that two agents in the same repository each keep
their own memory. They re-decide the same question, claim the same file, and
neither can see what the other already tried. MASC moves that state out of the
agents and into one place both of them read and write.

A **Keeper** is an optional long-running agent that MASC starts and supervises.
Keepers pick up tasks, run shell commands, edit files, and post what they did
back to the workspace. They are an advanced path; MASC works as a plain MCP
collaboration server without any of them.

> **Status:** MASC is a pre-1.0 project for local, trusted environments. It is
> not a production service or a security boundary. Gate, HITL, and Docker
> execution can constrain specific operations, but they do not protect an
> unattended agent from every unsafe action. `main` moves fast and can be well
> ahead of the latest published binary release.

## The terminal is the front door

Typing `masc` on a terminal opens the TUI. It reads `.masc/` from disk, talks to
the server for everything that only exists over HTTP, and starts that server
itself when nothing is answering the port — so one word gets you a running
workspace. The same workspace also answers to MCP clients and to a web
dashboard; all three read and write the same state.

Away from a terminal the same `masc` is the server it has always been: a pipe,
a unit file, a container, or a CI step has no TTY and gets the server. `masc
start` is the explicit spelling when you want the server regardless.

| Surface | Use it for | How you get it |
|---|---|---|
| **TUI** | Watching and steering Keepers, answering the Gate, reading tool calls as trees, browsing code, diffs, blame, and memory | `masc` on a terminal, or `masc-tui` by name |
| **MCP** | Your own agent joins the workspace: claim a task, post to the board, record evidence | Any MCP client over `http://127.0.0.1:8935/mcp` |
| **Dashboard** | The same state in a browser, for when a terminal is not at hand | Served at `/dashboard/` by the same process |

![MASC terminal UI](docs/screenshots/tui/2026-09-04/surfaces/01-overview.png)

Keeper names and the base path in this frame were replaced with stand-ins of
the same width; the [surface inventory](docs/screenshots/tui/2026-09-04/surfaces/README.md)
holds four more and the capture metadata. The [Terminal UI](#terminal-ui)
section below lists every surface and the keys that reach it.

## Start here

### Local source checkout

Install the OCaml dependencies once, then run the workspace server. The default
quickstart does not start Keepers and does not require a model-provider key.

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc

scripts/opam-pin-external-deps.sh --install
opam install . --deps-only
./quickstart.sh

BASE_PATH="${MASC_QUICKSTART_HOME:-$HOME/masc-quickstart}"
source "$BASE_PATH/.masc/config/mcp-client.env"
curl http://127.0.0.1:8935/health
```

Defaults:

- runtime state: `~/masc-quickstart/.masc`
- HTTP port: `8935`
- dashboard: `http://127.0.0.1:8935/dashboard/`
- MCP endpoint: `http://127.0.0.1:8935/mcp`
- Keeper preset: none
- runtime: the current `[runtime].default` in `config/runtime.toml`
- MCP bearer exports: `~/masc-quickstart/.masc/config/mcp-client.env`

Use `./quickstart.sh --help` for `--base-path`, `--team`, `--port`,
`--no-open`, and `--no-start`.

To start the `classic` Keeper preset, provide its model key on the first run:

```bash
export OLLAMA_CLOUD_API_KEY=...
./quickstart.sh --team classic
```

The exact compiler and Dune versions are defined in `dune-project`. The first
source run builds the OCaml server and dashboard and can take several minutes.

### Published binaries

Published releases can lag behind `main`. Choose a tag from
[GitHub Releases](https://github.com/jeong-sik/masc/releases), then use the
installer from that same tag. Keeping the script and assets on one tag avoids
mixing a newer installer contract with older release files.

```bash
TAG=vX.Y.Z
curl -fsSL "https://raw.githubusercontent.com/jeong-sik/masc/${TAG}/scripts/install.sh" \
  -o /tmp/masc-install.sh
less /tmp/masc-install.sh
bash /tmp/masc-install.sh --version "$TAG"
```

Installation behavior is versioned with the selected tag. Recent release
scripts verify `SHA256SUMS` when it is present and stop when required files are
absent. Supported platforms are the assets attached to that release. Follow
the login and start commands printed by the installer. The login command mints
a worker bearer for the MCP client; the endpoint does not accept an
unauthenticated client by default.

A release carries the server binary, the terminal UI, and the deployment
preflight helpers. The installer puts `masc-tui` next to `masc` and prints the
command that starts it.

### First-run setup

After placing the binaries the installer runs a one-time setup wizard (skip it
with `--no-wizard`). It reports what it detects on this host before writing
anything, and the only files it writes are `.masc/config/.env.local` (one
provider key) and `[runtime].default` in `runtime.toml`.

Two axes are reported. The **model source** is where turns get their tokens:

- A cloud provider (Anthropic, OpenAI, GLM, DeepSeek, …) is offered against its
  API-key environment variable. Pass `--provider <id>` to select one without
  prompting, and `--api-key` or `--api-key-stdin` to supply the key.
- A local server (Ollama, llama-server, MLX) is curled at its healthcheck path
  and shown `reachable` or `not running`, so a server that is not up is visible
  before it is chosen.
- A subscription CLI (Claude Code, Codex, Antigravity) is reached through that
  CLI's own login, so it needs no key. It is shown `installed` once its command
  is on `PATH`, and `signed in` when its own login check passes.

The **execution sandbox** is where a Keeper's tools run. The wizard only reports
which backends the host can offer — `docker` (daemon reachable), `microvm` (a
guest behind a hypervisor; see below for which runtime provides it), and
`remote_ssh` (endpoints declared in `runtime.toml`). It does not pick one on its
own: the sandbox is set per Keeper in `.masc/config/keepers/<name>.toml`, or by a
`--team <preset>` that carries its own choice — pass
`--sandbox docker|microvm|remote_ssh` to set the seeded team's.

`microvm` says a Keeper's tree lives on a guest behind a hypervisor boundary. It
does not say which runtime provides that guest; `microvm_backend` in the Keeper
TOML does, and RFC-0405 holds the comparison. Omit it and the host's assumed
backend applies — Apple's `container` on macOS, nothing elsewhere, so a Keeper on
another host is refused at boot rather than quietly given a different isolation.

| `microvm_backend` | CLI | State, measured 2026-09-04 on macOS 26.6.1 |
|---|---|---|
| `apple_container` | `container` | Runs. The assumed backend on macOS. |
| `microsandbox` | `msb` | Wired, does not boot. `msb list --format json` reports only `{created_at, image, name, status}` and echoes no label values, so the sweep cannot tell which guests are its own; the Keeper stops at `microvm_container_listing_failed`. `msb inspect` does carry the labels, one call per guest. |
| `nerdctl_kata` | `nerdctl` | Untested here — the CLI is absent, and an absent CLI is refused by name rather than substituted. |

A backend whose CLI is missing is refused at boot. That refusal is the point: a
Keeper that asked for a microVM never silently receives a shared kernel.

The subscription sign-in check is also a standalone command:
`masc runtime-probe <runtime_id>` exits `0` when the CLI is signed in and `1`
when it is not, reusing the server's login probe instead of reading credential
files.

### What a finished install still does not have

The install ends with a workspace that serves MCP and a dashboard. Four things
it deliberately does not do, each of which is a step you take next.

**No Keeper exists.** The config seed writes runtime settings, prompts, tool
definitions and connector declarations, and leaves `config/keepers/` empty. A
roster is per workspace, so neither the installer nor the server invents one.
Create the first from the TUI's Keepers surface, or with `masc keeper-create`
against a running server. `--team <preset>` at install time seeds one instead.

**The Docker sandbox image is not built.** A Keeper on `sandbox_profile =
"docker"` runs in `masc-keeper-sandbox:local`, which is built locally and is
published to no registry. Without it every turn stops at
`docker_preflight_failed`. From a source checkout:

```bash
scripts/build-keeper-sandbox-image.sh
```

There is no host arm — the profiles are `docker`, `microvm` and `remote_ssh`
only — so a host with no Docker, no `container`, and no SSH endpoint can run
the workspace but cannot run a Keeper.

**The provider key is not in the server's environment.** The wizard writes it
to `.masc/config/.env.local`, and nothing reads that file for you: `source` it
in the shell that starts the server. This is easy to miss on the TUI path,
because the server the TUI starts with `s` inherits the TUI's environment — so
source the file before launching the TUI, not after.

**Most of the seeded model catalog is not dispatchable.** The catalog ships 31
provider/model bindings as documented examples; the 13 that declare
`max-request-body-bytes` can take a Keeper turn and the rest are named in a
startup warning that says exactly which key to add. `[runtime].default` is one
of the 13.

## Terminal UI

A release install puts `masc-tui` on `PATH` next to `masc`; from a source
checkout it is one Dune target.

```bash
dune build --root . bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path /path/to/project
```

`.masc` must sit directly below the path you pass. `--base-path` falls back to
`MASC_BASE_PATH` and then the current directory. `dune install` or an opam
install puts the same program on `PATH` as `masc-tui`.

When no server is answering on the port, the Keepers surface offers `s` to
start one here: it launches the sibling `masc` binary as a child process,
waits for `/health`, and stops that server again when the TUI exits. A server
that was already running is left alone. This is the path a fresh install takes:
type `masc`, press `s`, and the workspace is up.

### Surfaces

`Tab` and `Shift-Tab` rotate through the ring below, in this order, and the
active surface is highlighted in a strip on the top row. Child surfaces open
from their parent with the key in parentheses, and every one of them is also
a `go <name>` entry in the `:` palette.

| Surface | Shows | Children |
|---|---|---|
| Overview | Workspace summary, the task backlog, and what needs attention | |
| Activity | Every Keeper's tool calls, turn boundaries, and settlements as they land, newest first; `f` cycles the scope | `l` System Logs, the server's own log ring |
| Keepers | The roster, plus per-Keeper chat, logs, tool calls, runtime, sandbox status and container logs, and the names of the secrets it holds | `f` Changes, one Keeper's recorded file writes; `Enter` detail, whose tabs (`[`/`]`) hold Info, the effective prompt, GitHub identity, Channels, Automation, and Runs |
| Memory | Memory OS health per Keeper | `Enter` the fact browser over both stores, `c` cycles the category |
| Approvals | The Gate queue, the standing always-allow rules, and the questions Keepers are waiting on | |
| Board | Posts from people, agents, automation, and the system | |
| Planning | Goals and plans | `v` walks Task Review, Verdicts, Schedules, and Fusion |
| Workspace | Registered repositories; `d` shows a repository's working-tree changes | `Enter` Code, a lazy file browser over the selected checkout |
| Runtime | Runtime lanes, ordered candidates, and provider reachability | `p` walks keeper lanes, all runtimes, and the standalone Lanes |
| Config | `runtime.toml` as the server reads it (`e` edits it in `$EDITOR`), typed params, prompts, and themes | `s` Resources, the MCP resource catalog; `t` Tools, the registered tool catalog with its receipts and usage |

Above the input row, one line on every surface names the next scheduled wake
and whichever Keeper is stopped waiting on a person. It is absent when there is
neither.

### Keys that work everywhere

| Key | Effect |
|---|---|
| `?` | Help: every binding, grouped by surface |
| `:` | Command palette: `go <surface>`, `keeper <name>`, `settings` |
| `/` | Search: the Keeper roster, the Code tree, and the request tab of a chat |
| `r` | Force refresh |
| `q` twice | Quit |

### Talking to a Keeper

The input row at the bottom sends a message to the Keeper it names. `/task
<title>` creates a task through `masc_add_task` and hands the Keeper its id in
the same message; `/help` lists the other slash commands, which cover switching
the pane to another Keeper, stopping or interrupting a streaming turn, and
staging an image to send. A Keeper that asked a question through `masc_ask` is
answered from the same row, which is what the line above the composer is
pointing at.

A chat shows each tool call as a tree: the call's JSON arrives as structure,
labels in one tree share a column, each part of the payload has its own colour,
and a result's string documents unfold in place. The context inspector beside
the chat says what went into each turn and, on its request tab, what the
provider answered and where each item stands.

### Reading code

On the Code surface, `Enter` opens a file, `d` shows its working-tree diff
against HEAD, `H` lists the commits that touched it, `b` puts `git blame` in the
margin, `m` shows the notes anchored to it, and `K`/`D` ask the language server
for hover text or the definition under the cursor. Changes, the Keeper's own
file writes, opens the same viewer with `v`.

MASC ships no language server. It starts the one the project's language names
and expects that program on `PATH`; an absent one answers `Command_not_found`
rather than a guess.

| Language | Program | Project marker |
|---|---|---|
| OCaml | `ocamllsp` | `dune-project`, `dune-workspace` |
| TypeScript | `typescript-language-server` | `tsconfig.json`, `package.json` |
| JavaScript | `typescript-language-server` | `jsconfig.json`, `package.json` |
| Python | `pylsp` | `pyproject.toml`, `setup.py`, `setup.cfg` |
| Rust | `rust-analyzer` | `Cargo.toml` |
| Go | `gopls` | `go.mod` |

The same servers back the Keeper's `keeper_code_query` tool, so a Keeper asked
about a language whose server is missing falls back to reading text. For OCaml,
`references` also needs `dune build @ocaml-index`; without it the answer names
that command rather than returning a short list. The other five declare no
index precondition this client checks.

### When the server is not there

The header says when the TUI and the server disagree about which workspace
they are on: `[workspace mismatch]` beside the connection badge, with both
paths in the footer. Reads that would mix the two are refused while it is up;
everything the server answers still draws.

Without a server the Keeper roster, per-Keeper detail, and the task backlog
still read from disk. Approvals, Board, Planning, Runtime, Memory, the logs,
and messaging need the server, and say so rather than showing an empty list;
a count of `0` next to `data unreliable` means the read failed.

The TUI needs an interactive TTY and a terminal other than `dumb`. Full key
tables, per-surface behavior, themes, and troubleshooting are in
[`docs/TUI-GUIDE.md`](docs/TUI-GUIDE.md).

## MCP client setup

The one-step path is `masc mcp-config`: it mints a bearer and prints a ready
config block for your client, so you paste one block instead of assembling the
URL, token, and header by hand.

```bash
masc mcp-config --base-path /path/to/project --client codex
masc mcp-config --base-path /path/to/project --client claude-desktop
masc mcp-config --base-path /path/to/project --client env   # shell exports
```

It mints a long-lived worker token (pass `--expiring` for a session-scoped one)
and embeds the endpoint, token, and header for the chosen client. The manual
pieces below are the same shapes, for wiring a client the command does not cover.

HTTP is the public MCP path. First load the worker bearer created by
`quickstart.sh`:

```bash
BASE_PATH="${MASC_QUICKSTART_HOME:-$HOME/masc-quickstart}"
source "$BASE_PATH/.masc/config/mcp-client.env"
```

For clients that support a bearer-token environment variable (e.g. Codex or custom scripts):

```toml
[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
bearer_token_env_var = "MASC_TOKEN"
http_headers = { "Accept" = "application/json, text/event-stream" }
```

For Claude Desktop (`claude_desktop_config.json`) using `mcp-remote`:

```json
{
  "mcpServers": {
    "masc": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://127.0.0.1:8935/mcp"],
      "env": {
        "MASC_TOKEN": "paste-your-token-from-mcp-client.env"
      }
    }
  }
}
```

### Multi-agent collaboration flow

When multiple agents connect to the same workspace, they coordinate through tasks, claims, and verified transitions:

```text
# 1. Agent A joins and claims a task
masc_start(path="/path/to/project", task_title="Fix auth token refresh")
masc_transition(task_id="task-001", action="claim")

# 2. Agent B connects, inspects active state, and takes distinct work
masc_start(path="/path/to/project")
masc_status()  # Sees task-001 is claimed by Agent A
masc_add_task(title="Write integration test for auth flow")
masc_transition(task_id="task-002", action="claim")

# 3. Agent A completes work with verifiable evidence
masc_transition(
  task_id="task-001",
  action="submit_for_verification",
  handoff_context={
    "summary": "Token refresh tests passing",
    "evidence_refs": ["artifact:tests/auth_test.log"]
  }
)
```

### Goals and autonomous verification (RFC-0387)

Goals represent shared team intent across all agents (there is no single `owner`):

- **Creation**: Creating a Goal strictly requires measurable success criteria: `metric` and `target_value` (e.g. `masc_goal_upsert(title="Improve test coverage", metric="coverage", target_value=">=85%")`).
- **Autonomous Verification**: Goals transition through `Executing -> Verifying -> Completed`. Calling `masc_goal_transition(goal_id=..., action="request_complete")` routes through the `verifier_exact` autonomous LLM judge, which validates task evidence and commits the final verdict.

The tool set grows, so ask the server you are on rather than trusting a static number — `tools/list` over the session answers it. A 2026-08-26 build answered with 43 workspace tools.

URL-only configuration fails with `401 Unauthorized` under the default local
auth policy. For other client formats, a direct initialize probe, and manual
bearer creation, see [`docs/MCP-TEMPLATE.md`](docs/MCP-TEMPLATE.md). Admin-only
dashboard operations are covered by
[`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md).

## Current scope

| Area | Current use | Important limit |
|---|---|---|
| Workspace collaboration | Share Goals, Tasks, claims, transitions, board posts, and verification evidence through MCP | Coordination data does not provide transactional protection for concurrent source edits |
| Keepers | Run configured agents that react to workspace events and write execution records | Advanced path; behavior depends on the selected runtime and Keeper configuration |
| Terminal UI | The operator front door: watch Keepers, answer the Gate queue, message a Keeper, read tool calls and memory, browse repository files, diffs, and blame | Needs an interactive TTY; the surface set changes often on `main` |
| Dashboard | The same workspace and runtime state in a browser, with operator actions | Availability and write access depend on the built SPA and auth mode |
| Gate and HITL | Apply Always Allow, model judgment, or human approval to supported external effects | Authorization workflow, not a sandbox or credential boundary |
| Runtime routing | Assign a provider/model runtime to each Keeper and define ordered runtime lanes | A valid catalog and provider credentials are still required |
| Fusion | Run panel and judge workflows through `masc_fusion` | Presets and judge runtimes must be configured before use |
| Connectors | Connect workspace activity to Discord, iMessage, Slack and Telegram. Discord, iMessage and Slack run in-process; Telegram still goes through a sidecar | Tokens and channel-to-Keeper bindings are explicit operator configuration |
| Sandboxes | Run Keeper shell work under `docker`, `microvm` (the guest owns its working tree; `microvm_backend` names the runtime), or `remote_ssh` | A Keeper with no accepted profile does not run; none of the three is a complete security boundary. Of the three microVM backends only `apple_container` is known to boot — see the table under First-run setup |
| IDE | Inspect the experimental in-dashboard collaboration shell | Not the supported front door for normal work |

The product front door is repo workspace collaboration, and the terminal UI is
the operator's front door onto it; the dashboard shows the same state in a
browser. Remote-safe operation, cluster deployment,
and production service guarantees are outside the current promise. See
[`docs/PRODUCT-OPERATING-PLAN.md`](docs/PRODUCT-OPERATING-PLAN.md).

## Configuration

MASC resolves runtime data below `<base-path>/.masc`. Authored configuration is
under `<base-path>/.masc/config` unless `MASC_CONFIG_DIR` explicitly selects a
different config root.

| Path | Purpose |
|---|---|
| `runtime.toml` | Provider/model catalog, required `[runtime].default`, runtime lanes, and Keeper assignments |
| `config/tools/*.toml` | Declarative schemas for 130+ MASC tools (workspace, board, tasks, goals, keeper control) |
| `agent-core-models-overlay.toml` | Optional deployment-specific model capability rows; the embedded Agent Core catalog is used when the file is absent |
| `keepers/<name>.toml` | Everything one Keeper needs: operational settings, prompt instructions, and tool postures in `[keeper.tools]` |
| `repositories.toml` | Registered repository identity and checkout metadata for repository workflows |
| `keeper_repo_mappings.toml` | Keeper-to-repository preferences; these are defaults, not an authorization boundary |
| `.env.local` | Provider environment variables written by current installer and quickstart flows |

One directory below the same root is authored rather than generated:

| Path | Purpose |
|---|---|
| `<base-path>/.masc/skills/<name>/SKILL.md` | A capability a Keeper can be handed by name. `name` in the frontmatter has to equal the directory name, because a task names a skill by that directory |

A Keeper is one authored file, `<base-path>/.masc/config/keepers/reviewer.toml`:

```toml
[keeper]
autoboot_enabled = true
proactive_enabled = true
sandbox_profile = "docker"
mention_targets = ["operator"]

[keeper.tools]
native = "read"  # "none" | "read" | "full" (Auto mode safely degrades to read)

instructions = """
You are the review Keeper. Inspect the current change and report concrete
evidence with file paths and commands.
"""
```

Unknown Keeper TOML keys are rejected. `sandbox_profile` accepts `docker`,
`microvm`, or `remote_ssh`; there is no host profile, and a Keeper declared
without an accepted one is refused rather than run on the host. A `microvm`
Keeper may add `microvm_backend = "apple_container" | "microsandbox" |
"nerdctl_kata"`; omitted, the host's assumed backend applies. A `remote_ssh`
Keeper must add `remote_endpoint = "<name>"` naming a table under
`[exec.ssh.endpoints]` in `runtime.toml`.

`network_mode` accepts `none`, `inherit`, or `policy`. `policy` is the mode
between the other two: the guest reaches an allowlist proxy this server owns
and nothing else, so a Keeper that needs one host stops being given every
host. What it may reach is declared under `[egress.keepers.<name>]` in
`runtime.toml` and parsed when that file is read, so a rule the matcher and a
resolver could read differently fails the load rather than sitting in a live
allowlist. The lane is carried today only by the `apple_container` microVM
backend; every other backend refuses it and names what has to be measured
first. See the [egress runbook](docs/operations/egress-policy-runbook.md).

### Keeper event-driven lifecycle

When a Keeper runs in the background, it follows an event-driven reactive loop:

1. **Stimulus Intake**: Wakes immediately when stimulated by `@keeper` board mentions, scheduled timers, or unassigned backlog tasks.
2. **Turn Execution**: Executes shell commands and file edits under strict context budgets (autonomous thought CoT is excluded from replay checkpoints per RFC-0385 to prevent context bloating).
3. **Durable Gate**: External service mutations (e.g. Jira, GitHub, Slack) are routed through durable Gate approval queues.
4. **Evidence Persistence**: Commits execution records and tool artifacts into `<base-path>/.masc/` before returning to idle.

Runtime assignment belongs in `runtime.toml`:

```toml
[runtime.assignments]
reviewer = "<provider>.<model>"
```

Use [`docs/KEEPER-FILE-MODEL.md`](docs/KEEPER-FILE-MODEL.md) for the complete
file contract, and [`docs/ENV-CONTRACT.md`](docs/ENV-CONTRACT.md) for the
environment variables the runtime reads. Use the `masc_config` tool or
`/api/v1/dashboard/config` to inspect the resolved configuration.

## Run modes

| Command | Use |
|---|---|
| `masc start --base-path <path>` | Start an installed binary; `masc` with no subcommand is equivalent |
| `./start-masc.sh --http --base-path <path>` | Start the full source-checkout runtime |
| `scripts/start-loopback.sh` | Start on `127.0.0.1:8935` with Keeper bootstrap disabled unless explicitly enabled |
| `scripts/run-local.sh --target-dir <path>` | Start an isolated development runtime with a path-derived port |

`masc` also carries `init`, `login`, `runtime-default-set`,
`runtime-wizard-catalog`, `schedule-prune`, and `keeper-github` for the setup
and identity steps those names describe.

Always inspect the effective runtime root before editing state:

```bash
curl -fsS 'http://127.0.0.1:8935/health?full=1' \
  | jq '.paths | {effective_base_path, effective_masc_root, roots_diverge}'
```

Runtime-owned files outside `.masc/config/` are not configuration inputs. Do
not edit Keeper snapshots, task stores, board logs, receipts, or approval
history by hand.

## Dashboard

The same server exposes a web view at `/dashboard/`. It reads the state the
terminal UI reads; reach for it when a browser is handier than a terminal, or
for the screens that only exist there (the IDE shell, the Lab diagnostics).
Navigation is defined in `dashboard/src/config/navigation.ts`.

![MASC dashboard overview](docs/screenshots/dashboard/2026-09-04/01-overview.png)

This image was captured from a live local runtime with operational identifiers
redacted. The [dashboard inventory](docs/screenshots/dashboard/2026-09-04/README.md)
contains 24 screens and the exact capture metadata.

Primary sidebar screens:

| Screen | Purpose |
|---|---|
| Overview | Workspace and runtime summary |
| Keepers | Keeper roster, conversation, and context |
| Registry | Keeper declarations and runtime bindings |
| Monitor | Fleet, tool, runtime, and observation views |
| Work | Goals, plans, repositories, and verification |
| Gate | Human approval queue and Always rules |
| Schedule | Scheduled work and wake signals |
| Board | Human, agent, automation, and system posts |
| Fusion | Panel and judge runs |
| Logs | Runtime event log |
| IDE | Experimental collaboration shell |
| Connectors | External channel status and bindings |
| Settings | Operator configuration views |

Visible second-level sections:

| Screen | Sections |
|---|---|
| Monitor | `agents`, `internal-agents`, `fleet-health`, `runtime`, `observatory`, `skills` |
| Work | `work`, `planning`, `repositories`, `verification` |
| Connectors | `connector-status` |
| IDE | `ide-shell` |
| Lab | `tools`, `harness`, `performance`, `keeper-memory-health` |

`Lab` and `Command` are addressable but are not pinned to the primary sidebar.
Hidden diagnostics are not part of the visible navigation contract.

Route examples required by the current dashboard contract:
`dashboard#monitoring?section=journey`,
`dashboard#command?section=operations`,
`dashboard#connectors?section=connector-status`, and
`dashboard#workspace?section=verification`. `journey` is a hidden diagnostic.

See the [24-screen inventory](docs/screenshots/dashboard/2026-09-04/README.md)
for the captured primary, Monitor, Work, and Lab views.

## Repository layout

```text
masc/
├── bin/          server, CLI, and terminal UI entry points
├── lib/          workspace, Keeper, runtime, Gate, and server code
├── packages/     embedded Agent Core package
├── dashboard/    TypeScript and Preact dashboard source
├── assets/       built web assets
├── config/       default configuration seeds
├── docs/         runbooks, contracts, specs, and historical RFCs
├── scripts/      build, install, validation, and local operations
└── test/         OCaml tests and fixtures
```

## Documentation

| Document | Use |
|---|---|
| [`docs/MCP-TEMPLATE.md`](docs/MCP-TEMPLATE.md) | MCP client configuration |
| [`docs/TUI-GUIDE.md`](docs/TUI-GUIDE.md) | Terminal UI surfaces, keys, and troubleshooting |
| [`docs/PROMPT-MAP.md`](docs/PROMPT-MAP.md) | Which prompt file each reader gets, and where it lands on the wire |
| [`docs/KEEPER-USER-MANUAL.md`](docs/KEEPER-USER-MANUAL.md) | Configuring, starting, and watching Keepers |
| [`docs/KEEPER-IDENTITY-MANUAL.md`](docs/KEEPER-IDENTITY-MANUAL.md) | Attaching Jira, Notion, Google and 51 other services to a Keeper |
| [`docs/KEEPER-FILE-MODEL.md`](docs/KEEPER-FILE-MODEL.md) | Current Keeper file and runtime assignment contract |
| [`docs/SKILLS.md`](docs/SKILLS.md) | Declaring a capability in `SKILL.md` and handing it to a Keeper |
| [`docs/ENV-CONTRACT.md`](docs/ENV-CONTRACT.md) | Environment variables the runtime reads |
| [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | Local bearer and dashboard write access |
| [`docs/operations/ssh-endpoints-runbook.md`](docs/operations/ssh-endpoints-runbook.md) | Provisioning a `remote_ssh` endpoint with `masc-exec-ssh-bootstrap`, migrating a Keeper onto it, and every preflight failure code |
| [`docs/operations/egress-policy-runbook.md`](docs/operations/egress-policy-runbook.md) | Declaring what a Keeper in `network_mode = "policy"` may reach, which backends carry the lane, and reading the egress events |
| [`docs/AGENT-CORE-BOUNDARY.md`](docs/AGENT-CORE-BOUNDARY.md) | Responsibility split between MASC and embedded Agent Core |
| [`docs/spec/SPEC-INDEX.md`](docs/spec/SPEC-INDEX.md) | Specification index; inventory counts inside it are historical unless marked current |
| [`docs/RELEASE-EVIDENCE.md`](docs/RELEASE-EVIDENCE.md) | Release evidence format; verify its version header before reuse |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Build, test, and pull-request workflow |
| [`ROADMAP.md`](ROADMAP.md) | Current planning view, not a release promise |

## Development and release status

- The package version is defined in `dune-project` and generated into
  `masc.opam`.
- `CHANGELOG.md` records the source release line.
- [GitHub Releases](https://github.com/jeong-sik/masc/releases) is the source of
  truth for published binaries and their assets.
- APIs and configuration may change before 1.0.

## License

MIT. See [`LICENSE`](LICENSE).
