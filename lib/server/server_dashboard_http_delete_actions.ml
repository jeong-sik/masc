(** Dashboard delete action handlers — board, tasks, goals, agents.

    Extracted from server_routes_http_routes_dashboard.ml.
    Contains POST handler logic for /api/v1/dashboard/board/delete,
    /api/v1/dashboard/tasks/delete, /api/v1/dashboard/goals/delete,
    /api/v1/dashboard/goals/sweep, /api/v1/dashboard/agents/purge.
    Keeper purge is durable and asynchronous; plain-agent purge remains an
    exact synchronous cleanup. *)

module Http = Http_server_eio

open Server_auth

type agent_purge_cleanup_result =
  { agent_name : string
  ; heartbeats_stopped : int
  ; workspace_unbound : bool
  }

type path_removal = Path_absent | Path_removed

type plain_agent_resolve_error =
  | Invalid_plain_agent_name of string
  | Plain_agent_artifact_read_failed of string

let invalid_request field =
  Printf.sprintf "invalid request: requires {\"%s\":\"...\"}" field
;;

let respond_ok ~request reqd =
  Http.Response.json_value ~compress:true ~request (`Assoc [ ("ok", `Bool true) ]) reqd
;;

let respond_ok_with_warning ~request reqd warning =
  Http.Response.json_value
    ~compress:true
    ~request
    (`Assoc
      [ ("ok", `Bool true); ("partial_cleanup", `Bool true); ("warning", `String warning) ])
    reqd
;;

let respond_error ?(status = `Bad_request) ~request reqd message =
  Http.Response.json_value ~status ~request
    (`Assoc [ ("ok", `Bool false); ("error", `String message) ])
    reqd
;;

let path_error operation path exn =
  Printf.sprintf "%s failed for %s: %s" operation path (Printexc.to_string exn)
;;

let lstat_path_blocking path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exn -> Error (path_error "lstat" path exn)
;;

let lstat_path path =
  try Eio_guard.run_in_systhread (fun () -> lstat_path_blocking path) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (path_error "systhread lstat" path exn)
;;

let unlink_path_blocking path =
  try
    Unix.unlink path;
    Ok Path_removed
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Path_absent
  | exn -> Error (path_error "unlink" path exn)
;;

let rmdir_path_blocking path =
  try
    Unix.rmdir path;
    Ok Path_removed
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Path_absent
  | exn -> Error (path_error "rmdir" path exn)
;;

let rec remove_path_strict_blocking path =
  match lstat_path_blocking path with
  | Error _ as error -> error
  | Ok None -> Ok Path_absent
  | Ok (Some stat) ->
    (match stat.Unix.st_kind with
     | Unix.S_DIR ->
       let entries =
         try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare) with
         | exn -> Error (path_error "readdir" path exn)
       in
       (match entries with
        | Error _ as error -> error
        | Ok entries ->
          let rec remove_entries = function
            | [] -> rmdir_path_blocking path
            | entry :: rest ->
              (match remove_path_strict_blocking (Filename.concat path entry) with
               | Error _ as error -> error
               | Ok (Path_absent | Path_removed) -> remove_entries rest)
          in
          remove_entries entries)
     | Unix.S_REG
     | Unix.S_LNK
     | Unix.S_CHR
     | Unix.S_BLK
     | Unix.S_FIFO
     | Unix.S_SOCK -> unlink_path_blocking path)
;;

let remove_path_strict path =
  try Eio_guard.run_in_systhread (fun () -> remove_path_strict_blocking path) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (path_error "systhread recursive removal" path exn)
;;

let rec remove_paths_strict = function
  | [] -> Ok ()
  | path :: rest ->
    (match remove_path_strict path with
     | Error _ as error -> error
     | Ok outcome ->
       Log.Misc.debug
         "[dashboard_purge] artifact path=%s outcome=%s"
         path
         (match outcome with Path_absent -> "absent" | Path_removed -> "removed");
       remove_paths_strict rest)
;;

let validate_agent_alias alias =
  match Workspace.validate_agent_name alias with
  | Ok _ -> Ok alias
  | Error detail ->
    Error (Printf.sprintf "invalid exact agent purge owner %S: %s" alias detail)
;;

