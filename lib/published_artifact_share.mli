(** Pure, per-artifact external-sharing history.

    A request carries the version it observed and a UUIDv7 operation identity.
    An accepted change advances the version even when the boolean value is
    unchanged. A refused stale request is also recorded: replaying its identity
    cannot apply it later after the state has changed. *)

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
val receipts : t -> receipt list
val find : t -> operation_id:string -> receipt option
val apply : t -> request -> (transition, error) result
(** [Replay] is returned only for the same operation and exact request. A
    different request using an already recorded identity is [Operation_reused]. *)

val snapshot_to_json : snapshot -> Yojson.Safe.t
val receipt_to_json : receipt -> Yojson.Safe.t
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
(** Decoding validates the complete ordered history, including unique request
    identities and every observed snapshot. The original two-field share file
    is read as version zero so existing shared documents retain their state. *)
