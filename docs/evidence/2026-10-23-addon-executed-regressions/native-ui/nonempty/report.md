# Nonempty original-result preservation — actual follow-up

**OBSERVED PASS** for this isolated native first-party source→lane_output→statistics path and original-result/current/history separation. No P0–P2 blocker observed on the exercised path. This completes the previously empty-input observation gap only; it is not Agent/model/browser/Dashboard/whole-goal proof. The prior empty-input report is unchanged.

## Candidate and real input

Same downloaded source `a6fba325404c963061b7b95c4c564e35f5ea5e2e` (native run 39928840589, workflow 9bf443caaeaf8c54db442c64cfb90d87d6b7cf26), server/TUI hashes re-read and full-health embedded server commit recorded. Fresh isolated workspace `/tmp/masc-addon-nonempty-review-20261023/workspace` at port 57157, private HOME/XDG/config. Only privately copied native launcher and unmodified first-party Python `vst-phrase/server.py`, `output-statistics/server.py`, and shared `protocol.py` run. Manifests explicitly adapt runtime to host_process and remove container-only fields. Their source/deployment hashes are recorded. No mocked service/model/worker or injected completed host record.

A valid declared snapshot_file supplies one known-failure phrase observation (v1), then two observations (v2). This is explicit local input data, **not actual VST/audio rendering or playback**. Source binding: `phrase-source` / run `nonempty-review`; statistics binding: `source_id=phrase-input, kind=lane_output, installation_id=phrase-source, output_id=phrase, selection=latest_completed`.

## Actual observed results

| Evidence | Observed result |
|---|---|
| 01-source-save, 02-source-inspect | Real CAS declaration create: durable file receipt; actual source worker `01a1681c-35b8-7000-b89c-4aa711972d7e` attached and returned1 row |
| 03-statistics-save, 04-nonempty-inspect | Actual statistics worker `01a1681c-664d-7000-9b12-e905430e98a5` returned count1, value1, input_complete true, original source seq1 and exact upstream row/evidence coordinates |
| 05-original-statistics-selected | Actual PTY selected and read the original statistics row |
| 06-statistics-off-save, 07-original-selected-after-off | Actual CAS save disabled worker; original result stayed selected through detaching/release |
| 08-source-observe-v2, 09-source-v2-and-off-settled | Declared local input changed to2 supported observations; actual upstream worker completed sequence2 with2 rows; statistics Off settled inactive |
| 10-statistics-reconnect-save, 11-reconnected-inspect | New statistics instance `01a1681d-74da-7000-af11-ca81ee22e3a2` consumed source seq2, returned count2; original instance retained |
| 11-original-selected-after-reconnect | Refresh kept original result selected, detached, count1/upstream seq1, instead of replacing it with the current result |
| 12-original-raw-details, 12-original-slice-reread | Exact original row ID/provenance/evidence readable via real TUI raw details and actual API Slice; retained Inspect separately supplies original metadata/native release |
| 15-new-statistics-result | Explicitly selected the current replacement result: count2/source seq2 |
| 16-original-history-reopened | Reopened retained original: count1/source seq1 |
| 17-current-selection-restored | Switching back restored separately remembered current result: count2/source seq2 |
| 20-original-row-after-cleanup | Original row remains byte-equivalent after canonical JSON serialization even after final Off of both packages |

Original row `01a1681c-664d-7000-9b12-e905430e98a5/1/451835066f530213e751185322c2adce610e570bdf8c9bf48c52a124c2303721`. Before/after canonical SHA256: `5618464d5328c1b28c7909659fbc42baedc8e9ae52bbb623502c74a65f1509aa`. Structural equality includes evidence `lane-evidence:6a8945f8563b5784618ce84003c3028791daea896f7a860b6fde9a543a0931e9`. The original native release receipt is equal before and after final cleanup. Actual API file-write receipts are retained separately. No action-receipt proof is claimed: the first-party phrase row explicitly declares `action_receipt=false`.

## Evidence and limits

Raw HTTP requests/responses (bearer omitted), local input v1/v2, submitted declarations, complete raw PTY stream, command events, cell captures,7 cell-rasterized PNGs and20 durable runtime records are under `/tmp/masc-addon-nonempty-review-20261023/evidence`. See `final-preservation-analysis.json` and `evidence-manifest.json`. Screenshots are explicitly offline rasterizations of actual PTY cells with supplied default colors, not OS screenshots/physical paint measurements. A representative preserved-result image was visually inspected. No screen assertions or new tests were made.

Scoped Inspect returns instance metadata without row bodies; result bodies were read through actual Slice. Slice's coverage envelope is not assumed frozen with the row: preserved producer/coverage provenance inside the original result fields was checked independently.

All source/statistics declarations were saved Off through real API, three instance records retained native release/consumed history, own server/TUI/worker PIDs ended and the port is available. No live workspace or installed binary was modified. No Docker container, Agent/model/provider, browser, Dashboard, server-restart recovery or audio device exercised. Launcher build source remains unverified. No source changes, Dune, build/typecheck/executable tests, CI polling, public push/PR or approval.