let exact_agent_aliases agent_names =
  let aliases =
    agent_names
    |> List.filter_map String_util.trim_to_option
    |> List.sort_uniq String.compare
  in
  let rec validate acc = function
    | [] -> Ok (List.rev acc)
    | alias :: rest ->
      (match validate_agent_alias alias with
       | Error _ as error -> error
       | Ok alias -> validate (alias :: acc) rest)
  in
  validate [] aliases
;;

let agent_file_path config agent_name =
  Filename.concat (Workspace.agents_dir config)
    (Workspace.safe_filename agent_name ^ ".json")
;;

let plain_agent_candidate_names requested_name =
  let trimmed = String.trim requested_name in
  [ trimmed ]
  |> List.filter (fun value -> value <> "")
;;

let plain_agent_artifacts_exist config agent_name =
  let rec any_path_exists = function
    | [] -> Ok false
    | path :: rest ->
      (match lstat_path path with
       | Error _ as error -> error
       | Ok (Some _) -> Ok true
       | Ok None -> any_path_exists rest)
  in
  any_path_exists
    [ agent_file_path config agent_name
    ; Metrics_store_eio.agent_metrics_dir config agent_name
    ; Auth.credential_file config.base_path agent_name
    ]
;;

let resolve_plain_agent_target config requested_name =
  match exact_agent_aliases (plain_agent_candidate_names requested_name) with
  | Error detail -> Error (Invalid_plain_agent_name detail)
  | Ok [] -> Ok None
  | Ok (agent_name :: _) ->
    (match plain_agent_artifacts_exist config agent_name with
     | Error detail -> Error (Plain_agent_artifact_read_failed detail)
     | Ok true -> Ok (Some agent_name)
     | Ok false -> Ok None)
;;

let plain_agent_resolve_error_to_string = function
  | Invalid_plain_agent_name detail -> detail
  | Plain_agent_artifact_read_failed detail -> detail
;;

let plain_agent_resolve_status = function
  | Invalid_plain_agent_name _ -> `Bad_request
  | Plain_agent_artifact_read_failed _ -> `Internal_server_error
;;

let agent_purge_cleanup_result_to_json
    { agent_name
    ; heartbeats_stopped
    ; workspace_unbound
    } =
  `Assoc
    [ ("agent_name", `String agent_name)
    ; ("heartbeats_stopped", `Int heartbeats_stopped)
    ; ("workspace_unbound", `Bool workspace_unbound)
    ]
;;

type credential_plan =
  { aliases : string list
  ; credential_paths : string list
  }
;;

let credential_plan config aliases =
  let owner_matches (credential : Masc_domain.agent_credential) =
    List.exists (String.equal credential.agent_name) aliases
  in
  let rec collect credential_paths = function
    | [] ->
      Ok
        { aliases
        ; credential_paths = List.sort_uniq String.compare credential_paths
        }
    | alias :: rest ->
      let alias_path = Auth.credential_file config.Workspace.base_path alias in
      (match lstat_path alias_path with
       | Error _ as error -> error
       | Ok None -> collect credential_paths rest
       | Ok (Some _) ->
         let loaded =
           try Ok (Auth.load_credential config.base_path alias) with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn -> Error (path_error "credential read" alias_path exn)
         in
         (match loaded with
          | Error _ as error -> error
          | Ok None ->
            Error
              (Printf.sprintf
                 "credential artifact is present but unreadable: owner=%s path=%s"
                 alias
                 alias_path)
          | Ok (Some credential) when owner_matches credential ->
            let credential_paths =
              match credential.id with
              | None -> alias_path :: credential_paths
              | Some credential_id ->
                Auth.credential_file
                  config.base_path
                  (Masc_domain.Credential_id.to_string credential_id)
                :: alias_path
                :: credential_paths
            in
            collect credential_paths rest
          | Ok (Some credential) ->
            Error
              (Printf.sprintf
                 "credential artifact owner mismatch: requested=%s persisted=%s path=%s"
                 alias
                 credential.agent_name
                 alias_path)))
  in
  collect [] aliases
;;

let delete_credentials config ({ aliases; credential_paths } : credential_plan) =
  let rec delete_aliases = function
    | [] -> remove_paths_strict credential_paths
    | alias :: rest ->
      (try
         Auth.delete_credential config.Workspace.base_path alias;
         delete_aliases rest
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Error
           (Printf.sprintf
              "credential deletion failed for exact owner %s: %s"
              alias
              (Printexc.to_string exn)))
  in
  delete_aliases aliases
