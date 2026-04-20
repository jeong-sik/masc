type git_capture_hook =
  workdir:string -> string list -> string list option

let git_capture_hook_for_tests : git_capture_hook option Atomic.t =
  Atomic.make None

let set_git_capture_hook_for_tests hook =
  Atomic.set git_capture_hook_for_tests (Some hook)

let clear_git_capture_hook_for_tests () =
  Atomic.set git_capture_hook_for_tests None

(* `git status --porcelain` timeout budget.

   The 5.0s default hit its ceiling 30x in a 45-minute fleet window on
   2026-04-20 when the workdir was a Second Brain root with many
   worktrees, thousands of untracked files, and concurrent indexer
   activity. Each timeout falls through to stale cache (live context
   goes quiet for the keeper) and emits a WARN.

   15.0s covers p99 for large working trees without meaningfully
   stretching keeper turn latency — the call is cached (see
   [status_cache_ttl_sec] below) so the full budget is paid at most
   once per TTL window per repo. Env var stays the escape hatch for
   unusually slow hosts. *)
let default_git_status_timeout_sec = 15.0

let git_status_timeout_sec () =
  match Sys.getenv_opt "MASC_WORKTREE_GIT_STATUS_TIMEOUT_SEC" with
  | Some raw ->
    (match float_of_string_opt (String.trim raw) with
     | Some v when v > 0. -> v
     | _ -> default_git_status_timeout_sec)
  | None -> default_git_status_timeout_sec

let run_git_capture_lines_once ~workdir args =
  try
    let argv = [ "git"; "-C"; workdir ] @ args in
    let raw_source = String.concat " " (List.map Filename.quote argv) in
    match
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:"system/worktree_live_context"
        ~raw_source
        ~summary:"worktree live context git capture"
        ~timeout_sec:(git_status_timeout_sec ())
        argv
    with
    | Unix.WEXITED 0, output ->
        Some
          (output
          |> String.split_on_char '\n'
          |> List.filter (fun line -> String.trim line <> ""))
    | _ -> None
  with Sys_error _ | Unix.Unix_error _ -> None

let run_git_capture_lines ~workdir args =
  match Atomic.get git_capture_hook_for_tests with
  | Some hook -> hook ~workdir args
  | None ->
      let rec loop attempts_left =
        match run_git_capture_lines_once ~workdir args with
        | Some _ as result -> result
        | None when attempts_left > 0 -> loop (attempts_left - 1)
        | None -> None
      in
      loop 1

let nearest_git_root path =
  let rec walk dir =
    let marker = Filename.concat dir ".git" in
    if Sys.file_exists marker then Some dir
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else walk parent
  in
  try walk path with Sys_error _ -> None

let repo_root_for ~base_path =
  if not (Coord_git.has_git_marker base_path) then None
  else nearest_git_root base_path

type status_cache_entry = {
  lines : string list;
  refreshed_at : float;
}

let status_cache : (string, status_cache_entry) Hashtbl.t =
  Hashtbl.create 4

let status_cache_mu = Stdlib.Mutex.create ()

let status_cache_ttl_sec () =
  match Sys.getenv_opt "MASC_WORKTREE_STATUS_CACHE_TTL_S" with
  | Some raw -> (
      match float_of_string_opt (String.trim raw) with
      | Some ttl when ttl >= 0.0 && ttl <= 10.0 -> ttl
      | _ -> 1.0)
  | None -> 1.0

let status_cache_lookup repo_root ~now ~ttl =
  if ttl <= 0.0 then None
  else begin
    Stdlib.Mutex.lock status_cache_mu;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock status_cache_mu)
      (fun () ->
        match Hashtbl.find_opt status_cache repo_root with
        | Some entry when now -. entry.refreshed_at <= ttl ->
            Some entry.lines
        | _ -> None)
  end

let status_cache_store repo_root lines ~now ~ttl =
  if ttl > 0.0 && lines <> [] then begin
    Stdlib.Mutex.lock status_cache_mu;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock status_cache_mu)
      (fun () ->
        Hashtbl.replace status_cache repo_root { lines; refreshed_at = now })
  end

let clear_status_cache_for_tests () =
  Stdlib.Mutex.lock status_cache_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock status_cache_mu)
    (fun () -> Hashtbl.clear status_cache)

let current_status_lines_uncached ~repo_root =
  run_git_capture_lines ~workdir:repo_root
    [ "--no-optional-locks"; "status"; "--porcelain" ]
  |> Option.value ~default:[]
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")

let current_status_lines ~repo_root =
  let now = Time_compat.now () in
  let ttl = status_cache_ttl_sec () in
  match status_cache_lookup repo_root ~now ~ttl with
  | Some lines -> lines
  | None ->
      let lines = current_status_lines_uncached ~repo_root in
      status_cache_store repo_root lines ~now:(Time_compat.now ()) ~ttl;
      lines

let state_dir ~repo_root =
  Filename.concat
    (Coord_utils.masc_dir_from_base_path ~base_path:repo_root)
    "live-context"

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
