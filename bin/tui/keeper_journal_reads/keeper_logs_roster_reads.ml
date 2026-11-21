module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Owed_read = Masc_tui_owed_read
module Mono = Masc_tui_wake.Mono
module Fetched = Masc_tui_fetched
module Admission = Masc_tui_transport.Workspace_admission
module Event_streams = Masc_tui_transport.Event_streams
module Owed_read_policy = Masc_tui_owed_surface_reads.Owed_read_policy
module Observer = Masc_tui_observer
module Roster_owed = Masc_tui_roster_owed
module Execute_stream = Masc_tui_execute_stream
module Execute_stream_job = Masc_tui_execute_stream_job
module Keeper_control = Masc_tui_keeper_control
module Metrics_tail = Masc_tui_metrics_tail
module Tui_decode = Masc.Tui_decode

let keeper_log_window = 200

let log_keeper_log_read ~phase (request : T.keeper_log_request) ~outcome =
  let key = Fetched.request_key request.T.klr_request in
  Log.Transport.info "tui_keeper_logs=%s" (Yojson.Safe.to_string (`Assoc [
    "phase", `String phase; "keeper", `String key.T.klk_keeper;
    "base_path", `String key.T.klk_base_path;
    "request", `Intlit (Int64.to_string (Fetched.request_id request.T.klr_request));
    "started_ns", `Intlit (Int64.to_string request.T.klr_started_ns);
    "observed_ns", `Intlit (Int64.to_string (Mtime_clock.elapsed_ns ()));
    "outcome", `String outcome ]))

(* The logs view and the Info tab read the selected Keeper's metrics when they
   open or [r] asks, when [keeper_metrics_appended] names the Keeper, on a
   revalidation, and again after a failed read (RFC-0480 §3.1). *)
let current_logs_owed (state : T.state) ~keeper_name =
  match state.T.keeper_logs_owed with
  | Some owed
    when String.equal owed.T.klgo_keeper keeper_name
         && owed.T.klgo_reading == state.T.workspace_read_authority ->
      Some owed
  | Some _ | None -> None

let update_logs_owed (state : T.state) ~keeper_name transition =
  let owed =
    match current_logs_owed state ~keeper_name with
    | Some owed -> owed
    | None ->
        { T.klgo_keeper = keeper_name
        ; klgo_reading = state.T.workspace_read_authority
        ; klgo_read = Owed_read.settled }
  in
  state.T.keeper_logs_owed <- Some { owed with klgo_read = transition owed.T.klgo_read }

let settle_logs_owed (state : T.state) ~keeper_name transition =
  match current_logs_owed state ~keeper_name with
  | Some owed ->
      state.T.keeper_logs_owed <- Some { owed with klgo_read = transition owed.T.klgo_read }
  | None -> ()

let launch_keeper_log_read (state : T.state) ~mailbox ~intent (keeper : T.keeper) =
  match T.begin_keeper_log_read state ~intent ~limit:keeper_log_window
      ~started_ns:(Mtime_clock.elapsed_ns ()) keeper with
  | None -> false
  | Some request ->
      update_logs_owed state ~keeper_name:keeper.Tui_decode.k_name Owed_read.started;
      let key = Fetched.request_key request.T.klr_request in
      let superseded, supersede = Eio.Promise.create () in
      T.supersede_keeper_log_read state
        (Some (request.T.klr_owner, fun () -> ignore (Eio.Promise.try_resolve supersede ())));
      let enqueue_async = Admission.workspace_enqueue state in
      let deliver result = enqueue_async mailbox (P.Keeper_msg (P.Keeper_logs_loaded (request, result))) in
      log_keeper_log_read ~phase:"started" request ~outcome:"pending";
      let run () = Fun.protect
        ~finally:(fun () -> T.finish_keeper_log_read state request)
        (fun () -> Eio.Fiber.first
          (fun () ->
            let result = try Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                Metrics_tail.load_keeper ~base_path:key.T.klk_base_path
                  ~keeper_name:key.T.klk_keeper ~limit:key.T.klk_limit)
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn -> Error (Printexc.to_string exn) in
            log_keeper_log_read ~phase:"read_completed" request
              ~outcome:(match result with Ok _ -> "received" | Error _ -> "failed");
            T.finish_keeper_log_read state request;
            deliver result)
          (fun () ->
            Eio.Promise.await superseded;
            log_keeper_log_read ~phase:"superseded" request ~outcome:"cancel_requested")) in
      (match Eio_context.get_switch_opt () with
       | None ->
           T.finish_keeper_log_read state request;
           deliver (Error "Eio switch is unavailable for Keeper metrics reading")
       | Some sw ->
           (match Admission.fork_job ~observation:true state ~mailbox ~sw run with
            | () -> ()
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception exn ->
                T.finish_keeper_log_read state request;
                deliver (Error (Printexc.to_string exn))));
      true

