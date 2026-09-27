# Linux TUI artifact comparison

`bench-tests.yml` with `compare_tui=true` consumes two successful
`linux-x64-probe.yml` artifacts on Ubuntu 24.04. Supply each run ID, artifact ID
and full source commit; it downloads and verifies the original ZIP, repository,
workflow, run success/attempt, all four executable hashes and ELF64 x86-64
headers before launching the TUI. No server, local build or Release dispatch is
needed. The verifier is the same `linux_probe_artifact.py` used by the server
comparison (#39409).

The repeated-input scenario and its receipt validator are unchanged: each
input waits for the requested complete PTY frame, retained Channels must be
fully read before returning to Info, and alpha/beta fixture identity, input
order, frame timing and whole-session child CPU receipts remain checked.
`input_cycles`, `repetitions`, `retained_channels` and `keeper_metadata` retain
their meanings from the existing repeated-input harness (#39263).

The downloader sees the job token. The scenario/TUI environment carries only
PATH, LANG, LC_ALL, TERM and TZ from the driver, plus the owned frame-timing
path. It receives no inherited MASC configuration, HOME or GitHub token; the
scenario creates its own workspace and HTTP fixture.

Raw stdout/stderr, each accepted receipt, internal frame timing and both
verified identities are uploaded even when a later session fails. Failed or
incomplete sessions produce no aggregate success. SIGINT/SIGTERM asks the
scenario owner to reap its TUI; forced runner termination can still interrupt
cleanup and upload. The result measures acknowledged PTY output including
observer and OS costs, not physical display latency or the production server.

Earlier macOS measurements keep their archived observer/source identities.
They cannot establish Linux latency. An adapter smoke using two binaries with
unchanged TUI source demonstrates harness execution only; it does not establish
an optimization effect. The 0.1 ms goal remains independent of scenario success.
