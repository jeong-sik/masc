(** Build identity for the running server process. *)

type t =
  { release_version : string
  ; binary_version : string
  ; repo_version : string option [@default None]
  ; commit : string option [@default None]
  ; commit_source : string option [@default None]
  ; commit_unix_ts : float option [@default None]
  ; commit_age_seconds : int option [@default None]
  ; binary_commit : string option [@default None]
  ; binary_commit_source : string option [@default None]
  ; binary_commit_unix_ts : float option [@default None]
  ; binary_commit_age_seconds : int option [@default None]
  ; repo_head_commit : string option [@default None]
  ; repo_head_commit_source : string option [@default None]
  ; repo_head_commit_unix_ts : float option [@default None]
  ; repo_head_commit_age_seconds : int option [@default None]
  ; executable_path : string [@default ""]
  ; executable_dir : string [@default ""]
  ; repo_root : string option [@default None]
  ; started_at : string
  ; uptime_seconds : int
  }
[@@deriving yojson { strict = false }]

let rec find_git_root dir =
  let git_marker = Filename.concat dir ".git" in
  if Sys.file_exists git_marker
  then Some dir
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else find_git_root parent)
;;

let runtime_cwd () = Config_dir_resolver.current_working_dir ()

let executable_path () =
  let cwd = runtime_cwd () in
  let argv0 = if Array.length Sys.argv > 0 then Sys.argv.(0) else cwd in
  let path = if Filename.is_relative argv0 then Filename.concat cwd argv0 else argv0 in
  try Unix.realpath path with
  | exn ->
    Log.Identity.warn
      "build_identity: Unix.realpath failed for %s: %s"
      path
      (Printexc.to_string exn);
    path
;;

let executable_dir () = Filename.dirname (executable_path ())

let git_capture_output_result ~repo_root args =
  let argv = [ "git"; "-C"; repo_root ] @ args in
  let raw_source = String.concat " " (List.map Filename.quote argv) in
  match
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:(Masc_exec.Agent_id.of_string "system/build_identity")
      ~raw_source
      ~summary:"build identity git probe"

      argv
  with
  | Unix.WEXITED 0, output -> Ok output
  | status, _ -> Error status
;;

let git_capture_output ~repo_root args =
  match git_capture_output_result ~repo_root args with
  | Ok output -> Some output
  | Error _ -> None
;;

let string_of_process_status = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
;;

let git_probe_from_root repo_root =
  let output =
    try git_capture_output ~repo_root [ "rev-parse"; "--short"; "HEAD" ] with
    | Sys_error msg ->
      Log.Identity.warn "git_probe_from_root read failed: %s" msg;
      None
    | Unix.Unix_error (code, fn, arg) ->
      Log.Identity.warn
        "git_probe_from_root unix error: %s (%s %s)"
        (Unix.error_message code)
        fn
        arg;
      None
    | exn ->
      Log.Identity.warn "git_probe_from_root unexpected: %s" (Printexc.to_string exn);
      None
  in
  Option.bind output String_util.trim_to_option
;;

let observe_probe_failure ~site exn =
  match exn with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_build_identity_probe_failures
      ~labels:[ "site", site ]
      ();
    Log.Identity.warn "build_identity %s failed: %s" site (Printexc.to_string exn)
;;

(** Pick the ordered list of directories to probe for a git repo,
    executable_dir first so the binary's own source tree wins over
    whatever cwd the user started the process from.

    Rationale: running `cd ~/me && ~/.../masc/_build/.../main_eio.exe`
    used to report ~/me's git HEAD instead of masc's because the old
    implementation sorted candidates with [List.sort_uniq String.compare]
    and cwd happened to sort first alphabetically.

    Pure — exposed for unit testing. *)
let pick_repo_candidates ~exe_dir ~cwd =
  if String.equal exe_dir cwd then [ exe_dir ] else [ exe_dir; cwd ]
;;

let probe_git_commit () =
  pick_repo_candidates ~exe_dir:(executable_dir ()) ~cwd:(runtime_cwd ())
  |> List.find_map (fun dir ->
    match find_git_root dir with
    | Some root -> git_probe_from_root root
    | None -> None)
;;

let probe_repo_root () =
  pick_repo_candidates ~exe_dir:(executable_dir ()) ~cwd:(runtime_cwd ())
  |> List.find_map find_git_root
;;

let parse_dune_project_version raw =
  raw
  |> String.split_on_char '\n'
  |> List.find_map (fun line ->
    let line = String.trim line in
    let prefix = "(version " in
    if String.starts_with ~prefix line && String.ends_with ~suffix:")" line
    then
      String.sub
        line
        (String.length prefix)
        (String.length line - String.length prefix - String.length ")")
      |> String_util.trim_to_option
    else None)
;;

