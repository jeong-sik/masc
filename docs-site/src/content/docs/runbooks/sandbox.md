---
title: Keeper Sandbox
description: Isolating a Keeper's tool commands with Docker, microVM, or remote SSH.
---

A Keeper's shell commands run isolated, not on your host. There is no host
profile: a Keeper declared without an accepted `sandbox_profile` is refused at
boot, so a Keeper cannot start until you pick one.

## Isolation backends

- **`docker`** — runs the Keeper's tools inside a container. Needs Docker installed
  and its daemon running.
- **`microvm`** — runs them behind a hypervisor boundary, so an escape has to
  cross the hypervisor rather than a shared kernel. Three runtimes speak this
  profile; see below.
- **`remote_ssh`** — runs them on a remote host declared under
  `[exec.ssh.endpoints]` in `runtime.toml`, selected with `remote_endpoint`.

## Which microVM runtime

`microvm` is a profile, not a program. MASC drives one of three:

| Backend | Runtime | Where it fits |
| --- | --- | --- |
| `apple_container` | Apple's `container` CLI | macOS 26+. The only backend that carries `network_mode = "policy"` today. |
| `microsandbox` | `msb` | Linux and macOS. Guest users are named, not numeric uid:gid, and the work volume is directory-kind. |
| `nerdctl_kata` | `nerdctl` with the Kata runtime | Linux, where Kata containers are already the isolation story. |

On macOS the default is `apple_container`, chosen by looking for
`/System/Library/CoreServices/SystemVersion.plist`. **On Linux there is no
default** — name the backend explicitly, or the Keeper has no microVM runtime to
start.

## The sandbox image

MASC ships no image. Build the general one once:

```bash
masc sandbox-image
```

`masc-sandbox:general` is Debian slim carrying `bash` (a turn is run as
`bash -l -s`), `ripgrep` (the Grep tool refuses without `rg`), `git`, `curl`,
`ca-certificates`, `less`, `procps` and `findutils`. Nothing beyond that is
assumed: a project's own toolchain belongs in that project's image, named per
Keeper with `sandbox_image`.

The recipe lives inside the binary and is piped to `docker build -` with no
build context, so it builds the same on a host that never had a checkout.
`masc sandbox-image --print` writes the Dockerfile to stdout instead of
building. `MASC_KEEPER_SANDBOX_DOCKER_IMAGE` overrides the default tag for both
the `docker` and `microvm` guest paths.

## Configuration

`masc keeper-create` writes these fields for you (`--sandbox-profile` and the
required `--network-mode`). The resulting `<base-path>/.masc/config/keepers/<name>.toml`
looks like:

```toml
sandbox_profile = "docker"   # "docker" | "microvm" | "remote_ssh"
network_mode = "none"        # "none" | "inherit" | "policy"

# only for sandbox_profile = "remote_ssh":
# remote_endpoint = "worker-node-1"
```

`network_mode` is separate from the profile and is required. `none` gives the
guest no network at all — a Keeper that does web search or `git push` needs
`inherit`. `policy` is the mode between the two: the guest reaches an allowlist
proxy this server owns and nothing else (today only the `apple_container`
microVM backend carries this mode). The default for `docker` and `microvm`
is `none`, which is why `masc keeper-create` refuses to proceed without the
flag rather than choosing for you.

---

## Switching Isolation Backends in TUI

You can reconfigure a Keeper's sandbox backend on the fly directly inside `masc-tui` without editing raw TOML files:

1. Press `Tab` to navigate to **Keepers**.
2. Select the target Keeper and press `Enter` to open the **Detail View**.
3. Use `[` / `]` to switch to the **`Sandbox`** tab.
4. Press a single shortcut key to change the isolation profile:
   - **`d`**: Switch immediately to **Docker** container isolation
   - **`m`**: Switch immediately to **MicroVM** hypervisor isolation
   - **`s`**: Switch immediately to **Remote SSH** worker isolation

The update is validated and applied by the server, and the TUI Sandbox view refreshes in real time.
