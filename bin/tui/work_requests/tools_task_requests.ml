module T = Masc_tui_types
module P = Masc_tui_async_protocol
module W = Masc_tui_words
module WA = Masc_tui_transport.Workspace_admission
module RN = Masc_tui_transport.Request_notice

(* An owed read shares a pending reading for the same Keeper. Explicit
   refresh and selection changes supersede it, retaining the generation guard. *)
let close_tools_async_task (state : T.state) =
  Option.iter
    (fun (request : T.tools_async_task_request) ->
      Masc_tui_workspace_job.cancel_observation state ~key:request.T.atr_job)
    state.tools_async_task_body_request;
  Option.iter
    (fun (request : _ T.task_history_request) ->
      Masc_tui_workspace_job.cancel_observation state ~key:request.T.thr_job)
    state.tools_async_task_history_request;
  T.suspend_tools_async_task state;
  state.tools_async_task_source <- None;
  state.tools_async_task_owed <- Masc_tui_owed_read.settled;
  T.tools_task_user_scroll state 0

let reconcile_task_documents ~terminal_size (state : T.state) ~mailbox =
  (match state.task_history_request with
   | None -> ()
   | Some request ->
       let current =
         T.task_history_request_in_scope state request
         && Masc_tui_fetched.is_current ~equal:String.equal state.task_history
              request.T.thr_ticket
       in
       if not current then begin
         Masc_tui_workspace_job.cancel_observation state ~key:request.T.thr_job;
         T.cancel_task_history_for_view_exit state
       end);
  let previous =
    List.filter_map Fun.id
      [ state.task_document_body.T.tds_request
      ; state.task_document_history.T.tds_request
      ]
  in
  let _, terminal_cols = terminal_size () in
  let cols = T.task_document_columns state ~terminal_cols in
  let started = T.sync_task_documents state ~cols in
  let current =
    List.filter_map Fun.id
      [ state.task_document_body.T.tds_request
      ; state.task_document_history.T.tds_request
      ]
  in
  List.iter
    (fun request ->
      if not (List.exists (fun active -> active == request) current) then
        Masc_tui_workspace_job.cancel_observation state ~key:request.T.tdr_job)
    previous;
  List.iter
    (fun (request : T.task_document_request) ->
      let module Observation = Masc_tui_task_document_observation in
      let observe = Observation.observe request.T.tdr_observation in
      let key = Masc_tui_fetched.request_key request.T.tdr_ticket in
      let name =
        match Masc_tui_task_document.part key.T.tdk_input with
        | Masc_tui_task_document.Body -> "task.document.body.prepare_wait"
        | Masc_tui_task_document.History ->
            "task.document.history.prepare_wait"
      in
      WA.launch_result ~key:request.T.tdr_job ~observation:true
        ~observe_job:(function
          | Masc_tui_workspace_job.Cancellation_requested ->
              observe Observation.Cancellation_requested
          | Masc_tui_workspace_job.Registration_released ->
              observe Observation.Registration_released)
        ~on_not_run:(fun () ->
          observe (Observation.Caller_observed Observation.Not_started))
        state ~mailbox ~boundary_error:Fun.id
        ~deliver:(fun result ->
          P.Task_msg (P.Task_document_prepared (request, result)))
        (fun () ->
          Ok
            (Observation.run request.T.tdr_observation ~name (fun () ->
               Masc_tui_task_document.prepare key.T.tdk_input))))
    started;
  started <> [] || List.length previous <> List.length current

let close_tools_async_detail (state : T.state) =
  close_tools_async_task state;
  Option.iter
    (fun (request : T.tools_async_detail_request) ->
      Masc_tui_workspace_job.cancel_observation state ~key:request.T.tad_job)
    state.tools_async_detail_request;
  T.suspend_tools_async_detail state;
  state.tools_async_detail_open <- false;
  (* The next detail opened is another request; it owes nothing yet. *)
  state.tools_async_detail_owed <- Masc_tui_owed_read.settled;
  T.tools_task_user_scroll state 0

