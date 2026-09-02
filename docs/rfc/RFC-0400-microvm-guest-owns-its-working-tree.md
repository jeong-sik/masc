---
rfc: "0400"
status: Draft
---

# RFC-0400 — The microVM guest owns its working tree

- Status: Draft
- Decision driver: RFC-0399 moved `_build` off the virtiofs share and the
  three panics stopped, but the share itself is still the boundary. Measured
  2026-09-02 on the live fleet: a keeper's checkout is about 10,600 files, so
  one `rg` over it pins about 10,600 host vnodes; eight keepers reading three
  checkouts each exceed the guard's budget (209,715 vnodes) with no build
  involved. The playground census found what the share invites: 64 orphan
  worktrees under one checkout (592,870 files), a `_dune_cache` a keeper put
  next to its checkout (67,529 files), `node_modules` three times. A cron
  guard (`masc-microvm-fd-recycle.sh`, labelled WORKAROUND, removal target
  "RFC merge") stops fat guests every 23 minutes and is not idle-aware.
- Area: `lib/keeper/keeper_sandbox_remote.ml` (new),
  `lib/keeper/keeper_sandbox_ssh.ml`, `lib/keeper/keeper_remote_path.ml`,
  `lib/keeper/keeper_sandbox_microvm.ml`,
  `lib/keeper/keeper_turn_sandbox_runtime.ml`, the `Docker | Micro_vm`
  dispatch arms, `lib/exec_shim/exec_shim.ml`.

## Problem

Apple's virtiofs opens one host `O_PATH` descriptor per inode the guest
touches and never releases it while the guest runs (no `FUSE_FORGET` on
container 1.3.1; issue tracked upstream, not fixed by a version bump). A host
descriptor is a host vnode. The guest's access pattern therefore decides a
host kernel resource, and the host has no handle to reclaim it short of
stopping the guest.

Managing that from the host is not a fix:

- The guard is load-bearing forever: the budget is exceeded by legitimate
  work (reading source), not by mistakes.
- The RFC-0399 link covers `_build` only. `_dune_cache`, `node_modules`,
  `.worktrees` and the checkout itself stay on the share.
- Telling keepers in their prompt not to create worktrees reduces the
  frequency of a deterministic failure and leaves the failure in place.

## What the codebase already says

`keeper_remote_path.ml` classifies every consumer of a keeper's host root
into three kinds: logical-path bookkeeping (no remote I/O), remote-proxied
reads and commands (translated through that module to the shim), and
"Docker-only, explicitly divergent: their host roots are bind-mount inputs
and are never used by `Remote_ssh`". The `remote_ssh` profile is the proof
that the runtime already runs a keeper whose tree lives elsewhere: the host
keeps a bookkeeping bundle, translates paths, and proxies reads and commands
through `masc-exec-shim`.

`microvm` today is in the Docker kind. The share is its bind mount. That is
the whole defect.

## Decision

An Apple `container` guest is a remote endpoint, the same kind as an OpenSSH
endpoint. It owns its working tree on an ext4 named volume; the host reaches
it through the shim, over `container exec` instead of `ssh`.

| | OpenSSH endpoint (RFC-0395) | Guest endpoint (this RFC) |
|---|---|---|
| Transport argv | pinned `ssh ... masc-exec-shim` | `container exec -i --user u:g -w <root> --env MASC_EXEC_SHIM_CONFIG=.. <guest> <shim>` |
| Wire | framed request on stdin, trailer on stderr | same, byte for byte |
| Remote root | `[exec.ssh.endpoints.<name>].remote_root` | `/masc-work`, the guest mount of volume `masc-keeper-work-<name>` |
| Keeper root | `<remote_root>/<keeper>` | same |
| Host side | bookkeeping bundle `playground/<keeper>/` | same bundle |
| Path translation | `Keeper_remote_path` by `remote_root` | same module, same call |
| Reads | proxied `cat` through the shim | same |
| Identity | `<keeper>/.config/gh` installed by bootstrap | the identity snapshot mounted read-only, named by `GH_CONFIG_DIR` |
| Preflight | probe, git, rg, roots, disk, `gh auth status` | same checks; the keeper root is created by the VM start path rather than by hand |
| Trust boundary | dedicated key, pinned host key, sshd | the hypervisor; the CLI is local |
| Error codes | `remote_ssh_*` | `microvm_remote_*` |

Nothing crosses the boundary as a file. Source crosses as git objects (the
guest clones and fetches over its NAT network, as it does today); what the
keeper wrote crosses as the tool-call ledger, which `file-activity` already
projects without touching a live tree; a file the host truly needs is read
through the shim, a channel whose cost is visible.

With the tree on ext4, host descriptors per guest stay flat regardless of
what the keeper does: measured on RFC-0399, an ext4 volume held 26 host
descriptors before and after a build that pinned 20,027 through virtiofs. The
guard's removal condition is met by construction, not by policing.

