open Repo_manager_types

let env_of_credential credential =
  match credential.cred_type with
  | Github | Gitlab -> (
      match credential.gh_config_dir with
      | Some dir -> [Printf.sprintf "GH_CONFIG_DIR=%s" dir]
      | None -> [])
  | Local -> (
      match credential.ssh_key_path with
      | Some key -> [Printf.sprintf "GIT_SSH_COMMAND=ssh -i %s" key]
      | None -> [])

let run_git ~cwd ?(env = []) args =
  let env_prefix =
    if env = [] then "" else String.concat " " env ^ " "
  in
  let cmd =
    Printf.sprintf "%sgit -C %S %s" env_prefix cwd
      (String.concat " " (List.map Filename.quote args))
  in
  let ic = Unix.open_process_in cmd in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let rec loop acc =
        match input_line ic with
        | line -> loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      let lines = loop [] in
      match Unix.close_process_in ic with
      | Unix.WEXITED 0 -> Ok lines
      | _ -> Error (Printf.sprintf "git command failed: %s" cmd))

let clone ~repository ~credential =
  let env = env_of_credential credential in
  let parent_dir = Filename.dirname repository.local_path in
  (try
     if not (Sys.file_exists parent_dir) then
       Sys.mkdir parent_dir 0o755
   with Sys_error _ -> ());
  match
    run_git ~cwd:parent_dir ~env
      ["clone"; repository.url; repository.local_path]
  with
  | Ok _ -> Ok ()
  | Error msg -> Error msg

let fetch ~repository ~credential : (string list, string) result =
  let env = env_of_credential credential in
  match run_git ~env ~cwd:repository.local_path ["fetch"; "--all"] with
  | Error msg -> Error msg
  | Ok _ -> (
      match
        run_git ~cwd:repository.local_path
          ["branch"; "-r"; "--format=%(refname:short)"]
      with
      | Ok lines -> Ok lines
      | Error msg -> Error msg)

let checkout_worktree ~repository ~branch =
  let worktree_path =
    Filename.concat repository.local_path (Printf.sprintf "_worktrees/%s" branch)
  in
  (try
     if not (Sys.file_exists worktree_path) then
       let parent = Filename.dirname worktree_path in
       if not (Sys.file_exists parent) then Sys.mkdir parent 0o755
   with Sys_error _ -> ());
  match
    run_git ~cwd:repository.local_path
      ["worktree"; "add"; worktree_path; branch]
  with
  | Ok _ -> Ok worktree_path
  | Error msg -> Error msg

let get_branches ~repository =
  match
    run_git ~cwd:repository.local_path
      ["branch"; "-a"; "--format=%(refname:short)"]
  with
  | Ok lines -> Ok lines
  | Error msg -> Error msg

let get_recent_commits ~repository ~branch ~limit =
  match
    run_git ~cwd:repository.local_path
      ["log"; branch; "-n"; string_of_int limit; "--oneline"]
  with
  | Ok lines -> Ok lines
  | Error msg -> Error msg
