(** Docker exec failure formatting + recording.

    Single-concern module: format a structured failure message from a
    [Unix.process_status] + raw output, and (optionally) persist it on
    the keeper registry with [docker_mount_failure_details] for the
    dashboard. *)

open Keeper_types

(** [docker_exec_status_label status] returns the wire label for
    [status] (one of [exit=N], [signal=N], [stopped=N]). *)
val docker_exec_status_label : Unix.process_status -> string

(** [docker_exec_failure_message_internal ?base_path_hash ?keeper_name
      ?container_kind ?network_label ~image ~status ~output ()] returns
    the full human-readable failure message. Optional context fields
    enable the mount-failure context suffix. *)
val docker_exec_failure_message_internal
  :  ?base_path_hash:string
  -> ?keeper_name:string
  -> ?container_kind:string
  -> ?network_label:string
  -> image:string
  -> status:Unix.process_status
  -> output:string
  -> unit
  -> string

(** [docker_exec_failure_message ~image ~status ~output] is the
    context-less convenience wrapper. *)
val docker_exec_failure_message
  :  image:string
  -> status:Unix.process_status
  -> output:string
  -> string

(** [docker_exec_failure_message_with_context …] is the
    required-context wrapper used by [record_docker_exec_failure]. *)
val docker_exec_failure_message_with_context
  :  base_path_hash:string
  -> keeper_name:string
  -> container_kind:string
  -> network_label:string
  -> image:string
  -> status:Unix.process_status
  -> output:string
  -> string

(** [record_docker_exec_failure ~config ~meta ~image ~container_kind
      ~network_label ~status ~output] persists the failure via
    [Keeper_registry_error_recording.record], attaching
    [docker_mount_failure_details] for the dashboard. *)
val record_docker_exec_failure
  :  config:Coord.config
  -> meta:keeper_meta
  -> image:string
  -> container_kind:string
  -> network_label:string
  -> status:Unix.process_status
  -> output:string
  -> unit
