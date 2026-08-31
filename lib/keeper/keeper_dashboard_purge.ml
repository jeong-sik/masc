type target =
  { requested_name : string
  ; keeper_name : string
  ; meta : Keeper_meta_contract.keeper_meta
  }

type resolve_error =
  | Empty_requested_name
  | Invalid_requested_name of
      { requested_name : string
      ; detail : string
      }
  | Keeper_metadata_unreadable of
      { keeper_name : string
      ; metadata_path : string
      ; detail : string
      }
  | Keeper_metadata_required of
      { keeper_name : string
      ; configuration_path : string
      }
  | Keeper_metadata_name_mismatch of
      { expected_keeper_name : string
      ; persisted_keeper_name : string
      }
  | Keeper_owner_unavailable of
      { keeper_name : string
      ; detail : string
      }
  | Keeper_operation_unreadable of
      { keeper_name : string
      ; operation_id : Keeper_shutdown_types.Operation_id.t
      ; detail : string
      }
  | Keeper_purge_blocked of
      { keeper_name : string
      ; operation_id : Keeper_shutdown_types.Operation_id.t
      ; detail : string
      }
  | Keeper_lane_executing of
      { keeper_name : string
      ; phase : string
      ; live_turn_id : int option
      }

let resolve_error_to_string = function
  | Keeper_purge_blocked { keeper_name; operation_id; detail } ->
    Printf.sprintf
      "keeper purge %s is blocked and will not resume on its own: keeper=%s \
       failure=%s; release the admission fence with an operator supersession, \
       then reissue the purge"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
      keeper_name
      detail
  | Keeper_lane_executing { keeper_name; phase; live_turn_id } ->
    (match live_turn_id with
     | None ->
       Printf.sprintf
         "dashboard Keeper purge refused while the lane is executing: \
          keeper=%s phase=%s. Stop or pause the Keeper first."
         keeper_name
         phase
     | Some turn_id ->
       Printf.sprintf
         "dashboard Keeper purge refused while a turn is in flight: keeper=%s \
          phase=%s turn=%d. Let the turn finish, or stop the Keeper first."
         keeper_name
         phase
         turn_id)
  | Empty_requested_name -> "dashboard Keeper purge requires a non-empty target name"
  | Invalid_requested_name { requested_name; detail } ->
    Printf.sprintf
      "dashboard purge target name is invalid: target=%S error=%s"
      requested_name
      detail
  | Keeper_metadata_unreadable { keeper_name; metadata_path; detail } ->
    Printf.sprintf
      "dashboard Keeper purge cannot read exact owner metadata: keeper=%s path=%s error=%s"
      keeper_name
      metadata_path
      detail
  | Keeper_metadata_required { keeper_name; configuration_path } ->
    Printf.sprintf
      "dashboard Keeper purge requires persisted owner metadata before removing a configured Keeper: keeper=%s config=%s"
      keeper_name
      configuration_path
  | Keeper_metadata_name_mismatch
      { expected_keeper_name; persisted_keeper_name } ->
    Printf.sprintf
      "dashboard Keeper purge metadata owner mismatch: expected=%s persisted=%s"
      expected_keeper_name
      persisted_keeper_name
  | Keeper_owner_unavailable { keeper_name; detail } ->
    Printf.sprintf
      "dashboard Keeper purge cannot read Owner shutdown state: keeper=%s error=%s"
      keeper_name
      detail
  | Keeper_operation_unreadable { keeper_name; operation_id; detail } ->
    Printf.sprintf
      "dashboard Keeper purge cannot load the operation owning admission: keeper=%s operation=%s error=%s"
      keeper_name
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
      detail
;;

let canonical_requested_name requested_name =
  let requested_name = String.trim requested_name in
  if String.equal requested_name ""
  then Error Empty_requested_name
  else
    match Keeper_id.Keeper_name.of_string requested_name with
    | Ok keeper_name -> Ok (Keeper_id.Keeper_name.to_string keeper_name)
    | Error keeper_detail ->
      (* This resolver runs before the plain-agent purge boundary. Keep its
         namespaced identity grammar available for fallthrough, but never let
         that generic 64-character gate reject a Keeper name that the Keeper
         creation contract already admitted up to [Keeper_name.max_length]. *)
      (match Workspace.validate_agent_name requested_name with
       | Ok _ -> Ok requested_name
       | Error _ ->
         Error
           (Invalid_requested_name
              { requested_name; detail = keeper_detail }))
;;