let launch_tools_async_detail ?(force = false) (state : T.state) ~mailbox =
  if
    T.server_authority_ready state
    && state.view = T.Tools
    && state.tools_pane = T.Tools_async
    && state.tools_async_detail_open
    && Option.is_none state.tools_async_task_source
  then begin
    let previous = state.tools_async_detail_request in
    match T.begin_tools_async_detail state ~force with
    | None -> ()
    | Some request ->
        state.tools_async_detail_owed <-
          Masc_tui_owed_read.started state.tools_async_detail_owed;
        Option.iter
          (fun (old : T.tools_async_detail_request) ->
            Masc_tui_workspace_job.cancel_observation state ~key:old.T.tad_job)
          previous;
        let host = WA.server_peer_host and port = state.port in
        let target = Masc_tui_fetched.request_key request.T.tad_ticket in
        WA.launch_json_read ~key:request.T.tad_job state ~mailbox
          ~boundary_error:(fun detail -> T.Request_failed detail)
          ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
          ~deliver:(fun result ->
            P.Tools_msg (P.Tools_async_detail_loaded (request, result)))
          (fun () ->
            Masc_tui_http.fetch_async_request_detail ~host ~port ~target
            |> Result.map_error (fun detail -> T.Request_failed detail))
  end

let launch_tools_async_task_history ?(force = false) ?(older = false)
    ~terminal_size (state : T.state) ~mailbox =
  if
    T.server_authority_ready state
    && state.view = T.Tools
    && state.tools_pane = T.Tools_async
    && state.tools_async_detail_open
    && Option.is_some state.tools_async_task_source
  then begin
    let previous = state.tools_async_task_history_request in
    let limit, _ = terminal_size () in
    match T.begin_tools_async_task_history ~older state ~force ~limit with
    | None -> ()
    | Some request ->
        Option.iter
          (fun (old : _ T.task_history_request) ->
            Masc_tui_workspace_job.cancel_observation state ~key:old.T.thr_job)
          previous;
        let host = WA.server_peer_host and port = state.port in
        WA.launch_json_read ~key:request.T.thr_job state ~mailbox
          ~boundary_error:(fun detail -> T.Request_failed detail)
          ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
          ~deliver:(fun result ->
            P.Tools_msg (P.Tools_async_task_history_loaded (request, result)))
          (fun () ->
            Masc_tui_http.fetch_task_history_page ~host ~port
              ~request:request.T.thr_page
            |> Result.map_error (fun detail -> T.Request_failed detail))
  end

let launch_tools_async_task ?(force = false) ~terminal_size (state : T.state)
    ~mailbox =
  if
    T.server_authority_ready state
    && state.view = T.Tools
    && state.tools_pane = T.Tools_async
    && state.tools_async_detail_open
    && Option.is_some state.tools_async_task_source
  then begin
    let host = WA.server_peer_host and port = state.port in
    let previous = state.tools_async_task_body_request in
    (match T.begin_tools_async_task_body state ~force with
     | None -> ()
     | Some request ->
         state.tools_async_task_owed <-
           Masc_tui_owed_read.started state.tools_async_task_owed;
         Option.iter
           (fun (old : T.tools_async_task_request) ->
             Masc_tui_workspace_job.cancel_observation state ~key:old.T.atr_job)
           previous;
         let source = Masc_tui_fetched.request_key request.T.atr_ticket in
         WA.launch_json_read ~key:request.T.atr_job state ~mailbox
           ~boundary_error:(fun detail -> T.Request_failed detail)
           ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
           ~deliver:(fun result ->
             P.Tools_msg (P.Tools_async_task_body_loaded (request, result)))
           (fun () ->
             Masc_tui_http.fetch_original_task_detail ~host ~port
               ~task_id:source.T.ats_task_id ~previous:request.T.atr_previous
             |> Result.map_error (fun detail -> T.Request_failed detail)));
    launch_tools_async_task_history ~force ~terminal_size state ~mailbox
  end

