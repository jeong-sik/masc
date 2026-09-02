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

### C0. Remote file operations

RFC-0395 shipped the OpenSSH lane with Execute and Read proxied and left
Write and Edit on the host: `handle_file_write_with_outcome` writes through
Eio capabilities on a directory it can open, and for a remote keeper that
directory is the bookkeeping bundle, not the tree. A remote_ssh keeper's
Write therefore lands where no command of that keeper will ever look. The
guest lane would inherit the same hole, so it is closed before the cut.

- `Keeper_types_profile_sandbox.tree_location` says where a profile's tree
  is: `Shared_mount` (Docker) or `Endpoint_owned` (Remote_ssh, and Micro_vm
  since the cut). Every consumer that used to spell `Docker | Micro_vm`
  against `Remote_ssh` branches on this one function instead, so the cut
  was one arm.
- `Keeper_sandbox_remote_lane` finds the endpoint for a profile: the
  runtime.toml entry for OpenSSH, the turn factory's running guest for
  Micro_vm.
- `Keeper_tool_filesystem_remote_write` is Write/Edit for an
  `Endpoint_owned` tree: the same path jail, modes, patch
  (`Keeper_tool_patch`, moved out so both handlers apply one patch) and
  evidence as the host handler, with the bytes delivered as a `sh` payload
  over the shim (`mktemp` beside the target, `cat > tmp`, keep the mode,
  `mv -f`; `cat >>` for append; a chosen exit code marks a missing patch
  source). No Gate: the jail admits only the keeper's playground, which the
  host handler also authorizes without the Gate. No publication-recovery
  journal: the replace is atomic on the endpoint's own filesystem.
- Read dispatch routes an `Endpoint_owned` tree through the lane whatever
  the factory holds, so a guest's reads take the same path as its writes.

### B. Guest provisioning

On VM boot (`start_microvm_container_unlocked`):

- ensure named volume `masc-keeper-work-<name>` (probe with
  `container volume inspect`, confirm a 1 against the listing, create when
  absent) and mount it at `/masc-work`;
- mount the host directory holding the static shim and its config read-only
  at `/opt/masc-exec-shim`;
- create `/masc-work/<keeper>` as root with an explicit mode (the volume
  root is root-owned and Apple's user namespace refuses mode changes from
  guest root); a guest whose root cannot be made is taken down again;
- build the guest's `Keeper_sandbox_remote.t` with `Container_exec` and the
  identity snapshot's guest path as `GH_CONFIG_DIR`.

The virtiofs mount of `playground/microvm/<keeper>` is dropped from the
start argv. Config and identity stay read-only mounts, as today.

### C. Routing hard cut

`Micro_vm` leaves the Docker arms and joins the remote arms.

- `tree_location_of_profile Micro_vm = Endpoint_owned`, so Read, Write and
  Edit take the remote lane through what C0 wired, cwd echoes and execution
  locations are the host bundle, and the host root is
  `.masc/playground/<keeper>/` (the bundle, as for `remote_ssh`) rather than
  `.masc/playground/microvm/<keeper>/`.
- Execute: `Keeper_sandbox_shell_ir_target.guest_target` builds the
  `Micro_vm` target over `Keeper_sandbox_remote.runner`. The endpoint is
  acquired per stage (`Keeper_sandbox_remote_lane.microvm_endpoint`: ensure
  the guest is up, preflight if enabled), which is what boots the guest on
  first use, as the Docker runner starts its container. No pipeline runner,
  as for OpenSSH. A file redirect inside the guest is refused the way it is
  for OpenSSH: there is no mount that maps the target onto this host.
- The guest boot argv mounts no host playground; `--workdir` is the work
  volume. `Keeper_turn_sandbox_runtime`'s `docker exec` entrypoints refuse a
  microvm keeper (`microvm_exec_is_remote`), and `spawn` refuses it as it
  refuses `remote_ssh`.
- The config env (`MASC_BASE_PATH`, `MASC_BASE_PATH_INPUT`,
  `MASC_CONFIG_DIR`) that the Docker exec passes as `--env` travels as the
  endpoint's injected env; the shim config written at boot allowlists those
  names (`env_allowlist=`). One list, `config_env_names`, feeds both.
- The RFC-0399 `_build` link machinery, its status rows, the build volume
  and `MASC_KEEPER_MICROVM_BUILD_VOLUME_SIZE` are deleted: on a tree that
  already lives on ext4 the links would classify every checkout as
  `Build_real_directory` and warn each turn about a problem that no longer
  exists.

Live cutover (`docs/MICROVM-REMOTE-RUNBOOK.md`): the two keepers holding
uncommitted work on the share (polisher: 7 task checkouts; edgar: 2) have
it copied into `/masc-work/<keeper>/` with `container exec` while the old
guest still mounts both, with their `_build` symlinks dropped; then the
server restarts and boots guests without the share.

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
- Unit (C): `test_keeper_sandbox_microvm` pins that the boot argv carries no
  host playground path and starts on the work volume, that the shim config
  allowlists the config env, that the guest endpoint injects it, and that a
  microvm factory binding builds a `Micro_vm` target without booting;
  `test_keeper_fs_edit_patch` and `test_keeper_sandbox_read_backend` cover
  the `Endpoint_owned` dispatch the flip routes a guest into.
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
