(** Keeper Decision Audit — Forensics-only decision trail.

    Records keeper decision snapshots for post-hoc analysis.
    Abstract type: external modules cannot access fields directly,
    preventing trust calculations from consuming forensics data (E5).

    Gated by MASC_DECISION_LAYER_LEVEL >= 1.

    @since Decision Layer v2 — Phase A2 (#6232) *)

(** Current decision layer level (MASC_DECISION_LAYER_LEVEL, 0-4).
    Cached on first call — no per-call env lookup after initialization.
    Level 0: off, 1: audit, 2: +guard bridge, 3: +trust, 4: +claim. *)
val decision_layer_level : unit -> int

(** Whether audit is enabled (MASC_DECISION_LAYER_LEVEL >= 1).
    Cached on first call (delegates to [decision_layer_level]). *)
val audit_enabled : unit -> bool

(** Abstract decision record. Field access restricted to this module. *)
type decision_record

(** Construct a decision record from pipeline outputs. *)
val make :
  cycle_id:string ->
  keeper_name:string ->
  generation:int ->
  ?snapshot:Keeper_measurement.measurement_snapshot ->
  heartbeat_verdict:Heartbeat_smart.decision ->
  turn_verdict:Keeper_world_observation.turn_verdict ->
  wall_clock:float ->
  ?tool_diversity_entropy:float ->
  unit ->
  decision_record

(** Append a decision record to the in-memory ring buffer.
    If MASC_DECISION_LAYER_LEVEL < 1, this is a no-op. *)
val append : keeper_name:string -> decision_record -> unit

(** Read recent decision records for forensics.
    Returns most recent first, up to ring buffer capacity. *)
val recent : keeper_name:string -> limit:int -> decision_record list

(** Serialize a decision record for JSONL output. *)
val to_json : decision_record -> Yojson.Safe.t

(** Flush buffered records to JSONL file.
    Path: .masc/decision_audit/{keeper_name}/YYYY-MM/DD.jsonl
    Called periodically from heartbeat loop. *)
val flush_if_needed : base_path:string -> keeper_name:string -> unit

(** Ring buffer capacity (env: MASC_DECISION_AUDIT_RING_CAPACITY, default 50, min 1). *)
val ring_capacity : unit -> int

(** Generate a Mermaid stateDiagram-v2 for the Decision Pipeline.
    Shows the Guard→Thompson→ToolPolicy feedback loop with current
    phase highlighted and Thompson score annotated.

    Optional parameters surface per-cycle Decision Pipeline state from
    [KeeperDecisionPipeline.tla] (state variables: guard_penalties_this_cycle,
    tool_policy selection, turn_outcome). When omitted, the note block
    shows "n/a" for the missing field — callers can adopt the new
    parameters incrementally without breaking the render. *)
val decision_pipeline_to_mermaid :
  ?guard_penalty_this_cycle:int ->
  ?tool_policy_mode:[`Preset of string | `Custom] ->
  ?turn_outcome:[`Ok | `Failed | `Blocked] ->
  phase:Keeper_state_machine.phase ->
  thompson_alpha:float ->
  thompson_beta:float ->
  tool_count:int ->
  recovery_floor_count:int ->
  unit ->
  string

(** Generate a Mermaid stateDiagram-v2 for the Cascade FSM.
    Shows the provider failover chain with accept/reject/exhaustion
    transitions. [last_provider_result] highlights the provider that
    served the most recent successful response. *)
val cascade_fsm_to_mermaid :
  models:string list ->
  last_provider_result:string option ->
  string
