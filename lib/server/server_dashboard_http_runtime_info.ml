(** Runtime-resolution and dashboard tools projections extracted from the
    dashboard HTTP facade. *)

open Dashboard_http_helpers

let contains_substring ~needle haystack = String_util.contains_substring haystack needle

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

let trim_to_option raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed
;;

type dashboard_runtime_probe_cache_entry =
  { probe : Yojson.Safe.t
  ; refreshed_at : float
  }

let dashboard_runtime_probe_cache : dashboard_runtime_probe_cache_entry option Atomic.t =
  Atomic.make None
;;

let dashboard_runtime_probe_cache_ttl_sec = 30.0
let dashboard_runtime_probe_force_min_refresh_sec = 10.0
let dashboard_runtime_probe_timeout_sec = 15
let dashboard_runtime_probe_refresh_in_flight = Atomic.make false

let dashboard_runtime_probe_runner_hook : (unit -> Yojson.Safe.t) option Atomic.t =
  Atomic.make None
;;

let set_dashboard_runtime_probe_runner_for_tests hook =
  Atomic.set dashboard_runtime_probe_runner_hook (Some hook)
;;

let clear_dashboard_runtime_probe_runner_for_tests () =
  Atomic.set dashboard_runtime_probe_runner_hook None
;;

let clear_dashboard_runtime_probe_cache_for_tests () =
  Atomic.set dashboard_runtime_probe_cache None;
  Atomic.set dashboard_runtime_probe_refresh_in_flight false
;;

(* Per-path TTL cache for `git rev-parse --short HEAD`.  Each miss forks
   git and can take seconds on large worktrees (~/me etc.), yet HEAD
   changes infrequently, and every dashboard shell refresh calls this
   twice (workspace + base).  Serving cached values keeps snapshot_json
   off the 5 s git-probe budget on the hot path. *)
let git_rev_parse_short_ttl_sec = 60.0

let git_rev_parse_short_cache : (string, string option * float) Hashtbl.t =
  Hashtbl.create 4
;;

let git_rev_parse_short_in_flight : (string, unit) Hashtbl.t = Hashtbl.create 4
let git_rev_parse_short_mu = Stdlib.Mutex.create ()

let git_rev_parse_short_probe_hook_for_tests : (string -> string option) option Atomic.t =
  Atomic.make None
;;

let set_git_rev_parse_short_probe_hook_for_tests hook =
  Atomic.set git_rev_parse_short_probe_hook_for_tests (Some hook)
;;

let clear_git_rev_parse_short_probe_hook_for_tests () =
  Atomic.set git_rev_parse_short_probe_hook_for_tests None
;;

let git_rev_parse_short_cached_lookup dir ~now =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () ->
       match Hashtbl.find_opt git_rev_parse_short_cache dir with
       | Some (value, ts) when now -. ts <= git_rev_parse_short_ttl_sec -> Some value
       | _ -> None)
;;

let git_rev_parse_short_cached_any dir =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () -> Hashtbl.find_opt git_rev_parse_short_cache dir |> Option.map fst)
;;

let git_rev_parse_short_try_begin_refresh dir =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () ->
       if Hashtbl.mem git_rev_parse_short_in_flight dir
       then false
       else (
         Hashtbl.replace git_rev_parse_short_in_flight dir ();
         true))
;;

let git_rev_parse_short_finish_refresh dir value ~now =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () ->
       Hashtbl.replace git_rev_parse_short_cache dir (value, now);
       Hashtbl.remove git_rev_parse_short_in_flight dir)
;;

let git_rev_parse_short_cancel_refresh dir =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () -> Hashtbl.remove git_rev_parse_short_in_flight dir)
;;

let git_rev_parse_short_probe_argv dir =
  [ "git"; "-C"; dir; "--no-optional-locks"; "rev-parse"; "--short"; "HEAD" ]
;;

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
    (match
       Masc_exec.Exec_gate.run_argv_with_status
         ~actor:(Masc_exec.Agent_id.of_string "system/runtime_info")
         ~raw_source
         ~summary:"dashboard runtime git probe"
         ~timeout_sec:git_rev_parse_short_probe_timeout_sec
         argv
     with
     | Unix.WEXITED 0, output -> trim_to_option output
     | _ -> None)
;;

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
;;

