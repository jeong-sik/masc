# Installed-server schedule behavior evidence

See the [behavior report](../../reports/2026-10-26-scheduled-job-runtime-audit.md).
This directory retains selected captures from new disposable-workspace runs;
it does not overwrite the earlier component evidence.

| Run | Probe result | Evidence scope |
|---|---|---|
| `api-extended-1` | 33 checks pass, exit 0 | Actual MCP calls to all seven schedule tools; two named identities, one parallel note submission, recipient authorization, replacement/cancel note retention, pagination and typed errors |
| `retarget-cancel-4` | 17 pass / 1 fail, exit 1 | Explicitly paused, zero-turn A retains the exact occurrence after retarget to B and successful cancel |

Both used installed commit `bc3038a22374705db648bebd7f556223b3e84727`,
executable SHA-256 `833298c99525205f929bab74ee6d45a53601c340bd1b084a2473e183c7663a57`.
The `requested_source` in each provenance file is the checkout observed by the
harness, not the executed server commit. Both owned servers stopped with exit 0.

`api-records.json` retains unmodified request/response records except the large
health response was omitted. The build/path observation is preserved in each
provenance file. The final owner status is a selected-field projection, explicitly
named `owner-final-status-selected.json`; the actual full status response is also
present in its MCP record. All names, messages, credentials and workspaces were
created solely for these probes. Bearer tokens and HTTP authentication headers
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
selected actual API fields, not suite pass receipts. No completed backend suite
result is included here.
