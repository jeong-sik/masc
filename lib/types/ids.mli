(** MASC MCP Types — newtype IDs that prevent accidental string mixups.

    Each module wraps [string] in an abstract type so the type system
    rejects passing an [Agent_id.t] where a [Task_id.t] is expected
    (and vice versa). All modules expose [of_string]/[to_string] and
    [Yojson] round-trips so JSON boundaries can lift/lower without
    leaking the underlying representation. *)

(** Agent identifier — random UUIDv4. *)
module Agent_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(** Task identifier — timestamp-prefixed sequence. *)
module Task_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(** Conversation thread identifier — timestamp-prefixed sequence. *)
module Thread_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(** Turn identifier — individual turn within a thread. *)
module Turn_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : thread_id:string -> seq:int -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(** Keeper identifier — structural record with uid, name, path.

    RFC-0232 P3: [t] changed from string-alias to a concrete record
    so that message-scope and board-signal modules can compare keeper
    identity by structural fields instead of reverse-parsing through
    Keeper_identity.canonical_keeper_name string gymnastics.

    {[type t = { uid : string; name : string; path : string }]}

    [uid] is the deterministic UUIDv5 of @"masc-keeper:<name>:<path>"@.
    [equal] compares by [uid] alone.
    [to_string] returns [uid]; [to_yojson] serialises as [`String uid]
    for backward compatibility with persisted state. *)
module Keeper_id : sig
  type t
  val make : uid:string -> name:string -> path:string -> t
  val uid : t -> string
  val name : t -> string
  val path : t -> string
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : name:string -> path:string -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
  val uid_of_yojson : Yojson.Safe.t -> (t, string) result
  module Trace_id : sig
    type t
    val of_string : string -> (t, string) result
    val to_string : t -> string
    val equal : t -> t -> bool
  end
  module Task_id : sig
    type t
    val of_string : string -> (t, string) result
    val to_string : t -> string
    val equal : t -> t -> bool
  end
end

(** Credential identifier — random UUIDv4. *)
module Credential_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end
