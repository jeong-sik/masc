(** Sole-writer SQLite storage for Keeper chat operations. *)

module Operation = Keeper_chat_operation

type t

type error =
  | Invalid_input of string
  | Unknown_operation of Operation.Operation_id.t
  | Not_queued of Operation.Operation_id.t
  | Not_running of Operation.Operation_id.t
  | Idempotency_conflict of Operation.Operation_id.t
  | Store_unavailable of string
  | Integrity_error of string

type admission =
  | Accepted of Operation.t
  | Existing of Operation.t

type inventory =
  { queued_count : int
  ; running_operation_id : Operation.Operation_id.t option
  ; terminal_count : int
  ; interrupted_count : int
  }

val database_file : string
val open_or_create : path:string -> (t, error) result
val close : t -> (unit, error) result
val path : t -> string

val submit
  :  t
  -> now:float
  -> operation_id:Operation.Operation_id.t
  -> source:Yojson.Safe.t
  -> input:Yojson.Safe.t
  -> (admission, error) result

val get : t -> Operation.Operation_id.t -> (Operation.t option, error) result
val inventory : t -> (inventory, error) result
val claim_next : t -> now:float -> (Operation.t option, error) result

val list_queued
  :  t
  -> after_sequence:int64 option
  -> limit:int
  -> (Operation.t list, error) result

val edit_queued
  :  t
  -> operation_id:Operation.Operation_id.t
  -> input:Yojson.Safe.t
  -> (Operation.t, error) result

val move_queued_to_end
  :  t
  -> operation_id:Operation.Operation_id.t
  -> (Operation.t, error) result

val cancel_queued
  :  t
  -> now:float
  -> operation_id:Operation.Operation_id.t
  -> (Operation.t, error) result

val succeed_running
  :  t
  -> now:float
  -> operation_id:Operation.Operation_id.t
  -> outcome_ref:string
  -> (Operation.t, error) result

val fail_running
  :  t
  -> now:float
  -> operation_id:Operation.Operation_id.t
  -> kind:Operation.failure_kind
  -> detail:string
  -> outcome_ref:string option
  -> (Operation.t, error) result

val settle_running_after_restart : t -> now:float -> (int, error) result
val error_to_string : error -> string

module For_testing : sig
  type commit_fault =
    | Fail_before_commit
    | Fail_after_commit

  val fail_next_commit : commit_fault -> unit
  val clear_commit_fault : unit -> unit
  val database_file : string
  val database_application_id : int64
  val table_column_counts : (string * int) list
end
