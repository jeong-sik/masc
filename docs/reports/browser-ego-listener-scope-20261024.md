# Browser ego session: listener ownership repair

This repair extends Native Stack #45537 above #45632. The seven existing
heads stay unchanged; integration must include the new repair layer and all
seven prerequisites together. The stack targets main
`c2dfa238ebd318a9152e70d874ac2cbf68ae2ad8`.

## Actual failure

[Test run 40059360776](https://github.com/jeong-sik/masc/actions/runs/40059360776)
compiled and executed four selected native suites at exact head
`4f94c17aebc6e307ba442c82de258c75ca2efdfe`:

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `test_browser_ego_peer` | 29 | 0 | 0 |
| `test_browser_task_capabilities` | 14 | 0 | 0 |
| `test_browser_controls` | 15 | 0 | 0 |
| `test_browser_addon_live_ego` | 5 | 6 | 0 |

The overall run failed. The live-session cases for command reuse/restart,
cancelled startup, worker retirement, late results, interrupted reads and an
operator-held space failed. The first two commands and the assertion that the
socket path disappears after connection succeeded before restart failed with
`Unix.Unix_error(Unix.ENOENT, "unlink", "/tmp/.../s")`.

## Cause and repair

`start_session` attached the listener to the process switch, closed it and
manually unlinked its path immediately after accepting a connection. Eio 1.3's
[Linux listener implementation](https://github.com/ocaml-multicore/eio/blob/v1.3/lib_eio_linux/eio_linux.ml)
also registers an unconditional path unlink on that switch. Closing the
listener leaves this hook registered, so releasing the process switch later
unlinks a path already removed by MASC and raises `ENOENT`. The
[POSIX listener implementation](https://github.com/ocaml-multicore/eio/blob/v1.3/lib_eio_posix/net.ml)
has different explicit-close cleanup, explaining why the original macOS
execution did not expose the Linux failure.

The listener now belongs to a nested handshake switch. That switch closes and
removes the listening socket through Eio before publishing a connected session.
The accepted flow, child process, pipes and output-draining daemon remain owned
by the outer process switch. The existing process lifetime, failed-handshake
cleanup, cancellation, restart, timeout and retirement behavior remain in that
outer scope. MASC no longer closes or unlinks an Eio-owned listener separately.
The pre-listen cleanup of a stale path remains before Eio takes ownership.

No backend detection, retry, timeout change or ignored teardown exception was
introduced. The existing live-session suite already exercises the reproduced
failure, cancellation and worker lifecycle, so it is the focused executable
verification target for this repair.

## Evidence boundary

`ocamlc -stop-after parsing lib/browser_addon_live_ego.ml` and
`git diff --check` passed after the repair. These checks establish syntax and
patch cleanliness only. No local Dune build was run.

A new selected Linux `test_browser_addon_live_ego` execution is required for
the repaired source. A dispatch alone does not establish its result. The three
passing suites above remain evidence for their historical tested head; they
are not relabelled as execution of this repair. The fixtures launch real
processes and exercise actual host/worker lifetime but substitute the ego
process; they do not prove an installed ego browser session, current iframe
behavior, UI behavior or whole-stack approval.
