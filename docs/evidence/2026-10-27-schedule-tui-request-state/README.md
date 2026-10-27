# Scheduled Job: actual TUI requests and saved input

An owned native TUI trial now passes the bounded request/state scenario. It selects two Keepers, rereads schedules, and edits the original queued operation with the expected draft after normal input, paste, F9 key sequences and terminal resizes. This extends the [earlier state/file evidence](../2026-10-27-schedule-tui-file/README.md); it does not turn the whole Scheduled Job audit into PASS.

The [original trial4 result](trial4/result.json) and [independent closed-run review](trial4/review.json) describe **one scenario**, with 43 recorded assertions. The controller exited 0. The TUI and server children also exited 0; [cleanup](trial4/cleanup.json) records no forced kill, no lingering setup/inventory children and no remaining currently readable matching owned server. Snapshot inventories are not an exhaustive history of every transient process.

## Source and fixture

The frozen source is C2 `a3950a189b9cc5a7ce82cb725699455d79923f42`, the separate duplicate-source proof vehicle [#46274](https://github.com/jeong-sik/masc/pull/46274). Native producer workflow **Minimal manual checks 40396800146**, execution head `9377c7f3025d68e3856d2afd3762468dabc77813`, ref `main`, conclusion **success**, used that explicit source input. This is an isolated artifact run, not installation or a merge.

The hash targets are distinct files in the extracted artifact:

| File | SHA256 |
| --- | --- |
| `artifact/masc` — server | `1622a35d1082da4fe24d9effb05aec11918d9444288441049c8d6d30cedb415c` |
| `artifact/masc-tui` — TUI | `b0a45e199a808f1968265056b78bc755021a4b1a475093cb7c51356a295ee6ca` |
| `artifact.zip` — downloaded archive | `a9e1eff4b3ddc6b43c14fa2fc48b7f468634d902ff487d9337b57bc4f5cb5927` |

The small [producer receipt](native/receipt.json), [identity verification](native/identity-verification.json), and [trial provenance](trial4/provenance.json) are retained; the executables/archive are not copied into this bundle. The independent review rehashed the 28 recorded local inputs including controller `a97ec74d24c7cca29263d3ad4a78ec80c9e2fa996f31c40b382f51f9c0f00b97` before reporting this result. A receipt is not independently downloadable binary proof by itself.

Only a fresh owned base and two synthetic, manual, paused Keepers were used. The server's existing documented `MASC_HTTP_BASE_URL` was explicitly set to the relay URL in its child environment, admitting the configured public identity alongside its bind identity. The [identity configuration record](trial4/owned-request-identity-config.json) binds the inspected source. Host, request bytes and responses were forwarded unchanged. A separately named, no-bearer [root health prerequisite](trial4/root-relay-health-prerequisite.json) is not a TUI request. TUI/setup/server environments exclude real provider credentials; the canonical dead-loopback fixture has public synthetic auth. HOME was preserved and config/XDG locations were owned.

## What the actual TUI did

[Selected relay observations](trial4/tui-http-selected.json) contain **147 `masc-tui` requests** (145 responses with status 200 and two with status 304) and **one `tui-probe-prerequisite` root request**. No selected capture error was recorded. This is a whitelist of traffic, not a capture of every TUI request or raw authenticated wire. Sanitized/decoded response entities and request bodies retain separate original-entity digests; they are not original wire bytes.

| Behavior | Observed result |
| --- | --- |
| Select A, then B, then return to A | Exact target-filtered responses contain only the selected owner's schedules: seven A responses and one B response. |
| Retain an accepted one-shot | The first A response contains the original schedule instance with dispatch `succeeded`, settlement `accepted`, and `matched_pending`. [Pending acceptance](trial4/pending-accepted.json) is retained. |
| Reread the fleet | A newly created row, absent from earlier successful fleet responses, appears after the refresh input. [Refresh observation](trial4/refresh-observation.json) is retained. Shared polling also exists, so this does not isolate the refresh key as the sole cause. |
| Edit A's original queued operation | One native TUI POST is accepted with status 200. Its request/response match the independent canonical after-GET. The message and text block end in `_WIDE_TYPE_WIDE_PASTE`; narrow ordinary/paste suffixes are absent. |
| Preserve identities and the other owner | A keeps its operation ID, creation time, source, sequence and admission digest; its execution digest changes with the edited input. B's entire before/after operation is unchanged. Both owners remain manual/paused with total turns 0, no runtime attempt/current execution and only their original queued operation. |

[Before](trial4/operations-before.json) and [after](trial4/operations-after.json) operation objects, exact canonical GET bodies [43](trial4/http/00043-response.bin)/[44](trial4/http/00044-response.bin), waiting inventories [45](trial4/http/00045-response.bin)/[48](trial4/http/00048-response.bin), and queued lists [47](trial4/http/00047-response.bin)/[50](trial4/http/00050-response.bin) support those joins. The [final owner status projection](trial4/projections/trial4-owner-status-projection.json) selects explicit fields from the two recorded MCP status bodies and declares their original identities; complete status/config bodies remain local. The [root HTTP index](trial4/http/events.jsonl) also references unretained historical bodies, not just the six retained bodies.

The independent report's source incarnation 0 is a join with the separate final root waiting inventory [45](trial4/http/00045-response.bin), whose `event_queue_pending` row has the same post ID and `source_incarnation="0"`. That field is absent from the TUI schedule response; it was not directly received there.

The [PTY input trace](trial4/pty-input-trace.json) records the normal input/paste baselines, two intended F9 sequences, 120→20→120-column kernel resize readbacks and the final submission. Output was drained, not retained or parsed as ANSI/text. The accepted final draft is evidence of the bounded input/state outcome. F9 recognition/expanded state, a canonical UI resize-processing acknowledgement, narrow-guard causality, painting and row visibility remain unproved.

## Readiness and the earlier incomplete trial

Before sending the first key, controller v5 observed the same TUI PID/session and source capture through requested → accepted admission → applied UI state, plus installed terminal decoder/applied capabilities. [Readiness](trial4/first-input-readiness.json) was observed at `1793056657.622804`; the first keyboard write was `1793056657.623404`. The applied Keeper observation is not proof that a particular name is present or that the palette is usable; the later exact-target requests provide the outcome evidence.

The [selected log prefix](trial4/projections/trial4-readiness-log-prefix.jsonl) preserves exactly 25,987 bytes with SHA256 `3f634ee02fc631a840d0c2cd28770ef748bd25e7b639fcb9bd1fedfbcfc3d1ff`. Its [provenance](trial4/projections/trial4-readiness-log-prefix-provenance.json) distinguishes the observed prefix from the complete later log. It contains structured application/startup observations, not PTY output. The independent review checked the original prefix and selected lines 13/37/39/56.

Earlier [trial3](trial3/result.json) remains INCOMPLETE. It configured the relay identity and obtained actual TUI health 200, but did not reach a qualifying target request before the observer was normally interrupted. Its first keyboard write preceded completion of the HTTP refresh; this is **not** a diagnosis that the palette lacked Keepers. Local Keeper admission actually preceded the first input, and post-apply routine observations were not enabled. The original [stop reason](trial3/root-observer-stop-reason.json) remains unchanged beside the [causal-limit correction](trial3/root-readiness-causal-limit-correction.json). The v4→v5 change adds existing semantic observations; it does not prove a product input-loss cause or repair. Trials 1/2 and their distinct failures remain in the parent bundle.

## Retention and remaining work

[selected-copies.json](selected-copies.json) declares the original repository root explicitly. Removing that exact prefix from each `original_path` gives its key in the selection-time manifest; the corresponding current-location entry gives the retained path. Selection verification checks that relationship and each length/hash separately. The repository location checker then checks the manifest/sidecar and retained bytes; it does not infer absolute-path prefixes. This explains the same relationship used in the parent bundle without changing its historical records.

The [selection-time manifest](selection-time-manifest.json) and [current-location sidecar](current-locations.json) cover 43 selected artifact copies. The explicit prefix/path relationship was also rechecked for the parent's unchanged 80 copies. These are retention checks, not new runtime scenarios.

Some copied artifacts are themselves labelled derivatives, such as projected owner status, decoded HTTP records and the selected log prefix. Byte-exact copying of those artifacts does not make them raw wire or complete original files. Full logs, real credentials, provider inputs/reasoning, PTY output and whole status/config bodies are omitted. Unretained-input hashes in reviews and historical indexes remain evidence identities, not claims that every referenced input is public here.

The captured `controllers/v4-to-v5.diff` keeps its original blank context-line prefixes on lines 13/14. Whitespace validation excludes only that exact captured patch; its original bytes/hash remain checked with the other selected artifacts.

This trial supplements audit rows 52/53/55/56 only within the request/state limits above. Visible overdue notification, F9 appearance, real late-response transport races, draft persistence across process restart, model execution/failover, other-user traffic/general RBAC and production installation remain separate. The actual two-job DeepSeek scope failure [#46281](https://github.com/jeong-sik/masc/issues/46281) remains open.
