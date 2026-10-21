# Independent review: frozen current-native lifecycle and Candle container evidence

verdict: PASS scope: bounded working-tree evidence snapshot by: g01_context_response

No remaining P0–P2 recording/scope error was found in the inspected baseline. This is evidence review, not approval of an as-yet-uncommitted PR head, whole54 completion, or execution of the subsequent preservation fix.

## Exact inspected content

Worktree: `/tmp/masc-addon-evidence-retained-20261022`; branch `docs/addon-current-native-lifecycle-proof-20261022`; HEAD/base at inspection `d06fc9229f2d46597933526d06863e0473c87874`.

Scope is the working-tree content of the two evidence directories and `reports/addon-lane-full-worklist-20261021.md`, including its latest A06 follow-up. The index was being prepared concurrently; the worklist had a staged earlier version plus its final working-tree delta. This verdict binds the actual files below, not an invented committed head or only `git diff --cached`.

- Native directory:125 manifest entries plus manifest; manifest SHA-256 `e188844443de77ccd28d87b6560ef6ef32c69939cbf1dc99dfe06b83f2c30e74`.
- Candle directory:23 manifest entries plus manifest; manifest SHA-256 `254c65de875ec2a9c802c200c7db4ec2269876cb3666df8d0c8b0a24d44dbe6e`.
- Worklist SHA-256 `4f46c04af1de720194b193b321dc9675decee65df074df7f528af43af323c39a`.
- All151 files together: content identity `993cafba40c8a6319fb839274bdf47508151093825feaec04e37aca3f47d7c8d`. This is SHA-256 of `masc-bounded-evidence-working-tree-v1\0`, followed by each lexically sorted repository-relative path, byte length and content SHA-256, each separated by NUL. It is explicitly not the canonical committed Git diff identity.

All entries in both manifests match actual file sizes/SHA-256 and exactly cover each directory other than its manifest. No product source modification is part of this evidence scope. Source6f68, Candle sourced35, subsequent fixd06 and Browser restackaa0e remain different coordinates.

## Resolved publication issues

During inspection, the README claimed the original native suite logs were included while they had not yet been copied into the public files. Both original logs are now included and byte-identical to the native artifact. The author also corrected the manifest after compressing the raw Dashboard build log, preserving its original whitespace rather than rewriting it.

The initial cleanup wording could imply a separately observed proxy PID absence, while the primary shutdown file only covered server/TUI PIDs and both ports. Final README explicitly limits PID absence to server/TUI and separately records the original proxy tool-session interrupt/terminal exit130. This no longer overstates the process evidence. These corrections were made by the author, not by this reviewer.

## Frozen6f68 identity and executed checks

Native source is exactly `6f68dbc38d7c3dfd53fd1ded00f6a4bd3622609d`, run39626945820, workflow source `003f52e210d31abe087f0edeba335e5bb095f4af`. The original receipt, generated targets, suite list/TSV, qualification record and published suite logs agree:24 TUI checks and5 application checks passed. I read the actual successful suite summaries and compared the public receipt and two suite logs byte-for-byte to `/tmp/masc-addon-native-39626945820`.

I compared the existing server/TUI/key-reference bytes with their recorded hashes; all match. Server hash is `070b48ec73a5da0b43a47e0977134482ef34b089d08bdcd01cff12ee23ac8a03`; TUI hash is `1184f859e7183e9193229eac697918b296dfb2f0bfbd6cb5821b44aa62e79a05`. I did not execute these binaries. The qualification records original executed build identities, and the actual captured health response independently reports the embedded6f68 server commit, matching server executable hash, isolated effective base/root and selected Dashboard path.

The actual Dashboard checkout still reports clean, detached6f68. I compared all671 built files against the public build index's lengths/hashes and the emitted build identity. The original dependency/build logs show reuse without downloads and successful build, and health's selected asset root matches that checkout. The uninstalled health response has null build-provenance fields; neither README nor this review converts them to installed-release proof. The four exported package source file hashes also match the frozen6f68 Git objects. This is the documented synthetic phrase observer, not audio/provider/LLM execution.

## Raw captures, actual sequence and screenshot phase

All25 compressed cell captures decode to160×56 and reconstruct their matching TXT bytes exactly. Raw terminal data decompresses to633,830 bytes.102 public files with original capture counterparts are byte-identical, including the manual terminal/transport provenance. I read the terminal driver and proxy: they execute/record the real child/bytes, and the fault path closes only selected Slice reads without manufacturing an HTTP response or logging credentials/bodies.

Raw API/state establishes the lifecycle:

