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
  turn_verdict:Keeper_world_observation.turn_verdict ->
  wall_clock:float ->
  ?tool_diversity_entropy:float ->
  unit ->
  decision_record

(** Append a decision record to the in-memory ring buffer. *)
val append : keeper_name:string -> decision_record -> unit

(** Serialize a decision record for JSONL output. *)
val to_json : decision_record -> Yojson.Safe.t

(** Flush buffered records through a {!Dated_jsonl} store rooted at
    [.masc/decision_audit/{keeper_name}], so the day file is the same
    [YYYY-MM/DD.jsonl] the retention pruner resolves — UTC, not local time.
    Called periodically from heartbeat loop. *)
val flush_if_needed : base_path:string -> keeper_name:string -> unit
