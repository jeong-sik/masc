module T = Masc_tui_types
module P = Masc_tui_async_protocol
module System_logs_view = Masc_tui_system_logs

(* One request per refresh returns this many lines. The server caps the
   parameter at 3000; a screenful of scrollback is what the surface can show
   without holding the whole ring in memory. *)
let system_log_page = 300

let refresh_client_system_logs (state : T.state) =
  match System_logs_view.source state.T.system_logs with
  | System_logs_view.Server -> ()
  | System_logs_view.This_tui ->
    let page = T.system_logs_page state in
    let result =
      System_logs_view.client_snapshot ~limit:system_log_page
        ~min_level:page.System_logs_view.lp_min_level
    in
    state.T.system_logs <- System_logs_view.apply System_logs_view.This_tui result state.T.system_logs

(* The server's logs arrive over [GET /api/v1/dashboard/logs/stream] while the
   System logs view shows them (RFC-0480 §3.1): the first frame is the page,
   later ones the entries pushed since. A dropped connection reconnects after
   the newest entry the job has seen, backing off while connections stay
   short. A new floor closes the stream; the next loop iteration opens one with
   it. An ended job stays registered until the view is left, so a bug does not
   turn into a reconnect loop. *)
let system_log_stream_level (state : T.state) =
  Option.map Masc.Tui_decode.system_log_level_query
    (System_logs_view.page System_logs_view.Server state.T.system_logs).System_logs_view.lp_min_level

(* A connection that lasted this long resets the backoff. *)
let system_log_stream_stable_s = 3.0 *. Server_mcp_transport_http_headers.sse_ping_interval_s

let stop_system_log_stream (state : T.state) =
  match state.T.system_log_stream with
  | None -> ()
  | Some (_, stop) ->
    state.T.system_log_stream <- None;
    stop ()

let launch_system_log_stream (state : T.state) ~mailbox ~level ~instance =
  let stream =
    { T.slf_level = level
    ; slf_instance = instance
    ; slf_reading = state.T.workspace_read_authority
    ; slf_owner = ref () } in
  let stopped, stop = Eio.Promise.create () in
  state.T.system_log_stream <- Some (stream, fun () -> ignore (Eio.Promise.try_resolve stop ()));
  let enqueue_async = Masc_tui_transport.Workspace_admission.workspace_enqueue state in
  let deliver event = enqueue_async mailbox (P.System_log_streamed (stream, event)) in
  let host = Masc_tui_transport.Workspace_admission.server_peer_host and port = state.T.port in
  let run clock =
    let since = ref None in
    let rec connect delay =
      let reader = Masc_tui_system_log_stream.create () in
      let opened_at = Eio.Time.now clock in
      let ended =
        Masc_tui_http.observe_system_log_stream ~clock ~host ~port ~instance ?level
          ?since_seq:!since
          ~limit:system_log_page
          ~on_chunk:(fun chunk ->
            List.iter
              (function
                | Ok (frame : Masc_tui_system_log_stream.frame) ->
                  (match frame.Masc_tui_system_log_stream.snapshot.Masc.Tui_decode.sys_latest_seq with
                   | Some _ as newest -> since := newest
                   | None -> ());
                  deliver (T.System_log_frame frame)
                | Error detail -> deliver (T.System_log_frame_unread detail))
              (Masc_tui_system_log_stream.feed reader chunk))
          ()
      in
      deliver (T.System_log_stream_down ended);
      let delay =
        if Eio.Time.now clock -. opened_at >= system_log_stream_stable_s
        then Masc_tui_transport.Event_streams.stream_reconnect_s
        else delay
      in
      Eio.Time.sleep clock delay;
      connect (Float.min Owed_retry.max_reconnect_s (delay *. 2.0))
    in
    connect Masc_tui_transport.Event_streams.stream_reconnect_s
  in
  match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
  | Some sw, Some clock ->
    (match
       Masc_tui_transport.Workspace_admission.fork_job ~observation:true state ~mailbox ~sw (fun () ->
         try Eio.Fiber.first (fun () -> run clock) (fun () -> Eio.Promise.await stopped) with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn -> deliver (T.System_log_stream_down (Printexc.to_string exn)))
     with
     | () -> ()
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn ->
       state.T.system_logs <-
         System_logs_view.apply System_logs_view.Server (Error (Printexc.to_string exn))
           state.T.system_logs)
  | None, _ | _, None ->
    state.T.system_logs <-
      System_logs_view.apply System_logs_view.Server (Error "Eio switch or clock is unavailable")
        state.T.system_logs

(* The server admits a log stream only under the Observer instance the
   request names, and this TUI learns that instance from its own Observer
   stream. Until that stream has been answered there is no instance to name. *)
let system_log_stream_waits_for_observer =
  "the log stream opens once this TUI's Observer stream names the workspace instance"

