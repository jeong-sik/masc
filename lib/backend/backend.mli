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
      acquire/hold timings into Otel_metric_store histograms.  The default
      observers are no-ops, so [masc_backend] does not depend on
      [Otel_metric_store] at link time.

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
  (** [acquire_lock], [release_lock], [extend_lock] and [commit_under_lease]
      each run inside one fence per [key]: a process-wide mutex keyed by the
      fence file's path, then an fcntl lock on that file. A lease record
      therefore cannot change hands between an owner check and the write
      that depended on it, across fibers, backend values and processes on
      the host. *)

  type lease_lost = { holder : string option }
  (** The lease was not [owner]'s when checked inside the fence: [holder]
      is the owner then recorded, [None] when no lease record existed or it
      could not be decoded. *)

  val commit_under_lease :
    t -> key:string -> owner:string -> ttl_seconds:int ->
    (unit -> 'a) -> ('a, lease_lost) Stdlib.result result
  (** Inside [key]'s fence: when [owner] holds the lease, renew it to
      [ttl_seconds] from now and run the publication, returning [Ok (Ok v)].
      Otherwise return [Ok (Error lost)] without running it. [Error] is a
      backend or fence failure; the publication did not run. *)

  val lease_fence_path : t -> key:string -> string result
  (** Native path of [key]'s fence file, for tests that probe the fence from
      another process. *)

  val after_lease_owner_read_hook : (key:string -> unit) Stdlib.Atomic.t
  (** Test seam: called inside [commit_under_lease]'s fence after the owner
      is read and before renewal and publication. Production never sets it. *)

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
