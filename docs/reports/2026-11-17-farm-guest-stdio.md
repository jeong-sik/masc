# Farm guest-agent interactive stdio

The previous host port accepted OpenSSH and microVM per-request processes but
refused the default Guest Agent. This change connects that route to an owned
socket session. This is source implementation, not deployed VM or reader proof.

## Request and ownership

Relay version 2 adds `Interactive_run` (`I`). Each connection must supply the
actual matching hello, read-only root, expected Keeper uid/gid and no-new-privileges
before the host sends any request byte. The port validates a V3 Interactive frame
with no initial payload before connecting. The existing managed-guest boot identity
already includes Relay.version; no second capability registry is introduced.

`Run` and `Probe` retain their finite queued-input-before-EOF behavior. The Linux
interactive relay detects send-half-close independently of a full input queue,
discards pending input and closes shim stdin to cancel. It continues forwarding
stdout/stderr. A disconnected peer also loses its undeliverable output queue,
while the relay drains and reaps its owned child. Final output remains nonblocking;
if the existing cleanup grace ends before delivery, the connection ends without
an Exit chunk. No Exit means the host cannot assert transport completion.

The host uses one chunk decoder and a rendezvous stream for exact stdout.
A normal callback return shuts down the socket send side, drains unread stdout
and stderr, and waits for the actual relay Exit. Callback failure and cancellation
close the owned connection. Reconnection is limited to failed connection/hello
attempts before request writing. Callback exceptions are not classified as socket
I/O failures, and primary errors survive secondary cleanup failures.

The remote preparation freezes a closed process or guest carrier. Its endpoint
lease covers the complete session. Required runtime context is obtained before
lease acquisition or a control probe, so an uninitialized process helper cannot
fall through to a Unix probe. A guest requires Eio network/clock, not a process
manager. Owner dispatch happens after the accepted guest hello and before request
writing. The first write attempt changes execution evidence to possibly dispatched.
Completion consumes an actual local process status or guest Exit and checks the
prepared carrier, request major and receipt mode; it never invents a guest PID.

## Evidence and remaining work

- Full-file OCaml parsing, native fallback C syntax, shell syntax, embedded Python
  parsing and whitespace checks were performed. These are not type/link checks.
- The authored relay fixtures use the real relay and shim, including dependent
  binary exchange and kernel-observed input/output pressure. Existing finite EOF
  cases remain. Host fixtures separately script hello/refusal/exit facts, dependent
  exchanges, half-close drain and a missing Exit.
- The remote guest fixture uses the real host port and MCP Channel for initialization
  and two complete results with a scripted local peer. Its hello and sandbox receipt
  are fixture data, not proof of a mounted guest or applied sandbox. It also checks
  that no process runtime or local carrier is used.
- These new fixtures have not been compiled or executed. Independent source review
  and any later execution are recorded separately against their exact candidates.
- Real managed guest replacement, network/VM execution, repeated sessions and
  recovery of original retained operations still require observation. No installation,
  runtime restart, request replay or merge was performed for this change.
- External reader declarations, durable owner/Gate/replay settlement and the actual
  DOCX path remain subsequent Farm work. This transport does not establish them.
