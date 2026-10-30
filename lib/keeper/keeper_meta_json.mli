(** Keeper meta JSON codec facade. *)

include module type of Keeper_meta_json_current_schema

include module type of Keeper_meta_json_parse

(** Serialize a [keeper_meta] record to JSON. *)
val meta_to_json : Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

module Snapshot_digest : sig
  type t

  val of_meta : Keeper_meta_contract.keeper_meta -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end
(** SHA-256 of the exact compact current-schema JSON encoding. This is a
    conditional-mutation witness, not an independently mutable version. *)

val current_write_json :
  Keeper_meta_contract.keeper_meta -> (Yojson.Safe.t, string) result
(** Serialize and immediately prove that the current exact reader accepts the
    emitted object. Persistence must use this guarded surface so non-finite
    values and reader/writer invariant drift cannot be written. *)

(** Canonical key list shared by the exact current reader and writer. *)
val canonical_keeper_meta_key_names : string list
