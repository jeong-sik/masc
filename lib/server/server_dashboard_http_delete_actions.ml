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

let dedupe_keep_order items =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
      if Hashtbl.mem seen item
      then false
      else (
        Hashtbl.add seen item ();
        true))
    items
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
  |> dedupe_keep_order
;;

let agent_file_path config agent_name =
  Filename.concat (Coord.agents_dir config)
    (Coord.safe_filename agent_name ^ ".json")
;;

let resolve_keeper_purge_target config requested_name =
  let trimmed = String.trim requested_name in
  let candidates =
    [
      Some trimmed;
      Keeper_types.canonical_keeper_name_from_agent_name trimmed;
      Keeper_types.canonical_keeper_name trimmed;
    ]
    |> List.filter_map (function
         | Some value when value <> "" -> Some value
         | _ -> None)
    |> dedupe_keep_order
  in
  let rec loop = function
    | [] -> None
    | candidate :: rest -> (
      let candidate_meta_path = Keeper_types.keeper_meta_path config candidate in
      let candidate_toml_path = Config_dir_resolver.keeper_toml_path_opt candidate in
      match Keeper_types.read_meta_resolved config candidate with
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
              agent_name = Keeper_types.keeper_agent_name candidate;
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
              agent_name = Keeper_types.keeper_agent_name candidate;
              trace_id = None;
              toml_path = candidate_toml_path;
            })
        else loop rest)
  in
  loop candidates
;;

let plain_agent_candidate_names config requested_name =
  let trimmed = String.trim requested_name in
  let resolved = Coord.resolve_agent_name config trimmed in
  [ trimmed; resolved ]
  |> List.filter (fun value -> value <> "")
  |> dedupe_keep_order
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

let purge_agent_filesystem_artifacts config agent_names =
  agent_names
  |> dedupe_keep_order
  |> List.iter (fun agent_name ->
       ignore
         (Operator_pending_confirm.remove_pending_confirms_by_target config
            ~target_type:"agent" ~target_id:(Some agent_name));
       ignore (Heartbeat.stop_by_agent ~agent_name);
       ignore (Coord.leave config ~agent_name);
       remove_path_if_exists ~context:"agent_purge"
         (agent_file_path config agent_name);
       remove_path_if_exists ~context:"agent_purge"
         (Metrics_store_eio.agent_metrics_dir config agent_name);
       Tool_shard.remove_agent_shards agent_name;
       credential_aliases agent_name
       |> List.iter (Auth.delete_credential config.base_path))
;;

