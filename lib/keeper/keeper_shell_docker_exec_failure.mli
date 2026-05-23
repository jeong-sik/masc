(** Docker exec failure formatting + recording.

    Extracted from [keeper_shell_docker.ml].  Owns the failure-message
    pipeline: status label → message formatting → registry recording. *)

(** Diagnostic label for a [Unix.process_status]:
    [exit=N] / [signal=N] / [stopped=N]. *)
val docker_exec_status_label : Unix.process_status -> string

(** Context-less failure message (kept for an existing external caller). *)
val docker_exec_failure_message :
  image:string -> status:Unix.process_status -> output:string -> string

(** Required-context wrapper used by [record_docker_exec_failure]. *)
val docker_exec_failure_message_with_context :
  base_path_hash:string ->
  keeper_name:string ->
  container_kind:string ->
  network_label:string ->
  image:string ->
  status:Unix.process_status ->
  output:string ->
  string

(** Persist the failure on the keeper registry along with structured
    [docker_mount_failure_details]. *)
val record_docker_exec_failure :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  image:string ->
  container_kind:string ->
  network_label:string ->
  status:Unix.process_status ->
  output:string ->
  unit
