(** Runtime-resolution and dashboard tools projections extracted from the
    dashboard HTTP facade. *)

open Dashboard_http_helpers

let take = Server_dashboard_http_runtime_info_json.take
type dashboard_runtime_probe_cache_entry =
  { probe : Yojson.Safe.t
  ; refreshed_at : float
  }

let dashboard_runtime_probe_cache : dashboard_runtime_probe_cache_entry option Atomic.t =
  Atomic.make None
;;

let dashboard_runtime_probe_cache_ttl_sec = 30.0
let dashboard_runtime_probe_force_min_refresh_sec = 10.0
(* Metadata-probe timeout. The dashboard probe hits provider metadata endpoints
   only ([/api/tags] for Ollama, [/models] for messages/chat — see
   {!dashboard_runtime_probe_url}); it never sends a completion request, so there
   is no warm-KV inference to wait for. A dead/dropping runtime therefore fails
   fast (RST) and a slow one is bounded here. 15s matched the completion-probe
   timeout and let one unreachable runtime stall the whole dashboard for the
   full window ("runtime-probe 한 번 잡히면 모든 게 다 느려짐"); 5s is a ~10x margin
   over observed metadata latency (<500ms) while cutting the worst-case stall
   by 3x. The completion-probe ([tool_local_runtime_probe]) keeps its own
   longer timeout because it does run inference.

   Caveat: this 5s is a total-request cap that also bounds remote provider
   [/models] endpoints (Messages/Chat APIs reached over the public internet),
   not just loopback Ollama. A legitimately-slow-but-alive cloud endpoint that
   the prior 15s tolerated can now be cut to [network_error]/unreachable;
   because the probe runs off the hot path and the next poll retries this
   self-heals, but the <500ms margin is evidenced for the local path only. *)
let dashboard_runtime_probe_timeout_sec = 5
(* Soft-TTL for stale-while-revalidate. A cache value is served as fresh for the
   full [dashboard_runtime_probe_cache_ttl_sec], but once its age crosses this
   threshold the request path schedules a non-blocking background refresh so the
   *next* poll (default 30s) sees a fresh value instead of a post-expiry miss.
   Set to half the TTL so a value refreshed on poll N is pre-warmed before
   poll N+1 -- this is what closes the TTL==poll-interval hit-rate-0 trap
   (cache expiry landing right at the next poll). *)
let dashboard_runtime_probe_soft_refresh_sec = 15.0
(* Concurrency cap for the parallel runtime-probe fan-out
   ([dashboard_runtime_probe_payload_json_of_runtimes]). The configured runtime
   fleet is small (a handful of providers), so this is a safety bound against
   unbounded fork rather than a tuned throughput knob; it mirrors
   [Dashboard_execution.dashboard_enrich_max_fibers] (8). *)
let dashboard_runtime_probe_max_fibers = 8
let dashboard_runtime_probe_refresh_in_flight = Atomic.make false

let dashboard_runtime_probe_runner_hook : (unit -> Yojson.Safe.t) option Atomic.t =
  Atomic.make None
;;

let dashboard_runtime_provider_http_get_hook :
  (url:string ->
   headers:(string * string) list ->
   timeout_sec:float ->
   (int * (string * string) list * string, string) result)
    option
    Atomic.t
  =
  Atomic.make None
;;

let set_dashboard_runtime_probe_runner_for_tests hook =
  Atomic.set dashboard_runtime_probe_runner_hook (Some hook)
;;

let clear_dashboard_runtime_probe_runner_for_tests () =
  Atomic.set dashboard_runtime_probe_runner_hook None
;;

let set_dashboard_runtime_provider_http_get_for_tests hook =
  Atomic.set dashboard_runtime_provider_http_get_hook (Some hook)
;;

let clear_dashboard_runtime_provider_http_get_for_tests () =
  Atomic.set dashboard_runtime_provider_http_get_hook None
;;

let clear_dashboard_runtime_probe_cache_for_tests () =
  Atomic.set dashboard_runtime_probe_cache None;
  Atomic.set dashboard_runtime_probe_refresh_in_flight false
;;

let set_dashboard_runtime_probe_cache_for_tests ~probe ~age_sec () =
  (* Seed the probe cache with a value [age_sec] seconds old so tests can drive
     the fresh / recent-window / stale branches of [dashboard_runtime_probe_http_json]
     deterministically. Unit tests have no Eio switch to fork a real background
     refresh into, so the cache must be seeded directly. The [age_sec] is
     translated to an absolute [refreshed_at] here so callers do not depend on
     [Time_compat]. *)
  Atomic.set
    dashboard_runtime_probe_cache
    (Some { probe; refreshed_at = Time_compat.now () -. age_sec })
;;

(* Per-path TTL cache for `git rev-parse --short HEAD`.  Each miss forks
   git and can take seconds on large worktrees (~/me etc.), yet HEAD
   changes infrequently, and every dashboard shell refresh calls this
   twice (workspace + base).  Serving cached values keeps snapshot_json
   off the 5 s git-probe budget on the hot path. *)
let git_rev_parse_short_ttl_sec = 60.0

(** Per-directory, mutex-guarded single-flight cache backing a background
    refresh probe.

    Extracted from the structurally identical bookkeeping that
    {!git_rev_parse_short} and {!git_upstream_status} each inlined
    (2026-06-17). The cache owns only state plus lookup/guard/store
    bookkeeping; the caller-driven background refresh orchestration and
    the domain-fork-aware fiber fork stay in the enclosing module and
    call [try_begin_refresh] / [finish_refresh] / [cancel_refresh].

    Concurrency model is unchanged from the previous inlined code:
    [mu] guards [cache] and [in_flight] together; [try_begin_refresh]
    is the single-flight gate (one refresh per key); [finish_refresh] /
    [cancel_refresh] release it. *)
module Make_probe_cache (C : sig
  type value

  val ttl_sec : float
end) = struct
  let cache : (string, C.value * float) Hashtbl.t = Hashtbl.create 4

  let in_flight : (string, unit) Hashtbl.t = Hashtbl.create 4

  let mu = Stdlib.Mutex.create ()

  let probe_hook_for_tests : (string -> C.value) option Atomic.t =
    Atomic.make None

  (** [Mutex.protect] (OCaml >= 5.1) is the manual-recommended primitive for a
      mutex-bracketed critical section. Unlike the hand-rolled
      [Mutex.lock; Fun.protect ~finally:unlock] form, it guarantees [unlock]
      even when an asynchronous exception (e.g. [Sys.Break]) is raised, so the
      mutex can never be left locked. *)
  let with_lock f = Stdlib.Mutex.protect mu f

  let cached_lookup dir ~now =
    with_lock (fun () ->
        match Hashtbl.find_opt cache dir with
        | Some (value, ts) when now -. ts <= C.ttl_sec -> Some value
        | _ -> None)

  let cached_any dir =
    with_lock (fun () -> Hashtbl.find_opt cache dir |> Option.map fst)

  let try_begin_refresh dir =
    with_lock (fun () ->
        if Hashtbl.mem in_flight dir then false
        else (
          Hashtbl.replace in_flight dir ();
          true))

  let finish_refresh dir value ~now =
    with_lock (fun () ->
        Hashtbl.replace cache dir (value, now);
        Hashtbl.remove in_flight dir)

  let cancel_refresh dir =
    with_lock (fun () -> Hashtbl.remove in_flight dir)

  let clear_cache_for_tests () =
    with_lock (fun () ->
        Hashtbl.clear cache;
        Hashtbl.clear in_flight)

  let seed_cache_for_tests dir value ~refreshed_at =
    with_lock (fun () ->
        Hashtbl.replace cache dir (value, refreshed_at);
        Hashtbl.remove in_flight dir)

  let set_probe_hook_for_tests hook =
    Atomic.set probe_hook_for_tests (Some hook)

  let clear_probe_hook_for_tests () = Atomic.set probe_hook_for_tests None
end

module Rev_parse_cache =
  Make_probe_cache (struct
    type value = string option

    let ttl_sec = git_rev_parse_short_ttl_sec
  end)

let set_git_rev_parse_short_probe_hook_for_tests =
  Rev_parse_cache.set_probe_hook_for_tests

let clear_git_rev_parse_short_probe_hook_for_tests =
  Rev_parse_cache.clear_probe_hook_for_tests
;;

let eio_switch_fork_unavailable = function
  | Invalid_argument msg ->
    String_util.contains_substring msg "Switch accessed from wrong domain"
    || String_util.contains_substring msg "Switch finished"
  | _ -> false
;;

(* Dashboard shell projections may run on Domain_pool worker domains.  Those
   domains can read the stale cache, but they must not fork fibers on the
   server root switch owned by the main Eio domain. *)
let background_refresh_unavailable_domains : (int, unit) Hashtbl.t = Hashtbl.create 4
let background_refresh_unavailable_domains_mu = Stdlib.Mutex.create ()

let current_domain_id () = (Domain.self () :> int)

let background_refresh_domain_unavailable () =
  Stdlib.Mutex.lock background_refresh_unavailable_domains_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock background_refresh_unavailable_domains_mu)
    (fun () -> Hashtbl.mem background_refresh_unavailable_domains (current_domain_id ()))
;;

let background_refresh_mark_domain_unavailable () =
  Stdlib.Mutex.lock background_refresh_unavailable_domains_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock background_refresh_unavailable_domains_mu)
    (fun () -> Hashtbl.replace background_refresh_unavailable_domains (current_domain_id ()) ())
;;

let background_refresh_clear_unavailable_domains_for_tests () =
  Stdlib.Mutex.lock background_refresh_unavailable_domains_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock background_refresh_unavailable_domains_mu)
    (fun () -> Hashtbl.clear background_refresh_unavailable_domains)
;;

let fork_background_refresh_or_cancel ~dir ~cancel_refresh run =
  if background_refresh_domain_unavailable ()
  then cancel_refresh dir
  else match Eio_context.get_switch_opt () with
  | None -> cancel_refresh dir
  | Some sw ->
    (try Eio.Fiber.fork ~sw run with
     | exn when eio_switch_fork_unavailable exn ->
       background_refresh_mark_domain_unavailable ();
       cancel_refresh dir
     | exn ->
       cancel_refresh dir;
       raise exn)
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
   keep serving during the refresh. This git-probe timeout is deliberately
   independent of (and larger than) the metadata probe
   [dashboard_runtime_probe_timeout_sec] (now 5s): a git rev-parse on a large
   repo is slower than an HTTP metadata GET, so the two are tuned separately. *)
let git_rev_parse_short_probe_timeout_sec = 15.0

let git_rev_parse_short_probe dir =
  match Atomic.get Rev_parse_cache.probe_hook_for_tests with
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
     | Unix.WEXITED 0, output -> String_util.trim_to_option output
     | _ -> None)
;;

let git_rev_parse_short_refresh dir =
  try
    let value = git_rev_parse_short_probe dir in
    Rev_parse_cache.finish_refresh dir value ~now:(Time_compat.now ());
    value
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Rev_parse_cache.cancel_refresh dir;
    raise exn
;;

