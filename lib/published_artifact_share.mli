(** Pure, per-artifact external-sharing state.

    A request carries the version it observed and a UUIDv7 operation identity.
    An accepted change advances the version even when the boolean value is
    unchanged. Each state carries its latest receipt. The store must archive
    that receipt before replacing it and consult archived identities as well. *)

type snapshot = { version : int; shared : bool }
type request = { operation_id : string; expected_version : int; requested : bool }
type outcome = Applied of snapshot | Conflict of snapshot
type receipt = { request : request; outcome : outcome }
type t

type error = Invalid of string | Operation_reused
type transition = Recorded of t * receipt | Replay of receipt

val initial : id:string -> shared:bool -> (t, error) result
val id : t -> string
val snapshot : t -> snapshot
val latest : t -> receipt option
val valid_operation_id : string -> bool
val valid_version : int -> bool
val receipt_snapshot : receipt -> snapshot
val apply : t -> request -> (transition, error) result
(** This checks the latest identity only; the store owns earlier receipts. *)

val snapshot_to_json : snapshot -> Yojson.Safe.t
val snapshot_of_json : Yojson.Safe.t -> (snapshot, error) result
val receipt_to_json : receipt -> Yojson.Safe.t
val receipt_of_json : Yojson.Safe.t -> (receipt, error) result
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
(** The latest receipt is validated against the snapshot. The original
    two-field share file reads as version zero. *)
