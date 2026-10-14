(** Pure operation state reducer. No persistence, clocks, fibers, or callbacks. *)

module Operation = Keeper_chat_operation

type command =
  | Start of { started_at : float }
  | Requeue_continuation
  | Edit_queued of
      { input : Yojson.Safe.t
      ; execution_digest : string
      }
  | Move_queued of { sequence : int64 }
  | Cancel_queued of { completed_at : float }
  | Succeed_running of
      { completed_at : float
      ; outcome_ref : string
      }
  | Fail_running of
      { completed_at : float
      ; failure : Operation.failure
      }

type error =
  | Not_queued
  | Not_running
  | Invalid_input of string

val apply : Operation.t -> command -> (Operation.t, error) result
(** The operation after [command]. The caller picks the statement that
    stores it, since each caller issues one command. *)
val error_to_string : error -> string
