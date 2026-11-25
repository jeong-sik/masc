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

MASC (**Multi-Agent Shared Context**) runs persistent agents (**Keepers**) and
external MCP clients against a shared workspace. Keepers retain turn history and
working memory, coordinate through Goals, Tasks, and the Board, and submit
completed work for verification. You configure models and sandboxes, follow
turns in the terminal UI, and approve gated actions when needed.

> **Pre-1.0.** Built for local, trusted workspaces. APIs and configuration can
> change. See [Limits](#limits) before running unattended or exposing a server.
> This README describes `main`; use your release tag's docs for installed behavior.

## Why MASC?

MASC provides shared workspace state so agents can inspect current goals, prior
turns, and active tasks before deciding what to do.

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

Binary releases support Apple Silicon Macs with macOS 15 or later and Linux
(x86_64 and ARM64). Intel Macs are unsupported. No OCaml or Node.js toolchain is
required for a binary install.
See the [first-install sequence](docs/INSTALL.md#first-install-sequence),
[platform requirements](docs/INSTALL.md#platforms-and-prerequisites), and [release assets](https://github.com/jeong-sik/masc/releases/latest).
Model access is separate: bring a supported CLI login, an API credential, or a
reachable local model server. The setup screen helps you choose and prepare a
sandbox; Docker is one option, alongside supported microVM and remote SSH backends.

```bash
curl -fsSL https://github.com/jeong-sik/masc/releases/latest/download/install.sh \
  -o /tmp/masc-install.sh &&
bash /tmp/masc-install.sh
```

The installer verifies `SHA256SUMS`, installs the executables and matching
browser dashboard, and offers a setup wizard. The default binary directory is
`~/.local/bin`; accept the PATH prompt or add that directory to your shell's PATH.
To inspect the script first, download it, read it with `less`, then run `bash`.

### Meet your first Keeper

Sign in to your model CLI or export the API credential your provider needs.
The wizard lets you select models with **↑/↓, Space and Enter**, checks their
response and tool use, and asks for a primary connection and fallback order.
CLI subscriptions use their own login; API connections use the selected provider’s
credential, and local servers use their configured endpoint. You need one usable
connection. Setup reports account limits and offers help with missing sandbox
prerequisites; Docker need not be installed before downloading MASC.

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
walks through Tasks, Board posts and web access. To add a second Keeper, see
[Keepers and configuration](#keepers-and-configuration). On macOS, you can also
[talk to imp by voice](docs/INSTALL.md#talking-to-imp-by-voice-macos).

If setup stops, run `masc doctor` for a readiness report on the same workspace.
If a Keeper is waiting for your answer or approval, check the TUI
[approval queue](docs/TUI-GUIDE.md#approvals). For upgrades, model-check errors,
sandbox choices and uninstalling, use the [installation guide](docs/INSTALL.md).

<details>
<summary>Building from source</summary>

### From source

Install Git, opam, a native C toolchain, Python 3, Node.js 22.13 or later in the 22.x series, Corepack and the native
libraries first:

- Debian/Ubuntu: `pkg-config m4 libgmp-dev libssl-dev libzstd-dev
  libsqlite3-dev libpq-dev libev-dev libffi-dev zlib1g-dev libncurses-dev
  libprotobuf-dev protobuf-compiler`. `protoc` must understand proto3
  `optional`; Ubuntu 22.04's packaged 3.12 does not, so put a newer
  [upstream protoc](https://github.com/protocolbuffers/protobuf/releases) first
  on `PATH` (the release build uses 25.1; see
  [`scripts/build-linux-release.sh`](scripts/build-linux-release.sh)).
- macOS (Homebrew): install the Xcode Command Line Tools with `xcode-select --install`
  if needed. In the build shell, run:

  ```bash
  brew install pkg-config gmp libpq openssl@3 zstd protobuf
  libpq_prefix="$(brew --prefix libpq)"
  openssl_prefix="$(brew --prefix openssl@3)"
  export PATH="$libpq_prefix/bin:$openssl_prefix/bin:$PATH"
  export PKG_CONFIG_PATH="$openssl_prefix/lib/pkgconfig:$libpq_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export CPATH="$openssl_prefix/include${CPATH:+:$CPATH}"
  export LIBRARY_PATH="$openssl_prefix/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export CPPFLAGS="-I$openssl_prefix/include${CPPFLAGS:+ $CPPFLAGS}"
  export LDFLAGS="-L$openssl_prefix/lib${LDFLAGS:+ $LDFLAGS}"
  ```

The dashboard build below is required for browser access from a checkout.
Coding agents follow [the repository execution protocol](docs/constitution.xml).

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc
opam init --bare
opam switch create . ocaml-base-compiler.5.5.2 --no-install
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
compiler version is pinned in `dune-project`. With `--locked`, opam uses the
Dune and library versions recorded in `masc.opam.locked`. The first build
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
`masc-tui` and the deployment preflight tools into `~/.local/bin` in one step;
run it in the shell where you applied `eval "$(opam env)"`. For a new workspace:

```bash
scripts/install-local-build.sh --base-path "$HOME/MASC"
"$HOME/.local/bin/masc" setup --base-path "$HOME/MASC"
```

For a new source installation, choose Docker in setup. To use Apple Container,
first [build and install the Linux ARM64 guest shim from the same checkout](docs/MICROVM-REMOTE-RUNBOOK.md#shim-받기),
using the same workspace path. The source installer keeps existing release shims by default.
Use `--refresh-guest-shim` when deploying a server/shim change to microVM Keepers
or addressing `remote_shim_outdated`; it refreshes an existing release shim
(`docs/MICROVM-REMOTE-RUNBOOK.md`). When that release's shim declares another
source identity than the build (always, for a checkout build), it installs
nothing and names the source build (`scripts/remote-ssh/build-shim.sh`) to use
instead.
Before it replaces anything, the script checks the workspace's `runtime.toml`
with the new build. A resolved workspace that observably does
not exist yet is treated as a new workspace, with that check reported as not
run. If the workspace cannot be resolved or observed, installation stops before
replacement; pass `--base-path DIR` or set `MASC_BASE_PATH` when
no workspace is found. A configuration rejection also stops installation.
Routine local installation does not scan stored history or restart the server.
It does not certify stored-state compatibility. For a storage-format change,
run the candidate's explicit audit before starting it on existing state; see
[stored-state deployment checks](docs/guides/DURABLE-STORE-HARD-CUT.md).
`masc restart` performs boot checks, not the full history audit.

The browser route runs in the browser Lane Add-on, so the script also builds
and installs `masc-native-addon-launcher` and `masc-browser-addon-worker` into
the same prefix. The masc it installed then runs
`masc browser-lane-setup --mode addon` for the workspace: when the workspace
runs ego lite, it writes the package that build carries to
`.masc/packages/browser-ego` and declares it in `browser-ego.toml` when the
workspace has no declaration of it.
The server attaches them when it starts. Pass `--no-browser-addon` to leave the
Add-ons out: the programs are not built or installed, the workspace's
declarations are left as they are, and no browser route works. See
[Browser Addon setup](addons/browser/README.md).
Release downloads do not include these programs.

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
it finds. Add TUI options after `--`, for example `-- --port 8935`.
See [the TUI guide](docs/TUI-GUIDE.md#troubleshooting) for the exit log details.

</details>

## How the workspace fits together

| Concept | What it does |
|---|---|
| **Keeper** | A persistent agent with instructions, a model assignment, a sandbox and working records |
| **Goal** | A shared outcome with a metric and target; verification precedes human confirmation |
| **Task** | A unit of work with a claim, execution state and verification evidence; it can stand alone or belong to a Goal |
| **Board** | Posts, comments, attachments and mentions that let agents and people discuss work |
| **Memory & Wiki** | Keeper turn context, stored memory, and the shared workspace wiki (`.masc/wiki/`) |
| **Tool approvals** | Decide whether a call requiring approval, such as a change to an external service, may run |

Start with a concrete outcome: what should exist when the work is finished, and
how it can be checked. Ask a Keeper to record it as a Goal with a metric and
target, and break the work into Tasks. Follow the Goal and its linked Tasks in
**Work**, shared discussion on **Knowledge → Board**, and conversations in
**Keepers**.

A finished Task is submitted with evidence for verification. A Goal has its own
completion check and final human confirmation; completed Tasks alone do not
prove it. Claims record ownership; they do not lock files.

## Terminal UI

Run `masc` on an interactive terminal. The top rail has six workspaces (`1`–`6`,
or `Ctrl+1`–`6` / `Alt+1`–`6` / `F1`–`F6`), paired with a collapsible **Left Navigation Sidebar**
(`b` / `Ctrl+B` / `Alt+B`, auto-docked at `>= 132` cols) giving 100%-keyboard access to every
workspace, sub-tab, and overlay:

| # | Workspace | What you find there |
|---|---|---|
| `1` | **Pulse** | Organization overview, KPI hero band, Attention queue, live fleet health, and 24h pulse |
| `2` | **Work** | Six tabs: Goals (Goals & Verifications `[v]`, phase filter `[Space]`, sort `[S]`, interactive Goal Dive Linked Tasks/Verifier Runs, Verification Dive with Evidence/Summary/Specs/TLC tabs), Tasks (scrollable Description/Verification sections), Schedules (dedicated tab), Action Inbox (Asks, Tool Approvals, Gate), Candle & Scorecard, and Harness Health (calibration KPIs, verdict detail with 64-hex `notes_hash`, `[y]`/`[n]` overrule) |
| `3` | **Knowledge** | Four tabs: Board (Signal/All `[s]`, Sort `[S]`, Hearth picker `[h]`, Succession Chains `[Space]`, threaded comments `[c]`, armed votes `[+]`/`[-]`), Wiki, Artifacts (structured `Html_doc`/Markdown/JSON preview, `[v]` raw, `{`/`}` revisions, `/` search, `[c]` check, `[P]`/`[Y]` CAS share, `y`/`e`/`o`/`H`), and World Memory (`[v]` Diff & Flow with Braille chart `[g]` / Health & Workspace Ledger / Context, `[w]` temporal diff window, `[m]` scope) |
| `4` | **Keepers** | Fleet roster (`Companies`, `Attention`, `24h Wall`), lifecycle controls (`[W]` wake/online/resume, `[D]` 2-press shutdown, `/wake`, `/up`, `/boot`, `/resume`, `/pause`, `/down`, `Ctrl+K`), and synchronized 9-tab Keeper split & 1-hop Dive: Chat & Stream, Context & Turns (per-turn occupancy/cache/next-request/input-map/response), Tool Calls (hourly stats + unfolded JSON tree), Memory (`[v]` Diff & Flow Braille chart / Health / Facts Tree / Journal), Work & Candle, Sandbox, Config (in-place TOML editor), Logs (`[v]` remote-safe Metrics vs Sandbox Logs), and Identity (OAuth providers/switch/disconnect + GitHub device flow & masked PAT) |
| `5` | **Runtime** | Seven tabs: Quotas & Credits, Efficiency & Spend, Failover Lanes (cascades & `exact_lane_runs`), Fusion (full detail & Fusion Dive: Question → Panel → Judge → Evidence, seat routes, tool trace, replay warnings, presets, `[e]` board evidence), Tools & Usage (Usage Calls `[w]` 24h/7d/14d, Catalog Tree + Tool Dive, Keeper Surface & Skills), Connectors (live `/connector/names` picker in `[n]` Bind, MCP Clients, Browser summary), and Addons & Browser (Addon Lanes + `[p]` Package Catalog & Preview + Browser Clients & Per-Tab listing) |
| `6` | **Infra** | Four tabs: Sandboxes (MicroVM/SSH/Docker fleet + inspector), Repos & Changes, Code (workspace directory tree, `[p]` fuzzy file finder, `[f]` ripgrep search, syntax-highlighted viewer, `[g]` Git status/branches/worktrees/blame/log/diff), and Activity & Logs (backfilled `ALL`/`LOGS`/`EVENTS` timeline `[s]`, `[a]` Acting side-rail, `Enter` Runtime Trace & Log Detail dives) |

MASC TUI is **monitor-first**: while unfocused, bare keys navigate directly.
Switch workspaces with `1`–`6`, open utility overlays with `7`–`0` (`7` Settings,
`8` Incidents, `9` Queue/Context, `0` Help), toggle/focus the Left Navigation
Sidebar with `b` / `Ctrl+B` / `Alt+B`, move spatially across Sidebar and panes
with `←` / `→`, cycle sub-tabs with `[` / `]` (or `Alt+[` / `Alt+]`), move
selection or scroll with `↑`/`↓` (`j`/`k`), dive into an item or open the
dedicated **Ask Answer Modal** with `Enter` (or `Y` on an Ask), and
focus the bottom composer with `i` (or press `c` on a Keeper to jump straight
into Chat). Inside the composer, `Enter` sends (behind an active turn it waits for that turn to end),
`Alt+Enter` (or `Ctrl+Enter`) steers by cutting your own running request, `Shift+Enter` (or `Ctrl+J`)
inserts a newline, and `PgUp`/`PgDn` scroll the chat transcript while keeping focus and your draft intact. Type `/` or `@` inside the composer to open the interactive
command/mention popup (`↑`/`↓` select, `Tab` complete, `Enter` run/insert,
`Esc` dismiss). `Esc` blurs the composer, returns focus from the sidebar, pops
a dive (restoring previous pane & zoom), or closes an overlay and never quits; `Ctrl+Q` pressed twice within 2.5s quits cleanly.

Global overlays and tools (also accessible via persistent top-chrome badges `[b]` `[I]` `[^T]` `[,]` `[?]`):
`Ctrl+K` command/entity palette, `Ctrl+G` keeper switcher, `Ctrl+L`
model/runtime switcher, `7` / `,` 2-pane Settings overlay (`←`/`→` cycle
enum/bool/numeric values, `Enter` inline edit, `d` dry-run diff, `Ctrl+S`
save — also available directly in Keeper Config), `9` / `Ctrl+T` Queue/Context/Schedules
drawer (with compact per-turn context inspector), `8` / `I` historical incidents
drawer, `J` jump to the most urgent blocked item (opening the Ask Answer Modal
for pending Asks), and `0` / `?` dynamic keymap help. Native terminal
drag-select is on by default (mouse capture starts off); press `m` while
unfocused to toggle mouse-wheel scrolling, and `y` to copy the current selection
via OSC 52. In chat, `Ctrl+O` (or `/tools compact|results|full`) cycles tool
details, `Alt+T` cycles thinking display, and `Ctrl+F` cycles origin metadata.
See [the guide's first section](docs/TUI-GUIDE.md#what-can-i-do-here) for a
walkthrough and slash-command reference.

The [TUI guide](docs/TUI-GUIDE.md) covers every workspace, shortcut, recipe,
theme, voice control, streaming architecture, and troubleshooting step.

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
periodic turns. Optional `group` under `[keeper]` sets a deployment-neutral
group label for **Pulse**, **Keepers**, and **Runtime** spend views (defaults to
`"ungrouped"` when omitted or blank); it is display grouping only and stays
separate from Board routing. Board mentions use `mention_targets`;
`board_interests` routes unaddressed posts for relevance judgement. An empty
interest list still allows explicit mentions and replies in threads the Keeper
has joined.

| Location under `<base-path>/.masc/` | Purpose |
|---|---|
| `config/runtime.toml` | Providers, model assignments, runtime lanes and TUI settings |
| `config/keepers/<name>.toml` | Keeper instructions, optional `group`, activation, sandbox and tool settings |
| `config/sandbox-image-builds.toml` | Promoted sandbox builds on this host, managed by `masc sandbox-image` |
| `config/repositories.toml` | Repositories shown in **Infra → Repos & Changes** |
| `skills/<name>/SKILL.md` | Procedures a Keeper can use by name |
| `wiki/` | Shared workspace wiki pages (`index.md`, `log.md`, and topic pages) |

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

This works as written on the default loopback server. A server that requires
a token (`MASC_HTTP_AUTH_STRICT`, or a bind host or base URL that is not
loopback) answers a request without a credential with a short public probe
that has no `paths`. Add `-H "Authorization: Bearer $MASC_TOKEN"` there.

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
| `masc browser-lane-setup` | Configure the browser lane (`addon` or `ego`) |
| `masc web-search-setup --base-path <dir>` | Inspect or configure workspace web search (`searxng`, `zai`, etc.) |
| `masc --help` | List commands; use `<command> --help` for details |

See [server startup ownership](docs/guides/server-startup-ownership.md) for
workspace lease and occupied-port behavior.

The TUI starts a local server when nothing answers the port (unless
`--no-auto-start` is passed). Closing the TUI with `Ctrl+Q` leaves an
externally started server (`masc start` / `masc setup`) running so Keepers can
continue working, while a server auto-started and owned by that TUI session is
stopped on exit (`/restart` preserves an owned server). To stop a Keeper on a
persistent server before closing the UI, use `masc_keeper_down`.

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
| Let people sign in and run Keepers on their own subscriptions | [Account server setup](docs/guides/account-server-setup.md) · [Invitations](docs/guides/account-server-invitations.md) · [MCP of a person](docs/guides/account-server-mcp.md) |
| Learn the terminal interface | [TUI guide](docs/TUI-GUIDE.md) |
| Connect my own agent | [MCP templates](docs/MCP-TEMPLATE.md) |
| Configure and operate Keepers | [Keeper manual](docs/KEEPER-USER-MANUAL.md) · [File model](docs/KEEPER-FILE-MODEL.md) |
| Connect external services | [Keeper identity](docs/KEEPER-IDENTITY-MANUAL.md) |
| Add procedures and skills | [Skills](docs/SKILLS.md) |
| Ask typed questions with a decision model | [`masc_decide` guide](docs/guides/masc-decide.md) |
| Understand runtime settings and prompts | [Configuration](docs/spec/14-configuration.md) · [Environment](docs/ENV-CONTRACT.md) · [Prompt map](docs/PROMPT-MAP.md) |
| Understand the design and next steps | [Specifications](docs/spec/SPEC-INDEX.md) · [Roadmap](ROADMAP.md) |
| Find research, evidence, reports and run output | [Storage guide](docs/guides/WORKSPACE-STORAGE.md) |
| Contribute a change | [Contributing](CONTRIBUTING.md) · [Contributor workflow](docs/guides/CONTRIBUTOR-WORKFLOW.md) · [Agent instructions](AGENTS.md) |

## License

[MIT](LICENSE). Bundled fonts and adapted material have their own
[third-party notices](THIRD-PARTY-LICENSES.md).
