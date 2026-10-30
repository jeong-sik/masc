# Actual scheduled model execution and busy counterexample

These are three owned, isolated workspace runs. They used the existing declared
Ollama Cloud/DeepSeek and Z.AI/GLM providers with environment credentials; retained
configuration contains credential names only. HTTP authorization headers and
credential values were never captured. No production Keeper, schedule, gate or
runtime declaration was changed. The local disposable workspaces and raw captures
remain under `artifacts/scheduled-job-runtime-audit-20261026/`.

| Run | Actual executable commit | Observed result |
|---|---|---|
| `real-deepseek-1` | `1ce158d50d3eb48648e6deea7f668172f914fea3` | One scheduled turn, one exact note authored by the Keeper, note readback, exact Completed/ACK, server exit 0 |
| `real-glm-1` | `1ce158d50d3eb48648e6deea7f668172f914fea3` | Same required effect and completion; three wrong-ID note attempts were refused before the one successful append; server exit 0 |
| `real-busy-deepseek-1` | `6a2d8dd6171e1d732ca15f918fb084e462e4d371` | **FAIL**: second schedule arrives during the first live turn; only second note exists, but both sources are Completed/ACK and no turn remains live |

The busy binary SHA-256 is
`87f8c4afffa1b0b30075f5b2bddfa264edec2d454d972593e68c1068aa5ea548`.
The installed executable changed between the baseline runs and the busy run.
Each provenance file records the binary's own build identity; checkout `24524e6…`
is not the executed program head. The retained derived finding corrects a manually
written stale `scope` commit; its original hash and exact transformation remain
in the manifest. No observed queue/reaction/note field was changed.

`first-busy.json` binds the first source to a live unfinished turn. `overlap.json`
shows both exact sources pending during that same turn. The original
`reaction-ledger.jsonl` records first `turn_finished` with `checkpointed`, then
**first ACK before second turn-start**. Tool receipts show only two loader calls
in the first turn, then the second schedule's get/note/readback calls. The final
snapshot retains empty first notes, one second note and both exact terminal
projections. The checkpoint was saved and resumed; this does not prove loss of
the checkpoint file. It proves early consumption of unfinished scheduled work
and failure to fulfill the original exact request in this observed execution.

The original busy observer lacked a failure oracle for both sources terminal
with a missing effect, so it kept observing. An independent API read verified
both terminals and no live turn before the observer alone was interrupted
(exit 130). `observer-stop.json` records that harness limitation. After another
no-live-turn read, only the owned server was stopped; PID disappearance was
observed, but its exit code was unavailable because its parent had exited.
This is not a clean-shutdown pass. `checks.json` remains the original partial
setup/overlap checks; the authoritative failure is `finding.json` plus the raw
terminal/note/ledger/receipt evidence, not a fabricated probe exit-1 receipt.

The manifest hashes every retained input and capture, records original raw
hashes separately, and describes selected fields and log excerpts. Live turn
control/interrupt tokens are omitted. Baseline snapshots retain exact queue,
reaction and note evidence plus selected owner identity/counters. Checks retain names and decisions; repeated detail snapshots are kept only in their dedicated capture. Tool receipts retain exact input/output, execution ID, model binding and turn identity, omitting repeated resource/action-radius descriptions. Original raw digests and selection rules remain in the manifest. Each
`probe-used.py` is the actual run's reproduction source. The busy script needs
the missing-effect terminal oracle before reuse. No new attempt is represented
by these records.

These note effects are internal durable results. They do not prove Slack/file
or other external destination delivery, provider/account failover, recovery
through interruption, arbitrary effect idempotence, a real sandbox Execute,
Lane package worker execution or TUI interaction. The two baselines are two
successful examples, not a universal multi-model guarantee; the busy run
contradicts whole-feature PASS.
