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
  | Write_failed of
      { path : string
      ; cause : Keeper_fs.durable_write_error
      }

type enqueue_result =
  | Enqueued
  | Already_present

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
