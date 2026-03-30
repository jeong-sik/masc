(** Structured delta entries for inter-session handoff.

    Produces evidence-pointer structures instead of prose summaries.
    The handoff skill (SSOT per D-0 ADR) consumes these entries.

    @since 2.176.0 *)

type delta_entry = {
  since_checkpoint_id: string option;
  evidence_refs: evidence_ref list;
  updated_paths: string list;
  open_loops: open_loop list;
  decisions: decision list;
  keeper_state: Keeper_memory_policy.keeper_state_snapshot option;
  created_at: float;
}

and evidence_ref = {
  ref_type: string;
  ref_id: string;
  description: string;
}

and open_loop = {
  loop_id: string;
  description: string;
  status: string;
  blocking_reason: string option;
}

and decision = {
  decision_id: string;
  summary: string;
  rationale: string;
}

(** Serialize delta entry to JSON. *)
val to_json : delta_entry -> Yojson.Safe.t

(** Build a delta entry from keeper state and session metadata. *)
val build :
  ?session_id:string ->
  ?snapshot:Keeper_memory_policy.keeper_state_snapshot ->
  ?git_changes:string list ->
  ?commits:(string * string) list ->
  unit ->
  delta_entry

(** Render delta entry as markdown for session-state.md or handoff. *)
val to_markdown : delta_entry -> string
