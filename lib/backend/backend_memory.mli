(** In-memory backend implementation used by tests and local ephemeral state. *)

type t

val create : unit -> t
val get : t -> string -> string Backend_types.result
val set : t -> string -> string -> unit Backend_types.result
val exists : t -> string -> bool
val delete : t -> string -> unit Backend_types.result
val list_keys : t -> prefix:string -> string list Backend_types.result
val get_all : t -> prefix:string -> (string * string) list Backend_types.result
val set_if_not_exists : t -> string -> string -> bool Backend_types.result
val clear : t -> unit
val get_or_create : base_path:string -> t
