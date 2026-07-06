(** Dashboard performance artifact projection extracted from runtime info. *)

open Dashboard_http_helpers

(* SSOT: Server_dashboard_http_runtime_info_json.take is the canonical implementation. *)
let take = Server_dashboard_http_runtime_info_json.take

let list_hd_opt = function
  | [] -> None
  | x :: _ -> Some x

;;

let path_descends_from ~root path =
  String.equal path root || String.starts_with ~prefix:(root ^ "/") path
;;

let path_relative_to ~root path =
  if String.equal path root
  then Some "."
  else if String.starts_with ~prefix:(root ^ "/") path
  then
    Some
      (String.sub
         path
         (String.length root + 1)
         (String.length path - String.length root - 1))
  else None
;;

type dashboard_perf_row =
  { benchmark : string
  ; avg_ms : int
  ; p50_ms : int
  ; p95_ms : int
  ; max_ms : int
  ; notes : string
  }

type dashboard_perf_compare_row =
  { benchmark : string
  ; avg_delta_ms : int
  ; avg_delta_pct : float option
  ; p95_delta_ms : int
  ; p95_delta_pct : float option
  ; max_delta_ms : int
  ; verdict : string
  }

let dashboard_perf_read_error_json ?line_index ~source ~path ~kind ~message () =
  let fields =
    [ "source", `String source
    ; "path", `String path
    ; "kind", `String kind
    ; "message", `String message
    ]
  in
  let fields =
    match line_index with
    | None -> fields
    | Some value -> fields @ [ "line_index", `Int value ]
  in
  `Assoc fields
;;

let path_exists_result path =
  try Ok (Sys.file_exists path) with
  | Sys_error message -> Error message
;;

let path_exists path =
  match path_exists_result path with
  | Ok value -> value
  | Error _ -> false
;;

let is_directory_result path =
  try Ok (Sys.is_directory path) with
  | Sys_error message -> Error message
;;

let is_directory path =
  match is_directory_result path with
  | Ok value -> value
  | Error _ -> false
;;

let existing_directory_candidate ~source path =
  match path_exists_result path with
  | Error message ->
    ( None
    , [ dashboard_perf_read_error_json
          ~source
          ~path
          ~kind:"path_exists_error"
          ~message
          ()
      ] )
  | Ok false -> None, []
  | Ok true ->
    (match is_directory_result path with
     | Ok true -> Some path, []
     | Ok false -> None, []
     | Error message ->
       ( None
       , [ dashboard_perf_read_error_json
             ~source
             ~path
             ~kind:"directory_probe_error"
             ~message
             ()
         ] ))
;;

let dedupe_strings values =
  List.fold_left
    (fun acc value -> if value = "" || List.mem value acc then acc else acc @ [ value ])
    []
    values
;;

let parse_benchmark_timestamp path =
  let base = Filename.basename path in
  let prefix = "results_" in
  let suffix = ".csv" in
  if String.length base <= String.length prefix + String.length suffix
  then None
  else if
    (not (String.starts_with ~prefix base)) || not (Filename.check_suffix base suffix)
  then None
  else
    Some
      (String.sub
         base
         (String.length prefix)
         (String.length base - String.length prefix - String.length suffix))
;;

let current_worktree_results_dir (config : Workspace.config) =
  let cwd = Sys.getcwd () in
  let worktrees_root = Filename.concat config.base_path ".worktrees" in
  if String.equal cwd worktrees_root
  then None
  else if path_descends_from ~root:worktrees_root cwd
  then (
    let rel =
      String.sub
        cwd
        (String.length worktrees_root + 1)
        (String.length cwd - String.length worktrees_root - 1)
    in
    let worktree_name =
      match String.index_opt rel '/' with
      | Some i -> String.sub rel 0 i
      | None -> rel
    in
    let workspace_root = Filename.concat worktrees_root worktree_name in
    Some (Filename.concat workspace_root "benchmarks/results"))
  else None
;;

let display_benchmark_path (config : Workspace.config) path =
  match path_relative_to ~root:config.base_path path with
  | Some relative -> relative
  | None -> Filename.basename path
;;

let benchmark_results_dir_candidates_with_read_errors (config : Workspace.config) =
  let env_dir =
    match Sys.getenv_opt "MASC_BENCHMARK_RESULTS_DIR" with
    | Some "" | None -> None
    | some -> some
  in
  let scoped_dirs =
    [ Option.value ~default:"" (current_worktree_results_dir config)
    ; Filename.concat config.base_path "benchmarks/results"
    ]
  in
  dedupe_strings
    (match String_util.trim_to_option (Option.value ~default:"" env_dir) with
     | Some dir -> [ dir ]
     | None -> scoped_dirs)
  |> List.fold_left
       (fun (dirs, read_errors) path ->
          let candidate, candidate_errors =
            existing_directory_candidate
              ~source:"dashboard_perf_candidate_dir"
              path
          in
          let dirs =
            match candidate with
            | None -> dirs
            | Some dir -> dirs @ [ dir ]
          in
          dirs, read_errors @ candidate_errors)
       ([], [])
;;

let benchmark_results_dir_candidates (config : Workspace.config) =
  let dirs, _read_errors =
    benchmark_results_dir_candidates_with_read_errors config
  in
  dirs
;;

let benchmark_result_files_with_read_errors results_dir =
  let entries =
    try Sys.readdir results_dir |> Array.to_list with
    | Sys_error message ->
      []
      , [ dashboard_perf_read_error_json
            ~source:"dashboard_perf_results_dir"
            ~path:results_dir
            ~kind:"directory_read_error"
            ~message
            ()
        ]
  in
  match entries with
  | [], (_ :: _ as read_errors) -> [], read_errors
  | entries, [] ->
    ( entries
      |> List.filter (fun name ->
        String.starts_with ~prefix:"results_" name && Filename.check_suffix name ".csv")
      |> List.map (Filename.concat results_dir)
      |> List.filter path_exists
    , [] )
;;

let benchmark_result_files results_dir =
  let files, _read_errors = benchmark_result_files_with_read_errors results_dir in
  files
;;

let latest_file_by_mtime_with_read_errors files =
  let stats, read_errors =
    List.fold_left
      (fun (stats, read_errors) path ->
         match
           try Ok (Unix.stat path) with
           | Unix.Unix_error (err, fn, arg) ->
             Error
               (Printf.sprintf "%s %s: %s" fn arg (Unix.error_message err))
           | Sys_error msg -> Error msg
         with
         | Ok stat -> (path, stat.Unix.st_mtime) :: stats, read_errors
         | Error message ->
           ( stats
           , read_errors
             @ [ dashboard_perf_read_error_json
                   ~source:"dashboard_perf_result_file"
                   ~path
                   ~kind:"stat_read_error"
                   ~message
                   ()
               ] ))
      ([], [])
      files
  in
  let latest =
    stats
    |> List.sort (fun (_, left) (_, right) -> Float.compare right left)
    |> List.map fst
    |> list_hd_opt
  in
  latest, read_errors
;;

let latest_file_by_mtime files =
  let latest, _read_errors = latest_file_by_mtime_with_read_errors files in
  latest
;;

let latest_benchmark_result_file_with_read_errors (config : Workspace.config) =
  let candidate_dirs, candidate_errors =
    benchmark_results_dir_candidates_with_read_errors config
  in
  let files, discovery_errors =
    candidate_dirs
    |> List.fold_left
         (fun (files, read_errors) results_dir ->
            let dir_files, dir_errors =
              benchmark_result_files_with_read_errors results_dir
            in
            files @ dir_files, read_errors @ dir_errors)
         ([], [])
  in
  let latest, stat_errors = latest_file_by_mtime_with_read_errors files in
  latest, candidate_errors @ discovery_errors @ stat_errors
;;

let latest_benchmark_result_file (config : Workspace.config) =
  let latest, _read_errors =
    latest_benchmark_result_file_with_read_errors config
  in
  latest
;;

let split_csv_row line =
  match String.split_on_char ',' line with
  | benchmark :: avg_ms :: p50_ms :: p95_ms :: max_ms :: notes ->
    Some
      (benchmark, avg_ms, p50_ms, p95_ms, max_ms, String.concat "," notes |> String.trim)
  | _ -> None
;;

let int_of_string_opt raw = int_of_string_opt (String.trim raw)

let load_benchmark_rows_with_read_errors path =
  let lines =
    try Fs_compat.load_file path |> String.split_on_char '\n' with
    | Sys_error message ->
      []
      , [ dashboard_perf_read_error_json
            ~source:"dashboard_perf_result_csv"
            ~path
            ~kind:"file_read_error"
            ~message
            ()
        ]
  in
  match lines with
  | [], (_ :: _ as read_errors) -> [], read_errors
  | lines, [] ->
    lines
    |> List.mapi (fun index line -> index + 1, String.trim line)
    |> List.fold_left
         (fun (rows, read_errors) (line_index, trimmed) ->
            if trimmed = "" || String.starts_with ~prefix:"benchmark," trimmed
            then rows, read_errors
            else
              match split_csv_row trimmed with
              | None ->
                ( rows
                , read_errors
                  @ [ dashboard_perf_read_error_json
                        ~source:"dashboard_perf_result_csv"
                        ~path
                        ~line_index
                        ~kind:"csv_row_parse_error"
                        ~message:"expected benchmark,avg_ms,p50_ms,p95_ms,max_ms,notes"
                        ()
                    ] )
              | Some (benchmark, avg_ms, p50_ms, p95_ms, max_ms, notes) ->
                (match
                   ( int_of_string_opt avg_ms
                   , int_of_string_opt p50_ms
                   , int_of_string_opt p95_ms
                   , int_of_string_opt max_ms )
                 with
                 | Some avg_ms, Some p50_ms, Some p95_ms, Some max_ms ->
                   ( { benchmark; avg_ms; p50_ms; p95_ms; max_ms; notes }
                     :: rows
                   , read_errors )
                 | _ ->
                   ( rows
                   , read_errors
                     @ [ dashboard_perf_read_error_json
                           ~source:"dashboard_perf_result_csv"
                           ~path
                           ~line_index
                           ~kind:"csv_number_parse_error"
                           ~message:"expected integer avg_ms/p50_ms/p95_ms/max_ms"
                           ()
                       ] )))
         ([], [])
    |> fun (rows, read_errors) -> List.rev rows, read_errors
;;

let load_benchmark_rows path =
  let rows, _read_errors = load_benchmark_rows_with_read_errors path in
  rows
;;

let load_benchmark_meta_with_read_errors path =
  if
    path_exists path
  then (
    try Some (Yojson.Safe.from_file path), [] with
    | Yojson.Json_error message ->
      ( None
      , [ dashboard_perf_read_error_json
            ~source:"dashboard_perf_meta_json"
            ~path
            ~kind:"json_parse_error"
            ~message
            ()
        ] )
    | Sys_error message ->
      ( None
      , [ dashboard_perf_read_error_json
            ~source:"dashboard_perf_meta_json"
            ~path
            ~kind:"file_read_error"
            ~message
            ()
        ] ))
  else None, []
;;

let load_benchmark_meta path =
  let meta, _read_errors = load_benchmark_meta_with_read_errors path in
  meta
;;

let note_tags_json notes =
  let tags =
    notes
    |> String.split_on_char ';'
    |> List.filter_map (fun token ->
      match String.split_on_char '=' token with
      | [ key; value ] ->
        let key = String.trim key in
        let value = String.trim value in
        if key = "" || value = "" then None else Some (key, `String value)
      | _ -> None)
  in
  `Assoc tags
;;

let dashboard_perf_row_json (row : dashboard_perf_row) =
  `Assoc
    [ "benchmark", `String row.benchmark
    ; "avg_ms", `Int row.avg_ms
    ; "p50_ms", `Int row.p50_ms
    ; "p95_ms", `Int row.p95_ms
    ; "max_ms", `Int row.max_ms
    ; "notes", `String row.notes
    ; "note_tags", note_tags_json row.notes
    ]
;;

let pct_delta ~baseline delta =
  if baseline = 0
  then None
  else Some (float_of_int delta /. float_of_int baseline *. 100.0)
;;

let compare_verdict ~avg_delta ~p95_delta =
  if
    ((avg_delta > 0 && p95_delta < 0) || (avg_delta < 0 && p95_delta > 0))
    && (abs avg_delta >= 50 || abs p95_delta >= 50)
  then "mixed"
  else if avg_delta >= 50 && p95_delta >= 0
  then "regressed"
  else if p95_delta >= 50 && avg_delta >= 0
  then "regressed"
  else if avg_delta <= -50 && p95_delta <= 0
  then "improved"
  else if p95_delta <= -50 && avg_delta <= 0
  then "improved"
  else "stable"
;;

let compare_rows ~baseline ~current =
  current
  |> List.filter_map (fun (row : dashboard_perf_row) ->
    match
      List.find_opt
        (fun (candidate : dashboard_perf_row) ->
           String.equal candidate.benchmark row.benchmark)
        baseline
    with
    | None -> None
    | Some base ->
      let avg_delta = row.avg_ms - base.avg_ms in
      let p95_delta = row.p95_ms - base.p95_ms in
      Some
        { benchmark = row.benchmark
        ; avg_delta_ms = avg_delta
        ; avg_delta_pct = pct_delta ~baseline:base.avg_ms avg_delta
        ; p95_delta_ms = p95_delta
        ; p95_delta_pct = pct_delta ~baseline:base.p95_ms p95_delta
        ; max_delta_ms = row.max_ms - base.max_ms
        ; verdict = compare_verdict ~avg_delta ~p95_delta
        })
  |> List.sort (fun left right ->
    compare
      (abs right.p95_delta_ms, abs right.avg_delta_ms)
      (abs left.p95_delta_ms, abs left.avg_delta_ms))
;;

let dashboard_perf_compare_row_json (row : dashboard_perf_compare_row) =
  `Assoc
    [ "benchmark", `String row.benchmark
    ; "avg_delta_ms", `Int row.avg_delta_ms
    ; ( "avg_delta_pct"
      , Option.fold ~none:`Null ~some:(fun value -> `Float value) row.avg_delta_pct )
    ; "p95_delta_ms", `Int row.p95_delta_ms
    ; ( "p95_delta_pct"
      , Option.fold ~none:`Null ~some:(fun value -> `Float value) row.p95_delta_pct )
    ; "max_delta_ms", `Int row.max_delta_ms
    ; "verdict", `String row.verdict
    ]
;;

let baseline_file_for_with_read_errors ~current_file ~meta =
  match meta with
  | Some json ->
    (match json_string_field_opt "compare_baseline_file" json with
     | Some path when path_exists path -> Some path, []
     | _ -> None, [])
  | None ->
    let results_dir = Filename.dirname current_file in
    let files, discovery_errors =
      benchmark_result_files_with_read_errors results_dir
    in
    let latest, stat_errors =
      files
      |> List.filter (fun path -> not (String.equal path current_file))
      |> latest_file_by_mtime_with_read_errors
    in
    latest, discovery_errors @ stat_errors
;;

let baseline_file_for ~current_file ~meta =
  let baseline_file, _read_errors =
    baseline_file_for_with_read_errors ~current_file ~meta
  in
  baseline_file
;;

let benchmark_source_json config ~results_dir ~result_file ~meta_file ~baseline_file =
  `Assoc
    [ "results_dir", `String (display_benchmark_path config results_dir)
    ; "result_file", `String (display_benchmark_path config result_file)
    ; ( "meta_file"
      , Option.fold
          ~none:`Null
          ~some:(fun path -> `String (display_benchmark_path config path))
          meta_file )
    ; ( "baseline_file"
      , Option.fold
          ~none:`Null
          ~some:(fun path -> `String (display_benchmark_path config path))
          baseline_file )
    ]
;;

let latest_run_json ~result_file ~meta rows =
  let timestamp = parse_benchmark_timestamp result_file in
  let started_at = Option.bind meta (json_string_field_opt "started_at") in
  let pattern = Option.bind meta (json_string_field_opt "pattern") in
  let iterations =
    Option.bind meta (fun json -> Safe_ops.json_int_opt "iterations" json)
  in
  let warmup_iterations =
    Option.bind meta (fun json -> Safe_ops.json_int_opt "warmup_iterations" json)
  in
  let session_warmup_iterations =
    Option.bind meta (fun json -> Safe_ops.json_int_opt "session_warmup_iterations" json)
  in
  `Assoc
    [ "timestamp", Option.fold ~none:`Null ~some:(fun value -> `String value) timestamp
    ; "started_at", Option.fold ~none:`Null ~some:(fun value -> `String value) started_at
    ; "pattern", Option.fold ~none:`Null ~some:(fun value -> `String value) pattern
    ; "iterations", Option.fold ~none:`Null ~some:(fun value -> `Int value) iterations
    ; ( "warmup_iterations"
      , Option.fold ~none:`Null ~some:(fun value -> `Int value) warmup_iterations )
    ; ( "session_warmup_iterations"
      , Option.fold ~none:`Null ~some:(fun value -> `Int value) session_warmup_iterations
      )
    ; "benchmark_count", `Int (List.length rows)
    ]
;;

let worst_live_mcp rows =
  rows
  |> List.filter (fun (row : dashboard_perf_row) ->
    String.starts_with ~prefix:"mcp_" row.benchmark
    && not (String.equal row.benchmark "mcp_session_init"))
  |> List.sort (fun left right -> compare right.p95_ms left.p95_ms)
  |> list_hd_opt
;;

let row_by_name rows name =
  List.find_opt (fun (row : dashboard_perf_row) -> String.equal row.benchmark name) rows
;;

let verdict_counts_json rows =
  let counts =
    rows
    |> List.fold_left
         (fun (improved, stable, mixed, regressed) (row : dashboard_perf_compare_row) ->
            match row.verdict with
            | "improved" -> improved + 1, stable, mixed, regressed
            | "mixed" -> improved, stable, mixed + 1, regressed
            | "regressed" -> improved, stable, mixed, regressed + 1
            | _ -> improved, stable + 1, mixed, regressed)
         (0, 0, 0, 0)
  in
  let improved, stable, mixed, regressed = counts in
  `Assoc
    [ "improved", `Int improved
    ; "stable", `Int stable
    ; "mixed", `Int mixed
    ; "regressed", `Int regressed
    ]
;;

let dashboard_perf_compute (config : Workspace.config) : Yojson.Safe.t =
  match latest_benchmark_result_file_with_read_errors config with
  | None, read_errors ->
    let status = if read_errors = [] then "empty" else "unknown" in
    `Assoc
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "status", `String status
      ; "read_error_count", `Int (List.length read_errors)
      ; "read_errors", `List read_errors
      ; "benchmarks", `List []
      ; "comparison", `Null
      ; ( "candidate_dirs"
        , `List
            (benchmark_results_dir_candidates config
             |> List.map (fun path -> `String (display_benchmark_path config path))) )
      ; "message", `String "No benchmark artifacts found"
      ]
  | Some result_file, discovery_errors ->
    let results_dir = Filename.dirname result_file in
    let rows, row_read_errors = load_benchmark_rows_with_read_errors result_file in
    let meta_file =
      let path = Filename.chop_suffix result_file ".csv" ^ ".meta.json" in
      if path_exists path then Some path else None
    in
    let meta, meta_read_errors =
      match meta_file with
      | None -> None, []
      | Some path -> load_benchmark_meta_with_read_errors path
    in
    let baseline_file, baseline_discovery_errors =
      baseline_file_for_with_read_errors ~current_file:result_file ~meta
    in
    let comparison_rows, baseline_read_errors =
      match baseline_file with
      | Some path ->
        let baseline_rows, read_errors =
          load_benchmark_rows_with_read_errors path
        in
        compare_rows ~baseline:baseline_rows ~current:rows, read_errors
      | None -> [], []
    in
    let read_errors =
      discovery_errors
      @ row_read_errors
      @ meta_read_errors
      @ baseline_discovery_errors
      @ baseline_read_errors
    in
    let status =
      match rows, read_errors with
      | [], _ :: _ -> "unknown"
      | _, _ :: _ -> "degraded"
      | _ -> "ok"
    in
    `Assoc
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "status", `String status
      ; "read_error_count", `Int (List.length read_errors)
      ; "read_errors", `List read_errors
      ; ( "source"
        , benchmark_source_json config ~results_dir ~result_file ~meta_file ~baseline_file
        )
      ; "latest_run", latest_run_json ~result_file ~meta rows
      ; ( "highlights"
        , `Assoc
            [ ( "session_init"
              , Option.fold
                  ~none:`Null
                  ~some:dashboard_perf_row_json
                  (row_by_name rows "mcp_session_init") )
            ; ( "worst_live_mcp"
              , Option.fold
                  ~none:`Null
                  ~some:dashboard_perf_row_json
                  (worst_live_mcp rows) )
            ; ( "runtime_status"
              , Option.fold
                  ~none:`Null
                  ~some:dashboard_perf_row_json
                  (row_by_name rows "oas_runtime_status") )
            ; ( "runtime_single"
              , Option.fold
                  ~none:`Null
                  ~some:dashboard_perf_row_json
                  (row_by_name rows "oas_runtime_single") )
            ] )
      ; "benchmarks", `List (List.map dashboard_perf_row_json rows)
      ; ( "comparison"
        , match baseline_file with
          | None -> `Null
          | Some path ->
            `Assoc
              [ "baseline_file", `String (display_benchmark_path config path)
              ; "verdict_counts", verdict_counts_json comparison_rows
              ; ( "top_changes"
                , `List
                    (comparison_rows |> take 8 |> List.map dashboard_perf_compare_row_json)
                )
              ] )
      ]
;;

(* /api/v1/dashboard/perf was running [dashboard_perf_compute] inline on
   the Eio main domain.  The compute walks [benchmark_results_dir_candidates]
   ([Sys.file_exists] + [Sys.is_directory] per candidate), then enumerates
   each results dir via [Sys.readdir], stats every match for mtime sort
   ([Unix.stat] × N), loads the latest CSV file ([Fs_compat.load_file]), and
   when a meta file is present parses it via [Yojson.Safe.from_file].  When a
   baseline file is available the CSV load runs again for the baseline.

   That whole I/O chain ran synchronously on the calling fiber's domain,
   so every concurrent dashboard request had to wait — same Eio cooperative
   scheduling violation that PR #18991 / #18993 / #18994 / #19007 / #19015
   addressed for the other dashboard endpoints.

   Same fix pattern: [Dashboard_cache.get_or_compute] keeps repeat hits on
   the fast path with stale-while-revalidate, and
   [Domain_pool_ref.submit_io_or_inline] runs the disk scan on a worker
   domain so the main HTTP domain keeps serving requests during refresh.

   TTL 30s: benchmark artifacts are generated by CI runs, not live data,
   so a 30s view of a CSV/JSON pair is plenty fresh; the cost of the scan
   is high enough that any sub-minute refresh is dominated by I/O. *)
let perf_cache_ttl_s = 30.0

let dashboard_perf_http_json (config : Workspace.config) : Yojson.Safe.t =
  let cache_key = Printf.sprintf "perf:%s" config.Workspace.base_path in
  Dashboard_cache.get_or_compute cache_key ~ttl:perf_cache_ttl_s (fun () ->
    Domain_pool_ref.submit_io_or_inline (fun () ->
      dashboard_perf_compute config))
;;
