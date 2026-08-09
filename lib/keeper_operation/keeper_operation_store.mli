type t

type operation_state =
  | Queued
  | Running
  | Settled
  | Cancelled
  | Interrupted

type operation =
  { queue_seq : int64
  ; operation_id : Keeper_operation_id.Operation_id.t
  ; kind : Keeper_operation_request.kind
  ; source_ref : Keeper_operation_request.Canonical_json.t
  ; submitter_ref : Keeper_operation_request.Canonical_json.t
  ; state : operation_state
  ; request_digest : string
  ; input_ref : Keeper_operation_blob_store.Input_ref.t
  ; base_state_ref : Keeper_operation_blob_store.State_ref.t option
  ; outcome_ref : Keeper_operation_blob_store.Outcome_ref.t option
  ; next_state_ref : Keeper_operation_blob_store.State_ref.t option
  ; created_at : float
  ; started_at : float option
  ; finished_at : float option
  }

type error =
  | Invalid_input of string
  | Identity_conflict of Keeper_operation_id.Operation_id.t
  | State_conflict of
      { operation_id : Keeper_operation_id.Operation_id.t
      ; state : operation_state
      }
  | Store_error of string
  | Integrity_error of string

val error_to_string : error -> string

val open_or_create
  :  base_path:string
  -> keeper_runtime_dir:string
  -> (t, error) result

val close : t -> (unit, error) result

type admission =
  | Accepted of operation
  | Replayed of operation

val admit
  :  t
  -> now:float
  -> request:Keeper_operation_request.t
  -> input_ref:Keeper_operation_blob_store.Input_ref.t
  -> (admission, error) result

val find
  :  t
  -> Keeper_operation_id.Operation_id.t
  -> (operation option, error) result

val start_next
  :  t
  -> now:float
  -> base_state_ref:Keeper_operation_blob_store.State_ref.t option
  -> (operation option, error) result

val cancel_queued
  :  t
  -> now:float
  -> Keeper_operation_id.Operation_id.t
  -> (operation, error) result

val interrupt_running
  :  t
  -> now:float
  -> operation_id:Keeper_operation_id.Operation_id.t
  -> evidence_ref:Keeper_operation_blob_store.Outcome_ref.t
  -> (operation, error) result

val settle
  :  t
  -> now:float
  -> operation_id:Keeper_operation_id.Operation_id.t
  -> outcome_ref:Keeper_operation_blob_store.Outcome_ref.t
  -> next_state_ref:Keeper_operation_blob_store.State_ref.t option
  -> (operation, error) result

val set_paused : t -> bool -> (unit, error) result
val paused : t -> (bool, error) result
val count_operations : t -> (int64, error) result
