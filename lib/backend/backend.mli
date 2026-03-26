(** Backend: OCaml 5.x Eio-native storage backend *)

(** {1 Compression} *)

module Compression = Backend_compression

(** {1 Types (from Backend_types)} *)

include module type of struct include Backend_types end

(** {1 FileSystem Backend (Eio)} *)

module FileSystem : sig
  type t

  val create : fs:Eio.Fs.dir_ty Eio.Path.t -> config -> t
  val validate_key : string -> (string, error) Stdlib.result

  (** Core operations *)
  val get : t -> string -> string result
  val set : t -> string -> string -> unit result
  val exists : t -> string -> bool
  val delete : t -> string -> unit result
  val list_keys : t -> prefix:string -> string list result
  val set_if_not_exists : t -> string -> string -> bool result

  (** Lock operations *)
  type lock_info = {
    owner: string;
    acquired_at: float;
    expires_at: float;
  }

  val acquire_lock : t -> key:string -> owner:string -> ttl_seconds:int -> bool result
  val release_lock : t -> key:string -> owner:string -> bool result
  val extend_lock : t -> key:string -> owner:string -> ttl_seconds:int -> bool result

  (** Atomic operations *)
  val atomic_increment : t -> string -> int result
  val atomic_get : t -> string -> int result
  val atomic_update : t -> string -> f:(string option -> string) -> string result

  (** Health check *)
  val health_check : t -> health_result result
end

(** {1 Memory Backend (for testing)} *)

module Memory : sig
  type t

  val create : unit -> t
  val get : t -> string -> string result
  val set : t -> string -> string -> unit result
  val exists : t -> string -> bool
  val delete : t -> string -> unit result
  val list_keys : t -> prefix:string -> string list result
  val get_all : t -> prefix:string -> (string * string) list result
  val set_if_not_exists : t -> string -> string -> bool result
  val clear : t -> unit
end

(** {1 PostgreSQL Backend (Eio)} *)

module Postgres : sig
  type t = Backend_pg.t

  val create :
    sw:Eio.Switch.t ->
    env:Caqti_eio.stdenv ->
    url:string ->
    config ->
    (t, error) Stdlib.result

  val create_readonly :
    sw:Eio.Switch.t ->
    env:Caqti_eio.stdenv ->
    url:string ->
    config ->
    (t, error) Stdlib.result

  val close : t -> unit
  val get_pool : t -> (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t
  val get : t -> string -> string result
  val set : t -> string -> string -> unit result
  val exists : t -> string -> bool
  val delete : t -> string -> unit result
  val list_keys : t -> prefix:string -> string list result
  val get_all : t -> prefix:string -> (string * string) list result
  val get_all_matching_recent :
    t ->
    prefix:string ->
    suffix:string ->
    updated_since:float ->
    limit:int ->
    (string * string) list result
  val set_if_not_exists : t -> string -> string -> bool result
  val compare_and_swap :
    t -> key:string -> expected:string -> value:string -> bool result
  val acquire_lock : t -> key:string -> owner:string -> ttl_seconds:int -> bool result
  val release_lock : t -> key:string -> owner:string -> bool result
  val extend_lock : t -> key:string -> owner:string -> ttl_seconds:int -> bool result
  val publish : t -> channel:string -> message:string -> int result
  val subscribe : t -> channel:string -> callback:(string -> unit) -> unit result
  val health_check : t -> health_result result
  val cleanup_pubsub_by_age : t -> days:int -> int result
  val cleanup_pubsub_by_limit : t -> max_messages:int -> int result
  val cleanup_pubsub : t -> days:int -> max_messages:int -> int result
end

(** {1 Unified Backend} *)

type backend =
  | FS of FileSystem.t
  | Mem of Memory.t
  | PG of Postgres.t

val get : backend -> string -> string result
val set : backend -> string -> string -> unit result
val exists : backend -> string -> bool
val delete : backend -> string -> unit result
val list_keys : backend -> string list result
val set_if_not_exists : backend -> string -> string -> bool result
val acquire_lock : backend -> key:string -> owner:string -> ttl_seconds:int -> bool result
val release_lock : backend -> key:string -> owner:string -> bool result
val extend_lock : backend -> key:string -> owner:string -> ttl_seconds:int -> bool result
