let stream_reconnect_s = 2.0

let account_server_answers ~host ~port =
  match
    Masc_tui_loader.server_probe
      (Masc_tui_workspace_read.without_binding (fun () ->
           Masc_tui_loader.load_server_reading ~host ~port))
  with
  | Masc_tui_loader.Probe_account_server _ -> true
  | Masc_tui_loader.Probe_identity (Ok _ | Error _) -> false

let stop_observer_recovery (state : Masc_tui_types.state) =
  match state.observer_recovery_owner with
  | None -> ()
  | Some owner ->
      state.observer_recovery_owner <- None;
      Masc_tui_workspace_job.cancel state ~key:owner

let launch_observer_recovery (state : Masc_tui_types.state) ~origin ~host ~port
    ~mailbox =
  match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
  | Some sw, Some clock ->
      let authority = state.workspace_authority in
      let owner = ref () in
      let session = ref state.mcp_session in
      let refusal_reported = ref false in
      let expected_base_path, expected_masc_root =
        match origin with
        | Masc_tui_async_protocol.Observer_existing_workspace expected ->
            expected.sid_base_path, expected.sid_masc_root
        | Masc_tui_async_protocol.Observer_initial_workspace paths ->
            paths.lw_base_path, paths.lw_masc_root
      in
      let report session_id =
        Workspace_admission.enqueue mailbox
          (Masc_tui_async_protocol.Observer_msg
             (Masc_tui_async_protocol.Observer_recovery_ready
                (authority, owner, session_id)))
      in
      let report_existing session_id =
        match origin with
        | Masc_tui_async_protocol.Observer_existing_workspace _ ->
            report session_id
        | Masc_tui_async_protocol.Observer_initial_workspace _ -> ()
      in
      let open_refused = ref false in
      let failed_attempt = ref false in
      let rec follow () =
        open_refused := false;
        let opened = ref false in
        let note_opened () =
          if not !opened then begin
            opened := true;
            Workspace_admission.enqueue mailbox
              (Masc_tui_async_protocol.Observer_msg
                 (Masc_tui_async_protocol.Observer_recovery_opened
                    ( authority
                    , owner
                    , if !failed_attempt then
                        Masc_tui_refresh_pace.Opened_after_failure
                      else Masc_tui_refresh_pace.Opened_each_time )))
          end
        in
        let outcome =
          try
            match
              match !session with
              | Some session_id -> Ok session_id
              | None ->
                  Masc_tui_http.open_mcp_session ~host ~port
                    ~client_version:Runtime_build_version.current
            with
            | Error detail ->
                open_refused := true;
                Error (Masc_tui_http.Transport_failed detail)
            | Ok session_id ->
                session := Some session_id;
                let live = ref true in
                Fun.protect
                  ~finally:(fun () -> live := false)
                  (fun () ->
                    Masc_tui_http.observe_runtime_events ~clock
                      ~expected_base_path ~expected_masc_root ~host ~port
                      ~session_id ~cursor:None
                      ~on_identity:(fun (handshake, identity) ->
                        note_opened ();
                        Workspace_admission.enqueue mailbox
                          (Masc_tui_async_protocol.Observer_msg
                             (Masc_tui_async_protocol.Observer_recovery_identity
                                ( authority
                                , owner
                                , live
                                , session_id
                                , handshake.Sse_wire.instance_id
                                , origin
                                , identity ))))
                      ~on_open:(fun _ ->
                        note_opened ();
                        refusal_reported := false;
                        report_existing (Some session_id))
                      ~on_chunk:(fun _ -> ()))
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Masc_tui_http.Transport_failed (Printexc.to_string exn))
        in
        if not !opened then failed_attempt := true;
        (match outcome with
         | Error (Masc_tui_http.Http_refused { status; detail })
           when Masc_tui_http.observer_workspace_refused ~status ~detail ->
             if not !refusal_reported then begin
               refusal_reported := true;
               report_existing None
             end
         | Error (Masc_tui_http.Http_refused { status = 404 | 409; _ }) ->
             session := None
         | Ok ()
         | Error
             ( Masc_tui_http.Http_refused _ | Masc_tui_http.Transport_failed _
             | Masc_tui_http.Invalid_handshake _
             | Masc_tui_http.Retry_without_cursor _ ) -> ());
        if !open_refused && account_server_answers ~host ~port then
          Workspace_admission.enqueue mailbox
            (Masc_tui_async_protocol.Observer_msg
               (Masc_tui_async_protocol.Observer_found_account_server
                  (authority, owner)))
        else begin
          Eio.Time.sleep clock stream_reconnect_s;
          follow ()
        end
      in
      state.observer_recovery_owner <- Some owner;
      (try Workspace_admission.fork_job ~key:owner state ~mailbox ~sw follow with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
           state.observer_recovery_owner <- None;
           Log.Transport.warn "tui_observer_recovery_unavailable: %s"
             (Printexc.to_string exn))
  | (None, _ | _, None) -> ()

