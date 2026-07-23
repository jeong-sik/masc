(** Type-safe identifiers for the Keeper domain.
    Implements "Parse, Don't Validate" by making IDs abstract or private. *)

module Keeper_name : sig
  type t = private string
  (** Keeper name parsed with the shared portable-name grammar
      [[A-Za-z0-9._-]+] used by {!Keeper_config.validate_name}, excluding the
      reserved path components [.] and [..]. *)
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

module Trace_id : sig
  type t = private string
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

module Task_id : sig
  type t = private string
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

module Uid : sig
  (** Stable unique identifier for a keeper.  Format: "keeper-<uuidv4>". *)
  type t = private string
  val generate : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module For_testing : sig
  val unsafe_trace_id_of_string : string -> Trace_id.t
end

val uid_to_yojson : Uid.t -> [> `String of string ]
val uid_of_yojson : [ `String of string | `Null ] -> (Uid.t, string) result
