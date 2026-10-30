# Scheduled Job: focused TUI state checks and an actual file effect

This bundle extends the [durable-request evidence](../2026-10-27-schedule-durable-runtime/README.md). It preserves failures as well as the successful file scenario. It is not a whole-feature verdict, installation, or merge record.

All actual runs use the frozen, isolated C2 source `a3950a189b9cc5a7ce82cb725699455d79923f42` from Draft [#46274](https://github.com/jeong-sik/masc/pull/46274). C2 is a duplicate-source proof vehicle, not a merge target. Its native producer is workflow **Minimal manual checks**, run **40396800146**, execution head `9377c7f3025d68e3856d2afd3762468dabc77813`, ref `main`, conclusion **success**, with explicit source input C2. The server executable SHA256 is `1622a35d1082da4fe24d9effb05aec11918d9444288441049c8d6d30cedb415c`; the matching TUI SHA256 is `b0a45e199a808f1968265056b78bc755021a4b1a475093cb7c51356a295ee6ca`.

## Existing TUI state tests: eight passed

Workflow [**Test 40409087814**](https://github.com/jeong-sik/masc/actions/runs/40409087814), execution head C2, ref `ci/schedule-durable-candidate-20261027`, conclusion **success**, ran only existing `test_tui_loading_notice` with `minimal=true`. The [raw suite output](focused-tui-state/member-0.txt) records **8 passed, 0 failed, 0 skipped**. The [independent evidence review](focused-tui-state/tui-state-focused-test-independent-review.json) checks the downloaded ZIP/member identities and the source/head bindings.

One case covers schedule target and generation decisions: late A results/errors cannot replace B, an old generation cannot regress a current page, a failed refresh preserves the last read, and the chat target remains authoritative while the roster selects another Keeper. Seven other cases cover shared wait/timing decisions. These are eight existing cases, not eight actual scheduled-job user scenarios. They do not prove transport interleaving, painted UI, F9, narrow-terminal input, or full CI.

## Actual file trial 1: failure preserved

The [original result](file-trial1/result.json) remains **FAIL**. DeepSeek issued one Write with the exact requested 71 UTF-8 bytes, but its MicroVM dependency reported `microvm_shim_missing`. The [final raw tool ledger](file-trial1/workspace/.masc/tool_calls/2026-10/26.jsonl) contains that failed Write and a later read-only `keeper_lane_status` reporting the dependency failure. The original observer's earlier one-call snapshot is retained separately in [all-owned-tool-calls.json](file-trial1/all-owned-tool-calls.json).

There was no Read or success marker. A later Completed/ACK is source execution bookkeeping, not successful file creation. [Fresh post-failure observation](file-trial1/root-post-failure-readonly.json) found the exact original source completed, the Keeper idle, and zero notes. [Owned cleanup](file-trial1/root-owned-server-stop.json) reverified the executable and command before SIGTERM; the PID disappeared, but its non-parent exit status is unknown. The [offline review](file-trial1/review.json) discloses the reviewer's controller authorship and is not an independent source approval of that controller.

## Actual file trial 2: one bounded scenario passed

The [result](file-trial2/result.json) is **PASS**. The [independent runtime evidence review](file-trial2/review.json) directly correlates the raw ledgers, execution API observations, primary schedule, and original source identity. Its 88 recorded checks, including repeated checks, describe **one scenario**.

The environment change was explicit: before starting the new owned server, the controller copied an existing, pinned Linux AArch64 guest shim and matching SHA256 sidecar into that fresh base's canonical `.masc/microvm/shim` directory. [Source and destination identities](file-trial2/guest-shim-copy-verified.json) match. No primary config, `.conf`, `.env`, or alternative `.bin` was copied. The asset's release/source provenance remains unknown; matching bytes alone did not establish protocol compatibility.

The actual [tool ledger](file-trial2/raw/tool_calls/2026-10/26.jsonl) then records:

1. One successful Write, `mode=overwrite`, `bytes_written=71`, `via=microvm`.
2. A successful full Read of the same logical guest target: 71 bytes, two lines, `truncated=false`, exact nonce, LF, Korean and emoji, with no final newline.
3. Tool discovery, followed by one exact marker note on the original schedule after the Read.

Write completion was `1793054821.656139`; Read completion was `1793054822.91141`; the primary marker was created at `1793054825.369285`, before its tool completion at `1793054825.402565`. The complete content SHA256 is recorded in the review. All four execution IDs join the same original source and incarnation 0, then Completed/ACK. [Final source/execution proof](file-trial2/source-execution-proof.json) and [process-ended receipt](file-trial2/process-ended.json) retain fresh terminal/idle observation and normal server exit 0, without restart or forced kill.

The selected execution output strings are sanitized/reserialized representations; their parsed values match the raw tool records. Byte-exact raw JSONL is retained separately. The path returned by Write/Read is a logical MicroVM target, not proof of a host file. This is actual backend Read verification, not an independent guest-filesystem export, external-channel delivery, provider failover, or a repair of the two-job DeepSeek scope violation [#46281](https://github.com/jeong-sik/masc/issues/46281).

## Actual TUI trial 1: incomplete controller observation

The [original result](tui-trial1/result.json) remains **INCOMPLETE**. The [source investigation](controllers/tui/compact-health-baseline-bug-source-review.json) withdraws the earlier controller source PASS: the initial Overview requests compact `/health`, but the v2 selector accepted only `/health?full=1`. Waiting for that selected receipt before sending keyboard input formed a circular baseline gate. The [one-line v3 delta](controllers/tui/v2-to-v3.diff) repairs this selector; it does not establish runtime success.

The closed run also had failed refresh aggregates and an empty canonical startup-attempt file. Therefore the selector bug is not established as the only cause. The [lifecycle record](tui-trial1/owned-lifecycle.json) distinguishes an attempted startup from a successful/live detached server. [Cleanup](tui-trial1/cleanup.json) records TUI/server exit 0, no remaining readable matching owned server, and no forced kill. The [explicit observer-stop reason](tui-trial1/root-observer-stop-reason.json) is separate from a producer deadline or a product failure.

PTY output was drained and hashed, never parsed or retained as text. No screenshot, wording, layout, row order, F9 appearance, or paint assertion was made. Rows 52–57 of the behavior audit remain only partly covered.

## Actual TUI trial 2: relay authority refusal observed

The selector-fixed controller exposed actual compact-health responses: [selected TUI observations](tui-trial2/tui-http-selected.json) record the `masc-tui` actor receiving HTTP 400 and the same 103-byte response-entity digest. A [separate root diagnostic](tui-trial2/root-relay-compact-health-diagnostic.json), explicitly named `tui-probe-diagnostic` and carrying no bearer, read the corresponding error body: `request_authority_untrusted`, because the request Host was not a configured server identity. Its response bytes have the same SHA256. The root diagnostic is not a TUI request or a substitute for one.

The [independent closed-run review](tui-trial2/review.json) corrects the root stop receipt's count label without editing that receipt: the final 77 selected events are **76 actual TUI requests plus one root diagnostic**. The original `tui_observations: 77` field counted the combined set. Two retained pre-TUI HTTP response bodies support the manual/paused/zero-turn baseline; this is a precondition observation, not an all-run model-execution proof.

The raw relay preserved the TUI Host, including the relay port, while the server had only its original configured identity. The server's refusal is consistent with its authority boundary. The documented existing `MASC_HTTP_BASE_URL` setting is the configuration path for a public/reverse-proxy identity; this trial had not configured it. No Host/header/response rewriting or authority bypass was used to make the observation pass.

The [result](tui-trial2/result.json) remains **INCOMPLETE**, with an [explicit normal observer interruption](tui-trial2/root-observer-stop-reason.json) after the failed prerequisite was established. Keyboard scenarios were not reached. [Cleanup](tui-trial2/cleanup.json) records both owned children exiting 0, no remaining readable matching owned server, and no forced kill. This is a test-environment authority refusal, not proof that scheduled-job target switching, F9, narrow input or overdue notification is broken or working.

## Retention and limits

[selected-copies.json](selected-copies.json) locates each selected immutable copy with its original path, byte length and SHA256. Historical paths inside copied receipts are preserved; the map supplies their current retained locations. Hashes in reviews can also refer to explicitly unretained local inputs such as server logs, large repeated API captures, the native archive, or guest assets. Those hashes are not claims that every input is in this public bundle.

[current-locations.json](current-locations.json) is the repository checker's location sidecar. Its [selection-time manifest](selection-time-manifest.json) records the 80 selected source paths and hashes at retention time; it is not presented as a manifest emitted by an earlier producer. All 80 locations are frozen retained captures, including the executed controller copies.

No bearer files, real provider credentials, private provider wire/reasoning, whole health response, guest binary, or PTY output body is retained. The canonical dead-loopback fixture's public synthetic auth is not a real provider credential. Executed controllers and synthetic request bodies are retained intentionally. Their historical invocation paths describe these owned trials; they do not authorize adopting an existing output directory or replaying a failed job.

The earlier GLM observer failure and DeepSeek two-job request-scope failure remain in the parent bundle. Exact HTTP race forcing, visible overdue notification/F9/narrow interaction, long calendar behavior, model/account failover, nonempty Lane recovery/effect-unknown handling, external delivery and production installation remain separate work.
