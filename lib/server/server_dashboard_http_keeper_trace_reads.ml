(* See server_dashboard_http_keeper_trace_reads.mli. *)

module Http = Http_server_eio
module Api_post = Server_dashboard_http_keeper_api_post
module Limits = Server_dashboard_http_keeper_read_limits

let handle_raw_traces_get state req reqd name =
  (* The turn record already carries a raw_trace_run_ref naming this file;
     until now nothing served it, so the pointer reached the dashboard type
     and the content had no route. Listing is separate from reading because a
     turn file runs to hundreds of records and an operator picks one first. *)
  let limit =
    Server_utils.int_query_param req "limit" ~default:25 |> max 1 |> min 200
  in
  (match Keeper_raw_trace_reader.list_turns
           ~config:(Mcp_server.workspace_config state)
           ~keeper:name
           ~limit
   with
   | Error error ->
     Http.Response.json_value ~status:`Bad_request
       (`Assoc
          [ "error", `String (Keeper_raw_trace_reader.read_error_to_string error) ])
       reqd
   | Ok turns ->
     Http.Response.json_value ~compress:true ~request:req
       (`Assoc
          [ "keeper", `String name
          ; "count", `Int (List.length turns)
          ; ( "turns"
            , `List (List.map Keeper_raw_trace_reader.turn_summary_to_json turns) )
          ; "dashboard_surface", `String "/api/v1/keepers/:name/raw-traces"
          ])
       reqd)
;;

let handle_raw_trace_get state req reqd name =
  (* One turn's records. [file] is a handle from the listing, never a path;
     the reader rejects anything that could leave the keeper's directory
     rather than normalizing it. *)
  let offset = Server_utils.int_query_param req "offset" ~default:0 |> max 0 in
  let limit =
    Server_utils.int_query_param req "limit" ~default:200 |> max 1 |> min 2000
  in
  (* A missing [file] is a caller that named no turn. Defaulting it to the
     empty string would route that request into the reader's file-name
     validation and report it as an invalid name, which describes a different
     mistake than the one made. *)
  (match Server_utils.query_param req "file" with
   | None ->
     Http.Response.json_value ~status:`Bad_request
       (`Assoc [ "error", `String "file is required; list turns at /raw-traces" ])
       reqd
   | Some file ->
     (match Keeper_raw_trace_reader.read_turn
              ~config:(Mcp_server.workspace_config state)
              ~keeper:name
              ~file
              ~offset
              ~limit
      with
   | Error (Keeper_raw_trace_reader.No_such_turn _ as error) ->
     Http.Response.json_value ~status:`Not_found
       (`Assoc
          [ "error", `String (Keeper_raw_trace_reader.read_error_to_string error) ])
       reqd
   | Error
       ((Keeper_raw_trace_reader.Unknown_keeper _
        | Keeper_raw_trace_reader.Invalid_file_name _
        | Keeper_raw_trace_reader.Invalid_trace_record _
        | Keeper_raw_trace_reader.Read_failed _) as error) ->
     Http.Response.json_value ~status:`Bad_request
       (`Assoc
          [ "error", `String (Keeper_raw_trace_reader.read_error_to_string error) ])
       reqd
   | Ok records ->
     Http.Response.json_value ~compress:true ~request:req
       (match Keeper_raw_trace_reader.turn_records_to_json records with
        | `Assoc fields ->
          `Assoc
            (("keeper", `String name)
             :: ("dashboard_surface", `String "/api/v1/keepers/:name/raw-trace")
             :: fields)
        | json -> json)
       reqd))
;;

let handle_trajectory_get state req reqd name =
  if not (Keeper_config.validate_name name) then
    Http.Response.json_value ~status:`Bad_request
      (`Assoc
         [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
      reqd
  else
    let config = (Mcp_server.workspace_config state) in
    (match Keeper_meta_store.read_meta config name with
     | Error e ->
       Api_post.respond_error ~status:`Internal_server_error reqd e
     | Ok None ->
       Api_post.respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
     | Ok (Some m) ->
       let trajectory_default_limit = 50 in
       let trace_id =
         Keeper_id.Trace_id.to_string m.runtime.trace_id
       in
       let limit =
         Server_utils.int_query_param req "limit"
           ~default:trajectory_default_limit
         |> max 1 |> min Limits.trajectory_max_limit
       in
       (* Allow caller to request more result text up to a safe max.
          Default 2000 chars is enough for the collapsed list view;
          set result_max_len=10000 (or higher, capped at 10000) to
          get full detail for an expanded entry. *)
       let result_max_len =
         Server_utils.int_query_param req "result_max_len"
           ~default:2000
         |> max 0 |> min 10000
       in
       let include_thinking =
         Server_utils.bool_query_param req "include_thinking"
           ~default:false
       in
       let tail_scan_lines =
         let multiplier = if include_thinking then 3 else 8 in
         max 500 (min 5000 (limit * multiplier))
       in
       let cache_key =
         Printf.sprintf
           "keeper:trajectory:%s:%s:%s:%d:%d:%b:%d"
           (Workspace.masc_dir config)
           name
           trace_id
           limit
           result_max_len
           include_thinking
           tail_scan_lines
       in
       let payload =
         Dashboard_cache.get_or_compute_payload cache_key ~ttl:Limits.keeper_hot_path_cache_ttl_s (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
           let masc_root = Workspace.masc_dir config in
           let trajectory_lines =
             Trajectory.read_recent_lines ~masc_root ~keeper_name:m.name
               ~trace_id ~max_lines:tail_scan_lines
           in
           (* Reasoning evidence comes only from the metadata-only
              trajectory producer. Internal assistant history is never
              reclassified into this surface. *)
           let lines =
             if include_thinking then trajectory_lines
             else List.filter (function
               | Trajectory.Tool_call _ -> true
               | Trajectory.Withheld_thinking _ -> false) trajectory_lines
           in
           let total = List.length lines in
           let recent =
             if total <= limit then lines
             else
               let drop = total - limit in
               List.filteri (fun i _e -> i >= drop) lines
           in
           `Assoc [
             ("keeper", `String name);
             ("trace_id", `String trace_id);
             ("total_entries", `Int total);
             ("showing", `Int (List.length recent));
             ("entries", `List (List.map
               (Trajectory.trajectory_line_to_json ~result_max_len) recent));
           ]))
       in
       Server_cached_read_http.respond ~request:req reqd payload)
;;
