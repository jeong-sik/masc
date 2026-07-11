(** Keeper_turn_lifecycle -- typed, lane-local Keeper shutdown transaction. *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Result.Syntax

type tool_result = Keeper_types_profile.tool_result

type shutdown_request =
  { remove_meta : bool
  ; remove_session : bool
  }

type shutdown_failure_stage =
  | Self_shutdown
  | Paused_intent_persist
  | Stop_transition
  | Lane_join
  | Turn_settlement
  | Task_ownership_settlement
  | Pending_confirm_cleanup
  | Session_removal
  | Drain_complete
  | Meta_removal
  | Terminal_commit

let shutdown_failure_stage_label = function
  | Self_shutdown -> "self_shutdown"
  | Paused_intent_persist -> "paused_intent_persist"
  | Stop_transition -> "stop_transition"
  | Lane_join -> "lane_join"
  | Turn_settlement -> "turn_settlement"
  | Task_ownership_settlement -> "task_ownership_settlement"
  | Pending_confirm_cleanup -> "pending_confirm_cleanup"
  | Session_removal -> "session_removal"
  | Drain_complete -> "drain_complete"
  | Meta_removal -> "meta_removal"
  | Terminal_commit -> "terminal_commit"
;;

type remove_pending_confirms_by_target =
  Workspace.config ->
  target_type:string ->
  target_id:string option ->
  (int, string) result

let remove_pending_confirms_by_target_callback
    : remove_pending_confirms_by_target option Atomic.t
  =
  Atomic.make None
;;

let register_remove_pending_confirms_by_target fn =
  Atomic.set remove_pending_confirms_by_target_callback (Some fn)
;;

let remove_pending_confirms_by_target config ~target_type ~target_id =
  match Atomic.get remove_pending_confirms_by_target_callback with
  | Some remove -> remove config ~target_type ~target_id
  | None -> Error "operator pending-confirm cleanup is not registered"
;;

let task_ids_json task_ids =
  `List
    (List.map
       (fun task_id -> `String (Keeper_id.Task_id.to_string task_id))
       task_ids)
;;

let shutdown_failure
      ~stage
      ~name
      ~request
      ~lane_joined
      ~continuation_path
      ~released_task_ids
      ~pending_confirms_removed
      detail
  =
  let stage_label = shutdown_failure_stage_label stage in
  Log.Keeper.error
    "keeper_down partial failure keeper=%s stage=%s lane_joined=%b: %s"
    name
    stage_label
    lane_joined
    detail;
  tool_result_error
    (Yojson.Safe.to_string
       (`Assoc
         [ "error", `String "keeper_shutdown_partial_failure"
         ; "failure_stage", `String stage_label
         ; "detail", `String detail
         ; "name", `String name
         ; "lane_joined", `Bool lane_joined
         ; "remove_meta", `Bool request.remove_meta
         ; "remove_session", `Bool request.remove_session
         ; ( "continuation_record"
           , match continuation_path with
             | Some path -> `String path
             | None -> `Null )
         ; "released_task_ids", task_ids_json released_task_ids
         ; "pending_confirms_removed", `Int pending_confirms_removed
         ; "retryable", `Bool true
         ]))
;;

