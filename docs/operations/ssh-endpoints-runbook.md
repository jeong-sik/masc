# SSH remote execution endpoints

This is the operator runbook for RFC-0395 and `sandbox_profile = "remote_ssh"`.
The lane is fail-closed: do not recover an SSH failure by silently switching
`sandbox_profile` to `docker` or `microvm`.

## Prerequisites

- A Linux host reachable with OpenSSH and a dedicated remote account.
- Existing operator SSH authentication for the one-time `ssh-copy-id` step.
- Non-interactive sudo (`sudo -n`) for installing the shim/config and creating
  keeper roots. The bootstrap fails instead of opening a PTY or waiting for a
  sudo password.
- `git`, `rg`, `python3`, and enough free disk on the remote host. Install `gh`
  when provisioning a GitHub identity. Bootstrap uses Python's directory file
  descriptors under non-interactive sudo to prepare workspaces without
  following symbolic links.
- Docker locally when building the static shim or running the live fixture.

Do not put private keys, token files, or generated `artifacts/` in git.

## 1. Declare the endpoint

Add one table to the effective `<base>/.masc/config/runtime.toml`:

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

Each shim/probe command authenticates a new SSH connection using the dedicated
identity and pinned hosts file. MASC disables connection sharing, ambient agent
authentication, default identity selection and system known-hosts fallback.
Replacing a key or pin is therefore enforced on the next
connection, even while readiness observations are cached. Observation timestamps
describe prior probes and dispatches; they are not a new authentication check.
`max_concurrent_sessions` bounds active requests for the endpoint across
Keepers. Independent authentication adds a connection handshake per command;
there is no workspace-relative Unix control socket or idle SSH master.

## 2. Build the static shim

Release installations include `masc-exec-ssh-bootstrap` beside `masc`.
Use the installer and assets from the same release. The release also publishes
`masc-exec-shim-linux-amd64` and `masc-exec-shim-linux-arm64`; download and verify
the one matching the SSH endpoint's CPU against that release's `SHA256SUMS`,
then pass its path explicitly with `--shim`. The endpoint's architecture can
differ from the operator machine's. The guest shim installed under
`<base>/.masc/microvm/shim/` follows the operator's guest architecture, so do not
assume it matches a different SSH host.

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

Prepare a workspace without a GitHub login:

```sh
masc-exec-ssh-bootstrap \
  --base-path /path/to/base \
  --endpoint builder \
  --shim /path/to/masc/artifacts/masc-exec-shim \
  --keeper keeper-a
```

Repeat `--keeper` for each Keeper. This creates its private directory without
removing existing work. The endpoint root, workspace, and their directory
ancestors must be actual directories: bootstrap refuses symbolic links before
changing their permissions or owner. GitHub login is optional for commands and file tools;
preflight skips identity validation only when the endpoint confirms that the
Keeper has no `hosts.yml`. An unavailable probe remains a failure.

For a Keeper that needs GitHub, store its token in a temporary local 0600
file and use the same command with `--github-token-file` instead:

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
5. prepares `remote_root/<keeper>` for every `--keeper` and
   `--github-token-file` name; when a token is supplied, creates `.config/gh`
   there and sends the token only on SSH stdin;
6. for each supplied token, writes its value to
   `.masc/ssh/redaction/<keeper>.token` at 0600 so
   output redaction knows it, without adding it to any execution environment.

Delete the input token file after successful provisioning using the
organization's approved secret-file procedure.

For a planned host-key rotation, verify the new fingerprint out of band and
rerun with `--replace-host-key`. Never use that flag merely to clear a mismatch.

### Tools and environment the host declares

A keeper's command does not run in a login shell. The shim builds its
environment: `PATH=/usr/local/bin:/usr/bin:/bin`, `HOME`, `USER`, `TMPDIR`, and
the request values the endpoint's `env_allowlist` admits. A host whose tools
live in a venv, conda or a CUDA install declares that in
`/etc/masc-exec-shim.conf`:

```text
path=/opt/venv/bin:/usr/local/bin:/usr/bin:/bin
env_file=/etc/masc-exec-shim.env
```

- `path=` is the payload `PATH` and the directories the shim looks programs up
  in.
- `env_file=` names a file of `NAME=VALUE` lines (docker `--env-file` grammar,
  values taken byte for byte) that every payload runs with, for example
  `VIRTUAL_ENV=/opt/venv` or `LD_LIBRARY_PATH=/usr/local/cuda/lib64`. The
  request denylist does not apply to it; `PATH` is refused there because
  `path=` declares it. GitHub token names (`GH_TOKEN`, `GITHUB_TOKEN`,
  `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN`) and the names the runner
  sets for each request (`GH_CONFIG_DIR`, `GIT_TERMINAL_PROMPT`,
  `GIT_AUTHOR_NAME`, `GIT_COMMITTER_NAME`) are refused too: each keeper acts
  as its own GitHub login and commits under its own name. Request values admitted by
  `env_allowlist` replace the file's values.