;;

let unbind_exact_workspace_agents config aliases =
  try
    let state = Workspace.read_state config in
    let unbound =
      List.filter
        (fun alias -> List.exists (String.equal alias) state.active_agents)
        aliases
    in
    if unbound <> []
    then
      ignore
        (Workspace.update_state config (fun current ->
           { current with
             active_agents =
               List.filter
                 (fun active -> not (List.exists (String.equal active) aliases))
                 current.active_agents
           }));
    Ok unbound
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "exact workspace agent unbind failed for [%s]: %s"
         (String.concat "," aliases)
         (Printexc.to_string exn))
;;

let purge_agent_filesystem_artifacts config agent_names =
  match exact_agent_aliases agent_names with
  | Error _ as error -> error
  | Ok aliases ->
    (match credential_plan config aliases with
     | Error _ as error -> error
     | Ok credential_plan ->
       (match unbind_exact_workspace_agents config aliases with
        | Error _ as error -> error
        | Ok unbound ->
          let cleanup_results =
            List.map
              (fun agent_name ->
                 let heartbeats_stopped = Heartbeat.stop_by_agent ~agent_name in
                 Tool_shard.remove_agent_shards agent_name;
                 { agent_name
                 ; heartbeats_stopped
                 ; workspace_unbound =
                     List.exists (String.equal agent_name) unbound
                 })
              aliases
          in
          let filesystem_paths =
            aliases
            |> List.concat_map (fun alias ->
                 [ agent_file_path config alias
                 ; Metrics_store_eio.agent_metrics_dir config alias
                 ])
            |> List.sort_uniq String.compare
          in
          (match remove_paths_strict filesystem_paths with
           | Error _ as error -> error
           | Ok () ->
             (match delete_credentials config credential_plan with
              | Error _ as error -> error
              | Ok () ->
                List.iter
                  (fun result ->
                     Log.Misc.info
                       "[agent_purge] exact owner=%s heartbeats_stopped=%d workspace_unbound=%b"
                       result.agent_name
                       result.heartbeats_stopped
                       result.workspace_unbound)
                  cleanup_results;
                Ok cleanup_results))))
;;

let keeper_artifact_path config keeper_name artifact =
  let open Keeper_shutdown_types in
  match artifact with
  | Keeper_metrics_artifact ->
    Some (Keeper_types_support.keeper_metrics_path config keeper_name)
  | Keeper_memory_bank_artifact ->
    Some (Keeper_types_support.keeper_memory_bank_path config keeper_name)
  | Keeper_generation_index_artifact ->
    Some (Keeper_types_support.keeper_generation_index_path config keeper_name)
  | Keeper_policy_log_artifact ->
    Some (Keeper_types_support.keeper_policy_log_path config keeper_name)
  | Keeper_decision_log_artifact ->
    Some (Keeper_types_support.keeper_decision_log_path config keeper_name)
  | Keeper_feedback_log_artifact ->
    Some (Keeper_types_support.keeper_feedback_log_path config keeper_name)
  | Keeper_dataset_export_artifact ->
    Some (Keeper_types_support.keeper_dataset_export_path config keeper_name)
  | Keeper_runtime_directory_artifact ->
    Some (Filename.concat (Keeper_fs.keeper_dir config) keeper_name)
  | Keeper_configuration_artifact ->
    Some
      (Filename.concat
         (Config_dir_resolver.keepers_dir_for_base_path
            ~base_path:config.Workspace.base_path)
         (keeper_name ^ ".toml"))
  | Agent_artifact_bundle _ -> None
;;

