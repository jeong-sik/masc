(** Current Keeper context-observation wire projection. *)

val missing_context_fields :
  unit ->
  (string * Yojson.Safe.t) list
(** Null context fields plus the typed missing-measurement reason. Checkpoint inventory
    is a separate endpoint and is not loaded by fleet context observation. *)

val context_fields :
  config:Workspace.config ->
  keeper_name:string ->
  current_trace_id:string ->
  (string * Yojson.Safe.t) list
(** Context occupancy projected from the keeper's newest TurnRecord
    (RFC-0233), the measurement SSOT: [context_tokens] is the
    provider-reported prompt total of the last completed turn,
    [context_max] the context window resolved for that same request, and
    the nested ["context"] object carries provenance ([turn_ref],
    [observed_at], [request_body_bytes]).

    Observation-only: no runtime consumer may derive context-pressure or
    compaction decisions from these fields; dashboard triage surfaces
    (bands, ordering, health counts) render them. It reads only the
    dated-JSONL tail (one strict line), never checkpoints. Absence stays
    typed via [context_metrics_unavailable] with a closed reason set:
    [context_measurement_missing] (no record),
    [turn_record_undecodable] (newest line is not valid JSON or rejects
    the strict codec, warn-logged),
    [turn_record_read_failed] (store IO or listing failed, warn-logged),
    [turn_record_without_usage] (turn completed without provider usage),
    [turn_record_trace_mismatch] (newest row belongs to a previous trace
    identity — a reseeded keeper stays typed-absent until its first
    completed turn). *)

val last_turn_usage_json_of_meta :
  Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
(** Provider-reported usage from the latest successful usage observation.
    Its timestamp is independent from [last_turn_ts], which also advances on
    failed turns. *)
(** Provider-reported usage for the latest completed turn. This is not
    context occupancy and must never feed context pressure or compaction
    decisions. *)

val last_turn_usage_json :
  base_path:string ->
  Keeper_meta_contract.keeper_meta ->
  Yojson.Safe.t
(** Process-local provider usage for the same persisted Keeper identity.
    Persisted token counters are never promoted when the live registry has no
    typed observation. *)
