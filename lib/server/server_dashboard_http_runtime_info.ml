(** Runtime-resolution and dashboard tools projections extracted from the
    dashboard HTTP facade. *)

open Dashboard_http_helpers

let contains_substring ~needle haystack =
  String_util.contains_substring haystack needle

let take n xs =
  let rec loop acc remaining xs =
    if remaining <= 0 then List.rev acc
    else
      match xs with
      | [] -> List.rev acc
      | x :: tl -> loop (x :: acc) (remaining - 1) tl
  in
  loop [] n xs

let trim_to_option raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed

let list_hd_opt = function
  | [] -> None
  | x :: _ -> Some x

type dashboard_runtime_probe_cache_entry = {
  probe : Yojson.Safe.t;
  refreshed_at : float;
}

let dashboard_runtime_probe_cache : dashboard_runtime_probe_cache_entry option Atomic.t =
  Atomic.make None

let dashboard_runtime_probe_cache_ttl_sec = 30.0
let dashboard_runtime_probe_force_min_refresh_sec = 10.0
let dashboard_runtime_probe_timeout_sec = 15
let dashboard_runtime_probe_refresh_in_flight = Atomic.make false
let dashboard_runtime_probe_runner_hook : (unit -> Yojson.Safe.t) option Atomic.t =
  Atomic.make None

let set_dashboard_runtime_probe_runner_for_tests hook =
  Atomic.set dashboard_runtime_probe_runner_hook (Some hook)

let clear_dashboard_runtime_probe_runner_for_tests () =
  Atomic.set dashboard_runtime_probe_runner_hook None

let clear_dashboard_runtime_probe_cache_for_tests () =
  Atomic.set dashboard_runtime_probe_cache None;
  Atomic.set dashboard_runtime_probe_refresh_in_flight false

let path_descends_from ~root path =
  String.equal path root || String.starts_with ~prefix:(root ^ "/") path

let path_relative_to ~root path =
  if String.equal path root then Some "."
  else if String.starts_with ~prefix:(root ^ "/") path then
    Some (String.sub path (String.length root + 1) (String.length path - String.length root - 1))
  else None

(* Per-path TTL cache for `git rev-parse --short HEAD`.  Each miss forks
   git and can take seconds on large worktrees (~/me etc.), yet HEAD
   changes infrequently, and every dashboard shell refresh calls this
   twice (workspace + base).  Serving cached values keeps snapshot_json
   off the 5 s git-probe budget on the hot path. *)
let git_rev_parse_short_ttl_sec = 60.0

let git_rev_parse_short_cache :
    (string, string option * float) Hashtbl.t =
  Hashtbl.create 4

let git_rev_parse_short_in_flight : (string, unit) Hashtbl.t =
  Hashtbl.create 4

let git_rev_parse_short_mu = Stdlib.Mutex.create ()

let git_rev_parse_short_probe_hook_for_tests :
    (string -> string option) option Atomic.t =
  Atomic.make None

let set_git_rev_parse_short_probe_hook_for_tests hook =
  Atomic.set git_rev_parse_short_probe_hook_for_tests (Some hook)

let clear_git_rev_parse_short_probe_hook_for_tests () =
  Atomic.set git_rev_parse_short_probe_hook_for_tests None

let git_rev_parse_short_cached_lookup dir ~now =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () ->
      match Hashtbl.find_opt git_rev_parse_short_cache dir with
      | Some (value, ts) when now -. ts <= git_rev_parse_short_ttl_sec ->
          Some value
      | _ -> None)

let git_rev_parse_short_cached_any dir =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () ->
      Hashtbl.find_opt git_rev_parse_short_cache dir
      |> Option.map fst)

let git_rev_parse_short_try_begin_refresh dir =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () ->
      if Hashtbl.mem git_rev_parse_short_in_flight dir then false
      else begin
        Hashtbl.replace git_rev_parse_short_in_flight dir ();
        true
      end)

let git_rev_parse_short_finish_refresh dir value ~now =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () ->
      Hashtbl.replace git_rev_parse_short_cache dir (value, now);
      Hashtbl.remove git_rev_parse_short_in_flight dir)

let git_rev_parse_short_cancel_refresh dir =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () -> Hashtbl.remove git_rev_parse_short_in_flight dir)

let git_rev_parse_short_probe_argv dir =
  [ "git"; "-C"; dir; "--no-optional-locks"; "rev-parse"; "--short"; "HEAD" ]

