(** MASC Git Worktree Operations

    Provides Git worktree isolation for multi-agent parallel work.
    Implementation is argv-based (no shell) to avoid injection and quoting bugs.
*)

open Types

(* ============================================ *)
(* argv-based process helpers                   *)
(* ============================================ *)

(** Run argv and return first non-empty line. *)
let run_argv_line (argv : string list) : string option =
  let output = Process_eio.run_argv ~timeout_sec:30.0 argv in
  match String.split_on_char '\n' output |> List.map String.trim |> List.filter (fun s -> s <> "") with
  | [] -> None
  | h :: _ -> Some h

(** Run argv and return exit code. *)
let run_argv_exit (argv : string list) : int =
  match Process_eio.run_argv_with_status ~timeout_sec:30.0 argv with
  | Unix.WEXITED n, _ -> n
  | Unix.WSIGNALED _, _ -> 128
  | Unix.WSTOPPED _, _ -> 128

let run_argv_lines (argv : string list) : string list =
  Process_eio.run_argv ~timeout_sec:30.0 argv
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

(* ============================================ *)
(* Input Validation                             *)
(* ============================================ *)

(** Validate branch/path components — alphanumeric + /_-. only *)
let is_valid_branch_name s =
  String.length s > 0
  && String.length s < 256
  && s |> String.to_seq |> Seq.for_all (fun c ->
       (c >= 'a' && c <= 'z')
       || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9')
       || c = '/'
       || c = '_'
       || c = '-'
       || c = '.')

(* ============================================ *)
(* Git Repository Utilities                     *)
(* ============================================ *)

(** Fast check for .git marker by walking parent directories.
    Avoids spawning a subprocess when clearly not in a git repo. *)
let has_git_marker path =
  let rec walk dir =
    let marker = Filename.concat dir ".git" in
    if Sys.file_exists marker then true
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then false else walk parent
  in
  try walk path with Sys_error _ -> false

(** Get git root directory *)
let git_root ~base_path =
  if not (has_git_marker base_path) then None
  else run_argv_line ["git"; "-C"; base_path; "rev-parse"; "--show-toplevel"]

(** Check if directory is a git repository *)
let is_git_repo ~base_path =
  has_git_marker base_path
  && match git_root ~base_path with
     | Some _ -> true
     | None -> false

let remote_branch_exists root branch =
  if not (is_valid_branch_name branch) then false
  else
    run_argv_exit
      [
        "git";
        "-C";
        root;
        "show-ref";
        "--verify";
        "--quiet";
        Printf.sprintf "refs/remotes/origin/%s" branch;
      ]
    = 0

let origin_head_branch root =
  let line = run_argv_line ["git"; "-C"; root; "symbolic-ref"; "-q"; "refs/remotes/origin/HEAD"] in
  match line with
  | None -> None
  | Some refname -> (
      match List.rev (String.split_on_char '/' refname) with
      | branch :: _ -> Some branch
      | [] -> None)

let resolve_base_branch root base_branch =
  if remote_branch_exists root base_branch then Ok (base_branch, None)
  else
    let candidates =
      match origin_head_branch root with
      | Some head -> [head; "main"; "master"]
      | None -> ["main"; "master"]
    in
    match List.find_opt (remote_branch_exists root) candidates with
    | Some fallback -> Ok (fallback, Some base_branch)
    | None ->
        Error
          (IoError
             (Printf.sprintf
                "Base branch origin/%s not found and no fallback branch detected." base_branch))

(* ============================================ *)
(* Worktree Operations                          *)
(* ============================================ *)

