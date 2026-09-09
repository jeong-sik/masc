# Install, use and upgrade MASC

[한국어](INSTALL.ko.md)

This document is the installation contract for **0.35.0**. Check tag and asset
availability on [GitHub Releases](https://github.com/jeong-sik/masc/releases).
The download commands below select `v0.35.0` and its matching installer.

## Platforms and prerequisites

| OS / CPU | Release asset suffix | Verified on |
|---|---|---|
| Linux x86-64 | `linux-x64` | Ubuntu 24.04 runner + fresh Ubuntu 24.04 container |
| Linux ARM64 | `linux-arm64` | Ubuntu 24.04 ARM runner + fresh Ubuntu 24.04 container |
| macOS Apple Silicon | `macos-arm64` | macOS 14 ARM runner |
| macOS Intel | `macos-x64` | macOS 15 Intel runner |

This table is what CI targets. An install counts as verified only after you
have checked the successful `Release` run for that release and the actual
assets. Alpine/musl, Linux with an older glibc, and macOS older than the
versions above are not covered by these binaries. An Intel Mac offers no Apple
Container based microVM, so choose Docker or remote SSH there. Runner names
follow the [official GitHub list](https://github.com/actions/runner-images).

The install script uses Bash, curl, Python 3, and `sha256sum` or `shasum`.
OCaml/opam/Dune and Node.js/pnpm are **not needed for a binary install**.
The shared libraries have to be installed on the OS.

Ubuntu 24.04:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl python3 libffi8 libgmp10 libpq5 \
  libssl3t64 libzstd1 zlib1g libncurses6 libtinfo6
```

macOS ([Homebrew installation requirements](https://docs.brew.sh/Installation)):

```bash
brew install python gmp libpq openssl@3 zstd
```

The improved macOS installer checks the OS version and the Homebrew runtime
dependencies before downloading, and installs only the packages that are
missing. On a terminal without Homebrew it hands over to the official Homebrew
installer and goes through that program's confirmation and password prompts.
A noninteractive run needs Homebrew prepared beforehand. `--dry-run` installs
no packages. Linux system packages are prepared with the command above.

On macOS the Homebrew library path is the default prefix for that CPU. An
environment linked to another prefix, such as Intel Homebrew on Apple Silicon,
is told the cause before the download. If the binary still does not start
after the packages are installed, the installer shows the executable's raw
stderr right away.

### `SIGABRT` or `build-commit` failure on macOS

`SIGABRT` is the signal the process exited with, and by itself it does not say
why. Check the raw stderr, such as `dyld: Library not loaded`, and the path of
the executable that failed. The exit signal alone does not establish that a
library is missing.

The minimum supported OS is **macOS 14.0** on Apple
Silicon and **macOS 15.0** on Intel. Prepare the dependencies in the default
Homebrew prefix for that CPU (Apple Silicon `/opt/homebrew`, Intel
`/usr/local`).

```bash
brew install python gmp libpq openssl@3 zstd
sw_vers -productVersion
uname -m
```

`otool -L <failed-executable>` shows the library paths actually linked. If it
still aborts after the dependencies and OS requirements are met, report the
exit signal together with the raw stderr. `--force` is a re-download option
and does not fix loader or OS compatibility problems.

## Install

```bash
TAG=v0.35.0
curl -fsSL "https://github.com/jeong-sik/masc/releases/download/${TAG}/install.sh" \
  -o /tmp/masc-install.sh
bash /tmp/masc-install.sh --version "$TAG" --base-path "$HOME/masc-workspace"
```

After installation, run this separate command to update PATH in the current terminal.

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Optional inspection: run `less /tmp/masc-install.sh` before installation. Press `q` to exit, then run the `bash` installation command above.

For a reinstall, append `--force` or `--wizard` to the `bash /tmp/masc-install.sh` command. The separate `export PATH=...` command takes no installer options.

`--prefix` defaults to `$HOME/.local/bin`. A first install on a terminal asks
for the workspace path that will hold `.masc`. For a new workspace it
suggests `$HOME`, so accepting that creates the data in `.masc` under that
workspace. If the current directory already has a `.masc/config`, it suggests
that workspace. An explicit `--base-path` is used without asking, and a
noninteractive run or `--no-wizard` keeps the current directory. `.masc` is
created under the given base path. The install location and the working-data
location are independent. The `install.sh` on the release page installs that
version's assets, and installer fixes are recorded in the release notes with
their source commit. The binary tag is not changed. A missing or mismatched
checksum stops the install.

`--no-wizard` skips model selection. `--provider <id>` selects from the
provider catalog in `runtime.toml`. The wizard detects the model servers that
are available and the sign-in state of CLIs, selects `[runtime].default`, and
stores no API key. Without a model, installing the server and using the status
screens still works.

## First-install wizard

The wizard menu shows each provider's name, its current detection state, and
the ID to use with `--provider`. Choose by number, or press Enter for the
default shown. An invalid number is asked again, and a closed input cancels
the selection.

| Situation | Behaviour |
|---|---|
| First install on a terminal | Shows the provider menu and saves the choice |
| Piped input/automation, one usable source | Selects that source |
| Piped input/automation, no usable source or several | Automatic mode leaves the choice pending; with `--wizard` forced, `--provider` is required |
| `--provider <id>` | Selects that provider, in an existing workspace too |
| `--no-wizard` | Skips model selection and the connectivity check; cannot be combined with `--provider` |
| Regular upgrade with existing configuration | Keeps the existing choice; `--wizard` to choose again |

You can choose again with the script of the installed tag. Export a new API
key in the shell that starts the server, and keep in mind that a server
already running does not pick it up on its own.

```bash
bash /tmp/masc-install.sh --version "$TAG" \
  --base-path "$HOME/masc-workspace" --wizard
```

In provider detection, `cloud` proves neither that the API key is valid nor
that the model answers. A CLI is checked with its own login probe, and an
unsupported probe is marked separately. HTTP providers call the healthcheck
declared in the catalog. Without a credential or a healthcheck, the check is
reported as skipped. Passing the connectivity check is not evidence of actual
model generation, tool execution, or sustained Keeper runs either. In
automation, `MASC_INSTALL_NO_PING=1` skips only the post-install connectivity
check; the wizard's local server detection still runs. To skip all wizard
detection, use `--no-wizard`. `--sandbox` is used together with `--team` and
does not change existing Keeper configuration in bulk.

## Default installed contents

| Location | Contents / purpose |
|---|---|
| `<prefix>/masc` | HTTP/MCP server and the CLI for configuration, login, and Keeper management. Run on a terminal, it opens the TUI |
| `<prefix>/masc-tui` | Terminal UI for Keepers, chat, tasks, the board, approvals, and logs |
| `<prefix>/masc-browser-host` | Executable for the Firefox-family native messaging connection. Installing it alone does not register it with the browser |
| `<prefix>/masc-deployment-preflight-helper` | Helper binary for the execution-environment preflight |
| `<prefix>/masc-check-runtime-deployment-preflight` | Script that runs the preflight |
| `<prefix>/.masc-releases/<receipt-hash>/` | Dashboard from the same commit as the server, the server executable, and the verification receipt |
| `<base-path>/.masc/config/` | Embedded runtime/model overlay and the default configuration seed. Tools and prompts used in operation are managed from the embedded assets as well |
| `<base-path>/.masc/microvm/shim/` | exec shim for Linux guests and its SHA256 sidecar. Can be skipped with `--no-guest-shim` |

The **0.35.0 binary** installs one `imp` with `activation_mode = "manual"` and the
`browser-lanes` skill. That `imp` defaults to the Docker sandbox and is
started by hand once a model and an execution environment are ready. The
installer takes its configuration from the binary. The instructions are a starting point; edit them directly. Model weights,
model CLIs, API keys, Docker, Apple Container, SSH servers,
browsers/extensions, Slack/Discord accounts, and autostart services are not
installed. Detecting which execution environments are available does not
stand in for installing or authenticating them.

## Choosing a model connection

Besides the existing API and Ollama settings, the terminal wizard offers
**llama.cpp, vLLM, Claude Code, Codex, Antigravity** and a generic
**OpenAI-compatible endpoint**. An option stays on the list even when the
tool is not installed, and a local server may point at an endpoint on
another machine.

Only the connection you pick is added. For Claude Code and Codex, enter the
model id; the installed model catalog supplies its context size when known,
and the CLI connection enables tools and streaming without a capability quiz.
An unknown model still asks for its context size. For HTTP connections, enter
the context size and explicitly confirm tool calling and streaming supported
by your server. The HTTP capability overlay applies only to that provider.
API credentials are environment variable names, never values; the seeded Z.AI
connection reads `ZAI_API_KEY` from the shell that starts MASC.

The setting is written only after it passes the same binary's runtime check
in a temporary workspace. If that check fails, or the original changes
underneath, the existing setting is kept. When a connection for the same
setup already exists, pick that provider or edit the TOML rather than
creating a duplicate.

**A validated setting, an installed CLI, a reachable HTTP endpoint, an
authenticated account, and a model that actually answers are five different
states.** This wizard installs no model server, model weights, or provider
CLI, and authenticates no account. Antigravity additionally needs the path
to the OAuth file its CLI wrote, and a request timeout. `Configure later`
defers the model connection, and the default Keeper does not start on its
own. To run this again in an existing workspace, use `--wizard`.

## First conversation with `imp` (0.35.0)

This is the 0.35.0 installation contract. Check the release tag and asset
availability on [GitHub Releases](https://github.com/jeong-sik/masc/releases) before downloading.

1. Run the installer wizard with `--base-path "$HOME/masc-workspace"` and select
   the model runtime you own. Runtime setup binds that selection to the helper
   lanes with `--setup-lanes`; you do not need a second model subscription.
2. Authenticate that runtime before starting MASC. For Claude Code or Codex,
   install its CLI and complete its own login, then confirm it can answer a
   prompt in this terminal. For an API runtime, export the credential variable
   named by the wizard in this terminal. For a local model, start its server
   and load a model that supports tool calls. MASC does not install or log in
   to these model runtimes.
3. Install and start [Docker Desktop on macOS](https://docs.docker.com/desktop/setup/install/mac-install/),
   or [Docker Engine on Linux](https://docs.docker.com/engine/install/).
   `docker info` must succeed as your current user. Then run:

```bash
masc setup --base-path "$HOME/masc-workspace"
```

`setup` seeds missing configuration, checks Docker, builds the default sandbox
image, starts or connects to the server for this workspace, logs in as
`local-admin`, starts the existing `imp`, and opens the TUI. It preserves the
Keeper manifest. The default `imp` has `activation_mode = "manual"`,
`sandbox_profile = "docker"`, and `network_mode = "inherit"`.
If another workspace occupies the port, choose a free one with `--port 8936`.
On exit, setup stops a server it started itself. Use `--no-tui` to leave that
server running and connect to it separately.

In the TUI, select **Keepers → imp** and send these requests one at a time:

- “Hello. Please reply so I can check our conversation.”
- “Create a Board post titled First conversation and show its id.”
- “Create a Task titled Explore my sandbox, with a description, and show its id.”
- “Run `pwd` and `ls` in your sandbox and show the directory listing.”
- “Use WebFetch to retrieve https://example.com now and report the HTTP status and title.”

Confirm the reply, persisted Board post and Task, and successful sandbox and
web tool results. This checks conversation and basic capabilities; Task
completion is a separate workflow. Web fetch does not require a search API
key; web search needs its own configured search provider. If a tool is waiting
for approval, inspect its pending request in the chat or **Approvals** view.
Do not interpret a pending request or a listening HTTP server as successful
model inference or tool execution.

For an MCP-only server, use `masc start --base-path "$HOME/masc-workspace"` and follow the [client setup](../README.md#mcp-client-setup).

## Images and the Linux/microVM boundary

The install script neither downloads nor builds a sandbox image.
`masc sandbox-image` embeds the **recipe** for the general image, and the
first build needs network access to fetch the Debian base image and packages.

| Execution environment | Preparation | Verification scope |
|---|---|---|
| Linux + Docker | Install and start the Docker daemon separately, then run `masc sandbox-image` | Server install and image creation/tool execution are checked separately |
| Apple Silicon + Apple Container | macOS 26 and `container` installed, then a build naming the runtime below | Passing the macOS 14 server CI alone does not prove this backend |
| Linux + nerdctl/Kata | containerd/nerdctl/Kata with virtualization support, an explicit backend, and an image created in that store | Work volume created idempotently and confirmed with inspect; real Kata verification needed, policy networking not supported |
| remote SSH | A remote endpoint with authentication, shim, and tools prepared | A remote environment independent of the local Docker/microVM images |

```bash
# image store for Docker Keepers
masc sandbox-image

# separate image store for Apple Container Keepers
masc sandbox-image --runtime apple_container

# separate image store for nerdctl/Kata Keepers
masc sandbox-image --runtime nerdctl_kata
```

On Linux, create the Keeper with the same base path as the running server.
First prepare the Kata runtime and image above and the server's model
configuration, and sign in with an admin credential. The CLI passes the
selected backend to the server, and it is stored in the Keeper TOML.

```bash
masc keeper-create --base-path "$HOME/masc-workspace" \
  --agent local-admin --name linux-worker \
  --sandbox-profile microvm --microvm-backend nerdctl_kata \
  --network-mode none --activation-mode manual \
  --instructions "Carry out the assigned task and report the execution results and evidence."
```

`--microvm-backend` is valid only with `microvm`. Omitting it keeps the
existing backend, and a new Linux Keeper has no host default, so it has to be
named. Given together with `--edit`, it is refused as a conflict, like the
other declaration flags.

Changing `--runtime` alone installs no hypervisor or daemon. Building directly
with `--runtime nerdctl_kata` also needs
[nerdctl's BuildKit setup](https://github.com/containerd/nerdctl/blob/main/docs/build.md).
Having only containerd and Kata running does not mean the image build is
ready. An image in the Docker store is not copied to the Apple
Container/nerdctl store automatically. On Linux, nerdctl/Kata creates a
persistent named volume in that runtime and confirms its name and mountpoint
with inspect. Recreating the guest attaches the same volume. This store is a
managed directory on the host and differs from Apple's guest ext4 disk.
`MASC_KEEPER_MICROVM_WORK_VOLUME_SIZE` is not enforced by nerdctl, and the
space actually available follows the host filesystem. This difference is
shown in the boot log. Host descriptor characteristics measured on Apple are
not guaranteed to be the same on Linux. Use `network_mode=none` or `inherit`;
`policy` is not supported on Linux. `scripts/smoke-nerdctl-kata-volume.sh`
checks Kata's volume and isolation. To verify as far as an installed Keeper,
set `release_run` of the `Kata volume smoke` workflow to the run number of a
Release whose Linux x64 job succeeded. That path installs that release's
binary and shim and confirms image creation, Keeper tool execution, the
canonical checkpoint, and file preservation after guest recreation. Passing
the plain volume check alone does not guarantee that an installed Keeper runs.
[Apple Container](https://github.com/apple/container#requirements) supports
Apple Silicon and macOS 26, and
[Kata](https://github.com/kata-containers/kata-containers/blob/main/docs/installation.md)
requires checking the host's virtualization requirements. Microsandbox's
current MASC integration is constrained on the required isolation conditions
and is not offered as a verified alternative.

`masc-sandbox:general` contains bash, CA certificates, curl, findutils, gh,
git, less, procps, Python 3, and ripgrep. **Node, pnpm, OCaml, compilers, an
SSH client, and model CLIs are not included.** To build and test a project,
prepare an image with the toolchain it needs and name it in the Keeper's
`sandbox_image`. The repository's `Dockerfile.keeper-sandbox` is a separate
image for MASC development, not part of a regular install.

## Initial prompts, skills, and Keepers

The default installation prepares **one Keeper, `imp`, that does not start on its own** and the
built-in skills `browser-lanes`, `browser-design`, `frontend-implement`,
`frontend-verify`, and `evidence-review`. Configure a model and a sandbox,
then start the Keeper.

Task and Goal verification agents can also read the instruction Skills
published in the workspace through `keeper_skill`. The default
`evidence-review` walks through comparing the contract, the execution log,
and the revision. A Skill supplies a way to look things up; it grants no new
tool and no execution permission. With no Skill installed, verification
continues with the existing evidence lookups.

For prompts, there are only three places to tell apart.

| What you want to change | Where to edit |
|---|---|
| How every Keeper works, verifies, and writes | `keeper` in the prompt editor |
| One Keeper's role | `instructions` in `.masc/config/keepers/<name>.toml` |
| The detailed procedure for one tool | That skill |

The shared body is provided in [Korean](../config/prompts/keeper.md) and
[English](../config/prompts/keeper.en.md). Open `keeper` in the prompt editor
and choose **한국어 / English** to switch the draft. Check the content, then
press **오버라이드 적용** (apply override). An unsaved draft has to be saved
or reset before another language can be chosen. The language choice changes
only the shared behaviour guidance. The situational slots and tool schemas are
shared, and it does not force a change to an individual Keeper's role
instructions or answer language.

Everything under `###` in `config/prompts/keeper.md` is a slot the runtime
renders when it is needed. It does not send both language bodies at once, nor
put all of these slots into every turn. Write the shared behaviour rules once
in the body, and put only the assigned duties in the role instructions.

The installed `.masc/config/prompts/` is the distributed copy. The server
aligns it with the embedded copy at start, so do not edit it directly. What
you save in the editor is kept in `.masc/prompt_overrides.json` and applied
to the prompts composed from then on. A valid override takes precedence over
the distributed copy even after an upgrade, so to use the new default
guidance, choose that language again in the editor and save, or clear the
override. A slot override such as `keeper.identity` is a separate entry too.

There is no need to restore a whole preset just to change the language. Use
presets to save and restore the roles, prompts, and model assignments of
several Keepers together. `constitution.xml` is a development contract, not a
Keeper's system prompt.

`browser-lanes` holds the procedures for connecting to, navigating,
controlling, and verifying a browser. It does not install a browser, an
extension, or authentication. An existing skill package is not overwritten,
so on upgrade compare your changes with the new guidance and merge them in.
The Gecko scene features need the native host together with browser
extension 0.4.0 or later. Update an existing browser extension separately.

Choosing `--team classic` adds the following four Keeper TOMLs.

| Keeper | Role in its own instructions |
|---|---|
| `tech_lead` | Breaks down requirements, distributes roles, reviews diffs/evidence |
| `backend` | Backend implementation and verification |
| `frontend` | Frontend implementation and verification |
| `qa` | Tests and verification against the requirements |

This preset uses `activation_mode="autonomous"`, `sandbox_profile="docker"`,
and `network_mode="inherit"`, and follows the default model. Role instructions
do not install compilers, credentials, or additional skill packages.

The skill search path is declared by `[[skills.sources]]` in `runtime.toml`.
The default order is `<base-path>/.masc/skills`, `<base-path>/.agents/skills`,
`<user-home>/.masc/skills`, `<user-home>/.agents/skills`.
Even when the install is empty, **user skills that already exist can be found**.
Each skill consists of `<name>/SKILL.md` and the resources it needs, and the
selection is stated with `--skill` or `--no-skills` when the Keeper is
created. Not every skill installed for Codex/Claude is copied to MASC
automatically.

## Upgrade and recovery

Download the `install.sh` attached to the release again, then run it with the
same prefix/base path as before.

```bash
bash /tmp/masc-install.sh --version "$TAG" \
  --base-path "$HOME/masc-workspace" --force --no-wizard
```

From 0.34.0, `--force` updates the binaries and preserves the existing
runtime configuration, model choice, and Keeper files. In a workspace that
already has the runtime and model overlay, it only adds new embedded skills
and leaves the existing configuration and any optional configuration files
the user deleted as they are. In a new install or a workspace without the
required configuration, it seeds the defaults. Add `--reset-config` only when
the goal is to reset the configuration. That option overwrites the seeded
configuration and the selected team files, so keep a separate copy of your
configuration before using it.

The server/dashboard and the companion executables in the prefix are restored
to their previous state when an install fails. The workspace's guest shim and
configuration you explicitly reset are not part of this prefix transaction.
If the process was killed and a `.masc-install-transaction` is left behind,
see the [distribution transaction guide](design/installed-dashboard-distribution.md).

Some releases change a state file's contract instead of converting the old
file. The `Fresh state required` entries in `CHANGELOG.md` list those files.
Delete or rewrite them before the new server starts. Otherwise the boot log
reports the file as undecodable, and the surface that reads it (Keeper
profiles, Goals) stays empty or returns that error until you do.

A running server is not replaced by the install alone. Wind down the work in
progress, restart the server, and check `masc --version`, `/health?full=1`,
and the dashboard again. To go back to an earlier version, use that tag's
install script as well. An earlier version's `--force` may reset the
configuration too, so it needs a configuration backup and
`--no-seed --no-wizard`. Earlier release directories are kept for running
processes and for recovery.

## Release verification

The `Release` workflow builds all four native targets as required jobs and
runs a checksum-verified `file://` install → config seed → installed server
health → dashboard verification. On Linux it runs the same install in a fresh
Ubuntu container without an OCaml development environment as well. It also
confirms that the dynamic loader works by running `--help` on the TUI and the
browser host. On the Linux native runner it also runs a first-turn
verification: it creates a new Keeper with the installed executables and runs
the tool a local model fixture requested in real Docker. It passes only if
the ToolResult comes back in the next model request and the host files match
the durable checkpoint. Model quality, real API authentication, and long
continuity are not proven by this fixture. The `keeper-create` CLI's
successful exit and its exit on refused authentication are checked separately
as well.

`workflow_dispatch` is for verifying branch artifacts and creates no public
release. Pushing the `v0.35.0` tag to a verified commit publishes the GitHub
Release and `SHA256SUMS` after the four builds and asset verification. The
tag, CI success, the actual release assets, and the result of running after
install each have to be checked on their own.

## Uninstall

Stop the running MASC server and TUI, then use the latest installer
downloaded from the release. The default uninstall deletes only the programs
and the dashboard, and preserves configuration, Keepers, records, and the
Homebrew dependencies.

```bash
bash /tmp/masc-install.sh --uninstall --dry-run
bash /tmp/masc-install.sh --uninstall
```

If you gave `--prefix` at install time, give the same value when
uninstalling. Uninstall runs without network, Python, or Homebrew and does
not delete the prefix directory or other files. If an interrupted install
transaction is left behind, it fails with an error asking you to recover that
first.

To remove the data as well, you have to name **the workspace path you
actually installed into**. The example below deletes `.masc` under that
workspace. If you chose HOME as the workspace, that is `--base-path "$HOME"`.
Do not pass the `.masc` directory itself as the base path.

```bash
bash /tmp/masc-install.sh --uninstall --purge-data \
  --base-path "$HOME/masc-workspace" --dry-run
# check what will be deleted, then run without --dry-run
```

A `.masc` or distribution-directory symlink that points elsewhere has only
the link itself deleted.
