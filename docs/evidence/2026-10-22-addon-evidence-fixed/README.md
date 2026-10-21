# Retained Evidence view: exact-source execution after the fix

This is a separate execution from the [6f68 reproduction and lifecycle record](../2026-10-22-addon-current-native/README.md).
Product source is `d06fc9229f2d46597933526d06863e0473c87874`, the code head of
[#44895](https://github.com/jeong-sik/masc/pull/44895). Workflow source is separately
`c3efec4db0a32c1bac8d298ccadd7506e06ec16f`.

## Build and actual execution

- [Run 39631388009](https://github.com/jeong-sik/masc/actions/runs/39631388009)
  completed successfully: original TUI24 and application5 checks passed. Both
  executables' actual build-commit output and SHA-256 match the original receipt.
  `native-artifact-qualification.json` records those comparisons.
- A clean detached checkout of this product source built matching Dashboard
  assets with offline frozen dependencies. Their source identity and all file
  hashes are retained. **This second execution did not open that Dashboard in a
  browser.** The earlier actual two-UI lifecycle remains scoped to 6f68.
- Restart the owned isolated server using the original temporary workspace,
  private HOME/XDG and local credential. Its declaration remains Off, so no
  worker is started. The actual API still reads all three original retained
  bindings and rows across that server restart. `health.json` records this new
  executable and the same physical workspace identity.
- Run the matching native TUI, open retained history and select the **original
  first worker**, `01a15f2e-2d70-7000-b1ff-86b6c9cc5fad`, and its original record
  `01a15f2e-2d70-7000-b1ff-86b6c9cc5fad/1/e8e8b75037064ace8cb1bde36d94521f726b782d9295136ffc7e04d0f326da1d`.
- Close only its Slice read at the original transparent proxy, then press `r`.
  Capture 05 contains the real EOF failure together with the original result.
- Mark that row and choose **Preserve only**. Capture 07, taken immediately
  after the successful receipt, contains the **same selected row, original
  evidence, owner-labelled receipt and existing detail-read failure together**.
  No recovery refresh was required to restore the row after preservation.
- Remove the read fault and refresh (capture 08). Preserve only again in that
  normal state (capture 09): the same selected row and receipt remain. The next
  Installation view shows the original installation Off and all three retained
  incarnations (capture 10). That view is an observation, not a claim that every
  application failure or concurrent ticket case was executed.

The preserved Evidence digest is still
`2ed0cb5ec42432edf643fd4393203c6908ade96ded953be8e45c78e683c961a4`.
`original-preserved-evidence.json` is the actual stored file and hashes to that
digest. No Broadcast or external message was sent by either preservation.
The raw terminal stream, manually captured cells, commands and HTTP method/path
events are retained. These are manual observations, with no screen assertions
or fake HTTP response. Drivers are the unchanged scripts published with the
earlier record; this run uses `public-session.json`'s separate capture/port/binary
configuration. Private credential/login output and server log are excluded.

## Source review and remaining scope

The independent source review initially identified that clearing application
state before an Evidence request would erase its last observation. The final
head uses the existing `Application.suspend` to retire that ticket and retain its
last result or failure. The review report and formal current-head approval
snapshot are included. That source analysis and this actual result are distinct
evidence. Navigation/workspace replacement and Broadcast ACK recovery were not
newly executed in this manual run.

The earlier erroneous-source request39631235633 remains recorded in the earlier
receipt and is not counted. The final server/TUI/proxy were stopped; original
process checks and closed ports are in `shutdown-observed.json`. Retained data was
kept. No operator runtime was replaced, no LLM/provider/audio ran and no Candle
obligation was settled. No new On/Off/removal sequence was executed in this second
candidate, so the earlier lifecycle is not silently promoted to this source.

This proves the reproduced Evidence-preservation defect is repaired for this
observed path. Broader A02/G06/H01/H03 boundaries, Browser67 integration, E01
host-managed Off/On/provider/settlement and the other full54 work remain open.
