(** Immutable approval state calculations. The queue owns locks, persistence,
    publication and dispatch; this module only derives values from its inputs. *)
open Keeper_approval_queue_rules_types
open Keeper_approval_queue_result
open Keeper_approval_queue_codec

val exact_attempt_identity_matches : exact_attempt_binding -> exact_attempt_binding -> bool
val summary_attempt_allows_exact_bind : summary_attempt_disposition -> bool
val validate_exact_attempt_candidate :
  id:string -> input_hash:string -> sequence:int -> slot_id:string -> call_id:string ->
  plan_fingerprint:string -> request_body_sha256:string ->
  (exact_attempt_binding, exact_attempt_error) result

val entries_for_base :
  base_path:string -> 'a Set_util.StringMap.t -> ('a -> pending_approval) ->
  'a Set_util.StringMap.t
val delta_rows :
  before_pending:pending_approval Set_util.StringMap.t ->
  before_deliveries:persisted_delivery Set_util.StringMap.t ->
  after_pending:pending_approval Set_util.StringMap.t ->
  after_deliveries:persisted_delivery Set_util.StringMap.t -> log_row list
(** Uses physical equality for unchanged immutable entries; pending rows precede
    delivery rows, each in map order. *)

val classify_restarted_pending :
  pending_approval Set_util.StringMap.t -> bool * pending_approval Set_util.StringMap.t
val classify_restarted_deliveries :
  persisted_delivery Set_util.StringMap.t -> bool * persisted_delivery Set_util.StringMap.t
(** The boolean reports whether restart classification changed any entry. *)

val find_pending_id_in_map :
  pending_approval Set_util.StringMap.t ->
  base_path:string -> keeper_name:string -> tool_name:string -> input_hash:string ->
  task_id:string option -> goal_id:string option ->
  continuation_channel:Keeper_continuation_channel.t -> string option
val find_unconsumed_grant_id_in_deliveries :
  persisted_delivery Set_util.StringMap.t ->
  base_path:string -> keeper_name:string -> tool_name:string -> input_hash:string ->
  task_id:string option -> goal_id:string option ->
  continuation_channel:Keeper_continuation_channel.t -> string option
(** First matching key in map order, or [None] when no matching request exists. *)

val compare_pending_order : pending_approval -> pending_approval -> int
