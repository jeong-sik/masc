(* Dashboard /logs endpoint JSON builder.

   Wraps a slice of [Log.Ring] entries with retention metadata,
   the applied query parameters, and cursor information (latest_seq /
   oldest_seq) so the dashboard can fetch deltas via [since_seq].

   Extracted from [Server_routes_http_routes_dashboard] (godfile decomp).
   Pure JSON builder over [Log.Ring.entry list] - the ring read happens
   in the caller. *)


let store_path ~masc_root =
  Filename.concat
    (Filename.concat masc_root "logs")
    (Printf.sprintf
       "system_log_%s.jsonl"
       (Log.format_utc_date_of (Unix.gettimeofday ())))
;;

let build
      ~(config : Workspace.config)
      ~limit
      ~level_filter
      ~applied_level
      ~min_level
      ~module_filter
      ~since_seq
      ~before_seq
      ~category_filter
      ~exclude_category
      (entries : Log.Ring.entry list)
  : Yojson.Safe.t
  =
  let masc_root = Workspace.masc_root_dir config in
  let newest =
    match entries with
    | [] -> None
    | entry :: _ -> Some entry
  in
  let oldest = List.fold_left (fun _ entry -> Some entry) None entries in
  let entry_seq_json = Option.map (fun (entry : Log.Ring.entry) -> entry.seq) in
  let entry_ts_json = Option.map (fun (entry : Log.Ring.entry) -> entry.ts) in
  match Log.Ring.to_json entries with
  | `Assoc fields ->
    `Assoc
      ([ "generated_at_iso", `String (Masc_domain.now_iso ())
       ; "dashboard_surface", `String "/api/v1/dashboard/logs"
       ; "source", `String "masc_log_ring"
       ; ( "retention"
         , `Assoc
             [ "scope", `String "dashboard_logs"
             ; "workspace_root", `String masc_root
             ; "buffer", `String "Log.Ring"
             ; "capacity", `Int Log.Ring.capacity
             ; "durable_store", `String (store_path ~masc_root)
             ; "file_pattern", `String "system_log_YYYY-MM-DD.jsonl"
             ; "keep_days", `Int 7
             ; ( "cache_policy"
               , `String
                   "uncached; reads in-memory ring backed by daily JSONL sink; \
                    delta cursor via since_seq" )
             ] )
       ; ( "query"
         , `Assoc
             [ "limit", `Int limit
             ; "level", `String level_filter
             ; "applied_level", `String (Log.level_to_string applied_level)
             ; "min_level", `Int min_level
             ; "module", `String module_filter
             ; "since_seq", Json_util.int_option_to_yojson since_seq
             ; "before_seq", Json_util.int_option_to_yojson before_seq
             ; "category", Json_util.string_opt_to_json category_filter
             ; ( "exclude_category"
               , match exclude_category with
                 | None -> `Null
                 | Some xs -> `List (List.map (fun x -> `String x) xs) )
             ] )
       ; "returned", `Int (List.length entries)
       ; "latest_seq", Json_util.int_option_to_yojson (entry_seq_json newest)
       ; "oldest_seq", Json_util.int_option_to_yojson (entry_seq_json oldest)
       ; "latest_ts_iso", Json_util.string_option_to_yojson (entry_ts_json newest)
       ]
       @ fields)
  | json -> json
;;
