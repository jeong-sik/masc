# Install, use and upgrade MASC

[한국어](INSTALL.ko.md)

## Quick start

One command installs the latest release and opens setup.

```bash
bash -c "$(curl -fsSL https://github.com/jeong-sik/masc/releases/latest/download/install.sh)"
```

It asks where to keep the workspace, then walks through the model connection and
the sandbox. Claude Code and Codex appear when their CLI is on `PATH`, and a
failed connection check can open their sign-in without losing the selection. When
no sandbox service is installed, setup offers to install one: it checks the
vendor's publisher and checksum, then hands the terminal to that installer.

When it finishes, open a new terminal. The installer records `~/.local/bin` in the
shell profile, so `masc` is on `PATH` there. To use it in the same terminal
instead, run `export PATH="$HOME/.local/bin:$PATH"`.

To read the script before running it:

```bash
curl -fsSL https://github.com/jeong-sik/masc/releases/latest/download/install.sh \
  -o /tmp/masc-install.sh
less /tmp/masc-install.sh    # q to exit
bash /tmp/masc-install.sh
```

Piping the script straight into `bash` leaves the setup questions no terminal to
read from, so use one of the two forms above.

The rest of this document is reference material: what is installed, how to choose
a model, how the sandboxes differ, and how to upgrade or uninstall. Check tag
and asset availability on
[GitHub Releases](https://github.com/jeong-sik/masc/releases). Multi-selection
requires 0.35.2 or later.

## Platforms and prerequisites

| OS / CPU | Release asset suffix | Verified on |
|---|---|---|
| Linux x86-64 | `linux-x64` | Ubuntu 24.04 runner + fresh Ubuntu 24.04 container |
| Linux ARM64 | `linux-arm64` | Ubuntu 24.04 ARM runner + fresh Ubuntu 24.04 container |
| macOS Apple Silicon | `macos-arm64` | macOS 14 ARM runner |
| macOS Intel | `macos-x64` | macOS 15 Intel runner |

This table is what CI targets. An install counts as verified only after you
have checked the successful `Release` run for that release and the actual
assets.

The Linux binaries are built inside an Ubuntu 22.04 container, so they need
**glibc 2.35 or newer** — Ubuntu 22.04, Debian 12, RHEL 10 and anything later.
The release fails rather than publishing a binary that asks for more, so this
floor is checked and not merely intended (`scripts/check-glibc-floor.sh`). The
glibc floor is separate from the shared libraries listed below, which each
distribution still has to provide. RHEL 9 ships glibc 2.34 and is below the
floor. Alpine and other musl distributions are not covered, and neither is
macOS older than the versions above. An Intel Mac offers no Apple
Container based microVM, so choose Docker or remote SSH there. Runner names
follow the [official GitHub list](https://github.com/actions/runner-images).

The install script uses Bash, curl, tar, and `sha256sum` or `shasum`.
macOS includes its Python and shared-library runtime; Homebrew and a preinstalled
Python are not required. Linux x64 and ARM64 also include verified Python; the
system libraries below are still required.
OCaml/opam/Dune and Node.js/pnpm are **not needed for a binary install**.

Ubuntu 24.04:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl libffi8 libgmp10 libpq5 \
  libssl3t64 libzstd1 zlib1g libncurses6 libtinfo6
```

Ubuntu 22.04 and Debian 12 name the OpenSSL package `libssl3`, not `libssl3t64`:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl libffi8 libgmp10 libpq5 \
  libssl3 libzstd1 zlib1g libncurses6 libtinfo6
```

macOS requires **macOS 14.0 or later on Apple Silicon** or **macOS 15.0 or later on Intel**. The installer verifies and installs the matching Python and shared-library runtime with the release. It does not install Homebrew or Xcode command-line tools.

The setup screen inspects sandbox services, explains what is missing, and offers to install it. It verifies the vendor's publisher and checksum, then hands the terminal to that vendor's own installer, so its prompts and any administrator password stay in front of you. On supported Apple Silicon Macs it can use Apple Container; Docker is available on macOS and Linux. Model connections require the provider’s subscription or API credit. Claude Code and Codex sign-in can be opened from a failed connection check without losing the selected models.

If startup fails, use the executable path and raw stderr shown by the installer to diagnose it. A signal such as `SIGABRT` alone does not identify a missing library. `--force` refreshes the release files while preserving workspace configuration; it does not make an unsupported OS version compatible.

### PDF evidence inspection

Task and Goal verification can inspect PDF text and rendered pages when the MASC
host has Poppler's `pdftotext` and `pdftoppm`. Poppler is a host dependency; the
portable release archive does not include it.

Open `masc setup`, then choose **PDF document inspection** in **Prepare imp’s
workspace**. Setup shows whether both commands can start and offers an explicit
installation action. On macOS this uses an existing Homebrew installation
([`brew install poppler`](https://formulae.brew.sh/formula/poppler)); on Debian and
Ubuntu it uses `sudo apt-get` to install
[`poppler-utils`](https://packages.debian.org/stable/poppler-utils). Other Linux
distributions require installation through their own package manager. The default
MASC bootstrap does not install Homebrew or PDF tools automatically.

The same action is available without the setup screen:

```bash
masc prerequisite-actions pdf-tools                        # inspect tools and actions
masc prerequisite-actions pdf-tools --execute poppler_install
```

After installation, MASC runs both commands with `-v`. The result describes the
current process environment; it does not claim that a PDF has been inspected or
accepted. If MASC runs as a service, make the tools available on that service's
PATH before requesting PDF verification.

## Install

The quick start above covers a normal install. Name the workspace directly when
you do not want to be asked:

```bash
curl -fsSL https://github.com/jeong-sik/masc/releases/latest/download/install.sh \
  -o /tmp/masc-install.sh
bash /tmp/masc-install.sh --base-path "$HOME/masc-workspace"
```

To install one specific release instead of the latest one, take that tag's
installer and pin it:

```bash
TAG=v0.35.12
curl -fsSL "https://github.com/jeong-sik/masc/releases/download/${TAG}/install.sh" \
  -o /tmp/masc-install.sh
bash /tmp/masc-install.sh --version "$TAG" --base-path "$HOME/masc-workspace"
```

`install.sh` from a tag installs that tag's assets; without `--version` the
installer resolves the latest release.

The installer writes `~/.local/bin` into the shell profile, so a new terminal
finds `masc`. For the terminal you installed from, run
`export PATH="$HOME/.local/bin:$PATH"` separately; that command takes no
installer options.

For a reinstall, append `--force` or `--wizard` to the `bash /tmp/masc-install.sh` command.

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

`--no-wizard` skips model selection. `--provider <id>` selects a configured
provider for automation. The interactive wizard lets you select several
connections and models, then choose which imp should try first and the fallback
order. It stores environment variable names for API credentials, never their values.

## First-install wizard

Use **↑/↓ to move, Space to select several items, and Enter to continue**.
Single-choice screens use Enter. Press `q` to return or cancel. Terminals without
cursor support show numbered choices; enter `1,3` to select multiple items.

The model list comes from your CLI cache, HTTP server, existing workspace
connections, and the installed catalog. Catalog suggestions are checked before
saving: every selected model must return a response and complete a harmless tool
call. On failure, retry, exclude that connection, choose again, or configure later.
Existing connections remain available when you add more models.

| Situation | Behaviour |
|---|---|
| First install on a terminal | Workspace → model connections → sandbox → first conversation, through the installed setup journey |
| Piped input/automation, one usable source | Selects that source; reports a connectivity probe separately |
| Piped input/automation, no usable source or several | Automatic mode leaves selection pending; forced `--wizard` requires `--provider` |
| `--provider <id>` | Selects that configured provider, including in an existing workspace |
| `--no-wizard` | Skips model selection; cannot be combined with `--provider` |
| Regular upgrade with existing configuration | Preserves selections; use `--wizard` to choose again |

```bash
bash /tmp/masc-install.sh --version "$TAG" \
  --base-path "$HOME/masc-workspace" --wizard
```

`masc setup` checks the selected model again before preparing imp. A successful
model/tool check is not proof that Docker or the full Keeper sandbox is ready;
setup reports those stages separately. In scripted provider selection,
`MASC_INSTALL_NO_PING=1` skips the provider connectivity probe. It does not turn a
model into a verified connection. `--sandbox` is used with `--team` and does not
change existing Keeper configurations in bulk.

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

The **installed binary** provisions one `imp` with `activation_mode = "manual"` and the
`browser-lanes` skill. That `imp` defaults to the Docker sandbox and is
started by hand once a model and an execution environment are ready. The
installer takes its configuration from the binary. The instructions are a starting point; edit them directly. Model weights,
model CLIs, API keys, Docker, Apple Container, SSH servers,
browsers/extensions, Slack/Discord accounts, and autostart services are not
installed. Detecting which execution environments are available does not
stand in for installing or authenticating them.

## Choosing a model connection

AWS Bedrock and GCP/Vertex connections are TODO items for a later release.
They are outside this installation and verification scope.

Select existing API providers, Claude Code, Codex, or local Ollama models.
Use **Add another server URL** for llama.cpp, vLLM, another OpenAI-compatible
server, or Ollama on another computer. Existing Antigravity connections remain
listed, but a runtime without a supported real verification adapter cannot pass
the interactive readiness check.

The wizard reads context windows from model metadata or the exact connection's
existing declaration. For a fresh Codex home, it reads the installed CLI's bundled
model catalog without authentication or a model call. API catalog suggestions
do not supply a Codex context limit; model availability is checked separately. For Ollama it reads the configured or running context and
loads only selected models when needed; it does not allocate the architectural
maximum. For a single-model llama.cpp server it can read the configured context
from `/props`. An unknown limit offers model selection again or an advanced field
for the documented server limit. No tool-support questionnaire is required.

Several models can be registered together. Choose the primary model and each
fallback in order. This order applies to the conversation lane; internal exact-output
helper lanes use the primary model. Other Keepers with explicit assignments keep
their assignments. Selecting the same connection again reuses it; changing its
model or connection settings creates a separate declaration.

The same binary validates a staged configuration and verifies every selected
connection before publishing. Validation or verification failure preserves the
existing files. Credentials use the selected shell, CLI account or private credential
store. Offered installation and sign-in actions run only when selected; model
weights are not downloaded automatically. **Configure later** defers model setup;
imp does not start automatically.

## First conversation with `imp`

Run `masc`. No `MASC_BASE_PATH` export is needed. With no saved workspace,
select the suggested `~/MASC` directory with Enter, or choose another location.
The directory is created only after you select it. Explicit `--base-path` and
existing environment configuration still take precedence over the saved default.

The setup journey then asks for model connections and a sandbox. You can select
several models and choose their fallback order. For Claude Code or Codex, a failed
connection check offers official sign-in and retry with the same selections.
Each selected model must complete an actual response and tool check before saving.

The sandbox screen shows service observations, missing prerequisites and advanced
choices. Choosing a service that is not ready opens the installation and startup
actions available for this computer; `masc prerequisite-actions <service>` lists
the same actions as JSON. A running service still needs image preparation and imp boot. The quick
path permits internet access for guest commands when choosing a new backend.
Selecting the currently configured backend preserves its network policy; Advanced
setup can explicitly change it. Disabling guest networking affects sandbox commands.
MASC model connections and WebFetch use separate server-side network controls.

```bash
masc setup                     # reopen connection and sandbox selection
masc doctor                    # read-only preparation report
masc sandbox-catalog           # inspect host sandbox choices as JSON
```

Preparation uses the selected backend, validates it before saving the selection,
and starts or connects to the server for this workspace. It creates a local
operator credential and starts `imp`. Later, bare `masc` opens the saved imp
history without repeating model selection; the UI observes its current server
and execution state separately. A persisted history does not prove that the
current account or sandbox is usable.

For automation, supply the workspace and selections explicitly. For example:

```bash
masc setup --base-path "$HOME/masc-workspace" --no-tui \
  --sandbox-profile docker --network-mode inherit
```

The prepared server stays running when you leave the setup journey. If another
workspace occupies the port, choose a free one with `--port 8936`. Model choices
survive sign-in/retry within the current wizard session. Choosing “Finish later”
preserves committed configuration; unverified selections have not been saved.

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
| Linux + Docker | Install and start the Docker daemon, from setup's actions or on your own, then run `masc sandbox-image` | Server install and image creation/tool execution are checked separately |
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
extension 0.5.0 or later. Update an existing browser extension separately.

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
release. Pushing a `vX.Y.Z` tag to a verified commit publishes the GitHub
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

### Existing workspace needs attention

`masc setup` checks existing Keeper profiles and Goal state before initializing the
workspace, preparing Docker, signing in, or starting a server. If a file cannot
be read with the current schema, setup prints its actual path and decoder error
and stops without rewriting the workspace. A preserved file from an older
release is not proof that the new version can read it.

Choose one of these paths:

- Start separately: choose an unused directory and run
  `bash /tmp/masc-install.sh --version "$TAG" --base-path "$HOME/masc-new-workspace" --wizard`
  with the verified installer downloaded above. After selecting your runtime, run
  `masc setup --base-path "$HOME/masc-new-workspace"`. Your original workspace remains available for review.
- Return without changes: stop setup, keep the original files, and review the
  reported paths with the `Fresh state required` entry in `CHANGELOG.md`.
  Existing logs are under the original workspace's `.masc/logs` directory.
  Rerun setup on that workspace only after you have intentionally repaired it.

Setup does not delete old Goal files, restore recovery mirrors, or silently
convert Keeper settings. It does not claim readiness for the stopped workspace.