let maybe_refresh_git_rev_parse_short_in_background dir =
  match Eio_context.get_switch_opt () with
  | None -> ()
  | Some sw ->
    if git_rev_parse_short_try_begin_refresh dir
    then
      Eio.Fiber.fork ~sw (fun () ->
        try
          let _ = git_rev_parse_short_refresh dir in
          ()
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Dashboard.warn
            "dashboard runtime git probe refresh failed for %s: %s"
            dir
            (Printexc.to_string exn))
;;

let git_rev_parse_short path =
  match trim_to_option path with
  | None -> None
  | Some dir when not (Sys.file_exists dir) -> None
  | Some dir ->
    let now = Time_compat.now () in
    (match git_rev_parse_short_cached_lookup dir ~now with
     | Some value -> value
     | None ->
       (match git_rev_parse_short_cached_any dir with
        | Some stale ->
          maybe_refresh_git_rev_parse_short_in_background dir;
          stale
        | None ->
          if git_rev_parse_short_try_begin_refresh dir
          then git_rev_parse_short_refresh dir
          else git_rev_parse_short_cached_any dir |> Option.value ~default:None))
;;

let opt_string_json = function
  | None -> `Null
  | Some value -> `String value
;;

let opt_bool_json = function
  | None -> `Null
  | Some value -> `Bool value
;;

let opt_commit_equal left right =
  match left, right with
  | Some left, Some right -> Some (String.equal left right)
  | _ -> None
;;

let deployment_state_json
      ~(build : Build_identity.t)
      ~server_repo_commit
      ~workspace_commit
      ~resolved_base_commit
      ~source_mismatch
  =
  let binary_commit_known = Option.is_some build.binary_commit in
  let deployed_matches_server_repo =
    opt_commit_equal build.commit server_repo_commit
  in
  let deployed_matches_runtime_repo =
    opt_commit_equal build.commit build.repo_head_commit
  in
  let built_matches_runtime_repo =
    opt_commit_equal build.binary_commit build.repo_head_commit
  in
  let status =
    if source_mismatch
    then "diverged"
    else if not binary_commit_known
    then "unproven"
    else (
      match built_matches_runtime_repo with
      | Some true -> "current"
      | Some false -> "diverged"
      | None -> "unknown")
  in
  `Assoc
    [ "schema", `String "masc.runtime_deployment_state.v1"
    ; "status", `String status
    ; "operator_action_required", `Bool (String.equal status "diverged")
    ; "binary_commit_known", `Bool binary_commit_known
    ; ( "merged"
      , `Assoc
          [ "commit", opt_string_json server_repo_commit
          ; "source", `String "server_repo_head"
          ] )
    ; ( "built"
      , `Assoc
          [ "commit", opt_string_json build.binary_commit
          ; "source", opt_string_json build.binary_commit_source
          ; ( "proof"
            , `String
                (if binary_commit_known
                 then "build_env_commit"
                 else "missing_build_env_commit") )
          ] )
    ; ( "deployed"
      , `Assoc
          [ "commit", opt_string_json build.commit
          ; "source", opt_string_json build.commit_source
          ; "started_at", `String build.started_at
          ; "executable_path", `String build.executable_path
          ] )
    ; ( "runtime_repo"
      , `Assoc
          [ "head_commit", opt_string_json build.repo_head_commit
          ; "head_commit_source", opt_string_json build.repo_head_commit_source
          ] )
    ; ( "workspace"
      , `Assoc
          [ "head_commit", opt_string_json workspace_commit
          ; "resolved_base_head_commit", opt_string_json resolved_base_commit
          ] )
    ; ( "checks"
      , `Assoc
          [ "deployed_matches_merged", opt_bool_json deployed_matches_server_repo
          ; "deployed_matches_runtime_repo", opt_bool_json deployed_matches_runtime_repo
          ; "built_matches_runtime_repo", opt_bool_json built_matches_runtime_repo
          ; "source_mismatch", `Bool source_mismatch
          ] )
    ]
;;

let clear_git_rev_parse_short_cache_for_tests () =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () ->
       Hashtbl.clear git_rev_parse_short_cache;
       Hashtbl.clear git_rev_parse_short_in_flight)
;;

let seed_git_rev_parse_short_cache_for_tests dir value ~refreshed_at =
  Stdlib.Mutex.lock git_rev_parse_short_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock git_rev_parse_short_mu)
    (fun () ->
       Hashtbl.replace git_rev_parse_short_cache dir (value, refreshed_at);
       Hashtbl.remove git_rev_parse_short_in_flight dir)