let purge_dashboard_keeper_artifacts config operation =
  let open Keeper_shutdown_types in
  match operation.Keeper_shutdown_types.cleanup_intent.reason with
  | Dashboard_keeper_purge context ->
    let artifacts =
      Keeper_shutdown_types.dashboard_purge_artifact_plan
        ~keeper_name:operation.keeper_name
        context
    in
    let rec remove = function
      | [] -> Ok ()
      | Agent_artifact_bundle aliases :: rest ->
        (match purge_agent_filesystem_artifacts config aliases with
         | Error _ as error -> error
         | Ok _ -> remove rest)
      | artifact :: rest ->
        (match keeper_artifact_path config operation.keeper_name artifact with
         | None ->
           Error "dashboard Keeper purge artifact plan lost its typed projection"
         | Some path ->
           (match remove_path_strict path with
            | Error _ as error -> error
            | Ok outcome ->
              (match artifact with
               | Keeper_runtime_directory_artifact ->
                 Keeper_fs.invalidate_dir path
               | Keeper_metrics_artifact
               | Keeper_memory_bank_artifact
               | Keeper_generation_index_artifact
               | Keeper_policy_log_artifact
               | Keeper_decision_log_artifact
               | Keeper_feedback_log_artifact
               | Keeper_dataset_export_artifact
               | Keeper_configuration_artifact
               | Agent_artifact_bundle _ -> ());
              Log.Keeper.debug
                "dashboard Keeper purge artifact: keeper=%s path=%s outcome=%s"
                operation.keeper_name
                path
                (match outcome with
                 | Path_absent -> "absent"
                 | Path_removed -> "removed");
              remove rest))
    in
    remove artifacts
  | Operator_stop_retain_meta
  | Operator_stop_remove_meta
  | Dead_tombstone_cleanup ->
    Error "dashboard Keeper purge artifacts require a dashboard purge operation"
;;

let handle_dashboard_keeper_purge_completion config operation =
  match Masc_event_bus.get () with
  | None -> Error "MASC lifecycle event bus is not installed"
  | Some _ ->
    (match operation.Keeper_shutdown_types.cleanup_intent.reason with
     | Keeper_shutdown_types.Dashboard_keeper_purge context ->
       (match purge_dashboard_keeper_artifacts config operation with
        | Error _ as error -> error
        | Ok () ->
          let operation_id =
            Keeper_shutdown_types.Operation_id.to_string operation.operation_id
          in
          Keeper_supervisor_publish_lifecycle.publish_lifecycle
            ~event:
              (Keeper_lifecycle_events.Custom_event
                 { verb = Keeper_lifecycle_events.Purged; phase = None })
            operation.keeper_name
            (Printf.sprintf
               "requested_name=%s agent_name=%s shutdown_operation=%s"
               context.requested_name
               context.agent_name
               operation_id)
            ();
          Log.Keeper.info
            "dashboard Keeper purge completion delivered: keeper=%s operation=%s"
            operation.keeper_name
            operation_id;
          Ok ())
     | Operator_stop_retain_meta
     | Operator_stop_remove_meta
     | Dead_tombstone_cleanup ->
       Error "dashboard purge completion does not belong to a dashboard purge operation")
;;

let handle_keeper_lifecycle_completion config operation = function
  | Keeper_shutdown_types.Dashboard_keeper_purged ->
    handle_dashboard_keeper_purge_completion config operation
  | Dead_tombstone_reaped as action ->
    Keeper_supervisor_cleanup_tombstone.handle_completion config operation action
;;

let keeper_purge_resolve_status = function
  | Keeper_dashboard_purge.Empty_requested_name -> `Bad_request
  | Invalid_requested_name _ -> `Bad_request
  | Keeper_metadata_unreadable _ -> `Internal_server_error
  | Keeper_metadata_required _
  | Keeper_metadata_name_mismatch _
  | Keeper_agent_name_invalid _ -> `Conflict
  | Keeper_operation_unreadable _ -> `Internal_server_error
;;

let keeper_purge_submit_status = function
  | Keeper_shutdown_runtime.Worker_start_error _ -> `Service_unavailable
  | Existing_operation_load_error _ -> `Internal_server_error
  | Prepare_error _
  | Existing_operation_lane_mismatch _
  | Existing_operation_intent_mismatch _ -> `Conflict
;;

module For_testing = struct
  let purge_dashboard_keeper_artifacts = purge_dashboard_keeper_artifacts
end

