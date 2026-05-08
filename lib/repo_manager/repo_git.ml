open Repo_manager_types

let ensure_dir path =
  let rec loop dir =
    if dir = "" || dir = "." || Sys.file_exists dir then ()
    else begin
      loop (Filename.dirname dir);
      try Unix.mkdir dir 0o755
      with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  loop path

let merge_env overrides =
  let keys = List.map fst overrides in
  let has_key entry =
    match String.index_opt entry '=' with
    | None -> false
    | Some idx ->
        let key = String.sub entry 0 idx in
        List.exists (String.equal key) keys
  in
  let inherited =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry -> not (has_key entry))
  in
	Array.of_list
	  (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) overrides
	   @ inherited)

let git_terminal_prompt_key = "GIT_" ^ "TERMINAL_PROMPT"
let git_askpass_key = "GIT_" ^ "ASKPASS"

let env_of_credential credential =
  let non_interactive =
    [
      (git_terminal_prompt_key, "0");
      (git_askpass_key, "");
      ("SSH_ASKPASS", "");
      ("GCM_INTERACTIVE", "Never");
    ]
  in
  match credential.cred_type with
  | Github | Gitlab -> (
      match credential.gh_config_dir with
      | Some dir -> ("GH_CONFIG_DIR", dir) :: non_interactive
      | None -> non_interactive)
  | Local -> (
      match credential.ssh_key_path with
      | Some key -> ("GIT_SSH_COMMAND", Printf.sprintf "ssh -i %S" key) :: non_interactive
      | None -> non_interactive)

let split_lines text =
  if text = "" then []
  else String.split_on_char '\n' text |> List.filter (fun line -> line <> "")

let run_git ~cwd ?(env = []) args : (string list, string) result =
  let argv = "git" :: "-C" :: cwd :: args in
  let envp = merge_env env in
  let raw_source = String.concat " " (List.map Filename.quote argv) in
  let status, stdout, stderr =
    Masc_exec.Exec_gate.run_argv_with_status_split
      ~actor:(Masc_exec.Agent_id.of_string "repo-manager/git") ~raw_source ~summary:"repo manager git"
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Repo_manager_git ()) ~env:envp argv
  in
  match status with
  | Unix.WEXITED 0 -> Ok (split_lines stdout)
  | _ ->
      let status_text =
        match status with
        | Unix.WEXITED code -> Printf.sprintf "exit %d" code
        | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
        | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
      in
      let detail =
        let stderr = String.trim stderr in
        let stdout = String.trim stdout in
        if stderr <> "" then status_text ^ ": " ^ stderr
        else if stdout <> "" then status_text ^ ": " ^ stdout
        else status_text
      in
      Error (Printf.sprintf "git %s failed: %s" (String.concat " " args) detail)

let clone ~repository ~credential =
  let env = env_of_credential credential in
  let parent_dir = Filename.dirname repository.local_path in
  ensure_dir parent_dir;
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
  let safe_branch_path =
    String.map (function '/' | ':' | '\\' -> '-' | c -> c) branch
  in
  let worktree_path =
    Filename.concat repository.local_path (Printf.sprintf "_worktrees/%s" safe_branch_path)
  in
  ensure_dir (Filename.dirname worktree_path);
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