(* The logs view and the Terminal tab follow a Keeper's Execute output over its
   stream, so a row reaches the screen when the server logs it. The job owns
   the connection and the reader, and posts the reader's view to the mailbox;
   the render fiber owns all state. Retriable failures back off; a permanent
   refusal stops until the view is reopened. *)

(* The reader is posted at most this often. A command that prints faster draws
   every row all the same; they arrive together. *)
let keeper_execute_stream_post_interval_s = 0.05

(* The job ends when the workspace withdraws it, [stop] is called, a permanent
   refusal occurs, or an exception is reported as the stream going down. An
   ended job stays registered until the view is left, so a bug does not turn
   into a reconnect loop; leaving the view and coming back opens a new one. *)
let launch_keeper_execute_stream (state : T.state) ~mailbox ~expected_workspace ~key =
  let stream =
    { T.kxf_key = key; kxf_reading = state.T.workspace_read_authority; kxf_owner = ref () } in
  let stopped, stop = Eio.Promise.create () in
  state.T.keeper_execute_stream <-
    Some (stream, fun () -> ignore (Eio.Promise.try_resolve stop ()));
  (match Fetched.refresh ~equal:T.keeper_log_equal_key state.T.keeper_execute_output ~key with
   | Fetched.Started (next, _) -> state.T.keeper_execute_output <- next
   | Fetched.Already_loading -> ());
  let enqueue_async = Admission.workspace_enqueue state in
  let deliver event = enqueue_async mailbox (P.Keeper_msg (P.Keeper_execute_streamed (stream, event))) in
  (* The fiber that launches the job is also the only one that drains the
     mailbox, so a job that cannot start is reported to the state directly:
     queueing it could wait on a full mailbox that only this fiber empties. *)
  let report_unstarted detail =
    ignore (T.take_keeper_execute_stream state stream
      (T.Execute_stream_down (T.Execute_stream_stopped { reason = Execute_stream_job.Unexpected_error; detail })) : bool) in
  let host = Admission.server_peer_host and port = state.T.port in
  let run () =
    match Eio_context.get_clock_opt () with
    | None -> deliver (T.Execute_stream_down (T.Execute_stream_stopped
        { reason = Execute_stream_job.Unexpected_error; detail = "Eio clock is unavailable" }))
    | Some clock ->
        Execute_stream_job.run ~clock
          ~reconnect_s:Owed_read_policy.keeper_execute_stream_reconnect_s
          ~max_reconnect_s:Owed_read_policy.keeper_execute_stream_max_reconnect_s
          ~stable_s:Server_routes_http_routes_dashboard.execute_output_heartbeat_s
          ~monotonic_now:(fun () -> Int64.to_float (Mtime_clock.elapsed_ns ()) /. 1e9)
          ~post_interval_s:keeper_execute_stream_post_interval_s
          ~reader:(Execute_stream.create ~keeper:key.T.klk_keeper ~capacity:key.T.klk_limit)
          ~observe:(fun ~on_chunk ->
            match
              Masc_tui_http.observe_execute_output_stream ~clock ~expected_workspace ~host ~port
                ~keeper:key.T.klk_keeper ~on_chunk
            with
            | Ok () -> Ok ()
            | Error (Masc_tui_http.Execute_http_refused { status; detail }) ->
              Error (Execute_stream_job.Http_refusal { status; detail })
            | Error (Masc_tui_http.Execute_unattested { status; detail }) ->
              Error (Execute_stream_job.Unattested { status; detail })
            | Error (Masc_tui_http.Execute_invalid_response { status; detail }) ->
              Error (Execute_stream_job.Invalid_response { status; detail })
            | Error (Masc_tui_http.Execute_transport_failed detail) ->
              Error (Execute_stream_job.Transport_failure detail))
          ~on_view:(fun view ->
            Option.iter
              (fun (reading, observed_at) ->
                 deliver (T.Execute_stream_reading (reading, observed_at)))
              (T.keeper_execute_reading_of_stream ~now:(Eio.Time.now clock) view))
          ~on_ended:(fun ending ->
            let failure = match ending with
              | Execute_stream_job.Retry_after { detail; _ } -> T.Execute_stream_retrying detail
              | Execute_stream_job.Reopen_required { reason; detail } -> T.Execute_stream_stopped { reason; detail } in
            let detail = T.keeper_execute_failure_detail failure in
            Log.Transport.warn "tui_execute_stream_ended keeper=%s detail=%s" key.T.klk_keeper detail;
            deliver (T.Execute_stream_down failure))
  in
  match Eio_context.get_switch_opt () with
  | None -> report_unstarted "Eio switch is unavailable"
  | Some sw ->
      (match
         Admission.fork_job ~observation:true state ~mailbox ~sw (fun () ->
           try Eio.Fiber.first run (fun () -> Eio.Promise.await stopped) with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn -> deliver (T.Execute_stream_down (T.Execute_stream_stopped
               { reason = Execute_stream_job.Unexpected_error; detail = Printexc.to_string exn })))
       with
       | () -> ()
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception exn -> report_unstarted (Printexc.to_string exn))

