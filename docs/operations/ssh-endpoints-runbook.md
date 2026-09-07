# SSH remote execution endpoints

This is the operator runbook for RFC-0395 and `sandbox_profile = "remote_ssh"`.
The lane is fail-closed: do not recover an SSH failure by changing a keeper to
`local` or silently routing it to Docker.

## Prerequisites

- A Linux host reachable with OpenSSH and a dedicated remote account.
- Existing operator SSH authentication for the one-time `ssh-copy-id` step.
- Non-interactive sudo (`sudo -n`) for installing the shim/config and creating
  keeper roots. The bootstrap fails instead of opening a PTY or waiting for a
  sudo password.
- `git`, `gh`, and enough free disk on the remote host.
- Docker locally when building the static shim or running the live fixture.

Do not put private keys, token files, or generated `artifacts/` in git.

## 1. Declare the endpoint

Add one table to the effective `<base>/.masc/runtime.toml`:

```toml
[exec.ssh.endpoints.builder]
host = "builder.example.net"
user = "masc-exec"
port = 22
remote_root = "/srv/masc/playground"
connect_timeout_sec = 10
max_concurrent_sessions = 8
env_allowlist = ["LANG"]
capabilities = []
# 이 계정의 홈이 이 keeper 만의 것일 때만 true. keeper TOML 의
# observation_run = "guest_local" 은 이 선언이 있는 엔드포인트에서만 상자를
# 만들고, 없으면 그 요청은 judge 로 간다 (RFC-0422 §3.4).
private_home = false
```

Omitted path defaults resolve against the MASC base path:

- identity: `.masc/ssh/builder.key`
- pinned host key: `.masc/ssh/known_hosts.d/builder`

Unknown endpoint keys and unknown endpoint names are load errors.

## 2. Build the static shim

From the MASC repository:

```sh
scripts/build-shim-static.sh artifacts/masc-exec-shim
file artifacts/masc-exec-shim
```

That builds one artifact for the host you are on, which is what
`scripts/test-ssh-fixture.sh` consumes.

musl static linking makes the shim indifferent to the remote distribution but
not to its CPU: x86_64 instances need `amd64`, Graviton and Ampere need
`arm64`, and an artifact built for the wrong one fails the remote probe rather
than running. To produce both and keep them side by side, use the
architecture-aware builder instead:

```sh
scripts/remote-ssh/build-shim.sh                 # amd64 + arm64
scripts/remote-ssh/build-shim.sh --arch arm64    # one of them
```

It writes `dist/remote-ssh/masc-exec-shim-linux-<arch>`; pass the matching file
to the bootstrap's `--shim`.

Continue only when `file` reports `statically linked` or `static-pie linked`
and no dynamic interpreter. The build script enforces this check.

## 3. Bootstrap trust and keeper identity

Store each GitHub token in a temporary local 0600 file. Then run:

```sh
masc-exec-ssh-bootstrap \
  --base-path /path/to/base \
  --endpoint builder \
  --shim /path/to/masc/artifacts/masc-exec-shim \
  --github-token-file keeper-a=/secure/tmp/keeper-a.token
```

The tool prints the scanned ED25519 fingerprint. Verify it through a separate
channel (provider console, host administrator, or direct console), then retype
the exact `SHA256:...` value. Retyping a value copied only from the same scan is
not out-of-band verification.

The bootstrap then:

1. creates or reuses the dedicated keypair and authorizes its public key using
   the operator's existing SSH authentication;
2. proves the pinned key works in batch mode;
3. uploads and installs the shim and `/etc/masc-exec-shim.conf`;
4. records the remote shim probe under `/usr/local/share/masc/`;
5. creates `remote_root/<keeper>/.config/gh` and sends the token only on SSH
   stdin;
6. writes the token value to `.masc/ssh/redaction/<keeper>.token` at 0600 so
   output redaction knows it, without adding it to any execution environment.

Delete the input token file after successful provisioning using the
organization's approved secret-file procedure.

For a planned host-key rotation, verify the new fingerprint out of band and
rerun with `--replace-host-key`. Never use that flag merely to clear a mismatch.

## 4. Create or migrate a keeper

Use both fields in the same update:

```json
{
  "name": "keeper-a",
  "sandbox_profile": "remote_ssh",
  "remote_endpoint": "builder"
}
```

`masc_keeper_up` forces live preflight before committing. To move away from
the SSH lane, select the new profile and pass `"remote_endpoint": null` in the
same call. Leaving a remote endpoint attached to another profile is rejected.

Repo checkout materialization is not inferred from the host filesystem. Until
the typed inventory in masc#31460 lands, provision required checkouts through
an explicit operator-approved repository workflow.

### What one endpoint separates, and what it does not

Every keeper on an endpoint logs in as the same unix account. The boundary
between two keepers there is the directory jail under `remote_root`, not an OS
boundary: a keeper that escapes the jail reaches its neighbours. Use one
endpoint per trust domain, and when keepers must not reach each other, give each
its own unix account and declare a separate endpoint per account.