let keeper_down_success
      ~name
      ~request
      ~lane_joined
      ~continuation_path
      ~released_task_ids
      ~pending_confirms_removed
  =
  tool_result_ok
    (Yojson.Safe.to_string
       (`Assoc
         [ "name", `String name
         ; "stopped", `Bool true
         ; "lane_joined", `Bool lane_joined
         ; "remove_meta", `Bool request.remove_meta
         ; "remove_session", `Bool request.remove_session
         ; ( "continuation_record"
           , match continuation_path with
             | Some path -> `String path
             | None -> `Null )
         ; "released_task_ids", task_ids_json released_task_ids
         ; "pending_confirms_removed", `Int pending_confirms_removed
         ]))
;;

let persist_paused_shutdown_intent config name (meta : keeper_meta) =
  let paused =
    { meta with
      updated_at = now_iso ()
    ; paused = true
    ; latched_reason =
        Some
          (Keeper_latched_reason.Operator_paused
             { operator_actor = Keeper_latched_reason.operator_actor_keeper_down })
    ; auto_resume_after_sec = None
    ; runtime = { meta.runtime with last_blocker = None }
    }
  in
  match
    write_meta_with_merge
      ~merge:Keeper_meta_merge.operator_pause_from_caller
      config
      paused
  with
  | Ok () ->
    (match read_meta config name with
     | Error error ->
       Error
         (Printf.sprintf
            "shutdown pause was persisted but canonical meta reload failed: %s"
            error)
     | Ok None ->
       Error "shutdown pause was persisted but canonical keeper meta disappeared"
     | Ok (Some persisted) ->
       Keeper_registry.update_meta
         ~base_path:config.base_path
         name
         persisted;
       Ok persisted)
  | Error error ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WriteMetaFailures)
      ~labels:
        [ "keeper", name
        ; ( "phase"
          , if Keeper_meta_store.is_version_conflict_error error
            then "keeper_down_cas_race"
            else "keeper_down" )
        ]
      ();
    Error error
;;

let settle_interrupted_turn config (entry : Keeper_registry.registry_entry) =
  let persist_failed record prior_error =
    match Keeper_shutdown_record.persist ~config record with
    | Error retry_error ->
      Error
        (Printf.sprintf
           "shutdown continuation persist failed: prior=%s retry=%s"
           prior_error
           retry_error)
    | Ok persisted ->
      (match Keeper_registry.record_shutdown_turn_persisted entry persisted with
       | Ok () -> Ok (Some persisted.path)
       | Error state_error ->
         Error
           (Keeper_registry.shutdown_state_error_to_string state_error))
  in
  match Keeper_registry.shutdown_turn_settlement entry with
  | None -> Error "shutdown state disappeared before turn settlement"
  | Some Keeper_shutdown_types.No_interrupted_turn -> Ok None
  | Some (Keeper_shutdown_types.Awaiting_interrupted_turn { turn_id }) ->
    Error
      (Printf.sprintf
         "lane exited before interrupted turn %d committed a continuation record"
         turn_id)
  | Some
      (Keeper_shutdown_types.Interrupted_turn_persisted { path; _ }) ->
    Ok (Some path)
  | Some
      (Keeper_shutdown_types.Interrupted_turn_persist_failed { record; error }) ->
    persist_failed record error
;;

let shutdown_handoff_context (meta : keeper_meta) =
  { Masc_domain.summary =
      Printf.sprintf "Released by the Keeper shutdown transaction for %s" meta.name
  ; reason = Some "keeper_shutdown"
  ; next_step = Some "Reclaim after confirming the replacement Keeper lane is executable."
  ; failure_mode = None
  ; reclaim_policy = Some Masc_domain.Allow_reclaim
  ; evidence_refs = []
  ; updated_at = Some (now_iso ())
  ; updated_by = Some Keeper_supervisor_types.supervisor_agent_name
  }
;;

let clear_current_task_id config (meta : keeper_meta) =
  match meta.current_task_id with
  | None -> Ok meta
  | Some _ ->
    let cleared = { meta with current_task_id = None; updated_at = now_iso () } in
    (match
       write_meta_with_merge
         ~merge:Keeper_current_task_reconcile.merge_current_task_id
         config
         cleared
     with
     | Error error -> Error error
     | Ok () ->
       (match read_meta config meta.name with
        | Error error ->
          Error
            (Printf.sprintf
               "current_task_id was persisted but canonical meta reload failed: %s"
               error)
        | Ok None ->
          Error
            "current_task_id was persisted but the canonical keeper meta disappeared"
        | Ok (Some persisted) ->
          Keeper_registry.update_meta
            ~base_path:config.base_path
            meta.name
            persisted;
          Ok persisted))
;;

let settle_task_ownership config (meta : keeper_meta) =
  let handoff_context = shutdown_handoff_context meta in
  match
    Keeper_task_ownership_settlement.release_owned_active_tasks
      ~config
      ~meta
      ~actor:Keeper_supervisor_types.supervisor_agent_name
      ~reason_tag:"keeper_shutdown_task_release"
      ~handoff_context
  with
  | Error
      (Keeper_task_ownership_settlement.Release_failed
         { released; failures = _ } as error) ->
    Error
      ( released
      , Keeper_task_ownership_settlement.error_to_string error )
  | Error (Keeper_task_ownership_settlement.Discovery_failed _ as error) ->
    Error ([], Keeper_task_ownership_settlement.error_to_string error)
  | Ok released ->
    (match clear_current_task_id config meta with
     | Ok settled_meta -> Ok (settled_meta, released)
     | Error error ->
       Error
         ( released
         , Printf.sprintf "failed to clear current_task_id after release: %s" error ))
;;

let remove_file_result path =
  try
    if Fs_compat.file_exists path then Sys.remove path;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | error ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SessionCleanupFailures)
      ~labels:[ "keeper", meta.name ]
      ();
    Error (Printexc.to_string error)
;;

let remove_keeper_session config (meta : keeper_meta) =
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let session_dir = Filename.concat (session_base_dir config) trace_id in
  try
    if Fs_compat.file_exists session_dir then Fs_compat.remove_tree session_dir;
    Keeper_fs.invalidate_dir session_dir;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | error -> Error (Printexc.to_string error)
;;

let dispatch_stop_requested config name =
  match Keeper_registry.get_phase ~base_path:config.Workspace.base_path name with
  | Some (Keeper_state_machine.Draining | Keeper_state_machine.Stopped) -> Ok ()
  | Some _ ->
    Keeper_registry.dispatch_event
      ~base_path:config.Workspace.base_path
      name
      Keeper_state_machine.Stop_requested
    |> Result.map (fun _ -> ())
    |> Result.map_error Keeper_state_machine.transition_error_to_string
  | None -> Error "registered lane disappeared before Stop_requested"
;;

let dispatch_drain_complete config name =
  match Keeper_registry.get_phase ~base_path:config.Workspace.base_path name with
  | Some Keeper_state_machine.Stopped -> Ok ()
  | Some _ ->
    Keeper_registry.dispatch_event
      ~base_path:config.Workspace.base_path
      name
      Keeper_state_machine.Drain_complete
    |> Result.map (fun _ -> ())
    |> Result.map_error Keeper_state_machine.transition_error_to_string
  | None -> Error "registered lane disappeared before Drain_complete"
;;

let complete_registry_shutdown config (entry : Keeper_registry.registry_entry) =
  match
    Keeper_registry.resolve_done
      entry
      ~source:"keeper_shutdown_transaction"
      `Stopped
  with
  | Keeper_registry.Done_resolved _ ->
    Keeper_supervisor_publish_lifecycle.publish_phase_lifecycle
      ~phase:Keeper_state_machine.Stopped
      entry.name
      "shutdown transaction committed"
      ();
    Keeper_registry.unregister ~base_path:config.Workspace.base_path entry.name;
    Ok ()
  | Keeper_registry.Done_already_resolved { previous = `Stopped; _ } ->
    Keeper_registry.unregister ~base_path:config.Workspace.base_path entry.name;
    Ok ()
  | Keeper_registry.Done_already_resolved { previous = `Crashed reason; _ } ->
    Error (Printf.sprintf "lane already resolved as crashed: %s" reason)
;;

type shutdown_progress =
  { lane_joined : bool
  ; continuation_path : string option
  ; released_task_ids : Keeper_id.Task_id.t list
  ; pending_confirms_removed : int
  }

type shutdown_transaction_error =
  { stage : shutdown_failure_stage
  ; progress : shutdown_progress
  ; detail : string
  }

let initial_progress =
  { lane_joined = false
  ; continuation_path = None
  ; released_task_ids = []
  ; pending_confirms_removed = 0
  }
;;

let transaction_error stage progress detail = Error { stage; progress; detail }

let render_shutdown_transaction ~name ~request = function
  | Error { stage; progress; detail } ->
    shutdown_failure
      ~stage
      ~name
      ~request
      ~lane_joined:progress.lane_joined
      ~continuation_path:progress.continuation_path
      ~released_task_ids:progress.released_task_ids
      ~pending_confirms_removed:progress.pending_confirms_removed
      detail
  | Ok progress ->
    keeper_down_success
      ~name
      ~request
      ~lane_joined:progress.lane_joined
      ~continuation_path:progress.continuation_path
      ~released_task_ids:progress.released_task_ids
      ~pending_confirms_removed:progress.pending_confirms_removed
;;

let run_common_durable_cleanup
      config
      ~name
      ~(meta : keeper_meta)
      ~request
      ~progress
  =
  let task_settlement = settle_task_ownership config meta in
  let* settled_meta, released_task_ids =
    match task_settlement with
    | Ok value -> Ok value
    | Error (released_task_ids, detail) ->
      transaction_error
        Task_ownership_settlement
        { progress with released_task_ids }
        detail
  in
  let progress = { progress with released_task_ids } in
  let* pending_confirms_removed =
    match
      remove_pending_confirms_by_target
        config
        ~target_type:"keeper"
        ~target_id:(Some name)
    with
    | Ok removed -> Ok removed
    | Error detail -> transaction_error Pending_confirm_cleanup progress detail
  in
  let progress = { progress with pending_confirms_removed } in
  let* () =
    if not request.remove_session
    then Ok ()
    else
      remove_keeper_session config settled_meta
      |> Result.map_error (fun detail ->
           { stage = Session_removal; progress; detail })
  in
  Ok progress
;;

let run_joined_shutdown
      config
      ~name
      ~(meta : keeper_meta)
      ~(entry : Keeper_registry.registry_entry)
      ~request
  =
  let transaction () =
    ignore
      (Keeper_registry.begin_shutdown entry : Keeper_registry.shutdown_begin_result);
    let* () =
      dispatch_stop_requested config name
      |> Result.map_error (fun detail ->
           { stage = Stop_transition; progress = initial_progress; detail })
    in
    let* joined_entry, interrupt, grpc_close_error =
      match
        Keeper_keepalive.request_shutdown_and_await_exit
          ~base_path:config.base_path
          name
      with
      | Keeper_keepalive.Shutdown_keeper_not_registered ->
        transaction_error
          Lane_join
          initial_progress
          "registered lane disappeared before shutdown could join it"
      | Keeper_keepalive.Shutdown_self_join_rejected ->
        transaction_error
          Self_shutdown
          initial_progress
          "the shutdown request moved into its target turn and cannot join itself"
      | Keeper_keepalive.Shutdown_lane_joined
          { entry; grpc_close_error; interrupt } ->
        Ok (entry, interrupt, grpc_close_error)
    in
    let progress = { initial_progress with lane_joined = true } in
    let* () =
      match interrupt with
      | Keeper_registry.Shutdown_turn_state_error error ->
        transaction_error
          Turn_settlement
          progress
          (Keeper_registry.shutdown_state_error_to_string error)
      | Keeper_registry.Shutdown_no_turn_in_flight
      | Keeper_registry.Shutdown_turn_interrupted _
      | Keeper_registry.Shutdown_turn_interrupt_pending _ -> Ok ()
    in
    let* continuation_path =
      settle_interrupted_turn config joined_entry
      |> Result.map_error (fun detail ->
           { stage = Turn_settlement; progress; detail })
    in
    let progress = { progress with continuation_path } in
    let* () =
      match grpc_close_error with
      | None -> Ok ()
      | Some detail ->
        transaction_error
          Lane_join
          progress
          ("gRPC lane resource close failed: " ^ detail)
    in
    let* progress =
      run_common_durable_cleanup config ~name ~meta ~request ~progress
    in
    let* () =
      dispatch_drain_complete config name
      |> Result.map_error (fun detail ->
           { stage = Drain_complete; progress; detail })
    in
    let* () =
      complete_registry_shutdown config joined_entry
      |> Result.map_error (fun detail ->
           { stage = Terminal_commit; progress; detail })
    in
    let* () =
      if not request.remove_meta
      then Ok ()
      else
        remove_file_result (keeper_meta_path config name)
        |> Result.map_error (fun detail ->
             { stage = Meta_removal; progress; detail })
    in
    if request.remove_meta
    then Keeper_tool_emission_hook.drop_keeper_accumulator name;
    Ok progress
  in
  Eio.Cancel.protect transaction
  |> render_shutdown_transaction ~name ~request
;;

let run_absent_lane_shutdown config ~name ~(meta : keeper_meta) ~request =
  let transaction () =
    let progress = initial_progress in
    let* progress =
      run_common_durable_cleanup config ~name ~meta ~request ~progress
    in
    let* () =
      if not request.remove_meta
      then Ok ()
      else
        remove_file_result (keeper_meta_path config name)
        |> Result.map_error (fun detail ->
             { stage = Meta_removal; progress; detail })
    in
    if request.remove_meta
    then Keeper_tool_emission_hook.drop_keeper_accumulator name;
    Ok progress
  in
  Eio.Cancel.protect transaction
  |> render_shutdown_transaction ~name ~request
;;

let handle_keeper_down_config ~(config : Workspace.config) args : tool_result =
  let requested_name = String.trim (get_string args "name" "") in
  let request =
    { remove_meta = get_bool args "remove_meta" false
    ; remove_session = get_bool args "remove_session" false
    }
  in
  if not (validate_name requested_name)
  then
    tool_result_error
      (Printf.sprintf
         "invalid keeper name %S (must be non-empty and match \
          [A-Za-z0-9._-]+; see Keeper_config.validate_name)"
         requested_name)
  else
    match read_meta_resolved config requested_name with
    | Error error -> tool_result_error error
    | Ok resolved ->
      let entry = Keeper_registry.get ~base_path:config.base_path requested_name in
      let resolved_keeper =
        match resolved, entry with
        | Some (name, meta), _ -> Some (name, meta)
        | None, Some registered -> Some (registered.name, registered.meta)
        | None, None -> None
      in
      (match resolved_keeper with
       | None ->
         if request.remove_session
         then
           shutdown_failure
             ~stage:Session_removal
             ~name:requested_name
             ~request
             ~lane_joined:false
             ~continuation_path:None
             ~released_task_ids:[]
             ~pending_confirms_removed:0
             "keeper meta is absent, so no typed trace_id is available for session removal"
         else
           (match
              remove_pending_confirms_by_target
                config
                ~target_type:"keeper"
                ~target_id:(Some requested_name)
            with
            | Error detail ->
              shutdown_failure
                ~stage:Pending_confirm_cleanup
                ~name:requested_name
                ~request
                ~lane_joined:false
                ~continuation_path:None
                ~released_task_ids:[]
                ~pending_confirms_removed:0
                detail
            | Ok pending_confirms_removed ->
              keeper_down_success
                ~name:requested_name
                ~request
                ~lane_joined:false
                ~continuation_path:None
                ~released_task_ids:[]
                ~pending_confirms_removed)
       | Some (name, meta) ->
         let entry = Keeper_registry.get ~base_path:config.base_path name in
         (match entry with
          | Some registered when Keeper_registry.current_fiber_owns_turn registered ->
            shutdown_failure
              ~stage:Self_shutdown
              ~name
              ~request
              ~lane_joined:false
              ~continuation_path:None
              ~released_task_ids:[]
              ~pending_confirms_removed:0
              "a Keeper turn cannot synchronously join its own lane; use an external operator lane"
          | Some registered ->
            if not (Keeper_registry.try_claim_shutdown_transaction registered)
            then
              shutdown_failure
                ~stage:Lane_join
                ~name
                ~request
                ~lane_joined:false
                ~continuation_path:None
                ~released_task_ids:[]
                ~pending_confirms_removed:0
                "another operator fiber already owns this Keeper shutdown transaction"
            else
              Fun.protect
                ~finally:(fun () ->
                  Keeper_registry.release_shutdown_transaction registered)
                (fun () ->
                   match persist_paused_shutdown_intent config name meta with
                   | Error detail ->
                     shutdown_failure
                       ~stage:Paused_intent_persist
                       ~name
                       ~request
                       ~lane_joined:false
                       ~continuation_path:None
                       ~released_task_ids:[]
                       ~pending_confirms_removed:0
                       detail
                   | Ok paused_meta ->
                     run_joined_shutdown
                       config
                       ~name
                       ~meta:paused_meta
                       ~entry:registered
                       ~request)
          | None ->
            (match persist_paused_shutdown_intent config name meta with
             | Error detail ->
               shutdown_failure
                 ~stage:Paused_intent_persist
                 ~name
                 ~request
                 ~lane_joined:false
                 ~continuation_path:None
                 ~released_task_ids:[]
                 ~pending_confirms_removed:0
                 detail
             | Ok paused_meta ->
               run_absent_lane_shutdown
                 config
                 ~name
                 ~meta:paused_meta
                 ~request)))
;;

let handle_keeper_down (ctx : _ context) args =
  handle_keeper_down_config ~config:ctx.config args
;;

module For_testing = struct
  let remove_pending_confirms_by_target ~config ~target_type ~target_id =
    remove_pending_confirms_by_target config ~target_type ~target_id
  ;;

  let reset_remove_pending_confirms_by_target () =
    Atomic.set remove_pending_confirms_by_target_callback None
  ;;
end
