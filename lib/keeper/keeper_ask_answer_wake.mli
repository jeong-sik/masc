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
  physical_execution_id : string;
  trace_id : string;
  keeper_turn_id : int;
  tool_name : string;
  recorded_at : float;
  outcome : Tool_result.recorded_call_outcome;
}

type tool_outcomes = {
  succeeded : int; deferred : int; failed : int; unsettled : int; malformed : int;
}
type tool_actions = {
  observed_count : int;
  outcomes : tool_outcomes;
  first_recorded_at : float option;
  latest : tool_action option;
}
(** Committed Tool result observations in turns whose input contains this exact
    canonical answer. Includes failed results; proves neither effect success nor
    that the answer caused the action. Physical invocation identity determines
    uniqueness; multiple fresh rechecks may share a logical [execution_id].
    Rows without physical identity do not supply an observation. Malformed or
    duplicate physical identities leave evidence unavailable. No start or
    unfinished native-action claim. Every observed result remains in exactly
    one canonical outcome bucket, including unsettled/malformed outcomes.
    The bucket sum equals [observed_count]; Task progress remains independent. *)

type linked_task =
  | Task_unlinked
  | Task_missing of string
  | Task_unavailable of { task_id : string; detail : string }
  | Task_observed of {
      task_id : string;
      location : Workspace_query.task_status_location;
      status : Masc_domain.task_status;
      observed_at : float;
    }
(** Current lookup of the Task ID on the canonical original question. A Task's
    actual phase is independent of answer delivery, turn boundaries and Tool
    results. This association proves neither answer causation nor whole-work
    completion and grants no claim/resume authority. No current-Task fallback. *)

type followup = {
  answered_at : float;
  stimulus_id : string;
  reactions : (Keeper_reaction_ledger.event_queue_reaction_evidence_outcome, string) result;
  tool_actions : (tool_actions, string) result;
  linked_task : linked_task;
}

type followup_identity = { answered_at : float; stimulus_id : string }
type followup_source =
  | Reaction_evidence of (Keeper_reaction_ledger.event_queue_reaction_evidence_outcome, string) result
  | Tool_results of (tool_actions, string) result
  | Linked_task of linked_task

val observe_followup :
  ?on_started:(followup_identity -> unit) ->
  ?on_source:(followup_identity -> followup_source -> unit) ->
  base_path:string -> keeper_name:string -> ask:Keeper_ask.ask ->
  resolution:Keeper_ask.resolution -> unit -> (followup, string) result
(** Read-only evidence for the exact source of this canonical answered row.
    Reaction, Tool and linked Task reads are independent; one unavailable
    source cannot hide another source's positive observation.
    [on_started] runs once after canonical answer validation. Each [on_source]
    runs when that source settles, before the aggregate join; callback failure
    cancels the read scope rather than repeating a source or hiding disconnect.
    No enqueue, wake hint or answer write. Turn entry/boundary and queue
    settlement are observations; neither a queue transfer nor an ACK proves
    answer consumption, Tool action or completion of the Keeper's work. *)

val followup_to_json : followup -> Yojson.Safe.t
(** Source identity, canonical answer time, reaction clocks, any first
    quarantine reason code, known physical Tool results and linked Task status
    metadata. No question, answer text, responder identity, Task
    title/description, completion notes or reason. *)

val followup_source_to_json : followup_source -> string * Yojson.Safe.t
(** Typed source name and the same private-content-free source projection used
    by the aggregate response. No unavailable placeholder for another source. *)

type failure = { keeper_name : string option; ask_id : string option; error : error }
type report =
  { inspected : int
  ; evidence_window_reads : int
  ; enqueued : int
  ; already_pending : int
  ; already_delivered : int
  ; failures : failure list
  }

val reconcile : base_path:string -> (report, Keeper_ask_store.read_error) result
(** Startup/maintenance recovery. Reads strict ask rows, captures delivery
    evidence on the first demand for each Keeper/canonical-answer UTC-day window,
    then reuses that immutable observation for shared windows in this pass only.
    Windows appearing once in discovered answered rows are not retained in
    the pass's snapshot map. Calendar conversion failure stays with the original
    answer row and cannot abort the demand index before other rows are delivered.
    [evidence_window_reads] counts those capture calls, including failures, not
    physical file reads or successful deliveries. Only unresolved sources reach
    enqueue; the queue owner's fresh evidence and lifecycle checks are retained.
    No timer, history cap, second answer store or outbox. *)

type t
val create :
  base_path:string -> ?on_report:(keeper_name:string -> report -> unit) ->
  ?on_discovery:(base_path:string -> (unit, Keeper_ask_store.read_error) result -> unit) ->
  unit -> t
(** One server-lifetime recovery supervisor. [on_report] observes a settled
    original Keeper batch, not answer consumption, Task progress or effect
    success. Observer failure cannot undo committed deliveries.

    [on_discovery] receives the actual directory/log discovery and owner
    reservation result, with the original base path. [Ok ()] means that pass
    returned, not that owner delivery finished. Partial unreadable logs retain
    their existing diagnostics while healthy owners can recover. The default
    observer logs a whole-discovery failure. No question/answer rows are exposed
    to this observer. Observer failure cannot undo already reserved workers.

    Default supervisor discovery/recovery diagnostics include the original
    workspace base path, including existing failure/interruption records.
    Routine phase formatting remains lazy; existing other logging levels and
    frequency remain. Added quoted-path bytes/formatting are observation cost,
    not delivery authority or measured execution progress. *)

val pulse : sw:Eio.Switch.t -> t -> unit
(** Reserve a switch-owned discovery child, then return without joining its
    directory/log reads. Return is scheduling only; actual discovery success or
    failure reaches [on_discovery]. The child yields before the original
    discovery/reservation pass. One discovery remains active through its
    observer and cleanup; pulses while active coalesce. Once read, canonical
    logs reserve independent owner workers under the original supplied switch.
    Complete discovery still precedes owner reservation within that child.
    Within one Keeper preserve original row order and pass-local evidence-window
    reuse, including failures. Other Keepers do not wait for that owner's intake
    mutex or file lock. The fresh queue-owner evidence and lifecycle fence
    remain authoritative for every delivery.

    Active owners are reserved once until the original worker settles or is
    cancelled. New answers for an active owner wait for a later admitted
    discovery; no
    captured row/result is reused across workers. A changed/failed discovery
    neither cancels an existing worker nor authorizes absence. Unreadable logs
    are reported while healthy owners can recover. Check the supplied switch
    before discovery scheduling and every reservation; cancellation is never a
    store error. A scheduling failure releases its discovery reservation.
    Root-switch cancellation still joins protected physical I/O. No timer,
    retry cap, replacement question, Task inference or fresh authority is added.
    Single-domain Eio caller; the active set is only a scheduling hint. *)
