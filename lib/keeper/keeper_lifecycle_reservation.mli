(** Per-keeper lifecycle transaction ownership.

    Reservations are process-local concurrency barriers keyed by canonical
    workspace base path and keeper name. The opaque token is the only
    authority that may cross a reserved durable-meta or registry mutation
    boundary. This module deliberately contains no MASC/AGENT_CORE runtime policy. *)

type purpose = Keeper_registry_types.lifecycle_transaction_purpose =
  | Paused_work_disposition
  | Keepalive_launch

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

val snapshot_to_string : snapshot -> string

(** Render a release outcome as ["released"], ["release_missing"], or
    ["release_not_owner: "] followed by {!snapshot_to_string} of the owner
    that still holds the reservation. *)
val release_outcome_to_string : release_outcome -> string

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

(** Serialize one ownership check plus authority mutation for this keeper key
    across Eio fibers and non-Eio callers. This is a per-keeper cooperative
    mutex, never a fleet-wide lock. *)
val with_key_lock :
  base_path:string ->
  keeper_name:string ->
  (unit -> 'a) ->
  'a

(** Test/recovery observation only. No mutation authority is exposed. *)
val current : base_path:string -> keeper_name:string -> snapshot option