let resolve (config : Workspace.config) requested_name =
  match canonical_requested_name requested_name with
  | Error _ as error -> error
  | Ok requested_name ->
      let keeper_name = requested_name in
      let metadata_path = Keeper_types_profile.keeper_meta_path config keeper_name in
      let configuration_path =
        Config_dir_resolver.keeper_toml_path_opt_for_base_path
          ~base_path:config.base_path
          keeper_name
      in
      (match Keeper_meta_store.read_meta config keeper_name with
       | Error detail ->
         Error
           (Keeper_metadata_unreadable { keeper_name; metadata_path; detail })
       | Ok (Some meta) when String.equal meta.name keeper_name ->
         (* Two signals, because the two lanes admit turns differently. The
            autonomous cycle only enters through a phase [can_execute_turn]
            admits, but the chat lane runs
            [run_keeper_invocation_turn_admitted] and never changes phase —
            [mark_turn_started] writes [current_turn_observation] and leaves
            [phase] alone. A phase-only guard therefore reads a Paused
            Keeper answering a chat message as purgeable. *)
         (match Keeper_registry.get ~base_path:config.base_path keeper_name with
          | Some entry when Keeper_state_machine.can_execute_turn entry.phase ->
            Error
              (Keeper_lane_executing
                 { keeper_name
                 ; phase = Keeper_state_machine.phase_to_string entry.phase
                 ; live_turn_id = None
                 })
          | Some { current_turn_observation = Some observation; phase; _ } ->
            Error
              (Keeper_lane_executing
                 { keeper_name
                 ; phase = Keeper_state_machine.phase_to_string phase
                 ; live_turn_id = Some observation.turn_id
                 })
          | Some _ | None -> Ok (Some { requested_name; keeper_name; meta }))
       | Ok (Some meta) ->
         Error
           (Keeper_metadata_name_mismatch
              { expected_keeper_name = keeper_name
              ; persisted_keeper_name = meta.name
              })
       | Ok None ->
         (match configuration_path with
          | Some configuration_path ->
            Error
              (Keeper_metadata_required { keeper_name; configuration_path })
          | None -> Ok None))
;;

let existing_operation (config : Workspace.config) requested_name =
  match canonical_requested_name requested_name with
  | Error _ as error -> error
  | Ok keeper_name ->
    let snapshot =
      Keeper_owner_registry.shutdown_operation_id
        ~base_path:config.base_path
        ~keeper_name
    in
    (match snapshot with
     | Error error ->
       Error
         (Keeper_owner_unavailable
            { keeper_name
            ; detail = Keeper_owner_registry.lookup_error_to_string error
            })
     | Ok None -> Ok None
     | Ok (Some operation_id) ->
       (match Keeper_shutdown_store.load ~config ~keeper_name operation_id with
        | Error error ->
          Error
            (Keeper_operation_unreadable
               { keeper_name
               ; operation_id
               ; detail = Keeper_shutdown_store.error_to_string error
               })
        | Ok operation ->
          (match operation.cleanup_intent.reason with
           | Keeper_shutdown_types.Dashboard_keeper_purge _ ->
             (match operation.phase with
              | Keeper_shutdown_types.Blocked failure ->
                Error
                  (Keeper_purge_blocked
                     { keeper_name
                     ; operation_id
                     ; detail =
                         Printf.sprintf
                           "%s: %s"
                           (Keeper_shutdown_types.failure_stage_to_string
                              failure.Keeper_shutdown_types.stage)
                           failure.Keeper_shutdown_types.detail
                     })
              | Prepared
              | Joining_lanes
              | Joined_idle
              | Finalizing_tasks _
              | Cleanup_ready _
              | Reconciliation_required _
              | Finalized _
              | Superseded _ -> Ok (Some operation))
           | Operator_stop_retain_meta
           | Operator_stop_remove_meta
           | Supervisor_cleanup -> Ok None)))
;;

let submit ~config ~actor ({ requested_name; keeper_name; meta } : target) =
  let context : Keeper_shutdown_types.dashboard_purge_context = { requested_name } in
  let request : Keeper_shutdown_prepare_join.request =
    { actor
    ; cleanup_intent =
        { reason = Keeper_shutdown_types.Dashboard_keeper_purge context
        ; remove_session = true
        }
    }
  in
  match Keeper_registry.get ~base_path:config.Workspace.base_path keeper_name with
  | Some entry -> Keeper_shutdown_runtime.submit ~config ~entry ~request
  | None -> Keeper_shutdown_runtime.submit_dormant ~config ~meta ~request
;;
