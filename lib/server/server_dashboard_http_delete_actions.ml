(** Dashboard delete action handlers — board, tasks, goals, agents.

    Extracted from server_routes_http_routes_dashboard.ml.
    Contains POST handler logic for /api/v1/dashboard/board/delete,
    /api/v1/dashboard/tasks/delete, /api/v1/dashboard/goals/delete,
    /api/v1/dashboard/goals/sweep, /api/v1/dashboard/agents/purge. *)

module Http = Http_server_eio

open Server_auth

type keeper_purge_target =
  { keeper_name : string
  ; agent_name : string
  ; trace_id : string option
  ; toml_path : string option
  }

type agent_purge_cleanup_result =
  { agent_name : string
  ; pending_confirms_removed : int
  ; heartbeats_stopped : int
  ; workspace_unbind_result : string
  }

type agent_purge_cleanup_target =
  { agent_name : string
  ; aliases : string list
  }

type keeper_purge_cleanup_result =
  { keeper_pending_confirms_removed : int
  ; agent_cleanup_results : agent_purge_cleanup_result list
  }

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

let sum_pending_confirm_removals config ~target_type target_ids =
  target_ids
  |> List.fold_left
       (fun acc target_id ->
         match acc with
         | Error _ -> acc
         | Ok total -> (
           match
             Operator_pending_confirm.remove_pending_confirms_by_target
               config
               ~target_type
               ~target_id:(Some target_id)
           with
           | Ok removed -> Ok (total + removed)
           | Error msg ->
             Error
               (Printf.sprintf
                  "pending-confirm cleanup failed for %s %s: %s"
                  target_type
                  target_id
                  msg)))
       (Ok 0)
;;

let rec rm_rf path =
  if Fs_compat.file_exists path
  then if Sys.is_directory path
  then (
    Sys.readdir path
    |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
    (try Fs_compat.rmdir path with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Misc.warn "[agent_purge] failed to remove directory %s: %s"
         path (Printexc.to_string exn)))
  else Safe_ops.remove_file_logged ~context:"agent_purge" path
;;

let remove_path_if_exists ~context path =
  if Fs_compat.file_exists path
  then if Sys.is_directory path
  then rm_rf path
  else Safe_ops.remove_file_logged ~context path
;;

let credential_aliases agent_name =
  let trimmed = String.trim agent_name in
  let aliases =
    [
      Some trimmed;
      (if Nickname.is_generated_nickname trimmed
       then Nickname.extract_agent_type trimmed
       else None);
    ]
  in
  aliases
  |> List.filter_map (function
       | Some value when value <> "" -> Some value
       | _ -> None)
  |> Json_util.dedupe_keep_order
;;

let agent_file_path config agent_name =
  Filename.concat (Workspace.agents_dir config)
    (Workspace.safe_filename agent_name ^ ".json")
;;

