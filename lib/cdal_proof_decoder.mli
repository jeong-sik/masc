(** CDAL proof bundle decoder -- MASC-side consumer of OAS proof manifests.

    Part of the Contract-Driven Agent Loop walking skeleton.

    This module decodes OAS proof bundle manifests (JSON) into MASC-local
    types. It does NOT import OAS types directly; the boundary is JSON.

    {2 Invariants}

    - {b I1 Totality}: [of_json] is total -- all valid JSON inputs produce
      [Ok _] or [Error _], never an exception.
    - {b I2 Idempotency}: [of_json j |> Result.map to_json |> Result.map of_json]
      yields the same result as [of_json j].
    - {b I3 Schema version guard}: Unknown [schema_version] values produce
      [Error (Schema_version_unsupported _)], never silent downgrade. *)

(** {1 Types}

    These mirror OAS [Cdal_proof.t] but are independently defined.
    The coupling is at the JSON schema level, verified by fixture tests. *)

type result_status =
  | Completed
  | Errored
  | Timed_out
  | Cancelled

type execution_mode =
  | Diagnose
  | Draft
  | Execute

type risk_class =
  | Low
  | Medium
  | High
  | Critical

type provider_snapshot = {
  provider_name : string;
  model_id : string;
  api_version : string option;
}

type capability_snapshot = {
  tools : string list;
  mcp_servers : string list;
  max_turns : int;
  max_tokens : int option;
  thinking_enabled : bool option;
}

type artifact_ref = string

type proof_manifest = {
  schema_version : int;
  run_id : string;
  contract_id : string;
  requested_execution_mode : execution_mode;
  effective_execution_mode : execution_mode;
  mode_decision_source : string;
  risk_class : risk_class;
  provider_snapshot : provider_snapshot;
  capability_snapshot : capability_snapshot;
  tool_trace_refs : artifact_ref list;
  raw_evidence_refs : artifact_ref list;
  checkpoint_ref : artifact_ref option;
  result_status : result_status;
  started_at : float;
  ended_at : float;
}

(** {1 Decode errors} *)

type decode_error =
  | Schema_version_unsupported of int
  | Missing_field of string
  | Invalid_field of { field : string; reason : string }
  | Json_parse_error of string

val pp_decode_error : Format.formatter -> decode_error -> unit
val decode_error_to_string : decode_error -> string

(** {1 Evidence gap}

    When decoding partially succeeds but fields are missing or malformed,
    an evidence gap record is produced alongside the error. This supports
    antifragile learning -- the system records what failed for downstream
    pattern analysis rather than silently discarding. *)

type evidence_gap = {
  run_id : string option;
  missing_fields : string list;
  invalid_fields : (string * string) list;  (** (field, reason) *)
  raw_json_excerpt : string;
}

(** {1 Operations} *)

val schema_version_supported : int
(** The schema version this decoder understands. Currently [1]. *)

val of_json : Yojson.Safe.t -> (proof_manifest, decode_error) result
(** Decode a proof manifest from JSON. Total function (Invariant I1). *)

val to_json : proof_manifest -> Yojson.Safe.t
(** Re-encode to JSON for roundtrip verification (Invariant I2). *)

val evidence_gap_of_error :
  json:Yojson.Safe.t -> decode_error -> evidence_gap
(** Extract an evidence gap record from a decode failure.
    Always produces a record, even for schema version errors. *)

val was_downgraded : proof_manifest -> bool
(** [true] if [effective_execution_mode < requested_execution_mode]. *)

val duration_s : proof_manifest -> float
(** [ended_at - started_at]. *)