let maybe_refresh_git_rev_parse_short_in_background dir =
  if Rev_parse_cache.try_begin_refresh dir
  then
    fork_background_refresh_or_cancel
      ~dir
      ~cancel_refresh:Rev_parse_cache.cancel_refresh
      (fun () ->
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
  match String_util.trim_to_option path with
  | None -> None
  | Some dir when not (Sys.file_exists dir) -> None
  | Some dir ->
    let now = Time_compat.now () in
    (match Rev_parse_cache.cached_lookup dir ~now with
     | Some value -> value
     | None ->
       (match Rev_parse_cache.cached_any dir with
        | Some stale ->
          maybe_refresh_git_rev_parse_short_in_background dir;
          stale
        | None ->
          if Rev_parse_cache.try_begin_refresh dir
          then git_rev_parse_short_refresh dir
          else Option.join (Rev_parse_cache.cached_any dir)))
;;

let opt_string_json = Server_dashboard_http_runtime_info_json.opt_string_json
let opt_bool_json = Server_dashboard_http_runtime_info_json.opt_bool_json
let opt_commit_equal = Server_dashboard_http_runtime_info_json.opt_commit_equal
let opt_int_json = Server_dashboard_http_runtime_info_json.opt_int_json

type git_upstream_status =
  Server_dashboard_http_runtime_info_json.git_upstream_status =
  { branch : string option
  ; upstream_ref : string option
  ; upstream_head_commit : string option
  ; ahead_count : int option
  ; behind_count : int option
  }

let empty_git_upstream_status =
  Server_dashboard_http_runtime_info_json.empty_git_upstream_status

let git_upstream_status_ttl_sec = 60.0

module Upstream_status_cache =
  Make_probe_cache (struct
    type value = git_upstream_status option

    let ttl_sec = git_upstream_status_ttl_sec
  end)

let set_git_upstream_status_probe_hook_for_tests =
  Upstream_status_cache.set_probe_hook_for_tests

let clear_git_upstream_status_probe_hook_for_tests =
  Upstream_status_cache.clear_probe_hook_for_tests
;;

let git_probe_trimmed dir args =
  let argv = [ "git"; "-C"; dir; "--no-optional-locks" ] @ args in
  let raw_source = String.concat " " (List.map Filename.quote argv) in
  match
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:(Masc_exec.Agent_id.of_string "system/runtime_info")
      ~raw_source
      ~summary:"dashboard runtime git upstream probe"
      ~timeout_sec:git_rev_parse_short_probe_timeout_sec
      argv
  with
  | Unix.WEXITED 0, output -> String_util.trim_to_option output
  | _ -> None
;;

let parse_ahead_behind raw =
  match
    raw
    |> String.trim
    |> String.split_on_char '\t'
    |> List.concat_map (String.split_on_char ' ')
    |> List.filter_map String_util.trim_to_option
  with
  | [ ahead; behind ] ->
    (match int_of_string_opt ahead, int_of_string_opt behind with
     | Some ahead, Some behind -> Some (ahead, behind)
     | _ -> None)
  | _ -> None
;;

let git_default_origin_head dir =
  git_probe_trimmed dir [ "symbolic-ref"; "--short"; "refs/remotes/origin/HEAD" ]
;;

let git_upstream_status_probe dir =
  match Atomic.get Upstream_status_cache.probe_hook_for_tests with
  | Some hook -> hook dir
  | None ->
    let branch = git_probe_trimmed dir [ "rev-parse"; "--abbrev-ref"; "HEAD" ] in
    let upstream_ref =
      match
        git_probe_trimmed
          dir
          [ "rev-parse"; "--abbrev-ref"; "--symbolic-full-name"; "@{upstream}" ]
      with
      | Some upstream -> Some upstream
      | None -> git_default_origin_head dir
    in
    let upstream_head_commit =
      Option.bind upstream_ref (fun ref_name ->
        git_probe_trimmed dir [ "rev-parse"; "--short"; ref_name ])
    in
    let ahead_count, behind_count =
      match upstream_ref with
      | None -> None, None
      | Some ref_name ->
        (match
           git_probe_trimmed
             dir
             [ "rev-list"; "--left-right"; "--count"; "HEAD..." ^ ref_name ]
         with
         | Some raw ->
           (match parse_ahead_behind raw with
            | Some (ahead, behind) -> Some ahead, Some behind
            | None -> None, None)
         | None -> None, None)
    in
    if branch = None
       && upstream_ref = None
       && upstream_head_commit = None
       && ahead_count = None
       && behind_count = None
    then None
    else Some { branch; upstream_ref; upstream_head_commit; ahead_count; behind_count }
;;

let git_upstream_status_refresh dir =
  try
    let value = git_upstream_status_probe dir in
    Upstream_status_cache.finish_refresh dir value ~now:(Time_compat.now ());
    value
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Upstream_status_cache.cancel_refresh dir;
    raise exn
;;

let maybe_refresh_git_upstream_status_in_background dir =
  if Upstream_status_cache.try_begin_refresh dir
  then
    fork_background_refresh_or_cancel
      ~dir
      ~cancel_refresh:Upstream_status_cache.cancel_refresh
      (fun () ->
        try
          let _ = git_upstream_status_refresh dir in
          ()
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Dashboard.warn
            "dashboard runtime git upstream refresh failed for %s: %s"
            dir
            (Printexc.to_string exn))
;;

let git_upstream_status path =
  match String_util.trim_to_option path with
  | None -> None
  | Some dir when not (Sys.file_exists dir) -> None
  | Some dir ->
    let now = Time_compat.now () in
    (match Upstream_status_cache.cached_lookup dir ~now with
     | Some value -> value
     | None ->
       (match Upstream_status_cache.cached_any dir with
        | Some stale ->
          maybe_refresh_git_upstream_status_in_background dir;
          stale
        | None ->
          if Upstream_status_cache.try_begin_refresh dir
          then git_upstream_status_refresh dir
          else Option.join (Upstream_status_cache.cached_any dir)))
;;

let deployment_state_json
      ~(build : Build_identity.t)
      ~server_repo_commit
      ~workspace_commit
      ~resolved_base_commit
      ~upstream_status
  ~source_mismatch
  =
  let binary_commit_known = Option.is_some build.binary_commit in
  let deployed_commit = build.binary_commit in
  let deployed_commit_source = build.binary_commit_source in
  let deployed_matches_server_repo =
    opt_commit_equal deployed_commit server_repo_commit
  in
  let deployed_matches_upstream =
    opt_commit_equal deployed_commit upstream_status.upstream_head_commit
  in
  let deployed_matches_runtime_repo =
    opt_commit_equal deployed_commit build.repo_head_commit
  in
  let runtime_repo_matches_server_repo =
    opt_commit_equal build.repo_head_commit server_repo_commit
  in
  let runtime_repo_matches_upstream =
    opt_commit_equal build.repo_head_commit upstream_status.upstream_head_commit
  in
  let built_matches_upstream =
    opt_commit_equal build.binary_commit upstream_status.upstream_head_commit
  in
  let built_matches_runtime_repo =
    opt_commit_equal build.binary_commit build.repo_head_commit
  in
  let server_repo_behind_upstream =
    match upstream_status.behind_count with
      | Some count -> count > 0
      | None -> false
  in
  let binary_diverged =
    match built_matches_upstream, built_matches_runtime_repo with
    | Some false, _ | _, Some false -> true
    | _ -> false
  in
  let runtime_repo_snapshot_diverged =
    match runtime_repo_matches_server_repo, runtime_repo_matches_upstream with
    | Some false, _ | _, Some false -> true
    | _ -> false
  in
  let deployment_diverged =
    server_repo_behind_upstream
    || binary_diverged
    || runtime_repo_snapshot_diverged
  in
  let status =
    if source_mismatch || deployment_diverged
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
    ; ( "upstream"
      , `Assoc
          [ "branch", opt_string_json upstream_status.branch
          ; "ref", opt_string_json upstream_status.upstream_ref
          ; "head_commit", opt_string_json upstream_status.upstream_head_commit
          ; "ahead_count", opt_int_json upstream_status.ahead_count
          ; "behind_count", opt_int_json upstream_status.behind_count
          ; "source", `String "local_tracking_ref"
          ] )
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
          [ "commit", opt_string_json deployed_commit
          ; "source", opt_string_json deployed_commit_source
          ; ( "proof"
            , `String
                (if binary_commit_known
                 then "build_env_commit"
                 else "missing_binary_commit") )
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
          ; "deployed_matches_upstream", opt_bool_json deployed_matches_upstream
          ; "deployed_matches_runtime_repo", opt_bool_json deployed_matches_runtime_repo
          ; "runtime_repo_matches_merged", opt_bool_json runtime_repo_matches_server_repo
          ; "runtime_repo_matches_upstream", opt_bool_json runtime_repo_matches_upstream
          ; "built_matches_upstream", opt_bool_json built_matches_upstream
          ; "built_matches_runtime_repo", opt_bool_json built_matches_runtime_repo
          ; "server_repo_behind_upstream", `Bool server_repo_behind_upstream
          ; "source_mismatch", `Bool source_mismatch
          ] )
    ]
;;

let clear_git_rev_parse_short_cache_for_tests () =
  background_refresh_clear_unavailable_domains_for_tests ();
  Rev_parse_cache.clear_cache_for_tests ()
;;

let seed_git_rev_parse_short_cache_for_tests =
  Rev_parse_cache.seed_cache_for_tests

let clear_git_upstream_status_cache_for_tests () =
  background_refresh_clear_unavailable_domains_for_tests ();
  Upstream_status_cache.clear_cache_for_tests ()
;;

let seed_git_upstream_status_cache_for_tests =
  Upstream_status_cache.seed_cache_for_tests
;;

let path_item_json ~source path =
  `Assoc
    [ "path", `String path
    ; "exists", `Bool (String.trim path <> "" && Sys.file_exists path)
    ; "source", `String source
    ]
;;

let normalized_path_opt path =
  match String_util.trim_to_option path with
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

let normalized_path_segments path =
  let normalized = Env_config_core.normalize_path_lexically path in
  if String.equal normalized "/" || String.equal normalized "."
  then []
  else normalized |> String.split_on_char '/' |> List.filter (fun segment -> segment <> "")
;;

let rec segment_prefix ~prefix path =
  match prefix, path with
  | [], _ -> true
  | _ :: _, [] -> false
  | p :: ps, x :: xs -> String.equal p x && segment_prefix ~prefix:ps xs
;;

let same_or_descendant_normalized_path path expected =
  match normalized_path_opt path, normalized_path_opt expected with
  | Some path, Some expected ->
    segment_prefix
      ~prefix:(normalized_path_segments expected)
      (normalized_path_segments path)
  | _ -> false
;;

let server_workspace_mismatch ~server_repo_path (config : Workspace.config) =
  not
    (same_or_descendant_normalized_path server_repo_path config.workspace_path
     || same_or_descendant_normalized_path server_repo_path config.base_path)
;;

let server_workspace_mismatch_for_tests ~server_repo_path (config : Workspace.config) =
  match normalized_path_opt server_repo_path with
  | Some server_repo_path -> server_workspace_mismatch ~server_repo_path config
  | None -> false
;;

let shutdown_signal_of_message message =
  if String_util.contains_substring message "Received SIGTERM"
  then Some "SIGTERM"
  else if String_util.contains_substring message "Received SIGINT"
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
        when String_util.contains_substring
               message "repairing state and rewriting canonical JSON" ->
        Some
          (`Assoc
              [ "ts", `String entry.ts
              ; "kind", `String "state_repair"
              ; "message", `String message
              ])
      | None
        when String_util.contains_substring message "invalid agent JSON"
             || String_util.contains_substring message "repaired agent JSON"
             || String_util.contains_substring
                  message "parse error: Types_core.agent.last_seen" ->
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
         match Json_util.assoc_member_opt "kind" json with
         | Some (`String value) when String.equal value kind -> acc + 1
         | _ -> acc)
      0
      diagnostics
  in
  `List diagnostics, count "external_signal", count "state_repair", count "agent_state"
;;

type dashboard_runtime_provider_probe =
  { runtime_id : string
  ; json : Yojson.Safe.t
  ; status : string
  ; reachable : bool option
  ; skipped : bool
  }

let runtime_inventory_source = "runtime.toml"

let dashboard_runtime_probe_timeout_sec_float =
  Float.of_int dashboard_runtime_probe_timeout_sec
;;

let dashboard_runtime_trim_trailing_slashes raw =
  let raw = String.trim raw in
  let rec loop idx =
    if idx < 0
    then ""
    else if Char.equal raw.[idx] '/'
    then loop (idx - 1)
    else String.sub raw 0 (idx + 1)
  in
  loop (String.length raw - 1)
;;

let dashboard_runtime_append_probe_path base ~suffix =
  let base = dashboard_runtime_trim_trailing_slashes base in
  if String.equal base "" || String.ends_with ~suffix base
  then base
  else base ^ suffix
;;

let dashboard_runtime_probe_url ~(api_format : Runtime_schema.api_format) base_url =
  match api_format with
  | Runtime_schema.Ollama_api ->
    let base = dashboard_runtime_trim_trailing_slashes base_url in
    if String.ends_with ~suffix:"/api/tags" base
    then base
    else if String.ends_with ~suffix:"/api" base
    then base ^ "/tags"
    else base ^ "/api/tags"
  | Runtime_schema.Messages_api | Runtime_schema.Chat_completions_api ->
      dashboard_runtime_append_probe_path base_url ~suffix:"/models"
;;

let dashboard_runtime_url_for_json raw =
  let uri = Uri.of_string raw in
  Uri.with_uri ~userinfo:None ~query:None ~fragment:None uri |> Uri.to_string
;;

let dashboard_runtime_http_url_valid url =
  let uri = Uri.of_string url in
  match Option.map String.lowercase_ascii (Uri.scheme uri), Uri.host uri with
  | Some ("http" | "https"), Some host when String.trim host <> "" -> true
  | _ -> false
;;

let dashboard_runtime_provider_auth_kind = function
  | None -> "none"
  | Some (Runtime_schema.Env key) -> "env:" ^ key
  | Some (Runtime_schema.File path) -> "file:" ^ path
  | Some (Runtime_schema.Inline _) -> "inline"
;;

let dashboard_runtime_header_is_auth name =
  match String.lowercase_ascii (String.trim name) with
  | "authorization" | "x-api-key" | "api-key" | "x-auth-token" -> true
  | _ -> false
;;

let dashboard_runtime_non_auth_headers (provider : Runtime_schema.provider) =
  match provider.headers with
  | None -> []
  | Some headers ->
    List.filter (fun (name, _) -> not (dashboard_runtime_header_is_auth name)) headers
;;

let dashboard_runtime_credential_value = function
  | Runtime_schema.Env key ->
    (match Option.bind (Sys.getenv_opt key) String_util.trim_to_option with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "env credential %s is empty or unset" key))
  | Runtime_schema.File path ->
    (try
       match Fs_compat.load_file path |> String_util.trim_to_option with
       | Some value -> Ok value
       | None -> Error (Printf.sprintf "credential file %s is empty" path)
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn -> Error (Printf.sprintf "credential file %s: %s" path (Printexc.to_string exn)))
  | Runtime_schema.Inline value ->
    (match String_util.trim_to_option value with
     | Some value -> Ok value
     | None -> Error "inline credential is empty")
;;

let dashboard_runtime_probe_headers (provider : Runtime_schema.provider) =
  let base_headers =
    [ "Accept", "application/json" ] @ dashboard_runtime_non_auth_headers provider
  in
  match provider.credentials with
  | None -> Ok (false, base_headers)
  | Some credential ->
    (match dashboard_runtime_credential_value credential with
     | Ok value -> Ok (true, ("Authorization", "Bearer " ^ value) :: base_headers)
     | Error _ as error -> error)
;;

let dashboard_runtime_probe_transport_kind = function
  | Runtime_schema.Cli _ -> "cli"
  | Runtime_schema.Http url
    when Uri.of_string url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt ->
    "local"
  | Runtime_schema.Http _ -> "http"
;;

let dashboard_runtime_probe_http_get ~url ~headers ~timeout_sec =
  match Atomic.get dashboard_runtime_provider_http_get_hook with
  | Some hook -> hook ~url ~headers ~timeout_sec
  | None ->
    let clock = Eio_context.get_clock_opt () in
    (match Masc_http_client.get_response_sync ?clock ~timeout_sec ~url ~headers () with
     | Ok response -> Ok (response.status, response.headers, response.body)
     | Error _ as error -> error)
;;

let dashboard_runtime_header_value name headers =
  let name = String.lowercase_ascii name in
  headers
  |> List.find_map (fun (k, v) ->
    if String.equal name (String.lowercase_ascii k) then Some v else None)
;;

let dashboard_runtime_list_member_len key json =
  match Json_util.assoc_member_opt key json with
  | Some (`List items) -> Some (List.length items)
  | _ -> None
;;

let dashboard_runtime_model_count_of_body ~(api_format : Runtime_schema.api_format) body =
  try
    let json = Yojson.Safe.from_string body in
    match api_format with
    | Runtime_schema.Ollama_api -> dashboard_runtime_list_member_len "models" json
    | Runtime_schema.Messages_api | Runtime_schema.Chat_completions_api ->
      (match dashboard_runtime_list_member_len "data" json with
       | Some _ as value -> value
       | None -> dashboard_runtime_list_member_len "models" json)
  with
  | Yojson.Json_error _ -> None
;;

let dashboard_runtime_status_of_http_status = function
  | Some code when code >= 200 && code < 300 -> "reachable"
  | Some 401 | Some 403 -> "auth_failed"
  | Some 404 -> "endpoint_not_found"
  | Some code when code >= 500 -> "server_error"
  | Some _ -> "http_error"
  | None -> "unknown_http_status"
;;

let dashboard_runtime_provider_probe_json
    ?(http_get = dashboard_runtime_probe_http_get)
    (rt : Runtime.t)
  =
  let runtime_kind = dashboard_runtime_probe_transport_kind rt.provider.transport in
  let auth_kind = dashboard_runtime_provider_auth_kind rt.provider.credentials in
  let credential_required = Option.is_some rt.provider.credentials in
  let endpoint_url =
    match rt.provider.transport with
    | Runtime_schema.Http url -> Some (dashboard_runtime_url_for_json url)
    | Runtime_schema.Cli _ -> None
  in
  let base_fields
        ?probe_url
        ?http_status
        ?latency_ms
        ?model_count
        ?content_type
        ?downloaded_bytes
        ?error
        ~auth_present
        ~status
        ~reachable
        ()
    =
    [ "runtime_id", `String rt.id
    ; "provider_id", `String rt.provider.id
    ; "provider_display_name", `String rt.provider.display_name
    ; "model_id", `String rt.model.id
    ; "model_api_name", `String rt.model.api_name
    ; "protocol", `String rt.provider.protocol
    ; "runtime_kind", `String runtime_kind
    ; "transport", `String (match rt.provider.transport with Runtime_schema.Http _ -> "http" | Runtime_schema.Cli _ -> "cli")
    ; "auth_kind", `String auth_kind
    ; "credential_required", `Bool credential_required
    ; "auth_present", `Bool auth_present
    ; "status", `String status
    ; "reachable", (match reachable with Some value -> `Bool value | None -> `Null)
    ; "http_status", Json_util.int_opt_to_json http_status
    ; "latency_ms", Json_util.float_opt_to_json latency_ms
    ; "model_count", Json_util.int_opt_to_json model_count
    ; "content_type", Json_util.string_opt_to_json content_type
    ; "downloaded_bytes", Json_util.int_opt_to_json downloaded_bytes
    ; "endpoint_url", Json_util.string_opt_to_json endpoint_url
    ; "probe_url", Json_util.string_opt_to_json probe_url
    ; "error", Json_util.string_opt_to_json error
    ; "checked_at", `String (Masc_domain.now_iso ())
    ]
  in
  let make ?probe_url ?http_status ?latency_ms ?model_count ?content_type
      ?downloaded_bytes ?error ~auth_present ~status ~reachable ~skipped () =
    { json =
        `Assoc
          (base_fields
             ?probe_url
             ?http_status
             ?latency_ms
             ?model_count
             ?content_type
             ?downloaded_bytes
             ?error
             ~auth_present
             ~status
             ~reachable
             ())
    ; runtime_id = rt.id
    ; status
    ; reachable
    ; skipped
    }
  in
  match rt.provider.transport with
  | Runtime_schema.Cli _ ->
    make
      ~auth_present:false
      ~status:"skipped_cli"
      ~reachable:None
      ~skipped:true
      ~error:"CLI runtimes do not expose an HTTP reachability endpoint"
      ()
  | Runtime_schema.Http endpoint_url ->
    let probe_url = dashboard_runtime_probe_url ~api_format:rt.provider.api_format endpoint_url in
    let probe_url_json = dashboard_runtime_url_for_json probe_url in
    if not (dashboard_runtime_http_url_valid probe_url)
    then
      make
        ~probe_url:probe_url_json
        ~auth_present:false
        ~status:"invalid_endpoint"
        ~reachable:(Some false)
        ~skipped:false
        ~error:"runtime endpoint is not an absolute http(s) URL"
        ()
    else (
      match dashboard_runtime_probe_headers rt.provider with
      | Error error ->
        make
          ~probe_url:probe_url_json
          ~auth_present:false
          ~status:"missing_auth"
          ~reachable:(Some false)
          ~skipped:false
          ~error
          ()
      | Ok (auth_present, headers) ->
        let started_at = Time_compat.now () in
        (match
           http_get ~url:probe_url ~headers
             ~timeout_sec:dashboard_runtime_probe_timeout_sec_float
         with
         | Ok (http_status, response_headers, body) ->
           let latency_ms = (Time_compat.now () -. started_at) *. 1000.0 in
           let status = dashboard_runtime_status_of_http_status (Some http_status) in
           let reachable = http_status >= 200 && http_status < 300 in
           let model_count =
             if reachable
             then dashboard_runtime_model_count_of_body ~api_format:rt.provider.api_format body
             else None
           in
           make
             ~probe_url:probe_url_json
             ~http_status
             ~latency_ms
             ?model_count
             ?content_type:(dashboard_runtime_header_value "content-type" response_headers)
             ?downloaded_bytes:(Some (String.length body))
             ~auth_present
             ~status
             ~reachable:(Some reachable)
             ~skipped:false
             ()
         | Error error ->
           let latency_ms = (Time_compat.now () -. started_at) *. 1000.0 in
           make
             ~probe_url:probe_url_json
             ~latency_ms
             ~auth_present
             ~status:"network_error"
             ~reachable:(Some false)
             ~skipped:false
             ~error
             ()))
;;

let dashboard_runtime_probe_payload_json_of_runtimes ?default_id runtimes =
  (* Probe each runtime concurrently when a server switch is reachable (the
     production background-refresh fiber / boot warm, or a switch-bearing
     test). Each probe is an independent runtime/URL/HTTP connection with no
     shared mutable state, so the work is embarrassingly parallel and latency
     collapses from [sum latencies] to [max latencies] -- a dead runtime no
     longer serializes the probes after it.

     Concurrency goes through [Eio.Fiber.List.map], the established in-repo
     idiom for bounded parallel dashboard fan-out (see
     [Dashboard_execution]'s enrich_keeper_with_diagnostic). It (a) preserves
     input order, so the count / summary / errors invariants below stay
     byte-identical to the sequential branch; (b) runs the bodies on its OWN
     internal switch and re-raises any non-[Cancelled] exception at THIS call
     site, NOT on the ambient (server root) switch. That distinction matters
     because the probe body is NOT total: [dashboard_runtime_provider_probe_json]
     reaches [Masc_http_client]'s pool init ([Pool.create] / [register_pool]),
     which can raise [Invalid_argument] / [Eio.Mutex.Poisoned]. A bare
     [Eio.Fiber.fork ~sw] onto the root switch would let such a raise call
     [Switch.fail sw] and cancel sibling server background fibers; routing
     through [Fiber.List.map] instead degrades the whole batch to the caller's
     failure envelope ([maybe_fork_dashboard_runtime_probe_refresh]'s
     [| exception exn -> record_failure]) -- the same outcome the sequential
     [List.map] already produces, so the parallel path is no worse than
     sequential under a rogue exn. [Eio.Cancel.Cancelled] (server shutdown)
     still propagates. Bounded at [dashboard_runtime_probe_max_fibers].

     Without a switch (unit tests, no Eio scheduler) it falls back to a
     sequential [List.map] so deterministic ordering and test seams hold. *)
  let probes =
    match Eio_context.get_switch_opt () with
    | None -> List.map dashboard_runtime_provider_probe_json runtimes
    | Some _sw ->
      Eio.Fiber.List.map
        ~max_fibers:dashboard_runtime_probe_max_fibers
        dashboard_runtime_provider_probe_json
        runtimes
  in
  let count pred = probes |> List.filter pred |> List.length in
  let skipped = count (fun p -> p.skipped) in
  let reachable = count (fun p -> Option.equal Bool.equal p.reachable (Some true)) in
  let failed = count (fun p -> Option.equal Bool.equal p.reachable (Some false)) in
  let probed = List.length probes - skipped in
  let status =
    if failed = 0 && probed > 0
    then "reachable"
    else if failed = 0
    then "no_http_runtimes"
    else if reachable > 0
    then "degraded"
    else "unreachable"
  in
  let errors =
    probes
    |> List.filter_map (fun probe ->
      match probe.reachable with
      | Some false ->
        Some (Printf.sprintf "%s: %s" probe.runtime_id probe.status)
      | _ -> None)
  in
  `Assoc
    [ "source", `String runtime_inventory_source
    ; "status", `String status
    ; "probe_ok", `Bool (failed = 0)
    ; "checked_at", `String (Masc_domain.now_iso ())
    ; ( "summary"
      , `Assoc
          [ "runtimes", `Int (List.length runtimes)
          ; "probed", `Int probed
          ; "reachable", `Int reachable
          ; "failed", `Int failed
          ; "skipped", `Int skipped
          ; "default_runtime_id", Json_util.string_opt_to_json default_id
          ] )
    ; "providers", `List (List.map (fun p -> p.json) probes)
    ; "errors", Json_util.json_string_list errors
    ; ( "observations"
      , Json_util.json_string_list
          [ Printf.sprintf
              "runtime.toml provider reachability: %d reachable, %d failed, %d skipped"
              reachable
              failed
              skipped
          ] )
    ; "limitations"
      , Json_util.json_string_list
          [ "Probe checks provider metadata endpoints only; it does not send a completion request."
          ; "CLI runtimes are listed but not executed by the dashboard probe."
          ]
    ]
;;

let dashboard_runtime_probe_payload_json_for_tests ?default_id runtimes =
  dashboard_runtime_probe_payload_json_of_runtimes ?default_id runtimes
;;

let run_dashboard_runtime_probe () =
  match Atomic.get dashboard_runtime_probe_runner_hook with
  | Some hook -> hook ()
  | None ->
    let runtimes = Runtime.get_runtimes () in
    let default_id =
      Runtime.get_default_runtime () |> Option.map (fun (rt : Runtime.t) -> rt.id)
    in
    dashboard_runtime_probe_payload_json_of_runtimes ?default_id runtimes
;;

let dashboard_runtime_probe_degraded_envelope
      ~status ~error ~observation ~limitation () =
  (* Degraded probe envelope shared by the warming-up (cold start, no prior
     cache value) and unreachable paths. Keeps [probe_ok] false and every
     summary count zero so the dashboard surfaces a clear "no data yet" state
     rather than stalling the HTTP response. *)
  `Assoc
    [ "source", `String runtime_inventory_source
    ; "status", `String status
    ; "probe_ok", `Bool false
    ; "checked_at", `String (Masc_domain.now_iso ())
    ; ( "summary"
      , `Assoc
          [ "runtimes", `Int 0
          ; "probed", `Int 0
          ; "reachable", `Int 0
          ; "failed", `Int 0
          ; "skipped", `Int 0
          ; "default_runtime_id", `Null
          ] )
    ; "providers", `List []
    ; "errors", `List [ `String error ]
    ; "observations", `List [ `String observation ]
    ; "limitations", `List [ `String limitation ]
    ]
;;

let dashboard_runtime_probe_failure_envelope_of_exn (exn : exn) =
  (* Failure envelope persisted to the cache when a background refresh raises,
     so the dashboard surfaces the cause instead of masking it as a stale or
     warming-up value (failure-visibility contract). [Printexc.to_string]
     carries the exception message into the [errors] array; the next refresh
     after TTL expiry retries the probe. Pure function so the envelope shape is
     unit-testable independent of the cache/atomic plumbing. *)
  dashboard_runtime_probe_degraded_envelope
    ~status:"unreachable"
    ~error:(Printexc.to_string exn)
    ~observation:
      "Runtime probe background refresh failed; the value below is a failure \
       snapshot cached for the cache TTL window so the dashboard surfaces the \
       cause. The next refresh after TTL expiry retries the probe."
    ~limitation:"Cached failure envelope; a successful refresh replaces it."
    ()

let dashboard_runtime_probe_record_failure exn =
  (* Write the failure envelope to the cache (so subsequent reads within the
     TTL window see the cause) and release the single-flight CAS. [Atomic.set]
     never yields. *)
  Atomic.set
    dashboard_runtime_probe_cache
    (Some
       { probe = dashboard_runtime_probe_failure_envelope_of_exn exn
       ; refreshed_at = Time_compat.now ()
       });
  Atomic.set dashboard_runtime_probe_refresh_in_flight false
;;

let maybe_fork_dashboard_runtime_probe_refresh () =
  (* Trigger a background refresh of the runtime probe cache without ever
     blocking the caller. Single-flight via the
     [dashboard_runtime_probe_refresh_in_flight] CAS: if a refresh is already
     running, this is a no-op. On domains where a background [Eio.Fiber.fork]
     is not permitted (Domain_pool worker domains, or when no server switch is
     reachable), release the CAS and skip -- a subsequent request on the main
     domain will pick it up. [Atomic.set] never yields, so the in-flight flag
     is always cleared even when the forked fiber raises or is cancelled.

     This replaces the previous synchronous wait (up to
     [dashboard_runtime_probe_timeout_sec], i.e. 15s) that stalled the whole
     dashboard shell on every cache-miss poll and every force=1 request.
     Mirrors the git-rev-parse background-refresh pattern
     ([maybe_refresh_git_rev_parse_short_in_background]) already in this
     module. *)
  if Atomic.compare_and_set dashboard_runtime_probe_refresh_in_flight false true
  then begin
    if background_refresh_domain_unavailable () then
      Atomic.set dashboard_runtime_probe_refresh_in_flight false
    else
      match Eio_context.get_switch_opt () with
      | None -> Atomic.set dashboard_runtime_probe_refresh_in_flight false
      | Some sw ->
        let run () =
          match run_dashboard_runtime_probe () with
          | fresh ->
            let refreshed_at = Time_compat.now () in
            Atomic.set
              dashboard_runtime_probe_cache
              (Some { probe = fresh; refreshed_at });
            Atomic.set dashboard_runtime_probe_refresh_in_flight false
          | exception Eio.Cancel.Cancelled _ ->
            (* Switch cancelled (e.g. server shutdown): release CAS, do not
               cache. A shutdown is not a probe failure. *)
            Atomic.set dashboard_runtime_probe_refresh_in_flight false
          | exception exn ->
            (* Persist a failure envelope so the dashboard surfaces the cause
               instead of masking it as a stale or warming-up value
               (failure-visibility contract). Cached for the TTL window; the
               next refresh after expiry retries. Covers [Eio.Mutex.Poisoned]
               and any other exn -- [dashboard_runtime_probe_record_failure]
               writes the envelope and releases the CAS atomically. *)
            Log.Dashboard.warn
              "runtime probe background refresh failed: %s"
              (Printexc.to_string exn);
            dashboard_runtime_probe_record_failure exn
        in
        (try Eio.Fiber.fork ~sw run with
         | exn when eio_switch_fork_unavailable exn ->
           background_refresh_mark_domain_unavailable ();
           Atomic.set dashboard_runtime_probe_refresh_in_flight false
         | exn ->
           Atomic.set dashboard_runtime_probe_refresh_in_flight false;
           raise exn)
  end
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

(* Why this exists: force=1 callers (the dashboard "Live probe" button) expect an
   immediate fresh value, but the route is non-blocking — a cache miss schedules
   a background refresh and returns the best value available now. This tag makes
   that contract explicit in the response so the client can tell "this is the
   refreshed value" from "a refresh was scheduled; the next poll carries the new
   value", instead of inferring it from [cache_hit] alone. Closed sum so adding a
   freshness branch forces an exhaustive update of the serializer. *)
type dashboard_runtime_probe_refresh_state =
  | Refresh_fresh (* TTL-fresh cache hit (non-force); no background refresh triggered. *)
  | Refresh_recent
  (* force=1 within [dashboard_runtime_probe_force_min_refresh_sec]: the recent
     value is served and no new refresh is triggered (force rate limit). *)
  | Refresh_served_stale
  (* Cache miss with a stale value: the stale value is returned and a background
     refresh was scheduled; the next poll carries the fresh value. *)
  | Refresh_warming_up
(* Cold start (no cache value): a warming-up placeholder is returned and a
     background refresh was scheduled; the next poll carries the fresh value. *)

let dashboard_runtime_probe_refresh_state_to_string = function
  | Refresh_fresh -> "fresh"
  | Refresh_recent -> "recent"
  | Refresh_served_stale -> "served_stale"
  | Refresh_warming_up -> "warming_up"
;;

let dashboard_runtime_probe_http_json ?(force = false) () =
  let now = Time_compat.now () in
  let probe, cache_hit, refreshed_at, refresh_state =
    match
      if force
      then dashboard_runtime_probe_recent_value ~now
      else dashboard_runtime_probe_fresh_value ~now
    with
    | Some (cached, cached_at) ->
      (* Cache hit: a force=1 hit inside the recent-value window is rate-limited
         (no new refresh) and tagged [recent]; a plain TTL-fresh hit is [fresh].
         Stale-while-revalidate: even on a TTL-fresh (non-force) hit, once the
         cached value's age crosses the soft-TTL
         [dashboard_runtime_probe_soft_refresh_sec] we schedule a non-blocking
         background refresh. The single-flight CAS inside
         {!maybe_fork_dashboard_runtime_probe_refresh} makes this a no-op when a
         refresh is already running. This pre-warms the cache so the *next* poll
         sees a fresh value instead of letting cache expiry land on a poll (the
         TTL==poll-interval hit-rate-0 trap). The current response still serves
         the fresh value; the refresh is invisible to the client. *)
      let age = now -. cached_at in
      if (not force) && age > dashboard_runtime_probe_soft_refresh_sec
      then maybe_fork_dashboard_runtime_probe_refresh ();
      cached, true, cached_at, (if force then Refresh_recent else Refresh_fresh)
    | None ->
      (* Cache miss (or forced refresh past the recent window): trigger a
         non-blocking background refresh and return the best value available
         right now (stale cache, or a warming-up envelope on cold start). This
         removes the synchronous up-to-[dashboard_runtime_probe_timeout_sec]
         wait that previously stalled the dashboard shell on every cache-miss
         poll and on every force=1 request. [refresh_state] tells the client a
         refresh was scheduled, so a force=1 caller does not mistake the
         stale/warming-up value for an immediate fresh probe. *)
      maybe_fork_dashboard_runtime_probe_refresh ();
      (match dashboard_runtime_probe_cached_value () with
       | Some (stale, stale_at) -> stale, false, stale_at, Refresh_served_stale
       | None ->
         ( dashboard_runtime_probe_degraded_envelope
             ~status:"warming_up"
             ~error:"background probe in progress"
             ~observation:
               "Runtime probe is running in the background after a cold \
                start or cache expiry; the next poll returns the refreshed \
                value."
             ~limitation:
               "First response with no prior cache value returns this \
                placeholder until the background probe completes."
             (),
           false,
           0.0,
           Refresh_warming_up ))
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
    ; ( "refresh_state"
      , `String (dashboard_runtime_probe_refresh_state_to_string refresh_state) )
    ; "probe", probe
    ]
;;

let runtime_endpoint_url_of_transport = function
  | Runtime_schema.Http url -> Some url
  | Runtime_schema.Cli _ -> None
;;

let runtime_transport_string = function
  | Runtime_schema.Http _ -> "http"
  | Runtime_schema.Cli _ -> "cli"
;;

let runtime_http_transport_is_loopback url =
  Uri.of_string url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt
;;

let runtime_kind_of_transport = function
  | Runtime_schema.Cli _ -> "cli"
  | Runtime_schema.Http url when runtime_http_transport_is_loopback url -> "local"
  | Runtime_schema.Http _ -> "http"
;;

let runtime_dashboard_kind_of_runtime_kind = function
  | "local" -> "local"
  | "cli" -> "cli"
  | _ -> "cloud"
;;

let runtime_auth_kind_of_credential = function
  | None -> "none"
  | Some (Runtime_schema.Env key) -> "env:" ^ key
  | Some (Runtime_schema.File path) -> "file:" ^ path
  | Some (Runtime_schema.Inline _) -> "inline"
;;

let runtime_default_runtime_id () =
  Runtime.get_default_runtime () |> Option.map (fun (rt : Runtime.t) -> rt.id)
;;

(* Canonical wire strings for the thinking-control-format capability, matching
   the forms lib/runtime/runtime_toml.ml's parser accepts so the projection
   round-trips. Exhaustive by construction — a new variant fails to compile
   here rather than silently emitting a stale label. *)
let thinking_control_format_wire : Runtime_schema.thinking_control_format -> string = function
  | Runtime_schema.No_thinking_control -> "none"
  | Runtime_schema.Thinking_object -> "thinking-object"
  | Runtime_schema.Thinking_object_adaptive -> "thinking-object-adaptive"
  | Runtime_schema.Thinking_object_only -> "thinking-object-only"
  | Runtime_schema.Chat_template_kwargs -> "chat-template-kwargs"
  | Runtime_schema.Chat_template_token _ -> "chat-template-token"
  | Runtime_schema.Ollama_think -> "ollama-think"
  | Runtime_schema.Reasoning_effort -> "reasoning-effort"
  | Runtime_schema.Enable_thinking -> "enable-thinking"
;;

let preserve_thinking_control_format_wire
  : Llm_provider.Capabilities.preserve_thinking_control_format -> string
  = function
  | No_preserve_thinking_control -> "none"
  | Thinking_object_keep_all -> "thinking-object-keep-all"
  | Chat_template_kwargs_preserve_thinking -> "chat-template-kwargs-preserve-thinking"
  | Top_level_preserve_thinking -> "top-level-preserve-thinking"
  | Always_preserved_thinking -> "always-preserved-thinking"
;;

let assistant_tool_content_format_wire
  : Llm_provider.Capabilities.assistant_tool_content_format -> string
  = function
  | Assistant_tool_content_null -> "null"
  | Assistant_tool_content_empty_string -> "empty-string"
;;

let reasoning_output_format_wire : Llm_provider.Capabilities.reasoning_output_format -> string =
  function
  | No_reasoning_output_format -> "none"
  | Split_reasoning_fields -> "split-reasoning-fields"
;;

let reasoning_streaming_format_json
  : Llm_provider.Capabilities.reasoning_streaming_format -> Yojson.Safe.t
  = function
  | Default_reasoning_streaming -> `Assoc [ "kind", `String "default" ]
  | No_reasoning_streaming -> `Assoc [ "kind", `String "none" ]
  | Delta_reasoning_field field ->
    `Assoc [ "kind", `String "delta-reasoning-field"; "field", `String field ]
  | Template_reasoning_streaming -> `Assoc [ "kind", `String "template" ]
;;

let reasoning_replay_override_wire
  : Llm_provider.Capabilities.reasoning_replay_override -> string
  = function
  | Default_reasoning_replay -> "default"
  | Force_no_replay -> "force-no-replay"
  | Force_drop_without_tool_preserve_with_tool -> "drop-without-tool-preserve-with-tool"
  | Force_preserve_always -> "preserve-always"
;;

let task_json : Llm_provider.Capabilities.task option -> Yojson.Safe.t = function
  | None -> `Null
  | Some Transcription -> `String "transcription"
  | Some Speech -> `String "speech"
  | Some Image_generation -> `String "image-generation"
  | Some Video_generation -> `String "video-generation"
;;

let modality_priority_wire : Llm_provider.Modality.priority -> string = function
  | Preserve_input_order -> "preserve-input-order"
  | Visual_first -> "visual-first"
;;

let tool_choice_json : Llm_provider.Types.tool_choice option -> Yojson.Safe.t = function
  | None -> `Null
  | Some Llm_provider.Types.Auto -> `Assoc [ "kind", `String "auto" ]
  | Some Llm_provider.Types.Any -> `Assoc [ "kind", `String "required" ]
  | Some Llm_provider.Types.None_ -> `Assoc [ "kind", `String "none" ]
  | Some (Llm_provider.Types.Tool name) ->
    `Assoc [ "kind", `String "tool"; "name", `String name ]
;;

let response_format_json : Llm_provider.Types.response_format -> Yojson.Safe.t = function
  | Llm_provider.Types.Off -> `Assoc [ "kind", `String "off"; "has_schema", `Bool false ]
  | Llm_provider.Types.JsonMode ->
    `Assoc [ "kind", `String "json_mode"; "has_schema", `Bool false ]
  | Llm_provider.Types.JsonSchema _ ->
    `Assoc [ "kind", `String "json_schema"; "has_schema", `Bool true ]
;;

let runtime_request_config_json (rt : Runtime.t) =
  let cfg = rt.provider_config in
  `Assoc
    [ "source", `String "oas-provider-config"
    ; "provider_kind", `String (Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
    ; "request_path", `String cfg.request_path
    ; ( "request_path_targets_responses_api"
      , `Bool (Llm_provider.Provider_config.request_path_targets_responses_api cfg.request_path)
      )
    ; "max_tokens", Json_util.int_opt_to_json cfg.max_tokens
    ; "max_context", Json_util.int_opt_to_json cfg.max_context
    ; "temperature", Json_util.float_opt_to_json cfg.temperature
    ; "top_p", Json_util.float_opt_to_json cfg.top_p
    ; "top_k", Json_util.int_opt_to_json cfg.top_k
    ; "min_p", Json_util.float_opt_to_json cfg.min_p
    ; "has_system_prompt", `Bool (Option.is_some cfg.system_prompt)
    ; "enable_thinking", Json_util.bool_opt_to_json cfg.enable_thinking
    ; "preserve_thinking", Json_util.bool_opt_to_json cfg.preserve_thinking
    ; "thinking_budget", Json_util.int_opt_to_json cfg.thinking_budget
    ; "clear_thinking", Json_util.bool_opt_to_json cfg.clear_thinking
    ; ( "resolved_reasoning_effort"
      , Json_util.string_opt_to_json
          (Llm_provider.Provider_config.reasoning_effort_request_value
             ~enable_thinking:cfg.enable_thinking
             ~thinking_budget:cfg.thinking_budget) )
    ; "glm_clear_thinking", `Bool (Llm_provider.Provider_config.glm_clear_thinking cfg)
    ; "glm_replay_reasoning", `Bool (Llm_provider.Provider_config.glm_should_replay_reasoning cfg)
    ; "tool_stream", `Bool cfg.tool_stream
    ; "tool_choice", tool_choice_json cfg.tool_choice
    ; "disable_parallel_tool_use", `Bool cfg.disable_parallel_tool_use
    ; "response_format", response_format_json cfg.response_format
    ; "has_output_schema", `Bool (Option.is_some cfg.output_schema)
    ; "cache_system_prompt", `Bool cfg.cache_system_prompt
    ; "supports_tool_choice_override", Json_util.bool_opt_to_json cfg.supports_tool_choice_override
    ; ( "supports_structured_output_override"
      , Json_util.bool_opt_to_json cfg.supports_structured_output_override )
    ; "has_model_capabilities_override", `Bool (Option.is_some cfg.model_capabilities_override)
    ; "keep_alive", Json_util.string_opt_to_json cfg.keep_alive
    ; "internal_model_rotation_count", Json_util.int_opt_to_json cfg.internal_model_rotation_count
    ; "num_ctx", Json_util.int_opt_to_json cfg.num_ctx
    ; "seed", Json_util.int_opt_to_json cfg.seed
    ; "has_previous_response_id", `Bool (Option.is_some cfg.previous_response_id)
    ; "connect_timeout_s", Json_util.float_opt_to_json cfg.connect_timeout_s
    ]
;;

let runtime_api_format_wire : Runtime_schema.api_format -> string = function
  | Runtime_schema.Messages_api -> "messages"
  | Runtime_schema.Chat_completions_api -> "chat-completions"
  | Runtime_schema.Ollama_api -> "ollama"
;;

let runtime_provider_behavior_capabilities_json
    (capabilities : Runtime_schema.capabilities option) =
  match capabilities with
  | None -> `Null
  | Some caps ->
    `Assoc
      [ "supports_inline_tools", `Bool caps.supports_inline_tools
      ; ( "requires_per_keeper_bridging_for_bound_actor_tools"
        , `Bool caps.requires_per_keeper_bridging_for_bound_actor_tools )
      ; ( "identity_runtime_mcp_header_keys"
        , Json_util.json_string_list caps.identity_runtime_mcp_header_keys )
      ; "argv_prompt_preflight", `Bool caps.argv_prompt_preflight
      ; "uses_anthropic_caching", `Bool caps.uses_anthropic_caching
      ; "max_turns_per_attempt", Json_util.int_opt_to_json caps.max_turns_per_attempt
      ; "tolerates_bound_actor_fallback", `Bool caps.tolerates_bound_actor_fallback
      ]
;;

let runtime_declared_model_capabilities_json
    (capabilities : Runtime_schema.model_capabilities option) =
  match capabilities with
  | None -> `Null
  | Some caps ->
    `Assoc
      [ "source", `String runtime_inventory_source
      ; "max_output_tokens", Json_util.int_opt_to_json caps.max_output_tokens
      ; "supports_tool_choice", `Bool caps.supports_tool_choice
      ; "supports_required_tool_choice", `Bool caps.supports_required_tool_choice
      ; "supports_named_tool_choice", `Bool caps.supports_named_tool_choice
      ; "supports_parallel_tool_calls", `Bool caps.supports_parallel_tool_calls
      ; "supports_extended_thinking", `Bool caps.supports_extended_thinking
      ; "supports_reasoning_budget", `Bool caps.supports_reasoning_budget
      ; "thinking_control_format", `String (thinking_control_format_wire caps.thinking_control_format)
      ; "supports_image_input", `Bool caps.supports_image_input
      ; "supports_audio_input", `Bool caps.supports_audio_input
      ; "supports_video_input", `Bool caps.supports_video_input
      ; "supports_multimodal_inputs", `Bool caps.supports_multimodal_inputs
      ; "supports_response_format_json", `Bool caps.supports_response_format_json
      ; "supports_structured_output", `Bool caps.supports_structured_output
      ; "supports_native_streaming", `Bool caps.supports_native_streaming
      ; "supports_system_prompt", `Bool caps.supports_system_prompt
      ; "supports_caching", `Bool caps.supports_caching
      ; "supports_prompt_caching", `Bool caps.supports_prompt_caching
      ; "prompt_cache_alignment", Json_util.int_opt_to_json caps.prompt_cache_alignment
      ; "supports_top_k", `Bool caps.supports_top_k
      ; "supports_min_p", `Bool caps.supports_min_p
      ; "supports_seed", `Bool caps.supports_seed
      ; "supports_seed_with_images", `Bool caps.supports_seed_with_images
      ; "emits_usage_tokens", `Bool caps.emits_usage_tokens
      ; "supports_computer_use", `Bool caps.supports_computer_use
      ; "supports_code_execution", `Bool caps.supports_code_execution
      ]
;;

let runtime_declared_spec_json (rt : Runtime.t) =
  `Assoc
    [ "source", `String runtime_inventory_source
    ; ( "provider"
      , `Assoc
          [ "id", `String rt.provider.id
          ; "display_name", `String rt.provider.display_name
          ; "protocol", `String rt.provider.protocol
          ; "api_format", `String (runtime_api_format_wire rt.provider.api_format)
          ; "transport", `String (runtime_transport_string rt.provider.transport)
          ; "auth_kind", `String (runtime_auth_kind_of_credential rt.provider.credentials)
          ; "is_non_interactive", `Bool rt.provider.is_non_interactive
          ; "has_capabilities", `Bool (Option.is_some rt.provider.capabilities)
          ; ( "behavior_capabilities"
            , runtime_provider_behavior_capabilities_json rt.provider.capabilities )
          ; ( "custom_header_count"
            , `Int
                (match rt.provider.headers with
                 | None -> 0
                 | Some headers -> List.length headers) )
          ; "connect_timeout_s", Json_util.float_opt_to_json rt.provider.connect_timeout_s
          ] )
    ; ( "model"
      , `Assoc
          [ "id", `String rt.model.id
          ; "api_name", `String rt.model.api_name
          ; "tools_support", `Bool rt.model.tools_support
          ; "max_context", `Int rt.model.max_context
          ; "thinking_support", `Bool rt.model.thinking_support
          ; "preserve_thinking", Json_util.bool_opt_to_json rt.model.preserve_thinking
          ; "max_thinking_budget", Json_util.int_opt_to_json rt.model.max_thinking_budget
          ; "streaming", `Bool rt.model.streaming
          ; "temperature", Json_util.float_opt_to_json rt.model.temperature
          ; "top_p", Json_util.float_opt_to_json rt.model.top_p
          ; "top_k", Json_util.int_opt_to_json rt.model.top_k
          ; "min_p", Json_util.float_opt_to_json rt.model.min_p
          ; "capabilities", runtime_declared_model_capabilities_json rt.model.capabilities
          ; "match_prefixes", Json_util.json_string_list rt.model.match_prefixes
          ] )
    ; ( "binding"
      , `Assoc
          [ "provider_id", `String rt.binding.provider_id
          ; "model_id", `String rt.binding.model_id
          ; "is_default", `Bool rt.binding.is_default
          ; "max_concurrent", Json_util.int_opt_to_json rt.binding.max_concurrent
          ; "price_input", Json_util.float_opt_to_json rt.binding.price_input
          ; "price_output", Json_util.float_opt_to_json rt.binding.price_output
          ; "keep_alive", Json_util.string_opt_to_json rt.binding.keep_alive
          ; "num_ctx", Json_util.int_opt_to_json rt.binding.num_ctx
          ] )
    ]
;;

let effective_capabilities_json (rt : Runtime.t) =
  match Llm_provider.Provider_config.capabilities_for_config_model rt.provider_config with
  | None -> `Null
  | Some caps ->
    let accepted_reasoning_efforts =
      match caps.accepted_reasoning_efforts with
      | None -> `Null
      | Some efforts ->
        efforts
        |> List.map Llm_provider.Reasoning_effort.to_string
        |> Json_util.json_string_list
    in
    let supported_models =
      match caps.supported_models with
      | None -> `Null
      | Some models -> Json_util.json_string_list models
    in
    `Assoc
      [ "source", `String "oas-provider-config-model"
      ; "max_context_tokens", Json_util.int_opt_to_json caps.max_context_tokens
      ; "max_output_tokens", Json_util.int_opt_to_json caps.max_output_tokens
      ; "supports_tools", `Bool caps.supports_tools
      ; "supports_tool_choice", `Bool caps.supports_tool_choice
      ; "supports_required_tool_choice", `Bool caps.supports_required_tool_choice
      ; "supports_named_tool_choice", `Bool caps.supports_named_tool_choice
      ; "supports_parallel_tool_calls", `Bool caps.supports_parallel_tool_calls
      ; "supports_runtime_mcp_tools", `Bool caps.supports_runtime_mcp_tools
      ; "supports_runtime_tool_events", `Bool caps.supports_runtime_tool_events
      ; ( "assistant_tool_content_format"
        , `String (assistant_tool_content_format_wire caps.assistant_tool_content_format) )
      ; "supports_reasoning", `Bool caps.supports_reasoning
      ; "supports_extended_thinking", `Bool caps.supports_extended_thinking
      ; "supports_reasoning_budget", `Bool caps.supports_reasoning_budget
      ; "accepted_reasoning_efforts", accepted_reasoning_efforts
      ; "thinking_control_format", `String (thinking_control_format_wire caps.thinking_control_format)
      ; ( "preserve_thinking_control_format"
        , `String (preserve_thinking_control_format_wire caps.preserve_thinking_control_format)
        )
      ; "reasoning_output_format", `String (reasoning_output_format_wire caps.reasoning_output_format)
      ; "reasoning_streaming_format", reasoning_streaming_format_json caps.reasoning_streaming_format
      ; "reasoning_replay_override", `String (reasoning_replay_override_wire caps.reasoning_replay_override)
      ; "supports_response_format_json", `Bool caps.supports_response_format_json
      ; "supports_structured_output", `Bool caps.supports_structured_output
      ; "supports_multimodal_inputs", `Bool caps.supports_multimodal_inputs
      ; "supports_image_input", `Bool caps.supports_image_input
      ; "supports_audio_input", `Bool caps.supports_audio_input
      ; "supports_video_input", `Bool caps.supports_video_input
      ; "modality_priority", `String (modality_priority_wire caps.modality_priority)
      ; "task", task_json caps.task
      ; "supports_native_streaming", `Bool caps.supports_native_streaming
      ; "supports_system_prompt", `Bool caps.supports_system_prompt
      ; "supports_caching", `Bool caps.supports_caching
      ; "supports_prompt_caching", `Bool caps.supports_prompt_caching
      ; "prompt_cache_alignment", Json_util.int_opt_to_json caps.prompt_cache_alignment
      ; "supports_top_k", `Bool caps.supports_top_k
      ; "supports_min_p", `Bool caps.supports_min_p
      ; "supports_seed", `Bool caps.supports_seed
      ; "supports_seed_with_images", `Bool caps.supports_seed_with_images
      ; ( "ignored_sampling_parameters"
        , caps.ignored_sampling_parameters
          |> List.map Llm_provider.Capabilities.sampling_parameter_to_string
          |> Json_util.json_string_list )
      ; "supports_computer_use", `Bool caps.supports_computer_use
      ; "supports_code_execution", `Bool caps.supports_code_execution
      ; "emits_usage_tokens", `Bool caps.emits_usage_tokens
      ; "supported_models", supported_models
      ]
;;

let runtime_parameter_policy_json (rt : Runtime.t) =
  let module RD = Llm_provider.Reasoning_dialect in
  let sampling_parameter_json_list values =
    values
    |> List.map Llm_provider.Capabilities.sampling_parameter_to_string
    |> Json_util.json_string_list
  in
  let dialect = RD.for_provider_config rt.provider_config in
  let sampling_candidates = RD.sampling_params_ignored_when_thinking dialect in
  let ignored_sampling_params =
    List.filter
      (fun field -> RD.ignores_sampling_param dialect ~enable_thinking:None field)
      sampling_candidates
  in
  let always_ignored_sampling_params =
    List.filter
      (fun field -> RD.ignores_sampling_param dialect ~enable_thinking:(Some false) field)
      sampling_candidates
  in
  `Assoc
    [ "reasoning_toggle_wire", `String (RD.toggle_wire_to_string dialect.toggle_wire)
    ; "reasoning_replay_policy", `String (RD.replay_policy_to_string dialect.replay_policy)
    ; "requires_reasoning_replay_on_tool_call", `Bool (RD.requires_reasoning_replay_on_tool_call dialect)
    ; "ignored_sampling_params", sampling_parameter_json_list ignored_sampling_params
    ; ( "always_ignored_sampling_params"
      , sampling_parameter_json_list always_ignored_sampling_params )
    ]
;;

let runtime_inventory_entry_json ~default_id (rt : Runtime.t) =
  let runtime_kind = runtime_kind_of_transport rt.provider.transport in
  let models = [ rt.model.api_name ] in
  let capabilities_declared, caps =
    match rt.model.capabilities with
    | Some caps -> true, caps
    | None ->
      ( false
      , Runtime_schema.model_capabilities_default
        (* DET-OK: absent [models.<id>.capabilities] is exposed below as
           [capabilities_declared=false]; the all-false record only keeps this
           read-only dashboard projection total, it is not a policy default. *) )
  in
  `Assoc
    [ "provider", `String rt.id
    ; "runtime_id", `String rt.id
    ; "provider_id", `String rt.provider.id
    ; "provider_display_name", `String rt.provider.display_name
    ; "model_id", `String rt.model.id
    ; "model_api_name", `String rt.model.api_name
    ; "protocol", `String rt.provider.protocol
    ; "transport", `String (runtime_transport_string rt.provider.transport)
    ; "kind", `String (runtime_dashboard_kind_of_runtime_kind runtime_kind)
    ; "runtime_kind", `String runtime_kind
    ; "auth_kind", `String (runtime_auth_kind_of_credential rt.provider.credentials)
    ; "status", `String "configured"
    ; "available", `Bool true
    ; "is_default_runtime", `Bool (Option.equal String.equal default_id (Some rt.id))
    ; "max_context", `Int rt.model.max_context
    ; "tools_support", `Bool rt.model.tools_support
    ; "thinking_support", `Bool rt.model.thinking_support
    ; "streaming", `Bool rt.model.streaming
      (* Per-model sampling temperature override ([models.<id>].temperature).
         [`Null] when unset (the runtime keeps the fleet fallback). Read-only
         projection for the dashboard runtime capability card. *)
    ; ( "temperature"
      , match rt.model.temperature with
        | Some t -> `Float t
        | None -> `Null )
    ; "top_p", Json_util.float_opt_to_json rt.model.top_p
    ; "top_k", Json_util.int_opt_to_json rt.model.top_k
    ; "min_p", Json_util.float_opt_to_json rt.model.min_p
      (* Additive capability projection for dashboard runtime snapshot cards.
         These mirrors are declared model capabilities from runtime.toml only;
         [capabilities_declared=false] below keeps the all-false fallback from
         being mistaken for provider/model inference. *)
    ; "capabilities_declared", `Bool capabilities_declared
    ; "max_output_tokens", Json_util.int_opt_to_json caps.max_output_tokens
    ; "supports_tool_choice", `Bool caps.supports_tool_choice
    ; "supports_required_tool_choice", `Bool caps.supports_required_tool_choice
    ; "supports_named_tool_choice", `Bool caps.supports_named_tool_choice
    ; "supports_parallel_tool_calls", `Bool caps.supports_parallel_tool_calls
    ; "supports_extended_thinking", `Bool caps.supports_extended_thinking
    ; "supports_multimodal_inputs", `Bool caps.supports_multimodal_inputs
    ; "supports_image_input", `Bool caps.supports_image_input
    ; "supports_audio_input", `Bool caps.supports_audio_input
    ; "supports_video_input", `Bool caps.supports_video_input
    ; "supports_reasoning_budget", `Bool caps.supports_reasoning_budget
    ; "thinking_control_format", `String (thinking_control_format_wire caps.thinking_control_format)
    ; "supports_response_format_json", `Bool caps.supports_response_format_json
    ; "supports_structured_output", `Bool caps.supports_structured_output
    ; "supports_native_streaming", `Bool caps.supports_native_streaming
    ; "supports_system_prompt", `Bool caps.supports_system_prompt
    ; "supports_caching", `Bool caps.supports_caching
    ; "supports_prompt_caching", `Bool caps.supports_prompt_caching
    ; "prompt_cache_alignment", Json_util.int_opt_to_json caps.prompt_cache_alignment
    ; "supports_top_k", `Bool caps.supports_top_k
    ; "supports_min_p", `Bool caps.supports_min_p
    ; "supports_seed", `Bool caps.supports_seed
    ; "supports_seed_with_images", `Bool caps.supports_seed_with_images
    ; "emits_usage_tokens", `Bool caps.emits_usage_tokens
    ; "supports_computer_use", `Bool caps.supports_computer_use
    ; "supports_code_execution", `Bool caps.supports_code_execution
    ; "effective_capabilities", effective_capabilities_json rt
    ; "parameter_policy", runtime_parameter_policy_json rt
    ; "request_config", runtime_request_config_json rt
    ; "declared_spec", runtime_declared_spec_json rt
    ; "model_count", `Int (List.length models)
    ; "models", Json_util.json_string_list models
    ; "source", `String runtime_inventory_source
    ; "endpoint_url", Json_util.string_opt_to_json (runtime_endpoint_url_of_transport rt.provider.transport)
    ; "note", `Null
    ]
;;

let runtime_unique_count values =
  values |> List.sort_uniq String.compare |> List.length
;;

let runtime_assignment_governance_json ~default_id =
  let assignments =
    Runtime.keeper_assignments ()
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  in
  let assignment_count = List.length assignments in
  let assigned_runtime_ids = List.map snd assignments in
  let assigned_runtimes = List.sort_uniq String.compare assigned_runtime_ids in
  let assigned_runtime_count = List.length assigned_runtimes in
  let default_assignment_count =
    match default_id with
    | None -> 0
    | Some default_id ->
      assignments
      |> List.filter (fun (_, runtime_id) -> String.equal runtime_id default_id)
      |> List.length
  in
  let librarian_runtime_id = Runtime.librarian_runtime_id () in
  let single_runtime_pin = assignment_count > 1 && assigned_runtime_count = 1 in
  let assignments_match_default =
    assignment_count > 0 && default_assignment_count = assignment_count
  in
  let add_if condition warning warnings =
    if condition then warning :: warnings else warnings
  in
  let warnings =
    []
    |> add_if (assignment_count > 0) "explicit_assignments_present"
    |> add_if single_runtime_pin "single_runtime_assignment_pin"
    |> add_if assignments_match_default "assignments_match_default_runtime"
    |> add_if (Option.is_some librarian_runtime_id) "librarian_runtime_override"
    |> List.rev
  in
  let status =
    if warnings = []
    then "ok"
    else if single_runtime_pin || assignments_match_default || Option.is_some librarian_runtime_id
    then "degraded"
    else "watch"
  in
  `Assoc
    [ "schema", `String "masc.runtime_assignment_governance.v1"
    ; "source", `String runtime_inventory_source
    ; "status", `String status
    ; "degraded", `Bool (String.equal status "degraded")
    ; "operator_action_required", `Bool (warnings <> [])
    ; "blast_radius",
      `String
        (if assignment_count = 0
         then "default_runtime_only"
         else if single_runtime_pin
         then "single_runtime_assignment_pin"
         else "mixed_runtime_assignments")
    ; "assignment_count", `Int assignment_count
    ; "assigned_runtime_count", `Int assigned_runtime_count
    ; "default_assignment_count", `Int default_assignment_count
    ; "default_runtime_id", Json_util.string_opt_to_json default_id
    ; "librarian_runtime_id", Json_util.string_opt_to_json librarian_runtime_id
    ; "warnings", Json_util.json_string_list warnings
    ; "assigned_runtimes", Json_util.json_string_list assigned_runtimes
    ; ( "assignments"
      , `List
          (List.map
             (fun (keeper_name, runtime_id) ->
                `Assoc
                  [ "keeper", `String keeper_name
                  ; "runtime_id", `String runtime_id
                  ; ( "matches_default"
                    , `Bool (Option.equal String.equal default_id (Some runtime_id)) )
                  ])
             assignments) )
    ]
;;

let governance_hitl_json () =
  (* doc-03 P0#1 acceptance: surface whether human-in-the-loop approval is active
     and why, so an operator can confirm the fail-closed default at runtime instead
     of inferring it from the environment. [Env_config_core.disable_hitl] reads
     MASC_DISABLE_HITL with a fail-closed [~default:false] — HITL stays enabled
     unless an operator explicitly disables it; the thresholds mirror
     [Governance_pipeline] so the "why" travels with the "whether". *)
  let enabled = not (Env_config_core.disable_hitl ()) in
  let threshold_json resolver =
    match resolver "production" with
    | Some level -> `String (Governance_pipeline.risk_level_to_string level)
    | None -> `Null
  in
  `Assoc
    [ "schema", `String "masc.governance_hitl.v1"
    ; "enabled", `Bool enabled
    ; "disable_env_key", `String Env_config_core.disable_hitl_env_key
    ; "default_when_unset", `String "enabled"
    ; ( "production_confirm_threshold"
      , threshold_json Governance_pipeline.confirm_threshold )
    ; ( "keeper_production_confirm_threshold"
      , threshold_json Governance_pipeline.keeper_confirm_threshold )
    ; ( "reason"
      , `String
          (if enabled
           then "human approval required for high/critical actions (fail-closed default)"
           else
             "human approval gates disabled via " ^ Env_config_core.disable_hitl_env_key) )
    ]
;;

let runtime_inventory_json () =
  let runtimes = Runtime.get_runtimes () in
  let default_id = runtime_default_runtime_id () in
  let kind_of_runtime (rt : Runtime.t) =
    runtime_kind_of_transport rt.provider.transport
    |> runtime_dashboard_kind_of_runtime_kind
  in
  let count_models kind =
    runtimes
    |> List.filter (fun rt -> String.equal (kind_of_runtime rt) kind)
    |> List.length
  in
  let provider_ids = List.map (fun (rt : Runtime.t) -> rt.provider.id) runtimes in
  `Assoc
    [ "updated_at", `String (Masc_domain.now_iso ())
    ; "source", `String runtime_inventory_source
    ; "config_path", Json_util.string_opt_to_json (Runtime.config_path ())
    ; ( "startup_degradation"
      , Runtime.startup_degradation_to_yojson (Runtime.startup_degradation ()) )
    ; ( "summary"
      , `Assoc
          [ "providers", `Int (runtime_unique_count provider_ids)
          ; "runtimes", `Int (List.length runtimes)
          ; "local_models", `Int (count_models "local")
          ; "cloud_models", `Int (count_models "cloud")
          ; "cli_models", `Int (count_models "cli")
          ; "default_runtime_id", Json_util.string_opt_to_json default_id
          ] )
    ; "assignment_governance", runtime_assignment_governance_json ~default_id
    ; "providers", `List (List.map (runtime_inventory_entry_json ~default_id) runtimes)
    ]
;;

let runtime_resolution_json (config : Workspace.config) =
  let build = Build_identity.current () in
  let runtime_commit = build.binary_commit in
  let runtime_commit_known = Option.is_some runtime_commit in
  let server_repo_path = Build_identity.repo_root () in
  let server_repo_commit = Option.bind server_repo_path git_rev_parse_short in
  let upstream_status =
    Option.bind server_repo_path git_upstream_status
    |> Option.value ~default:empty_git_upstream_status
  in
  let workspace_commit = git_rev_parse_short config.workspace_path in
  let resolved_base_commit = git_rev_parse_short config.base_path in
  let base_path_input =
    (* SSOT: Env_config_core.base_path_source_opt prefers
       MASC_BASE_PATH_INPUT over MASC_BASE_PATH, preserving an
       operator's raw "<base>/.masc" input.
       Host_config.base_path_raw only reads MASC_BASE_PATH and strips
       a preserved ".masc" suffix when both env vars are set.
       RFC-0085 PR-9 keeps the raw helper private, so use
       base_path_source_opt's value component.
       Test: "runtime base_path preserves raw input"
       (test/test_dashboard_http_core.ml:260). *)
    Env_config_core.base_path_source_opt ()
    |> Option.map snd
    |> Option.value ~default:config.workspace_path
  in
  let prompt_markdown_dir =
    Prompt_registry.get_markdown_dir ()
    |> Option.value ~default:(Config_dir_resolver.prompts_dir ())
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
    | Some server_repo_path -> server_workspace_mismatch ~server_repo_path config
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
         marker itself so the warning is self-contained. *)
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
      "Runtime binary commit is unknown; runtime_repo_head_commit is only the \
       checkout HEAD snapshot captured by the running process and must not be \
       treated as binary/deploy proof."
      :: acc
    else acc
  in
  let add_runtime_repo_snapshot_drift_warning acc =
    if runtime_commit_known
    then acc
    else
      match build.repo_head_commit, server_repo_commit with
      | Some runtime_head, Some server_head when not (String.equal runtime_head server_head)
        ->
        Printf.sprintf
          "Runtime source snapshot (%s) differs from server repo HEAD (%s), \
           but the binary commit is unknown. Rebuild/restart before trusting \
           runtime identity."
          runtime_head
          server_head
        :: acc
      | _ -> acc
  in
  let add_upstream_drift_warning acc =
    match upstream_status.behind_count, upstream_status.upstream_head_commit with
    | Some behind, Some upstream when behind > 0 ->
      let deployed =
        match build.binary_commit, build.repo_head_commit with
        | Some commit, _ -> "binary " ^ commit
        | None, Some commit -> "runtime source snapshot " ^ commit
        | None, None -> "unknown binary commit"
      in
      let branch =
        Option.value ~default:"detached" upstream_status.branch
      in
      let upstream_ref =
        Option.value ~default:"upstream" upstream_status.upstream_ref
      in
      Printf.sprintf
        "Server source branch %s is behind %s by %d commit(s); running runtime \
         identity (%s) differs from upstream %s. Fetch/build/restart from \
         current main before trusting runtime identity."
        branch
        upstream_ref
        behind
        deployed
        upstream
      :: acc
    | _ -> acc
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
    then Printf.sprintf "Recent workspace-state repair events detected (%d)." repair_count :: acc
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
    |> add_runtime_repo_snapshot_drift_warning
    |> add_upstream_drift_warning
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
      ; "data_root", path_item_json ~source:"runtime_data" (Workspace.masc_root_dir config)
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
            ~resolved_base_commit ~upstream_status ~source_mismatch )
      ; "governance_hitl", governance_hitl_json ()
      ]
      @ Server_routes_http_runtime.keeper_fleet_runtime_resolution_fields () )
;;

let light_runtime_resolution_json (config : Workspace.config) =
  let build = Build_identity.current () in
  let base_path_input =
    Env_config_core.base_path_source_opt ()
    |> Option.map snd
    |> Option.value ~default:config.workspace_path
  in
  let prompt_markdown_dir =
    Prompt_registry.get_markdown_dir ()
    |> Option.value ~default:(Config_dir_resolver.prompts_dir ())
  in
  let server_repo_path = Build_identity.repo_root () in
  let server_workspace_mismatch =
    match Option.bind server_repo_path normalized_path_opt with
    | Some server_repo_path -> server_workspace_mismatch ~server_repo_path config
    | None -> false
  in
  let fleet_fields =
    Server_routes_http_runtime.keeper_fleet_runtime_resolution_light_fields ()
  in
  let fleet_safety =
    match List.assoc_opt "keeper_fleet_safety" fleet_fields with
    | Some ((`Assoc _) as json) -> Some json
    | _ -> None
  in
  let fleet_warning =
    match fleet_safety with
    | Some (`Assoc fields) ->
      let status =
        match List.assoc_opt "status" fields with
        | Some (`String status) -> status
        | _ -> "unknown"
      in
      let operator_action_required =
        match List.assoc_opt "operator_action_required" fields with
        | Some (`Bool value) -> value
        | _ -> false
      in
      (not (String.equal status "ok")) || operator_action_required
    | _ -> false
  in
  let warnings =
    []
    |> (fun acc ->
         if server_workspace_mismatch
         then
           "Server binary checkout differs from dashboard workspace/base path."
           :: acc
         else acc)
    |> (fun acc ->
         if fleet_warning
         then "Keeper fleet safety is degraded; inspect keeper_fleet_safety." :: acc
         else acc)
    |> List.rev
  in
  let status = if warnings = [] then "ready" else "warn" in
  `Assoc
    ( [ "status", `String status
      ; "warnings", `List (List.map (fun warning -> `String warning) warnings)
      ; "base_path", path_item_json ~source:"input" base_path_input
      ; "workspace_path", path_item_json ~source:"workspace" config.workspace_path
      ; "resolved_base_path", path_item_json ~source:"resolved_base" config.base_path
      ; "data_root", path_item_json ~source:"runtime_data" (Workspace.masc_root_dir config)
      ; "prompt_markdown_dir", path_item_json ~source:"prompt_registry" prompt_markdown_dir
      ; ( "server_repo_path"
        , match server_repo_path with
          | Some path -> path_item_json ~source:"server_binary" path
          | None ->
            `Assoc
              [ "path", `Null; "exists", `Bool false; "source", `String "server_binary" ] )
      ; "source_mismatch", `Bool false
      ; "server_workspace_mismatch", `Bool server_workspace_mismatch
      ; "diagnostics", `List []
      ; ("keeper_runtime", Keeper_runtime_resolved.(current () |> to_yojson))
      ; "build", Build_identity.to_yojson build
      ]
      @ fleet_fields )
;;

(* 30-second TTL chosen to match the dashboard frontend's natural refresh
   cadence (~3s polling × 10 = a fresh value at least every minute under
   sustained load).  Tool inventory + usage stats rarely change inside a
   30s window — the per-actor cache key isolates permission changes from
   leaking across actors.  Schedule FSM projection is attached outside this
   cache because due/pending state is operationally time-sensitive. *)
let dashboard_tools_cache_ttl_sec = 30.0

let dashboard_tools_cache_key ~base_path ~actor =
  Printf.sprintf "tools:%s:%s" base_path actor

let dashboard_actor_name = function
  | Some actor when String.trim actor <> "" -> actor
  | Some _ | None -> "dashboard"
;;

let dashboard_tools_warming_json ~actor =
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; "status", `String "warming"
    ; "is_warming", `Bool true
    ; "stale_reason", `String "warming"
    ; "config_resolution", `Assoc [ "status", `String "warming" ]
    ; "runtime_resolution", `Assoc [ "status", `String "warming" ]
    ; ( "tool_inventory"
      , `Assoc
          [ "count", `Int 0
          ; "tools", `List []
          ; "surface_summary", `Assoc []
          ] )
    ; ( "tool_usage"
      , `Assoc
          [ "total_calls", `Int 0
          ; "distinct_tools_called", `Int 0
          ; "top_20", `List []
          ; "never_called_count", `Int 0
          ; "dispatch_v2_enabled", `Bool false
          ; "registered_count", `Int 0
          ; "source", `String "dashboard_cache_warming"
          ; "health", `String "warming"
          ; "latest_age_s", `Null
          ; "entry_count", `Int 0
          ; "stale_reason", `String "warming"
          ; "actor", `String actor
          ] )
    ]
;;

let schedule_projection_request_limit = 20

let unix_iso_json ts = `String (Masc_domain.iso8601_of_unix_seconds ts)

let unix_iso_option_json = function
  | None -> `Null
  | Some ts -> unix_iso_json ts
;;

let schedule_status_count schedules status =
  List.fold_left
    (fun count (request : Schedule_domain.schedule_request) ->
      if request.status = status then count + 1 else count)
    0 schedules
;;

let schedule_counts_json schedules =
  `Assoc
    (List.map
       (fun status ->
         ( Schedule_domain.schedule_status_to_string status
         , `Int (schedule_status_count schedules status) ))
       Schedule_domain.all_schedule_statuses)
;;

type schedule_payload_support =
  | Supported
  | Unsupported
  | Unknown

let schedule_payload_support (request : Schedule_domain.schedule_request) =
  match Schedule_payload_projection.support_status request with
  | Schedule_payload_projection.Supported -> Supported
  | Schedule_payload_projection.Unsupported -> Unsupported
  | Schedule_payload_projection.Unknown -> Unknown
;;

let schedule_payload_support_to_string = function
  | Supported -> "supported"
  | Unsupported -> "unsupported"
  | Unknown -> "unknown"
;;

let schedule_payload_support_status request =
  schedule_payload_support request |> schedule_payload_support_to_string
;;

let schedule_payload_support_json schedules =
  Schedule_payload_projection.support_summary_to_yojson schedules
;;

let schedule_request_active (request : Schedule_domain.schedule_request) =
  not (Schedule_domain.is_terminal request.status)
;;

let schedule_effectively_expired ~now (request : Schedule_domain.schedule_request) =
  match request.status, request.expires_at with
  | (Schedule_domain.Pending_approval | Schedule_domain.Scheduled | Schedule_domain.Due), Some expires_at
    when expires_at <= now -> true
  | _ -> false
;;

let schedule_request_effectively_active ~now request =
  schedule_request_active request && not (schedule_effectively_expired ~now request)
;;

let schedule_readiness_counts_as_live_supported = function
  | Schedule_projection.Blocked_approval
  | Schedule_projection.Awaiting_approval
  | Schedule_projection.Due_pending_refresh
  | Schedule_projection.Ready
  | Schedule_projection.Approved
  | Schedule_projection.Scheduled
  | Schedule_projection.Running ->
    true
  | Schedule_projection.Expired | Schedule_projection.Terminal -> false
;;

let schedule_effectively_due ~now (request : Schedule_domain.schedule_request) =
  (not (schedule_effectively_expired ~now request))
  &&
  match request.status with
  | Schedule_domain.Due -> true
  | Schedule_domain.Scheduled -> request.due_at <= now
  | Schedule_domain.Pending_approval
  | Schedule_domain.Running
  | Schedule_domain.Succeeded
  | Schedule_domain.Failed
  | Schedule_domain.Rejected
  | Schedule_domain.Cancelled
  | Schedule_domain.Expired ->
    false
;;

let schedule_due_candidate (request : Schedule_domain.schedule_request) =
  match request.status with
  | Schedule_domain.Pending_approval | Schedule_domain.Scheduled | Schedule_domain.Due ->
    true
  | Schedule_domain.Running
  | Schedule_domain.Succeeded
  | Schedule_domain.Failed
  | Schedule_domain.Rejected
  | Schedule_domain.Cancelled
  | Schedule_domain.Expired ->
    false
;;

let schedule_next_due_at ~now schedules =
  schedules
  |> List.filter (fun request ->
    schedule_due_candidate request && not (schedule_effectively_expired ~now request))
  |> List.fold_left
       (fun acc (request : Schedule_domain.schedule_request) ->
         match acc with
         | None -> Some request.due_at
         | Some ts -> Some (min ts request.due_at))
       None
;;

let schedule_blocked_approval ~now state (request : Schedule_domain.schedule_request) =
  (not (schedule_effectively_expired ~now request))
  && request.due_at <= now
  && Schedule_domain.requires_separate_human_grant request
  &&
  match request.status with
  | Schedule_domain.Pending_approval -> true
  | Schedule_domain.Due -> not (Schedule_store.has_current_approved_grant state request)
  | Schedule_domain.Scheduled
  | Schedule_domain.Running
  | Schedule_domain.Succeeded
  | Schedule_domain.Failed
  | Schedule_domain.Rejected
  | Schedule_domain.Cancelled
  | Schedule_domain.Expired ->
    false
;;

let schedule_effective_status ~now state (request : Schedule_domain.schedule_request) =
  if schedule_effectively_expired ~now request
  then "expired"
  else
    match request.status with
    | Schedule_domain.Pending_approval when request.due_at <= now -> "blocked_approval"
    | Pending_approval -> "pending_approval"
    | Scheduled when request.due_at <= now -> "due"
    | Scheduled -> "scheduled"
    | Due when schedule_blocked_approval ~now state request -> "blocked_approval"
    | Due -> "ready"
    | Running -> "running"
    | Succeeded -> "succeeded"
    | Failed -> "failed"
    | Rejected -> "rejected"
    | Cancelled -> "cancelled"
    | Expired -> "expired"
;;

let schedule_execution_readiness ~now state (request : Schedule_domain.schedule_request) =
  if schedule_effectively_expired ~now request
  then Schedule_projection.Expired
  else if Schedule_domain.is_terminal request.status
  then Schedule_projection.Terminal
  else if request.status = Schedule_domain.Running
  then Schedule_projection.Running
  else if schedule_blocked_approval ~now state request
  then Schedule_projection.Blocked_approval
  else if Schedule_store.has_current_approved_grant state request
  then Schedule_projection.Approved
  else
    match request.status with
    | Schedule_domain.Pending_approval -> Schedule_projection.Awaiting_approval
    | Schedule_domain.Scheduled when request.due_at <= now ->
      Schedule_projection.Due_pending_refresh
    | Schedule_domain.Scheduled -> Schedule_projection.Scheduled
    | Schedule_domain.Due -> Schedule_projection.Ready
    | Schedule_domain.Running -> Schedule_projection.Running
    | Schedule_domain.Succeeded
    | Schedule_domain.Failed
    | Schedule_domain.Rejected
    | Schedule_domain.Cancelled
    | Schedule_domain.Expired ->
      Schedule_projection.Terminal
;;

let schedule_operator_action readiness =
  match Schedule_projection.operator_action_for_execution_readiness readiness with
  | Some action -> `String action
  | None -> `Null
;;

let tool_projection_surfaces_for tool_name =
  let surfaces = ref [] in
  let add_surface surface =
    if not (List.exists (String.equal surface) !surfaces)
    then surfaces := surface :: !surfaces
  in
  if Tool_catalog.is_public_mcp tool_name then add_surface "public_mcp";
  Capability_registry.all_projection_seeds_from Config.raw_all_tool_schemas
  |> List.iter (fun (seed : Capability_registry.capability_seed) ->
    let surface = Capability_registry.surface_to_string seed.projection.surface in
    if
      (not (String.equal surface "public_mcp"))
      && (String.equal seed.projection.tool_name tool_name
          || String.equal seed.projection.backend_tool_name tool_name)
    then add_surface surface);
  List.sort String.compare !surfaces
;;

let schedule_keeper_next_tool_status_json = function
  | None -> `Null
  | Some tool_name ->
    let registered_schema =
      List.exists
        (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name tool_name)
        Config.raw_all_tool_schemas
    in
    let dispatch_registered = Option.is_some (Tool_dispatch.lookup_tag tool_name) in
    let metadata = Tool_catalog.metadata tool_name in
    let surfaces = tool_projection_surfaces_for tool_name in
    let effect_domain =
      match metadata.effect_domain with
      | None -> `Null
      | Some domain -> `String (Tool_catalog.effect_domain_to_string domain)
    in
    `Assoc
      [ "name", `String tool_name
      ; "registered_schema", `Bool registered_schema
      ; "dispatch_registered", `Bool dispatch_registered
      ; "direct_call_allowed", `Bool (Tool_catalog.allow_direct_call tool_name)
      ; "visibility", `String (Tool_catalog.visibility_to_string metadata.visibility)
      ; ( "surfaces"
        , `List (List.map (fun surface -> `String surface) surfaces) )
      ; "surface_count", `Int (List.length surfaces)
      ; "effect_domain", effect_domain
      ; ( "read_only"
        , match metadata.readonly with
          | None -> `Null
          | Some read_only -> `Bool read_only )
      ; ( "requires_actor_binding"
        , match metadata.requires_actor_binding with
          | None -> `Null
          | Some requires_actor_binding -> `Bool requires_actor_binding )
      ]
;;

let schedule_keeper_next_action readiness =
  match Schedule_projection.keeper_next_action_for_execution_readiness readiness with
  | Some action -> `String action
  | None -> `Null
;;

let schedule_fsm_state ~now state schedules =
  let count status = schedule_status_count schedules status in
  let count_non_expired status =
    List.fold_left
      (fun count (request : Schedule_domain.schedule_request) ->
         if request.status = status && not (schedule_effectively_expired ~now request)
         then count + 1
         else count)
      0 schedules
  in
  let due_effective_count =
    List.fold_left
      (fun count request -> if schedule_effectively_due ~now request then count + 1 else count)
      0 schedules
  in
  let blocked_approval_count =
    List.fold_left
      (fun count request ->
         if schedule_blocked_approval ~now state request then count + 1 else count)
      0 schedules
  in
  if count Schedule_domain.Running > 0
  then "running"
  else if blocked_approval_count > 0
  then "blocked_approval"
  else if due_effective_count > 0
  then "due"
  else if count_non_expired Schedule_domain.Pending_approval > 0
  then "pending_approval"
  else if count_non_expired Schedule_domain.Scheduled > 0
  then "scheduled"
  else if
    List.exists (fun request -> schedule_effectively_expired ~now request) schedules
  then "expired"
  else "idle"
;;

let execution_record_dashboard_json (execution : Schedule_domain.execution_record) =
  match Schedule_domain.execution_record_to_yojson execution with
  | `Assoc fields ->
    `Assoc
      (fields
       @ [ "started_at_iso", unix_iso_json execution.started_at
         ; "finished_at_iso", unix_iso_option_json execution.finished_at
         ])
  | other -> other
;;

let schedule_dispatch_receipt_dashboard_json
  (execution : Schedule_domain.execution_record option)
  =
  match execution with
  | None -> `Null
  | Some execution ->
    (match execution.Schedule_domain.detail with
     | None -> `Null
     | Some detail ->
    (match Server_schedule_consumers.dispatch_receipt_of_detail detail with
     | Ok receipt ->
       (match Server_schedule_consumers.dispatch_receipt_to_yojson receipt with
        | `Assoc fields -> `Assoc (("projection_status", `String "recognized") :: fields)
        | other -> other)
     | Error reason ->
       `Assoc
         [ "projection_status", `String "unrecognized_detail"
         ; "reason", `String reason
         ]))
;;

let schedule_queue_read_error_dashboard_json
  (error : Keeper_event_queue_persistence.snapshot_read_error)
  =
  `Assoc
    [ "kind", `String (Keeper_event_queue_persistence.snapshot_read_error_kind_to_string error.kind)
    ; ( "path"
      , match error.path with
        | None -> `Null
        | Some path -> `String path )
    ; "message", `String error.message
    ]
;;

let schedule_queue_match
  ~(schedule_id : string)
  ~(due_at : float)
  ~(payload_digest : string)
  ~(post_id : string)
  ~(stimulus_label : string)
  (queue : Keeper_event_queue.t)
  =
  queue
  |> Keeper_event_queue.to_list
  |> List.find_opt (fun (stimulus : Keeper_event_queue.stimulus) ->
    String.equal stimulus.post_id post_id
    && String.equal (Keeper_event_queue.payload_kind_label stimulus.payload) stimulus_label
    &&
    match stimulus.payload with
    | Keeper_event_queue.Schedule_due wake ->
      String.equal wake.schedule_id schedule_id
      && Float.equal wake.due_at due_at
      && String.equal wake.payload_digest payload_digest
    | _ -> false)
;;

let schedule_queue_match_fields ~now bucket (stimulus : Keeper_event_queue.stimulus) =
  let scheduled_wake =
    match stimulus.payload with
    | Keeper_event_queue.Schedule_due wake -> Some wake
    | _ -> None
  in
  [ "matched_bucket", `String bucket
  ; "matched_post_id", `String stimulus.post_id
  ; "matched_payload_kind", `String (Keeper_event_queue.payload_kind_label stimulus.payload)
  ; "matched_arrived_at", `Float stimulus.arrived_at
  ; "matched_arrived_at_iso", unix_iso_json stimulus.arrived_at
  ; ( "matched_schedule_id"
    , match scheduled_wake with
      | Some wake -> `String wake.schedule_id
      | None -> `Null )
  ; ( "matched_due_at"
    , match scheduled_wake with
      | Some wake -> `Float wake.due_at
      | None -> `Null )
  ; ( "matched_due_at_iso"
    , match scheduled_wake with
      | Some wake -> unix_iso_json wake.due_at
      | None -> `Null )
  ; ( "matched_payload_digest"
    , match scheduled_wake with
      | Some wake -> `String wake.payload_digest
      | None -> `Null )
  ; "matched_age_seconds", `Float (Float.max 0.0 (now -. stimulus.arrived_at))
  ]
;;

let schedule_keeper_queue_evidence_dashboard_json
  ~now
  (config : Workspace.config)
  (execution : Schedule_domain.execution_record option)
  =
  match execution with
  | None -> `Null
  | Some execution ->
    (match execution.Schedule_domain.detail with
     | None -> `Null
     | Some detail ->
       (match Server_schedule_consumers.dispatch_receipt_of_detail detail with
        | Error reason ->
          `Assoc
            [ "projection_status", `String "unrecognized_receipt"
            ; "reason", `String reason
            ]
        | Ok Server_schedule_consumers.Board_post_created _ -> `Null
        | Ok
            (Server_schedule_consumers.Keeper_wake_enqueued
              { keeper_name
              ; schedule_id
              ; urgency = _
              ; post_id
              ; queue
              ; stimulus
              ; stimulus_id = _
              ; reaction_ledger_status = _
              }) ->
          let due_at = execution.Schedule_domain.due_at in
          let payload_digest = execution.Schedule_domain.payload_digest in
          let snapshot =
            Keeper_event_queue_persistence.load_snapshot_pair_with_errors
              ~base_path:config.Workspace_utils.base_path
              ~keeper_name
          in
          let pending_match =
            schedule_queue_match ~schedule_id ~due_at ~payload_digest ~post_id
              ~stimulus_label:stimulus snapshot.pending
          in
          let inflight_match =
            schedule_queue_match ~schedule_id ~due_at ~payload_digest ~post_id
              ~stimulus_label:stimulus snapshot.inflight
          in
          let read_errors =
            List.map schedule_queue_read_error_dashboard_json snapshot.read_errors
          in
          let base_fields =
            [ "source", `String "durable_event_queue_snapshot"
            ; "queue", `String queue
            ; "stimulus", `String stimulus
            ; "keeper_name", `String keeper_name
            ; "schedule_id", `String schedule_id
            ; "post_id", `String post_id
            ; "execution_due_at", `Float due_at
            ; "execution_due_at_iso", unix_iso_json due_at
            ; "execution_payload_digest", `String payload_digest
            ; "pending_count", `Int (Keeper_event_queue.length snapshot.pending)
            ; "inflight_count", `Int (Keeper_event_queue.length snapshot.inflight)
            ; "read_errors", `List read_errors
            ]
          in
          (match pending_match, inflight_match, snapshot.read_errors with
           | Some match_, _, _ ->
             `Assoc
               (("projection_status", `String "matched_pending")
                :: base_fields
                @ schedule_queue_match_fields ~now "pending" match_)
           | None, Some match_, _ ->
             `Assoc
               (("projection_status", `String "matched_inflight")
                :: base_fields
                @ schedule_queue_match_fields ~now "inflight" match_)
           | None, None, _ :: _ ->
             `Assoc (("projection_status", `String "read_error") :: base_fields)
           | None, None, [] ->
             `Assoc (("projection_status", `String "not_found") :: base_fields))))
