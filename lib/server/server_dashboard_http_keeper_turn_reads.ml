(* See server_dashboard_http_keeper_turn_reads.mli. *)

module Http = Http_server_eio
module Limits = Server_dashboard_http_keeper_read_limits
module Memory_reads = Server_dashboard_http_keeper_memory_reads

let keeper_turn_record_lookup_response ~config ~keeper_name req =
  let parameters =
    Uri.query (Uri.of_string req.Httpun.Request.target)
    |> List.filter (fun (name, _) -> String.equal name "turn_ref")
  in
  let error status code detail =
    Some (status, `Assoc [ "error", `String detail; "code", `String code ])
  in
  let lookup turn_ref =
    let reading =
      Eio_guard.with_named_switch "keeper-exact-turn-record" (fun () ->
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          let location =
            Dated_jsonl.Store.keeper (Workspace.dated_store_root config)
              ~keeper:keeper_name Dated_jsonl.Store.Keeper.Turn_records
          in
          let store = Dated_jsonl.open_store location in
          Server_keeper_turn_records.read_exact ~store ~keeper:keeper_name ~turn_ref))
    in
    match reading with
    | Error error_detail ->
        error `Service_unavailable "turn_record_unavailable"
          (Server_keeper_turn_records.exact_error_to_string error_detail)
    | Ok (None, _) ->
        error `Not_found "turn_record_not_found"
          "No turn record with this Turn_ref exists for this Keeper"
    | Ok (Some record, skipped_rows) ->
        Some
          (`OK,
           `Assoc
             [ "keeper", `String keeper_name
             ; "turn_ref", Ids.Turn_ref.to_yojson turn_ref
             ; "count", `Int 1
             ; "skipped_rows", `Int skipped_rows
             ; "source", `String "turn_record"
             ; "entries", `List
                 [ `Assoc
                     [ "record", Turn_record.to_json record
                     ; "diff_vs_prev", `Null
                     ] ]
             ])
  in
  match parameters with
  | [] -> None
  | [ _, [ value ] ] ->
      if not (Keeper_config.validate_name keeper_name) then
        error `Bad_request "invalid_keeper_name" "invalid keeper name"
      else
        (match Ids.Turn_ref.of_string value with
         | None -> error `Bad_request "invalid_turn_ref" "invalid Turn_ref"
         | Some turn_ref -> lookup turn_ref)
  | _ ->
      error `Bad_request "invalid_turn_ref"
        "turn_ref must occur exactly once with one valid value"
;;

let keeper_turn_transcript_lookup_response ~(config : Workspace.config) ~keeper_name req =
  let error status detail = status, `Assoc [ "error", `String detail ] in
  let parameters = Uri.query (Uri.of_string req.Httpun.Request.target)
      |> List.filter (fun (name, _) -> String.equal name "turn_ref") in
  if not (Keeper_config.validate_name keeper_name) then
    error `Bad_request "invalid keeper name"
  else match parameters with
  | [ _, [ value ] ] ->
      (match Ids.Turn_ref.of_string value with
       | None -> error `Bad_request "invalid Turn_ref"
       | Some turn_ref ->
           let reading = Eio_guard.with_named_switch "keeper-exact-turn-transcript" (fun () ->
             Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
               Keeper_chat_store.load_turn_transcript_result
                 ~base_dir:config.base_path ~keeper_name ~turn_ref)) in
           (match reading with
            | Error error_detail -> error `Service_unavailable
                (Keeper_chat_history_page.error_to_string error_detail)
            | Ok transcript -> `OK,
                Keeper_chat_store.turn_transcript_to_json ~keeper:keeper_name ~turn_ref transcript))
  | [] | _ :: _ -> error `Bad_request "turn_ref must occur exactly once with one valid value"
;;

let handle_records_get state req reqd name =
  (* RFC-0233 §2.3 PR-4: serve TurnRecords with server-side
     consecutive-pair block diffs so the dashboard stays a renderer
     of the tested OCaml diff (views derive; no view-side repair). *)
  if not (Keeper_config.validate_name name) then
    Http.Response.json_value ~status:`Bad_request
      (`Assoc
         [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
      reqd
  else
    match keeper_turn_record_lookup_response
            ~config:(Mcp_server.workspace_config state) ~keeper_name:name req with
    | Some (status, json) -> Http.Response.json_value ~status json reqd
    | None ->
    let limit =
      Server_utils.int_query_param req "limit" ~default:50
      |> max 1 |> min Limits.trajectory_max_limit
    in
    let config = (Mcp_server.workspace_config state) in
    let turn_record_freshness_slo_s =
      Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec
      |> float_of_int
      |> fun keepalive_interval_s ->
      Keeper_status_runtime.keeper_turn_record_freshness_slo_s
        ~keepalive_interval_s
    in
    let store = Keeper_types_support.keeper_turn_record_store config name in
    (match Server_keeper_turn_records.read ~store ~limit with
     | Error error ->
       Http.Response.json_value ~status:`Internal_server_error
         (`Assoc ["error", `String (Dated_jsonl.read_error_to_string error)]) reqd
     | Ok (records, skipped_rows) ->
    let block_json = Turn_record.prompt_block_to_json in
    let entries =
      Turn_record.entries_with_diffs records
      |> List.map (fun ((record : Turn_record.t), diff) ->
           let diff_vs_prev =
             match diff with
             | Some (d : Turn_record.block_diff) ->
               `Assoc
                 [ ("added", `List (List.map block_json d.added))
                 ; ("removed", `List (List.map block_json d.removed))
                 ; ( "changed"
                   , `List
                       (List.map
                          (fun (prev_b, next_b) ->
                            `Assoc
                              [ ("prev", block_json prev_b)
                              ; ("next", block_json next_b)
                              ])
                          d.changed) )
                 ]
             | None -> `Null
           in
           `Assoc
             [ ("record", Turn_record.to_json record)
             ; ("diff_vs_prev", diff_vs_prev)
             ])
    in
    let latest_ts =
      List.fold_left
        (fun acc (r : Turn_record.t) ->
          match acc with
          | Some existing when existing >= r.ts -> acc
          | _ -> Some r.ts)
        None records
    in
    let latest_age_s =
      match latest_ts with
      | Some ts -> Some (max 0.0 (Time_compat.now () -. ts))
      | None -> None
    in
    let live_turn =
      match Keeper_registry.get ~base_path:config.base_path name with
      | Some entry -> Keeper_composite_observer.live_turn_observation entry
      | None -> None
    in
    let health, stale_reason =
      Keeper_status_runtime.keeper_turn_record_source_health
        ~skipped_rows
        ~live_turn_in_progress:(Option.is_some live_turn)
        ~latest_age_s
        ~freshness_slo_s:turn_record_freshness_slo_s
    in
    (* The dashboard decoder (dashboard/src/api/dashboard-turn-records.ts)
       rejects a response whose key set is not exactly its allowlist, so a
       field added here and nowhere else turns the whole payload into null
       and the turn-records and Memory OS panels go blank. That happened
       twice (#26799, #28216) and both times ended in adding the missing key
       afterwards. *)
    let json = `Assoc [
      ("keeper", `String name);
      ("count", `Int (List.length records));
      ("skipped_rows", `Int skipped_rows);
      ("source", `String "turn_record");
      ("producer", `String "keeper_agent_run.run_turn|keeper_turn_record_writer");
      ( "durable_store",
        `String
          (Filename.concat
             (Workspace.masc_dir config)
             (Printf.sprintf "keepers/%s/turn-records" name)) );
      ("dashboard_surface", `String "/api/v1/keepers/:name/turn-records");
      ("freshness_slo_s", `Float turn_record_freshness_slo_s);
      ("live_turn_in_progress", `Bool (Option.is_some live_turn));
      ( "live_turn_started_at_unix",
        match live_turn with
        | Some observation -> `Float observation.started_at
        | None -> `Null );
      ( "live_turn_last_progress_at_unix",
        match live_turn with
        | Some observation -> `Float observation.last_progress_at
        | None -> `Null );
      ("latest_ts_unix", Json_util.float_opt_to_json latest_ts);
      ( "latest_ts_iso",
        match latest_ts with
        | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
        | None -> `Null );
      ("latest_age_s", Json_util.float_opt_to_json latest_age_s);
      ("health", `String health);
      ( "stale_reason",
        if stale_reason = "" then `Null else `String stale_reason );
      ( "memory_os"
      , Memory_reads.memory_os_dashboard_json
          ~config:(Mcp_server.workspace_config state)
          ~keeper_id:name );
      ("entries", `List entries);
    ] in
    Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_transcript_get state req reqd name =
  (* RFC-0233 §7: serve one keeper turn's operator request + keeper
     response by an exact join on the persisted chat row turn_ref
     ("<trace_id>#<absolute_turn>"). Lazily fetched by the turn
     inspector so the transcript (which can be large) never bloats the
     turn-records list. Content is the load-time redacted view the chat
     history endpoint already serves (RFC-0132); an unmatched turn_ref
     returns [found:false] rather than a fabricated transcript. *)
  if not (Keeper_config.validate_name name) then
    Http.Response.json_value ~status:`Bad_request
      (`Assoc
         [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
      reqd
  else
    let status, json = keeper_turn_transcript_lookup_response
        ~config:(Mcp_server.workspace_config state) ~keeper_name:name req in
    Http.Response.json_value ~status ~compress:true ~request:req json reqd
;;