let purge_keeper_artifacts config requested_name
    ({ keeper_name; agent_name; trace_id; toml_path } : keeper_purge_target) =
  let keeper_dir = Keeper_types.keeper_dir config in
  let keeper_runtime_dir = Filename.concat keeper_dir keeper_name in
  let cleanup_names =
    [ requested_name; keeper_name; agent_name ]
    |> List.filter (fun value -> String.trim value <> "")
    |> dedupe_keep_order
  in
  cleanup_names
  |> List.iter (fun name ->
       Keeper_keepalive.stop_keepalive ~base_path:config.base_path name);
  ignore
    (Operator_pending_confirm.remove_pending_confirms_by_target config
       ~target_type:"keeper" ~target_id:(Some keeper_name));
  Keeper_registry.unregister ~base_path:config.base_path keeper_name;
  purge_agent_filesystem_artifacts config [ agent_name; keeper_name ];
  List.iter
    (remove_path_if_exists ~context:"keeper_purge")
    [
      Keeper_types.keeper_meta_path config keeper_name;
      Keeper_types.keeper_metrics_path config keeper_name;
      Keeper_types.keeper_memory_bank_path config keeper_name;
      Keeper_types.keeper_generation_index_path config keeper_name;
      Keeper_types.keeper_policy_log_path config keeper_name;
      Keeper_types.keeper_decision_log_path config keeper_name;
      Keeper_types.keeper_feedback_log_path config keeper_name;
      Keeper_types.keeper_dataset_export_path config keeper_name;
    ];
  remove_path_if_exists ~context:"keeper_purge" keeper_runtime_dir;
  Option.iter
    (fun keeper_trace_id ->
       remove_path_if_exists ~context:"keeper_purge"
         (Keeper_types.keeper_session_dir config keeper_trace_id))
    trace_id;
  Option.iter (remove_path_if_exists ~context:"keeper_purge") toml_path
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
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"post_id\":\"...\"}"}|} reqd
             | Some post_id ->
             match Board_dispatch.delete_post ~post_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error err ->
                 Http.Response.json ~status:`Not_found ~request:req
                   (Printf.sprintf {|{"ok":false,"error":"%s"}|}
                      (String.escaped (Board_types.show_board_error err)))
                   reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"post_id\":\"...\"}"}|} reqd
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
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"task_id\":\"...\"}"}|} reqd
             | Some task_id ->
             let config = state.Mcp_server.room_config in
             match Task_dispatch.delete_task config ~task_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error err ->
                 Http.Response.json ~status:`Not_found ~request:req
                   (Printf.sprintf {|{"ok":false,"error":"task delete failed: %s"}|}
                      (String.escaped (Masc_domain.masc_error_to_string err)))
                   reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"task_id\":\"...\"}"}|} reqd
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
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"goal_id\":\"...\"}"}|} reqd
             | Some goal_id ->
             let config = state.Mcp_server.room_config in
             match Goal_store.delete_goal config ~goal_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error msg ->
                 Http.Response.json ~status:`Not_found ~request:req
                   (Printf.sprintf {|{"ok":false,"error":"%s"}|} (String.escaped msg))
                   reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"goal_id\":\"...\"}"}|} reqd
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
               Http.Response.json ~status:`Bad_request ~request:req
                 {|{"ok":false,"error":"invalid request: requires {\"agent_name\":\"...\"}"}|}
                 reqd
             | Some requested_name ->
               let config = state.Mcp_server.room_config in
               (match resolve_keeper_purge_target config requested_name with
                | Some keeper_target ->
                  let toml_deleted = Option.is_some keeper_target.toml_path in
                  purge_keeper_artifacts config requested_name keeper_target;
                  Http.Response.json ~compress:true ~request:req
                    (Yojson.Safe.to_string
                       (`Assoc
                          [
                            ("ok", `Bool true);
                            ("target_kind", `String "keeper");
                            ("agent_name", `String keeper_target.agent_name);
                            ("keeper_name", `String keeper_target.keeper_name);
                            ("removed_keeper_toml", `Bool toml_deleted);
                          ]))
                    reqd
                | None -> (
                  match resolve_plain_agent_target config requested_name with
                  | Some agent_name ->
                    purge_agent_filesystem_artifacts config [ requested_name; agent_name ];
                    Http.Response.json ~compress:true ~request:req
                      (Yojson.Safe.to_string
                         (`Assoc
                            [
                              ("ok", `Bool true);
                              ("target_kind", `String "agent");
                              ("agent_name", `String agent_name);
                            ]))
                      reqd
                  | None ->
                    Http.Response.json ~status:`Not_found ~request:req
                      {|{"ok":false,"error":"agent or keeper not found"}|}
                      reqd))
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"agent_name\":\"...\"}"}|}
               reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/goals/sweep" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name _req reqd ->
         let config = state.Mcp_server.room_config in
         let result = Goal_janitor.run config in
         Http.Response.json ~compress:true ~request
           (Yojson.Safe.to_string
              (`Assoc [("ok", `Bool true);
                       ("result", Goal_janitor.sweep_result_to_yojson result)]))
           reqd
       ) request reqd)

  (* ── Board moderation routes (Phase 2) ───────────────────────────── *)

  |> Http.Router.post "/api/v1/dashboard/board/moderation/flag" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name req reqd ->
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
                  Http.Response.json ~status:`Bad_request ~request:req
                    {|{"ok":false,"error":"invalid request: requires {\"target_id\":\"...\"}"}|} reqd
              | Some target_id ->
                  let reporter =
                    Safe_ops.json_string_opt "reporter" json
                    |> Option.value ~default:"operator"
                  in
                  (match Board_moderation.flag ~target_kind ~target_id ~reporter ~reason with
                   | Error msg ->
                       Http.Response.json ~status:`Conflict ~request:req
                         (Yojson.Safe.to_string
                            (`Assoc [("ok", `Bool false); ("error", `String msg)]))
                         reqd
                   | Ok entry ->
                       Http.Response.json ~compress:true ~request:req
                         (Yojson.Safe.to_string
                            (`Assoc [("ok", `Bool true);
                                     ("entry", Board_moderation.queue_entry_to_json entry)]))
                         reqd))
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid JSON body"}|} reqd
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
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
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
                  Http.Response.json ~status:`Bad_request ~request:req
                    (Yojson.Safe.to_string
                       (`Assoc [("ok", `Bool false);
                                ("error",
                                 `String ("unknown action: " ^ action_str ^
                                          "; valid: approve, remove, hide, warn"))]))
                    reqd
              | Some action ->
                  (match Safe_ops.json_string_opt "target_id" json with
                   | None ->
                       Http.Response.json ~status:`Bad_request ~request:req
                         {|{"ok":false,"error":"invalid request: requires {\"target_id\":\"...\"}"}|} reqd
                   | Some target_id ->
                       let reason =
                         Option.bind
                           (Safe_ops.json_string_opt "reason" json)
                           Board_moderation.flag_reason_of_string
                       in
                       let note = Safe_ops.json_string_opt "note" json in
                       let actor =
                         match Safe_ops.json_string_opt "actor" json with
                         | Some a when String.trim a <> "" -> a
                         | _ -> agent_name
                       in
                       (match Board_moderation.record_action ~target_kind ~target_id
                                ~actor ~action ?reason ?note () with
                        | Error msg ->
                            Http.Response.json ~status:`Internal_server_error ~request:req
                              (Yojson.Safe.to_string
                                 (`Assoc [("ok", `Bool false); ("error", `String msg)]))
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
                                          Some (Board_types.show_board_error e))
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
                            Http.Response.json ~compress:true ~request:req
                              (Yojson.Safe.to_string
                                 (`Assoc ([("ok",    `Bool true);
                                           ("entry", Board_moderation.audit_entry_to_json entry)]
                                          @ extra)))
                              reqd)))
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid JSON body"}|} reqd
         )
       ) request reqd)