let open_tools_async_source_task ~terminal_size (state : T.state) ~mailbox =
  match state.tools_async_task_source with
  | Some _ -> launch_tools_async_task ~terminal_size state ~mailbox
  | None -> (
      match T.tools_async_source_task state with
      | T.Async_source_task source ->
          Option.iter
            (fun (request : T.tools_async_detail_request) ->
              Masc_tui_workspace_job.cancel_observation state
                ~key:request.T.tad_job)
            state.tools_async_detail_request;
          T.suspend_tools_async_detail state;
          state.tools_async_task_source <- Some source;
          T.tools_task_user_scroll state 0;
          launch_tools_async_task ~force:true ~terminal_size state ~mailbox
      | T.Async_source_has_no_task ->
          Masc_tui_loader.report_action state "system"
            "The original run records no source Task"
      | T.Async_source_not_composition ->
          Masc_tui_loader.report_action state "system"
            "This request is not a Composition source"
      | T.Async_source_unavailable detail ->
          Masc_tui_loader.report_action state "error"
            ("Original Task source unavailable: " ^ detail))

let launch_tools_async_observation_load (state : T.state) ~mailbox =
  if T.server_authority_ready state then
    match T.begin_tools_async_observation_read state with
    | None -> ()
    | Some generation ->
        let host = WA.server_peer_host in
        let port = state.port in
        WA.launch_json_read
          ~on_not_run:(fun () ->
            if generation = state.tools_async_request_generation then
              state.tools_async_observation_inflight <- false)
          state ~mailbox
          ~boundary_error:(fun detail -> T.Request_failed detail)
          ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
          ~deliver:(fun result ->
            P.Tools_msg (P.Tools_async_observation_loaded (generation, result)))
          (fun () ->
            Masc_tui_http.fetch_async_request_observation ~host ~port
            |> Result.map_error (fun detail -> T.Request_failed detail))

(* Starts the named Tools parts, beside the parts already in flight, and marks
   each part's owed read started. The inventory and the activations read for
   the selected Keeper under its generation; parts in flight for another
   Keeper are dropped. The skills catalog and the Usage answers read under
   their own generation. The async broker part has its own read and in-flight
   flag. *)