(* Bumped 5s → 15s for large repos (#9765, #9775).
   `~/me` repeatedly trips the 5s budget on first probe after TTL
   expiry (3 occurrences in issue #9775 logs at 18:29/18:41/18:50).
   The probe runs on a background fiber via
   [maybe_refresh_git_rev_parse_short_in_background], so the extra
   wall-time does not affect the hot dashboard path — cached values
   keep serving during the refresh. Matches the sibling
   [dashboard_runtime_probe_timeout_sec = 15] at the top of this module. *)
let git_rev_parse_short_probe_timeout_sec = 15.0

let git_rev_parse_short_probe dir =
  match Atomic.get git_rev_parse_short_probe_hook_for_tests with
  | Some hook -> hook dir
  | None ->
      let argv = git_rev_parse_short_probe_argv dir in
      let raw_source = String.concat " " (List.map Filename.quote argv) in
      match
        Masc_exec.Exec_gate.run_argv_with_status
          ~actor:"system/runtime_info"
          ~raw_source
          ~summary:"dashboard runtime git probe"
          ~timeout_sec:git_rev_parse_short_probe_timeout_sec
          argv
      with
      | Unix.WEXITED 0, output -> trim_to_option output
      | _ -> None

let git_rev_parse_short_refresh dir =
  try
    let value = git_rev_parse_short_probe dir in
    git_rev_parse_short_finish_refresh dir value ~now:(Time_compat.now ());
    value
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      git_rev_parse_short_cancel_refresh dir;
      raise exn

let maybe_refresh_git_rev_parse_short_in_background dir =
  match Eio_context.get_switch_opt () with
  | None -> ()
  | Some sw ->
      if git_rev_parse_short_try_begin_refresh dir then
        Eio.Fiber.fork ~sw (fun () ->
          try let _ = git_rev_parse_short_refresh dir in () with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              Log.Dashboard.warn
                "dashboard runtime git probe refresh failed for %s: %s"
                dir (Printexc.to_string exn))

let git_rev_parse_short path =
  match trim_to_option path with
  | None -> None
  | Some dir when not (Sys.file_exists dir) -> None
  | Some dir ->
      let now = Time_compat.now () in
      (match git_rev_parse_short_cached_lookup dir ~now with
       | Some value -> value
       | None -> (
           match git_rev_parse_short_cached_any dir with
           | Some stale ->
               maybe_refresh_git_rev_parse_short_in_background dir;
               stale
           | None ->
               if git_rev_parse_short_try_begin_refresh dir then
                 git_rev_parse_short_refresh dir
               else
                 git_rev_parse_short_cached_any dir |> Option.value ~default:None))

let clear_git_rev_parse_short_cache_for_tests () =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () ->
      Hashtbl.clear git_rev_parse_short_cache;
      Hashtbl.clear git_rev_parse_short_in_flight)

let seed_git_rev_parse_short_cache_for_tests dir value ~refreshed_at =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () ->
      Hashtbl.replace git_rev_parse_short_cache dir (value, refreshed_at);
      Hashtbl.remove git_rev_parse_short_in_flight dir)

let path_item_json ~source path =
  `Assoc
    [
      ("path", `String path);
      ("exists", `Bool (String.trim path <> "" && Sys.file_exists path));
      ("source", `String source);
    ]

let shutdown_signal_of_message message =
  if contains_substring ~needle:"Received SIGTERM" message then Some "SIGTERM"
  else if contains_substring ~needle:"Received SIGINT" message then Some "SIGINT"
  else None

let runtime_diagnostics_json () =
  let entries = Log.Ring.recent ~limit:200 ~order:`Newest_first () in
  let diagnostics =
    entries
    |> List.filter_map (fun (entry : Log.Ring.entry) ->
           let message = entry.message in
           match shutdown_signal_of_message message with
           | Some signal ->
               Some
                 (`Assoc
                   [
                     ("ts", `String entry.ts);
                     ("kind", `String "external_signal");
                     ("signal", `String signal);
                     ("message", `String message);
                   ])
           | None when contains_substring
                           ~needle:"repairing state and rewriting canonical JSON"
                           message ->
               Some
                 (`Assoc
                   [
                     ("ts", `String entry.ts);
                     ("kind", `String "state_repair");
                     ("message", `String message);
                   ])
           | None when contains_substring ~needle:"invalid agent JSON" message
                       || contains_substring ~needle:"repaired agent JSON" message
                       || contains_substring
                            ~needle:"parse error: Types_core.agent.last_seen"
                            message ->
               Some
                 (`Assoc
                   [
                     ("ts", `String entry.ts);
                     ("kind", `String "agent_state");
                     ("message", `String message);
                   ])
           | None -> None)
    |> take 8
  in
  let count kind =
    List.fold_left
      (fun acc json ->
        match Yojson.Safe.Util.member "kind" json with
        | `String value when String.equal value kind -> acc + 1
        | _ -> acc)
      0 diagnostics
  in
  ( `List diagnostics,
    count "external_signal",
    count "state_repair",
    count "agent_state" )

