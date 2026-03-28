(** Cdal_friction_projection -- Single-run friction projection from v1 evidence.

    Groups blocked attempts from mode_violations.json by (tool_name,
    violation_kind, effective_mode).  Uses only v1 fields; v2 fields
    (effect_class, required_min_mode, violated_rule_id, trace_id, turn)
    are treated as unavailable.

    @since CDAL Phase 1A *)

(** Grouping key for a set of blocked attempts sharing the same
    tool, violation kind, and effective mode. *)
type blocked_attempt_key = {
  tool_name : string;
  violation_kind : string;
  effective_mode : string;
}

(** A group of blocked attempts with a shared key and occurrence count. *)
type blocked_attempt_group = {
  key : blocked_attempt_key;
  count : int;
}

(** A group of evidence completeness gaps sharing the same artifact/impact. *)
type evidence_gap_group = {
  artifact : string;
  reason : string;
  impact : string;
  count : int;
}

(** Friction projection for a single run. *)
type friction_projection = {
  window : string;  (** Always ["single_run"]. *)
  based_on_run_ids : string list;
  basis_hash : string;
  blocked_attempt_count : int;
  blocked_tool_counts : (string * int) list;
  blocked_attempt_groups : blocked_attempt_group list;
  evidence_gap_groups : evidence_gap_group list;
  review_tripwires : string list;
}

(** [project_single_run ~store ?completeness_gaps ?tripwire_threshold proof]
    reads [mode_violations.json], parses v1 violation records, groups by
    [(tool_name, violation_kind, effective_mode)], derives tool counts and
    evidence gap groups, and fires review tripwires when any group count
    exceeds [tripwire_threshold] (default 3).

    Returns [None] when no violations and no completeness gaps exist. *)
val project_single_run :
  store:Agent_sdk.Proof_store.config ->
  ?completeness_gaps:Cdal_types.completeness_gap list ->
  ?tripwire_threshold:int ->
  Agent_sdk.Cdal_proof.t ->
  friction_projection option

(** Canonical JSON serialization with sorted keys. *)
val to_json : friction_projection -> Yojson.Safe.t