(* Keep the stream running for what the logs view or the Terminal tab shows:
   one for the Keeper under the cursor while either is on screen, none
   otherwise. True when this changed what is running, so the screen is
   redrawn. *)
let reconcile_keeper_execute_stream (state : T.state) ~mailbox =
  match T.plan_keeper_execute_stream state, state.T.server_identity with
  | T.Stream_stays, _ -> false
  | T.Stream_ends, _ -> T.stop_keeper_execute_stream state
  | T.Stream_follows key, Some expected_workspace ->
      ignore (T.stop_keeper_execute_stream state : bool);
      launch_keeper_execute_stream state ~mailbox ~expected_workspace ~key;
      true
  | T.Stream_follows _, None -> T.stop_keeper_execute_stream state

(* The Keeper's metrics. Its Execute output arrives over the stream that
   [reconcile_keeper_logs] opens. *)
let launch_current_keeper_logs (state : T.state) ~mailbox ~intent =
  match T.keeper_log_target state with
  | Some keeper -> launch_keeper_log_read state ~mailbox ~intent keeper
  | None -> false

(* Runs on every loop iteration; it reads only the Keeper on screen whose
   read is due, once no metrics read is in flight. *)
let launch_owed_keeper_logs (state : T.state) ~mailbox =
  match state.T.keeper_logs_owed with
  | None ->
      (match T.keeper_log_target state, state.T.workspace_identity with
       | Some _, T.Workspace_identity_match ->
           let reading = Fetched.in_flight state.T.keeper_logs in
           let read =
             if reading then state.T.keeper_log_owed
             else Owed_read.abandoned state.T.keeper_log_owed
           in
           state.T.keeper_log_owed <- read;
           if Owed_read.due ~now:(Mono.now ()) read && not reading then begin
             state.T.keeper_log_owed <- Owed_read.started read;
             ignore (launch_current_keeper_logs state ~mailbox ~intent:T.Snapshot_read.Refresh)
           end
       | None, (T.Workspace_identity_match | T.Workspace_identity_unread | T.Workspace_identity_mismatch _
               | T.Workspace_identity_match_unconfirmed _)
       | Some _, (T.Workspace_identity_unread | T.Workspace_identity_mismatch _
                 | T.Workspace_identity_match_unconfirmed _) ->
           state.T.keeper_log_owed <- Owed_read.settled)
  | Some owed ->
      if owed.T.klgo_reading != state.T.workspace_read_authority
      then state.T.keeper_logs_owed <- None
      else if
        Owed_read.due ~now:(Mono.now ()) owed.T.klgo_read
        && Option.is_none state.T.keeper_log_cancel
        && (match state.T.workspace_identity with
            | T.Workspace_identity_match -> true
            | T.Workspace_identity_unread | T.Workspace_identity_mismatch _
            | T.Workspace_identity_match_unconfirmed _ -> false)
      then
        match T.keeper_log_target state with
        | Some keeper when String.equal keeper.Tui_decode.k_name owed.T.klgo_keeper ->
            ignore (launch_keeper_log_read state ~mailbox ~intent:T.Snapshot_read.Join keeper)
        | Some _ | None -> ()

let owe_keeper_logs_read (state : T.state) ~mailbox ~keeper_name =
  update_logs_owed state ~keeper_name Owed_read.changed;
  launch_owed_keeper_logs state ~mailbox

