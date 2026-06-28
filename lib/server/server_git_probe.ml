let git_rev_parse_short_ttl_sec = 60.0

module Rev_parse_cache =
  Server_probe_cache.Make (struct
    type value = string option

    let ttl_sec = git_rev_parse_short_ttl_sec
  end)

let set_git_rev_parse_short_probe_hook_for_tests =
  Rev_parse_cache.set_probe_hook_for_tests

let clear_git_rev_parse_short_probe_hook_for_tests =
  Rev_parse_cache.clear_probe_hook_for_tests

let clear_git_rev_parse_short_cache_for_tests () =
  Server_probe_cache.background_refresh_clear_unavailable_domains_for_tests ();
  Rev_parse_cache.clear_cache_for_tests ()

let seed_git_rev_parse_short_cache_for_tests =
  Rev_parse_cache.seed_cache_for_tests

let git_rev_parse_short_probe_argv dir =
  [ "git"; "-C"; dir; "--no-optional-locks"; "rev-parse"; "--short"; "HEAD" ]

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

let maybe_refresh_git_rev_parse_short_in_background dir =
  if Rev_parse_cache.try_begin_refresh dir
  then
    Server_probe_cache.fork_background_refresh_or_cancel
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
  Server_probe_cache.Make (struct
    type value = git_upstream_status option

    let ttl_sec = git_upstream_status_ttl_sec
  end)

let set_git_upstream_status_probe_hook_for_tests =
  Upstream_status_cache.set_probe_hook_for_tests

let clear_git_upstream_status_probe_hook_for_tests =
  Upstream_status_cache.clear_probe_hook_for_tests

let clear_git_upstream_status_cache_for_tests () =
  Server_probe_cache.background_refresh_clear_unavailable_domains_for_tests ();
  Upstream_status_cache.clear_cache_for_tests ()

let seed_git_upstream_status_cache_for_tests =
  Upstream_status_cache.seed_cache_for_tests

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

let git_default_origin_head dir =
  git_probe_trimmed dir [ "symbolic-ref"; "--short"; "refs/remotes/origin/HEAD" ]

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

let maybe_refresh_git_upstream_status_in_background dir =
  if Upstream_status_cache.try_begin_refresh dir
  then
    Server_probe_cache.fork_background_refresh_or_cancel
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
