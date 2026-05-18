(** Coord Worktree - Exec gate wrappers.

    Thin adapters over [Masc_exec.Exec_gate.run_argv*] that pin the actor tag
    and audit summary used throughout the worktree subsystem.  Default
    timeout is [Env_config_runtime.Coord_git.local_op_timeout_sec] (the
    short window appropriate for local-only git operations).  Network-bound
    operations must pass an explicit longer budget — see
    [Env_config_core.git_fetch_timeout_sec].

    Extracted from [coord_worktree.ml] (Stage 06, godfile decomposition
    plan 2026-05-18). *)

let exec_gate_raw_source argv =
  String.concat " " (List.map Filename.quote argv)

(** Run argv and get lines (Eio-native, no shell) *)
let run_argv_lines argv =
  Masc_exec.Exec_gate.run_argv
    ~actor:(Masc_exec.Agent_id.of_string "coord/worktree")
    ~raw_source:(exec_gate_raw_source argv)
    ~summary:"coord_worktree argv"
    ~timeout_sec:Env_config_runtime.Coord_git.local_op_timeout_sec
    argv
  |> String.split_on_char '\n'
  |> List.filter (fun s -> s <> "")

(** Run argv and get process status + combined output. *)
let run_argv_with_status
    ?(timeout_sec = Env_config_runtime.Coord_git.local_op_timeout_sec)
    argv =
  Masc_exec.Exec_gate.run_argv_with_status
    ~actor:(Masc_exec.Agent_id.of_string "coord/worktree")
    ~raw_source:(exec_gate_raw_source argv)
    ~summary:"coord_worktree argv"
    ~timeout_sec
    argv

(** Run argv and get exit code (Eio-native, no shell) *)
let run_argv_exit ?timeout_sec argv =
  match run_argv_with_status ?timeout_sec argv with
  | Unix.WEXITED n, _ -> n
  | Unix.WSIGNALED _, _ -> 128
  | Unix.WSTOPPED _, _ -> 128

let first_nonempty_line output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.find_opt (fun s -> s <> "")
