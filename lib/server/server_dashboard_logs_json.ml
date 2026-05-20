(* Dashboard /logs endpoint JSON builder.

   Wraps a slice of [Log.Ring] entries with retention metadata,
   the applied query parameters, and cursor information (latest_seq /
   oldest_seq) so the dashboard can fetch deltas via [since_seq].

   Extracted from [Server_routes_http_routes_dashboard] (godfile decomp).
   Pure JSON builder over [Log.Ring.entry list] - the ring read happens
   in the caller. *)

let option_int_json = function
  | Some value -> `Int value
  | None -> `Null
;;

let option_string_json = function
  | Some value -> `String value
  | None -> `Null
;;

let store_path ~masc_root =
  Filename.concat
    (Filename.concat masc_root "logs")
    (Printf.sprintf
       "system_log_%s.jsonl"
       (Log.format_utc_date_of (Unix.gettimeofday ())))
;;

let build
      ~(config : Coord.config)
      ~limit
      ~level_filter
      ~min_level
      ~module_filter
      ~since_seq
      (entries : Log.Ring.entry list)
  : Yojson.Safe.t
  =
  let masc_root = Coord.masc_root_dir config in
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
             ; "coordination_root", `String masc_root
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
             ; ( "applied_level"
               , `String (Log.level_to_string (Log.level_of_string level_filter)) )
             ; "min_level", `Int min_level
             ; "module", `String module_filter
             ; "since_seq", option_int_json since_seq
             ] )
       ; "returned", `Int (List.length entries)
       ; "latest_seq", option_int_json (entry_seq_json newest)
       ; "oldest_seq", option_int_json (entry_seq_json oldest)
       ; "latest_ts_iso", option_string_json (entry_ts_json newest)
       ]
       @ fields)
  | json -> json
;;
