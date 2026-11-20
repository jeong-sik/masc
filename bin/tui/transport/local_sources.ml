let catch_non_cancel f =
  try Ok (f ()) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)

let intent_name = function
  | Masc_tui_types.Snapshot_read.Join -> "join"
  | Masc_tui_types.Snapshot_read.Refresh -> "refresh"

let launch_source (state : Masc_tui_types.state) ~mailbox ~intent ~source ~read
    ~prepare ~message base_path =
  match
    Masc_tui_types.begin_local_workspace_read state ~intent ~source ~base_path
      ~started_ns:(Mtime_clock.elapsed_ns ())
  with
  | None ->
      if
        intent = Masc_tui_types.Snapshot_read.Refresh
        && state.workspace_identity = Masc_tui_types.Workspace_identity_match
        && String.equal base_path state.local_base_path
        && Masc_tui_types.Local_read_order.has_followup
             (Masc_tui_types.local_source_order state source)
      then
        Log.Transport.info
          "tui_local_workspace_coalesced source=%s demand_revision=%s"
          (Masc_tui_types.local_read_source_name source)
          (Masc_tui_types.Local_read_order.revision_to_string
             (Masc_tui_types.Local_read_order.demanded_revision
                (Masc_tui_types.local_source_order state source)))
  | Some request -> (
      let token = ref () in
      let superseded, supersede = Eio.Promise.create () in
      Masc_tui_types.supersede_local_source_read state source
        (Some
           ( token
           , fun () ->
               Fun.protect
                 ~finally:(fun () ->
                   ignore (Eio.Promise.try_resolve supersede ()))
                 (fun () ->
                   Masc_tui_local_read_observation.observe request.lwr_observation
                     Masc_tui_local_read_observation.Cancellation_requested) ));
      Log.Transport.info
        "tui_local_workspace_started source=%s intent=%s request=%d demand_revision=%s started_ns=%Ld"
        (Masc_tui_types.local_read_source_name source)
        (intent_name request.lwr_intent)
        (Masc_tui_types.Local_read_order.request_id request.lwr_request)
        (Masc_tui_types.Local_read_order.revision_to_string
           (Masc_tui_types.Local_read_order.request_revision request.lwr_request))
        request.lwr_started_ns;
      let enqueue_async = Workspace_admission.workspace_enqueue state in
      (* The reading slot counts this read from its launch to its end (RFC
         tui-one-screen-grammar section 8). [track_reading] ends it at the
         first of the result, the withdrawal and the job's release. *)
      let on_not_run, deliver, released =
        Workspace_admission.track_reading state
          ~on_not_run:(fun () ->
            Masc_tui_local_read_observation.observe request.lwr_observation
              (Masc_tui_local_read_observation.Caller_observed
                 Masc_tui_local_read_observation.Not_started);
            Masc_tui_types.finish_local_source_read state source token)
          ~deliver:(fun result -> enqueue_async mailbox (message request result))
      in
      let run () =
        Fun.protect
          ~finally:(fun () ->
            Masc_tui_types.finish_local_source_read state source token)
          (fun () ->
            Eio.Fiber.first
              (fun () ->
                let result =
                  catch_non_cancel (fun () ->
                      Masc_tui_local_read_observation.run request.lwr_observation
                        ~read:(fun () -> read request)
                        ~prepare:(prepare request))
                in
                Masc_tui_types.finish_local_source_read state source token;
                deliver result)
              (fun () ->
                Eio.Promise.await superseded;
                Log.Transport.info
                  "tui_local_workspace_superseded source=%s intent=%s request=%d started_ns=%Ld observed_ns=%Ld outcome=cancel_requested"
                  (Masc_tui_types.local_read_source_name source)
                  (intent_name request.lwr_intent)
                  (Masc_tui_types.Local_read_order.request_id request.lwr_request)
                  request.lwr_started_ns (Mtime_clock.elapsed_ns ())))
      in
      match Eio_context.get_switch_opt () with
      | None ->
          Masc_tui_local_read_observation.observe request.lwr_observation
            (Masc_tui_local_read_observation.Caller_observed
               Masc_tui_local_read_observation.Not_started);
          Masc_tui_types.finish_local_source_read state source token;
          deliver (Error "Eio switch is unavailable for local workspace reading")
      | Some sw -> (
          match
            Workspace_admission.fork_job ~observation:true
              ~observe:(fun event ->
                released event;
                match event with
                | Masc_tui_workspace_job.Cancellation_requested ->
                    Masc_tui_local_read_observation.observe request.lwr_observation
                      Masc_tui_local_read_observation.Cancellation_requested
                | Masc_tui_workspace_job.Registration_released ->
                    Masc_tui_local_read_observation.observe request.lwr_observation
                      Masc_tui_local_read_observation.Registration_released)
              ~on_withdrawn:on_not_run
              state ~mailbox ~sw run
          with
          | () -> ()
          | exception (Eio.Cancel.Cancelled _ as exn) ->
              let bt = Printexc.get_raw_backtrace () in
              Masc_tui_local_read_observation.observe request.lwr_observation
                (Masc_tui_local_read_observation.Caller_observed
                   (Masc_tui_local_read_observation.Caller_failed
                      Masc_tui_local_read_observation.Interrupted));
              Printexc.raise_with_backtrace exn bt
          | exception exn ->
              Masc_tui_local_read_observation.observe request.lwr_observation
                (Masc_tui_local_read_observation.Caller_observed
                   (Masc_tui_local_read_observation.Caller_failed
                      Masc_tui_local_read_observation.Raised));
              Masc_tui_types.finish_local_source_read state source token;
              deliver (Error (Printexc.to_string exn))))

let launch_keeper_read state ~mailbox ~intent base_path =
  launch_source state ~mailbox ~intent
    ~source:Masc_tui_types.Local_keepers
    ~read:(fun (request : Masc_tui_types.local_workspace_request) ->
      Masc_tui_loader.read_local_keepers request.lwr_base_path)
    ~prepare:(fun _ reading -> reading)
    ~message:(fun request result ->
      Masc_tui_async_protocol.Local_msg
        (Masc_tui_async_protocol.Local_keepers_read (request, result)))
    base_path

let launch_work_read state ~mailbox ~intent base_path =
  launch_source state ~mailbox ~intent
    ~source:Masc_tui_types.Local_work
    ~read:(fun (request : Masc_tui_types.local_workspace_request) ->
      Masc_tui_loader.read_local_workspace request.lwr_base_path)
    ~prepare:Masc_tui_loader.prepare_local_workspace
    ~message:(fun request result ->
      Masc_tui_async_protocol.Local_msg
        (Masc_tui_async_protocol.Local_workspace_read (request, result)))
    base_path

let launch_workspace_read state ~mailbox ~intent base_path =
  launch_keeper_read state ~mailbox ~intent base_path;
  launch_work_read state ~mailbox ~intent base_path

let launch_followup (state : Masc_tui_types.state) ~mailbox source =
  if
    Masc_tui_types.Local_read_order.has_followup
      (Masc_tui_types.local_source_order state source)
  then
    match source with
    | Masc_tui_types.Local_keepers ->
        launch_keeper_read state ~mailbox
          ~intent:Masc_tui_types.Snapshot_read.Join state.local_base_path
    | Masc_tui_types.Local_work ->
        launch_work_read state ~mailbox
          ~intent:Masc_tui_types.Snapshot_read.Refresh state.local_base_path

let observe_source (state : Masc_tui_types.state) ~source ~is_observed
    (request : Masc_tui_types.local_workspace_request) result =
  let observation =
    Masc_tui_types.take_local_workspace_read state ~source ~is_observed request
      result
  in
  Log.Transport.info
    "tui_local_workspace_settled source=%s intent=%s request=%d demand_revision=%s started_ns=%Ld observed_ns=%Ld outcome=%s followup_pending=%b full_refresh_running=%b"
    (Masc_tui_types.local_read_source_name source)
    (intent_name request.lwr_intent)
    (Masc_tui_types.Local_read_order.request_id request.lwr_request)
    (Masc_tui_types.Local_read_order.revision_to_string
       (Masc_tui_types.Local_read_order.request_revision request.lwr_request))
    request.lwr_started_ns (Mtime_clock.elapsed_ns ())
    (match observation with
     | None -> "discarded"
     | Some (Ok reading) ->
         if is_observed reading then "received" else "source_failed"
     | Some (Error _) -> "failed")
    (Masc_tui_types.Local_read_order.has_followup
       (Masc_tui_types.local_source_order state source))
    (Option.is_some state.http_refresh_started_ns);
  observation

let log_live_context_read ~phase request ~started_ns ~outcome =
  let base_path, keeper_name, trace_id =
    Masc_tui_context_state.describe_key (Masc_tui_context_state.request_key request)
  in
  Log.Transport.info "tui_live_context=%s"
    (Yojson.Safe.to_string
       (`Assoc
          [ "phase", `String phase
          ; ( "request"
            , `Intlit (Int64.to_string (Masc_tui_context_state.request_id request))
            )
          ; "base_path", `String base_path
          ; "keeper", `String keeper_name
          ; ("trace", match trace_id with None -> `Null | Some trace -> `String trace)
          ; "started_ns", `Intlit (Int64.to_string started_ns)
          ; "observed_ns", `Intlit (Int64.to_string (Mtime_clock.elapsed_ns ()))
          ; "outcome", `String outcome
          ]))

let launch_live_context_load (state : Masc_tui_types.state) ~mailbox keeper =
  let module Context = Masc_tui_context_state in
  let key = Masc_tui_types.live_context_key state keeper in
  match Context.start state.live_context ~key with
  | Context.Already_loading -> false
  | Context.Started (next, request) ->
      state.live_context <- next;
      let superseded, supersede = Eio.Promise.create () in
      Masc_tui_types.supersede_live_context_read state
        (Some (fun () -> ignore (Eio.Promise.try_resolve supersede ())));
      let base_path = state.local_base_path in
      let enqueue_async = Workspace_admission.workspace_enqueue state in
      let started_ns = Mtime_clock.elapsed_ns () in
      log_live_context_read ~phase:"started" request ~started_ns ~outcome:"pending";
      (* The reading slot counts this read from its launch to its end (RFC
         tui-one-screen-grammar section 8); see [launch_source]. *)
      let on_not_run, deliver, released =
        Workspace_admission.track_reading state
          ~on_not_run:(fun () -> ())
          ~deliver:(fun result ->
            enqueue_async mailbox
              (Masc_tui_async_protocol.Live_context_loaded (request, started_ns, result)))
      in
      let run () =
        Fun.protect
          ~finally:(fun () ->
            if Context.is_current state.live_context request then
              state.live_context_cancel <- None)
          (fun () ->
            Eio.Fiber.first
              (fun () ->
                let result =
                  Result.join
                    (catch_non_cancel (fun () ->
                         Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__
                           (fun () ->
                             let config = Workspace_core.default_config base_path in
                             Context.load ~config keeper)))
                in
                log_live_context_read ~phase:"read_completed" request ~started_ns
                  ~outcome:(match result with Ok _ -> "received" | Error _ -> "failed");
                deliver result)
              (fun () ->
                Eio.Promise.await superseded;
                log_live_context_read ~phase:"superseded" request ~started_ns
                  ~outcome:"cancel_requested"))
      in
      (match Eio_context.get_switch_opt () with
       | None ->
           state.live_context_cancel <- None;
           deliver (Error "Eio switch is unavailable for live context reading")
       | Some sw -> (
           try
             Workspace_admission.fork_job ~observation:true ~observe:released
               ~on_withdrawn:on_not_run state ~mailbox ~sw run
           with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn -> deliver (Error (Printexc.to_string exn))));
      true

let clear_live_context (state : Masc_tui_types.state) =
  let held = Option.is_some (Masc_tui_context_state.current_key state.live_context) in
  state.live_context <- Masc_tui_context_state.clear state.live_context;
  Masc_tui_types.supersede_live_context_read state None;
  held

let launch_current_live_context state ~mailbox =
  match Masc_tui_types.live_context_keeper state with
  | None -> clear_live_context state
  | Some keeper -> launch_live_context_load state ~mailbox keeper

let reconcile_live_context (state : Masc_tui_types.state) ~mailbox =
  match Masc_tui_types.live_context_keeper state with
  | None -> clear_live_context state
  | Some keeper -> (
      let key = Masc_tui_types.live_context_key state keeper in
      match Masc_tui_context_state.current_key state.live_context with
      | Some current when Masc_tui_context_state.same_key key current -> false
      | Some _ | None -> launch_live_context_load state ~mailbox keeper)
