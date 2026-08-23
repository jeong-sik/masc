(** Sandbox backend exec failure formatting + recording. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val status_label : Unix.process_status -> string

val docker_failure_message :
  image:string -> status:Unix.process_status -> output:string -> string

val record_docker_failure :
  config:Workspace.config ->
  meta:keeper_meta ->
  image:string ->
  container_kind:string ->
  network_label:string ->
  status:Unix.process_status ->
  output:string ->
  unit