let resolve_keeper_purge_target config requested_name =
  let trimmed = String.trim requested_name in
  let candidates =
    [
      Some trimmed;
      Keeper_identity.canonical_keeper_name_from_agent_name trimmed;
      Keeper_identity.canonical_keeper_name trimmed;
    ]
    |> List.filter_map (function
         | Some value when value <> "" -> Some value
         | _ -> None)
    |> Json_util.dedupe_keep_order
  in
  let rec loop = function
    | [] -> None
    | candidate :: rest -> (
      let candidate_meta_path = Keeper_types_profile.keeper_meta_path config candidate in
      let candidate_toml_path = Config_dir_resolver.keeper_toml_path_opt candidate in
      match Keeper_meta_store.read_meta_resolved config candidate with
      | Ok (Some (resolved_name, meta)) ->
        Some
          {
            keeper_name = resolved_name;
            agent_name = meta.agent_name;
            trace_id =
              Some (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
            toml_path = Config_dir_resolver.keeper_toml_path_opt resolved_name;
          }
      | Ok None ->
        if Fs_compat.file_exists candidate_meta_path
           || Option.is_some candidate_toml_path
        then
          Some
            {
              keeper_name = candidate;
              agent_name = Keeper_identity.keeper_agent_name candidate;
              trace_id = None;
              toml_path = candidate_toml_path;
            }
        else loop rest
      | Error err ->
        if Fs_compat.file_exists candidate_meta_path
           || Option.is_some candidate_toml_path
        then (
          Log.Keeper.warn
            "agent purge: continuing despite keeper meta read failure for %s: %s"
            candidate err;
          Some
            {
              keeper_name = candidate;
              agent_name = Keeper_identity.keeper_agent_name candidate;
              trace_id = None;
              toml_path = candidate_toml_path;
            })
        else loop rest)
  in
  loop candidates
;;

let plain_agent_candidate_names config requested_name =
  let trimmed = String.trim requested_name in
  let resolved = Workspace.resolve_agent_name config trimmed in
  [ trimmed; resolved ]
  |> List.filter (fun value -> value <> "")
  |> Json_util.dedupe_keep_order
;;

let plain_agent_artifacts_exist config agent_name =
  let agent_exists = Fs_compat.file_exists (agent_file_path config agent_name) in
  let metrics_exists =
    Fs_compat.file_exists (Metrics_store_eio.agent_metrics_dir config agent_name)
  in
  let credential_exists =
    credential_aliases agent_name
    |> List.exists (fun alias ->
         Fs_compat.file_exists
           (Auth.credential_file config.base_path alias))
  in
  agent_exists || metrics_exists || credential_exists
;;

let resolve_plain_agent_target config requested_name =
  plain_agent_candidate_names config requested_name
  |> List.find_opt (plain_agent_artifacts_exist config)
;;

let agent_purge_cleanup_result_to_json
    { agent_name
    ; pending_confirms_removed
    ; heartbeats_stopped
    ; workspace_unbind_result
    } =
  `Assoc
    [ ("agent_name", `String agent_name)
    ; ("pending_confirms_removed", `Int pending_confirms_removed)
    ; ("heartbeats_stopped", `Int heartbeats_stopped)
    ; ("workspace_unbind_result", `String workspace_unbind_result)
    ]
;;

let resolve_agent_purge_targets config agent_names =
  let aliases_by_agent = Hashtbl.create (List.length agent_names) in
  let order = ref [] in
  let add_alias ~agent_name alias =
    let aliases =
      match Hashtbl.find_opt aliases_by_agent agent_name with
      | Some existing -> existing
      | None ->
        order := agent_name :: !order;
        []
    in
    Hashtbl.replace aliases_by_agent agent_name
      (aliases @ [ alias; agent_name ] |> Json_util.dedupe_keep_order)
  in
  agent_names
  |> List.iter (fun requested_name ->
       let alias = String.trim requested_name in
       if alias <> ""
       then (
         let agent_name = Workspace.resolve_agent_name config alias |> String.trim in
         if agent_name <> "" then add_alias ~agent_name alias));
  !order
  |> List.rev
  |> List.map (fun agent_name ->
       let aliases =
         Hashtbl.find_opt aliases_by_agent agent_name
         |> Option.value ~default:[ agent_name ]
         |> List.rev
         |> Json_util.dedupe_keep_order
         |> List.rev
       in
       { agent_name; aliases })
;;

let purge_agent_filesystem_artifacts config agent_names =
  agent_names
  |> resolve_agent_purge_targets config
  |> List.fold_left
       (fun acc { agent_name; aliases } ->
         match acc with
         | Error _ -> acc
         | Ok results -> (
           match sum_pending_confirm_removals config ~target_type:"agent" aliases with
           | Error msg -> Error msg
           | Ok pending_confirms_removed ->
             let heartbeats_stopped = Heartbeat.stop_by_agent ~agent_name in
             let workspace_unbind_result =
               Workspace.end_session ~stop_heartbeats:false config ~agent_name
             in
             let aliases_label = String.concat "," aliases in
             Log.Misc.info
               "[agent_purge] cleanup agent=%s aliases=%s pending_confirms_removed=%d heartbeats_stopped=%d workspace_unbind=%S"
               agent_name aliases_label pending_confirms_removed heartbeats_stopped
               workspace_unbind_result;
             aliases
             |> List.iter (fun alias ->
                  remove_path_if_exists ~context:"agent_purge"
                    (agent_file_path config alias);
                  remove_path_if_exists ~context:"agent_purge"
                    (Metrics_store_eio.agent_metrics_dir config alias);
                  Tool_shard.remove_agent_shards alias;
                  credential_aliases alias
                  |> List.iter (Auth.delete_credential config.base_path));
             Ok
               ({ agent_name
                ; pending_confirms_removed
                ; heartbeats_stopped
                ; workspace_unbind_result
                }
                :: results)))
       (Ok [])
  |> Result.map List.rev
;;

let purge_keeper_artifacts config requested_name
    ({ keeper_name; agent_name; trace_id; toml_path } : keeper_purge_target) =
  let keeper_dir = Keeper_fs.keeper_dir config in
  let keeper_runtime_dir = Filename.concat keeper_dir keeper_name in
  let cleanup_names =
    [ requested_name; keeper_name; agent_name ]
    |> List.filter_map String_util.trim_to_option
    |> Json_util.dedupe_keep_order
  in
  cleanup_names
  |> List.iter (fun name ->
       Keeper_keepalive.stop_keepalive ~base_path:config.base_path name);
  match
    Operator_pending_confirm.remove_pending_confirms_by_target
      config
      ~target_type:"keeper"
      ~target_id:(Some keeper_name)
  with
  | Error msg ->
    Error
      (Printf.sprintf
         "pending-confirm cleanup failed for keeper %s: %s"
         keeper_name
         msg)
  | Ok keeper_pending_confirms_removed ->
  Log.Misc.info
    "[keeper_purge] cleanup keeper=%s pending_confirms_removed=%d"
    keeper_name keeper_pending_confirms_removed;
  Keeper_registry.unregister ~base_path:config.base_path keeper_name;
  (match purge_agent_filesystem_artifacts config [ agent_name; keeper_name ] with
   | Error _ as err -> err
   | Ok agent_cleanup_results ->
  List.iter
    (remove_path_if_exists ~context:"keeper_purge")
    [
      Keeper_types_profile.keeper_meta_path config keeper_name;
      Keeper_types_support.keeper_metrics_path config keeper_name;
      Keeper_types_support.keeper_memory_bank_path config keeper_name;
      Keeper_types_support.keeper_generation_index_path config keeper_name;
      Keeper_types_support.keeper_policy_log_path config keeper_name;
      Keeper_types_support.keeper_decision_log_path config keeper_name;
      Keeper_types_support.keeper_feedback_log_path config keeper_name;
      Keeper_types_support.keeper_dataset_export_path config keeper_name;
    ];
  remove_path_if_exists ~context:"keeper_purge" keeper_runtime_dir;
  Option.iter
    (fun keeper_trace_id ->
       remove_path_if_exists ~context:"keeper_purge"
         (Keeper_types_support.keeper_session_dir config keeper_trace_id))
    trace_id;
  Option.iter (remove_path_if_exists ~context:"keeper_purge") toml_path;
  Ok { keeper_pending_confirms_removed; agent_cleanup_results })
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
             | Error err ->
                 respond_error ~status:`Not_found ~request:req reqd
                   (Goal_store.delete_goal_error_to_string err)
           with Yojson.Json_error _ ->
             respond_error ~request:req reqd (invalid_request "goal_id")
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/agents/purge" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "agent_name" json with
             | None ->
               respond_error ~request:req reqd (invalid_request "agent_name")
             | Some requested_name ->
               let config = (Mcp_server.workspace_config state) in
               (match resolve_keeper_purge_target config requested_name with
                | Some keeper_target ->
                  let toml_deleted = Option.is_some keeper_target.toml_path in
                  (match purge_keeper_artifacts config requested_name keeper_target with
                   | Error msg ->
                     respond_error
                       ~status:`Internal_server_error
                       ~request:req
                       reqd
                       msg
                   | Ok purge_result ->
                  Http.Response.json_value ~compress:true ~request:req
                    (`Assoc
                       [
                         ("ok", `Bool true);
                         ("target_kind", `String "keeper");
                         ("agent_name", `String keeper_target.agent_name);
                         ("keeper_name", `String keeper_target.keeper_name);
                         ("removed_keeper_toml", `Bool toml_deleted);
                         ( "keeper_pending_confirms_removed",
                           `Int purge_result.keeper_pending_confirms_removed );
                         ( "cleanup_results",
                           `List
                             (List.map agent_purge_cleanup_result_to_json
                                purge_result.agent_cleanup_results) );
                       ])
                    reqd)
                | None -> (
                  match resolve_plain_agent_target config requested_name with
                  | Some agent_name ->
                    (match
                       purge_agent_filesystem_artifacts config
                         [ requested_name; agent_name ]
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
                           ("target_kind", `String "agent");
                           ("agent_name", `String agent_name);
                           ( "cleanup_results",
                             `List
                               (List.map agent_purge_cleanup_result_to_json
                                  cleanup_results) );
                         ])
                      reqd)
                  | None ->
                    respond_error ~status:`Not_found ~request:req reqd
                      "agent or keeper not found"))
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