let read_file path =
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))
    |> fun contents -> Some contents
  with
  | Sys_error _ -> None
  | exn ->
    Log.Identity.warn "build_identity read_file %s failed: %s" path (Printexc.to_string exn);
    None
;;

let executable_build_commit_stamp_source = "executable_build_commit_stamp"

let build_commit_stamp_path executable_path = executable_path ^ ".build-commit"

let repo_roots_for_runtime () =
  pick_repo_candidates ~exe_dir:(executable_dir ()) ~cwd:(runtime_cwd ())
  |> List.filter_map find_git_root
  |> List.fold_left
       (fun roots repo_root ->
          if List.exists (String.equal repo_root) roots then roots else repo_root :: roots)
       []
  |> List.rev
;;

let stamp_commit_exists_in_runtime_repo_roots commit_hash =
  let commit_ref = commit_hash ^ "^{commit}" in
  repo_roots_for_runtime ()
  |> List.exists (fun repo_root ->
    match git_capture_output_result ~repo_root [ "cat-file"; "-e"; commit_ref ] with
    | Ok _ -> true
    | Error _ -> false)
;;

let read_executable_build_commit_stamp executable_path =
  let stamp_path = build_commit_stamp_path executable_path in
  if not (Sys.file_exists stamp_path)
  then None
  else (
    try
      let stamp_stat = Unix.stat stamp_path in
      let exe_stat = Unix.stat executable_path in
      if stamp_stat.st_mtime < exe_stat.st_mtime
      then (
        Log.Identity.warn
          "build_identity: build commit stamp %s is older than executable %s"
          stamp_path
          executable_path;
        None)
      else (
        match Option.bind (read_file stamp_path) String_util.trim_to_option with
        | None ->
          observe_probe_failure
            ~site:"build_commit_stamp_empty"
            (Failure (Printf.sprintf "empty build commit stamp %s" stamp_path));
          None
        | Some commit when stamp_commit_exists_in_runtime_repo_roots commit -> Some commit
        | Some commit ->
          observe_probe_failure
            ~site:"build_commit_stamp_commit_verify"
            (Failure
               (Printf.sprintf
                  "build commit stamp %s does not name a commit object: %s"
                  stamp_path
                  commit));
          None)
    with
    | Unix.Unix_error (code, fn, arg) ->
      Log.Identity.warn
        "build_identity: cannot read build commit stamp %s: %s (%s %s)"
        stamp_path
        (Unix.error_message code)
        fn
        arg;
      None
    | exn ->
      Log.Identity.warn
        "build_identity: unexpected build commit stamp failure %s: %s"
        stamp_path
        (Printexc.to_string exn);
      None)
;;

let probe_repo_version repo_root =
  let dune_project = Filename.concat repo_root "dune-project" in
  Option.bind (read_file dune_project) parse_dune_project_version
;;

let decimal_digits_only s =
  String.length s > 0 && String.for_all (fun c -> c >= '0' && c <= '9') s
;;

(* 2100-01-01T00:00:00Z.  This keeps obviously corrupt/far-future git
   output out of /health while leaving enough workspace for normal source history
   and reproducible-build timestamps. *)
let max_reasonable_commit_unix_ts = 4_102_444_800L

let parse_commit_unix_ts_output raw =
  match String_util.trim_to_option raw with
  | None -> None
  | Some s when not (decimal_digits_only s) -> None
  | Some s ->
    (match Int64.of_string_opt s with
     | Some ts
       when Int64.compare ts 0L >= 0
            && Int64.compare ts max_reasonable_commit_unix_ts <= 0 ->
       Some (Int64.to_float ts)
     | _ -> None)
;;

(** Probe the unix timestamp of [commit] from the same git repo we
    resolved [commit] against.  Best-effort: returns [None] if [commit]
    is [None], the repo cannot be located, or git fails / output is
    not a sane integer Unix timestamp.

    Why we run this: a 2026-05-05 fleet-stuck recurrence boiled down
    to a deploy gap — the server kept running an 8-hour-old binary
    while every fix-PR shipped to main.  Health endpoint had no signal
    that the running binary was behind, so the operator (rightly)
    re-asked the same diagnostic prompt 7 times before noticing.
    Surfacing [commit_unix_ts] on /health closes that loop without
    requiring the dashboard to fetch anything from the git remote. *)
let probe_commit_unix_ts commit_hash_opt =
  match commit_hash_opt with
  | None -> None
  | Some commit_hash ->
    let repo_roots = repo_roots_for_runtime () in
    let probe_one repo_root =
      let raw_opt =
        try
          match
            git_capture_output_result
              ~repo_root
              [ "log"; "-1"; "--format=%ct"; commit_hash ]
          with
          | Ok raw -> Some raw
          | Error status ->
            observe_probe_failure
              ~site:"commit_ts_git_status"
              (Failure
                 (Printf.sprintf
                    "git log failed with %s"
                    (string_of_process_status status)));
            None
        with
        | exn ->
          observe_probe_failure ~site:"commit_ts_git_capture" exn;
          None
      in
      match raw_opt with
      | None -> None
      | Some raw ->
        (match parse_commit_unix_ts_output raw with
         | Some ts -> Some ts
         | None ->
           observe_probe_failure
             ~site:"commit_ts_parse"
             (Failure (Printf.sprintf "invalid commit timestamp output %S" raw));
           None)
    in
    List.find_map probe_one repo_roots
