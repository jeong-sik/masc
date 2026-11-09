(** Running a command in the Docker container of a turn: the argv of an exec
    with the paths rewritten to the container, the runners that return split
    output or write it to files, the exec pipeline and its stage, and the
    runner that checks the exit code and cuts the output.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_turn_sandbox_runtime_record

val exec_argv :
  ?stdin:bool ->
  ?timeout_sec:float ->
  validate_cached_container:bool ->
  t ->
  cwd:string ->
  command_argv:string list ->
  (string list, string) result

val run_exec_with_status_split :
  ?stdin_content:string ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?timeout_sec:float ->
  t ->
  cwd:string ->
  command_argv:string list ->
  (Unix.process_status * string * string, string) result

val run_exec_with_output_files :
  ?stdin_content:string ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?timeout_sec:float ->
  capture_dir:string ->
  t ->
  cwd:string ->
  command_argv:string list ->
  (Unix.process_status * string * string * Process_output_capture.files option, string) result

type exec_pipeline_stage = {
  command_argv : string list;
  cwd : string option;
}

val run_exec_pipeline_with_status :
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?timeout_sec:float ->
  t ->
  cwd:string ->
  stages:exec_pipeline_stage list ->
  (Unix.process_status * string * string, string) result

val run_command_with_status :
  ?ok_exit_codes:int list ->
  timeout_sec:float ->
  t ->
  cwd:string ->
  command_argv:string list ->
  max_bytes:int ->
  unit ->
  (Unix.process_status * string, string) result