let launch_tools_parts (state : T.state) ~mailbox parts =
  if T.server_authority_ready state then begin
    let keeper =
      Option.map
        (fun (row : Masc.Tui_decode.keeper) -> row.Masc.Tui_decode.k_name)
        (T.selected_keeper state)
    in
    (* The Activations pane draws no ledger without a selected Keeper. *)
    let parts =
      match keeper with
      | Some _ -> parts
      | None ->
          if List.mem T.Tools_activations_read parts then begin
            state.tools_activations <- Some T.Activations_no_keeper;
            state.tools_activations_error <- None;
            state.tools_activations_owed <- Masc_tui_owed_read.settled
          end;
          List.filter (fun part -> part <> T.Tools_activations_read) parts
    in
    let keeper_parts, skill_parts =
      List.partition
        (function
          | T.Tools_inventory_read | T.Tools_activations_read -> true
          | T.Tools_catalog_read | T.Tools_usage_read _ | T.Tools_async_read ->
              false)
        parts
    in
    (match keeper_parts with
     | [] -> ()
     | _ :: _ ->
         state.tools_read_inflight <-
           Some
             (match state.tools_read_inflight with
              | Some request
                when request.T.tri_generation = state.tools_request_generation
                     && Option.equal String.equal request.T.tri_keeper keeper ->
                  { request with
                    T.tri_pending =
                      request.T.tri_pending
                      @ List.filter
                          (fun part -> not (List.mem part request.T.tri_pending))
                          keeper_parts
                  }
              | Some _ ->
                  (* Read for a Keeper no longer selected: its answers are not
                     this Keeper's. *)
                  state.tools_request_generation <-
                    state.tools_request_generation + 1;
                  { T.tri_generation = state.tools_request_generation
                  ; tri_keeper = keeper
                  ; tri_pending = keeper_parts
                  }
              | None ->
                  { T.tri_generation = state.tools_request_generation
                  ; tri_keeper = keeper
                  ; tri_pending = keeper_parts
                  }));
    let generation = state.tools_request_generation in
    let skill_generation = state.tools_skill_generation in
    state.tools_skill_pending <-
      state.tools_skill_pending
      @ List.filter
          (fun part ->
            (match part with
             | T.Tools_catalog_read | T.Tools_usage_read _ -> true
             | T.Tools_inventory_read | T.Tools_activations_read
             | T.Tools_async_read ->
                 false)
            && not (List.mem part state.tools_skill_pending))
          skill_parts;
    let host = WA.server_peer_host in
    let port = state.port in
    List.iter
      (function
        | T.Tools_inventory_read ->
            (* A reading or a failure held for another Keeper is not this
               Keeper's, so neither is kept on screen while this read runs. *)
            let for_another =
              not (Option.equal String.equal state.tools_inventory_keeper keeper)
            in
            if for_another then begin
              state.tools_inventory <- None;
              state.tools_inventory_keeper <- None;
              state.tools_error <- None
            end;
            state.tools_inventory_owed <-
              T.start_owed_read ~for_another state.tools_inventory_owed;
            WA.launch_json_read state ~mailbox
              ~boundary_error:(fun detail -> T.Request_failed detail)
              ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
              ~deliver:(fun result ->
                P.Tools_msg
                  (P.Tools_read_loaded
                     (P.Tools_inventory_loaded { generation; keeper; result })))
              (fun () ->
                Masc_tui_loader.load_tools ~host ~port ?keeper ()
                |> Result.map_error (fun detail -> T.Request_failed detail))
        | T.Tools_catalog_read ->
            state.tools_catalog_owed <-
              Masc_tui_owed_read.started state.tools_catalog_owed;
            WA.launch_json_read state ~mailbox
              ~boundary_error:(fun detail -> T.Request_failed detail)
              ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
              ~deliver:(fun result ->
                P.Tools_msg
                  (P.Tools_read_loaded
                     (P.Tools_catalog_loaded
                        { generation = skill_generation
                        ; result =
                            Result.map_error
                              (WA.attribute_request_failure
                                 Masc_tui_async_read.Skills_catalog)
                              result
                        })))
              (fun () ->
                Masc_tui_loader.load_skills_catalog ~host ~port
                |> Result.map_error (fun detail -> T.Request_failed detail))
        | T.Tools_activations_read ->
            (* The Activations pane draws the selected Keeper's ledger, which its
               own route answers (RFC-0483). *)
            Option.iter
              (fun keeper ->
                (* A reading or a failure held for no Keeper or for another one
                   is not this Keeper's, so it is not kept on screen while this
                   read runs. *)
                let for_another =
                  T.activations_held_for_another ~selected:(Some keeper)
                    state.tools_activations state.tools_activations_error
                in
                (match state.tools_activations with
                 | Some (T.Activations_read projection)
                   when String.equal
                          (Masc.Tui_decode_tools.skill_activation_keeper
                             projection)
                          keeper ->
                     ()
                 | Some (T.Activations_read _ | T.Activations_no_keeper) ->
                     state.tools_activations <- None
                 | None -> ());
                (match state.tools_activations_error with
                 | Some failure
                   when not (String.equal failure.T.taf_keeper keeper) ->
                     state.tools_activations_error <- None
                 | Some _ | None -> ());
                state.tools_activations_owed <-
                  T.start_owed_read ~for_another state.tools_activations_owed;
                WA.launch_json_read state ~mailbox
                  ~boundary_error:(fun detail -> T.Request_failed detail)
                  ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
                  ~deliver:(fun result ->
                    P.Tools_msg
                      (P.Tools_read_loaded
                         (P.Tools_activations_loaded
                            { generation; keeper; result })))
                  (fun () ->
                    Masc_tui_loader.load_keeper_skill_activations ~host ~port
                      ~keeper
                    |> Result.map_error (fun detail -> T.Request_failed detail)))
              keeper
        | T.Tools_usage_read keeper ->
            (* The Usage pane counts every Keeper's use of the catalog, one
               Keeper's ledger per read (RFC-0483). *)
            T.set_keeper_skill_usage_owed state keeper
              (Masc_tui_owed_read.started (T.keeper_skill_usage_owed state keeper));
            WA.launch_json_read state ~mailbox
              ~boundary_error:(fun detail -> T.Request_failed detail)
              ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
              ~deliver:(fun result ->
                P.Tools_msg
                  (P.Tools_read_loaded
                     (P.Tools_usage_loaded
                        { generation = skill_generation; keeper; result })))
              (fun () ->
                Masc_tui_loader.load_keeper_skill_usage ~host ~port ~keeper
                |> Result.map_error (fun detail -> T.Request_failed detail))
        | T.Tools_async_read -> launch_tools_async_observation_load state ~mailbox)
      parts
  end

(* Reads what depends on the selected Keeper: its tool inventory and
   effective surface, and its activations. A new generation drops the
   answers still in flight. The skills catalog and the Usage answers read on
   their pushes ([launch_owed_tools]). *)
let launch_tools_load (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
    state.tools_request_generation <- state.tools_request_generation + 1;
    state.tools_read_inflight <- None;
    launch_tools_parts state ~mailbox
      [ T.Tools_inventory_read; T.Tools_activations_read ]
  end

let settle_tools_skill_read (state : T.state) ~generation part =
  if generation = state.tools_skill_generation then
    state.tools_skill_pending <-
      List.filter (fun pending -> pending <> part) state.tools_skill_pending

(* [true] when the answer belongs to the request still in flight; an answer
   for a superseded generation settles nothing and reports [false]. *)
let settle_tools_read (state : T.state) ~generation part =
  match state.tools_read_inflight with
  | Some request when request.T.tri_generation = generation ->
      let pending =
        List.filter (fun pending -> pending <> part) request.T.tri_pending
      in
      state.tools_read_inflight <-
        (match pending with
         | [] -> None
         | _ -> Some { request with T.tri_pending = pending });
      true
  | Some _ | None -> false

let normalize_tools_skill_cursor (state : T.state) =
  let count = List.length (T.tools_skill_profiles state) in
  if count = 0 then state.tools_skill_cursor <- 0
  else if state.tools_skill_cursor >= count then
    state.tools_skill_cursor <- count - 1
  else if state.tools_skill_cursor < 0 then state.tools_skill_cursor <- 0

let cycle_tools_keeper (state : T.state) ~mailbox ~delta =
  let count = List.length state.keepers in
  if count > 0 then begin
    let next = (state.keeper_cursor + delta + count) mod count in
    state.keeper_cursor <- next;
    state.tools_inventory <- None;
    state.tools_error <- None;
    state.tools_activations <- None;
    state.tools_activations_error <- None;
    (* The cleared readings no longer say whose failures the owed reads
       carry, so the next Keeper's reads start with none behind them. *)
    state.tools_inventory_owed <-
      Masc_tui_owed_read.changed Masc_tui_owed_read.settled;
    state.tools_activations_owed <-
      Masc_tui_owed_read.changed Masc_tui_owed_read.settled;
    T.tools_task_user_scroll state 0;
    state.tools_skill_cursor <- 0;
    state.tools_skill_focus <- T.Choosing_skill;
    launch_tools_load state ~mailbox
  end

(* The two detail-pane histories, over HTTP. Same discipline as the call
   log: the answer names the row it is for, so a load that returns after the
   operator moved on is discarded, not drawn under another item. *)
let launch_goal_candle_load (state : T.state) ~mailbox goal_id =
  if T.server_authority_ready state then
    match T.begin_goal_candle_read state ~goal_id with
    | None -> ()
    | Some request ->
        let host = WA.server_peer_host and port = state.port in
        let expected_instance =
          Option.bind state.server_identity
            (fun (identity : Masc.Tui_decode.server_identity) ->
              identity.Masc.Tui_decode.sid_runtime_instance_id)
        in
        WA.launch_json_read state ~mailbox
          ~boundary_error:(fun detail -> T.Request_failed detail)
          ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
          ~deliver:(fun result ->
            P.Goal_msg (P.Goal_candle_loaded (request, result)))
          (fun () ->
            let credential = Masc_tui_http.bind_credential () in
            let result =
              match expected_instance with
              | None ->
                  Error
                    (T.Goal_candle_read_failed
                       "Server process identity is unavailable; refresh health")
              | Some expected -> (
                  match
                    Masc_tui_http.fetch_goal_candle ~credential
                      ~expected_instance:expected ~host ~port ~goal_id
                  with
                  | Error _ as error -> error
                  | Ok (instance, _) when not (String.equal instance expected)
                    ->
                      Error (T.Goal_candle_authority_changed None)
                  | Ok (instance, json) ->
                      Candle_goal_observation.of_yojson ~goal_id json
                      |> Result.map (fun observation -> (instance, observation))
                      |> Result.map_error (fun detail ->
                             T.Goal_candle_read_failed detail))
            in
            Ok (credential.Masc_tui_http.bound_owner, result))

let launch_goal_timeline_load (state : T.state) ~mailbox goal_id =
  if T.server_authority_ready state then begin
    launch_goal_candle_load state ~mailbox goal_id;
    match T.begin_goal_timeline_read state ~goal_id with
    | None -> ()
    | Some request ->
        let host = WA.server_peer_host in
        let port = state.port in
        WA.launch_json_read state ~mailbox
          ~boundary_error:(fun detail -> T.Request_failed detail)
          ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
          ~deliver:(fun result ->
            P.Goal_msg (P.Goal_timeline_loaded (request, result)))
          (fun () ->
            Masc_tui_http.fetch_goal_timeline ~host ~port ~goal_id
            |> Result.map_error (fun detail -> T.Request_failed detail))
  end

let launch_task_history_load ?(older = false) ?limit ~terminal_size
    (state : T.state) ~mailbox task_id =
  if T.server_authority_ready state then begin
    let previous = state.task_history_request in
    let limit =
      match limit with Some limit -> limit | None -> fst (terminal_size ())
    in
    match
      T.begin_task_history_read ~older ~progressive:(not older) state ~task_id
        ~limit
    with
    | None -> ()
    | Some request ->
        Option.iter
          (fun (old : _ T.task_history_request) ->
            Masc_tui_workspace_job.cancel_observation state ~key:old.T.thr_job)
          previous;
        let host = WA.server_peer_host and port = state.port in
        WA.launch_json_read ~key:request.T.thr_job state ~mailbox
          ~boundary_error:(fun detail -> T.Request_failed detail)
          ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
          ~deliver:(fun result ->
            P.Task_msg (P.Task_history_loaded (request, result)))
          (fun () ->
            Masc_tui_http.fetch_task_history_page ~host ~port
              ~request:request.T.thr_page
            |> Result.map_error (fun detail -> T.Request_failed detail))
  end

(* Cancel through the authenticated operator route with the captured workspace
   precondition. The server remains the authority for the Task transition;
   transport uncertainty must not be reported as a refusal or a success. *)
let launch_task_cancel (state : T.state) ~mailbox ~authority ~identity ~task_id
    ~reason =
  if
    state.workspace_identity <> T.Workspace_identity_match
    || authority <> state.workspace_authority
  then
    RN.report_kept_back state ~request:W.Kept_request.Task_cancel
      W.workspace_identity_unconfirmed W.Nothing_kept
  else
    match identity with
    | None ->
        RN.report_kept_back state ~request:W.Kept_request.Task_cancel
          W.workspace_identity_unread W.Nothing_kept
    | Some expected_workspace ->
        Approval_gate_requests.supersede_home_decision_receipt state;
        let host = WA.server_peer_host in
        let port = state.port in
        (* Keep the original operation switch and unscoped receipt: workspace
           withdrawal must not cancel an accepted Task cancellation or grant its
           follow-up read authority over the successor workspace. *)
        WA.launch_session state ~mailbox
          ~boundary_error:(fun detail -> P.Task_cancel_unconfirmed detail)
          ~deliver:(fun result ->
            let outcome = match result with Ok outcome | Error outcome -> outcome in
            P.Task_msg (P.Task_cancel_done (task_id, expected_workspace, outcome)))
          (fun () ->
            match WA.admit_request state ~mailbox ~authority ~identity ~host ~port () with
            | Error refusal -> Ok (P.Task_cancel_kept_back refusal)
            | Ok () ->
                Ok
                  (match
                     Masc_tui_http.cancel_task ~host ~port ~task_id ~reason
                       ~expected_workspace
                   with
                   | Masc_tui_http.Post_answered json ->
                       P.Task_cancel_confirmed (Yojson.Safe.to_string json)
                   | Masc_tui_http.Post_refused detail ->
                       P.Task_cancel_refused detail
                   | Masc_tui_http.Post_unanswered detail ->
                       P.Task_cancel_unconfirmed detail))
