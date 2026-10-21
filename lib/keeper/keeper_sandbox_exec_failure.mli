(** Sandbox backend exec failure formatting + recording. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val status_label : Unix.process_status -> string

val docker_run_failure_message :
  ?base_path_hash:string ->
  ?keeper_name:string ->
  ?container_kind:string ->
  ?network_label:string ->
  ?container_state:(Keeper_sandbox_runtime.docker_container_state, string) result ->
  prefix:string ->
  image:string ->
  status:Unix.process_status ->
  output:string ->
  unit ->
  string
(** The error a failed [docker run] of a keeper container reports:
    ["<prefix>: status=exit=N [container_after_run=...] output=<output>"].

    It always carries the exit status and says [<no output>] when the run
    printed nothing, so a bare container id on stdout no longer stands for the
    whole failure. [container_state] is the probe a caller ran by container
    name after the failure; when given, [container_after_run] is [stopped] (a
    container of that name exists and is not running), [absent] (none exists),
    [running], or [unknown] (the probe failed). It is an observation by name,
    not a statement of which run created the container. A mount failure adds
    the same context suffix as {!docker_failure_message}. *)

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
