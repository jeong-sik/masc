# Same-source Addon lifecycle observation

Observed on 2026-10-22 KST (2026-10-21 UTC), in an owned temporary workspace.
This is actual API, Docker worker, browser Dashboard and native TUI execution.
The input is a synthetic phrase-state snapshot. No audio, provider or LLM ran.
This is neither an operator installation nor full54 completion.

## Source and executable identity

- Product source: `6f68dbc38d7c3dfd53fd1ded00f6a4bd3622609d`.
- [Native run 39626945820](https://github.com/jeong-sik/masc/actions/runs/39626945820):
  TUI 24 checks and application 5 checks passed. Original logs and receipt are
  preserved here. The workflow source is a separate identity, `003f52e210d31abe087f0edeba335e5bb095f4af`.
- Both downloaded executables returned the product SHA when executed with their
  build-commit commands. Their hashes and the generated key-reference hash match
  the original receipt: see `native-artifact-qualification.json`.
- Dashboard was built from a clean detached checkout of the same product SHA,
  using offline frozen dependencies. Its emitted `.build-identity.json` identifies
  that SHA. `dashboard-build-files.json.gz` retains all built-file hashes.
  `health-initial.json` records the actual server executable hash, embedded SHA,
  isolated workspace identity and selected Dashboard asset path. This uninstalled
  surface reports some build provenance fields as null; those fields were not
  promoted to installed-release proof.
- The worker used the existing image identity recorded by the inventory. The
  selected package files and hashes are in `public-session.json`; no image tag
  was overwritten and the pre-existing image was not removed.

## Actual sequence

1. Start with the one TOML declaration Off and no worker. TUI Overview command
   `slice {}` sends exactly `/api/v1/lane-addons/slice`, without the formerly
   failing trailing `?`. That endpoint and an explicit empty filter both return
   HTTP 200. Their empty rows have `complete=false`; emptiness was not called
   complete coverage. The original request path is in `transport-events.jsonl.gz`.
2. Dashboard On / off → change draft → Save activity creates a real Docker worker
   `01a15f2e-2d70-7000-b1ff-86b6c9cc5fad`. Both UIs read input `current-input-1`.
   `inventory-on-first.json` records its installation, incarnation, container,
   original row and source-evidence digest.
3. Dashboard Off keeps the TOML. The original worker becomes retained/detached
   with an explicit released container identity. `first-container-after-off.json`
   records its actual absence. TUI `r` preserves the original selected record;
   a Dashboard run Slice reads that same retained row. See captures 09–14 and
   `dashboard-retained-slice.txt`.
4. Preserve only successfully writes original Evidence digest
   `2ed0cb5ec42432edf643fd4393203c6908ade96ded953be8e45c78e683c961a4`.
   **Capture 13 also reproduces a defect:** the receipt remains, but the automatic
   inventory-only follow-up removes retained rows from the current view. An
   explicit detail refresh restores the original row and selection (capture 14).
   The original stored evidence bytes are retained here and match their filename
   digest. This is the reproduction for [#44895](https://github.com/jeong-sik/masc/pull/44895),
   not evidence that its later fix already ran.
5. Closing only Slice reads at the byte-forwarding proxy produces a real EOF
   without a fabricated HTTP response. Capture 15 shows the read failure together
   with the same row, selection and receipt. A different-run detail Slice is
   refused (capture 16); the rejected command remains an editable draft. Escape
   closes that draft before retrying. Removing the fault and refreshing restores
   the original detail (capture 18). The proxy records request paths only.
6. Change the synthetic file to input `current-input-2`, then Dashboard On again.
   The **same installation ID** creates new incarnation
   `01a15f30-3b0b-7000-b3b7-70768510066d`. TUI shows the second result with the
   original first worker's owner-labelled receipt (capture 20). Dashboard run
   history shows both original rows. `dashboard-reconnect-clean-viewport.png`
   is an actual browser screenshot of the running second worker and retained first.
7. TUI **Remove TOML + worker** deletes the actual declaration and stops the
   second worker. API reports zero declarations; the file is absent and Slice
   still returns both old rows (`inventory-after-remove.json`, `slice-after-remove.json`).
   This differs from Off, which retained the file.
8. Dashboard New TOML → Save TOML recreates the same declaration path and ID.
   Input `current-input-3` is read by third incarnation
   `01a15f35-54a5-7000-b929-86084ccafd4e`. Both UIs read its result; run history
   contains all three original inputs. See capture 24 and the reinstallation
   inventory/Slice. Browser snapshots preserve the saved file receipt and its
   separate application-pending state.
9. Final Dashboard Off leaves all three workers retained and all three rows
   readable. Every original container ID is absent on the same recorded Docker
   engine. `owned-container-cleanup-observed.json` preserves the exact command
   results. A preparation helper's case-sensitive expectation of `No such` failed
   on Docker's actual lowercase `error: no such object`; this did not indicate
   a product cleanup failure and the original outputs were not rewritten.
   The owned TUI/server/proxy were then stopped; the two ports refuse connections
   and the original server/TUI PIDs are absent. The proxy terminal tool session
   returned exit 130 after its explicit interrupt; its port is closed. Browser
   task space 29 was finished.

## Reading these artifacts

Numbered `.txt` files are actual manually captured native terminal cells, not
assertions about text or layout. The matching `-cells.json.gz` and raw
`tui-terminal.bin.gz` preserve the terminal stream. Derived terminal PNGs, where
present, render those cells and are not physical-desktop screenshots. Browser
PNG files are actual browser captures; the raw API and snapshots establish the
phase, rather than a filename implying when asynchronous work finished.

The terminal driver and transparent fault proxy are included. There are no new
screen/wording/order tests. Private credential output, token files and private
HOME/XDG directories are excluded. The workspace and package paths in the
receipts identify this isolated execution only.

The direct worker preparation initially omitted the `evidence` array that the
real host adds to source observations. Both failed preparation and corrected
direct-RPC receipts are retained. That caller mistake is separate from the
actual host-created workers, whose source-file evidence was attached normally.

## Follow-up boundaries

The native result above qualifies A01 for this frozen source. A02/G06 still need
the Evidence preservation fix executed, and broader workspace/revision/failure
cases remain. [#44895](https://github.com/jeong-sik/masc/pull/44895) has independent
source review for `d06fc9229f2d46597933526d06863e0473c87874`; the exact native
[request 39631388009](https://github.com/jeong-sik/masc/actions/runs/39631388009)
is a separate candidate. No result from it is claimed in this receipt. The
author accidentally submitted an incorrect full SHA in request 39631235633;
that request was observed queued and cancellation requested. Its mistaken input
and the corrected request are retained separately, never counted as build proof.

The Browser stack has since been restacked to `aa0e05f6fcdfb4d0e5d35650dbbe07f169515971`.
Its updater's original completion message and REST top snapshot are included.
They do not certify its 67-layer source, approvals, build or runtime. It is not
the source of this execution. Candle provider/ledger Off→On and operating-system
installation remain separate requirements in the full worklist.