## Scope, as a stack

Each unit builds and passes its suites on its own head.

### A. Transport-neutral runner (this PR)

`Keeper_sandbox_ssh` held two things: OpenSSH endpoint resolution and the
shim exchange. The exchange moves to `Keeper_sandbox_remote` with the
transport as a value:

```ocaml
type transport =
  | Openssh of openssh            (* registry entry + key paths + ControlPath *)
  | Container_exec of container_exec  (* cli, guest name, uid:gid, shim path, shim config path *)
```

`Keeper_remote_path` takes `~remote_root` instead of an `Exec_ssh_endpoint.t`
it only read one field of. `Exec_ssh_protocol.shim_config_env_var` names the
one environment entry the shim reads for itself, so the host and the shim
cannot disagree on it. Error codes carry the lane prefix; the OpenSSH lane's
strings are unchanged, which the existing four ssh suites prove.

No behaviour changes for any profile.

### A2. Shim config `path=`

The guest image keeps `dune` and `ocaml` under `/home/opam/.opam/5.5/bin`
(measured live), off the shim's fixed payload `PATH`
(`/usr/local/bin:/usr/bin:/bin`). The shim config gains an optional `path=`
key, absolute entries only, that replaces the default. The host writes the
guest's config, so the value is server-authored; a vendor box keeps the
default. The static shim is rebuilt once (`scripts/remote-ssh/build-shim.sh`).

### B. Guest provisioning

On VM boot (`start_microvm_container_unlocked`):

- ensure named volume `masc-keeper-work-<name>` (same probe/create shape as
  the RFC-0399 build volume) and mount it at `/masc-work`;
- mount the host directory holding the static shim and its config read-only
  at `/opt/masc-exec-shim`;
- create `/masc-work/<keeper>` as root with an explicit mode, the way the
  build-link targets are created (the volume root is root-owned and Apple's
  user namespace refuses mode changes from guest root);
- build the guest's `Keeper_sandbox_remote.t` with `Container_exec` and the
  identity snapshot's guest path as `GH_CONFIG_DIR`.

The virtiofs mount of `playground/microvm/<keeper>` is dropped from the
start argv. Config and identity stay read-only mounts, as today.

### C. Routing hard cut

`Micro_vm` leaves the Docker arms and joins the remote arms: execute and
read dispatch go through `Keeper_sandbox_remote.runner`; host root projection
is the bookkeeping bundle; `Keeper_invariant.sandbox_isolation` is scoped on
the endpoint as it is for `remote_ssh`. Eight `Docker | Micro_vm` arms move.
The RFC-0399 `_build` link machinery and its status rows are deleted: on a
tree that already lives on ext4 they would classify every checkout as
`Build_real_directory` and warn each turn about a problem that no longer
exists. The build volume is folded into the work volume.

Live cutover: keepers re-clone into the volume. Two keepers hold uncommitted
work on the share (polisher: 7 task checkouts; edgar: 2); the runbook copies
those into the volume with `container exec` before the mount is dropped.

### D. Guard retirement (`~/me`)

Remove the cron entry and the script once C is live and the acceptance
measurement holds.

## Alternatives, and why they are not this

- **sshd inside the guest, endpoint in the registry.** The 2026-08-27 design
  (§4.3) said this for Firecracker on a remote Linux host, where the network
  is the boundary. For a guest on this host the CLI already delivers stdin
  and exit codes (measured), and sshd would add a key, a host key that
  changes per boot unless persisted, an address to discover, and a port. The
  wire protocol is the same either way; only the argv differs, and the argv
  is a value.
- **Another shared filesystem.** Swaps the leaking implementation for one
  that also makes guest access a host resource. Same boundary, different
  clothes.
- **Copy the tree per turn.** Pays a checkout per turn and creates drift
  between two trees that both claim to be the working tree.
- **Fix virtiofs upstream.** Correct and worth filing; not something this
  runtime can wait on, and the boundary is wrong independent of the bug.

## Verification

- Unit: `test_keeper_sandbox_remote` drives the runner through a stub CLI
  (argv shape, frame contents, injected identity env, lane codes, the CLI's
  own not-found failure) and checks the OpenSSH probe stays one shell word.
  The four existing ssh suites pass unchanged.
- Live (C): a microvm keeper runs `dune build` inside the volume; the guard
  log shows per-guest host descriptors under 100 for a day of activity and
  zero recycles; `sysctl kern.num_vnodes` no longer tracks keeper activity.

## Known gaps

- The `MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC` and
  `MASC_KEEPER_SSH_PREFLIGHT_*` names now govern both lanes. Renaming them is
  a separate config change with its own migration; this RFC only documents
  the shared meaning.
- The bootstrap binary (`masc_exec_ssh_bootstrap`) provisions OpenSSH
  endpoints only. Guest provisioning is the runtime's job (B), not a
  script's.
