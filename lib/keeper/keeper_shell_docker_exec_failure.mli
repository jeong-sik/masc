(** Docker exec failure formatting + recording. *)

open Keeper_types

val docker_exec_status_label : Unix.process_status -> string

val docker_exec_failure_message_internal :
  ?base_path_hash:string ->
  ?keeper_name:string ->
  ?container_kind:string ->
  ?network_label:string ->
  image:string ->
  status:Unix.process_status ->
  output:string ->
  unit ->
  string

val docker_exec_failure_message :
  image:string -> status:Unix.process_status -> output:string -> string

val docker_exec_failure_message_with_context :
  base_path_hash:string ->
  keeper_name:string ->
  container_kind:string ->
  network_label:string ->
  image:string ->
  status:Unix.process_status ->
  output:string ->
  string

val record_docker_exec_failure :
  config:Coord.config ->
  meta:keeper_meta ->
  image:string ->
  container_kind:string ->
  network_label:string ->
  status:Unix.process_status ->
  output:string ->
  unit
