(** Per-keeper lifecycle transaction ownership.

    Reservations are process-local concurrency barriers keyed by canonical
    workspace base path and keeper name. The opaque token is the only
    authority that may cross a reserved durable-meta or registry mutation
    boundary. Durable recovery records are owned by
    {!Keeper_dead_revival_transaction}; this module deliberately contains no
    MASC/OAS runtime policy. *)

type purpose = Keeper_registry_types.lifecycle_transaction_purpose = Dead_revival

type token

type snapshot = Keeper_registry_types.lifecycle_reservation_snapshot =
  { owner_id : string
  ; expected_generation : int
  ; purpose : purpose
  }

type acquire_error = Already_reserved of snapshot

type release_outcome =
  | Released
  | Release_missing
  | Release_not_owner of snapshot

val purpose_to_string : purpose -> string
val snapshot_to_string : snapshot -> string

val acquire :
  base_path:string ->
  keeper_name:string ->
  expected_generation:int ->
  purpose:purpose ->
  (token, acquire_error) result

val authorize :
  ?token:token ->
  base_path:string ->
  keeper_name:string ->
  unit ->
  (unit, snapshot) result

val owner_id : token -> string
val expected_generation : token -> int
val release : token -> release_outcome

(** Serialize one ownership check plus authority mutation for this keeper key.
    This is a per-keeper mutex, never a fleet-wide lock. Eio fibers wait
    cooperatively while non-Eio callers share the same exclusion authority. *)
val with_key_lock :
  base_path:string ->
  keeper_name:string ->
  (unit -> 'a) ->
  'a

(** Test/recovery observation only. No mutation authority is exposed. *)
val current : base_path:string -> keeper_name:string -> snapshot option
