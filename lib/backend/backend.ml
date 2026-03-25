(** Backend Module - Storage abstraction for MASC (facade)

    FileSystemBackend was removed in favour of Backend_eio.FileSystem.
    Dispatch is handled by room_utils_paths_backend.ml. *)

include Backend_core

(* FileSystemBackend removed — use Backend_eio.FileSystem instead.
   Migration: room_utils_paths_backend dispatch routes to Backend_eio.FileSystem
   via eio_to_backend_error conversion. *)

(* ============================================ *)
(* PostgreSQL Backend (Eio-native, non-blocking) *)
(* ============================================ *)

(** PostgresNative - Eio-based PostgreSQL backend using caqti-eio.
    Implementation delegated to Backend_pg for separation of concerns. *)
module PostgresNative : sig
  include BACKEND
  val create_eio : sw:Eio.Switch.t -> env:Caqti_eio.stdenv -> config -> (t, error) result
  val create_eio_readonly : sw:Eio.Switch.t -> env:Caqti_eio.stdenv -> config -> (t, error) result
  val get_pool : t -> (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t
  val get_all_matching_recent :
    t ->
    prefix:string ->
    suffix:string ->
    updated_since:float ->
    limit:int ->
    ((string * string) list, error) result
  val cleanup_pubsub_by_age : t -> days:int -> (int, error) result
  val cleanup_pubsub_by_limit : t -> max_messages:int -> (int, error) result
  val cleanup_pubsub : t -> days:int -> max_messages:int -> (int, error) result
end = struct
  include Backend_pg
end
