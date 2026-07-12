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
  | Keeper_agent_name_invalid of
      { keeper_name : string
      ; agent_name : string
      ; detail : string
      }
  | Keeper_operation_unreadable of
      { keeper_name : string
      ; operation_id : Keeper_shutdown_types.Operation_id.t
      ; detail : string
      }

let resolve_error_to_string = function
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
  | Keeper_agent_name_invalid { keeper_name; agent_name; detail } ->
    Printf.sprintf
      "dashboard Keeper purge metadata has an invalid agent owner: keeper=%s agent=%S error=%s"
      keeper_name
      agent_name
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
    match Workspace.validate_agent_name requested_name with
    | Error detail -> Error (Invalid_requested_name { requested_name; detail })
    | Ok _ -> Ok (requested_name, Keeper_identity.canonical_keeper_name requested_name)
;;

let resolve (config : Workspace.config) requested_name =
  match canonical_requested_name requested_name with
  | Error _ as error -> error
  | Ok (requested_name, canonical_name) ->
    match canonical_name with
    | None -> Ok None
    | Some keeper_name ->
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
         (match Workspace.validate_agent_name meta.agent_name with
          | Ok _ -> Ok (Some { requested_name; keeper_name; meta })
          | Error detail ->
            Error
              (Keeper_agent_name_invalid
                 { keeper_name; agent_name = meta.agent_name; detail }))
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
  | Ok (_, None) -> Ok None
  | Ok (_, Some keeper_name) ->
    let snapshot =
      Keeper_turn_admission.snapshot_for
        ~base_path:config.base_path
        ~keeper_name
    in
    (match snapshot.snapshot_shutdown_operation_id with
     | None -> Ok None
     | Some operation_id ->
       (match Keeper_shutdown_store.load ~config ~keeper_name operation_id with
        | Error error ->
          Error
            (Keeper_operation_unreadable
               { keeper_name
               ; operation_id
               ; detail = Keeper_shutdown_store.error_to_string error
               })
        | Ok operation ->
          Ok
            (match operation.cleanup_intent.reason with
             | Keeper_shutdown_types.Dashboard_keeper_purge _ -> Some operation
             | Operator_stop_retain_meta
             | Operator_stop_remove_meta
             | Dead_tombstone_cleanup
             | Stale_paused_prune _ -> None)))
;;

let submit ~config ~actor ({ requested_name; keeper_name; meta } : target) =
  let context : Keeper_shutdown_types.dashboard_purge_context =
    { requested_name; agent_name = meta.agent_name; meta_version = meta.meta_version }
  in
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
