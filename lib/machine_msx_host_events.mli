val relay : author:string -> string -> unit
(** Best-effort Board publication. Cancellation propagates; publication failures
    do not reinterpret an already applied machine transition. *)