In a boxed run (`observe`, `guest_local`) `HOME` and `TMPDIR` are the run's
scratch directory whatever the env file declares. Other directories the file
names are outside the box, so under `observe` a payload's writes there are
refused.

Keep the config and the env file regular files, root-owned and `0644`; the
bootstrap installs the config that way. Whoever can write the config names the
payload `PATH` and the env file, and whoever can write the env file sets every
payload's environment, the loader path included. So the shim refuses the
request, before it reads either file, when:

- the path is not a regular file (a FIFO, a device, a directory);
- the file's owner is neither root nor the account the shim runs as. A file
  owned by the shim's own account passes, but payloads run as that account
  and can rewrite it, so keep it root-owned;
- its group or every user may write it.

Keep the file on a filesystem that keeps Unix owners and modes, such as `/etc`.
A file on a mount that reports a fixed mode for every file (WSL drvfs, CIFS
mounted with `file_mode=0777`) is refused, and `chmod` will not help.

The shim reads the file for every request, so replace it in one step: write a
temporary file in the same directory, then `mv` it over the old one.

```sh
printf '%s\n' 'VIRTUAL_ENV=/opt/venv' | sudo tee /etc/masc-exec-shim.env.tmp >/dev/null
sudo chmod 0644 /etc/masc-exec-shim.env.tmp
sudo mv /etc/masc-exec-shim.env.tmp /etc/masc-exec-shim.env
```

When a line is malformed the shim reports the file and the line number, not
the line itself, since a line in the wrong place may be a secret.

Bootstrap updates `remote_root` and `env_allowlist` from the endpoint
declaration and preserves the existing `path`, `env_file`, and `scratch_root`.
It parses the existing config before installing anything; an invalid config
is reported rather than silently replaced. The replacement config is installed
atomically at `0644`, owned by the non-interactive sudo account (root).
The referenced environment file stays on the endpoint and is not copied.

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

The Dashboard's Keeper sandbox settings select from the current runtime
endpoint registry and display the server's last shim/dispatch observations.
An empty registry and an unreadable registry are different states. Reading
settings does not connect to the endpoint or establish current readiness.

In the native TUI, `e` edits `remote_endpoint` along with the other Keeper
settings. The Sandbox `s` shortcut retains an explicitly selected registered
endpoint or chooses the only registered endpoint, and selects inherited
networking in the same revision-checked save. With multiple endpoints, choose
one explicitly through `e`; `d` and `m` clear the SSH endpoint in their save.

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

For example, `research-a`, `research-b`, and `research-c` may all select the
same endpoint with `sandbox_profile = "remote_ssh"` and
`remote_endpoint = "team"`. The default 8 sessions are shared across all
three, not granted separately to each. Their work roots are
`remote_root/research-a`, `remote_root/research-b`, and
`remote_root/research-c`, with separate `.config/gh` directories, but the
same Unix account and kernel. Keep `private_home = false` for this shared
account and bootstrap each Keeper's root and token explicitly.

