(** Build identity for the running server process. *)

type t = {
  release_version : string;
  commit : string option [@default None];
  commit_unix_ts : float option [@default None];
  commit_age_seconds : int option [@default None];
  started_at : string;
  uptime_seconds : int;
} [@@deriving yojson { strict = false }]

let iso8601_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let trim_to_option raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed

let rec find_git_root dir =
  let git_marker = Filename.concat dir ".git" in
  if Sys.file_exists git_marker then
    Some dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else find_git_root parent

let executable_dir () =
  let argv0 =
    if Array.length Sys.argv > 0 then Sys.argv.(0) else Sys.getcwd ()
  in
  let path =
    if Filename.is_relative argv0 then
      Filename.concat (Sys.getcwd ()) argv0
    else
      argv0
  in
  Filename.dirname path

let git_capture_output ~repo_root args =
  let argv = [ "git"; "-C"; repo_root ] @ args in
  let raw_source = String.concat " " (List.map Filename.quote argv) in
  match
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:"system/build_identity"
      ~raw_source
      ~summary:"build identity git probe"
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Build_identity ())
      argv
  with
  | Unix.WEXITED 0, output -> Some output
  | _ -> None

let git_probe_from_root repo_root =
  let output =
    try git_capture_output ~repo_root [ "rev-parse"; "--short"; "HEAD" ] with
    | Sys_error msg ->
        Log.Identity.warn "git_probe_from_root read failed: %s" msg;
        None
    | Unix.Unix_error (code, fn, arg) ->
        Log.Identity.warn "git_probe_from_root unix error: %s (%s %s)"
          (Unix.error_message code) fn arg;
        None
    | exn ->
        Log.Identity.warn "git_probe_from_root unexpected: %s" (Printexc.to_string exn);
        None
  in
  Option.bind output trim_to_option

(** Pick the ordered list of directories to probe for a git repo,
    executable_dir first so the binary's own source tree wins over
    whatever cwd the user started the process from.

    Rationale: running `cd ~/me && ~/.../masc-mcp/_build/.../main_eio.exe`
    used to report ~/me's git HEAD instead of masc-mcp's because the old
    implementation sorted candidates with [List.sort_uniq String.compare]
    and cwd happened to sort first alphabetically.

    Pure — exposed for unit testing. *)
let pick_repo_candidates ~exe_dir ~cwd =
  if String.equal exe_dir cwd then [ exe_dir ] else [ exe_dir; cwd ]

let probe_git_commit () =
  pick_repo_candidates
    ~exe_dir:(executable_dir ())
    ~cwd:(Sys.getcwd ())
  |> List.find_map (fun dir ->
         match find_git_root dir with
         | Some root -> git_probe_from_root root
         | None -> None)

let probe_repo_root () =
  pick_repo_candidates
    ~exe_dir:(executable_dir ())
    ~cwd:(Sys.getcwd ())
  |> List.find_map find_git_root

(** Probe the unix timestamp of [commit] from the same git repo we
    resolved [commit] against.  Best-effort: returns [None] if [commit]
    is [None], the repo cannot be located, or git fails / output is
    not a valid float.

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
    let candidates =
      pick_repo_candidates
        ~exe_dir:(executable_dir ())
        ~cwd:(Sys.getcwd ())
    in
    let probe_one dir =
      match find_git_root dir with
      | None -> None
      | Some repo_root ->
        let raw_opt =
          try
            git_capture_output ~repo_root
              [ "log"; "-1"; "--format=%ct"; commit_hash ]
          with _ -> None
        in
        (match raw_opt with
         | None -> None
         | Some raw ->
           (match trim_to_option raw with
            | None -> None
            | Some s -> float_of_string_opt s))
    in
    List.find_map probe_one candidates

let resolve_commit ~env_value ~probe =
  match env_value with
  | Some raw -> (
      match trim_to_option raw with
      | Some commit -> Some commit
      | None -> probe ())
  | None -> probe ()

let started_at_unix = Unix.gettimeofday ()
let started_at_iso = iso8601_of_unix started_at_unix

(** Commit hash — eagerly resolved at startup.
    Not using [Eio.Lazy] because this is called from tests without Eio context.
    Env var check + git probe are fast and side-effect-free. *)
let commit =
  resolve_commit
    ~env_value:(Env_config_core.build_git_commit_opt ())
    ~probe:probe_git_commit

let resolved_repo_root = probe_repo_root ()

let repo_root () = resolved_repo_root

let commit_unix_ts = probe_commit_unix_ts commit

let current () =
  let now = Unix.gettimeofday () in
  let commit_age_seconds =
    match commit_unix_ts with
    | None -> None
    | Some ts ->
      let age = now -. ts in
      if Float.is_finite age then Some (max 0 (int_of_float age)) else None
  in
  {
    release_version = Version.version;
    commit;
    commit_unix_ts;
    commit_age_seconds;
    started_at = started_at_iso;
    uptime_seconds = max 0 (int_of_float (now -. started_at_unix));
  }

(* [to_yojson] is generated by [ppx_deriving_yojson] from the type definition. *)
