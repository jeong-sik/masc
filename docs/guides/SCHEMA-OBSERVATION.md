# Observe schema work in an owned diagnostic run

`masc schema-observe` is an experimental, opt-in server command for a finite
diagnostic run that you own. It records actual schema construction, encoding,
cache outcomes and request scope; it does not run a second shadow encoder or
change cache policy. It is not a production performance or fleet-readiness
verdict. Ordinary `masc start` does not enable it.

Choose an isolated workspace, a free port and a new output directory whose parent
already exists. `--base-path`, `--observation-mode` and
`--observation-directory` are required. Do not point a diagnostic server at the
workspace of a running server.

```sh
mkdir -p /tmp/masc-schema-diagnostic
masc schema-observe \
  --base-path /tmp/masc-schema-diagnostic/workspace \
  --port 18935 \
  --observation-mode identity \
  --observation-directory /tmp/masc-schema-diagnostic/identity-run
```

Modes are `disabled` (no observer binding or events), `identity` (physical schema
identities, operation and cache events without timing probes) and `timed` (also
calling-domain timing and allocation intervals). Physical identity is distinct
from equal schema contents. Allocation is not process-wide; interleaving and
observer overhead are reported rather than subtracted as a calibration constant.
Use matching owned workloads for comparisons and keep each mode's report.

The command starts the server and retains diagnostic events until its owned work
settles during shutdown. Run the intended Keeper workload, then stop this server
normally with Ctrl-C or SIGTERM. The owner writes `report.json` in the output
directory after shutdown. It streams the compact v1 JSON value through a staged
atomic writer, preserving event order and a final newline; it does not build a
second complete JSON tree or report string. The events themselves remain in
memory until shutdown, and the largest event still determines transient chunk
size. This is report serialization after shutdown, not live event streaming.
Payload and parent-directory sync failures are reported rather than treated as
successful publication. No background observation remains after the process
ends. To turn observation off, start the next server with ordinary `masc start`,
or select `--observation-mode disabled` for an explicit comparison run.

The output directory is created exclusively after startup handoff. Reusing an
existing directory fails with `EEXIST`; a missing parent fails with `ENOENT`.
Missing `--base-path` prints an explicit refusal. Choose a new output directory
instead of deleting evidence. Forced process termination can leave no final
report; an empty directory or absent report is not a successful observation.
Report-write errors are failures, and may replace the original server error in
this initial command's finalizer. Keep stderr alongside the report.

The report's `coverage`, `failures` and `active_spans` describe whether all
diagnostic bookkeeping completed. Timing and allocation data can be unavailable
or interleaved. This initial command buffers events in memory, so use an owned
finite experiment; it is not a persistent production recorder. A complete report
certifies the observation's recorded scope, not an installed runtime, sustained
real-model workload, source approval or merge.
