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
    exceeds [tripwire_threshold] (default 3). A blocking
    [evidence/review_warning.json] gap also emits a
    [review_requirement:submit_for_verification] tripwire so downstream
    coordinators can route through their verification FSM.

    Returns [None] when no violations and no completeness gaps exist. *)
val project_single_run :
  store:Agent_sdk.Proof_store.config ->
  ?completeness_gaps:Cdal_types.completeness_gap list ->
  ?tripwire_threshold:int ->
  Agent_sdk.Cdal_proof.t ->
  friction_projection option

(** Canonical JSON serialization with sorted keys. *)
val to_json : friction_projection -> Yojson.Safe.t

(** {1 Cross-run window support}

    @since CDAL Phase 3 *)

(** Cross-run window specification. *)
type run_window =
  | Single_run
  | Last_n_runs of int
  | Session of string
  | Rolling_seconds of float

(** [project_window ~store ~window ?scope ?completeness_gaps
     ?tripwire_threshold proofs]
    Projects friction across a set of runs. For [Single_run],
    delegates to [project_single_run] using the first proof.
    For cross-run windows, aggregates violations across multiple
    manifests.

    @since CDAL Phase 3 *)
val project_window :
  store:Agent_sdk.Proof_store.config ->
  window:run_window ->
  ?completeness_gaps:Cdal_types.completeness_gap list ->
  ?tripwire_threshold:int ->
  Agent_sdk.Cdal_proof.t list ->
  friction_projection option

(** Compute deterministic basis hash for cross-run window.
    Includes window type, run IDs (sorted), and version.

    @since CDAL Phase 3 *)
val compute_window_basis_hash :
  window:run_window ->
  run_ids:string list ->
  string

(** String representation of a run window. *)
val window_to_string : run_window -> string
