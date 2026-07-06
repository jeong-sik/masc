(** Reputation_ledger_v2 — Append-only event ledger for v2 agent accountability.

    Records significant agent actions (tool outcomes, goal completions, and
    safety violations) as immutable JSONL events.  Each record links to a
    [raw_trace_run_id] for deep auditability per the v2 accountability roadmap.

    Storage: [.masc/reputation_v2/YYYY-MM/DD.jsonl] (filesystem-first, no DB).

    @since v2 Accountability & Reputation Roadmap
*)

(** {1 Event kinds} *)

type error_kind = private Error_kind of string
(** Stable tool outcome error family. Render only at JSON/log boundaries. *)

val error_kind_of_string : string -> error_kind
val error_kind_to_string : error_kind -> string

(** A tool call outcome recorded in the ledger. *)
type tool_outcome_event = {
  agent_id : string;
  tool_name : string;
  success : bool;
  error_kind : error_kind option;  (** Structured error label when [success = false]. *)
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
  Workspace.config ->
  agent_id:string ->
  tool_name:string ->
  success:bool ->
  ?error_kind:error_kind ->
  ?raw_trace_run_id:string ->
  unit ->
  unit
(** Append a [Tool_outcome] event to the ledger.  No-op when [agent_id] is
    empty; safe to call from any fiber (serialised via the Dated_jsonl mutex). *)

val emit_tool_outcome_result :
  Workspace.config ->
  agent_id:string ->
  tool_name:string ->
  success:bool ->
  ?error_kind:error_kind ->
  ?raw_trace_run_id:string ->
  unit ->
  (unit, string) result
(** Result-returning variant of {!emit_tool_outcome}.  Empty [agent_id]
    preserves the existing no-op contract and returns [Ok ()]. *)

val emit_goal_completion :
  Workspace.config ->
  agent_id:string ->
  task_id:string ->
  task_title:string ->
  completed_within_budget:bool ->
  on_topic:bool ->
  ?raw_trace_run_id:string ->
  unit ->
  unit
(** Append a [Goal_completion] event. *)

val emit_goal_completion_result :
  Workspace.config ->
  agent_id:string ->
  task_id:string ->
  task_title:string ->
  completed_within_budget:bool ->
  on_topic:bool ->
  ?raw_trace_run_id:string ->
  unit ->
  (unit, string) result
(** Result-returning variant of {!emit_goal_completion}.  Empty [agent_id]
    preserves the existing no-op contract and returns [Ok ()]. *)

val emit_safety_violation :
  Workspace.config ->
  agent_id:string ->
  violation_kind:string ->
  ?tool_name:string ->
  ?raw_trace_run_id:string ->
  unit ->
  unit
(** Append a [Safety_violation] event. *)

val emit_safety_violation_result :
  Workspace.config ->
  agent_id:string ->
  violation_kind:string ->
  ?tool_name:string ->
  ?raw_trace_run_id:string ->
  unit ->
  (unit, string) result
(** Result-returning variant of {!emit_safety_violation}.  Empty [agent_id]
    preserves the existing no-op contract and returns [Ok ()]. *)

(** {1 Readers} *)

val read_events_for_agent :
  Workspace.config ->
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
  execution_reliability : float;
      (** [tool_successes / tool_calls], 1.0 if no calls
          (neutral when no history). *)
  goal_adherence : float;
      (** [goal_adherent_completions / goal_completions], 1.0 if none
          (neutral when no history). *)
  safety_compliance : float;  (** [1.0 - penalty] where penalty grows with violations. *)
}

val default_ledger_metrics : agent_ledger_metrics
(** All-zero metrics with [execution_reliability = 1.0], [goal_adherence = 1.0],
    [safety_compliance = 1.0] — the baseline for an agent with no history. *)

val compute_ledger_metrics :
  Workspace.config ->
  agent_id:string ->
  window_days:int ->
  agent_ledger_metrics
(** Compute aggregate metrics from ledger events for [agent_id]. *)
