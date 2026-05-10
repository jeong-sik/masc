(** Keeper_turn_telemetry — post-turn observability logging.

    Extracted from keeper_agent_run.ml as part of #5732 god-module
    split. Contains logging helpers for CDAL proofs, contract
    verdicts, friction projections, and memory-bank writes. *)

(** Convert a list of strings to a JSON list of strings. *)
val string_list_json : string list -> Yojson.Safe.t

(** Artifact names for completeness gaps that block the verdict
    (sorted, deduplicated). *)
val blocking_gap_artifacts :
  Cdal_types.contract_verdict -> string list

(** Artifact names for evidence-gap groups in a friction projection
    (sorted, deduplicated). *)
val friction_gap_artifacts :
  Cdal_friction_projection.friction_projection -> string list

(** Activity-payload JSON for a contract verdict, suitable for
    dashboard / event-bus consumption. *)
val contract_verdict_activity_payload :
  keeper_name:string ->
  Cdal_types.contract_verdict ->
  Yojson.Safe.t

(** Activity-payload JSON for a friction projection. *)
val friction_activity_payload :
  keeper_name:string ->
  Cdal_friction_projection.friction_projection ->
  Yojson.Safe.t

(** Log a CDAL proof at debug (Completed) or warn level. *)
val log_keeper_proof :
  keeper_name:string -> Masc_mcp_cdal_runtime.Cdal_proof.t -> unit

(** Log a contract verdict at debug (Satisfied) or warn (Violated,
    Inconclusive) level. *)
val log_keeper_contract_verdict :
  keeper_name:string ->
  Cdal_types.contract_verdict ->
  unit

(** Log a friction projection. Severity escalates with tripwires
    (warn) or any blocked attempts (debug). *)
val log_keeper_friction :
  keeper_name:string ->
  Cdal_friction_projection.friction_projection ->
  unit

(** Log a memory-bank write summary. Promoted to info level when
    [notes_written >= 10], otherwise debug. *)
val log_keeper_memory_write :
  keeper_name:string ->
  notes_written:int ->
  kinds_written:string list ->
  unit
