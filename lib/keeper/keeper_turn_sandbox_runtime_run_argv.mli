(** How the runtime spawns a process and reads its answer: the container
    spelling of a host path, the message of a failed docker exec, the scrubbed
    environment and the descriptor accounting every spawn shares, the argv
    runners with split output, stdin and pipelines, the runner of the build
    link requests, and the creation of the policy network with the gateway read
    back from it.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_turn_sandbox_runtime_record

val container_path_of_host :
  t ->
  host_path:string -> (string, string) result

val format_docker_exec_error :
  head_program:string -> st:Unix.process_status -> out:string -> string

val sandbox_environment : unit -> string array

val run_argv_with_status :
  ?timeout_sec:float -> string list -> Unix.process_status * string

val ensure_policy_network :
  Keeper_microvm_backend.t ->
  keeper_name:string ->
  Keeper_types_profile_sandbox.network_mode -> (string option, string) result

val output_for_status : stdout:string -> stderr:string -> string

val run_argv_with_status_split :
  ?timeout_sec:float ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?output_capture:Process_output_capture.t ->
  string list -> Unix.process_status * string * string

val run_build_link_effects :
  ?timeout_sec:float -> string list list -> Unix.process_status

val run_argv_with_stdin_and_status_split :
  ?timeout_sec:float ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?output_capture:Process_output_capture.t ->
  stdin_content:string ->
  string list ->
  Unix.process_status * string * string

val run_argv_pipeline_with_status_split :
  ?timeout_sec:float ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  Process_eio.pipeline_stage list ->
  (Unix.process_status * string * string, string) result
