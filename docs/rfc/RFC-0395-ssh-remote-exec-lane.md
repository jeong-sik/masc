---
rfc: "0395"
title: "Pinned OpenSSH is the Phase 1 remote execution lane"
status: Draft
created: 2026-08-28
updated: 2026-08-28
author: jeong-sik
supersedes: []
related: ["0394", "0213", "0208", "0001"]
---

# RFC-0395 — Pinned OpenSSH remote execution lane

## Context

RFC-0394 made the local playground fail closed and selected a machine boundary
as the durable isolation direction. Docker remains available, but it does not
move execution off the MASC host. Phase 1 needs a transport that can reach a
separate Linux machine without adding a new network service or sending payload
arguments and secrets through a shell command line.

The normative implementation design is
[`docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md`](../superpowers/specs/2026-08-27-openssh-microvm-exec-design.md).

## Decision

`sandbox_profile = "remote_ssh"` selects a named endpoint from
`[exec.ssh.endpoints.<name>]`. The keeper layer injects an SSH runner into the
dependency-clean `lib/exec` target. There is no fallback to Docker or local
execution when endpoint resolution, preflight, transport, or the remote shim
fails.

The client ignores ambient SSH configuration and pins its authority:

- no PTY; stdout and stderr remain separate;
- `-F none`, agent forwarding off, all forwarding cleared;
- batch mode, a dedicated identity, strict host-key checking, and one explicit
  `known_hosts` file;
- bounded connect and server-alive timers;
- endpoint-scoped ControlMaster multiplexing with an explicit session ceiling.

The remote command is always the fixed literal `masc-exec-shim`. A versioned
frame on stdin carries binary-safe argv, env, cwd, timeout, and payload stdin.
The Linux shim revalidates the cwd jail, synthesizes a minimal environment,
starts a new process group, reaps it on timeout or channel EOF, and returns one
typed result trailer. Exit, signal, remote timeout, shim failure, transport
failure, and local timeout remain distinct observations.

## Trust and secret boundary

Host secrets do not cross this lane by default. Typed env is still validated,
then reduced to the endpoint allowlist; reserved loader/shell variables are
dropped even if listed. GitHub identity is provisioned on the remote host per
keeper. Its token travels only on the bootstrap SSH stdin and is registered in
a host-side 0600 redaction file that is never projected into local or Docker
execution.

Endpoint bootstrap generates the dedicated key, scans only the ED25519 host
key, and writes it only after the operator verifies and retypes the fingerprint
out of band. The static shim, shim config, remote root, keeper root, and GitHub
identity are then installed through the pinned channel.

## Readiness and operation

`masc_keeper_up` requires a declared endpoint and forces a fresh readiness
check. Dispatch and remote reads consult a short endpoint+keeper TTL cache.
Readiness covers reachability, shim major version, git, root and keeper-root
existence, disk floor, and keeper-scoped `gh auth status`. Every failure is
named and stops the requested lane.

Keeper-visible logical paths remain host-shaped. One path module translates
them to `remote_root/<keeper>` and rewrites remote absolute paths in captured
and streamed output. Remote reads use the same SSH backend. Execute file
redirects remain fail-closed until typed remote file operations land
(masc#31442).

The operator procedure and complete error catalog live in
[`docs/operations/ssh-endpoints-runbook.md`](../operations/ssh-endpoints-runbook.md).

## Alternatives considered

### mTLS HTTP executor

An HTTP executor would make request framing straightforward, but it adds a new
listening service, certificate lifecycle, authorization policy, streaming
protocol, and remote supervisor. Those are additional security and operations
surfaces before they provide isolation.

### gRPC bidirectional stream

gRPC offers typed streaming and cancellation, but has the same new-daemon and
credential-lifecycle costs. It would also duplicate connection reuse,
keepalive, host authentication, and forwarding controls already supplied by
OpenSSH.

### Ambient SSH configuration

Using `~/.ssh/config`, an agent, or the user's default keys is convenient but
makes the effective authority host-dependent and unauditable. Phase 1 instead
uses explicit config-independent argv and endpoint-owned files.

## Consequences

- Operators must provision Linux/OpenSSH, a dedicated remote account, pinned
  host keys, non-interactive install authority, and per-keeper GitHub identity.
- A degraded endpoint produces visible tool failures; continuity never
  authorizes a weaker lane.
- CI without Docker builds the integration test but skips its seven live
  cases. `scripts/test-ssh-fixture.sh` is the exact local evidence producer.
- The current shim has one host-level config file. Deployments needing
  different roots or policies use separate endpoint hosts until that authority
  is explicitly redesigned.
- Phase 2 changes endpoint provisioning so the same shim runs inside a
  per-keeper microVM. The Phase 1 wire protocol and keeper-facing target remain
  unchanged.

## Verification

The gated fixture proves a real static Linux shim over a real sshd: binary argv
and 1 MiB stdin, split streams, exit/signal/trailer integrity, the fast-exit
SIGPIPE regression, cancellation with no remote orphan, env filtering,
preflight degradation, and absence of payload argv from the MASC host process
table.
