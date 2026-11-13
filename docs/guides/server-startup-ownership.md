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

1. It asks the kernel which process holds the workspace lease and which
   port that process announces: a server locks the byte of its port on
   `<lease>.single-user-server`, or on `<lease>.account-server` when it is
   the account server, once its listener is bound. Only the lease owner that
   announces the selected port is asked to stop. What answers on the port
   decides nothing: restart reads from it only the version, on the compact
   `/health`, after the kernel named the server. A lease owner that
   announces another port is refused with that port. A lease owner that
   announces nothing (a server still starting, or one started by a MASC that
   did not announce yet) is refused with its pid; wait until it has started,
   or stop it with `kill <pid>` and run `masc start`. A listener on the port
   with no lease owner behind it is refused and left running. A `--host`
   that 127.0.0.1 cannot reach is refused too, because restart could not see
   that replacement answer, and so is one that is not an IP address, such as
   `localhost`, because the replacement could not bind it.
2. It asks the kernel again, signs in as the local operator, and sends one
   SIGTERM to the lease owner it identified with `F_GETLK`, the same request
   `masc setup` makes. The operator credential goes only to the process the
   kernel names as lease owner and announcer of the port, and the kernel is
   asked again before each send. Nothing is forced down.
3. It starts `masc start --wait-for-previous-owner` in its own process group
   with its output appended to `<base>/.masc/logs/masc-start-<UTC time>.log`
   (`--log` chooses another file). That process sleeps on the lease until
   the previous owner exits and then boots as usual, so no other process can
   take the workspace in between. Only one process waits for a workspace: a
   second replacement started meanwhile exits at once, naming the first.
   When no server was running, restart starts plain `masc start` instead.
4. It waits until `/health/ready` answers 200 and the process it started
   holds the announcement byte of the port, then prints how long it took.
   Nothing in the answer is read. Ctrl-C stops the waiting, not the new
   server.

`masc setup`, `masc runtime-resume` and the commands that save runtime.toml
through the running server (`masc config set` and the setup commands) find
the server the same way, and refuse the same owners with the same sentences.

Plain `masc start` still refuses at once while another process holds the
lease: a running server that was not asked to stop does not exit.

Startup does not read, create, overwrite or remove a port-specific PID file.
A file named `masc-<port>.pid` does not establish listener ownership. Startup
also does not infer who sent a shutdown signal from a breadcrumb file; the
ordinary shutdown path still records the signal it received.

The design is in [masc restart](../rfc/RFC-masc-restart-replaces-the-workspace-server.md).
The connection-publication changes proposed in
[RFC-0447](../rfc/RFC-0447-port-bind-or-refuse.md) are separate and remain a draft.
