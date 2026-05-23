open Keeper_types

val rewrite_docker_command_paths :
  config:Coord.config ->
  meta:keeper_meta ->
  string ->
  string

val rewrite_docker_command_paths_for_host_validation :
  config:Coord.config ->
  meta:keeper_meta ->
  string ->
  string
