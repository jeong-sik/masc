(** GitHub repository slug and origin discovery for keeper GH tools. *)

(** Regex matching --repo owner/name, --repo=owner/name, or -R owner/name in gh CLI commands. *)
let repo_flag_re =
  Re.compile
    (Re.seq
       [ Re.alt [ Re.str "--repo"; Re.str "-R" ]
       ; Re.alt [ Re.rep1 Re.blank; Re.str "=" ]
       ; Re.rep1 (Re.compl [ Re.blank ])
       ])
;;

let has_repo_flag cmd = Re.execp repo_flag_re cmd

let is_valid_repo_segment segment =
  segment <> ""
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-' | '_' -> true
         | _ -> false)
       segment
;;

let validate_repo_slug raw =
  let slug = String.trim raw in
  match String.split_on_char '/' slug with
  | [ owner; repo ] when is_valid_repo_segment owner && is_valid_repo_segment repo ->
    Ok (owner ^ "/" ^ repo)
  | _ -> Error "repo must be an owner/repo slug without spaces or extra flags."
;;

let rec strip_repo_flags_from_args = function
  | [] -> []
  | "--repo" :: _value :: rest | "-R" :: _value :: rest -> strip_repo_flags_from_args rest
  | arg :: rest when String.starts_with ~prefix:"--repo=" arg ->
    strip_repo_flags_from_args rest
  | arg :: rest -> arg :: strip_repo_flags_from_args rest
;;

let args_have_repo_flag args =
  List.exists
    (fun arg -> arg = "--repo" || arg = "-R" || String.starts_with ~prefix:"--repo=" arg)
    args
;;

let inject_repo_flag_args ~repo_slug args =
  [ "--repo"; repo_slug ] @ strip_repo_flags_from_args args
;;

let repo_slug_of_remote_url url =
  match Keeper_github_clone_policy.extract_github_org_repo url with
  | Some slug ->
    (match validate_repo_slug slug with
     | Ok v -> Some v
     | Error detail ->
       Log.Misc.warn "repo slug validation error discarded: %s" detail;
       None)
  | None -> None
;;

(** Read an origin slug from a concrete git config path without invoking git.
    This survives host/container worktree divergence where [.git] points at a
    container-only gitdir but the host-side parent clone config is readable. *)
let origin_url_of_git_config_path config_path =
  if not (Sys.file_exists config_path)
  then None
  else (
    let ic = open_in_bin config_path in
    Eio_guard.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let rec loop ~in_origin =
           match input_line ic with
           | line ->
             let trimmed = String.trim line in
             if trimmed = "" || String.starts_with ~prefix:";" trimmed
             then loop ~in_origin
             else if String.starts_with ~prefix:"[" trimmed
             then loop ~in_origin:(String.equal trimmed "[remote \"origin\"]")
             else if
               in_origin
               && (String.starts_with ~prefix:"url = " trimmed
                   || String.starts_with ~prefix:"url=" trimmed)
             then (
               let value =
                 if String.starts_with ~prefix:"url = " trimmed
                 then String.sub trimmed 6 (String.length trimmed - 6)
                 else String.sub trimmed 4 (String.length trimmed - 4)
               in
               Some (String.trim value))
             else loop ~in_origin
           | exception End_of_file -> None
         in
         loop ~in_origin:false))
;;

let repo_slug_of_git_config_path config_path =
  match origin_url_of_git_config_path config_path with
  | Some url -> repo_slug_of_remote_url url
  | None -> None
;;

let repo_slug_of_git_config ~git_root =
  Filename.concat git_root ".git/config" |> repo_slug_of_git_config_path
;;

let repo_root_inferred_from_worktree_cwd worktree_cwd =
  let marker = "/.worktrees/" in
  match String_util.find_substring worktree_cwd marker with
  | None -> None
  | Some idx -> Some (String.sub worktree_cwd 0 idx)
;;

let origin_url_of_worktree_parent_config ~worktree_cwd =
  match repo_root_inferred_from_worktree_cwd worktree_cwd with
  | Some repo_root ->
    origin_url_of_git_config_path (Filename.concat repo_root ".git/config")
  | None -> None
;;

let origin_url_of_worktree_gitfile ~worktree_cwd =
  let dotgit = Filename.concat worktree_cwd ".git" in
  if (not (Sys.file_exists dotgit)) || Sys.is_directory dotgit
  then None
  else (
    try
      let line =
        let ic = open_in_bin dotgit in
        Eio_guard.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> input_line ic)
      in
      let prefix = "gitdir:" in
      let trimmed = String.trim line in
      if not (String.starts_with ~prefix trimmed)
      then None
      else (
        let raw =
          String.sub
            trimmed
            (String.length prefix)
            (String.length trimmed - String.length prefix)
          |> String.trim
        in
        let gitdir =
          if Filename.is_relative raw then Filename.concat worktree_cwd raw else raw
        in
        match origin_url_of_git_config_path (Filename.concat gitdir "config") with
        | Some _ as origin -> origin
        | None ->
          let common_git_dir = Filename.dirname (Filename.dirname gitdir) in
          origin_url_of_git_config_path (Filename.concat common_git_dir "config"))
    with
    | Sys_error _ | End_of_file -> None)
;;

let origin_url_of_git_command ~cwd =
  let argv = [ "git"; "remote"; "get-url"; "origin" ] in
  match
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:`Coord_git
      ~raw_source:(String.concat " " argv)
      ~summary:"keeper gh origin url from git"
      ~cwd
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Git_meta ())
      argv
  with
  | Unix.WEXITED 0, url ->
    let url = String.trim url in
    if url = "" then None else Some url
  | _ -> None
;;

let origin_url_of_task_worktree ~git_root ~worktree_cwd =
  [ (fun () -> origin_url_of_git_config_path (Filename.concat git_root ".git/config"))
  ; (fun () -> origin_url_of_worktree_parent_config ~worktree_cwd)
  ; (fun () -> origin_url_of_worktree_gitfile ~worktree_cwd)
  ; (fun () -> origin_url_of_git_command ~cwd:git_root)
  ; (fun () -> origin_url_of_git_command ~cwd:worktree_cwd)
  ]
  |> List.find_map (fun f -> f ())
;;

let repo_slug_of_task_worktree ~git_root ~worktree_cwd =
  match origin_url_of_task_worktree ~git_root ~worktree_cwd with
  | Some url -> repo_slug_of_remote_url url
  | None -> None
;;

let repo_slug_of_git_root ~git_root =
  match repo_slug_of_git_config ~git_root with
  | Some slug -> Some slug
  | None ->
    (match origin_url_of_git_command ~cwd:git_root with
     | Some url -> repo_slug_of_remote_url url
     | None -> None)
;;
