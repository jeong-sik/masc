(** Pure operation state reducer. No persistence, clocks, fibers, or callbacks. *)

module Operation = Keeper_chat_operation

type command =
  | Start of { started_at : float }
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

type persistence_intent =
  | Persist_running
  | Persist_queued_edit
  | Persist_queued_move
  | Persist_terminal

type post_commit_effect = Publish_operation

type transition =
  { operation : Operation.t
  ; persistence : persistence_intent
  ; post_commit : post_commit_effect
  }

type error =
  | Not_queued
  | Not_running
  | Invalid_input of string

val apply : Operation.t -> command -> (transition, error) result
val error_to_string : error -> string
