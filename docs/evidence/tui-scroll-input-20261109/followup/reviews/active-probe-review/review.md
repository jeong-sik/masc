# Active probe source boundary review

Reviewed source: `ff1cc7700b081c6ce7f1abebea42ef352d518ed5`.
Reviewed helper: `active_probe.py` SHA-256 `6f4332edf51fad53d73ebbcb1908f1bcb07b322a952583b413c2a5749a6b1428`.
Original `mixed_probe.py` remains SHA-256 `b43594f33f14edbe18d07eb98fac62e8a99c3803f74b0a04fd215ed0e0d30efd`.

The 800-message revision is sufficient for a conditional scroll-bound argument at 151 timed writes. Raising history to 2000 is unnecessary for that argument and would change the workload. This review does not establish actual initial scroll, input admission, rendering latency, or a native executable's source identity. No product execution, build, CI query, or Git mutation was performed.

## Changes and fixture preservation

The exact helper and driver bytes, unified diffs, source object identities, and arithmetic are retained alongside this report. The driver still supplies 800 messages and eight logical bullet lines per message. Its new `--messages` option defaults to 800; overriding that option requires recalculating the bounds. The probe CLI default changed from 300 to 800, so the probe itself is not byte-identical outside positioning. In the paired cohort that previously supplied 800 explicitly, history content is unchanged. The positioning counts are 200 PgUp before PageDown, 50 PgUp before WheelDown, and ten PgUp otherwise. Decoder, output ACK search, timed inputs, and timing calculations are unchanged in these diffs.

AST-only extraction of the fixture list comprehension produced 800 distinct IDs, alternating valid user/assistant roles, and eight nonempty bullet lines per message. Its JSON payload SHA-256 is `b1d4d6fa6c3ffc1a1ee129bd2057d57f0460ee5ccc30b138e2dcaca7b584703b`. The probe was not imported or run.

## Source bounds

`rows_of_json` and `page_of_json` accept the whole response list (`masc_tui_keeper_chat_history.ml:1790,1818`). The query-side production history limit does not truncate this helper's response. `msg_entries_of_history_rows` maps all decoded rows (`masc_tui.ml:11004`); owned aggregate/first-page delivery merges those rows (`27735,27825`), and `set_keeper_chat_sources` stores the complete list (`masc_tui_types.ml:21155`). `merge_paged_history` replaces matching identities without a count cap (`21654`). The user/assistant fixture has no tool, memory, selected live-log, or queued-request rows that the ordinary visibility projections fold away. `keeper_message_visible_entries` preserves the number of visible messages (`masc_tui_render_chat.ml:2104`). This establishes client capacity and retention for an accepted full fixture response; a server response counter alone does not establish that acceptance occurred before positioning.

For scrolled history, each nonempty bullet is rendered separately (`masc_tui_markdown.ml:1246,1645`), and `rows_of_entry` retains those body rows (`masc_tui_message_layout.ml:1966`). The live-edge oversized-entry preview and repeated-row collapse do not cap the full scrollback. Conservatively ignoring Record headers, blank lines, wrapping, metadata, and separators gives at least `800 × 8 = 6400` physical rows.

Fixed chrome is eight rows and status-row deductions are nonnegative (`masc_tui_message_layout.ml:762`). At terminal height 45, history height and page size are at most 37. Therefore the full transcript's maximum distance from the newest row is at least `6400 − 37 = 6363`. `set_msg_scroll` initially clamps only below zero (`masc_tui_types.ml:21676`); `clamped_scrolled_rows` clamps the top against the physical row count at render (`masc_tui_message_layout.ml:2521`), and that clamped position is fed back to state (`masc_tui_render_chat.ml:5264`, `masc_tui_types.ml:21932`).

Let P be the stable PgUp/PgDn size, 1 ≤ P ≤ 37; let n ≤ 151 be admitted timed scroll events. Assume every positioning event is admitted after full history and source pins are ready, with no history/geometry changes.

| Condition | Bound after timed phase |
| --- | --- |
| PageDown | Start is min(200P, actual max). If positioning never reaches the top, at least (200−151)P = 49P remains. If it reaches the top, at least 6363−151×37 = **776 rows** remain above the newest row. |
| PageUp | Ten positioning pages plus 151 timed pages cover at most 161×37 = 5957 rows; at least **406 rows** remain before the oldest boundary. |
| WheelDown | 50 positioning pages are at most 1850 rows, so do not reach the top. Each notch moves three rows (`masc_tui.ml:184,1544`). At n=151 the remaining lower bound is 50P−453; it is positive for **P≥10** (minimum 47 rows at P=10). |
| WheelUp | Ten pages plus 151×3 rows are at most 823 rows, well below 6363. |
| Typing alone | Ten admitted pages remain interior while the history and geometry stay fixed. |