let reconcile_observer_recovery (state : Masc_tui_types.state) ~refresh_inflight
    ~mailbox =
  match
    ( state.workspace_identity
    , state.server_identity
    , state.observer_recovery_owner )
  with
  | Masc_tui_types.Workspace_identity_match_unconfirmed _, Some expected_workspace, None
    when not refresh_inflight ->
      launch_observer_recovery state
        ~origin:
          (Masc_tui_async_protocol.Observer_existing_workspace
             expected_workspace)
        ~host:Workspace_admission.server_peer_host ~port:state.port ~mailbox
  | Masc_tui_types.Workspace_identity_unread, None, None
    when (not refresh_inflight)
         && (state.connection_status = Masc_tui_types.Disconnected
             || state.connection_status = Masc_tui_types.Degraded) ->
      Option.iter
        (fun paths ->
          launch_observer_recovery state
            ~origin:(Masc_tui_async_protocol.Observer_initial_workspace paths)
            ~host:Workspace_admission.server_peer_host ~port:state.port ~mailbox)
        state.local_workspace_paths
  | Masc_tui_types.Workspace_identity_match_unconfirmed _, Some _, _ -> ()
  | Masc_tui_types.Workspace_identity_unread, None, Some _ -> ()
  | ( Masc_tui_types.(
        ( Workspace_identity_unread | Workspace_identity_match
        | Workspace_identity_mismatch _ ))
    , _
    , _ )
  | Masc_tui_types.Workspace_identity_match_unconfirmed _, None, _ ->
      stop_observer_recovery state

let observer_backlog_limit = 1000
exception Observer_backlog_exceeded