let reconcile_keeper_logs (state : T.state) ~mailbox =
  (* Leaving the Terminal tab, or moving to another Keeper, ends what it held
     still. Coming back opens on the newest output again. *)
  T.reconcile_keeper_terminal state;
  let metrics = match T.keeper_log_target state, state.T.workspace_identity with
  | Some keeper, T.Workspace_identity_match ->
      let key = T.keeper_log_key state ~limit:keeper_log_window keeper in
      (match state.T.keeper_log_read with
       | Some request when request.T.klr_reading == state.T.workspace_read_authority
           && T.keeper_log_equal_key key (Fetched.request_key request.T.klr_request) -> false
       | Some _ | None -> launch_keeper_log_read state ~mailbox ~intent:T.Snapshot_read.Join keeper)
  | (Some _ | None), (T.Workspace_identity_unread | T.Workspace_identity_mismatch _
      | T.Workspace_identity_match_unconfirmed _ | T.Workspace_identity_match) ->
      let held = Option.is_some state.T.keeper_log_read in
      if held then T.suspend_keeper_logs state;
      held in
  let stream = reconcile_keeper_execute_stream state ~mailbox in
  metrics || stream

let owe_whole_keeper_roster_read (state : T.state) =
  state.T.keeper_roster_owed <- Roster_owed.roster_changed state.T.keeper_roster_owed

let owe_keeper_roster_change (state : T.state) = function
  | Observer.Keeper_row_changed { keeper } ->
      state.T.keeper_roster_owed <-
        Roster_owed.row_changed ~keeper_name:keeper state.T.keeper_roster_owed
  | Observer.Every_row_changed -> owe_whole_keeper_roster_read state

let fail_keeper_roster_read (state : T.state) read =
  state.T.keeper_roster_owed <-
    Roster_owed.failed ~retry_s:Event_streams.stream_reconnect_s
      ~max_retry_s:Owed_read_policy.keeper_execute_stream_max_reconnect_s ~now:(Mono.now ())
      read state.T.keeper_roster_owed

let launch_keeper_roster_owed_read (state : T.state) ~mailbox ~expected_workspace read =
  let enqueue_async = Admission.workspace_enqueue state in
  let host = Admission.server_peer_host and port = state.T.port in
  let launch ~deliver load =
    state.T.keeper_roster_owed <- Roster_owed.started read state.T.keeper_roster_owed;
    Admission.launch_async_read_with state ~mailbox
      ~boundary_error:(fun cause -> Keeper_control.Roster_unreachable cause)
      ~deliver load
  in
  match read with
  | Roster_owed.Read_roster ->
      Option.iter (fun roster_request ->
        launch
          ~deliver:(fun roster_result ->
            enqueue_async mailbox (P.Keeper_msg (P.Keeper_roster_reloaded { roster_request; roster_result })))
          (fun () ->
            Masc_tui_loader.load_keeper_roster ~host ~port ~expected_workspace))
        (T.begin_keeper_roster_read ~intent:T.Snapshot_read.Refresh state)
  | Roster_owed.Read_row keeper_name ->
      Option.iter (fun row_request ->
        launch
          ~deliver:(fun row_result ->
            enqueue_async mailbox
              (P.Keeper_msg (P.Keeper_row_reloaded { row_request; row_keeper = keeper_name; row_result })))
          (fun () ->
            Masc_tui_loader.load_keeper_row ~host ~port ~expected_workspace ~keeper_name))
        (T.begin_keeper_row_read state)

(* Runs on every loop iteration. One roster read runs at a time, the
   refresh's whole read included; a read that will not deliver leaves what it
   was reading owed again. Off the surfaces that draw the roster nothing is
   owed: entering one reads the roster whole. *)
let launch_owed_keeper_roster (state : T.state) ~mailbox ~needs_keeper_roster =
  if not needs_keeper_roster then
    state.T.keeper_roster_owed <- Roster_owed.settled
  else begin
    let reading =
      T.Snapshot_read.in_flight state.T.keeper_roster_read
      || T.Snapshot_read.in_flight state.T.keeper_row_read
    in
    if not reading then
      state.T.keeper_roster_owed <- Roster_owed.abandoned state.T.keeper_roster_owed;
    let now = Mono.now () in
    state.T.keeper_roster_owed <- Roster_owed.release_scheduled ~now state.T.keeper_roster_owed;
    match
      reading,
      state.T.server_identity,
      Roster_owed.next_read ~now state.T.keeper_roster_owed
    with
    | false, Some expected_workspace, Some read when T.server_authority_ready state ->
        launch_keeper_roster_owed_read state ~mailbox ~expected_workspace read
    | false, Some _, Some _ | true, _, _ | false, None, _ | false, Some _, None -> ()
  end
