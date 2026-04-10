(** Keeper Decision Audit — Forensics-only decision trail.

    Records keeper decision snapshots for post-hoc analysis.
    Abstract type: external modules cannot access fields directly,
    preventing trust calculations from consuming forensics data (E5).

    Gated by MASC_DECISION_LAYER_LEVEL >= 1.

    @since Decision Layer v2 — Phase A2 (#6232) *)

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

(** Ring buffer capacity. Registered as Runtime_params. *)
val ring_capacity : unit -> int
