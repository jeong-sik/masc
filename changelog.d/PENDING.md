### Internal

- The Keeper chat control-status and interleave fixture pages answer the
  exact per-execution tool-call lookup that their tool rows send. The lookup
  used to go to the dashboard proxy target, by default the local server on
  port 8935, so their Chromium checks depended on that server's answer. The
  control-status check presses the approval card's current button and waits
  for the approvals address the router gives; the interleave check expects
  the trace-only row to read `unavailable`, as its component test has since
  #43920 (#PENDING).