let launch_observer ~browser_scope (state : Masc_tui_types.state)
    ~(expected_workspace : Masc.Tui_decode.server_identity) ~host ~port ~mailbox =
  let enqueue_async = Workspace_admission.workspace_enqueue state in
  let workspace : Masc_tui_types.workspace_input_identity =
    { wi_base_path =
        Masc.Tui_decode.Canonical_path.to_string
          expected_workspace.sid_base_path
    ; wi_masc_root =
        Masc.Tui_decode.Canonical_path.to_string
          expected_workspace.sid_masc_root
    }
  in
  let authority = state.workspace_authority in
  let owner = ref () in
  let machine = Masc_tui_types.observer_machine_of_state state in
  let browser = browser_scope state in
  let play = Masc_tui_types.observer_play_of_state state in
  state.observer_stream_owner <- Some owner;
  state.observer_machine <- machine;
  state.observer_browser <- browser;
  state.observer_play <- play;
  state.observer_retry_owner <- None;
  state.observer <- Masc_tui_types.Observer_opening;
  let session = state.mcp_session in
  let cursor = state.observer_cursor in
  let run () =
    let result =
      try
        match
          match session with
          | Some session_id -> Ok session_id
          | None ->
              Masc_tui_http.open_mcp_session ~host ~port
                ~client_version:Runtime_build_version.current
        with
        | Error detail ->
            if account_server_answers ~host ~port then
              enqueue_async mailbox
                (Masc_tui_async_protocol.Observer_msg
                   (Masc_tui_async_protocol.Observer_found_account_server
                      (authority, owner)));
            Error (Masc_tui_http.Transport_failed detail)
        | Ok session_id -> (
            enqueue_async mailbox
              (Masc_tui_async_protocol.Observer_msg
                 (Masc_tui_async_protocol.Observer_session_ready session_id));
            match Eio_context.get_clock_opt () with
            | None ->
                Error (Masc_tui_http.Transport_failed "Eio clock is unavailable")
            | Some clock ->
                let reader = Masc_tui_observer.create () in
                let instance_id = ref None in
                let on_open (handshake : Sse_wire.observer_handshake option) =
                  instance_id :=
                    Option.map
                      (fun (handshake : Sse_wire.observer_handshake) ->
                        handshake.Sse_wire.instance_id)
                      handshake;
                  enqueue_async mailbox
                    (Masc_tui_async_protocol.Observer_msg
                       (Masc_tui_async_protocol.Observer_opened
                          (owner, session_id, handshake)))
                in
                (* The socket is read without waiting on the UI. Handing each
                   chunk to the mailbox stopped this reader whenever the UI was
                   behind; the server's queue for the session then filled and
                   it closed the stream (four closes in 15 minutes,
                   2026-11-17). Deliveries collect in [received], and the
                   forwarder hands all collected so far to the UI as one
                   batch, which the UI already reads as one. *)
                let received = Eio.Stream.create max_int in
                let backlog = Atomic.make 0 in
                let on_chunk chunk =
                  match Masc_tui_observer.feed reader chunk with
                  | [] -> ()
                  | decoded ->
                      (* Past what the server can replay, holding more gains
                         nothing: the stream is closed, and the reopen
                         resumes from the last applied cursor or revalidates
                         after the gap. *)
                      if
                        Atomic.fetch_and_add backlog (List.length decoded)
                        + List.length decoded
                        > observer_backlog_limit
                      then raise Observer_backlog_exceeded;
                      Eio.Stream.add received (Some (!instance_id, decoded))
                in
                let rec collected acc =
                  match Eio.Stream.take_nonblocking received with
                  | Some (Some batch) -> collected (batch :: acc)
                  | Some None -> List.rev acc, `Ended
                  | None -> List.rev acc, `Open
                in
                let rec forward () =
                  let first = Eio.Stream.take received in
                  let batches, stream =
                    match first with
                    | None -> [], `Ended
                    | Some batch -> collected [ batch ]
                  in
                  ignore
                    (Atomic.fetch_and_add backlog
                       (-List.fold_left
                           (fun n (_, d) -> n + List.length d)
                           0 batches));
                  List.iter
                    (fun batch ->
                      enqueue_async mailbox
                        (Masc_tui_async_protocol.Observer_msg
                           (Masc_tui_async_protocol.Observer_received
                              (owner, batch))))
                    (Masc_tui_observer.merge_batches batches);
                  match stream with `Ended -> () | `Open -> forward ()
                in
                let observed = ref (Ok ()) in
                Eio.Fiber.both
                  (fun () ->
                    observed :=
                      Masc_tui_http.observe_runtime_events_with_scopes ?play
                        ~machine ~browser ~clock
                        ~expected_base_path:expected_workspace.sid_base_path
                        ~expected_masc_root:expected_workspace.sid_masc_root
                        ~host ~port ~session_id ~cursor ~on_identity:(fun _ -> ())
                        ~on_open ~on_chunk ();
                    Eio.Stream.add received None)
                  forward;
                !observed)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | Observer_backlog_exceeded ->
          Error
            (Masc_tui_http.Transport_failed
               (Printf.sprintf
                  "the screen fell %d events behind the observer stream"
                  observer_backlog_limit))
      | exn -> Error (Masc_tui_http.Transport_failed (Printexc.to_string exn))
    in
    enqueue_async mailbox
      (Masc_tui_async_protocol.Observer_msg
         (Masc_tui_async_protocol.Observer_closed (owner, workspace, result)))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Workspace_admission.fork_job ~observation:true ~key:owner state ~mailbox
        ~sw run
  | None ->
      enqueue_async mailbox
        (Masc_tui_async_protocol.Observer_msg
           (Masc_tui_async_protocol.Observer_closed
              ( owner
              , workspace
              , Error
                  (Masc_tui_http.Transport_failed "Eio switch is unavailable")
              )))

let open_observer_if_due ~browser_scope (state : Masc_tui_types.state)
    ~retry_closed ~host ~port ~mailbox =
  match state.workspace_identity, state.server_identity with
  | ( Masc_tui_types.(
        Workspace_identity_match | Workspace_identity_mismatch _)
    , Some expected_workspace )
    when Masc_tui_types.server_authority_ready state -> (
      match state.connection_status, state.observer with
      | Masc_tui_types.(Connected | Degraded), Masc_tui_types.Observer_off ->
          launch_observer ~browser_scope state ~expected_workspace ~host ~port
            ~mailbox
      | ( Masc_tui_types.(Connected | Degraded)
        , Masc_tui_types.(
            Observer_closed_before_answer _ | Observer_closed_after_live _) )
        when retry_closed ->
          launch_observer ~browser_scope state ~expected_workspace ~host ~port
            ~mailbox
      | ( Masc_tui_types.(Connected | Degraded)
        , Masc_tui_types.(
            ( Observer_closed_before_answer _ | Observer_closed_after_live _
            | Observer_opening | Observer_live _ )) )
      | ( Masc_tui_types.(
            Disconnected | Connecting | Booting | Account_server _)
        , _ ) -> ())
  | ( Masc_tui_types.(
        ( Workspace_identity_unread | Workspace_identity_match_unconfirmed _
        | Workspace_identity_match | Workspace_identity_mismatch _ ))
    , _ ) -> ()

let reconcile_observer_machine ~browser_scope (state : Masc_tui_types.state)
    ~host ~port ~mailbox =
  let machine = Masc_tui_types.observer_machine_of_state state in
  let browser = browser_scope state in
  let play = Masc_tui_types.observer_play_of_state state in
  if
    machine <> state.observer_machine
    || browser <> state.observer_browser
    || play <> state.observer_play
  then begin
    Option.iter
      (fun owner -> Masc_tui_workspace_job.cancel_observation state ~key:owner)
      state.observer_stream_owner;
    state.observer_stream_owner <- None;
    state.observer_machine <- None;
    state.observer_browser <- None;
    state.observer_play <- None;
    state.observer_retry_owner <- None;
    state.observer <- Masc_tui_types.Observer_off;
    open_observer_if_due ~browser_scope state ~retry_closed:false ~host ~port
      ~mailbox
  end

let schedule_observer_retry (state : Masc_tui_types.state) ~mailbox owner =
  let unavailable detail =
    (match state.observer_retry_owner with
     | Some current when current == owner -> state.observer_retry_owner <- None
     | Some _ | None -> ());
    Log.Transport.warn "tui_observer_retry_unavailable: %s" detail
  in
  match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
  | Some sw, Some clock -> (
      let authority = state.workspace_authority in
      try
        Workspace_admission.fork_job ~observation:true state ~mailbox ~sw
          (fun () ->
            Eio.Time.sleep clock stream_reconnect_s;
            Workspace_admission.enqueue mailbox
              (Masc_tui_async_protocol.Observer_msg
                 (Masc_tui_async_protocol.Observer_retry_due (authority, owner))))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> unavailable (Printexc.to_string exn))
  | (None, _ | _, None) -> unavailable "Eio switch or clock is unavailable"

let launch_fleet_stream (state : Masc_tui_types.state) ~expected_workspace ~host
    ~port ~mailbox =
  let deliver = Workspace_admission.deliver_fleet state mailbox in
  let exception Close_connection in
  state.fleet_stream_reader <-
    Masc_tui_types.Fleet_stream_following
      Masc_tui_fleet_stream.Awaiting_first_reading;
  let run () =
    match Eio_context.get_clock_opt () with
    | None ->
        deliver
          (Masc_tui_fleet_results.Fleet_stream_reader_ended
             "Eio clock is unavailable")
    | Some clock ->
        let reader = Masc_tui_fleet_stream.create () in
        let posted = ref Masc_tui_fleet_stream.Awaiting_first_reading in
        let post () =
          let view = Masc_tui_fleet_stream.view reader in
          if view <> !posted then begin
            posted := view;
            deliver (Masc_tui_fleet_results.Fleet_stream_view view)
          end
        in
        let read_one_connection () =
          Masc_tui_fleet_stream.started reader;
          (* [Ok ()] covers two different ends: the transport returned without
             an error, or this client chose to stop reading -- a revision gap,
             an update before the snapshot, a rejected frame -- and unwound
             through Close_connection. The metric must not call the second one
             a server close, so the choice is remembered here. *)
          let client_reconnect = ref false in
          let outcome =
            try
              Masc_tui_http.observe_fleet_stream ~clock ~expected_workspace
                ~host ~port ~on_chunk:(fun chunk ->
                  let step = Masc_tui_fleet_stream.feed reader chunk in
                  post ();
                  match step with
                  | Masc_tui_fleet_stream.Keep_reading -> ()
                  | Masc_tui_fleet_stream.Reconnect ->
                      client_reconnect := true;
                      raise Close_connection)
            with Close_connection -> Ok ()
          in
          (* Every end emits exactly one connection_ended line so reconnect
             cadence is countable per outcome; the warn on transport failure
             stays the alarm signal with the detail. This replaces the old
             debug-only tui_fleet_stream_ended, which no reader could see. *)
          (match outcome with
           | Error (Masc_tui_http.Http_refused { status; detail }) ->
               Masc_tui_fleet_stream.refused reader ~status ~detail;
               Log.Transport.info
                 "tui_fleet_stream_connection_ended outcome=refused status=%d detail=%s"
                 status detail
           | Error (Masc_tui_http.Transport_failed detail) ->
               Log.Transport.warn "tui_fleet_stream_lost detail=%s" detail;
               Log.Transport.info
                 "tui_fleet_stream_connection_ended outcome=transport_failed"
           | Error (Masc_tui_http.Invalid_handshake detail) ->
               Masc_tui_fleet_stream.invalid_response reader detail;
               Log.Transport.info
                 "tui_fleet_stream_connection_ended outcome=invalid_handshake detail=%s"
                 detail
           | Error (Masc_tui_http.Retry_without_cursor (_, detail)) ->
               Masc_tui_fleet_stream.invalid_response reader detail;
               Log.Transport.info
                 "tui_fleet_stream_connection_ended outcome=retry_without_cursor detail=%s"
                 detail
           | Ok () ->
               Log.Transport.info
                 "tui_fleet_stream_connection_ended outcome=%s"
                 (if !client_reconnect then "client_reconnect"
                  else "closed_by_server"));
          Masc_tui_fleet_stream.lost reader ~now:(Eio.Time.now clock);
          post ()
        in
        while true do
          read_one_connection ();
          Eio.Time.sleep clock stream_reconnect_s
        done
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Workspace_admission.fork_job ~observation:true state ~mailbox ~sw
        (fun () ->
          try run () with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
              deliver
                (Masc_tui_fleet_results.Fleet_stream_reader_ended
                   (Printexc.to_string exn)))
  | None ->
      deliver
        (Masc_tui_fleet_results.Fleet_stream_reader_ended
           "Eio switch is unavailable")

let open_fleet_stream_if_due (state : Masc_tui_types.state) ~host ~port ~mailbox =
  match state.workspace_identity, state.server_identity with
  | Masc_tui_types.Workspace_identity_match, Some expected_workspace
    when Masc_tui_types.server_authority_ready state -> (
      match state.connection_status, state.fleet_stream_reader with
      | Masc_tui_types.(Connected | Degraded), Masc_tui_types.Fleet_stream_idle ->
          launch_fleet_stream state ~expected_workspace ~host ~port ~mailbox
      | Masc_tui_types.(Connected | Degraded), Masc_tui_types.Fleet_stream_following _
      | ( Masc_tui_types.(
            Disconnected | Connecting | Booting | Account_server _)
        , _ ) -> ())
  | ( Masc_tui_types.(
        ( Workspace_identity_unread | Workspace_identity_match
        | Workspace_identity_match_unconfirmed _
        | Workspace_identity_mismatch _ ))
    , _ ) -> ()
