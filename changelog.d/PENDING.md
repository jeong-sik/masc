### Performance

- A TUI workspace read started through `launch_workspace_request` no longer
  sends `/health` before the read once the workspace is confirmed. Its
  requests carry `x-masc-expected-base-path` and `x-masc-expected-masc-root`
  with the paths `/health` last reported, and the server refuses a read meant
  for another workspace before routing. Only a 409
  `workspace_precondition_failed` or a 503 `server_booting` costs one
  `/health` read, which updates the screen as before; the read is withdrawn
  and not sent again. The native task and child content reads drop their two
  checks around each GET the same way (#43356, #PENDING).
