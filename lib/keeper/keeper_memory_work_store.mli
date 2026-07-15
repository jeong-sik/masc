(** Keeper-local durable FIFO admission for post-turn Memory work. *)

type error =
  | Invalid_base_path of string
  | Invalid_keeper_name of string
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Decode_failed of
      { path : string
      ; detail : string
      }
  | Owner_mismatch of
      { expected : string
      ; actual : string
      }
  | No_matching_claim of
      { expected : string option
      ; actual : string
      }
  | Invalid_terminal_outcome of string
  | Settlement_conflict of string
  | Write_failed of
      { path : string
      ; cause : Keeper_fs.durable_write_error
      }

type enqueue_result =
  | Enqueued
  | Already_present

type claim_result =
  | Queue_empty
  | Claim_busy of string
  | Claimed of Keeper_memory_work_request.t

type terminal_outcome =
  | Completed
  | Failed of string

type settle_result =
  | Settled
  | Already_settled

type terminal =
  { request : Keeper_memory_work_request.t
  ; outcome : terminal_outcome
  }

val error_to_string : error -> string
val queue_path : base_path:string -> keeper_name:string -> (string, error) result

val enqueue
  :  base_path:string
  -> Keeper_memory_work_request.t
  -> (enqueue_result, error) result
(** Append exactly once by content-derived request identity. There is no queue
    limit and no admission policy. *)

val pending
  :  base_path:string
  -> keeper_name:string
  -> (Keeper_memory_work_request.t list, error) result
(** Return the persisted requests in exact admission order. *)

val claim_next : base_path:string -> keeper_name:string -> (claim_result, error) result
val recover_in_flight
  :  base_path:string
  -> keeper_name:string
  -> (Keeper_memory_work_request.t option, error) result

val settle
  :  base_path:string
  -> keeper_name:string
  -> request_id:string
  -> terminal_outcome
  -> (settle_result, error) result
(** Settle only the exact in-flight request. Replaying the same settlement is
    idempotent; a conflicting outcome is rejected. *)

val terminal
  :  base_path:string
  -> keeper_name:string
  -> (terminal list, error) result
