(** Reputation_ledger_v2 — Append-only event ledger for v2 agent accountability.

    Records significant agent actions (tool outcomes, goal completions, and
    safety violations) as immutable JSONL events.  Each record links to a
    [raw_trace_run_id] for deep auditability per the v2 accountability roadmap.

    Storage: [.masc/reputation_v2/YYYY-MM/DD.jsonl] (filesystem-first, no DB).

    @since v2 Accountability & Reputation Roadmap
*)

(** {1 Event kinds} *)

(** A tool call outcome recorded in the ledger. *)
type tool_outcome_event = {
  agent_id : string;
  tool_name : string;
  success : bool;
  error_kind : string option;  (** Structured error label when [success = false]. *)
  raw_trace_run_id : string option;
  timestamp : float;
}

(** A goal / task completion event. *)
type goal_completion_event = {
  agent_id : string;
  task_id : string;
  task_title : string;
  completed_within_budget : bool;  (** True when the agent finished without exhausting its token budget. *)
  on_topic : bool;  (** True when the agent's actions stayed aligned with the goal. *)
  raw_trace_run_id : string option;
  timestamp : float;
}

(** A safety / sandbox violation event. *)
type safety_violation_event = {
  agent_id : string;
  violation_kind : string;  (** e.g. "scope_violation" | "external_in_draft" *)
  tool_name : string option;
  raw_trace_run_id : string option;
  timestamp : float;
}

(** Discriminated union over all v2 ledger event kinds. *)
type ledger_event =
  | Tool_outcome of tool_outcome_event
  | Goal_completion of goal_completion_event
  | Safety_violation of safety_violation_event

(** {1 Emitters} *)

val emit_tool_outcome :
  Coord.config ->
  agent_id:string ->
  tool_name:string ->
  success:bool ->
  ?error_kind:string ->
  ?raw_trace_run_id:string ->
  unit ->
  unit
(** Append a [Tool_outcome] event to the ledger.  No-op when [agent_id] is
    empty; safe to call from any fiber (serialised via the Dated_jsonl mutex). *)

val emit_goal_completion :
  Coord.config ->
  agent_id:string ->
  task_id:string ->
  task_title:string ->
  completed_within_budget:bool ->
  on_topic:bool ->
  ?raw_trace_run_id:string ->
  unit ->
  unit
(** Append a [Goal_completion] event. *)

val emit_safety_violation :
  Coord.config ->
  agent_id:string ->
  violation_kind:string ->
  ?tool_name:string ->
  ?raw_trace_run_id:string ->
  unit ->
  unit
(** Append a [Safety_violation] event. *)

(** {1 Readers} *)

val read_events_for_agent :
  Coord.config ->
  agent_id:string ->
  window_days:int ->
  ledger_event list
(** Return all ledger events for [agent_id] within the past [window_days] days,
    oldest first.  Returns [[]] when no events exist. *)

(** {1 Aggregate metrics} *)

type agent_ledger_metrics = {
  tool_calls : int;
  tool_successes : int;
  goal_completions : int;
  goal_adherent_completions : int;
  safety_violations : int;
  execution_reliability : float;  (** [tool_successes / tool_calls], 0.0 if no calls. *)
  goal_adherence : float;  (** [goal_adherent_completions / goal_completions], 0.0 if none. *)
  safety_compliance : float;  (** [1.0 - penalty] where penalty grows with violations. *)
}

val default_ledger_metrics : agent_ledger_metrics
(** All-zero metrics with [execution_reliability = 1.0], [goal_adherence = 1.0],
    [safety_compliance = 1.0] — the baseline for an agent with no history. *)

val compute_ledger_metrics :
  Coord.config ->
  agent_id:string ->
  window_days:int ->
  agent_ledger_metrics
(** Compute aggregate metrics from ledger events for [agent_id]. *)
