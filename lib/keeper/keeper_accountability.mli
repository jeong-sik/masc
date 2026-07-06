type claim_kind =
  | Task_commitment
  | Completion_claim

type claim_status =
  | Pending
  | Supported
  | Unsupported
  | Expired
  | Partial

val accountability_emit_skip_metric : string
(** #10314: Otel_metric_store counter name surfaced for tests and dashboards.
    Labels:
    - [kind] ∈ task_transition | completion_claim
    - [reason] ∈ not_keeper_agent_name | empty_subject
    A non-zero rate on a keeper that has decisions.jsonl traffic
    indicates the fleet observability gap from #10314. *)

val record_task_transition :
  Workspace_query.config ->
  agent_name:string ->
  task_id:string ->
  transition:Masc_domain.task_action ->
  details:Yojson.Safe.t ->
  unit

val record_task_transition_result :
  Workspace_query.config ->
  agent_name:string ->
  task_id:string ->
  transition:Masc_domain.task_action ->
  details:Yojson.Safe.t ->
  (unit, string) result

val record_completion_claim :
  Workspace_query.config ->
  keeper_name:string ->
  agent_name:string ->
  trace_id:string ->
  turn_number:int ->
  subject:string ->
  ?task_id:string ->
  ?evidence_refs:string list ->
  ?surface:string ->
  strong_evidence:bool ->
  strong_evidence_refs:string list ->
  unit ->
  unit

val record_completion_claim_result :
  Workspace_query.config ->
  keeper_name:string ->
  agent_name:string ->
  trace_id:string ->
  turn_number:int ->
  subject:string ->
  ?task_id:string ->
  ?evidence_refs:string list ->
  ?surface:string ->
  strong_evidence:bool ->
  strong_evidence_refs:string list ->
  unit ->
  (unit, string) result

val accountability_summary_json :
  Workspace_query.config ->
  keeper_name:string ->
  agent_name:string ->
  Yojson.Safe.t

val accountability_summary_lookup :
  Workspace_query.config ->
  keeper_name:string ->
  agent_name:string ->
  Yojson.Safe.t

val enable_window_read_count_for_testing : unit -> unit
val disable_window_read_count_for_testing : unit -> unit
val window_read_count_for_testing : unit -> int

val accountability_risk_is_high :
  Workspace_query.config ->
  keeper_name:string ->
  agent_name:string ->
  bool

(** {1 Attribution envelope (Layer 1)}

    Convert a [claim_status] into the typed attribution envelope used by
    SSE emitters. Accountability is [Det]: status is derived from
    resolution events or deterministic time-based expiry.

    The caller is expected to have already collected the claim snapshot
    and built its own evidence payload — this keeps [claim_snapshot] and
    its constituent types private to this module. *)

val attribution_from_status :
  claim_status ->
  evidence:Yojson.Safe.t ->
  ?resolution_reason:string ->
  unit ->
  Attribution.t option
(** Mapping:
    - [Supported]    → [Attribution.Passed]
    - [Unsupported]  → [Attribution.Policy_failed { reason }]
                        (uses [resolution_reason] if given, else default)
    - [Expired]      → [Attribution.Policy_failed { reason = "expired" }]
    - [Partial]      → [Attribution.Partial_pass { score; rationale }]
                        (legacy [score] scalar is [0.0] because accountability
                         partial status is categorical unless an upstream
                         judge supplies a scored verdict; rationale from
                         [resolution_reason] or default)
    - [Pending]      → [None] (no verdict yet — consistent with verification)

    Returns [None] only for [Pending]. All other statuses yield [Some]. *)
