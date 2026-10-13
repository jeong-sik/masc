(** Recover delivery from the canonical answer log without repeating an answer
    write. Queue delivery is distinct from a Keeper consuming the answer. *)

type delivery = Enqueued | Already_pending | Already_delivered

type error =
  | Ask_store_unavailable of Keeper_ask_store.read_error
  | Ask_missing of string
  | Ask_not_answered of string
  | Invalid_answered_record of string
  | Delivery_evidence_unavailable of Keeper_reaction_ledger.strict_delivery_evidence_error
  | Queue_storage_failed of string

val error_to_string : error -> string

val deliver :
  base_path:string -> keeper_name:string -> ask_id:string -> (delivery, error) result
(** Read the canonical first answer and its original continuation/time. Exact
    positive turn-entry or accepted terminal (including cancellation/transfer)
    source evidence suppresses both enqueue and wake hint; it does not prove
    answer consumption or task completion. Incomplete
    evidence cannot authorize absence. The one-shot queue commit rechecks under
    the owner lock and honors the existing lifecycle intake fence. *)

type failure = { keeper_name : string option; ask_id : string option; error : error }
type report =
  { inspected : int
  ; enqueued : int
  ; already_pending : int
  ; already_delivered : int
  ; failures : failure list
  }

val reconcile : base_path:string -> (report, Keeper_ask_store.read_error) result
(** Startup/maintenance recovery. Reads the strict ask rows and one canonical
    source-evidence snapshot per Keeper, then only unresolved sources reach
    owner-lock enqueue. No timer, history cap, second answer store or outbox. *)
