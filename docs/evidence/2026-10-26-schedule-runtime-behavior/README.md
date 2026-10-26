# Installed-server schedule behavior evidence

See the [behavior report](../../reports/2026-10-26-scheduled-job-runtime-audit.md).
This directory retains selected captures from new disposable-workspace runs;
it does not overwrite the earlier component evidence.

| Run | Probe result | Evidence scope |
|---|---|---|
| `api-extended-1` | 33 checks pass, exit 0 | Actual MCP calls to all seven schedule tools; two named identities, one parallel note submission, recipient authorization, replacement/cancel note retention, pagination and typed errors |
| `retarget-cancel-4` | 17 pass / 1 fail, exit 1 | Explicitly paused, zero-turn A retains the exact occurrence after retarget to B and successful cancel |
| `restart-expiry-3` | 23 state checks pass, probe exit 0; server exits 124 then 0 | Stored instances, accepted source and notes survive expiry/restart; unaccepted expiry emits no wake; missed interval has one retained wake and a later next due |

The first two runs used installed commit `bc3038a22374705db648bebd7f556223b3e84727`,
executable SHA-256 `833298c99525205f929bab74ee6d45a53601c340bd1b084a2473e183c7663a57`.
The `requested_source` in each provenance file is the checkout observed by the
harness, not the executed server commit. Those two owned servers stopped with exit 0.

`api-records.json` retains unmodified request/response records except the large
health response was omitted. The build/path observation is preserved in each
provenance file. The final owner status is a selected-field projection, explicitly
named `owner-final-status-selected.json`; the actual full status response is also
present in its MCP record. The disposable-workspace runs use synthetic names,
messages and credentials created solely for these probes. The separate backend
request receipts refer to the existing MASC Keeper, not a synthetic Keeper.
Bearer tokens and HTTP authentication headers
were never recorded. The image promotion in the F1 probe only records an already
present host image in the disposable workspace's own catalog; it builds or starts
no image for the test. Keeper registration still starts its keepalive, so the
explicit pause and final zero-turn observation are material preconditions.

The scripts require an explicit installed binary. Run from the repository root,
writing new output under a new `artifacts/` directory:

```sh
python3 docs/evidence/2026-10-26-schedule-runtime-behavior/probe_api_extended.py \
  --binary /path/to/masc --output artifacts/schedule-api-new-run
python3 docs/evidence/2026-10-26-schedule-runtime-behavior/probe_retarget_cancel.py \
  --binary /path/to/masc --image-reference EXISTING_IMAGE_TAG \
  --output artifacts/schedule-retarget-new-run
```

The second probe uses `apple_container` and needs an existing base-compatible
image tag on the host. It refuses registration when the image prerequisite is
missing; a prerequisite failure is not the F1 cancellation failure.
`manifest.json` hashes the retained inputs/captures and records byte comparison of
the relevant backend sources with checkout `9d451a840ff006e70a684cb36d2c1eb69be3f8aa`.

Limitations: a single parallel submission does not prove all interleavings. The
note oracle compares body and author sets separately; independent raw-response
inspection additionally verified the correct body/author pairs in this run.
MCP's named admin credential is an automated actor, so this does not test the
separate `Operator_caller` branch. No actual TUI, successful model execution,
destination delivery, failover, Lane worker or storage fault recovery is proved.

`backend-operation-terminal.json` records the earlier selected-suite request's
actual `Failed / Turn_cancelled` state after a shared server restart.
`backend-recovery-admission.json` and `backend-recovery-observed.json` record a new
recovery request admitted and subsequently read back as `Queued`. These are
selected actual API fields; these Keeper operation receipts contain no completed
suite results. Completed targeted CI evidence is recorded below.

The later `restart-expiry-3` used installed commit
`1ce158d50d3eb48648e6deea7f668172f914fea3`, executable SHA-256
`b6a50b5e88c4730b029af14cd5a6b7a587f69f9535f90c7101caf9711e8c7312`.
It is a distinct execution. The first server reached its installed graceful
shutdown hard-exit guard (124); the second exited 0. State-check success does
not certify clean shutdown or Running-lease fault recovery. Its exact-lookup
responses include wake counts and the retention ceiling, not only queue counts.
The ceiling oracle uses process start; separate raw dispatch-time inspection
also confirmed the possible missed count remains below the ceiling in this run.
Run `probe_restart_expiry.py` with the same explicit binary/image/output arguments
as the F1 helper, using a new artifacts directory. No real provider is contacted.

`targeted-ci-result.json` records Test run 40322812745, exact head/ref and
conclusion=failure; the named five suites did not execute because compilation
failed first. `targeted-ci-failure-excerpt.txt` selects the input list and actual
compiler diagnostic, with trailing line whitespace trimmed. The full failed-step log's original digest is recorded
separately in the manifest; the excerpt does not claim to have that digest.

`backend-recovery-terminal.json` supersedes the earlier queued observation with
the actual `Interrupted_by_restart` failure. `targeted-ci-after-restack-admission.json`
records the new exact-head five-suite dispatch after adopting the existing
compile fix. Neither an admission nor an in-progress run is a completed pass.

`targeted-ci-after-restack-result.json` records the completed **Test** run
40325758202, head `ae6cabc219bccb6eb57726d81c3f8cc99ba3e04e`, ref
`audit/scheduled-job-runtime-20261026`, conclusion **success**. The downloaded
`suite-runner-log` artifact confirms five suites with 52/58/22/56/7 cases (195 total).
`targeted-ci-after-restack-excerpt.txt` retains the targeted runner, suite headings
and success summaries in order, trimming trailing line whitespace. The original
full-log digest and archive digest are recorded separately. This is targeted CI
evidence for that head, not whole-feature, real-provider, installed-binary or F1 repair proof.

The later F3 ownership repair is a separate code head: **Test** run
[40330717541](https://github.com/jeong-sik/masc/actions/runs/40330717541),
head `ed79abfd0500cec731168ab2517969ef30db490a`, ref
`fix/schedule-mutation-authority-20261026`, conclusion **success**.
`authority-fix-ci-result.json` and its excerpt bind the actual artifact to
55/58/9/2 cases (124 total), including the three new ownership regressions.
The four-suite compile and execution are not installation or an actual HTTP
cancel read/retarget interleaving proof. Original full-log/artifact digests are separate.
