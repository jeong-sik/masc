# Direct h with no connected browser

Native source `78049dd1685e531445af721c506c2e92cf3b6958`, run 34705173638,
was used for this separate capture. report.json records server/TUI SHA-256,
observed server build and empty browser client inventory. Capture exited 0;
server cleanup recorded -9 (SIGKILL), so graceful server shutdown is not proven.
Unlike the parent-directory 3e4 proof, **via_automation is false**: capture input
went directly from disconnected Browser Lane to h, then ] through four retained
observations and [ back. No browser session was opened.

Four OSC52 contexts match actual authenticated tool-call API receipts, timestamps,
artifact hashes/lengths, document IDs, URLs and truncation. Their producer is still
the earlier fb8d2a Keeper run. Identical blobs are reused from ../observations;
this consumer run does not establish later producer behavior.

Run `python3 audit.py` for the offline checks. The clean Overview4/4 PNG/text is
an xterm replay of the exact full-PTY prefix in boundary.json through FRAME_END.
The audit rejects stale Alpha body below the four navigation rows. Rerender via
`python3 ../replay.py overview-complete.pty --columns 130 --rows 35 --output overview.png`.
This uses real render completion and overlay disappearance, not a fixed delay.
It is a terminal replay, not a Firefox screenshot or a new runtime execution.

native-fixtures.log separately records the connected synthetic scenario and the
disconnected h/older-select/Q scenario. Those fixture results are not extra real
Keeper executions. capture-original.py preserves the actual authenticated capture
procedure with historical scratch-path prerequisites; credentials/config are not
included. This addendum leaves the earlier 3e4 evidence and its workaround intact.
