(** Task_sandbox — Worktree-based per-task filesystem isolation.

    Wraps [Coord_worktree] to provide a higher-level sandbox lifecycle:
    create sandbox, run work, collect diff, cleanup.

    A sandbox consists of:
    - A git worktree branched from main
    - A read-only symlink to [.masc/] for room state access *)

type sandbox = {
  task_id : string;
  worktree_path : string;
  branch_name : string;
  created_at : float;
}

let exec_gate_raw_source argv =
  String.concat " " (List.map Filename.quote argv)

(** Run git command in the given directory and collect stdout lines. *)
let git_lines ~cwd args =
  let argv = ["git"; "-C"; cwd] @ args in
  Masc_exec.Exec_gate.run_argv
    ~actor:(Masc_exec.Agent_id.of_string "system/task_sandbox")
    ~raw_source:(exec_gate_raw_source argv)
    ~summary:"task_sandbox git"
    ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Task_sandbox_git ())
    argv
  |> String.split_on_char '\n'
  |> List.filter (fun s -> String.trim s <> "")

(** Run git command and get exit code. *)
let git_exit ~cwd args =
  let argv = ["git"; "-C"; cwd] @ args in
  match
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:(Masc_exec.Agent_id.of_string "system/task_sandbox")
      ~raw_source:(exec_gate_raw_source argv)
      ~summary:"task_sandbox git"
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Task_sandbox_git ())
      argv
  with
  | Unix.WEXITED n, _ -> n
  | Unix.WSIGNALED _, _ -> 128
  | Unix.WSTOPPED _, _ -> 128

(* Worktree-message regexes are static — hoist so the DFAs are built
   once at module init instead of per [extract_*] call. *)
let abs_path_re = Re.Pcre.re {|Path: (/[^ \t\n\r]+)|} |> Re.compile
let rel_worktree_re = Re.Pcre.re {|\.worktrees/[^ \t\n\r]+|} |> Re.compile
let branch_name_re = Re.Pcre.re {|Branch: ([^ \t\n\r]+)|} |> Re.compile

(** Extract absolute worktree path from [Coord_worktree.worktree_create_r]
    success message. Tries "Path: <absolute>" first, then falls back to
    constructing from a relative [.worktrees/...] segment. *)
let extract_worktree_path ~base_path msg =
  match Re.exec_opt abs_path_re msg with
  | Some g -> Some (Re.Group.get g 1)
  | None ->
    (match Re.exec_opt rel_worktree_re msg with
    | Some g -> Some (Filename.concat base_path (Re.Group.get g 0))
    | None -> None)

(** Extract branch name from success message.
    Format: "Branch: agent/task-NNN" *)
let extract_branch_name msg =
  match Re.exec_opt branch_name_re msg with
  | Some g -> Some (Re.Group.get g 1)
  | None -> None

(** Symlink [.masc/] from the repo root into the worktree for read-only
    access to room state. Idempotent: does nothing if link already exists. *)
let symlink_masc ~repo_root ~worktree_path =
  let masc_source = Common.masc_dir_from_base_path ~base_path:repo_root in
  let masc_target = Common.masc_dir_from_base_path ~base_path:worktree_path in
  if Sys.file_exists masc_source && not (Sys.file_exists masc_target) then
    try Unix.symlink masc_source masc_target; Ok ()
    with Unix.Unix_error (e, _, _) ->
      Error (Printf.sprintf "symlink .masc failed: %s" (Unix.error_message e))
  else
    Ok ()

let create ~config ~task_id ?(base_branch = "main") ?repo_name ~agent_name () =
  (* Delegate worktree creation to Coord_worktree via the Coord facade. *)
  match Coord_worktree.worktree_create_r ~link_task:true ?repo_name config
          ~agent_name ~task_id ~base_branch with
  | Error e ->
    Error (Printf.sprintf "worktree creation failed: %s"
             (Masc_domain.masc_error_to_string e))
  | Ok msg ->
    let base_path = config.base_path in
    match extract_worktree_path ~base_path msg with
    | None ->
      Error (Printf.sprintf
               "worktree created but path not found in response: %s" msg)
    | Some worktree_path ->
      let branch_name =
        extract_branch_name msg
        |> Option.value ~default:(Playground_paths.worktree_branch_name agent_name task_id)
      in
      (* Resolve git root for symlink *)
      let repo_root =
        match Coord_git.git_root ~base_path with
        | Some r -> r
        | None -> base_path
      in
      (* Symlink .masc/ into the worktree *)
      (match symlink_masc ~repo_root ~worktree_path with
       | Error e ->
         Log.Misc.warn "[task_sandbox] %s" e
       | Ok () -> ());
      Ok {
        task_id;
        worktree_path;
        branch_name;
        created_at = Time_compat.now ();
      }

