(** The durable decision of a resolution in [Keeper_approval_queue].

    [resolve_error] says why a resolution failed: the approval is unknown or
    already resolved, its delivery failed, or the queue could not persist it;
    [resolve_error_to_string] renders it. [claim_resolution] takes the claim
    on an approval id and returns [false] when another caller holds it, and
    [release_resolution_claim] gives it back.
    [resolve_store_readiness_error] returns [Ok ()] for a ready store and
    [Persistence_failed] for an unavailable or uninstalled one.
    [resolution_target_unlocked] finds the approval of a workspace, either as
    a pending entry or as a journaled delivery, and returns [Not_found] for an
    id of another workspace.
    [journal_resolution] turns a pending entry into a delivery at the next
    sequence and persists both maps under the store lock. A rejection never
    asks to remember a rule. A delivery that is already journaled comes back
    as [Previously_journaled].
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_rules
open Keeper_approval_queue_result
open Keeper_approval_queue_codec

type resolve_error =
  | Not_found of string
  | Already_resolved of string
  | Delivery_failed of
      { approval_id : string
      ; reason : string
      }
  | Persistence_failed of
      { approval_id : string
      ; storage_error : storage_error
      }

val resolve_error_to_string : resolve_error -> string

val claim_resolution : string -> bool

val release_resolution_claim : string -> unit

val resolve_store_readiness_error :
  base_path:string -> approval_id:string -> (unit, resolve_error) result

type resolution_target =
  | Pending_resolution of pending_approval
  | Journaled_resolution of persisted_delivery

val resolution_target_unlocked :
  base_path:string -> id:string -> (resolution_target, resolve_error) result

type prepared_resolution =
  | Newly_journaled of persisted_delivery
  | Previously_journaled of persisted_delivery

val journal_resolution :
  base_path:string ->
  id:string ->
  decision:Keeper_approval_queue_rules_types.decision ->
  source:Keeper_approval_queue_rules_types.decision_source ->
  remember_rule:bool ->
  rule_expires_at:float option ->
  created_by:string option -> (prepared_resolution, resolve_error) result
