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
let dashboard_runtime_probe_timeout_sec = 15
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
   keep serving during the refresh. Matches the sibling
   [dashboard_runtime_probe_timeout_sec = 15] at the top of this module. *)
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

let same_normalized_path path expected =
  match normalized_path_opt expected with
  | Some expected -> String.equal path expected
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
  let probes = List.map dashboard_runtime_provider_probe_json runtimes in
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
        | exception Eio.Mutex.Poisoned cause ->
          Atomic.set dashboard_runtime_probe_refresh_in_flight false;
          Log.Dashboard.warn
            "runtime probe skipped: HTTP pool mutex poisoned (%s); \
             returning degraded envelope"
            (Printexc.to_string cause);
          let degraded =
            `Assoc
              [ "source", `String runtime_inventory_source
              ; "status", `String "unreachable"
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
              ; "errors", `List [ `String "pool mutex poisoned; restart to recover" ]
              ; ( "observations"
                , `List
                    [ `String
                        (Printf.sprintf
                           "Runtime probe failed: HTTP pool mutex poisoned (%s). \
                            The pool recovers on next successful request; if this \
                            persists, restart the server."
                           (Printexc.to_string cause))
                    ] )
              ; "limitations"
              , `List
                  [ `String "Probe skipped due to poisoned pool mutex."
                  ]
              ]
          in
          degraded, false, 0.0
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

let runtime_inventory_entry_json ~default_id (rt : Runtime.t) =
  let runtime_kind = runtime_kind_of_transport rt.provider.transport in
  let models = [ rt.model.api_name ] in
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
    match server_repo_path with
    | Some path ->
      not
        (same_normalized_path path config.workspace_path
         || same_normalized_path path config.base_path)
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
  then "expired"
  else if Schedule_domain.is_terminal request.status
  then "terminal"
  else if request.status = Schedule_domain.Running
  then "running"
  else if schedule_blocked_approval ~now state request
  then "blocked_approval"
  else if Schedule_store.has_current_approved_grant state request
  then "approved"
  else
    match request.status with
    | Schedule_domain.Pending_approval -> "awaiting_approval"
    | Scheduled when request.due_at <= now -> "due_pending_refresh"
    | Scheduled -> "scheduled"
    | Due -> "ready"
    | Running -> "running"
    | Succeeded | Failed | Rejected | Cancelled | Expired -> "terminal"
;;

let schedule_operator_action ~now state (request : Schedule_domain.schedule_request) =
  match schedule_execution_readiness ~now state request with
  | "blocked_approval" | "awaiting_approval" -> `String "approve_or_reject"
  | "due_pending_refresh" -> `String "wait_for_runner_tick"
  | "expired" -> `String "inspect_or_recreate"
  | "ready" | "approved" -> `String "wait_for_dispatch"
  | "scheduled" | "running" | "terminal" -> `Null
  | _ -> `Null
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

let schedule_payload_kind request =
  match Schedule_domain.payload_to_yojson request.Schedule_domain.payload with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String kind) -> Some kind
     | _ -> None)
  | _ -> None
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

let schedule_request_dashboard_json
  ~now
  ~state
  ?last_execution
  (request : Schedule_domain.schedule_request)
  =
  `Assoc
    [ "schedule_id", `String request.schedule_id
    ; "status", `String (Schedule_domain.schedule_status_to_string request.status)
    ; "effective_status", `String (schedule_effective_status ~now state request)
    ; "execution_readiness", `String (schedule_execution_readiness ~now state request)
    ; "operator_action", schedule_operator_action ~now state request
    ; "risk_class", `String (Schedule_domain.risk_class_to_string request.risk_class)
    ; "approval_required", `Bool request.approval_required
    ; "source", `String (Schedule_domain.schedule_source_to_string request.source)
    ; "requested_by", Schedule_domain.actor_to_yojson request.requested_by
    ; "scheduled_by", Schedule_domain.actor_to_yojson request.scheduled_by
    ; "requested_at", `Float request.requested_at
    ; "requested_at_iso", unix_iso_json request.requested_at
    ; "due_at", `Float request.due_at
    ; "due_at_iso", unix_iso_json request.due_at
    ; "expires_at", (match request.expires_at with None -> `Null | Some ts -> `Float ts)
    ; "expires_at_iso", unix_iso_option_json request.expires_at
    ; "recurrence", Schedule_domain.recurrence_to_yojson request.recurrence
    ; "recurrence_kind", `String (Schedule_domain.recurrence_kind_to_string request.recurrence)
    ; "payload_digest", `String (Schedule_domain.payload_digest request.payload)
    ; ( "payload_kind"
      , match schedule_payload_kind request with
        | None -> `Null
        | Some kind -> `String kind )
    ; ( "last_execution"
      , match last_execution with
        | None -> `Null
        | Some execution -> execution_record_dashboard_json execution )
    ]
;;

let scheduled_automation_dashboard_json (config : Workspace.config) : Yojson.Safe.t =
  (* NDT-OK: dashboard read-model freshness clock; it derives display-only
     effective-due state and never mutates the schedule store or runs work. *)
  let now = Unix.gettimeofday () in
  let state = Schedule_store.read_state config in
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
  let due_execution_ready_count =
    state
    |> Schedule_store.due_execution_candidates
    |> List.filter (fun request -> not (schedule_effectively_expired ~now request))
    |> List.length
  in
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
    [ "schema", `String "masc.dashboard.scheduled_automation.v1"
    ; "source", `String "schedule_store"
    ; "generated_at", `String (Masc_domain.now_iso ())
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
          ] )
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
                schedule_request_dashboard_json ~now ~state ?last_execution request)
             request_rows) )
    ]
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
  let attach_scheduled_automation json =
    let scheduled_automation =
      run Tools_compute (fun () -> scheduled_automation_dashboard_json config)
    in
    match json with
    | `Assoc fields -> `Assoc (fields @ [ "scheduled_automation", scheduled_automation ])
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
  attach_scheduled_automation cached
;;

let dashboard_perf_http_json = Server_dashboard_http_perf.dashboard_perf_http_json