;;

let path_item_json ~source path =
  `Assoc
    [ "path", `String path
    ; "exists", `Bool (String.trim path <> "" && Sys.file_exists path)
    ; "source", `String source
    ]
;;

let normalized_path_opt path =
  match trim_to_option path with
  | None -> None
  | Some path ->
    let normalized =
      if Sys.file_exists path
      then (
        try Unix.realpath path with
        | Unix.Unix_error _ -> path)
      else path
    in
    Some normalized
;;

let same_normalized_path path expected =
  match normalized_path_opt expected with
  | Some expected -> String.equal path expected
  | None -> false
;;

let shutdown_signal_of_message message =
  if contains_substring ~needle:"Received SIGTERM" message
  then Some "SIGTERM"
  else if contains_substring ~needle:"Received SIGINT" message
  then Some "SIGINT"
  else None
;;

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
              [ "ts", `String entry.ts
              ; "kind", `String "external_signal"
              ; "signal", `String signal
              ; "message", `String message
              ])
      | None
        when contains_substring
               ~needle:"repairing state and rewriting canonical JSON"
               message ->
        Some
          (`Assoc
              [ "ts", `String entry.ts
              ; "kind", `String "state_repair"
              ; "message", `String message
              ])
      | None
        when contains_substring ~needle:"invalid agent JSON" message
             || contains_substring ~needle:"repaired agent JSON" message
             || contains_substring
                  ~needle:"parse error: Types_core.agent.last_seen"
                  message ->
        Some
          (`Assoc
              [ "ts", `String entry.ts
              ; "kind", `String "agent_state"
              ; "message", `String message
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
      0
      diagnostics
  in
  `List diagnostics, count "external_signal", count "state_repair", count "agent_state"
;;

let run_dashboard_runtime_probe () =
  match Atomic.get dashboard_runtime_probe_runner_hook with
  | Some hook -> hook ()
  | None ->
    `Assoc
      [ "source", `String "runtime"
      ; "probe_ok", `Null
      ; "status", `String "oas_owned"
      ; "detail", `String "Concrete provider probes are owned by OAS."
      ]
;;

let dashboard_runtime_probe_cached_value () =
  match Atomic.get dashboard_runtime_probe_cache with
  | Some entry -> Some (entry.probe, entry.refreshed_at)
  | None -> None
;;

let dashboard_runtime_probe_fresh_value ~now =
  match dashboard_runtime_probe_cached_value () with
  | Some (probe, refreshed_at)
    when now -. refreshed_at <= dashboard_runtime_probe_cache_ttl_sec ->
    Some (probe, refreshed_at)
  | _ -> None
;;

let dashboard_runtime_probe_recent_value ~now =
  match dashboard_runtime_probe_cached_value () with
  | Some (probe, refreshed_at)
    when now -. refreshed_at <= dashboard_runtime_probe_force_min_refresh_sec ->
    Some (probe, refreshed_at)
  | _ -> None
;;

let dashboard_runtime_probe_http_json ?(force = false) () =
  let now = Time_compat.now () in
  let probe, cache_hit, refreshed_at =
    match
      if force
      then dashboard_runtime_probe_recent_value ~now
      else dashboard_runtime_probe_fresh_value ~now
    with
    | Some (cached, cached_at) -> cached, true, cached_at
    | None ->
      if Atomic.compare_and_set dashboard_runtime_probe_refresh_in_flight false true
      then (
        (* Run the Eio-yielding probe outside any Stdlib mutex/Fun.protect
             scope.  The CAS guard above serialises refreshes; the [match]
             below ensures the in-flight flag is always cleared even when
             the probe raises or is cancelled (Atomic.set never yields). *)
        match run_dashboard_runtime_probe () with
        | fresh ->
          let refreshed_at = Time_compat.now () in
          Atomic.set dashboard_runtime_probe_cache (Some { probe = fresh; refreshed_at });
          Atomic.set dashboard_runtime_probe_refresh_in_flight false;
          fresh, false, refreshed_at
        | exception exn ->
          let bt = Printexc.get_raw_backtrace () in
          Atomic.set dashboard_runtime_probe_refresh_in_flight false;
          Printexc.raise_with_backtrace exn bt)
      else (
        let fallback_now = Time_compat.now () in
        match
          if not force
          then dashboard_runtime_probe_fresh_value ~now:fallback_now
          else None
        with
        | Some (cached, cached_at) -> cached, true, cached_at
        | None ->
          (match dashboard_runtime_probe_cached_value () with
           | Some (cached, cached_at) -> cached, false, cached_at
           | None -> `Null, false, 0.0))
  in
  let response_now = Time_compat.now () in
  let refreshed_at_json, cache_age_json =
    if refreshed_at > 0.0
    then `Float refreshed_at, `Float (max 0.0 (response_now -. refreshed_at))
    else `Null, `Null
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; "refreshed_at_unix", refreshed_at_json
    ; "cache_ttl_sec", `Float dashboard_runtime_probe_cache_ttl_sec
    ; "cache_age_sec", cache_age_json
    ; "cache_hit", `Bool cache_hit
    ; "probe", probe
    ]
;;

let runtime_resolution_json (config : Coord.config) =
  let build = Build_identity.current () in
  let runtime_commit = build.binary_commit in
  let runtime_commit_known = Option.is_some runtime_commit in
  let server_repo_path = Build_identity.repo_root () in
  let server_repo_commit = Option.bind server_repo_path git_rev_parse_short in
  let workspace_commit = git_rev_parse_short config.workspace_path in
  let resolved_base_commit = git_rev_parse_short config.base_path in
  let base_path_input =
    (Host_config.from_env ()).base_path_raw |> Option.value ~default:config.workspace_path
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
    match runtime_commit, server_repo_commit, workspace_commit with
    | Some runtime, Some server_repo, _ -> not (String.equal runtime server_repo)
    | Some runtime, None, Some workspace -> not (String.equal runtime workspace)
    | _ -> false
  in
  let server_workspace_mismatch =
    match Option.bind server_repo_path normalized_path_opt with
    | None -> false
    | Some server_repo_path ->
      (not (same_normalized_path server_repo_path config.workspace_path))
      && not (same_normalized_path server_repo_path config.base_path)
  in
  let diagnostics, signal_count, repair_count, agent_issue_count =
    runtime_diagnostics_json ()
  in
  let add_source_mismatch_warning acc =
    if source_mismatch
    then (
      (* When [runtime_commit] is [None] the warning previously
         rendered as "Runtime build commit (unknown) differs from ...".
         The *reason* the binary commit is unknown was emitted as a
         separate [add_binary_commit_unknown_warning] further down,
         forcing the dashboard reader to cross-reference two warnings
         to understand a single mismatch.  Inline the reason in the
         sentinel itself so the warning is self-contained. *)
      let runtime =
        match runtime_commit with
        | Some commit -> commit
        | None ->
            "<unknown — Build_identity.binary_commit not populated by build \
             pipeline>"
      in
      let source_label, source_commit =
        match server_repo_commit with
        | Some commit -> "server repo HEAD", commit
        | None ->
            (* [workspace_commit] is [git_rev_parse_short config.workspace_path].
               [None] means [git rev-parse] failed at that path; naming the
               path gives the operator the worktree to check. *)
            let commit =
              match workspace_commit with
              | Some c -> c
              | None ->
                  Printf.sprintf
                    "<unknown — git rev-parse failed at workspace_path=%s>"
                    config.workspace_path
            in
            "workspace HEAD", commit
      in
      Printf.sprintf
        "Runtime build commit (%s) differs from %s (%s). Rebuild/restart from \
         the intended server worktree."
        runtime
        source_label
        source_commit
      :: acc)
    else acc
  in
  let add_binary_commit_unknown_warning acc =
    if (not runtime_commit_known) && Option.is_some build.repo_head_commit
    then
      "Runtime binary commit is unknown; build.repo_head_commit is only the \
       current checkout HEAD and must not be treated as rebuild proof."
      :: acc
    else acc
  in
  let add_server_workspace_mismatch_warning acc =
    if server_workspace_mismatch
    then (
      (* [server_workspace_mismatch] is only true when [server_repo_path] is
         [Some _] (see the [Option.bind] guard above), so the [None] branch is
         dead at runtime — but [Option.value ~default:"unknown server repo"]
         silently buried that invariant.  Use the structured form instead:
         the dead branch documents *why* it cannot fire. *)
      let server_repo =
        match server_repo_path with
        | Some repo -> repo
        | None ->
            (* Unreachable: [server_workspace_mismatch] requires
               [Option.bind server_repo_path normalized_path_opt = Some _],
               which in turn requires [server_repo_path = Some _]. *)
            "<unreachable — server_workspace_mismatch implies server_repo_path \
             = Some _>"
      in
      Printf.sprintf
        "Server binary checkout (%s) differs from dashboard workspace/base \
         path (%s / %s). This can be intentional; verify the running worktree \
         when dashboard data looks stale."
        server_repo
        config.workspace_path
        config.base_path
      :: acc)
    else acc
  in
  let add_prompt_dir_mismatch_warning acc =
    if prompt_dir_mismatch
    then
      Printf.sprintf
        "Prompt markdown dir (%s) differs from resolved config root (%s)."
        prompt_markdown_dir
        expected_prompt_dir
      :: acc
    else acc
  in
  let add_signal_warning acc =
    if signal_count > 0
    then
      Printf.sprintf
        "Recent external shutdown signals detected in server logs (%d). Ephemeral \
         agents will not auto-rejoin after these restarts."
        signal_count
      :: acc
    else acc
  in
  let add_repair_warning acc =
    if repair_count > 0
    then Printf.sprintf "Recent room-state repair events detected (%d)." repair_count :: acc
    else acc
  in
  let add_agent_issue_warning acc =
    if agent_issue_count > 0
    then
      Printf.sprintf "Recent agent-state compatibility warnings detected (%d)."
        agent_issue_count
      :: acc
    else acc
  in
  let warnings =
    []
    |> add_source_mismatch_warning
    |> add_binary_commit_unknown_warning
    |> add_server_workspace_mismatch_warning
    |> add_prompt_dir_mismatch_warning
    |> add_signal_warning
    |> add_repair_warning
    |> add_agent_issue_warning
    |> List.rev
  in
  let status = if warnings = [] then "ready" else "warn" in
  `Assoc
    ( [ "status", `String status
      ; "warnings", `List (List.map (fun warning -> `String warning) warnings)
      ; "base_path", path_item_json ~source:"input" base_path_input
      ; "workspace_path", path_item_json ~source:"workspace" config.workspace_path
      ; "resolved_base_path", path_item_json ~source:"resolved_base" config.base_path
      ; "data_root", path_item_json ~source:"runtime_data" (Coord.masc_root_dir config)
      ; "prompt_markdown_dir", path_item_json ~source:"prompt_registry" prompt_markdown_dir
      ; ( "server_repo_path"
        , match server_repo_path with
          | Some path -> path_item_json ~source:"server_binary" path
          | None ->
            `Assoc
              [ "path", `Null; "exists", `Bool false; "source", `String "server_binary" ] )
      ; ( "server_repo_git_commit"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) server_repo_commit )
      ; ( "runtime_binary_git_commit"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) runtime_commit )
      ; ( "runtime_repo_head_git_commit"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) build.repo_head_commit )
      ; ( "workspace_git_commit"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) workspace_commit )
      ; ( "resolved_base_git_commit"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) resolved_base_commit )
      ; "source_mismatch", `Bool source_mismatch
      ; "server_workspace_mismatch", `Bool server_workspace_mismatch
      ; "diagnostics", diagnostics
      ; ("keeper_runtime", Keeper_runtime_resolved.(current () |> to_yojson))
      ; "build", Build_identity.to_yojson build
      ; ( "deployment_state"
        , deployment_state_json ~build ~server_repo_commit ~workspace_commit
            ~resolved_base_commit ~source_mismatch )
      ]
      @ Server_routes_http_runtime.keeper_fleet_runtime_resolution_fields () )
;;

let dashboard_tools_http_json ?actor (config : Coord.config) : Yojson.Safe.t =
  let ctx : Tool_misc.context =
    { config; agent_name = Option.value ~default:"dashboard" actor }
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; ("config_resolution", Config_dir_resolver.(resolve () |> to_json))
    ; "runtime_resolution", runtime_resolution_json config
    ; ( "tool_inventory"
      , Tool_misc.tool_inventory_json ctx ~include_hidden:true ~include_deprecated:true )
    ; ( "tool_usage"
      , Tool_unified.summary_report ()
        |> Tool_usage_log.attach_source_metadata ~masc_root:(Coord.masc_root_dir config) )
    ]
;;

let dashboard_perf_http_json = Server_dashboard_http_perf.dashboard_perf_http_json
