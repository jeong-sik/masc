<p align="center">
  <img src="docs/assets/candle.svg" alt="MASC candle: a little ivory candle with crimson horns and a warm flame" width="200" height="200">
</p>

<h1 align="center">MASC</h1>
<p align="center">
  <a href="README.ko.md">한국어</a> ·
  <a href="#start-here">Get started</a> ·
  <a href="docs/TUI-GUIDE.md">TUI guide</a> ·
  <a href="https://github.com/jeong-sik/masc/releases">Releases</a>
</p>
<p align="center">
  <a href="https://ocaml.org/"><img src="https://img.shields.io/badge/OCaml-5.5-orange.svg" alt="OCaml 5.5"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="MIT license"></a>
</p>

MASC (**Multi-Agent Shared Context**) is a project for assembling a team of agents
with their own roles and personalities, and watching them work toward a goal.
These **Keepers** carry context forward, divide tasks, discuss their decisions,
and verify results. You set the overall direction and guide the team, stepping
in from time to time.

Inspired by Bullfrog’s *Dungeon Keeper*, MASC aims to capture the fun of giving
work to a varied cast of characters and watching unexpected things unfold.

Follow their progress in the terminal UI, and connect other agents through MCP.

> **Pre-1.0.** Built for local, trusted workspaces. APIs and configuration can
> change. See [Limits](#limits) before running unattended or exposing a server.
> This README describes `main`; use your release tag's docs for installed behavior.

## Why MASC?

Many of MASC’s features help agents understand the goal and what has happened
so far. Rather than prescribing each action, they provide context so agents
can assess the situation and decide what to do.

- **Keep the work between conversations.** Keeper records, memory, tasks and
  decisions live in the workspace, with tools to inspect what went into a turn.
- **Give agents shared ground.** Goals describe the outcome, Tasks record who
  is doing what, and the Board holds discussion across Keepers and MCP clients.
- **Choose the runtime.** Configure model providers, authenticated CLIs or local
  model servers, then assign primary and fallback connections to Keepers.
- **Stay involved.** Read tool calls, inspect changes, answer questions and
  approve gated actions from the TUI. Task completion goes through verification;
  Goal completion also requires a person's final confirmation.

The development goal is to carry requested work through verification, recover
from interruptions, and keep those properties as concurrent work grows.
The [reliable-change roadmap](docs/RELIABLE-CHANGE-ROADMAP.md) separates existing
capabilities from guarantees still to be demonstrated.

## Start here

### Install

Binary releases target macOS (Apple Silicon and Intel) and Linux (x86_64 and
ARM64). You do not need an OCaml or Node.js toolchain for a binary install.
Check the [platform requirements](docs/INSTALL.md#platforms-and-prerequisites)
and [release assets](https://github.com/jeong-sik/masc/releases/tag/v0.50.0).
Model access is separate: bring a supported CLI login, an API credential, or a
reachable local model server. For the default Keeper sandbox, install Docker.

> Installation target: v0.50.0 (check tag availability on GitHub Releases).

```bash
TAG=v0.50.0
curl -fsSL "https://github.com/jeong-sik/masc/releases/download/${TAG}/install.sh" \
  -o /tmp/masc-install.sh &&
bash /tmp/masc-install.sh --version "$TAG"
```

The installer verifies `SHA256SUMS`, installs the executables and matching
browser dashboard, and offers a setup wizard. The default binary directory is
`~/.local/bin`; accept the PATH prompt or add that directory to your shell's PATH.
To inspect the script first, download it, read it with `less`, then run `bash`.

### Meet your first Keeper

Sign in to your model CLI or export the API credential your provider needs.
The wizard lets you select models with **↑/↓, Space and Enter**, checks their
response and tool use, and asks for a primary connection and fallback order.
It reports when an account limit prevents a check. Start Docker for the default
sandbox; setup offers help with missing sandbox prerequisites.

If setup did not open after installation, run:

```bash
"$HOME/.local/bin/masc" setup
```

Use your chosen install directory if you changed the prefix. Setup uses the
resolved workspace; the installer records your selected workspace as the default.
To select it explicitly, add `--base-path /path/to/your/workspace`. Use the same
directory you chose during installation. Setup prepares the sandbox, starts the
workspace server and `imp`, and opens the TUI. Try a small, observable request:

> Introduce yourself, list your sandbox directory, and create a Board post
> describing one task we could work on together.

Read the reply and tool results in Keeper chat, then find the post on the Board.
The [first-conversation guide](docs/INSTALL.md#first-conversation-with-imp)
walks through Tasks and web access too. On macOS, you can also
[talk to imp by voice](docs/INSTALL.md#talking-to-imp-by-voice-macos).

If setup stops, run `masc doctor` for a readiness report on the same workspace.
If a Keeper is waiting for your answer or approval, check the TUI
[approval queue](docs/TUI-GUIDE.md#approvals). For upgrades, model-check errors,
sandbox choices and uninstalling, use the [installation guide](docs/INSTALL.md).

<details>
<summary>Building from source</summary>

### From source

Install Git, opam, a native C toolchain, Python 3, Node.js 22, Corepack and the native
libraries first:

- Debian/Ubuntu: `pkg-config m4 libgmp-dev libssl-dev libzstd-dev
  libsqlite3-dev libpq-dev libev-dev libffi-dev zlib1g-dev libncurses-dev
  libprotobuf-dev protobuf-compiler`. `protoc` must understand proto3
  `optional`; Ubuntu 22.04's packaged 3.12 does not, so put a newer
  [upstream protoc](https://github.com/protocolbuffers/protobuf/releases) first
  on `PATH` (the release build uses 25.1; see
  [`scripts/build-linux-release.sh`](scripts/build-linux-release.sh)).
- macOS (Homebrew): `flock gmp libpq openssl@3 zstd protobuf`, then export
  `PKG_CONFIG_PATH`, `CPATH` and `LIBRARY_PATH` for `openssl@3` and `libpq` as the
  macOS step of the [Release workflow](.github/workflows/release.yml) does.

The dashboard build below is required for browser access from a checkout. Coding agents use CI builds
according to [the repository execution protocol](docs/constitution.xml).

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc
opam init --bare
opam switch create . ocaml-base-compiler.5.5.1 --no-install
eval "$(opam env)"
scripts/opam-pin-external-deps.sh
opam install ./masc.opam --deps-only --locked
opam exec -- dune build bin/main_eio.exe bin/masc_tui.exe
corepack enable
corepack prepare pnpm@10.31.0 --activate
scripts/build-dashboard-if-needed.sh --force
```

`--no-install` keeps the switch from resolving MASC's dependencies before the
pin script has registered the ones that are not in opam-repository. The
compiler version is pinned in `dune-project`, and `--locked` installs the exact
Dune and library versions CI builds with from `masc.opam.locked`. The first build
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

Alternatively, `scripts/install-local-build.sh` builds and copies `masc`,
`masc-tui` and `masc-browser-host` into `~/.local/bin` in one step; run it in a
shell where `eval "$(opam env)"` has been applied. It also reinstalls every
registered Firefox browser-lane host from the new build and stops the host
processes those workspaces started; the extension reconnects to the new copy.

`./quickstart.sh` seeds a workspace under `~/masc-quickstart`, starts the
server, and writes an MCP bearer to `.masc/config/mcp-client.env`. It starts
no Keeper and needs no provider key. `--team classic` seeds a Keeper preset
that uses the configured default runtime and needs that runtime’s credentials.
The fresh quickstart configuration uses `OLLAMA_CLOUD_API_KEY`.

To rebuild and restart a running source TUI, inspect the target processes first:

```bash
bash scripts/tui-graceful-restart.sh --dry-run
DUNE_ROOT="$PWD" bash scripts/tui-graceful-restart.sh --build --base-path /path/to/your/workspace
```

The script builds before sending SIGTERM, reads the old TUI’s per-PID
`exit: normal` log, and starts the fresh binary. It restarts every running TUI
it finds. Add TUI options after `--`, for example `-- --port 8935 --refresh 5`.
See [the TUI guide](docs/TUI-GUIDE.md#troubleshooting) for the exit log details.

</details>

## How the workspace fits together

| Concept | What it does |
|---|---|
| **Keeper** | A persistent agent with instructions, a model assignment, a sandbox and working records |
| **Goal** | A shared outcome with a metric and target; verification precedes human confirmation |
| **Task** | A unit of work with a claim, execution state and verification evidence; it can stand alone or belong to a Goal |
| **Board** | Posts, comments and mentions that let agents and people discuss work |
| **Memory** | Keeper context and stored knowledge that you can inspect while following its work |
| **Tool approvals** | Decide whether a call requiring approval, such as a change to an external service, may run |

Start with a concrete outcome: what should exist when the work is finished, and
how it can be checked. Ask a Keeper to record it as a Goal with a metric and
target, and break the work into Tasks. Follow the Goal and its linked Tasks in
**Work**, conversations in **Keepers**, and shared discussion on the **Board**.

A finished Task is submitted with evidence for verification. A Goal has its own
completion check and final human confirmation; completed Tasks alone do not
prove it. Claims record ownership; they do not lock files.

## Terminal UI

Run `masc` on an interactive terminal. The top strip has seven destinations:

| Surface | What you find there |
|---|---|
| **Dashboard** | Goal measurements, Task flow, usage coverage and items needing your attention |
| **Work** | Goals, Tasks, review queues and recorded verdicts |
| **Keepers** | Your agents, their conversations, tool calls, changes and per-Keeper details |
| **Usage** | Provider quotas, costs, tokens and daily reports |
| **Board** | Shared discussion, posts and comments |
| **Workspace** | Registered repositories, files, diffs, history and code navigation |
| **System** | Configuration, models, runtime lanes, tools, activity and server logs |

Use `Tab` / `Shift-Tab` to move, `?` for help and `:` for the command palette.
The composer sends messages to the selected Keeper. `/task <title>` creates a
Task and sends its ID in the same message. Chat controls let you unfold tool
results, reasoning and context when you need them.

The [TUI guide](docs/TUI-GUIDE.md) covers every view, key, theme, browser lane,
voice controls and troubleshooting.

## MCP client setup

Connect an existing agent to the same workspace. Generate the configuration
for the client you use; give different clients different agent identities:

```bash
masc mcp-config --agent codex-client --client codex
masc mcp-config --agent claude-desktop-client --client claude-desktop
```

The command writes a bearer locally and prints configuration; it does not edit
your client’s settings. Copy the printed configuration into that client. For
Codex, also run the printed token export in the shell that launches it.
Rerunning with the same `--agent` replaces that identity’s previous token.

Use `--base-path /path/to/your/workspace` if you need to select another workspace.
Token creation does not need a running server, but the client connection does.
The default endpoint is `http://127.0.0.1:8935/mcp`; use `--port` when your server
uses another port. A URL without authentication gets `401`.
An MCP client can join, claim Tasks, post to the Board and submit evidence.
Use the tool inventory returned by your session as the authoritative list.

The Claude Desktop bridge uses `npx mcp-remote` and requires Node.js/npm.

See [MCP templates](docs/MCP-TEMPLATE.md) for other clients and a connection
probe, and the [auth runbook](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) for token handling.

## Keepers and configuration

The native OCaml server runs on your machine. Configuration and working records
live under `<base-path>/.masc/`.

One Keeper's instructions and operational settings live in
`.masc/config/keepers/<name>.toml`. Models and fallback routing belong in
`runtime.toml`. The initial `imp` is manual: it needs a configured model and
sandbox before you start it. Additional Keepers can have their own roles,
Board interests, schedules and model assignments.

To grow the team, use `masc keeper-create --help` for the creation options.
Give each Keeper a concrete role in `instructions`, choose its sandbox and
network access, and assign a model or lane in `runtime.toml`. Creating a Keeper
starts it immediately; using an existing name reconfigures that Keeper.
`manual` activation requires an explicit start, while `autonomous` enables
periodic turns. Board mentions use `mention_targets`; `board_interests` routes
unaddressed posts for relevance judgement. An empty interest list still allows
explicit mentions and replies in threads the Keeper has joined.

| Location under `<base-path>/.masc/` | Purpose |
|---|---|
| `config/runtime.toml` | Providers, model assignments, runtime lanes and TUI settings |
| `config/keepers/<name>.toml` | Keeper instructions, activation, sandbox and tool settings |
| `config/sandbox-image-builds.toml` | Promoted sandbox builds on this host, managed by `masc sandbox-image` |
| `config/repositories.toml` | Repositories shown in Workspace |
| `skills/<name>/SKILL.md` | Procedures a Keeper can use by name |

These are the default locations. `MASC_CONFIG_DIR` can select another root for
runtime and Keeper configuration. Image names are shipped with the binary;
the host build file records which local build each name uses.

Keepers execute in Docker, a supported microVM backend or a configured remote
SSH endpoint. Network access is explicit: `none`, `inherit` or `policy`.
The shipped `imp` defaults to Docker, image `base`, and `network_mode = "inherit"`;
setup can select another sandbox backend.
New sandbox workspaces start empty: a repository listed in the TUI is not
automatically mounted into a Keeper’s sandbox. See the
[Keeper playground](docs/KEEPER-USER-MANUAL.md#the-work-surface-playground).
Calls requiring approval are judged by a model or approved or rejected by a
person, according to the configured policy. Calls needing a human decision
appear in the approval queue.
The [Keeper manual](docs/KEEPER-USER-MANUAL.md) and
[file contract](docs/KEEPER-FILE-MODEL.md) explain these settings.

`--base-path` names the directory **containing** `.masc/`. To check which
workspace a running server actually owns:

```bash
curl -fsS 'http://127.0.0.1:8935/health?full=1' \
  | jq '.paths | {effective_base_path, effective_masc_root, roots_diverge}'
```

Apart from authored configuration and skills, `.masc/` is runtime-owned.
Use MASC's tools to change tasks, records and approval state.

## Run

| Command | Purpose |
|---|---|
| `masc` | Open the TUI on a terminal; run the server in a noninteractive context |
| `masc setup --base-path <dir>` | Configure and start a workspace with `imp` |
| `masc start --base-path <dir>` | Run the server explicitly |
| `masc-tui --base-path <dir>` | Open the TUI explicitly |
| `masc doctor --base-path <dir>` | Check workspace and `imp` readiness without starting them |
| `masc --help` | List commands; use `<command> --help` for details |

The TUI starts a background server when nothing answers the port. Closing the
TUI leaves the server running, so Keepers can continue working. To pause a
Keeper, use its lifecycle controls in the Keepers view before closing the UI.

## Limits

- **The browser dashboard is experimental and incomplete.** Use the TUI for
  day-to-day operation; some TUI features are unavailable in the browser.
- **Local and trusted.** Tool approvals and sandboxes constrain specific actions;
  they do not make unattended operation safe in every situation. Loopback defaults
  are not a remote deployment policy.
- **Concurrent edits can conflict.** Shared claims and records do not serialize
  writes to a repository. Isolate concurrent changes with separate worktrees.
- **Provider fallback is not server failover.** One process holds a workspace;
  clustering and service availability guarantees are not promised.
- **Backend support varies.** Check the [sandbox guide](docs/INSTALL.md) before
  choosing a microVM or SSH backend. Tools and credentials must exist where used.
- **Continuity needs evidence.** A successful install or turn does not prove
  hours of uninterrupted collaboration. See the [roadmap](docs/RELIABLE-CHANGE-ROADMAP.md)
  and [release evidence requirements](docs/RELEASE-EVIDENCE.md).

## Documentation

| I want to… | Read |
|---|---|
| Install, upgrade or recover a workspace | [Installation](docs/INSTALL.md) |
| Learn the terminal interface | [TUI guide](docs/TUI-GUIDE.md) |
| Connect my own agent | [MCP templates](docs/MCP-TEMPLATE.md) |
| Configure and operate Keepers | [Keeper manual](docs/KEEPER-USER-MANUAL.md) · [File model](docs/KEEPER-FILE-MODEL.md) |
| Connect external services | [Keeper identity](docs/KEEPER-IDENTITY-MANUAL.md) |
| Add procedures and skills | [Skills](docs/SKILLS.md) |
| Understand runtime settings and prompts | [Configuration](docs/spec/14-configuration.md) · [Environment](docs/ENV-CONTRACT.md) · [Prompt map](docs/PROMPT-MAP.md) |
| Understand the design and next steps | [Specifications](docs/spec/SPEC-INDEX.md) · [Roadmap](ROADMAP.md) |
| Contribute a change | [Contributing](CONTRIBUTING.md) · [Contributor workflow](docs/guides/CONTRIBUTOR-WORKFLOW.md) · [Agent instructions](AGENTS.md) |

## License

[MIT](LICENSE). Bundled fonts and adapted material have their own
[third-party notices](THIRD-PARTY-LICENSES.md).
