(** Background task lifecycle management for keeper shell.

    Extracted from keeper_exec_shell.ml — poll and kill operations
    for background bash tasks spawned by handle_keeper_bash. *)

open Keeper_types
open Keeper_exec_shared

(* ── Helpers ──────────────────────────────────────────────── *)

let status_to_json_opt = function
  | None -> `Null
  | Some st -> Keeper_alerting_path.process_status_to_json st

let signal_of_name_or_num args =
  match Safe_ops.json_string ~default:"" "signal" args |> String.uppercase_ascii with
  | "" | "TERM" | "SIGTERM" -> Sys.sigterm
  | "KILL" | "SIGKILL" -> Sys.sigkill
  | "INT" | "SIGINT" -> Sys.sigint
  | "HUP" | "SIGHUP" -> Sys.sighup
  | "QUIT" | "SIGQUIT" -> Sys.sigquit
  | raw ->
      (match int_of_string_opt raw with Some n -> n | None -> Sys.sigterm)

(* ── Poll ─────────────────────────────────────────────────── *)

let handle_keeper_bash_output
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t) =
  let _ = config in
  let raw_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
  let since_stdout = Safe_ops.json_int ~default:0 "since_stdout" args in
  let since_stderr = Safe_ops.json_int ~default:0 "since_stderr" args in
  if raw_id = "" then
    error_json
      "task_id is required. Example: task_id='bgt-<timestamp>-<seq>-<pid>'."
  else
    let tid = Bg_task.task_id_of_string_exn raw_id in
    match Bg_task.read tid ~since_stdout ~since_stderr with
    | Error (Bg_task.Unknown_task _) ->
        error_json
          (Printf.sprintf
             "no background task with id=%s (already reaped or never spawned)"
             raw_id)
    | Error (Bg_task.Read_failed msg) ->
        error_json (Printf.sprintf "bash_output read failed: %s" msg)
    | Ok snap ->
        let tid_str = Bg_task.task_id_to_string tid in
        let semantic_fields =
          if not (Masc_exec.Exec_semantic.enabled ()) then []
          else match snap.status with
          | None -> []
          | Some st ->
              let merged = snap.stdout_since ^ snap.stderr_since in
              let sem =
                Masc_exec.Exec_semantic.interpret_cmd
                  ~cmd:"" ~status:st ~output:merged
              in
              [
                ( "return_code_interpretation",
                  match Masc_exec.Exec_semantic.to_hint sem with
                  | None -> `Null
                  | Some h -> `String h );
              ]
        in
        Log.Keeper.info
          "BG_OUTPUT: keeper=%s task_id=%s closed=%b"
          meta.name tid_str snap.closed;
        Yojson.Safe.to_string
          (`Assoc
            ([
               ("ok", `Bool true);
               ("task_id", `String tid_str);
               ("stdout_since", `String snap.stdout_since);
               ("stderr_since", `String snap.stderr_since);
               ("closed", `Bool snap.closed);
               ("status", status_to_json_opt snap.status);
               ("bytes_dropped_stdout", `Int snap.bytes_dropped_stdout);
               ("bytes_dropped_stderr", `Int snap.bytes_dropped_stderr);
             ]
             @ semantic_fields))

(* ── Kill ─────────────────────────────────────────────────── *)

let handle_keeper_bash_kill
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t) =
  let _ = config in
  let raw_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
  let signal = signal_of_name_or_num args in
  let grace_sec =
    let raw = Safe_ops.json_float ~default:2.0 "grace_sec" args in
    if raw < 0.0 then 0.0
    else if raw > 30.0 then 30.0
    else raw
  in
  if raw_id = "" then
    error_json
      "task_id is required. Example: task_id='bgt-<timestamp>-<seq>-<pid>'."
  else
    let tid = Bg_task.task_id_of_string_exn raw_id in
    match Bg_task.kill tid ~signal ~grace_sec with
    | Error (Bg_task.Unknown_task_kill _) ->
        error_json
          (Printf.sprintf
             "no background task with id=%s (already reaped or never spawned)"
             raw_id)
    | Error (Bg_task.Kill_failed msg) ->
        error_json (Printf.sprintf "bash_kill failed: %s" msg)
    | Ok () ->
        let tid_str = Bg_task.task_id_to_string tid in
        Log.Keeper.info
          "BG_KILL: keeper=%s task_id=%s signal=%d grace=%.2f"
          meta.name tid_str signal grace_sec;
        Yojson.Safe.to_string
          (`Assoc
            [
              ("ok", `Bool true);
              ("task_id", `String tid_str);
              ("signal", `Int signal);
              ("grace_sec", `Float grace_sec);
            ])