let run_dashboard_runtime_probe () =
  match Atomic.get dashboard_runtime_probe_runner_hook with
  | Some hook -> hook ()
  | None ->
      Tool_local_runtime.runtime_ollama_probe_json ~probe_runs:2 ~max_tokens:8
        ~timeout_sec:dashboard_runtime_probe_timeout_sec ~ps_timeout_sec:2
        ~generate_when_unloaded:false ~run_generate:false ()

let dashboard_runtime_probe_cached_value () =
  match Atomic.get dashboard_runtime_probe_cache with
  | Some entry -> Some (entry.probe, entry.refreshed_at)
  | None -> None

let dashboard_runtime_probe_fresh_value ~now =
  match dashboard_runtime_probe_cached_value () with
  | Some (probe, refreshed_at)
    when now -. refreshed_at <= dashboard_runtime_probe_cache_ttl_sec ->
      Some (probe, refreshed_at)
  | _ -> None

let dashboard_runtime_probe_recent_value ~now =
  match dashboard_runtime_probe_cached_value () with
  | Some (probe, refreshed_at)
    when now -. refreshed_at <= dashboard_runtime_probe_force_min_refresh_sec ->
      Some (probe, refreshed_at)
  | _ -> None

let dashboard_runtime_probe_http_json ?(force = false) () =
  let now = Time_compat.now () in
  let probe, cache_hit, refreshed_at =
    match
      if force then dashboard_runtime_probe_recent_value ~now
      else dashboard_runtime_probe_fresh_value ~now
    with
    | Some (cached, cached_at) -> (cached, true, cached_at)
    | None ->
        if
          Atomic.compare_and_set dashboard_runtime_probe_refresh_in_flight false
            true
        then
          (* Run the Eio-yielding probe outside any Stdlib mutex/Fun.protect
             scope.  The CAS guard above serialises refreshes; the [match]
             below ensures the in-flight flag is always cleared even when
             the probe raises or is cancelled (Atomic.set never yields). *)
          match run_dashboard_runtime_probe () with
          | fresh ->
              let refreshed_at = Time_compat.now () in
              Atomic.set dashboard_runtime_probe_cache
                (Some { probe = fresh; refreshed_at });
              Atomic.set dashboard_runtime_probe_refresh_in_flight false;
              (fresh, false, refreshed_at)
          | exception exn ->
              let bt = Printexc.get_raw_backtrace () in
              Atomic.set dashboard_runtime_probe_refresh_in_flight false;
              Printexc.raise_with_backtrace exn bt
        else
          let fallback_now = Time_compat.now () in
          match
            if not force then dashboard_runtime_probe_fresh_value ~now:fallback_now
            else None
          with
          | Some (cached, cached_at) -> (cached, true, cached_at)
          | None -> (
              match dashboard_runtime_probe_cached_value () with
              | Some (cached, cached_at) -> (cached, false, cached_at)
              | None -> (`Null, false, 0.0))
  in
  let response_now = Time_compat.now () in
  let refreshed_at_json, cache_age_json =
    if refreshed_at > 0.0 then
      (`Float refreshed_at, `Float (max 0.0 (response_now -. refreshed_at)))
    else
      (`Null, `Null)
  in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("refreshed_at_unix", refreshed_at_json);
      ("cache_ttl_sec", `Float dashboard_runtime_probe_cache_ttl_sec);
      ("cache_age_sec", cache_age_json);
      ("cache_hit", `Bool cache_hit);
      ("probe", probe);
    ]
let runtime_resolution_json (config : Coord.config) =
  let build = Build_identity.current () in
  let runtime_commit = build.commit in
  let workspace_commit = git_rev_parse_short config.workspace_path in
  let resolved_base_commit = git_rev_parse_short config.base_path in
  let base_path_input =
    Env_config_core.base_path_raw_opt ()
    |> Option.value ~default:config.workspace_path
  in
  let prompt_markdown_dir =
    Prompt_registry.get_markdown_dir () |> Option.value ~default:""
  in
  let expected_prompt_dir = Config_dir_resolver.prompts_dir () in
  let prompt_dir_mismatch =
    prompt_markdown_dir <> ""
    && not (String.equal prompt_markdown_dir expected_prompt_dir)
  in
  let source_mismatch =
    match runtime_commit, workspace_commit with
    | Some runtime, Some workspace -> not (String.equal runtime workspace)
    | _ -> false
  in
  let diagnostics, signal_count, repair_count, agent_issue_count =
    runtime_diagnostics_json ()
  in
  let warnings =
    []
    |> fun acc ->
    if source_mismatch then
      let runtime = Option.value ~default:"unknown" runtime_commit in
      let workspace = Option.value ~default:"unknown" workspace_commit in
      (Printf.sprintf
         "Runtime build commit (%s) differs from workspace HEAD (%s). Rebuild/restart from the intended worktree."
         runtime workspace)
      :: acc
    else acc
    |> fun acc ->
    if prompt_dir_mismatch then
      (Printf.sprintf
         "Prompt markdown dir (%s) differs from resolved config root (%s)."
         prompt_markdown_dir expected_prompt_dir)
      :: acc
    else acc
    |> fun acc ->
    if signal_count > 0 then
      (Printf.sprintf
         "Recent external shutdown signals detected in server logs (%d). Ephemeral agents will not auto-rejoin after these restarts."
         signal_count)
      :: acc
    else acc
    |> fun acc ->
    if repair_count > 0 then
      (Printf.sprintf "Recent room-state repair events detected (%d)." repair_count)
      :: acc
    else acc
    |> fun acc ->
    if agent_issue_count > 0 then
      (Printf.sprintf
         "Recent agent-state compatibility warnings detected (%d)."
         agent_issue_count)
      :: acc
    else acc
    |> fun acc ->
    acc
    |> List.rev
  in
  let status = if warnings = [] then "ready" else "warn" in
  `Assoc
    [
      ("status", `String status);
      ("warnings", `List (List.map (fun warning -> `String warning) warnings));
      ("base_path", path_item_json ~source:"input" base_path_input);
      ("workspace_path", path_item_json ~source:"workspace" config.workspace_path);
      ("resolved_base_path", path_item_json ~source:"resolved_base" config.base_path);
      ("data_root", path_item_json ~source:"runtime_data" (Coord.masc_root_dir config));
      ("prompt_markdown_dir", path_item_json ~source:"prompt_registry" prompt_markdown_dir);
      ( "workspace_git_commit",
        Option.fold ~none:`Null ~some:(fun value -> `String value) workspace_commit
      );
      ( "resolved_base_git_commit",
        Option.fold
          ~none:`Null
          ~some:(fun value -> `String value)
          resolved_base_commit );
      ("source_mismatch", `Bool source_mismatch);
      ("diagnostics", diagnostics);
      ("keeper_runtime", Keeper_runtime_resolved.(current () |> to_yojson));
      ("build", Build_identity.to_yojson build);
    ]

let dashboard_tools_http_json ?actor (config : Coord.config) : Yojson.Safe.t =
  let ctx : Tool_misc.context =
    {
      config;
      agent_name = Option.value ~default:"dashboard" actor;
    }
  in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("config_resolution", Config_dir_resolver.(resolve () |> to_json));
      ("runtime_resolution", runtime_resolution_json config);
      ( "tool_inventory",
        Tool_misc.tool_inventory_json ctx ~include_hidden:true
          ~include_deprecated:true );
      ( "tool_usage",
        Tool_unified.summary_report ()
        |> Tool_usage_log.attach_source_metadata
             ~masc_root:(Coord.masc_root_dir config) );
    ]

type dashboard_perf_row = {
  benchmark : string;
  avg_ms : int;
  p50_ms : int;
  p95_ms : int;
  max_ms : int;
  notes : string;
}

type dashboard_perf_compare_row = {
  benchmark : string;
  avg_delta_ms : int;
  avg_delta_pct : float option;
  p95_delta_ms : int;
  p95_delta_pct : float option;
  max_delta_ms : int;
  verdict : string;
}

let dedupe_strings values =
  List.fold_left
    (fun acc value ->
      if value = "" || List.mem value acc then acc else acc @ [ value ])
    [] values

let parse_benchmark_timestamp path =
  let base = Filename.basename path in
  let prefix = "results_" in
  let suffix = ".csv" in
  if String.length base <= String.length prefix + String.length suffix then None
  else if not (String.starts_with ~prefix base) || not (Filename.check_suffix base suffix)
  then None
  else
    Some
      (String.sub base (String.length prefix)
         (String.length base - String.length prefix - String.length suffix))

let current_worktree_results_dir (config : Coord.config) =
  let cwd = Sys.getcwd () in
  let worktrees_root = Filename.concat config.base_path ".worktrees" in
  if String.equal cwd worktrees_root then
    None
  else if path_descends_from ~root:worktrees_root cwd then
    let rel = String.sub cwd (String.length worktrees_root + 1)
        (String.length cwd - String.length worktrees_root - 1) in
    let worktree_name =
      match String.index_opt rel '/' with
      | Some i -> String.sub rel 0 i
      | None -> rel
    in
    let worktree_root = Filename.concat worktrees_root worktree_name in
    Some (Filename.concat worktree_root "benchmarks/results")
  else None

let display_benchmark_path (config : Coord.config) path =
  match path_relative_to ~root:config.base_path path with
  | Some relative -> relative
  | None -> Filename.basename path

let benchmark_results_dir_candidates (config : Coord.config) =
  let env_dir =
    match Sys.getenv_opt "MASC_BENCHMARK_RESULTS_DIR" with
    | Some "" | None -> None
    | some -> some
  in
  let scoped_dirs =
    [
      Option.value ~default:"" (current_worktree_results_dir config);
      Filename.concat config.base_path "benchmarks/results";
    ]
  in
  dedupe_strings
    (match trim_to_option (Option.value ~default:"" env_dir) with
     | Some dir -> [ dir ]
     | None -> scoped_dirs)
  |> List.filter (fun path -> Sys.file_exists path && Sys.is_directory path)

let benchmark_result_files results_dir =
  let entries =
    try Sys.readdir results_dir |> Array.to_list
    with Sys_error _ -> []
  in
  entries
  |> List.filter (fun name ->
         String.starts_with ~prefix:"results_" name
         && Filename.check_suffix name ".csv")
  |> List.map (Filename.concat results_dir)
  |> List.filter (fun path -> Sys.file_exists path)

let latest_file_by_mtime files =
  files
  |> List.filter_map (fun path ->
         try Some (path, (Unix.stat path).Unix.st_mtime)
         with Unix.Unix_error _ | Sys_error _ -> None)
  |> List.sort (fun (_, left) (_, right) -> Float.compare right left)
  |> List.map fst
  |> list_hd_opt

let latest_benchmark_result_file (config : Coord.config) =
  benchmark_results_dir_candidates config
  |> List.concat_map benchmark_result_files
  |> latest_file_by_mtime

let split_csv_row line =
  match String.split_on_char ',' line with
  | benchmark :: avg_ms :: p50_ms :: p95_ms :: max_ms :: notes ->
      Some
        ( benchmark,
          avg_ms,
          p50_ms,
          p95_ms,
          max_ms,
          String.concat "," notes |> String.trim )
  | _ -> None

let int_of_string_opt raw =
  int_of_string_opt ((String.trim raw))

let load_benchmark_rows path =
  let lines =
    try In_channel.with_open_text path In_channel.input_all |> String.split_on_char '\n'
    with Sys_error _ -> []
  in
  lines
  |> List.filter_map (fun line ->
         let trimmed = String.trim line in
         if trimmed = "" || String.starts_with ~prefix:"benchmark," trimmed then None
         else
           match split_csv_row trimmed with
           | Some (benchmark, avg_ms, p50_ms, p95_ms, max_ms, notes) -> (
               match
                 ( int_of_string_opt avg_ms,
                   int_of_string_opt p50_ms,
                   int_of_string_opt p95_ms,
                   int_of_string_opt max_ms )
               with
               | Some avg_ms, Some p50_ms, Some p95_ms, Some max_ms ->
                   Some { benchmark; avg_ms; p50_ms; p95_ms; max_ms; notes }
               | _ -> None)
           | None -> None)

let load_benchmark_meta path =
  if Sys.file_exists path then
    try Some (Yojson.Safe.from_file path)
    with Yojson.Json_error _ | Sys_error _ -> None
  else None

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

let dashboard_perf_row_json (row : dashboard_perf_row) =
  `Assoc
    [
      ("benchmark", `String row.benchmark);
      ("avg_ms", `Int row.avg_ms);
      ("p50_ms", `Int row.p50_ms);
      ("p95_ms", `Int row.p95_ms);
      ("max_ms", `Int row.max_ms);
      ("notes", `String row.notes);
      ("note_tags", note_tags_json row.notes);
    ]

let pct_delta ~baseline delta =
  if baseline = 0 then None
  else Some ((float_of_int delta /. float_of_int baseline) *. 100.0)

let compare_verdict ~avg_delta ~p95_delta =
  if ((avg_delta > 0 && p95_delta < 0) || (avg_delta < 0 && p95_delta > 0))
     && (abs avg_delta >= 50 || abs p95_delta >= 50)
  then "mixed"
  else if avg_delta >= 50 && p95_delta >= 0 then "regressed"
  else if p95_delta >= 50 && avg_delta >= 0 then "regressed"
  else if avg_delta <= -50 && p95_delta <= 0 then "improved"
  else if p95_delta <= -50 && avg_delta <= 0 then "improved"
  else "stable"

let compare_rows ~baseline ~current =
  current
  |> List.filter_map (fun (row : dashboard_perf_row) ->
         match List.find_opt (fun (candidate : dashboard_perf_row) ->
                 String.equal candidate.benchmark row.benchmark) baseline with
         | None -> None
         | Some base ->
             let avg_delta = row.avg_ms - base.avg_ms in
             let p95_delta = row.p95_ms - base.p95_ms in
             Some
               {
                 benchmark = row.benchmark;
                 avg_delta_ms = avg_delta;
                 avg_delta_pct = pct_delta ~baseline:base.avg_ms avg_delta;
                 p95_delta_ms = p95_delta;
                 p95_delta_pct = pct_delta ~baseline:base.p95_ms p95_delta;
                 max_delta_ms = row.max_ms - base.max_ms;
                 verdict = compare_verdict ~avg_delta ~p95_delta;
               })
  |> List.sort (fun left right ->
         compare
           (abs right.p95_delta_ms, abs right.avg_delta_ms)
           (abs left.p95_delta_ms, abs left.avg_delta_ms))

let dashboard_perf_compare_row_json (row : dashboard_perf_compare_row) =
  `Assoc
    [
      ("benchmark", `String row.benchmark);
      ("avg_delta_ms", `Int row.avg_delta_ms);
      ( "avg_delta_pct",
        Option.fold ~none:`Null ~some:(fun value -> `Float value) row.avg_delta_pct );
      ("p95_delta_ms", `Int row.p95_delta_ms);
      ( "p95_delta_pct",
        Option.fold ~none:`Null ~some:(fun value -> `Float value) row.p95_delta_pct );
      ("max_delta_ms", `Int row.max_delta_ms);
      ("verdict", `String row.verdict);
    ]

let baseline_file_for ~current_file ~meta =
  match meta with
  | Some json -> (
      match json_string_field_opt "compare_baseline_file" json with
      | Some path when Sys.file_exists path -> Some path
      | _ -> None)
  | None ->
      let results_dir = Filename.dirname current_file in
      benchmark_result_files results_dir
      |> List.filter (fun path -> not (String.equal path current_file))
      |> latest_file_by_mtime

let benchmark_source_json config ~results_dir ~result_file ~meta_file ~baseline_file =
  `Assoc
    [
      ("results_dir", `String (display_benchmark_path config results_dir));
      ("result_file", `String (display_benchmark_path config result_file));
      ( "meta_file",
        Option.fold ~none:`Null
          ~some:(fun path -> `String (display_benchmark_path config path))
          meta_file );
      ( "baseline_file",
        Option.fold ~none:`Null
          ~some:(fun path -> `String (display_benchmark_path config path))
          baseline_file );
    ]

let latest_run_json ~result_file ~meta rows =
  let timestamp = parse_benchmark_timestamp result_file in
  let started_at = Option.bind meta (json_string_field_opt "started_at") in
  let pattern = Option.bind meta (json_string_field_opt "pattern") in
  let iterations = Option.bind meta (fun json -> Safe_ops.json_int_opt "iterations" json) in
  let warmup_iterations =
    Option.bind meta (fun json -> Safe_ops.json_int_opt "warmup_iterations" json)
  in
  let session_warmup_iterations =
    Option.bind meta (fun json -> Safe_ops.json_int_opt "session_warmup_iterations" json)
  in
  `Assoc
    [
      ("timestamp", Option.fold ~none:`Null ~some:(fun value -> `String value) timestamp);
      ("started_at", Option.fold ~none:`Null ~some:(fun value -> `String value) started_at);
      ("pattern", Option.fold ~none:`Null ~some:(fun value -> `String value) pattern);
      ("iterations", Option.fold ~none:`Null ~some:(fun value -> `Int value) iterations);
      ("warmup_iterations", Option.fold ~none:`Null ~some:(fun value -> `Int value) warmup_iterations);
      ( "session_warmup_iterations",
        Option.fold ~none:`Null ~some:(fun value -> `Int value) session_warmup_iterations );
      ("benchmark_count", `Int (List.length rows));
    ]

let worst_live_mcp rows =
  rows
  |> List.filter (fun (row : dashboard_perf_row) ->
         String.starts_with ~prefix:"mcp_" row.benchmark
         && not (String.equal row.benchmark "mcp_session_init"))
  |> List.sort (fun left right -> compare right.p95_ms left.p95_ms)
  |> list_hd_opt

let row_by_name rows name =
  List.find_opt (fun (row : dashboard_perf_row) -> String.equal row.benchmark name) rows

let verdict_counts_json rows =
  let counts =
    rows
    |> List.fold_left
         (fun (improved, stable, mixed, regressed) (row : dashboard_perf_compare_row) ->
           match row.verdict with
           | "improved" -> (improved + 1, stable, mixed, regressed)
           | "mixed" -> (improved, stable, mixed + 1, regressed)
           | "regressed" -> (improved, stable, mixed, regressed + 1)
           | _ -> (improved, stable + 1, mixed, regressed))
         (0, 0, 0, 0)
  in
  let improved, stable, mixed, regressed = counts in
  `Assoc
    [
      ("improved", `Int improved);
      ("stable", `Int stable);
      ("mixed", `Int mixed);
      ("regressed", `Int regressed);
    ]

let dashboard_perf_http_json (config : Coord.config) : Yojson.Safe.t =
  match latest_benchmark_result_file config with
  | None ->
      `Assoc
        [
          ("generated_at", `String (Masc_domain.now_iso ()));
          ("status", `String "empty");
          ("benchmarks", `List []);
          ("comparison", `Null);
          ( "candidate_dirs",
            `List
              (benchmark_results_dir_candidates config
              |> List.map (fun path -> `String (display_benchmark_path config path))) );
          ("message", `String "No benchmark artifacts found");
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
        [
          ("generated_at", `String (Masc_domain.now_iso ()));
          ("status", `String "ok");
          ( "source",
            benchmark_source_json config ~results_dir ~result_file ~meta_file
              ~baseline_file );
          ("latest_run", latest_run_json ~result_file ~meta rows);
          ( "highlights",
            `Assoc
              [
                ( "session_init",
                  Option.fold ~none:`Null ~some:dashboard_perf_row_json
                    (row_by_name rows "mcp_session_init") );
                ( "worst_live_mcp",
                  Option.fold ~none:`Null ~some:dashboard_perf_row_json
                    (worst_live_mcp rows) );
                ( "runtime_status",
                  Option.fold ~none:`Null ~some:dashboard_perf_row_json
                    (row_by_name rows "oas_runtime_status") );
                ( "runtime_single",
                  Option.fold ~none:`Null ~some:dashboard_perf_row_json
                    (row_by_name rows "oas_runtime_single") );
              ] );
          ("benchmarks", `List (List.map dashboard_perf_row_json rows));
          ( "comparison",
            match baseline_file with
            | None -> `Null
            | Some path ->
                `Assoc
                  [
                    ("baseline_file", `String (display_benchmark_path config path));
                    ("verdict_counts", verdict_counts_json comparison_rows);
                    ( "top_changes",
                      `List
                        (comparison_rows
                        |> take 8
                        |> List.map dashboard_perf_compare_row_json) );
                  ] );
        ]