The endpoint's `max_concurrent_sessions` semaphore is also shared by every
keeper pointed at it. Raising a keeper's throughput lowers its neighbours'.

Recreating the remote instance changes its host key. `StrictHostKeyChecking=yes`
is enforced, so the pin at `.masc/ssh/known_hosts.d/<name>` must be verified out
of band and rewritten before the endpoint answers again.

## 5. Verify and upgrade

Run the live transport proof from the exact source head:

```sh
scripts/test-ssh-fixture.sh
```

It builds a stale static shim, creates an ephemeral key and pinned sshd, runs
seven integration cases, and cleans up its container, image, and key directory.

To upgrade a real endpoint, take the shim asset from this server's release (or
rebuild the static artifact) and rerun the bootstrap with the same endpoint and
keeper token inputs. The dedicated key is reused; the unchanged host key is
re-confirmed; the shim and recorded probe are replaced through the pinned
channel. A major-version mismatch blocks preflight.

The shim names the release it was built from in its `--probe` answer, so
`/usr/local/share/masc/exec-shim.version` on the endpoint records it and the
server compares it with its own on every probe. A difference is the WARN
`remote_shim_outdated`, not a refusal: the two sides negotiate the protocol
major and keep running one release apart. A keeper can read the same fact for
its own lane with the `keeper_lane_status` tool, which reports `shim_release`
beside `server_release`.

### Reading the evidence instead of the report

A keeper's own account of a remote command is not evidence. Read the ledger:

- approval receipts: the `outcomes` in `<base>/.masc/gate/replay-results.json`
- command output: `<base>/.masc/tool_blobs/<sha2>/<sha256>`

A blob's `via` and `sandbox_profile` fields say which lane actually carried the
command. `via: remote_ssh` with exit 0 is proof the endpoint ran it; a keeper
sentence saying so is not.

## Failure modes

| Error prefix | Meaning | Operator action |
|---|---|---|
| `remote_ssh_no_network_mode` | `remote_ssh` was combined with a Docker-only network mode. | Remove `network_mode`; endpoint networking is host policy. |
| `remote_endpoint_requires_remote_ssh` | A non-SSH profile still has `remote_endpoint`. | Clear it with JSON `null` or select `remote_ssh`. |
| `remote_ssh_runtime_config_missing` | Effective runtime TOML cannot be found. | Verify the base path and `.masc/runtime.toml`. |
| `remote_ssh_runtime_config_invalid` | Runtime TOML or endpoint registry failed strict parsing. | Fix the named path/key/value; do not bypass the decoder. |
| `remote_ssh_endpoint_missing` | The keeper has no endpoint name. | Set `remote_endpoint` in the same keeper update. |
| `remote_ssh_endpoint_unknown` | The name is absent from the endpoint registry. | Declare the exact table or correct the keeper name. |
| `remote_ssh_control_path_unavailable` | The local ControlMaster directory cannot be created or secured. | Fix base-path ownership/permissions; keep the path short enough for the host socket limit. |
| `remote_ssh_host_key_confirmation_mismatch` | Retyped fingerprint differs from the scan. | Stop and re-verify out of band; do not write the key. |
| `remote_ssh_endpoint_unreachable` | Pinned SSH connect/probe failed or exited 255. | Check host/port, sshd, key authorization, host key, and connect timeout. |
| `remote_ssh_probe_invalid` | `--probe` did not return the typed probe JSON. | Verify the installed binary and remote PATH; reinstall the shim. |
| `remote_shim_version_skew` | Remote shim major version is incompatible. | Build and bootstrap the shim from the same MASC revision. |
| `remote_shim_outdated` (WARN, not a failure) | The endpoint's shim names a different MASC release than this server, or names none because it predates the stamp. The lane keeps running. | Reinstall the shim from this server's release with the same bootstrap command. |
| `remote_git_unavailable` | Remote `git --version` failed. | Install/fix git for the endpoint account. |
| `remote_ssh_root_missing` | Declared `remote_root` is absent. | Rerun bootstrap or restore the declared root. |
| `remote_ssh_keeper_root_missing` | `remote_root/<keeper>` is absent. | Bootstrap that keeper identity/root. |
| `remote_ssh_disk_probe_failed` | `df -Pk` failed or returned an unknown shape. | Fix remote coreutils/permissions and rerun preflight. |
| `remote_ssh_disk_low` | Available KiB is below the configured floor. | Free/expand disk or deliberately change the floor. |
| `remote_github_identity_missing` | Keeper-scoped `gh auth status` failed while `api.github.com` answered the endpoint. | Re-provision that keeper's token/config; never send a token per tool call. |
| `remote_github_unreachable` | `gh auth status` failed and `api.github.com` did not answer the endpoint; the token is not proven bad. | Fix the endpoint network first (microvm: `network_mode` in the keeper TOML, DNS via the sandbox profile); re-check the token only after the API answers. |
| `remote_ssh_env_invalid` | A typed env entry is malformed. | Correct the caller input; every entry must be `NAME=value`. |
| `remote_ssh_env_not_allowlisted` | Typed env is not in the endpoint allowlist. | Remove it or explicitly review and add the non-secret name. |
| `remote_ssh_path_jail_violation` | cwd/path escapes the keeper's remote root. | Correct the logical keeper path; do not weaken the jail. |
| `remote_ssh_redirect_unavailable` | Execute requested a remote file redirect not represented by typed remote file operations. | Use stdout/stderr or a supported remote read/write workflow; track masc#31442. |
| `remote_ssh_local_timeout` | The host-side connect+run+drain wall clock expired. | Check network/host load; compare with remote timeout evidence. |
| `remote_ssh_remote_timeout` | The shim's payload timer expired. | Reduce the operation or deliberately increase its typed timeout. |
| `remote_ssh_transport_error` | Frame/trailer/channel integrity failed. | Inspect sshd/shim logs and revision identity; do not treat it as payload exit. |
| `remote_ssh_version_error` | A request or result frame has an unsupported protocol version. | Align MASC and shim revisions. |
| `remote_ssh_shim_config_error` | `/etc/masc-exec-shim.conf` is missing or invalid. | Rerun bootstrap and inspect the strict config keys. |
| `remote_ssh_shim_error` | The shim failed before producing a payload result. | Inspect the named shim detail and remote system state. |
| `remote_ssh_dispatch_unavailable` | An SSH profile reached an inert Docker/legacy dispatch arm. | Treat as a wiring regression; capture the exact source head and file an issue. |
| `remote_ssh_read_failed` | A remote read command exited nonzero. | Inspect the returned exit/stderr and remote path. |
| `remote_ssh_read_signaled` | A remote read command died by signal. | Inspect remote resource/kill evidence. |
| `remote_ssh_read_stopped` | A remote read command reported a stopped status. | Treat as an execution anomaly and inspect the endpoint. |
| `remote_ssh_read_internal_error` | SSH profile reached Docker-only read code. | Treat as a routing regression; do not retry through Docker. |

