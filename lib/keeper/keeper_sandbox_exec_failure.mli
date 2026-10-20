(** Sandbox backend exec failure formatting + recording. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val status_label : Unix.process_status -> string

val container_state_after_failed_run_label :
  (Keeper_sandbox_runtime.docker_container_state, string) result -> string
(** The state a probe found after [docker run] failed: [stopped] when the
    daemon created the container and it died, [absent] when the run was
    refused, [running] when another start won the name, [unknown] when the
    probe itself failed. *)

val docker_container_start_failure_message :
  ?base_path_hash:string ->
  ?keeper_name:string ->
  ?container_kind:string ->
  ?network_label:string ->
  image:string ->
  status:Unix.process_status ->
  container_state:(Keeper_sandbox_runtime.docker_container_state, string) result ->
  output:string ->
  unit ->
  string
(** The error a failed [docker run] of a keeper container reports. It always
    carries the exit status and the container state found afterwards, and
    says [<no output>] when the run printed nothing, so a bare container id
    on stdout no longer stands for the whole failure. A mount failure adds the
    same context suffix as {!docker_failure_message}. *)

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