(* Runs on every loop iteration: one stream while the view shows the server's
   logs and this TUI may read the workspace, none otherwise. The stream names
   the Observer instance this TUI is bound to. A replaced workspace ends the
   Observer stream; the instance its successor is answered with is a new
   binding, and the next iteration opens a stream that names it. *)
let reconcile_system_log_stream (state : T.state) ~mailbox =
  let shown =
    state.T.view = T.System_logs
    && System_logs_view.source state.T.system_logs = System_logs_view.Server
    && T.server_authority_ready state
  in
  match shown, state.T.observer_scope_binding, state.T.system_log_stream with
  | false, _, None -> ()
  | false, _, Some _ -> stop_system_log_stream state
  | true, (T.Observer_scope_unbound | T.Observer_scope_retired), _ ->
    stop_system_log_stream state;
    let waiting = Some system_log_stream_waits_for_observer in
    let page = System_logs_view.page System_logs_view.Server state.T.system_logs in
    if not (Option.equal String.equal page.System_logs_view.lp_error waiting) then
      state.T.system_logs <-
        System_logs_view.apply System_logs_view.Server
          (Error system_log_stream_waits_for_observer) state.T.system_logs
  | true, T.Observer_scope_bound instance, Some (stream, _)
    when Option.equal String.equal stream.T.slf_level (system_log_stream_level state)
         && String.equal stream.T.slf_instance instance
         && stream.T.slf_reading == state.T.workspace_read_authority -> ()
  | true, T.Observer_scope_bound instance, (Some _ | None) ->
    stop_system_log_stream state;
    launch_system_log_stream state ~mailbox ~level:(system_log_stream_level state) ~instance

(* The reads on the wire that the pages tell the reader about: the facts each
   page hands [page_unread_note_while], and the sources the status line names.
   An iteration starts its reads, then handles the key, then draws. The key
   that opens a page is drawn before that page's first read starts, and the
   read starts on the next iteration, which draws nothing until an answer or a
   key arrives. The page kept saying "press r" while its read ran. The loop
   takes this before its launches and again just before it picks the frame,
   and asks for a frame when it moved, wherever in between the read started.

   The facts are named. Twelve positions in two nested tuples left a new fact
   to be added by counting slots, and a reader could not tell which slot was
   which without the render site open beside it. The loop compares whole
   records, so a new field joins the comparison with no edit there. That
   comparison reads every field and no projection does, which the
   unused-field warning cannot see. *)
type reads_in_flight =
  { rif_clients : bool
  ; rif_lane_runs : bool
  ; rif_runtime : int option
  ; rif_harness : bool
  ; rif_verification : bool
  ; rif_memory_health : bool
  ; rif_repositories : bool
  ; rif_changes : bool
  ; rif_system_log : bool
  ; rif_schedules : bool
  ; rif_fusion_runs : bool
  ; rif_memory_facts : bool
  ; rif_status_sources : T.Surface_read_order.source list
  }
[@@warning "-69"]

let reads_in_flight (state : T.state) =
  { rif_clients = state.T.clients_surface_inflight
  ; rif_lane_runs = state.T.lane_runs_loading
  ; rif_runtime = state.T.runtime_surface_inflight
  ; rif_harness = state.T.harness_inflight
  ; rif_verification = state.T.verification_inflight
  ; rif_memory_health = state.T.memory_health_inflight
  ; rif_repositories = state.T.repositories_inflight
  ; rif_changes = state.T.changes_inflight
  ; rif_system_log = Option.is_some state.T.system_log_stream
  ; rif_schedules = T.Snapshot_read.in_flight state.T.schedules_read
  ; rif_fusion_runs = T.view_is_loading (Masc_tui_fusion_model.fusion_runs_view state)
  ; rif_memory_facts = T.view_is_loading (T.memory_facts_view state)
  ; rif_status_sources = T.surface_reads_pending state
  }

(* A frame or an ending of the job that is current lands on the server page; a
   message from a job since replaced is dropped. *)
let take_system_log_stream (state : T.state) (stream : T.system_log_follow) event =
  match state.T.system_log_stream with
  | Some (current, _)
    when current.T.slf_owner == stream.T.slf_owner
         && stream.T.slf_reading == state.T.workspace_read_authority ->
    let result =
      match event with
      | T.System_log_frame frame ->
        Ok (Masc_tui_system_log_stream.apply ~limit:system_log_page frame
              (System_logs_view.page System_logs_view.Server state.T.system_logs).System_logs_view.lp_snapshot)
      | T.System_log_frame_unread detail | T.System_log_stream_down detail -> Error detail
    in
    state.T.system_logs <- System_logs_view.apply System_logs_view.Server result state.T.system_logs
  | Some _ | None -> ()

(* A new floor or source: the server page reopens its stream with it on the
   next loop iteration; the local page reads this process's ring now. *)
let refresh_system_logs_source (state : T.state) =
  match System_logs_view.source state.T.system_logs with
  | System_logs_view.This_tui -> refresh_client_system_logs state
  | System_logs_view.Server -> stop_system_log_stream state
