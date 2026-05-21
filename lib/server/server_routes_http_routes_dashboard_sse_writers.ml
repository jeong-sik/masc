(** Worktree-status SSE writer helpers, extracted from
    [server_routes_http_routes_dashboard.ml] (godfile decomp).

    Three telemetry-instrumented wrappers around [Httpun.Body.Writer]
    for the worktree-status SSE stream:

    - [observe_worktree_status_sse_write writer event] — single-event
      write. Returns `Result.t`; `observe_or_fail` surfaces I/O errors
      to the caller so the stream can abort cleanly.

    - [observe_worktree_status_sse_write_all writer events] — recursive
      sequence write. Short-circuits on first `Error`. Returns
      `Ok ()` on full success.

    - [observe_worktree_status_sse_close writer] — closes the body
      writer via `Telemetry_observe.observe_or_default ~default:()`
      so close-time I/O errors degrade silently (the connection is
      already terminating).

    All three thread `Telemetry_observe.*` kind labels
    `dashboard_worktree_status_sse_write` and
    `dashboard_worktree_status_sse_close` so the SSE stream's
    error/latency profile is observable in the operator dashboard's
    telemetry view. *)

let observe_worktree_status_sse_write writer event =
  Telemetry_observe.observe_or_fail
    ~kind:"dashboard_worktree_status_sse_write" (fun () ->
      Httpun.Body.Writer.write_string writer event)

let rec observe_worktree_status_sse_write_all writer = function
  | [] -> Ok ()
  | event :: rest ->
      (match observe_worktree_status_sse_write writer event with
       | Ok () -> observe_worktree_status_sse_write_all writer rest
       | Error _ as err -> err)

let observe_worktree_status_sse_close writer =
  Telemetry_observe.observe_or_default
    ~kind:"dashboard_worktree_status_sse_close"
    ~default:() (fun () ->
      Httpun.Body.Writer.close writer)
