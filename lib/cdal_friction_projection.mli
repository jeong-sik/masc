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

(** Friction projection for a single run. *)
type friction_projection = {
  window : string;  (** Always ["single_run"]. *)
  based_on_run_ids : string list;
  basis_hash : string;
  blocked_attempt_count : int;
  blocked_attempt_groups : blocked_attempt_group list;
}

(** [project_single_run ~store proof] reads [mode_violations.json]
    from [proof.raw_evidence_refs], parses v1 violation records,
    groups by [(tool_name, violation_kind, effective_mode)], and
    returns [Some projection] if violations exist, [None] otherwise.

    Returns [None] when:
    - no [mode_violations.json] ref exists in [raw_evidence_refs]
    - the file is missing on disk
    - the file parses to an empty array
    - a parse error occurs (treated as missing evidence) *)
val project_single_run :
  store:Agent_sdk.Proof_store.config ->
  Agent_sdk.Cdal_proof.t ->
  friction_projection option

(** Canonical JSON serialization with sorted keys. *)
val to_json : friction_projection -> Yojson.Safe.t