When reporting an incident, include timestamp, endpoint, keeper, exact error,
MASC source revision, shim probe/version, retryability, and observed recovery.

## Appendix: a local microVM as the endpoint

The lane does not care whether the remote host is another machine. A local
hypervisor guest that answers SSH is an endpoint like any other, and that is one
way to get microVM isolation from a runtime MASC has no backend for.

Measured 2026-09-04 with gondolin 0.12.0 (earendil-works, QEMU-backed, so no KVM
is needed) on macOS 26.6.1. RFC-0405 turned gondolin down as a `microvm_backend`
because nothing in its CLI puts a command into an existing session — `exec
--sock` takes write EPIPE against the interactive bash holding the channel, and
`attach` answers `session connection closed`. That verdict stands. It says
nothing about this lane, which needs only sshd.

```
gondolin bash --ssh --ssh-port 22222 --ssh-user root \
  --allow-host github.com --allow-host api.github.com \
  --allow-host dl-cdn.alpinelinux.org \
  --mount-hostfs "$HOME/me/.masc/gondolin-work:/opt/masc-playground-gondolin" \
  < /dev/null
```

Stdin closed, no TTY, and the session persists: `gondolin list` reports it ALIVE,
and a file written over one SSH connection is read back over the next. It prints
the exact `ssh` line and the generated key path; copy that key to
`.masc/ssh/<name>.key` at 0600 and pin the host key before declaring the
endpoint. A `remote_ssh` Keeper then drives it with no backend code at all.

Four things this costs, none of them obvious from the CLI's help:

- **The network has two modes, and the safe one is not the default.** With no
  `--allow-host`, GET reaches the internet and POST answers `502` — measured on
  one host and path, `GET api.github.com/zen` 200 against `POST` 502. That alone
  fails `gh auth login`, whose device flow is a POST. Naming any host switches
  the gateway to a strict allowlist, so the Alpine mirror has to be named too or
  `apk` takes `403`. A Keeper writes through `gh api` and `git push`, so the
  allowlist has to be decided up front.
- **The guest root filesystem is new on every boot.** The shim,
  `/etc/masc-exec-shim.conf`, `git`, `rg` and `gh` are gone after a restart and
  have to be installed again. This is not Apple's `container`, where the image
  carries them.
- **The stock rootfs is 262 MB against the lane's 1 GB floor.** `--rootfs-size`
  needs `resize2fs`, which the stock image does not ship. Mount the playground
  from the host instead: it clears the floor and survives restarts, which is also
  what keeps the `gh` login alive across them.
- **The session belongs to the host process that started it.** When that process
  exits the guest goes with it. Decide who owns the session before running
  anything durable on it.