(** Create worktree for agent *)
let create ~base_path ~agent_name ~task_id ~base_branch : string masc_result =
  if not (is_git_repo ~base_path) then
    Error (IoError "Not a git repository. MASC v2 requires .git directory for worktree isolation.")
  else
    match git_root ~base_path with
    | None -> Error (IoError "Cannot determine git root")
    | Some root ->
        let worktree_name = Playground_paths.worktree_dir_name agent_name task_id in
        let worktree_path = Filename.concat root (Filename.concat ".worktrees" worktree_name) in
        let branch_name = Playground_paths.worktree_branch_name agent_name task_id in

        (* Create .worktrees directory if not exists *)
        let worktrees_dir = Filename.concat root ".worktrees" in
        Fs_compat.mkdir_p worktrees_dir;

        if Sys.file_exists worktree_path then
          Ok
            (Printf.sprintf "✅ Worktree already exists:\n  Path: %s\n  Branch: %s\n\nNext: cd %s"
               worktree_path branch_name worktree_path)
        else (
          (* Fetch origin first *)
          let _ = run_argv_exit ["git"; "-C"; root; "fetch"; "origin"] in
          match resolve_base_branch root base_branch with
          | Error e -> Error e
          | Ok (resolved_base, fallback_from) ->
              let note =
                match fallback_from with
                | None -> ""
                | Some missing ->
                    Printf.sprintf "\n  Note: origin/%s not found; used origin/%s" missing
                      resolved_base
              in
              let exit_code =
                run_argv_exit
                  [
                    "git";
                    "-C";
                    root;
                    "worktree";
                    "add";
                    worktree_path;
                    "-b";
                    branch_name;
                    Printf.sprintf "origin/%s" resolved_base;
                  ]
              in
              if exit_code = 0 then
                Ok
                  (Printf.sprintf
                     "✅ Worktree created:\n  Path: %s\n  Branch: %s%s\n\nNext: cd %s && work && gh pr create --draft"
                     worktree_path branch_name note worktree_path)
              else Error (IoError (Printf.sprintf "Failed to create worktree from origin/%s." resolved_base)))

(** Remove worktree after work is merged *)
let remove ~base_path ~agent_name ~task_id : string masc_result =
  match git_root ~base_path with
  | None -> Error (IoError "Cannot determine git root")
  | Some root ->
      let worktree_name = Playground_paths.worktree_dir_name agent_name task_id in
      let worktree_path = Filename.concat root (Filename.concat ".worktrees" worktree_name) in
      let branch_name = Playground_paths.worktree_branch_name agent_name task_id in

      if not (Sys.file_exists worktree_path) then
        Error (IoError (Printf.sprintf "Worktree not found: %s" worktree_path))
      else
        let exit_code =
          run_argv_exit ["git"; "-C"; root; "worktree"; "remove"; worktree_path]
        in
        if exit_code = 0 then (
          let _ = run_argv_exit ["git"; "-C"; root; "branch"; "-d"; branch_name] in
          let _ = run_argv_exit ["git"; "-C"; root; "worktree"; "prune"] in
          Ok (Printf.sprintf "✅ Worktree removed: %s\n   Branch: %s" worktree_path branch_name))
        else Error (IoError "Failed to remove worktree. It may have uncommitted changes.")

(** List all worktrees in the repository *)
let list ~base_path =
  match git_root ~base_path with
  | None -> `Assoc [("error", `String "Not a git repository")]
  | Some root ->
      let lines = run_argv_lines ["git"; "-C"; root; "worktree"; "list"; "--porcelain"] in

      (* Parse porcelain output into worktree info *)
      let rec parse_worktrees lines current acc =
        match lines with
        | [] ->
            if current <> [] then List.rev (List.rev current :: acc) else List.rev acc
        | "" :: rest ->
            if current <> [] then parse_worktrees rest [] (List.rev current :: acc)
            else parse_worktrees rest [] acc
        | line :: rest -> parse_worktrees rest (line :: current) acc
      in
      let worktree_blocks = parse_worktrees lines [] [] in

      let parse_block block =
        let path = ref "" in
        let branch = ref "" in
        List.iter
          (fun line ->
            if String.length line > 9 && String.sub line 0 9 = "worktree " then
              path := String.sub line 9 (String.length line - 9)
            else if String.length line > 7 && String.sub line 0 7 = "branch " then
              branch := String.sub line 7 (String.length line - 7))
          block;
        if !path <> "" then
          Some
            (`Assoc
              [
                ("path", `String !path);
                ("branch", `String !branch);
                (* Check if path contains .worktrees - stdlib compatible *)
                ("is_masc", `Bool (Re.execp (Re.compile (Re.str ".worktrees")) !path));
              ])
        else None
      in

      let worktrees = List.filter_map parse_block worktree_blocks in
      `Assoc
        [
          ("worktrees", `List worktrees);
          ("count", `Int (List.length worktrees));
          ("masc_hint", `String "Use masc_worktree_create to add a new worktree for your task");
        ]

(** Get worktree info for a specific agent/task *)
let get_info ~base_path ~agent_name ~task_id =
  match git_root ~base_path with
  | None -> None
  | Some root ->
      let worktree_name = Playground_paths.worktree_dir_name agent_name task_id in
      let worktree_path = Filename.concat root (Filename.concat ".worktrees" worktree_name) in
      let branch_name = Playground_paths.worktree_branch_name agent_name task_id in
      if Sys.file_exists worktree_path then Some (worktree_path, branch_name) else None
