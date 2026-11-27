(** Record an operator's answer together with the Keeper's queue pointer to
    it, and observe what followed. Queue delivery is distinct from a Keeper
    consuming the answer. *)

type answer_failure =
  | Answer_refused of Keeper_ask_store.answer_failure
      (** The ask store refused or could not confirm the answer, as
          {!Keeper_ask_store.answer} reports it. *)
  | Keeper_intake_held of Keeper_shutdown_types.Operation_id.t
      (** This shutdown operation holds the Keeper's intake. Nothing was
          written and the ask stays open. *)
  | Keeper_queue_unavailable of string
      (** The Keeper's queue owner did not resolve or its lock raised. Nothing
          was appended to the ask log. *)

val answer :
  base_path:string -> keeper_name:string -> ask_id:string ->
  submissions:(string * Keeper_ask.response) list ->
  responder:Keeper_ask.responder -> now:float ->
  (Keeper_ask.answer list, answer_failure) result
(** Record an operator's answer and tell the Keeper. Inside the Keeper's
    intake fence and queue owner lock, the ask is validated, its
    [keeper-ask:<ask_id>] pointer is committed with strict durability, and
    then [Answered] is appended. An answer therefore never exists without its
    pointer. An ask already answered admits no pointer, so a consumed answer
    is not delivered again. After [Ok] the live wake hint is sent; a Keeper
    that is not running reads the pointer when it starts. *)

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
