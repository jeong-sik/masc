(* Container-aware git worktree gitdir path rewriter.

   `git worktree add` stamps absolute repo paths into `.git` gitfiles and
   into `<main>/.git/worktrees/<name>/gitdir`. When the same workspace is
   shared between a host and a Docker container with different mount
   roots, those stamps point to invalid paths inside the wrong root.

   This module:
   - enumerates candidate gitdir/gitfile stamps under [<host_root>/repos]
   - [prepare_*] rewrites host->container before the container runs
   - [repair_*]  rewrites container->host after the container exits

   Extracted from [Keeper_shell_docker] (godfile decomp). All side
   effects are filesystem reads/writes on git internal pointer files. *)

let safe_readdir dir =
  try
    if Sys.file_exists dir && Sys.is_directory dir
    then Sys.readdir dir |> Array.to_list
    else []
  with
  | Sys_error _ -> []
;;

let is_regular_file path =
  try (Unix.stat path).Unix.st_kind = Unix.S_REG with
  | Unix.Unix_error _ | Sys_error _ -> false
;;

let read_file path =
  let ic = open_in_bin path in
  Eio_guard.protect ~finally:(fun () -> close_in_noerr ic)
  @@ fun () -> really_input_string ic (in_channel_length ic)
;;

let write_file path content =
  let oc = open_out_bin path in
  Eio_guard.protect ~finally:(fun () -> close_out_noerr oc)
  @@ fun () -> output_string oc content
;;

let replace_all ~needle ~replacement source =
  if needle = ""
  then source
  else (
    let needle_len = String.length needle in
    let source_len = String.length source in
    let buf = Buffer.create source_len in
    let rec loop i =
      if i >= source_len
      then ()
      else if i + needle_len <= source_len && String.sub source i needle_len = needle
      then (
        Buffer.add_string buf replacement;
        loop (i + needle_len))
      else (
        Buffer.add_char buf source.[i];
        loop (i + 1))
    in
    loop 0;
    Buffer.contents buf)
;;

let candidates ~host_root =
  let repos_dir = Filename.concat host_root "repos" in
  safe_readdir repos_dir
  |> List.concat_map (fun repo_name ->
    let repo_root = Filename.concat repos_dir repo_name in
    if not (Sys.file_exists repo_root && Sys.is_directory repo_root)
    then []
    else (
      let worktree_gitfiles =
        let worktrees_dir = Filename.concat repo_root ".worktrees" in
        safe_readdir worktrees_dir
        |> List.map (fun name ->
          Filename.concat (Filename.concat worktrees_dir name) ".git")
      in
      let admin_gitdirs =
        let admin_worktrees =
          Filename.concat (Filename.concat repo_root ".git") "worktrees"
        in
        safe_readdir admin_worktrees
        |> List.map (fun name ->
          Filename.concat (Filename.concat admin_worktrees name) "gitdir")
      in
      worktree_gitfiles @ admin_gitdirs))
;;

(* Rewrite each candidate's contents, swapping [needle] for [replacement].
   Returns the number of files actually modified (idempotent on a
   no-op pass). Sys_error / End_of_file from a single file is skipped
   - the next sweep will retry. *)
let rewrite_each ~needle ~replacement paths =
  paths
  |> List.fold_left
       (fun changed path ->
          if not (is_regular_file path)
          then changed
          else (
            try
              let before = read_file path in
              let after = replace_all ~needle ~replacement before in
              if String.equal before after
              then changed
              else (
                write_file path after;
                changed + 1)
            with
            | Sys_error _ | End_of_file -> changed))
       0
;;

let repair ~host_root ~container_root =
  rewrite_each
    ~needle:container_root
    ~replacement:host_root
    (candidates ~host_root)
;;

let prepare ~host_root ~container_root =
  rewrite_each
    ~needle:host_root
    ~replacement:container_root
    (candidates ~host_root)
;;
