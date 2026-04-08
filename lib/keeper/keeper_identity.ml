(** Keeper_identity — Centralized keeper identity and trace ID management.

    Consolidates trace_id generation, session_id conventions, and
    git author/committer identity for keeper operations.

    - [trace_id] is generated per keeper creation and per handoff rollover.
    - [session_id] is set equal to [trace_id] in [create_session].
    - Directory layout: [.masc/traces/<trace_id>/] per execution trace.
    - Git identity: commits made by keepers are attributed via
      GIT_AUTHOR_NAME / GIT_COMMITTER_NAME environment variables.

    @since 2.162.0 — #3721 keeper stabilization
    @since 2.254.0 — git identity for keeper operations *)

(** Generate a new trace ID. Used at keeper creation and handoff rollover.
    Format: [trace-<epoch_ms>-<5hex>] *)
let generate_trace_id () : string =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFF in
  Printf.sprintf "trace-%d-%05x" ts hash

(* ── Git Identity ──────────────────────────────────────────────────── *)

(** Sanitize a keeper name for use in git author/email fields.
    Keeps [A-Za-z0-9._-], replaces everything else with ['_']. *)
let sanitize_name (name : string) : string =
  String.map (fun c ->
    if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
       || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
    then c else '_') name

let keeper_git_author ~(keeper_name : string) : string =
  let safe = sanitize_name keeper_name in
  Printf.sprintf "%s (MASC Keeper)" safe

let keeper_git_email ~(keeper_name : string) : string =
  let safe = sanitize_name keeper_name in
  Printf.sprintf "%s@masc.local" safe

let git_env_for_keeper ~(keeper_name : string) : string array =
  let author = keeper_git_author ~keeper_name in
  let email = keeper_git_email ~keeper_name in
  (* Inherit current process environment and override git identity vars *)
  let base_env = Unix.environment () in
  let filtered = Array.to_list base_env
    |> List.filter (fun s ->
      not (String.starts_with ~prefix:"GIT_AUTHOR_" s)
      && not (String.starts_with ~prefix:"GIT_COMMITTER_" s))
  in
  let overrides = [
    "GIT_AUTHOR_NAME=" ^ author;
    "GIT_AUTHOR_EMAIL=" ^ email;
    "GIT_COMMITTER_NAME=" ^ author;
    "GIT_COMMITTER_EMAIL=" ^ email;
  ] in
  Array.of_list (filtered @ overrides)