let changed_files sandbox =
  try
    git_lines ~cwd:sandbox.worktree_path
      ["diff"; "--name-only"; "HEAD"]
    @ git_lines ~cwd:sandbox.worktree_path
        ["diff"; "--name-only"; "--cached"; "HEAD"]
    |> List.sort_uniq String.compare
  with Eio.Cancel.Cancelled _ as e -> raise e | Failure _ | Sys_error _ -> []

let cleanup ~config ~agent_name sandbox =
  (* Capture changed files before removal *)
  let files = changed_files sandbox in
  (* Also capture committed-but-not-yet-pushed changes *)
  let committed_files =
    try
      git_lines ~cwd:sandbox.worktree_path
        ["diff"; "--name-only"; "origin/main...HEAD"]
    with Eio.Cancel.Cancelled _ as e -> raise e | Failure _ | Sys_error _ -> []
  in
  let all_files =
    (files @ committed_files)
    |> List.sort_uniq String.compare
  in
  (* Remove worktree via Coord_worktree *)
  match Coord_worktree.worktree_remove_r config ~agent_name ~task_id:sandbox.task_id with
  | Ok _msg -> Ok all_files
  | Error e ->
    (* If removal fails, still return the files we found *)
    Log.Misc.warn "[task_sandbox] cleanup failed for %s: %s"
      sandbox.task_id (Masc_domain.masc_error_to_string e);
    (* Attempt force removal as fallback *)
    let rec find_git_owner dir =
      if Sys.file_exists (Filename.concat dir ".git") then Some dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then None else find_git_owner parent
    in
    let repo_root =
      match find_git_owner (Filename.dirname sandbox.worktree_path) with
      | Some root -> root
      | None ->
          let base_path = config.base_path in
          match Coord_git.git_root ~base_path with
          | Some r -> r
          | None -> base_path
    in
    let exit_code =
      git_exit ~cwd:repo_root
        ["worktree"; "remove"; "--force"; sandbox.worktree_path]
    in
    if exit_code = 0 then begin
      let prune_exit = git_exit ~cwd:repo_root ["worktree"; "prune"] in
      if prune_exit <> 0 then
        Log.Misc.warn "[task_sandbox] git worktree prune returned %d for %s"
          prune_exit sandbox.task_id;
      Ok all_files
    end else
      Error (Printf.sprintf "cleanup failed for %s: %s"
               sandbox.task_id (Masc_domain.masc_error_to_string e))

let with_sandbox ~config ~task_id ?base_branch ?repo_name ~agent_name f =
  match create ~config ~task_id ?base_branch ?repo_name ~agent_name () with
  | Error e -> Error e
  | Ok sandbox ->
    let result_ref = ref None in
    let exn_ref = ref None in
    Fun.protect
      ~finally:(fun () ->
        match cleanup ~config ~agent_name sandbox with
        | Ok files -> result_ref := Some files
        | Error e ->
          Log.Misc.warn "[task_sandbox] with_sandbox cleanup error: %s" e;
          result_ref := Some [])
      (fun () ->
        try
          let v = f sandbox in
          (* Capture files before cleanup *)
          let files = changed_files sandbox in
          result_ref := Some files;
          exn_ref := Some (Ok v)
        with e ->
          exn_ref := Some (Error e);
          raise e);
    (* After Fun.protect returns normally *)
    match !exn_ref with
    | Some (Ok v) ->
      let files = Option.value ~default:[] !result_ref in
      Ok (v, files)
    | Some (Error e) -> raise e
    | None ->
      Error "with_sandbox: unexpected state (no result captured)"