;;

let schedule_keeper_reaction_evidence_dashboard_json
  (config : Workspace.config)
  (execution : Schedule_domain.execution_record option)
  =
  match execution with
  | None -> `Null
  | Some execution ->
    (match execution.Schedule_domain.detail with
     | None -> `Null
     | Some detail ->
       (match Server_schedule_consumers.dispatch_receipt_of_detail detail with
        | Error reason ->
          `Assoc
            [ "projection_status", `String "unrecognized_receipt"
            ; "reason", `String reason
            ]
        | Ok Server_schedule_consumers.Board_post_created _ -> `Null
        | Ok
            (Server_schedule_consumers.Keeper_wake_enqueued
              { keeper_name
              ; schedule_id
              ; urgency = _
              ; post_id
              ; queue = _
              ; stimulus
              ; stimulus_id
              ; reaction_ledger_status = _
              }) ->
          let base_fields =
            [ "source", `String "keeper_reaction_ledger"
            ; "keeper_name", `String keeper_name
            ; "schedule_id", `String schedule_id
            ; "post_id", `String post_id
            ; "stimulus", `String stimulus
            ; ( "reaction_kind"
              , `String
                  (Keeper_reaction_ledger.reaction_kind_to_string
                     Keeper_reaction_ledger.Turn_started) )
            ; ( "stimulus_kind"
              , `String
                  (Keeper_reaction_ledger.stimulus_kind_to_string
                     Keeper_reaction_ledger.Schedule_due) )
            ]
          in
          (match stimulus_id with
           | None ->
             `Assoc
               (("projection_status", `String "missing_stimulus_id")
                :: ("reason", `String "dispatch receipt predates stimulus_id projection")
                :: base_fields)
           | Some stimulus_id ->
             let evidence =
               Keeper_reaction_ledger.event_queue_reaction_evidence
                 ~base_path:config.Workspace_utils.base_path
                 ~keeper_name
                 ~stimulus_id
             in
             let projection_status =
               if evidence.event_queue_ack_seen
               then "matched_consumed_ack"
               else if evidence.turn_started_seen
               then "matched_turn_started"
               else if evidence.stimulus_seen
               then "matched_stimulus"
               else "not_found"
             in
             `Assoc
               (("projection_status", `String projection_status)
                :: base_fields
                @ [ "stimulus_id", `String stimulus_id
                  ; "stimulus_seen", `Bool evidence.stimulus_seen
                  ; "turn_started_seen", `Bool evidence.turn_started_seen
                  ; "event_queue_ack_seen", `Bool evidence.event_queue_ack_seen
                  ; "matched_record_count", `Int evidence.matched_record_count
                  ; ( "stimulus_recorded_at"
                    , match evidence.stimulus_recorded_at with
                      | None -> `Null
                      | Some ts -> `Float ts )
                  ; ( "stimulus_recorded_at_iso"
                    , unix_iso_option_json evidence.stimulus_recorded_at )
                  ; ( "turn_started_recorded_at"
                    , match evidence.turn_started_recorded_at with
                      | None -> `Null
                      | Some ts -> `Float ts )
                  ; ( "turn_started_recorded_at_iso"
                    , unix_iso_option_json evidence.turn_started_recorded_at )
                  ; ( "event_queue_ack_recorded_at"
                    , match evidence.event_queue_ack_recorded_at with
                      | None -> `Null
                      | Some ts -> `Float ts )
                  ; ( "event_queue_ack_recorded_at_iso"
                    , unix_iso_option_json evidence.event_queue_ack_recorded_at )
                  ; ( "latest_recorded_at"
                    , match evidence.latest_recorded_at with
                      | None -> `Null
                      | Some ts -> `Float ts )
                  ; ( "latest_recorded_at_iso"
                    , unix_iso_option_json evidence.latest_recorded_at )
                  ]))))
;;

let schedule_signal_projection_limit = 20

let schedule_signal_payload_kind_json (signal : Schedule_runner.wake_signal) =
  match signal.payload with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String kind) -> `String kind
     | _ -> `Null)
  | _ -> `Null
;;

let schedule_signal_dashboard_json (signal : Schedule_runner.wake_signal) =
  let kind = Schedule_runner.signal_kind_to_string signal.kind in
  `Assoc
    [ "signal_id", `String signal.signal_id
    ; "kind", `String kind
    ; "event_type", `String kind
    ; "schedule_id", `String signal.schedule_id
    ; "emitted_at", `Float signal.emitted_at
    ; "emitted_at_iso", unix_iso_json signal.emitted_at
    ; "due_at", `Float signal.due_at
    ; "due_at_iso", unix_iso_json signal.due_at
    ; "risk_class", `String (Schedule_domain.risk_class_to_string signal.risk_class)
    ; "payload_digest", `String signal.payload_digest
    ; "payload_kind", schedule_signal_payload_kind_json signal
    ]
;;

type schedule_signal_projection_entry =
  | Decoded_schedule_signal of Schedule_runner.wake_signal
  | Schedule_signal_decode_error of int * string

let schedule_signal_decode_error_dashboard_json ordinal error =
  `Assoc [ "ordinal", `Int ordinal; "error", `String error ]
;;

let schedule_signal_rows_and_errors config limit =
  let entries =
    Dated_jsonl.read_recent
      (Dated_jsonl.create ~base_dir:(Schedule_runner.signals_dir config) ())
      limit
    |> List.mapi (fun ordinal json ->
      match Schedule_runner.wake_signal_of_yojson json with
      | Ok signal -> Decoded_schedule_signal signal
      | Error error -> Schedule_signal_decode_error (ordinal, error))
  in
  List.fold_right
    (fun entry (signals, errors) ->
       match entry with
       | Decoded_schedule_signal signal -> signal :: signals, errors
       | Schedule_signal_decode_error (ordinal, error) ->
         signals, schedule_signal_decode_error_dashboard_json ordinal error :: errors)
    entries
    ([], [])
;;

let schedule_request_dashboard_json
  ~now
  ~config
  ~state
  ?last_execution
  (request : Schedule_domain.schedule_request)
  =
  let next_due_at =
    if Schedule_domain.is_terminal request.status then None else Some request.due_at
  in
  let requires_grant = Schedule_domain.requires_separate_human_grant request in
  let payload_target, payload_summary =
    Schedule_payload_projection.target_summary request
  in
  let execution_readiness = schedule_execution_readiness ~now state request in
  let keeper_next_tool =
    Schedule_projection.keeper_next_tool_for_execution_readiness execution_readiness
  in
  `Assoc
    [ "schedule_id", `String request.schedule_id
    ; "status", `String (Schedule_domain.schedule_status_to_string request.status)
    ; "effective_status", `String (schedule_effective_status ~now state request)
    ; ( "execution_readiness"
      , `String (Schedule_projection.execution_readiness_to_string execution_readiness) )
    ; "operator_action", schedule_operator_action execution_readiness
    ; ( "keeper_next_tool"
      , match keeper_next_tool with
        | None -> `Null
        | Some tool -> `String tool )
    ; "keeper_next_tool_status", schedule_keeper_next_tool_status_json keeper_next_tool
    ; "keeper_next_action", schedule_keeper_next_action execution_readiness
    ; "risk_class", `String (Schedule_domain.risk_class_to_string request.risk_class)
    ; "approval_required", `Bool request.approval_required
    ; "source", `String (Schedule_domain.schedule_source_to_string request.source)
    ; "requested_by", Schedule_domain.actor_to_yojson request.requested_by
    ; "scheduled_by", Schedule_domain.actor_to_yojson request.scheduled_by
    ; "requested_at", `Float request.requested_at
    ; "requested_at_iso", unix_iso_json request.requested_at
    ; "due_at", `Float request.due_at
    ; "due_at_iso", unix_iso_json request.due_at
    ; ( "next_due_at"
      , match next_due_at with
        | None -> `Null
        | Some ts -> `Float ts )
    ; "next_due_at_iso", unix_iso_option_json next_due_at
    ; "expires_at", (match request.expires_at with None -> `Null | Some ts -> `Float ts)
    ; "expires_at_iso", unix_iso_option_json request.expires_at
    ; "recurrence", Schedule_domain.recurrence_to_yojson request.recurrence
    ; "recurrence_kind", `String (Schedule_domain.recurrence_kind_to_string request.recurrence)
    ; "recurrence_summary", `String (Schedule_domain.recurrence_summary request.recurrence)
    ; ( "requires_separate_human_grant", `Bool requires_grant )
    ; ( "approval_policy"
      , `String
          (if requires_grant
           then "separate_human_grant_required"
           else "no_separate_grant_required") )
    ; "payload_digest", `String (Schedule_domain.payload_digest request.payload)
    ; ( "payload_kind"
      , match Schedule_payload_projection.kind request with
        | None -> `Null
        | Some kind -> `String kind )
    ; "payload_support", `String (schedule_payload_support_status request)
    ; ( "payload_dispatch_tool"
      , match Schedule_payload_projection.dispatch_tool_for_request request with
        | None -> `Null
        | Some tool_name -> `String tool_name )
    ; ( "payload_target"
      , match payload_target with
        | None -> `Null
        | Some target -> `String target )
    ; ( "payload_summary"
      , match payload_summary with
        | None -> `Null
        | Some summary -> `String summary )
    ; ( "last_execution"
      , match last_execution with
        | None -> `Null
        | Some execution -> execution_record_dashboard_json execution )
    ; "dispatch_receipt", schedule_dispatch_receipt_dashboard_json last_execution
    ; "keeper_queue_evidence", schedule_keeper_queue_evidence_dashboard_json ~now config last_execution
    ; ( "keeper_reaction_evidence"
      , schedule_keeper_reaction_evidence_dashboard_json config last_execution )
    ]
;;

let live_supported_evidence_ids_limit = 8

let schedule_live_supported_non_terminal_evidence_json ~now ~state schedules =
  let
    ( supported_request_count
    , supported_non_terminal_count
    , supported_live_count
    , supported_terminal_or_expired_count
    , unsupported_request_count
    , unknown_request_count
    , terminal_or_expired_count
    , matched_ids )
    =
    List.fold_left
      (fun
        ( supported_count
        , supported_non_terminal
        , supported_live
        , supported_terminal_or_expired
        , unsupported_count
        , unknown_count
        , terminal_or_expired
        , ids )
        (request : Schedule_domain.schedule_request)
       ->
         let readiness = schedule_execution_readiness ~now state request in
         let live_readiness =
           schedule_readiness_counts_as_live_supported readiness
         in
         let terminal_or_expired_row = not live_readiness in
         let terminal_or_expired =
           if terminal_or_expired_row then terminal_or_expired + 1 else terminal_or_expired
         in
         match schedule_payload_support request with
         | Supported ->
           let non_terminal = not (Schedule_domain.is_terminal request.status) in
           let supported_non_terminal =
             if non_terminal then supported_non_terminal + 1 else supported_non_terminal
           in
           if live_readiness
           then (
             let ids =
               if List.length ids < live_supported_evidence_ids_limit
               then request.schedule_id :: ids
               else ids
             in
             ( supported_count + 1
             , supported_non_terminal
             , supported_live + 1
             , supported_terminal_or_expired
             , unsupported_count
             , unknown_count
             , terminal_or_expired
             , ids ))
           else
             ( supported_count + 1
             , supported_non_terminal
             , supported_live
             , supported_terminal_or_expired + 1
             , unsupported_count
             , unknown_count
             , terminal_or_expired
             , ids )
         | Unsupported ->
           ( supported_count
           , supported_non_terminal
           , supported_live
           , supported_terminal_or_expired
           , unsupported_count + 1
           , unknown_count
           , terminal_or_expired
           , ids )
         | Unknown ->
           ( supported_count
           , supported_non_terminal
           , supported_live
           , supported_terminal_or_expired
           , unsupported_count
           , unknown_count + 1
           , terminal_or_expired
           , ids ))
      (0, 0, 0, 0, 0, 0, 0, [])
      schedules
  in
  let request_count = List.length schedules in
  let projection_status =
    if supported_live_count > 0
    then "matched_supported_non_terminal"
    else if supported_request_count = 0 && request_count > 0
    then "no_supported_payload_rows"
    else "no_supported_non_terminal"
  in
  let reason =
    if supported_live_count > 0
    then "live schedule_store contains supported rows whose readiness is not terminal or expired"
    else if supported_request_count = 0 && request_count > 0
    then "current live schedule_store has no rows with a supported payload kind"
    else "supported rows are currently terminal or effectively expired"
  in
  `Assoc
    [ "schema", `String "masc.dashboard.scheduled_automation.live_supported_non_terminal_evidence.v1"
    ; "source", `String "schedule_store"
    ; "projection_status", `String projection_status
    ; ( "criteria"
      , `String
          "payload_support=supported && execution_readiness not in {terminal,expired}" )
    ; "reason", `String reason
    ; "request_count", `Int request_count
    ; "supported_request_count", `Int supported_request_count
    ; "supported_non_terminal_count", `Int supported_non_terminal_count
    ; "supported_live_count", `Int supported_live_count
    ; "supported_terminal_or_expired_count", `Int supported_terminal_or_expired_count
    ; "unsupported_request_count", `Int unsupported_request_count
    ; "unknown_request_count", `Int unknown_request_count
    ; "terminal_or_expired_count", `Int terminal_or_expired_count
    ; ( "matched_schedule_ids"
      , `List (List.map (fun schedule_id -> `String schedule_id) (List.rev matched_ids)) )
    ; "matched_schedule_id_limit", `Int live_supported_evidence_ids_limit
    ]
;;

let scheduled_automation_dashboard_json (config : Workspace.config) : Yojson.Safe.t =
  (* NDT-OK: dashboard read-model freshness clock; it derives display-only
     effective-due state and never mutates the schedule store or runs work. *)
  let now = Unix.gettimeofday () in
  let signal_rows, signal_errors =
    schedule_signal_rows_and_errors config schedule_signal_projection_limit
  in
  let base_fields =
    [ "schema", `String "masc.dashboard.scheduled_automation.v1"
    ; "source", `String "schedule_store"
    ; "generated_at", `String (Masc_domain.now_iso ())
    ; "signal_source", `String "schedule_runner_signals"
    ; "signal_count", `Int (List.length signal_rows)
    ; "signal_error_count", `Int (List.length signal_errors)
    ; "signal_limit", `Int schedule_signal_projection_limit
    ; "signals", `List (List.map schedule_signal_dashboard_json signal_rows)
    ; "signal_errors", `List signal_errors
    ]
  in
  match Schedule_store.read_state_result config with
  | Error err ->
    let read_error =
      "schedule store read failed: " ^ Schedule_store.read_error_to_string err
    in
    `Assoc
      (base_fields
       @ [ "status", `String "unknown"
         ; "schedule_store_known", `Bool false
         ; "schedule_store_read_error", `String read_error
         ; "request_count", `Null
         ; "request_limit", `Int schedule_projection_request_limit
         ; "truncated", `Bool false
         ; "counts", `Null
         ; "derived_counts", `Null
         ; "payload_support", `Null
         ; "live_supported_non_terminal_evidence", `Null
         ; ( "fsm"
           , `Assoc
               [ "state", `String "unknown"
               ; "active_count", `Null
               ; "terminal_count", `Null
               ; "next_due_at", `Null
               ] )
         ; "requests", `List []
         ])
  | Ok state ->
    let schedules = state.schedules in
    let active_count =
      List.fold_left
        (fun count request ->
           if schedule_request_effectively_active ~now request then count + 1 else count)
        0 schedules
    in
    let terminal_count = List.length schedules - active_count in
    let expired_effective_count =
      List.fold_left
        (fun count request ->
           if schedule_effectively_expired ~now request then count + 1 else count)
        0 schedules
    in
    let due_effective_count =
      List.fold_left
        (fun count request -> if schedule_effectively_due ~now request then count + 1 else count)
        0 schedules
    in
    let blocked_approval_count =
      List.fold_left
        (fun count request ->
           if schedule_blocked_approval ~now state request then count + 1 else count)
        0 schedules
    in
    let approval_wait_seconds =
      List.fold_left
        (fun oldest_wait request ->
           if schedule_blocked_approval ~now state request
           then max oldest_wait (max 0.0 (now -. request.due_at))
           else oldest_wait)
        0.0
        schedules
    in
    let due_execution_ready_count =
      state
      |> Schedule_store.due_execution_candidates
      |> List.filter (fun request -> not (schedule_effectively_expired ~now request))
      |> List.length
    in
    let payload_support = schedule_payload_support_json schedules in
    let unsupported_payload_kind_count, unknown_payload_kind_count =
      match payload_support with
      | `Assoc fields ->
        ( (match List.assoc_opt "unsupported_request_count" fields with
           | Some (`Int count) -> count
           | _ -> 0)
        , (match List.assoc_opt "unknown_request_count" fields with
           | Some (`Int count) -> count
           | _ -> 0) )
      | _ -> 0, 0
    in
    Otel_metric_store.set_gauge
      Otel_metric_store.metric_schedule_approval_blocked_count
      (Float.of_int blocked_approval_count);
    Otel_metric_store.set_gauge
      Otel_metric_store.metric_schedule_approval_wait_seconds
      approval_wait_seconds;
    let sorted =
      schedules
      |> List.sort (fun left right ->
        match
          ( schedule_request_active left
          , schedule_request_active right
          , schedule_request_effectively_active ~now left
          , schedule_request_effectively_active ~now right
          , compare left.due_at right.due_at )
        with
        | _, _, true, false, _ -> -1
        | _, _, false, true, _ -> 1
        | true, false, _, _, _ -> -1
        | false, true, _, _, _ -> 1
        | _, _, _, _, due_cmp when due_cmp <> 0 -> due_cmp
        | _ -> String.compare left.schedule_id right.schedule_id)
    in
    let request_rows = take schedule_projection_request_limit sorted in
    `Assoc
      (base_fields
       @ [ "status", `String "ok"
         ; "schedule_store_known", `Bool true
         ; "schedule_store_read_error", `Null
         ; "request_count", `Int (List.length schedules)
         ; "request_limit", `Int schedule_projection_request_limit
         ; "truncated", `Bool (List.length schedules > schedule_projection_request_limit)
         ; "counts", schedule_counts_json schedules
         ; ( "derived_counts"
           , `Assoc
               [ "due_effective", `Int due_effective_count
               ; "blocked_approval", `Int blocked_approval_count
               ; "due_execution_ready", `Int due_execution_ready_count
               ; "expired_effective", `Int expired_effective_count
               ; "unsupported_payload_kind", `Int unsupported_payload_kind_count
               ; "unknown_payload_kind", `Int unknown_payload_kind_count
               ] )
         ; "payload_support", payload_support
         ; ( "live_supported_non_terminal_evidence"
           , schedule_live_supported_non_terminal_evidence_json ~now ~state schedules )
         ; ( "fsm"
           , `Assoc
               [ "state", `String (schedule_fsm_state ~now state schedules)
               ; "active_count", `Int active_count
               ; "terminal_count", `Int terminal_count
               ; "next_due_at", unix_iso_option_json (schedule_next_due_at ~now schedules)
               ] )
         ; ( "requests"
           , `List
               (List.map
                  (fun (request : Schedule_domain.schedule_request) ->
                     let last_execution =
                       Schedule_store.last_execution_for_schedule state
                         ~schedule_id:request.Schedule_domain.schedule_id
                     in
                     schedule_request_dashboard_json ~now ~config ~state ?last_execution request)
                  request_rows) )
         ])
;;

let dashboard_tools_http_json ?actor ?timing (config : Workspace.config) : Yojson.Safe.t =
  let actor_name = dashboard_actor_name actor in
  let ctx : Tool_misc.context =
    { config; agent_name = actor_name }
  in
  let run phase f =
    match timing with
    | None -> f ()
    | Some t -> Server_timing.measure t phase f
  in
  let cache_key =
    dashboard_tools_cache_key ~base_path:config.base_path ~actor:actor_name
  in
  Dashboard_cache.seed_stale_if_missing cache_key
    ~stale_for:dashboard_tools_cache_ttl_sec
    (dashboard_tools_warming_json ~actor:actor_name);
  let compute () =
    let config_resolution =
      run Projection_config_resolution (fun () ->
        Config_dir_resolver.(resolve () |> to_json))
    in
    let runtime_resolution =
      run Projection_runtime_resolution (fun () -> runtime_resolution_json config)
    in
    let inventory =
      run Tools_compute (fun () ->
        Tool_misc.tool_inventory_json ctx ~include_hidden:true)
    in
    let usage =
      run Tools_compute (fun () ->
        Tool_unified.summary_report
          ~runtime_metrics:Runtime_observation.runtime_metrics_json
          ()
        |> Tool_usage_log.attach_source_metadata
             ~masc_root:(Workspace.masc_root_dir config))
    in
    `Assoc
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "config_resolution", config_resolution
      ; "runtime_resolution", runtime_resolution
      ; "tool_inventory", inventory
      ; "tool_usage", usage
      ]
  in
  let attach_live_tools_projections json =
    let scheduled_automation =
      run Tools_compute (fun () -> scheduled_automation_dashboard_json config)
    in
    let keeper_waiting_inventory =
      run Tools_compute (fun () -> Server_keeper_waiting_inventory.dashboard_json config)
    in
    let keeper_background =
      run Tools_compute (fun () -> Server_keeper_background.dashboard_json config)
    in
    match json with
    | `Assoc fields ->
      `Assoc
        (fields
         @ [ "scheduled_automation", scheduled_automation
           ; "keeper_waiting_inventory", keeper_waiting_inventory
           ; "keeper_background", keeper_background
           ])
    | other -> other
  in
  let cached =
    match timing with
    | None ->
      Dashboard_cache.get_or_compute cache_key ~ttl:dashboard_tools_cache_ttl_sec
        compute
    | Some t ->
      Server_timing.measure t Cache_lookup (fun () ->
        Dashboard_cache.get_or_compute cache_key
          ~ttl:dashboard_tools_cache_ttl_sec compute)
  in
  attach_live_tools_projections cached
;;

let dashboard_perf_http_json = Server_dashboard_http_perf.dashboard_perf_http_json