;;

let resolve_commit ~env_value ~probe =
  match env_value with
  | Some raw ->
    (match String_util.trim_to_option raw with
     | Some commit -> Some commit
     | None -> probe ())
  | None -> probe ()
;;

type commit_resolution =
  { commit : string option
  ; commit_source : string option
  ; binary_commit : string option
  ; binary_commit_source : string option
  ; repo_head_commit : string option
  ; repo_head_commit_source : string option
  }

let build_env_commit_source = "env:MASC_BUILD_GIT_COMMIT"
let runtime_repo_head_source = "runtime_repo_head"

let resolve_commit_details ?(stamp_value = None) ~env_value ~probe =
  let env_commit = Option.bind env_value String_util.trim_to_option in
  let stamp_commit = Option.bind stamp_value String_util.trim_to_option in
  let binary_commit, binary_commit_source =
    match env_commit, stamp_commit with
    | Some commit, _ -> Some commit, Some build_env_commit_source
    | None, Some commit -> Some commit, Some executable_build_commit_stamp_source
    | None, None -> None, None
  in
  let repo_head_commit = probe () in
  let commit, commit_source =
    match binary_commit, repo_head_commit with
    | Some commit, _ -> Some commit, binary_commit_source
    | None, Some commit -> Some commit, Some runtime_repo_head_source
    | None, None -> None, None
  in
  { commit
  ; commit_source
  ; binary_commit
  ; binary_commit_source
  ; repo_head_commit
  ; repo_head_commit_source = Option.map (fun _ -> runtime_repo_head_source) repo_head_commit
  }
;;

let age_seconds ~now ts_opt =
  match ts_opt with
  | None -> None
  | Some ts ->
    let age = now -. ts in
    if Float.is_finite age then Some (max 0 (int_of_float age)) else None
;;

let started_at_unix = Unix.gettimeofday ()
let started_at_iso = Masc_domain.iso8601_of_unix_seconds started_at_unix
let resolved_executable_path = executable_path ()
let resolved_executable_dir = Filename.dirname resolved_executable_path

(** Commit hashes — eagerly resolved at startup.
    Not using [Eio.Lazy] because this is called from tests without Eio context.
    Env var check + git probe are fast and side-effect-free. *)
let commit_resolution =
  resolve_commit_details
    ~env_value:(Env_config_core.build_git_commit_opt ())
    ~stamp_value:(read_executable_build_commit_stamp resolved_executable_path)
    ~probe:probe_git_commit
;;

let resolved_repo_root = probe_repo_root ()
let repo_root () = resolved_repo_root
let repo_version = Option.bind resolved_repo_root probe_repo_version
let commit_unix_ts = probe_commit_unix_ts commit_resolution.commit
let binary_commit_unix_ts = probe_commit_unix_ts commit_resolution.binary_commit
let repo_head_commit_unix_ts = probe_commit_unix_ts commit_resolution.repo_head_commit

let current () =
  let now = Unix.gettimeofday () in
  { release_version = Version.version
  ; binary_version = Version.version
  ; repo_version
  ; commit = commit_resolution.commit
  ; commit_source = commit_resolution.commit_source
  ; commit_unix_ts
  ; commit_age_seconds = age_seconds ~now commit_unix_ts
  ; binary_commit = commit_resolution.binary_commit
  ; binary_commit_source = commit_resolution.binary_commit_source
  ; binary_commit_unix_ts
  ; binary_commit_age_seconds = age_seconds ~now binary_commit_unix_ts
  ; repo_head_commit = commit_resolution.repo_head_commit
  ; repo_head_commit_source = commit_resolution.repo_head_commit_source
  ; repo_head_commit_unix_ts
  ; repo_head_commit_age_seconds = age_seconds ~now repo_head_commit_unix_ts
  ; executable_path = resolved_executable_path
  ; executable_dir = resolved_executable_dir
  ; repo_root = resolved_repo_root
  ; started_at = started_at_iso
  ; uptime_seconds = max 0 (int_of_float (now -. started_at_unix))
  }
;;

module For_testing = struct
  let observe_probe_failure = observe_probe_failure
  let probe_commit_unix_ts = probe_commit_unix_ts
  let runtime_cwd = runtime_cwd
  let stamp_commit_exists_in_runtime_repo_roots = stamp_commit_exists_in_runtime_repo_roots
end

(* [to_yojson] is generated by [ppx_deriving_yojson] from the type definition. *)
