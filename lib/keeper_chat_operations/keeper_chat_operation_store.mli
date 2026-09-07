(** Sole-writer SQLite storage for Keeper chat operations. *)

module Operation = Keeper_chat_operation
module Semantic = Keeper_semantic_execution

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
val path_for_keeper : keepers_runtime_dir:string -> keeper_name:string -> string

type outstanding_snapshot =
  | Missing_store
  | Stored_operations of { chat_operations : Operation.t list; semantic_executions : Semantic.t list }

val inspect_outstanding : path:string -> (outstanding_snapshot, error) result
(** Read-only schema/integrity checked snapshot of queued and running operations.
    Exactly validated v1 chat-only stores are readable without migration; v2
    inspection also includes every nonterminal semantic execution.
    Never creates, initializes, or recovers a store. Missing files remain distinct
    from a validated empty queue. Callers authorizing lifecycle changes must
    exclude the sole writer and its creation for the whole enclosing commit. *)

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

(** Semantic execution records share the Owner's SQLite journal. Suspended or
    recovering records reserve only their own sources, never the running slot. *)
type semantic_error =
  | Semantic_store_error of error
  | Unknown_execution of Keeper_execution_scope_id.t
  | Admission_conflict of Keeper_execution_scope_id.t
  | Execution_changed of Semantic.t
  | Sources_owned of Keeper_execution_scope_id.t list
  | Execution_slot_busy of Keeper_execution_scope_id.t
  | Invalid_execution of Semantic.error

type semantic_admission = Semantic_created of Semantic.t | Semantic_existing of Semantic.t
val semantic_error_to_string : semantic_error -> string
val semantic_get : t -> Keeper_execution_scope_id.t -> (Semantic.t option, semantic_error) result
val semantic_outstanding : t -> (Semantic.t list, semantic_error) result
val semantic_prepare :
  t -> id:Keeper_execution_scope_id.t -> sources:Semantic.source_member list -> now:float ->
  (semantic_admission, semantic_error) result
(** The identity is Direct_operation or Autonomous_admission without aliases.
    The canonical typed JSON key includes both origin and scalar. Commits the
    identity, initialized empty repetition frame, source membership and
    Preparing phase together. Reusing identity never clears recorded evidence.
    An uncertain commit is an error; reload by that identity before deciding a
    retry. Different outstanding operations may coexist with disjoint sources. *)
val semantic_apply :
  t -> expected:Semantic.t -> now:float -> Semantic.action ->
  (Semantic.t, semantic_error) result
(** Exact-record CAS; terminal records are immutable. Only Running occupies the
    single semantic execution slot. Startup moves interrupted Running records
    to Recovering without clearing frames, allowing unrelated work to proceed. *)
