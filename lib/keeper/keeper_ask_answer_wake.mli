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
    answer consumption or task completion. Every delivery-evidence read is
    bounded to rows at/after the canonical answer time: a delivery cannot
    predate the answer, so older corruption (e.g. a torn pre-answer write)
    cannot make the evidence incomplete or block a fresh answer. Incomplete
    evidence inside that window still cannot authorize absence. The one-shot
    queue commit rechecks under the owner lock, with the same bound, and
    honors the existing lifecycle intake fence. *)

type tool_action = {
  execution_id : string;
  trace_id : string;
  keeper_turn_id : int;
  tool_name : string;
  recorded_at : float;
}

type tool_actions = {
  observed_count : int;
  first_recorded_at : float option;
  latest : tool_action option;
}
(** Committed Tool result observations in turns whose input contains this exact
    canonical answer. Includes failed results; proves neither effect success nor
    that the answer caused the action. No start/unfinished/native action claim. *)

type followup = {
  answered_at : float;
  stimulus_id : string;
  reactions : Keeper_reaction_ledger.event_queue_reaction_evidence_outcome;
  tool_actions : (tool_actions, string) result;
}

val observe_followup :
  base_path:string -> keeper_name:string -> ask:Keeper_ask.ask ->
  resolution:Keeper_ask.resolution -> (followup, string) result
(** Read-only evidence for the exact source of this canonical answered row.
    No enqueue, wake hint or answer write. Turn entry/boundary and queue
    settlement are observations; neither a queue transfer nor an ACK proves
    answer consumption, Tool action or completion of the Keeper's work. *)

val followup_to_json : followup -> Yojson.Safe.t
(** Source identity, canonical answer time, reaction clocks, any first
    quarantine reason code and known physical Tool result metadata; no question,
    answer text or responder identity. *)

type failure = { keeper_name : string option; ask_id : string option; error : error }
type report =
  { inspected : int
  ; enqueued : int
  ; already_pending : int
  ; already_delivered : int
  ; failures : failure list
  }

val reconcile : base_path:string -> (report, Keeper_ask_store.read_error) result
(** Startup/maintenance recovery. Reads the strict ask rows and, per answered
    ask, one delivery-evidence read bounded to rows at/after that answer's
    canonical time, then only unresolved sources reach owner-lock enqueue.
    No timer, history cap, second answer store or outbox. *)
