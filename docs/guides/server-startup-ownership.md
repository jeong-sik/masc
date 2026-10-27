# Server startup ownership

`masc start --base-path <dir>` acquires the workspace's BasePath lease and
attempts to bind an HTTP listening socket. The socket owns the endpoint.
An occupied endpoint causes startup to fail; startup does not terminate its
holder or retry the bind with a delay.

The BasePath lease separately prevents HTTP and stdio processes from owning
the same workspace concurrently. Its recorded PID is observational: inspect
the owning service or container on the correct host before stopping it.
Stop the confirmed owner through its operator controls before starting a
replacement.

## Replacing the running server

`masc restart` replaces this workspace's server on this host, for example
after `scripts/install-local-build.sh`:

1. It reads `/health?full=1` on loopback. Only a server of this workspace is
   asked to stop; another workspace, a non-MASC listener, or a lease owner
   that does not answer on the port is refused and left running. A `--host`
   that 127.0.0.1 cannot reach is refused too, because restart could not see
   that replacement answer, and so is one that is not an IP address, such as
   `localhost`, because the replacement could not bind it.
2. It signs in as the local operator and sends one SIGTERM to the lease
   owner it identified with `F_GETLK`, the same request `masc setup` makes.
   Nothing is forced down.
3. It starts `masc start --wait-for-previous-owner` in its own process group
   with its output appended to `<base>/.masc/logs/masc-start-<UTC time>.log`
   (`--log` chooses another file). That process sleeps on the lease until
   the previous owner exits and then boots as usual, so no other process can
   take the workspace in between. Only one process waits for a workspace: a
   second replacement started meanwhile exits at once, naming the first.
   When no server was running, restart starts plain `masc start` instead.
4. It waits until `/health/ready` answers 200 with the new process's `pid`,
   then prints how long it took. Ctrl-C stops the waiting, not the new server.

Plain `masc start` still refuses at once while another process holds the
lease: a running server that was not asked to stop does not exit.

Startup does not read, create, overwrite or remove a port-specific PID file.
A file named `masc-<port>.pid` does not establish listener ownership. Startup
also does not infer who sent a shutdown signal from a breadcrumb file; the
ordinary shutdown path still records the signal it received.

The design is in [masc restart](../rfc/RFC-masc-restart-replaces-the-workspace-server.md).
The connection-publication changes proposed in
[RFC-0447](../rfc/RFC-0447-port-bind-or-refuse.md) are separate and remain a draft.
