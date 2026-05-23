(** Docker [docker run] argv construction.

    Pure-data transformation: assembles the complete [docker run --rm …]
    argument vector from resolved parameters.  No I/O, no side effects. *)

open Keeper_types

val docker_run_argv :
  config:Coord.config ->
  meta:keeper_meta ->
  container_name:string ->
  container_root:string ->
  container_cwd:string ->
  host_root:string ->
  network_label:string ->
  network_args:string list ->
  uid:int ->
  gid:int ->
  seccomp_args:string list ->
  cred_mounts:string list ->
  cred_envs:string list ->
  identity_mounts:string list ->
  image:string ->
  ttl_sec:float ->
  string list
