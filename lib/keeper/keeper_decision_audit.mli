(** Keeper Decision Audit — Forensics-only decision trail.

    Records keeper decision snapshots for post-hoc analysis.
    Abstract type: external modules cannot access fields directly,
    preventing trust calculations from consuming forensics data (E5).

    @since Decision Audit Phase A2 (#6232) *)

(** Abstract decision record. Field access restricted to this module. *)
type decision_record

(** Construct a decision record from pipeline outputs. *)
val make :
  cycle_id:string ->
  keeper_name:string ->
  generation:int ->
  ?snapshot:Keeper_measurement.measurement_snapshot ->
  turn_verdict:Keeper_world_observation.turn_verdict ->
  wall_clock:float ->
  ?tool_diversity_entropy:float ->
  unit ->
  decision_record

(** Append a decision record to the in-memory ring buffer. *)
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

    The optional turn outcome is included when it is available. *)
val decision_pipeline_to_mermaid :
  ?turn_outcome:[`Ok | `Failed] ->
  phase:Keeper_state_machine.phase ->
  thompson_alpha:float ->
  thompson_beta:float ->
  unit ->
  string

(** Reasons a provider may be [Unhealthy].
    Each constructor corresponds to a distinguishable failure signal
    the runtime can record against a provider entry. Keep this list
    closed — new reasons require dashboard+spec updates. *)
type unhealthy_reason =
  [ `Saturated       (** slot pool full, no capacity left *)
  | `Unreachable     (** connect/DNS failure, provider not responding *)
  | `Rate_limited    (** 429 / quota exhausted *)
  | `Timeout         (** request did not complete within deadline *)
  | `Other of string (** free-form reason for signals we do not yet categorise *)
  ]

(** Provider health surfaced in the Runtime FSM render.
    Mirrors [phealth] in RuntimeLiveness.tla. [Unknown] covers the case
    where the runtime has no recent sample. [Unhealthy] carries a
    typed reason so the dashboard can distinguish saturation vs
    unreachability vs rate limiting without parsing free text. *)
type provider_health =
  [ `Healthy
  | `Unhealthy of unhealthy_reason
  | `Unknown
  ]

(** Generate a Mermaid stateDiagram-v2 for the Runtime FSM.
    Shows the provider failover chain with accept/reject/exhaustion
    transitions. [last_provider_result] highlights the provider that
    served the most recent successful response.

    Optional parameters bind runtime state from RuntimeLiveness.tla
    ([phealth]) and Keeper_runtime_routing (the reason the routing layer
    picked this runtime profile, e.g. phase-derived vs explicit override).

    The emitted edge labels are phrased in terms of
    RuntimeLiveness.tla actions (AdmitKeeper/TryNonLast/TryLast/
    UnblockWaiting/RespondOk/CascadableError/LastProviderFail/Timeout)
    rather than HTTP status literals, so the diagram stays valid even
    when the underlying provider protocol changes. *)
val runtime_fsm_to_mermaid :
  ?provider_health:(string * provider_health) list ->
  ?effective_runtime_reason:string ->
  models:string list ->
  last_provider_result:string option ->
  unit ->
  string
