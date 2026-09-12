# MASC

[![OCaml](https://img.shields.io/badge/OCaml-5.5-orange.svg)](https://ocaml.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[한국어](README.ko.md)

MASC (Multi-Agent Shared Context) is a harness for running several coding
agents against one repository. It is one OCaml binary that runs on your own
machine. It keeps a project's goals, tasks, claims, board posts, approvals, and
execution records in a `.masc/` directory, serves that state over MCP so any
MCP client can join, and shows all of it in a terminal UI.

**Development direction:** carry a requested change through verification, recover
from interruptions by checking what was already applied, and preserve those
properties as concurrent work grows. The [reliable-change roadmap](docs/RELIABLE-CHANGE-ROADMAP.md)
sets measurable Goals and separates existing capabilities from guarantees still
to be demonstrated.

Three things it does:

- **Shared state for agents.** Two agents in the same checkout otherwise keep
  separate memories: they re-decide the same question, claim the same file,
  and cannot see what the other tried. MASC moves that state into one place
  both of them read and write.
- **Supervised long-running agents.** A *Keeper* is an agent the server starts
  and supervises. It runs turns inside a sandbox, edits files, and posts what
  it did. A call that leaves the workspace (Jira, GitHub, Slack, ...) passes a
  Gate that a person or a model answers.
- **A terminal front door.** `masc` on a terminal opens the TUI: the Keeper
  roster, their chats and tool calls, the approval queue, the board, plans,
  repositories, diffs, and the server's own logs. The TUI starts the server
  when nothing is on the port.

> **Status.** Pre-1.0, for local, trusted environments. Not a production
> service and not a security boundary: the Gate and the sandboxes constrain
> specific operations, but they do not protect an unattended agent from every
> unsafe action. The installation contract targets 0.35.5; check
> [GitHub Releases](https://github.com/jeong-sik/masc/releases) for available binaries.

![MASC terminal UI](docs/screenshots/tui/2026-09-04/surfaces/01-overview.png)

Keeper names and the base path in the capture were replaced with stand-ins of
the same width. [Four more captures](docs/screenshots/tui/2026-09-04/surfaces/README.md)
and the capture metadata are in the same directory.

## Surfaces

| Surface | What it is for | How you reach it |
|---|---|---|
| **TUI** | Watch and steer Keepers, answer the Gate, read tool calls, browse code, diffs, blame, and memory | `masc` on a terminal, or `masc-tui` by name |
| **MCP** | Your own agent joins the workspace: claims a task, posts to the board, records evidence | Any MCP client at `http://127.0.0.1:8935/mcp` with a bearer |
| **Dashboard** | The same state in a browser | `/dashboard/` on the same server; the 0.35.5 installer includes a binary-matched bundle |

All three read and write the same `.masc/`. New operator work lands in the
TUI. The dashboard is kept building and truthful, but it is not where the
product grows (see [Dashboard](#dashboard)).

## Start here

### First conversation: 0.35.5

First sign in to your model CLI or export its API credential, and start Docker.
In the installer, use **↑/↓, Space and Enter** to select one or more models, then
choose imp's primary connection and fallback order. The wizard checks each model's
response and tool use before saving. Context limits come from the connection's
metadata; an unknown limit offers reselection or an advanced field. Z.AI uses
`ZAI_API_KEY`. Then start imp:

```bash
masc setup --base-path "$HOME/masc-workspace"
```

Setup prepares the default image, starts the workspace server and `imp`, and opens
the TUI. Ask `imp` to reply, create a Board post and Task, list its sandbox directory,
and say “Use WebFetch to retrieve https://example.com now and report the HTTP status and title.” Follow the [first-conversation steps](docs/INSTALL.md#first-conversation-with-imp-0352).
Check [GitHub Releases](https://github.com/jeong-sik/masc/releases) for binary availability.

### Published binaries

Download the installer attached to [GitHub Releases](https://github.com/jeong-sik/masc/releases/tag/v0.35.14).
It verifies and installs the assets for the selected release.

> Installation target: v0.35.14 (check tag availability on GitHub Releases).

```bash
TAG=v0.35.14
curl -fsSL "https://github.com/jeong-sik/masc/releases/download/${TAG}/install.sh" \
  -o /tmp/masc-install.sh
bash /tmp/masc-install.sh --version "$TAG"
```

Optional inspection: run `less /tmp/masc-install.sh` before installation. Press `q` to exit, then run the `bash` installation command above.

For a reinstall, append `--force` or `--wizard` to the `bash /tmp/masc-install.sh` command. The separate `export PATH=...` command takes no installer options.

The installer requires and verifies `SHA256SUMS`, installs the release executables,
and runs a one-time wizard (`--no-wizard` skips it). The 0.35.5 wizard
offers multiple model connections with arrow keys and checkboxes. It verifies each
selected model with a real response and harmless tool call, then binds imp to the
selected primary and fallback order while preserving other connections.
It asks for API credential variable names, never their secret values; the server
reads those variables from its startup environment. `--provider <id>` selects
an existing provider without prompting. For the default `imp`, `masc setup`
prepares the Docker image after you install and start Docker.

Release **0.35.5** includes Intel macOS, `masc-browser-host`, and the matched
dashboard, and preserves configuration during `--force` reinstalls.
The macOS installer includes its Python and shared libraries, so MASC does not require Homebrew. Apple Silicon requires macOS 14 or later; Intel requires macOS 15 or later.


### From source

Install Git, opam, a native C toolchain, Node.js 22 and Corepack first. Native
libraries and the reproducible build steps are listed in the
[Release workflow](.github/workflows/release.yml). The dashboard build below
is required for browser access from a checkout. Coding agents use CI builds
according to [the repository execution protocol](docs/constitution.xml).

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc
opam init --bare
opam switch create . ocaml-base-compiler.5.5.1
eval "$(opam env)"
scripts/opam-pin-external-deps.sh
opam install . --deps-only
opam exec -- dune build bin/main_eio.exe bin/masc_tui.exe
corepack enable
corepack prepare pnpm@10.31.0 --activate
(cd dashboard && pnpm install --frozen-lockfile)
scripts/build-dashboard-if-needed.sh --force
```

The compiler and Dune versions are pinned in `dune-project`. The first build
takes several minutes. Dune leaves the two programs at
`_build/default/bin/main_eio.exe` (server and CLI) and
`_build/default/bin/masc_tui.exe` (TUI). `masc` finds the TUI by the name
`masc-tui` next to itself or on `PATH`, so a bare checkout serves instead of
opening the TUI until the binaries get their installed names:

```bash
mkdir -p ~/.local/bin
ln -sf "$PWD/_build/default/bin/main_eio.exe" ~/.local/bin/masc
ln -sf "$PWD/_build/default/bin/masc_tui.exe" ~/.local/bin/masc-tui
```

`./quickstart.sh` seeds a workspace under `~/masc-quickstart`, starts the
server, and writes an MCP bearer to `.masc/config/mcp-client.env`. It starts
no Keeper and needs no provider key. `--team classic` seeds a Keeper preset
and then needs `OLLAMA_CLOUD_API_KEY` in the shell.

## Run

| Command | What happens |
|---|---|
| `masc` | On an interactive terminal: opens the TUI, starting the server first when nothing answers the port. Anywhere else (a pipe, a unit file, a container, CI): runs the server |
| `masc start --base-path <dir>` | Runs the server regardless of the terminal |
| `masc-tui --base-path <dir>` | Opens the TUI by name |
| `masc setup --base-path <dir>` | Prepares Docker, starts the existing `imp`, and opens the TUI (0.35.5) |
| `masc init --base-path <dir>` | Seeds `.masc/config/` from the assets embedded in the binary, including one Keeper, `imp`, with `activation_mode = "manual"` |

`--base-path` is the directory that holds `.masc`, not `.masc` itself. It
falls back to `MASC_BASE_PATH`, then the current directory. Runtime state
lives under `<base-path>/.masc`; authored configuration under
`<base-path>/.masc/config`.

Other subcommands: `login`, `mcp-config`, and `token` for bearers;
`keeper-create` and `keeper-github` for Keepers; `sandbox-image` for the
default sandbox image; `runtime-default-set`, `runtime-probe`, and
`runtime-wizard-catalog` for the model runtime; `schedule-prune`;
`build-commit`. `masc <command> --help` documents each one.

A running server answers `curl http://127.0.0.1:8935/health`. Before touching
state by hand, check which root the server actually uses:

```bash
curl -fsS 'http://127.0.0.1:8935/health?full=1' \
  | jq '.paths | {effective_base_path, effective_masc_root, roots_diverge}'
```

Apart from `config/` and `skills/`, files under `.masc/` are runtime-owned.
Do not edit Keeper snapshots, task stores, board logs, receipts, or approval
history by hand.

## Terminal UI

The TUI needs an interactive TTY and a terminal other than `dumb`. When
nothing answers the port it launches the sibling `masc` binary as a child,
waits for `/health`, and stops that child when it exits. A server that was
already running is left alone.

`Tab` and `Shift-Tab` rotate through ten surfaces, drawn as a strip on the
top row. Every child view is also a `go <name>` entry in the `:` palette.

| Surface | Shows |
|---|---|
| Overview | Workspace summary, the task backlog, what needs attention |
| Activity | Every Keeper's tool calls, turn boundaries, and settlements as they land; `l` opens the server's own log ring |
| Keepers | The roster; per Keeper its chat, logs, tool calls, runtime, sandbox status, recorded file writes, channels, schedules, and detail tabs |
| Memory | Memory health per Keeper and a fact browser over both stores |
| Approvals | The Gate queue, the standing always-allow rules, and the questions Keepers are waiting on |
| Board | Posts from people, agents, automation, and the system |
| Planning | Goals, plans, the task-review queue, and recorded verdicts |
| Fusion | Panel and judge runs with their evidence |
| Workspace | Registered repositories; `Enter` opens a file browser with diff, history, blame, notes, and language-server hover and definition |
| Config | `runtime.toml` as the server reads it (`e` edits it in `$EDITOR`), prompts, themes, runtime lanes and provider reachability, the MCP resource catalog, and the tool catalog with its receipts |

Keys that work everywhere: `?` help, `:` command palette, `r` refresh, `q`
twice to quit. `/` searches the Keeper roster, the Code tree, and a chat's
request tab.

The input row at the bottom sends a message to the Keeper it names.
`/task <title>` creates a task and hands the Keeper its id in the same
message; `/help` lists the rest. A question a Keeper asked through `masc_ask`
is answered from the same row. Each tool call in a chat is drawn as a tree
with its JSON as structure, and a context inspector beside the chat shows what
went into each turn and what the provider answered.

The Code view starts the language server the project's language names
(`ocamllsp`, `typescript-language-server`, `pyright-langserver`,
`rust-analyzer`, `gopls`, `clangd`, and others) and expects it on `PATH`.
MASC ships none. An absent server answers `Command_not_found` rather than a
guess.

Without a server, the roster, per-Keeper detail, and the task backlog still
read from disk. Everything else says it needs the server instead of showing
an empty list. The header shows `[workspace mismatch]` when the TUI and the
server are on different roots.

Every binding, per-surface behaviour, themes, the browser lane, and
troubleshooting are in [`docs/TUI-GUIDE.md`](docs/TUI-GUIDE.md).

## MCP client setup

`masc mcp-config` mints a bearer and prints a config block for the client you
name:

```bash
masc mcp-config --base-path /path/to/project --client codex
masc mcp-config --base-path /path/to/project --client claude-desktop
masc mcp-config --base-path /path/to/project --client env   # shell exports
```

It mints a long-lived worker token (`--expiring` for a session-scoped one) and
embeds endpoint, token, and header. A URL-only client configuration gets
`401 Unauthorized`; the local default does not accept unauthenticated
clients.

For a client the command does not cover, the pieces are the same. Codex:

```toml
[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
bearer_token_env_var = "MASC_TOKEN"
http_headers = { "Accept" = "application/json, text/event-stream" }
```

Claude Desktop, through [`mcp-remote`](https://github.com/punkpeye/mcp-remote#custom-headers)
(requires Node.js/npm for `npx`; the header maps the token into HTTP authentication):

```json
{
  "mcpServers": {
    "masc": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://127.0.0.1:8935/mcp",
        "--header", "Authorization: Bearer ${MASC_TOKEN}"],
      "env": { "MASC_TOKEN": "paste-the-token" }
    }
  }
}
```

### Tokens

- `masc login --agent <name> --client-env MASC_TOKEN` mints one bearer for
  one agent name. Minting again for the same name replaces the previous
  bearer; nothing else has to be revoked.
- The store keeps a SHA-256 of each token in `.masc/auth/agents/<agent>.json`.
  The raw secret exists in `.masc/auth/<agent>.token` (mode `0600`) and in
  whatever shell you exported it into.
- `masc token list`, `masc token revoke <agent>`, and `masc token prune`
  inspect, retire, and garbage-collect credentials.

### What agents do in a workspace

Agents coordinate through tasks, claims, and transitions. The names below are
MCP tools the server exposes; `tools/list` on your session is the
authoritative inventory.

```text
# Agent A joins and claims a task
masc_start(path="/path/to/project", task_title="Fix auth token refresh")
masc_transition(task_id="task-001", action="claim")

# Agent B joins, sees task-001 is taken, and takes distinct work
masc_start(path="/path/to/project")
masc_status()
masc_add_task(title="Write integration test for auth flow")
masc_transition(task_id="task-002", action="claim")

# Agent A submits with evidence
masc_transition(
  task_id="task-001",
  action="submit_for_verification",
  handoff_context={
    "summary": "Token refresh tests passing",
    "evidence_refs": ["artifact:tests/auth_test.log"]
  }
)
```

Goals are shared intent with no single owner. `masc_goal_upsert` requires a
`metric` and a `target_value`, and
`masc_goal_transition(action="request_complete")` hands the goal to a model
judge that reads the task evidence and records the verdict.

More client formats and a direct `initialize` probe are in
[`docs/MCP-TEMPLATE.md`](docs/MCP-TEMPLATE.md).

## Keepers

A Keeper is one TOML file under `<base-path>/.masc/config/keepers/`. The
server boots it, wakes it on board mentions, timers, and unassigned tasks,
runs each turn in a sandbox, and writes the turn's records under `.masc/`
before the Keeper goes idle. A fresh root starts with one Keeper, `imp`: the
installer, `masc init`, and the server all seed it from the binary's
`keepers-default/`. It ships with `activation_mode = "manual"`, so nothing runs
until a model and a sandbox exist and you start it with `masc setup` or set
`activation_mode = "autonomous"`.

```toml
[keeper]
activation_mode = "autonomous"
sandbox_profile = "docker"
sandbox_image = "node:22-bookworm"
network_mode = "none"
mention_targets = ["operator"]

instructions = """
You are the review Keeper. Inspect the current change and report concrete
evidence with file paths and commands.
"""

[keeper.tools]
native = "read"   # "none" | "read" | "full"
```

Unknown keys are rejected. The model is assigned in `runtime.toml`, not here:

```toml
[runtime.assignments]
reviewer = "<provider>.<model>"
```

What a Keeper needs before its first turn runs:

- **A sandbox.** `sandbox_profile` is `docker`, `microvm`, or `remote_ssh`.
  There is no host profile; a Keeper without an accepted profile is refused.
  A `remote_ssh` Keeper names a `remote_endpoint` declared under
  `[exec.ssh.endpoints]` in `runtime.toml`.
- **An image.** `docker` and `microvm` turns run inside an image, and until
  it exists image preflight refuses the turn. `masc sandbox-image`
  builds `masc-sandbox:general` (bash, ripgrep, git on Debian) from a recipe
  embedded in the binary. A Keeper that has to build a project names that
  project's toolchain image in `sandbox_image`. The container runs with a
  read-only rootfs, `--cap-drop=ALL`, and your uid, so an image has to carry
  `bash` and the toolchain already; nothing can be installed during a turn.
- **A network mode.** Sandboxes start on `network_mode = "none"`: no web
  search, no `git push`, no HTTP. `inherit` enables the backend's outbound network.
  `policy` gives only the destinations listed under
  `[egress.keepers.<name>]` in `runtime.toml`, through a proxy the server
  owns. `masc keeper-create` requires `--network-mode` and does not choose
  for you.
- **An authenticated model provider.** HTTP API providers use a key in the server's environment; `runtime.toml` names the
  variable per provider; the server reads it from the shell it was started
  in. On the TUI path, export it before launching, because the server the TUI
  starts inherits the TUI's environment. CLI providers require their CLI installation
  and login instead; local model servers follow their configured authentication.

Two approval lanes gate what a Keeper does. The workspace lane starts in
`auto_judge`: a model reads each gated call and decides. That judgement runs
on a lane of its own (`hitl_auto_judge`), and a call it cannot judge is
deferred to the Approvals queue for a person, neither allowed nor refused.
The external-services lane, anything leaving for Jira, GitHub, Slack, or
another attached service, starts in `manual`. A Keeper that looks stuck on
its first task is often waiting in Approvals.

OAuth connectors are declarations, not connections. On a fresh install
`GET /api/v1/keepers/oauth/providers` answers `has_client: false` for every
provider; attaching one needs an OAuth client first, entered through the
Connectors view or `POST /api/v1/keepers/oauth/client`. Channel connectors
are different: Discord, iMessage, and Slack run in-process and attach as soon
as their token is in the server's environment, so a server started from a
shell that exports `DISCORD_BOT_TOKEN` joins that guild on boot, scratch
base path or not. Telegram goes through a sidecar.

`microvm` names a guest behind a hypervisor, and `microvm_backend` names the
runtime. Measured 2026-09-04 on macOS 26.6.1:

| `microvm_backend` | CLI | State |
|---|---|---|
| `apple_container` | `container` | Runs. The assumed backend on macOS, and the only one that carries `network_mode = "policy"` |
| `microsandbox` | `msb` | Wired, does not boot: the sweep cannot tell its guests apart, and the Keeper stops at `microvm_container_listing_failed` |
| `nerdctl_kata` | `nerdctl` | Verified once on Linux x64 by the `Kata volume smoke` workflow (run 34194081312, 2026-09-08): a Keeper executes in a Kata guest and its work volume survives guest recreation. Not part of the release gate and not measured on macOS. An absent CLI is refused by name |

A backend whose CLI is missing is refused at boot rather than replaced with a
shared kernel. On a host other than macOS the backend has to be named.

Manuals: [`docs/KEEPER-USER-MANUAL.md`](docs/KEEPER-USER-MANUAL.md) for
running and watching Keepers,
[`docs/KEEPER-FILE-MODEL.md`](docs/KEEPER-FILE-MODEL.md) for the file
contract, [`docs/KEEPER-IDENTITY-MANUAL.md`](docs/KEEPER-IDENTITY-MANUAL.md)
for attaching external services, the
[egress runbook](docs/operations/egress-policy-runbook.md), and the
[SSH endpoint runbook](docs/operations/ssh-endpoints-runbook.md).

## Configuration

Authored configuration lives under `<base-path>/.masc/config` unless
`MASC_CONFIG_DIR` selects another root.

| Path | Purpose |
|---|---|
| `runtime.toml` | Provider/model catalog, the required `[runtime].default`, runtime lanes, Keeper assignments, SSH endpoints, egress rules, `[tui]` |
| `keepers/<name>.toml` | One Keeper: operational settings, prompt instructions, tool posture |
| `tools/*.toml` | Declarative schemas for the tools the server registers |
| `repositories.toml` | Registered repositories for the Workspace surface |
| `agent-core-models-overlay.toml` | Optional model-capability rows over the embedded catalog |
| `<base-path>/.masc/skills/<name>/SKILL.md` | A capability a Keeper can be handed by name; `name` in the frontmatter must equal the directory name |

[`docs/ENV-CONTRACT.md`](docs/ENV-CONTRACT.md) lists the environment
variables the runtime reads, and [`docs/PROMPT-MAP.md`](docs/PROMPT-MAP.md)
says which prompt file each reader gets.

## Dashboard

The server serves a TypeScript/Preact SPA at `/dashboard/`. The 0.35.5 release
installer installs the matching dashboard beneath the binary prefix and verifies
its source commit and file checksums. No Node.js, source checkout or frontend build
is needed to use it. An already running server keeps its original bundle until
restarted. See [installed distribution](docs/design/installed-dashboard-distribution.md)
and [installation](docs/INSTALL.md). Older tags must be used with their own installer.

The dashboard reads the state the TUI reads, and it holds two screens the TUI
does not have: the experimental IDE shell and the Lab diagnostics. In the two
weeks to 2026-09-07 it received 137 commits and the TUI 583, out of 3,003.
Operator features are built in the TUI first; the dashboard is kept
building, type-checked, and truthful. The
[24-screen inventory](docs/screenshots/dashboard/2026-09-04/README.md) and
[`docs/DASHBOARD-INTEGRATION.md`](docs/DASHBOARD-INTEGRATION.md) describe
it. Admin operations and write access are in
[`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md).

## Limits

- The coordination state does not lock files. Two agents editing the same
  file still conflict. MASC lets them see each other; it does not serialise
  them.
- The Gate is an authorization workflow, not a credential boundary. The
  sandboxes reduce what a turn can reach; none of them is a complete security
  boundary, and `remote_ssh` starts with the endpoint's network.
- Auth defaults are for the loopback. Remote-safe operation, cluster
  deployment, and service guarantees are not promised.
- One process holds the workspace. There is no failover.
- Only `apple_container` is known to boot a microVM Keeper. `auto_judge` needs
  a model on its own lane, which an install with one provider key usually
  lacks; those calls wait for a person.
- TUI surfaces and keys change on `main`; use documentation from the installed tag.

## Repository layout

```text
masc/
├── bin/          server and CLI (main_eio.ml), the TUI (masc_tui*.ml), exec shim, probes
├── lib/          workspace, Keeper, runtime, Gate, server, and TUI decoding
├── packages/     embedded Agent Core
├── dashboard/    TypeScript and Preact dashboard source
├── connectors/   browser lane host
├── config/       configuration seeds embedded into the binary
├── docs/         manuals, runbooks, specs, RFCs, research records
├── scripts/      build, install, CI lints, local operations
└── test/         Alcotest suites and fixtures
```

## Documentation

| Document | Use |
|---|---|
| [`docs/TUI-GUIDE.md`](docs/TUI-GUIDE.md) | Every TUI surface, key, theme, and failure mode |
| [`docs/MCP-TEMPLATE.md`](docs/MCP-TEMPLATE.md) | MCP client configuration and a direct initialize probe |
| [`docs/KEEPER-USER-MANUAL.md`](docs/KEEPER-USER-MANUAL.md) | Configuring, starting, and watching Keepers |
| [`docs/KEEPER-FILE-MODEL.md`](docs/KEEPER-FILE-MODEL.md) | Keeper file and runtime-assignment contract |
| [`docs/KEEPER-IDENTITY-MANUAL.md`](docs/KEEPER-IDENTITY-MANUAL.md) | Attaching Jira, Notion, Google, and other services to a Keeper |
| [`docs/SKILLS.md`](docs/SKILLS.md) | Declaring a capability in `SKILL.md` and handing it to a Keeper |
| [`docs/ENV-CONTRACT.md`](docs/ENV-CONTRACT.md) | Environment variables the runtime reads |
| [`docs/PROMPT-MAP.md`](docs/PROMPT-MAP.md) | Which prompt file each reader gets |
| [`docs/operations/ssh-endpoints-runbook.md`](docs/operations/ssh-endpoints-runbook.md) | Provisioning a `remote_ssh` endpoint and its preflight failure codes |
| [`docs/operations/egress-policy-runbook.md`](docs/operations/egress-policy-runbook.md) | Declaring what a `policy` Keeper may reach |
| [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | Local bearers and dashboard write access |
| [`docs/AGENT-CORE-BOUNDARY.md`](docs/AGENT-CORE-BOUNDARY.md) | Responsibility split between MASC and the embedded Agent Core |
| [`docs/spec/SPEC-INDEX.md`](docs/spec/SPEC-INDEX.md) | Specification index |
| [`docs/RELEASE-EVIDENCE.md`](docs/RELEASE-EVIDENCE.md) | Release evidence format |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Build, test, lint, and pull-request workflow |
| [`ROADMAP.md`](ROADMAP.md) | Current planning view, not a release promise |

## Release status

The package version is in `dune-project` and generated into `masc.opam`.
`CHANGELOG.md` records the source release line, and GitHub Releases is the
source of truth for binaries. APIs and configuration may change before 1.0.

Milestones (the live rules are `ROADMAP.md` → "Release lane rules"):

- `0.y.0` opens a user-visible train and `0.y.z` stabilizes it — the current
  line is `0.35.0`.
- `1.0.0` opens only when the TUI, the MCP workspace, and release truth hold
  without caveats.
- `v2.*` tags are history; they do not define the active line.

## License

MIT. See [`LICENSE`](LICENSE). Bundled fonts have their own
[third-party notices](THIRD-PARTY-LICENSES.md).
