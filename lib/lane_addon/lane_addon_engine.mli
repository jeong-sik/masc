(** Runtime-specific CLI and inspection contracts. This module does no I/O. *)
type mount = { source : string; destination : string }
type lookup = Name of string | Id of string
type image_identity
(** Validated local Docker image ID or Apple manifest digest, bound to its
    runtime. This observation belongs to one start, not to a mutable tag. *)
val image_of_inspect : Lane_addon_types.runtime -> string -> (image_identity, string) result
val image_digest : image_identity -> string
val image_identity_to_json : image_identity -> Yojson.Safe.t
(** Runtime and immutable digest observed during image resolution. This is not
    evidence that the container passed verification or started. *)
val image_create_reference : image_identity -> requested:string -> string
(** Docker creates by the observed immutable ID. Apple retains its requested
    reference and must prove the same manifest digest before process start. *)

val instance_label : string
val state_owner_label : string
val scope_label : string

(** A container as its inspection reports it. [name] is the bare name. A label
    that is missing, blank or only whitespace is [None]: it names nobody, and
    no default is made up for it. *)
type held = {
  container_id : string;
  name : string;
  instance : string option;
  state_owner : string option;
}

val owned_name : Lane_addon_types.runtime -> string -> string
val valid_id : string -> bool
val mount_argument : Lane_addon_types.runtime -> mount -> (string, string) result
val create_arguments :
  Lane_addon_types.container -> command:string list -> name:string -> instance_id:string -> state_owner:string option ->
  scope:string option -> image:string ->
  package_mount:string -> mounts:string list -> state_mounts:string list -> string list
val start_arguments : Lane_addon_types.runtime -> string -> string list
val inspect_arguments : Lane_addon_types.runtime -> string -> string list
val remove_arguments : Lane_addon_types.runtime -> string -> string list
val list_arguments : Lane_addon_types.runtime -> lookup -> string list
val listed_id : Lane_addon_types.runtime -> lookup -> string -> (string option, string) result
val verify_container :
  Lane_addon_types.runtime -> name:string -> resources:Lane_addon_types.resources ->
  image:image_identity -> string -> (string, string) result
val held_of_inspect : Lane_addon_types.runtime -> string -> (held, string) result
val scoped_list_arguments : Lane_addon_types.runtime -> string -> string list
val listed_scoped_ids : Lane_addon_types.runtime -> scope:string -> string -> (string list, string) result
(** The containers that carry this scope label, from a listing. *)
val info_arguments : Lane_addon_types.runtime -> string list
(** The engine identity command. Its exit status alone decides reachability. *)
val engine_of_info :
  Lane_addon_types.runtime -> string ->
  (Lane_addon_lifecycle.engine, Lane_addon_lifecycle.engine_fault) result
val image_arguments : Lane_addon_types.runtime -> string -> string list
val volume_list_arguments : Lane_addon_types.runtime -> string -> string list
val listed_volume : Lane_addon_types.runtime -> name:string -> string -> (bool, string) result
val verify_volume :
  Lane_addon_types.runtime -> name:string -> owner:string -> string -> (unit, string) result
val state_mount : Lane_addon_types.runtime -> string -> string
