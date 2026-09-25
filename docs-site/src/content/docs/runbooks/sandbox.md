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

MASC ships no image. A Keeper names one in `sandbox_image` by its name in the
host's image catalog, `<base-path>/.masc/config/sandbox-images.toml`: `base`
for a Keeper that builds nothing, `ocaml` for one that builds MASC. The catalog
records, per image store (Docker's, or a microVM runtime's own), which build
each name is on this host. `masc setup` builds `base` and promotes it when the
catalog has no `base` build for the store it sets up.

By hand:

```bash
masc sandbox-image                          # builds base, prints masc-sandbox-base:<UTC minute>-<input hash>
masc sandbox-image promote base <that tag>  # the next turn of a base Keeper starts from it
```

Other recipes are read from a checkout:
`masc sandbox-image --recipe ocaml --source <checkout>`. Each command takes
`--runtime <backend>` for a microVM runtime's store. A tag already in the store
is refused, so a build never changes under a tag.

Promote records a tag only when the store `--runtime` names holds it, and the
catalog keeps one tag per name and store. To go back, promote an earlier tag
the store still has. On Docker, `apple_container` and `nerdctl_kata`,
`masc sandbox-image` builds the tag to promote. `msb` has no build command:
build the image elsewhere, `msb load` its OCI archive, then promote that tag
with `--runtime microsandbox`.

A Keeper whose name the catalog lacks, or that has nothing promoted for its
store, starts no container; the refusal names the commands above. A turn looks
its Keeper's name up once, when it first needs a container, so a promote
reaches the next turn and never splits one.

What `base` carries is `sandbox-images/base/Dockerfile`. The binary embeds it
and pipes it to `docker build -` with no build context, so it builds the same
on a host that never had a checkout. `masc sandbox-image --print` writes the
Dockerfile to stdout instead of building.

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
