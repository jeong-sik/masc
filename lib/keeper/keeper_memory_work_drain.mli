(** Exact owner-lane drain over {!Keeper_memory_work_store}. *)

type report =
  { recovered : int
  ; claimed : int
  ; completed : int
  ; failed : int
  }

type error =
  | Store_error of Keeper_memory_work_store.error
  | Concurrent_claim of string

val error_to_string : error -> string

val drain
  :  base_path:string
  -> keeper_name:string
  -> execute:(Keeper_memory_work_request.t -> (unit, string) result)
  -> (report, error) result
(** Recover the exact in-flight request first, then claim and settle the durable
    FIFO until empty. [Completed] is written only for [Ok ()]; [Error detail]
    is durably settled as [Failed detail]. A store or settlement error stops the
    drain with the current request still recoverable. *)