let respond_keeper_purge_operation_accepted ~request reqd operation =
  match operation.Keeper_shutdown_types.cleanup_intent.reason with
  | Keeper_shutdown_types.Dashboard_keeper_purge context ->
    Http.Response.json_value
      ~status:`Accepted
      ~compress:true
      ~request
      (`Assoc
         [ ("ok", `Bool true)
         ; ("accepted", `Bool true)
         ; ("target_kind", `String "keeper")
         ; ("agent_name", `String context.agent_name)
         ; ("keeper_name", `String operation.keeper_name)
         ; ( "operation_id"
           , `String
               (Keeper_shutdown_types.Operation_id.to_string
                  operation.operation_id) )
         ])
      reqd
  | Operator_stop_retain_meta
  | Operator_stop_remove_meta
  | Dead_tombstone_cleanup ->
    respond_error
      ~status:`Internal_server_error
      ~request
      reqd
      "dashboard purge acceptance received a non-dashboard lifecycle operation"
;;

let add_delete_action_routes router =
  router
  |> Http.Router.post "/api/v1/dashboard/board/delete" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "post_id" json with
             | None ->
                 respond_error ~request:req reqd (invalid_request "post_id")
             | Some post_id ->
             match Board_dispatch.delete_post ~post_id with
             | Ok () -> respond_ok ~request:req reqd
             | Error err ->
                 respond_error ~status:`Not_found ~request:req reqd
                   (Board_tool.board_error_to_string err)
           with Yojson.Json_error _ ->
             respond_error ~request:req reqd (invalid_request "post_id")
         )
       ) request reqd)

  (* Pin is an operator-curated board mutation: same CanAdmin gate and auth
     helper as board/delete, so it lives alongside it rather than as an
     agent-facing MCP tool (which would let any keeper self-pin). *)
  |> Http.Router.post "/api/v1/dashboard/board/pin" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "post_id" json with
             | None ->
                 respond_error ~request:req reqd (invalid_request "post_id")
             | Some post_id ->
             let pinned = Safe_ops.json_bool ~default:true "pinned" json in
             match Board_dispatch.set_pinned ~post_id ~pinned with
             | Ok () -> respond_ok ~request:req reqd
             | Error err ->
                 respond_error ~status:`Not_found ~request:req reqd
                   (Board_tool.board_error_to_string err)
           with Yojson.Json_error _ ->
             respond_error ~request:req reqd (invalid_request "post_id")
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/tasks/delete" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "task_id" json with
             | None ->
                 respond_error ~request:req reqd (invalid_request "task_id")
             | Some task_id ->
             let config = (Mcp_server.workspace_config state) in
             match Task.Dispatch.delete_task config ~task_id with
             | Ok () -> respond_ok ~request:req reqd
             | Error err ->
                 respond_error ~status:`Not_found ~request:req reqd
                   (Printf.sprintf "task delete failed: %s"
                      (Masc_domain.masc_error_to_string err))
           with Yojson.Json_error _ ->
             respond_error ~request:req reqd (invalid_request "task_id")
         )
       ) request reqd)

  (* RFC-0267 Phase 2: assign an existing goalless task to a goal. Operator
     surface (CanAdmin); shares the validated backend
     [Task.Goal_assignment.set_task_goal] with the masc_task_set_goal MCP tool,
     so the precondition checks live in exactly one place. *)
  |> Http.Router.post "/api/v1/dashboard/tasks/assign-goal" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match
               ( Safe_ops.json_string_opt "task_id" json
               , Safe_ops.json_string_opt "goal_id" json )
             with
             | None, _ -> respond_error ~request:req reqd (invalid_request "task_id")
             | _, None -> respond_error ~request:req reqd (invalid_request "goal_id")
             | Some task_id, Some goal_id ->
             let config = (Mcp_server.workspace_config state) in
             (match Task.Goal_assignment.set_task_goal config ~task_id ~goal_id with
              | Ok () -> respond_ok ~request:req reqd
              | Error
                  (( Task.Goal_assignment.Unknown_task _
                   | Task.Goal_assignment.Unknown_goal _ ) as err) ->
                respond_error ~status:`Not_found ~request:req reqd
                  (Task.Goal_assignment.set_task_goal_error_to_string err)
              | Error (Task.Goal_assignment.Already_assigned _ as err) ->
                respond_error ~status:`Conflict ~request:req reqd
                  (Task.Goal_assignment.set_task_goal_error_to_string err)
              | Error (Task.Goal_assignment.Link_write_failed _ as err) ->
                respond_error ~status:`Internal_server_error ~request:req reqd
                  (Task.Goal_assignment.set_task_goal_error_to_string err))
           with Yojson.Json_error _ ->
             respond_error ~request:req reqd (invalid_request "task_id")
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/goals/delete" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "goal_id" json with
             | None ->
                 respond_error ~request:req reqd (invalid_request "goal_id")
             | Some goal_id ->
             let config = (Mcp_server.workspace_config state) in
             match Goal_store.delete_goal config ~goal_id with
             | Ok Goal_store.Deleted -> respond_ok ~request:req reqd
             | Ok (Goal_store.Deleted_with_orphaned_links warning) ->
                 respond_ok_with_warning ~request:req reqd warning
             | Error (Goal_store.Unknown_goal _ as err) ->
                 respond_error ~status:`Not_found ~request:req reqd
                  (Goal_store.delete_goal_error_to_string err)
             | Error (Goal_store.Persistence_failed _ as err) ->
                 respond_error ~status:`Internal_server_error ~request:req reqd
                   (Goal_store.delete_goal_error_to_string err)
           with Yojson.Json_error _ ->
             respond_error ~request:req reqd (invalid_request "goal_id")
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/agents/purge" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state actor req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "agent_name" json with
             | None ->
               respond_error ~request:req reqd (invalid_request "agent_name")
             | Some requested_name ->
               let config = (Mcp_server.workspace_config state) in
               (match
                  Keeper_dashboard_purge.existing_operation
                    config
                    requested_name
                with
                | Error error ->
                  respond_error
                    ~status:(keeper_purge_resolve_status error)
                    ~request:req
                    reqd
                    (Keeper_dashboard_purge.resolve_error_to_string error)
                | Ok (Some operation) ->
                  respond_keeper_purge_operation_accepted
                    ~request:req
                    reqd
                    operation
                | Ok None ->
                  (match Keeper_dashboard_purge.resolve config requested_name with
                  | Error error ->
                    respond_error
                      ~status:(keeper_purge_resolve_status error)
                      ~request:req
                      reqd
                      (Keeper_dashboard_purge.resolve_error_to_string error)
                  | Ok (Some keeper_target) ->
                  (match
                     Keeper_dashboard_purge.submit
                       ~config
                       ~actor
                       keeper_target
                   with
                   | Error error ->
                     respond_error
                       ~status:(keeper_purge_submit_status error)
                       ~request:req
                       reqd
                       (Keeper_shutdown_runtime.submit_error_to_string error)
                   | Ok operation ->
                     respond_keeper_purge_operation_accepted
                       ~request:req
                       reqd
                       operation)
                  | Ok None ->
                    (match resolve_plain_agent_target config requested_name with
                    | Error error ->
                      respond_error
                        ~status:(plain_agent_resolve_status error)
                        ~request:req
                        reqd
                        (plain_agent_resolve_error_to_string error)
                    | Ok (Some agent_name) ->
                      (match
                         purge_agent_filesystem_artifacts config
                           [ agent_name ]
                       with
                       | Error msg ->
                         respond_error
                           ~status:`Internal_server_error
                           ~request:req
                           reqd
                           msg
                       | Ok cleanup_results ->
                      Http.Response.json_value ~compress:true ~request:req
                        (`Assoc
                           [
                             ("ok", `Bool true);
                             ("accepted", `Bool false);
                             ("target_kind", `String "agent");
                             ("agent_name", `String agent_name);
                             ( "cleanup_results",
                               `List
                                 (List.map agent_purge_cleanup_result_to_json
                                    cleanup_results) );
                           ])
                        reqd)
                    | Ok None ->
                      respond_error ~status:`Not_found ~request:req reqd
                        "agent or keeper not found")))
           with Yojson.Json_error _ ->
             respond_error ~request:req reqd (invalid_request "agent_name")
         )
       ) request reqd)

  (* ── Board moderation routes (Phase 2) ───────────────────────────── *)

  |> Http.Router.post "/api/v1/dashboard/board/moderation/flag" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let target_kind_str =
               Safe_ops.json_string_opt "target_kind" json
               |> Option.value ~default:"post"
             in
             let target_kind =
               Board_moderation.target_kind_of_string target_kind_str
               |> Option.value ~default:Board_moderation.Target_post
             in
             let reason_str =
               Safe_ops.json_string_opt "reason" json
               |> Option.value ~default:"spam"
             in
             let reason =
               Board_moderation.flag_reason_of_string reason_str
               |> Option.value ~default:Board_moderation.Spam
             in
            (match Safe_ops.json_string_opt "target_id" json with
             | None ->
                  respond_error ~request:req reqd (invalid_request "target_id")
             | Some target_id ->
                  let reporter = agent_name in
                   (match Board_moderation.flag ~target_kind ~target_id ~reporter ~reason with
                    | Error msg ->
                       Http.Response.json_value ~status:`Conflict ~request:req
                         (`Assoc [("ok", `Bool false); ("error", `String msg)])
                         reqd
                    | Ok entry ->
                       Http.Response.json_value ~compress:true ~request:req
                         (`Assoc
                            [
                              ("ok", `Bool true);
                              ("entry", Board_moderation.queue_entry_to_json entry);
                            ])
                         reqd))
           with Yojson.Json_error _ ->
             respond_error ~request:req reqd "invalid JSON body"
         )
       ) request reqd)

  |> Http.Router.get "/api/v1/dashboard/board/moderation/queue" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name req reqd ->
         let resolved_param =
           match Server_utils.query_param req "resolved" with
           | Some "true"  -> Some true
           | Some "false" -> Some false
           | _            -> None
         in
         let entries = Board_moderation.get_queue ?resolved:resolved_param () in
         let json = `Assoc [
           ("ok",      `Bool true);
           ("entries", `List (List.map Board_moderation.queue_entry_to_json entries));
           ("count",   `Int (List.length entries));
         ] in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/board/moderation/action" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let target_kind_str =
               Safe_ops.json_string_opt "target_kind" json
               |> Option.value ~default:"post"
             in
             let target_kind =
               Board_moderation.target_kind_of_string target_kind_str
               |> Option.value ~default:Board_moderation.Target_post
             in
             let action_str =
               Safe_ops.json_string_opt "action" json
               |> Option.value ~default:""
             in
               (match Board_moderation.action_kind_of_string action_str with
                | None ->
                  Http.Response.json_value ~status:`Bad_request ~request:req
                    (`Assoc
                       [
                         ("ok", `Bool false);
                         ( "error",
                           `String
                             ("unknown action: " ^ action_str
                            ^ "; valid: approve, remove, hide, warn") );
                       ])
                    reqd
              | Some action ->
                  (match Safe_ops.json_string_opt "target_id" json with
                   | None ->
                       respond_error ~request:req reqd (invalid_request "target_id")
                   | Some target_id ->
                       let reason =
                         Option.bind
                           (Safe_ops.json_string_opt "reason" json)
                           Board_moderation.flag_reason_of_string
                       in
                       let note = Safe_ops.json_string_opt "note" json in
                       let actor = agent_name in
                       (match Board_moderation.record_action ~target_kind ~target_id
                                ~actor ~action ?reason ?note () with
                        | Error msg ->
                            Http.Response.json_value
                              ~status:`Internal_server_error ~request:req
                              (`Assoc
                                 [("ok", `Bool false); ("error", `String msg)])
                              reqd
                        | Ok entry ->
                            (* If the action is Remove, also delete from board *)
                            let delete_result =
                              if action = Board_moderation.Remove then
                                (match target_kind with
                                 | Board_moderation.Target_post ->
                                     (match Board_dispatch.delete_post ~post_id:target_id with
                                      | Ok () -> None
                                      | Error e ->
                                          Some (Board_tool.board_error_to_string e))
                                 | Board_moderation.Target_comment ->
                                     (* Comment removal not yet backed by dispatch; note only *)
                                     None)
                              else
                                None
                            in
                            let extra =
                              match delete_result with
                              | None      -> []
                              | Some warn -> [("delete_warning", `String warn)]
                            in
                            Http.Response.json_value ~compress:true ~request:req
                              (`Assoc
                                 ([ ("ok", `Bool true);
                                    ( "entry",
                                      Board_moderation.audit_entry_to_json entry
                                    );
                                  ]
                                  @ extra))
                              reqd)))
           with Yojson.Json_error _ ->
             respond_error ~request:req reqd "invalid JSON body"
         )
       ) request reqd)
