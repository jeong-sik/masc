(** Docker preflight checks — mount source validation, egress policy,
    image availability, and credential bundle status. *)

val path_exists : string -> bool
val path_is_directory : string -> bool

val docker_mount_preflight_details :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  image:string ->
  container_kind:string ->
  network_label:string ->
  mount_path:string ->
  reason:string ->
  Yojson.Safe.t

val credential_preflight_failure_json :
  keeper_name:string -> message:string -> string

val is_credential_preflight_failure : string -> bool

val egress_policy_path :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string

val check_egress :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cmd:string ->
  string option

val ensure_docker_shell_image_available :
  image:string -> timeout_sec:float -> (unit, string) result
