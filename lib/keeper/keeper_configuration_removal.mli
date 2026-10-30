(** Configuration-only deletion. No runtime lane or metadata evidence is
    synthesized. The callback executes under intake, lifecycle and manifest
    ownership; it must not acquire the manifest lock or remove that manifest. *)
type state = Prepared | Cleanup_required of string | Artifacts_removed | Removed
type receipt = {
  operation_id : Keeper_shutdown_types.Operation_id.t;
  keeper_name : string;
  actor : string;
  source_sha256 : string;
  source_path : string;
  requested_at : string;
  updated_at : string;
  state : state;
  last_error : string option;
}
type inventory = { receipts : receipt list; errors : string list }
type error = Invalid_request of string | Conflict of string | Storage_error of string
val error_to_string : error -> string
val to_json : receipt -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (receipt, error) result
val submit : config:Workspace.config -> keeper_name:string -> actor:string ->
  cleanup:(string -> (unit, string) result) -> (receipt, error) result
val retry : config:Workspace.config -> keeper_name:string ->
  operation_id:Keeper_shutdown_types.Operation_id.t ->
  cleanup:(string -> (unit, string) result) -> (receipt, error) result
val list : config:Workspace.config -> (inventory, error) result

(** Fold the lifecycle reservation release that closed a removal transaction
    into the transaction's result. [Release_not_owner] and [Release_missing]
    are both lost ownership evidence and turn the result into [Conflict];
    [Released], or no recorded release, keeps the body result. *)
val settle_reservation_release :
  keeper_name:string ->
  Keeper_lifecycle_reservation.release_outcome option ->
  (receipt, error) result ->
  (receipt, error) result
