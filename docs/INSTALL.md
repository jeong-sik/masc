# Install, use and upgrade MASC

[한국어](INSTALL.ko.md)

This document is the installation contract for **0.34.0**. The latest published
version is on [GitHub Releases](https://github.com/jeong-sik/masc/releases/latest).
The `v0.34.0` downloads below point at the tag published on 2026-09-08. Where a
`main` source build differs from 0.34.0 (the default Keeper `imp`), the body
notes it separately.

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

The Mach-O minimum OS of the 0.34.0 release files is **macOS 14.0** on Apple
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
TAG=v0.34.0
curl -fsSL "https://github.com/jeong-sik/masc/releases/download/${TAG}/install.sh" \
  -o /tmp/masc-install.sh
less /tmp/masc-install.sh
bash /tmp/masc-install.sh --version "$TAG" --base-path "$HOME/masc-workspace"
export PATH="$HOME/.local/bin:$PATH"
```

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

The published **0.34.0 binary** creates no default Keeper and installs the
`browser-lanes` skill. A `main` source build after the freeze seeds one `imp`
with autoboot off. The release installer takes its configuration from the
binary, so updating the installer alone does not change the 0.34.0 roster.
The instructions are a starting point; edit them directly. Model weights,
model CLIs, API keys, Docker, Apple Container, SSH servers,
browsers/extensions, Slack/Discord accounts, and autostart services are not
installed. Detecting which execution environments are available does not
stand in for installing or authenticating them.

## First run and what you can do

```bash
masc --base-path "$HOME/masc-workspace"
```

On a terminal this opens the TUI and starts the server when nothing is on the
port. To run only the HTTP server, use the following command.

```bash
masc start --base-path "$HOME/masc-workspace"
```

The server runs in the foreground. Check its state from another terminal.

```bash
curl http://127.0.0.1:8935/health
curl 'http://127.0.0.1:8935/health?full=1'
```

A `/health` response means the HTTP listener is open. Before creating the
first Keeper, also check that `startup.state_ready` in the full health is
`true`. Early in boot the listener answers first while internal state
initialization may still be in progress.

Open `http://127.0.0.1:8935/dashboard/` in a browser. The dashboard picks the
installed bundle on its own, so there is no need to start from a source
directory. Set up write access as described in the
[authentication guide](LOCAL-DASHBOARD-AUTH-RUNBOOK.md).

MCP clients connect to `http://127.0.0.1:8935/mcp` with a bearer. Use the
`masc login ... --shell` command the install script prints and the
[client setup](../README.md#mcp-client-setup).
External agents can register and claim tasks and share goals, board posts,
comments, and execution evidence. In that case an external agent uses its own
model, even with no model connected to MASC itself.

To run a Keeper, prepare both a model source and a tool execution environment.

1. Select a model in `runtime.toml`. For an API provider, export its credential
   environment variable in the shell that starts the server. For a CLI
   provider, install that CLI separately and sign in.
2. For Docker, start the Docker daemon and prepare the default execution image
   with `masc sandbox-image`. microVM/remote SSH each need their own backend
   configuration.
3. Create a Keeper from the TUI Keepers screen or with `masc keeper-create --help`.
   For a preconfigured team, use `--team classic --sandbox docker` at install
   time. The team files boot their Keepers automatically at the next server
   start, so prepare the model and sandbox first.

With the server running and the Docker image and model prepared, you can
create the first Keeper explicitly from another terminal. `login` and
`keeper-create` use the same base path, agent, and host/port.

```bash
masc login --base-path "$HOME/masc-workspace" --host 127.0.0.1 --port 8935 \
  --agent local-admin --role admin --no-expiry --json
masc keeper-create --base-path "$HOME/masc-workspace" --host 127.0.0.1 --port 8935 \
  --agent local-admin --name scout --sandbox-profile docker --network-mode none \
  --no-skills --no-autoboot --no-proactive \
  --instructions 'Carry out the given task and report with actual tool results as evidence.'
```

The create request boots the Keeper immediately. `--no-autoboot` turns off
automatic boot at later server restarts, and `--no-proactive` turns off
self-initiated activity. Send `scout` a task from the TUI or the dashboard.
The `none` in this example blocks the guest's outbound network, so web and
remote Git work needs a network setting that fits the task, such as
`inherit`. Running it again with the same name reconfigures the existing
Keeper.

If the first tool run waits, check the pending tool approval in the chat and
answer it. Tool approval in the Keeper chat (Auto/Yolo and per-tool approval)
is separate from the workspace Gate's `auto_judge`/`manual` and from the
external-service approval path. Setting the per-Keeper Gate to `always_allow`
does not relax the workspace's `auto_judge`. Check each approval state so that
a pending approval is not mistaken for a model connection or install failure.

A Keeper runs turns with the configured model, executes tools in the sandbox,
and collaborates through tasks, the board, and chat. Scheduled runs, approval
judgement, external connectors, and browser control need their
runtime/credential/backend configuration. The browser follows the separate
[native host connection guide](../connectors/browser/host/README.md).
The server install smoke does not prove model responses or long sustained
Keeper runs.

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
  --network-mode none --no-autoboot --no-proactive \
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

The published 0.34.0 binary creates no Keeper and prepares only the built-in
skill `browser-lanes`. A `main` source build after it, and the next release,
also prepare **one Keeper, `imp`, that does not start on its own** and the
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
Choosing `--team classic` adds the following four Keeper TOMLs.

| Keeper | Role in its own instructions |
|---|---|
| `tech_lead` | Breaks down requirements, distributes roles, reviews diffs/evidence |
| `backend` | Backend implementation and verification |
| `frontend` | Frontend implementation and verification |
| `qa` | Tests and verification against the requirements |

이 preset은 `activation_mode="autonomous"`, `sandbox_profile="docker"`,
`network_mode="inherit"`를 사용하고 fleet 기본 모델을 따릅니다. 역할 지침은
컴파일러나 인증을 설치하지 않으며 개별 `skills` 패키지도 추가하지 않습니다.

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
release. Pushing the `v0.34.0` tag to a verified commit publishes the GitHub
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
