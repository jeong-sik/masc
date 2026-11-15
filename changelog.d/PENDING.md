### Performance

- A TUI workspace read no longer sends `/health` before the read once the
  workspace is confirmed. Every workspace job launcher (workspace requests and
  results, sessions, async reads, workspace jobs, Task dispatch) runs its job
  in a request scope whose requests carry `x-masc-expected-base-path` and
  `x-masc-expected-masc-root` with the paths `/health` last reported, and the
  server refuses one meant for another workspace before routing. Only a 409
  `workspace_precondition_failed` or a 503 `server_booting` costs one
  `/health` read, which updates the screen as before; a refused read is
  withdrawn and not sent again. A job that changes something keeps its
  `/health` admission so its receipt still tells "not sent" from "unknown",
  and its requests carry the precondition as well (#43356, #PENDING).
