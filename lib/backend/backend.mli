(** Backend: OCaml 5.x Eio-native storage backend *)

(** {1 Compression} *)

module Compression = Backend_compression

(** {1 Types (from Backend_types)} *)

include module type of struct include Backend_types end

(** {1 FileSystem Backend (Eio)} *)

module FileSystem : sig
  type t

  (** Install observers for write-mutex contention.

      Called once at startup from the main library to wire mutex
      acquire/hold timings into Prometheus histograms.  The default
      observers are no-ops, so [masc_backend] does not depend on
      [Prometheus] at link time.

      [acquire] receives the seconds a fiber waited before entering
      the lock; [held] receives the seconds spent in the write critical
      section. Both run *outside* the mutex critical section to avoid
      nested locking.

      [op] is one of [set | delete | set_if_not_exists]. Read paths
      are not measured by these histograms. *)
  val set_mutex_observers :
    acquire:(op:string -> seconds:float -> unit) ->
    held:(op:string -> seconds:float -> unit) ->
    unit

  val create :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
    config ->
    t
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

  val lock_info_to_json : lock_info -> string
  val lock_info_of_json : string -> lock_info option
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
  val get_or_create : base_path:string -> t
end

(** {1 Unified Backend} *)

type backend =
  | FS of FileSystem.t
  | Mem of Memory.t

val get : backend -> string -> string result
val set : backend -> string -> string -> unit result
val exists : backend -> string -> bool
val delete : backend -> string -> unit result
val list_keys : backend -> string list result
val set_if_not_exists : backend -> string -> string -> bool result
val acquire_lock : backend -> key:string -> owner:string -> ttl_seconds:int -> bool result
val release_lock : backend -> key:string -> owner:string -> bool result
val extend_lock : backend -> key:string -> owner:string -> ttl_seconds:int -> bool result
