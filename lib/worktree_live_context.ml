let run_git_capture_lines ~workdir args =
  try
    let argv = [ "git"; "-C"; workdir ] @ args in
    let raw_source = String.concat " " (List.map Filename.quote argv) in
    match
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:"system/worktree_live_context"
        ~raw_source
        ~summary:"worktree live context git capture"
        ~timeout_sec:5.0
        argv
    with
    | Unix.WEXITED 0, output ->
        Some
          (output
          |> String.split_on_char '\n'
          |> List.filter (fun line -> String.trim line <> ""))
    | _ -> None
  with Sys_error _ | Unix.Unix_error _ -> None

let repo_root_for ~base_path =
  if not (Coord_git.has_git_marker base_path) then None
  else
  match run_git_capture_lines ~workdir:base_path [ "rev-parse"; "--show-toplevel" ] with
  | Some (root :: _) ->
      let root = String.trim root in
      if root = "" then None else Some root
  | _ -> None

let current_status_lines ~repo_root =
  run_git_capture_lines ~workdir:repo_root [ "status"; "--porcelain" ]
  |> Option.value ~default:[]
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")

let state_dir ~repo_root =
  Filename.concat (Filename.concat repo_root ".masc") "live-context"

let state_file ~repo_root ~actor_key =
  let safe_key = Coord_utils.safe_filename actor_key in
  Filename.concat (state_dir ~repo_root)
    (Printf.sprintf "%s.git-status-hash" safe_key)

let read_file_if_exists path =
  try
    if Fs_compat.file_exists path then
      Some (String.trim (Fs_compat.load_file path))
    else
      None
  with Sys_error _ -> None

let write_text path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path content

let hash_lines lines =
  Digest.string (String.concat "\n" lines) |> Digest.to_hex

let change_block_of_lines lines =
  let visible_lines =
    if List.length lines > 20 then
      List.filteri (fun idx _ -> idx < 20) lines
    else
      lines
  in
  let change_count = List.length lines in
  Printf.sprintf
    "<git_status_change>\nWorking tree changed since last keeper turn (%d files):\n%s\n</git_status_change>"
    change_count
    (String.concat "\n" visible_lines)

let capture_change_block ~base_path ~actor_key =
  match repo_root_for ~base_path with
  | None -> None
  | Some repo_root ->
      let lines = current_status_lines ~repo_root in
      let current_hash = hash_lines lines in
      let path = state_file ~repo_root ~actor_key in
      let previous_hash = read_file_if_exists path |> Option.value ~default:"" in
      write_text path current_hash;
      if lines = [] || current_hash = previous_hash then None
      else Some (change_block_of_lines lines)
