(** Runtime-specific CLI and inspection contracts. This module does no I/O. *)
type mount = { source : string; destination : string }
type lookup = Name of string | Id of string

val owned_name : Lane_addon_types.runtime -> string -> string
val valid_id : string -> bool
val mount_argument : Lane_addon_types.runtime -> mount -> (string, string) result
val create_arguments :
  Lane_addon_types.package -> name:string -> instance_id:string -> image:string ->
  package_mount:string -> mounts:string list -> state_mounts:string list -> string list
val start_arguments : Lane_addon_types.runtime -> string -> string list
val inspect_arguments : Lane_addon_types.runtime -> string -> string list
val remove_arguments : Lane_addon_types.runtime -> string -> string list
val list_arguments : Lane_addon_types.runtime -> lookup -> string list
val listed_id : Lane_addon_types.runtime -> lookup -> string -> (string option, string) result
val verify_container :
  Lane_addon_types.runtime -> name:string -> resources:Lane_addon_types.resources ->
  image_digest:string option -> string -> (string, string) result
val verify_owner :
  Lane_addon_types.runtime -> instance_id:string -> name:string option -> id:string ->
  string -> (unit, string) result
val image_arguments : Lane_addon_types.runtime -> string -> string list
val image_digest : Lane_addon_types.runtime -> string -> (string, string) result
val volume_list_arguments : Lane_addon_types.runtime -> string -> string list
val listed_volume : Lane_addon_types.runtime -> name:string -> string -> (bool, string) result
val verify_volume :
  Lane_addon_types.runtime -> name:string -> owner:string -> string -> (unit, string) result
val state_mount : Lane_addon_types.runtime -> string -> string
