type failure =
  | No_progress of { bytes_written : int }
  | Unix_error of
      { bytes_written : int
      ; error : Unix.error
      ; function_name : string
      ; argument : string
      }
  | Operation_failed of
      { bytes_written : int
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }

(** Exact EINTR-aware write-all state machine. [write] receives the current
    offset and remaining length. *)
val run
  :  length:int
  -> write:(offset:int -> length:int -> int)
  -> (unit, failure) result
