(** Pure current-schema wire codec for approval snapshots, append-log rows
    and the derived replay projection. It owns format revisions and validates
    decoded data before the effect owner can apply it. No filesystem, lock,
    mutable queue or dispatch state lives here. *)

open Keeper_approval_queue_rules_types
open Keeper_approval_queue_result

type persisted_delivery =
  { entry : pending_approval
  ; decision : decision
  ; source : decision_source
  ; remember_rule : bool
  ; rule_expires_at : float option
  ; rule_intent : Keeper_rule_revision.intent option
  ; created_by : string option
  ; grant_consumed : bool
  ; replay_outcome : resolution_replay_outcome option
  }

type log_row =
  | Pending_upsert of pending_approval
  | Pending_remove of string
  | Delivery_upsert of persisted_delivery
  | Delivery_remove of string

type decoded_log_row =
  { row : log_row
  ; row_generation : int
  ; row_next_sequence : int
  }

val pending_entry_to_yojson :
  ?include_request_context:bool -> pending_approval -> Yojson.Safe.t
val persisted_delivery_to_yojson : persisted_delivery -> Yojson.Safe.t
val resolution_replay_outcome_to_yojson : resolution_replay_outcome -> Yojson.Safe.t
val map_values_for_base :
  base_path:string -> 'a Set_util.StringMap.t -> ('a -> pending_approval) -> 'a list
val first_shared_id :
  'a Set_util.StringMap.t -> 'b Set_util.StringMap.t -> string option
(** The first shared key in map order, or [None] when the states are disjoint. *)

val snapshot_to_yojson :
  base_path:string -> next_sequence:int -> generation:int ->
  pending_map:pending_approval Set_util.StringMap.t ->
  delivery_map:persisted_delivery Set_util.StringMap.t -> Yojson.Safe.t
val replay_results_to_yojson :
  base_path:string -> delivery_map:persisted_delivery Set_util.StringMap.t -> Yojson.Safe.t
val log_row_to_yojson : generation:int -> next_sequence:int -> log_row -> Yojson.Safe.t

val pending_entry_of_yojson : base_path:string -> Yojson.Safe.t -> (pending_approval, string) result
val snapshot_of_yojson :
  base_path:string -> Yojson.Safe.t ->
  (pending_approval Set_util.StringMap.t * persisted_delivery Set_util.StringMap.t
   * int * int * string list, string) result
(** Maps, next sequence, generation, and rejected pending-entry evidence.
    Fatal invariants reject the whole snapshot; recoverable drops retain errors. *)
val validate_pending_snapshot : base_path:string -> Yojson.Safe.t -> (unit, string) result
(** Run the snapshot decode {!Keeper_approval_queue.install_persistence} runs on
    [gate/pending.json], without installing anything. [Error] carries the
    loader's own message: an unsupported [version], a malformed snapshot, or
    the first entry the loader would drop. Released v11 snapshots retain their
    pending entries and one-shot deliveries; new snapshots use v12.
    The append log is not read. *)
val replay_results_of_yojson :
  Yojson.Safe.t -> (resolution_replay_outcome Set_util.StringMap.t, string) result
val log_row_of_yojson : base_path:string -> Yojson.Safe.t -> (decoded_log_row, string) result
val apply_log_row :
  pending_approval Set_util.StringMap.t * persisted_delivery Set_util.StringMap.t ->
  log_row -> pending_approval Set_util.StringMap.t * persisted_delivery Set_util.StringMap.t

val exact_attempt_quarantine_summary_status : exact_attempt_quarantine_cause -> summary_status
val validate_entry_exact_attempt :
  id:string -> input_hash:string -> sequence:int -> summary_status:summary_status ->
  summary_attempt_disposition:summary_attempt_disposition -> exact_attempt_state ->
  (unit, string) result