`bounds.json` enumerates all 37 stable page sizes. The WheelDown minimum-page condition is material: P=9 would put 50P=450 rows above the newest row and 151 notches could return to zero. The complete status frame and its asynchronous/error rows prevent deriving a universal P≥10 from terminal dimensions alone. Observe actual geometry/anchors for this case; do not claim unconditional WheelDown safety from request count.

`keeper_message_page_rows` reserves the reading-back notice on both directions (`masc_tui.ml:993`), avoiding a one-row page-budget change when leaving the live edge. The default typed text and nonce contain no newline; `composer_extra_rows` counts logical newline lines (`masc_tui_types.ml:21701`, `masc_tui_message_layout.ml:694`), so this typing does not grow the reserved composer rows. The fixture sends no timed model reply or history update. Other asynchronous status changes remain a runtime qualification to the stable-P argument.

At width 150 the Activity pane does not intercept the helper's wheel at column 100: the narrow pane is 56 columns and its minimum surface inner width is 100, so the threshold is above 150 (`masc_tui_acting_pane.ml:21,39`, `masc_tui_render_schedule.ml:170`). The chat reader deliberately returns no generic wheel movement (`masc_tui_render_prim.ml:264`), leaving the three-row chat handler to process it. A changed terminal width or pane/modal state requires rechecking routing.

## Actual-position and FIFO limitations

The final draft-prefix ACK is not a drain barrier for scroll writes that were enqueued after that final typed character. If no complete frame exists after the last timed scroll write, retain the boundary-unconfirmed qualification.

The nonce emitted after positioning is a useful FIFO barrier: reaching that input in the TUI means the preceding terminal bytes have been consumed in order. It does not establish that every preceding scroll event changed the chat scroll. In particular, `set_msg_scroll` forces a painted empty Follow_live pin with no points back to zero. Keys may have been consumed before the history was applied or while ownership/admission denied scrolling. Waiting for a successful server response plus fixed sleeps does not independently prove a full chat projection was painted before the first positioning key.

The pin conversion does not itself shift an unchanged transcript: with a surviving source byte, the saved suffix minus rows_below restores the saved pin_scroll, and the requested delta is then added (`masc_tui_render_chat.ml:3795`). A removed/unresolved source byte can instead fall back or reset to zero. Therefore full static-history retention removes the expected drift, but the helper's request count and nonce alone do not prove that a valid pin existed.

The helper's `has_more=false` makes the footer a poor boundary detector. At **any** positive clamped scroll with no older page, the current renderer prints “the start of this conversation” (`masc_tui_render_chat.ml:4681`). That text does not establish oldest-boundary clamp. Likewise, concatenated ANSI-stripped output mixes frames and cannot identify the actual final visible Record.

## Concrete observations from retained captures

No new instrument is required to qualify the upcoming cohort, but the following checks should be made on retained captures where feasible:

1. Audit `result.json` for actual fixture count/line count, terminal dimensions, helper identity, positioning count, timed write count, ACK/errors, and the final observation window. If n exceeds 151, recalculate these bounds with that actual n. Do not label a write as an admitted movement solely because its `os.write` completed.
2. Reconstruct the terminal screen **offline** from raw timestamped chunks at completed frame boundaries, honoring CSI cursor/erase semantics and excluding OSC/DCS contents. Do not use the diagnostic PlainText stream as a screen emulator. At the last completed frame before timed input, identify visible synthetic Record indices and compare them with the 800-message history; this must be an interior history viewport rather than an empty screen or the newest record's tail. The nonce may be emitted in a different portion of a frame, so use the enclosing completed frame.
3. Inspect completed frames through the phase and the final completed frame after the last timed write. For monotonic PageDown/WheelDown on unchanged history, an interior final viewport means the newest boundary was not previously reached, because further down-only input could not leave that boundary. PageUp/WheelUp use the analogous oldest-boundary check. This is evidence only if the condition's events actually targeted chat and the reconstruction is complete.
4. Use `Record i` headers together with their body and chronological order; a header may lie above a partial message and identical bullet bodies do not identify a record by themselves. If the raw capture cannot establish the visible Record identity, preserve the result as **boundary-unconfirmed**. Do not infer an exact row offset from a Record number alone, since wrapping, separators, and metadata add rows.

These observations can establish that the timed window stays interior without changing the timed workload. They still do not prove every individual scroll write produced movement, or measure physical display latency. Source/fixture bounds, actual-position evidence, and draft-prefix emission latency should remain separate claims.
