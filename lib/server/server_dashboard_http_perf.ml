(** Dashboard performance artifact projection extracted from runtime info. *)

open Dashboard_http_helpers

let take n xs =
  let rec loop acc remaining xs =
    if remaining <= 0
    then List.rev acc
    else (
      match xs with
      | [] -> List.rev acc
      | x :: tl -> loop (x :: acc) (remaining - 1) tl)
  in
  loop [] n xs
;;

let list_hd_opt = function
  | [] -> None
  | x :: _ -> Some x
;;

let trim_to_option raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed
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

let current_worktree_results_dir (config : Coord.config) =
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
    let worktree_root = Filename.concat worktrees_root worktree_name in
    Some (Filename.concat worktree_root "benchmarks/results"))
  else None
;;

let display_benchmark_path (config : Coord.config) path =
  match path_relative_to ~root:config.base_path path with
  | Some relative -> relative
  | None -> Filename.basename path
;;

let benchmark_results_dir_candidates (config : Coord.config) =
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
    (match trim_to_option (Option.value ~default:"" env_dir) with
     | Some dir -> [ dir ]
     | None -> scoped_dirs)
  |> List.filter (fun path -> Sys.file_exists path && Sys.is_directory path)
;;

let benchmark_result_files results_dir =
  let entries =
    try Sys.readdir results_dir |> Array.to_list with
    | Sys_error _ -> []
  in
  entries
  |> List.filter (fun name ->
    String.starts_with ~prefix:"results_" name && Filename.check_suffix name ".csv")
  |> List.map (Filename.concat results_dir)
  |> List.filter (fun path -> Sys.file_exists path)
;;

let latest_file_by_mtime files =
  files
  |> List.filter_map (fun path ->
    try Some (path, (Unix.stat path).Unix.st_mtime) with
    | Unix.Unix_error _ | Sys_error _ -> None)
  |> List.sort (fun (_, left) (_, right) -> Float.compare right left)
  |> List.map fst
  |> list_hd_opt
;;

let latest_benchmark_result_file (config : Coord.config) =
  benchmark_results_dir_candidates config
  |> List.concat_map benchmark_result_files
  |> latest_file_by_mtime
;;

let split_csv_row line =
  match String.split_on_char ',' line with
  | benchmark :: avg_ms :: p50_ms :: p95_ms :: max_ms :: notes ->
    Some
      (benchmark, avg_ms, p50_ms, p95_ms, max_ms, String.concat "," notes |> String.trim)
  | _ -> None
;;

let int_of_string_opt raw = int_of_string_opt (String.trim raw)

let load_benchmark_rows path =
  let lines =
    try Fs_compat.load_file path |> String.split_on_char '\n' with
    | Sys_error _ -> []
  in
  lines
  |> List.filter_map (fun line ->
    let trimmed = String.trim line in
    if trimmed = "" || String.starts_with ~prefix:"benchmark," trimmed
    then None
    else (
      match split_csv_row trimmed with
      | Some (benchmark, avg_ms, p50_ms, p95_ms, max_ms, notes) ->
        (match
           ( int_of_string_opt avg_ms
           , int_of_string_opt p50_ms
           , int_of_string_opt p95_ms
           , int_of_string_opt max_ms )
         with
         | Some avg_ms, Some p50_ms, Some p95_ms, Some max_ms ->
           Some { benchmark; avg_ms; p50_ms; p95_ms; max_ms; notes }
         | _ -> None)
      | None -> None))
;;

let load_benchmark_meta path =
  if Sys.file_exists path
  then (
    try Some (Yojson.Safe.from_file path) with
    | Yojson.Json_error _ | Sys_error _ -> None)
  else None
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

let baseline_file_for ~current_file ~meta =
  match meta with
  | Some json ->
    (match json_string_field_opt "compare_baseline_file" json with
     | Some path when Sys.file_exists path -> Some path
     | _ -> None)
  | None ->
    let results_dir = Filename.dirname current_file in
    benchmark_result_files results_dir
    |> List.filter (fun path -> not (String.equal path current_file))
    |> latest_file_by_mtime
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

let dashboard_perf_http_json (config : Coord.config) : Yojson.Safe.t =
  match latest_benchmark_result_file config with
  | None ->
    `Assoc
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "status", `String "empty"
      ; "benchmarks", `List []
      ; "comparison", `Null
      ; ( "candidate_dirs"
        , `List
            (benchmark_results_dir_candidates config
             |> List.map (fun path -> `String (display_benchmark_path config path))) )
      ; "message", `String "No benchmark artifacts found"
      ]
  | Some result_file ->
    let results_dir = Filename.dirname result_file in
    let rows = load_benchmark_rows result_file in
    let meta_file =
      let path = Filename.chop_suffix result_file ".csv" ^ ".meta.json" in
      if Sys.file_exists path then Some path else None
    in
    let meta = Option.bind meta_file load_benchmark_meta in
    let baseline_file = baseline_file_for ~current_file:result_file ~meta in
    let comparison_rows =
      match baseline_file with
      | Some path ->
        let baseline_rows = load_benchmark_rows path in
        compare_rows ~baseline:baseline_rows ~current:rows
      | None -> []
    in
    `Assoc
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "status", `String "ok"
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