That endpoint may be one operator-provisioned Linux container. MASC connects
to its SSH listener but does not create, restart, or limit the container;
enforce its CPU, memory, swap, and pids limits in the container runtime. The
[Keeper manual's capacity and topology examples](../KEEPER-USER-MANUAL.md#sandbox-capacity-and-topologies)
show the complete endpoint, three-Keeper TOML, and bootstrap sequence.

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
| `sandbox_guest_unavailable` | A Docker/microVM guest could not be prepared, or its execution transport failed. It is not evidence that GitHub rejected the Keeper's token. | Inspect the guest, work-volume probe, and transport; do not re-login or repeatedly call `gh auth status`. Check `network_mode` and `microvm_backend` in the failure envelope. |
| `github_identity_snapshot_unavailable` | The Keeper's GitHub identity is what failed: a direct refresh, snapshot, or revision check, or a guest or container start that refused the identity. | Inspect that Keeper's GitHub identity with `masc keeper-github status` or the GitHub tab. The [Keeper manual](../KEEPER-USER-MANUAL.md#read-sandbox-failures-before-changing-credentials) lists the other signals. |
| `remote_ssh_no_network_mode` | `remote_ssh` was combined with a Docker-only network mode. | Remove `network_mode`; endpoint networking is host policy. |
| `remote_endpoint_requires_remote_ssh` | A non-SSH profile still has `remote_endpoint`. | Clear it with JSON `null` or select `remote_ssh`. |
| `remote_ssh_runtime_config_missing` | Effective runtime TOML cannot be found. | Verify the base path and `.masc/config/runtime.toml`. |
| `remote_ssh_runtime_config_invalid` | Runtime TOML or endpoint registry failed strict parsing. | Fix the named path/key/value; do not bypass the decoder. |
| `remote_ssh_endpoint_missing` | The keeper has no endpoint name. | Set `remote_endpoint` in the same keeper update. |
| `remote_ssh_endpoint_unknown` | The name is absent from the endpoint registry. | Declare the exact table or correct the keeper name. |
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
| `remote_ssh_shim_config_error` | `/etc/masc-exec-shim.conf` is missing, invalid, owned by neither root nor the shim's account, or may be written by its group or every user; or the `env_file=` it names is not a regular file, cannot be read, has a malformed line, or fails the same owner and mode rule. | A detail that names the env file's path (`cannot read env_file <path>`, `env_file <path> is not a regular file`, `env_file <path> line N: ...`, `env_file <path> is owned by uid N`, `env_file <path> is writable by ...`): fix that file and do not rerun bootstrap, which rewrites the config without `env_file=`. `config file <path> is owned by uid N` or `config file <path> is writable by ...`: make the config root-owned `0644` with `sudo chown root:root` and `sudo chmod 0644`; rerunning bootstrap resets the mode but keeps the owner of an existing file. Any other detail is about the config file, including `env_file must not be empty` and `env_file must be an absolute path` (the `env_file=` line itself is wrong): rerun bootstrap and inspect the strict config keys, then add `path=`/`env_file=` again (masc#36918). |
| `remote_ssh_shim_error` | The shim failed before producing a payload result. | Inspect the named shim detail and remote system state. |
| `remote_ssh_dispatch_unavailable` | An SSH profile reached a non-SSH dispatch arm. | Treat as a wiring regression; capture the exact source head and file an issue. |
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

## Watching Keeper commands and output

In the MASC TUI, open a Keeper (`Right` from the Keepers list) and press `[`
once from Info to reach the Terminal tab. It follows the Keeper's redacted
command lines and stdout/stderr as they arrive, reading once a second, and
`k`, `PgUp` or `Home` holds the screen still while you read back (`End` follows
again). The tab works the same for Docker, microVM and `remote_ssh` Keepers,
because all of them stream through the same server-side ring. It reads that
ring over HTTP, so it is not a PTY: nothing typed in the TUI reaches the
command. A pipeline with a file redirect, or another shape the dispatcher
chains without streaming, shows its output when the command ends rather
than line by line.

`l` opens the logs view instead. Its Execute section
shows the most recently observed command summaries and stdout/stderr, newest
first, at the TUI's normal cadence. Each row carries the stream and Task
identifiers. In either view a failed read is shown as unavailable, and a
missing earlier sequence means the in-memory server history has already been
truncated. The command summary omits shell operators and environment
assignments; it is an audit aid, not an exact command to copy and rerun.

For a terminal tail of several Keepers, from a MASC checkout use:

```sh
MASC_TOKEN="$(cat /path/to/operator-token)" python3 scripts/masc-keeper-output.py \
  --server http://127.0.0.1:8935 --agent masc-tui \
  --jsonl ./keeper-output.jsonl wkbl-data wkbl-front
```

Use an agent name matching the credential. `MASC_TOKEN` is optional when the
server accepts an unauthenticated read. `--jsonl` is optional; it appends the
server's redacted events to a private 0600 file. The live event ring is held
in the MASC server process and is bounded; it is not a durable transcript. A
reconnect reads a new snapshot and may show retained lines again. A disconnect
or an unknown result is not proof that a remote command did or did not run;
inspect its effects before deciding whether to execute it again.
The current output routes use HTTP/1.1; the separate HTTP/2 gateway does not
serve them. The TUI and terminal client use HTTP/1.1 for these reads.

## Endpoint observations

`keeper_lane_status` and the operator's `/api/v1/gate/keeper-shims` report the
last probe and dispatch seen by this server process for the logical endpoint.
An answered probe is evidence that its pinned transport and shim answered at
that time; a failed probe does not distinguish a powered-off machine from a
network, authentication, or protocol failure. The report does not initiate a
probe. Preflight and normal dispatch acquire observations when they need them.

A newer Linux shim can report its kernel boot UUID. The report compares it to
the last comparable value for the same endpoint declaration during this MASC
server process. A changed UUID can mean a reboot or a different endpoint; a
matching UUID means the same observed kernel boot and may be shared by
containers. Neither proves workspace continuity. The last change time is held
in memory, so the first observation after a MASC restart is a new baseline.
Older shims and systems without a kernel boot UUID report it as unavailable.
This status neither starts the machine nor proves that any container was
started automatically.
