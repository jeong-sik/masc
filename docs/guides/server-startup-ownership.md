# Server startup ownership

`masc start --base-path <dir>` acquires the workspace's BasePath lease and
binds the configured HTTP address and port. The listening socket owns the
port. A busy port causes startup to fail; startup does not terminate its
holder or retry the bind with a delay.

The BasePath lease separately prevents HTTP and stdio processes from owning
the same workspace concurrently. Its recorded PID is observational: inspect
the owning service or container on the correct host before stopping it.
Stop the confirmed owner through its operator controls before starting a
replacement.

Startup does not read, create, overwrite or remove a port-specific PID file.
A file named `masc-<port>.pid` does not establish listener ownership. Startup
also does not infer who sent a shutdown signal from a breadcrumb file; the
ordinary shutdown path still records the signal it received.

This boundary does not implement the predecessor-advertised handoff or
connection-publication changes proposed in [RFC-0447](../rfc/RFC-0447-port-bind-or-refuse.md).
That RFC remains a draft; these are separate changes.