1. The declaration starts Off/inactive with no worker. There is an actual bare global Slice GET, with no trailing `?`; captured successful empty results retain `complete=false`, not total coverage.
2. The same declared installation ID/path creates first instance `01a15f2e-2d70-7000-b1ff-86b6c9cc5fad`, then second `01a15f30-3b0b-7000-b3b7-70768510066d`, then third `01a15f35-54a5-7000-b929-86084ccafd4e`. Their captured application states name the corresponding applied incarnation. Off retains the declaration; Remove yields a complete inventory with no declarations; reinstallation restores the same declaration path/ID with a new instance.
3. Original input1/2/3 source snapshots and final Slice rows retain distinct original owner/row identities. The final Slice has exactly3 rows, one for each original input and instance. All3 workers are then retained/detached, while the declaration remains Off. Actual stored evidence files present in the bundle match their filename SHA-256. The third row's evidence reference remains a reference in the raw Slice; not every historical evidence blob is claimed to have been separately exported by this review.
4. Capture13 preserves the actual one-row evidence receipt `2ed0cb5e…` while the row disappears. Capture14 restores the same row/selection and receipt on detail refresh. This is a correctly retained defect, not fixed-candidate success. Fourteen actual Slice closures and capture15 corroborate read failure with the original row/selection/receipt; capture16 retains the cross-run refusal and editable command; capture18 records recovery.

I visually inspected all3 actual browser PNGs. `dashboard-reconnect-clean-viewport.png` shows the second attached/running incarnation and first detached history. The other reconnect/reinstalled filenames are not reliable phase timestamps: the corresponding images include later retained/detached state. README explicitly directs readers to raw APIs and snapshots for phase and does not claim those filenames alone prove a running reinstalled worker. Capture24 and the reinstallation inventory identify the third attached instance; later history snapshots identify the final retained state. No screenshot/text/layout assertion test was added.

The preparation RPC's omitted evidence-array failure and corrected scripted input remain recorded separately. An exit0 worker process is not used to hide the first MCP isError result. The actual host-created worker records have the source evidence the host adds; they are not equated with that preparation mistake.

## Cleanup and private data

The actual inventory/container cleanup records bind the3 original container IDs to Docker engine `ae0e98fe-d402-4dc7-88a8-685efbd65ae7`; each exact inspect reports absence. The helper's case-sensitive expected spelling error is documented separately from the actual lowercase Docker absence output. Server/TUI PIDs are observed absent and both isolated ports refuse connection. Proxy termination is a separately preserved tool-session exit130, not a separately captured PID absence. The records do not claim an operator deployment or remove the pre-existing worker image.

I internally read the original `.masc/auth/local-admin.token` and secret-bearing values in the original private-login JSON and checked all150 public evidence files, including decompressed gzip data, for exact inclusion. All were absent; no secret value was printed, copied here or sent to another agent. Private-login/token files and private HOME/XDG content are excluded. This is a bounded exact-secret comparison, not a universal external security attestation. Browser space completion is the author's recorded action, not a new browser query performed by this reviewer.

## Frozen Candle container proof and independent audit scope

The included independent audit is explicitly PASS only for d35 Docker worker/container/persistent-volume boundaries. I read that audit and the package's primary records, and independently rechecked all7 recorded source file hashes/blob IDs and original exported bytes against `d35d2559c56814b38615545a5f4f081304bccc05`. Nineteen public primary files with direct original counterparts are byte-identical. The22 original Docker command records all have exit0; all3 container inspect records bind the immutable image, distinct exact container IDs, read-only package mount, same named state volume/owner and normal process exit0. Request/reply counts/IDs match each batch.

The existing audit additionally describes the retained original pending/answered/unknown records, idempotent terminal ACK and changed-input/result refusals, state export and exact-ID/owner cleanup. README cites only that narrow scope. Scripted terminals, normal EOF replacement and a fixture caller are not real host-managed installation Off/On, provider admission/judgment, host Paid, crash/in-flight cancellation or either UI. Engine lease proof is explicitly outside this Candle bundle. Old Python13 and compiled host26 remain separate earlier results; no old result certifies the new Browser head.

## Browser follow-up and54-task preservation

The original updater completion message reports whole67 rebase/push and new topaa0e; the stored REST snapshot identifies that top. The appended independent census narrows this:0/67 currently bound approvals,24 lacking latest formal approval and43 old-head-only, with top dirty. The included merge-tree output actually records a worklist content conflict, so the top dirty signal is not dismissed as API delay. The focused Firefox environment audit is SOURCE PASS for the production environment projection chain, not whole67 review or actual Firefox execution. I read the stated review scope and primary result summaries; I did not re-review all67 source changes or rerun either audit's live queries.

A structured comparison to the d06 parent confirms all54 original IDs, descriptions and completion criteria are unchanged. Only status cells A01/A02/A06/E01/G06/H01 and dated evidence checkpoints change. The original host-owned obligation/provider/settlement/UI and broader workspace/revision/failure criteria remain. The current-native defect stays open for executed-fix proof rather than being counted as lifecycle completion.

## Limits of this verdict

The d06 preservation fix's wrong-SHA request/cancellation and corrected request are retained as separate records. This baseline does not claim that later fix ran; any actual new success or capture-fixed result belongs to its own evidence layer. I did not inspect or query that new result in this review. The report does not qualify aa0e execution, operation installation, actual provider/audio, full E01, Browser67 merge or full54.

No CI/API run lookup, test/build, Docker/browser/PTY execution, runtime mutation, source edit, checkout/ref change, approval publication or merge was performed. Only this private review report was written. A committed PR verdict must later rebind the exact committed head/base/diff to these reviewed file identities.
