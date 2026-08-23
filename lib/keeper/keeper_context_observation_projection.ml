(** Current Keeper context-observation projection.

    Context occupancy is projected from the newest TurnRecord (RFC-0233):
    [input_tokens] is the provider-reported prompt total for the last
    completed turn and [context_window] the window resolved for that same
    request. The pair describes that completed request; it does not predict the
    next input. This module is the single wire projection for that
    measurement, for its typed absence, and for the separate,
    provider-reported last-turn usage.

    Display-only: nothing here may feed context pressure or compaction
    decisions. Fleet observation reads only the dated-JSONL tail, never
    checkpoints. *)

let turn_record_source = "turn_record"

(* Closed reason set. Every non-observed outcome names which stage failed;
   an unknown string here is a bug, not a new category. *)
let reason_measurement_missing = "context_measurement_missing"
let reason_undecodable = "turn_record_undecodable"
let reason_read_failed = "turn_record_read_failed"
let reason_without_usage = "turn_record_without_usage"
let reason_trace_mismatch = "turn_record_trace_mismatch"

let not_observed_json ~reason =
  `Assoc [ "kind", `String "not_observed"; "reason", `String reason ]
;;

let missing_measurement_json () =
  not_observed_json ~reason:reason_measurement_missing
;;

let context_fields_unavailable unavailable =
  let context =
    `Assoc
      [ "source", `Null
      ; "context_ratio", `Null
      ; "context_tokens", `Null
      ; "context_max", `Null
      ; "metrics_unavailable", unavailable
      ]
  in
  [ "context_ratio", `Null
  ; "context_tokens", `Null
  ; "context_max", `Null
  ; "context_source", `Null
  ; "context_metrics_unavailable", unavailable
  ; "context", context
  ]
;;

let missing_context_fields () =
  context_fields_unavailable (missing_measurement_json ())
;;

type latest_turn_observation =
  | No_turn_record
  | Undecodable_turn_record
  | Turn_record_read_failed
  | Observed of Turn_record.t

(* The strict tail read keeps failure classes apart: [read_recent] would
   silently skip a malformed newest line and serve the previous row as "the
   measurement", and it flattens listing failures into an empty result. *)
let latest_turn_observation ~config ~keeper_name =
  match
    let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
    Dated_jsonl.read_recent_result store 1
  with
  | Ok [] -> No_turn_record
  | Ok (Dated_jsonl.Parsed json :: _) ->
    (match Turn_record.of_json json with
     | Ok record -> Observed record
     | Error _ -> Undecodable_turn_record)
  | Ok (Dated_jsonl.Malformed_json { path; line_number; detail } :: _) ->
    Log.Keeper.warn
      "context observation newest turn-record row is malformed keeper=%s path=%s line=%s: %s"
      keeper_name
      path
      (match line_number with
       | Some line -> string_of_int line
       | None -> "?")
      detail;
    Undecodable_turn_record
  | Error read_error ->
    Log.Keeper.warn
      "context observation turn-record read failed keeper=%s: %s"
      keeper_name
      (Dated_jsonl.read_error_to_string read_error);
    Turn_record_read_failed
  | exception (Eio.Cancel.Cancelled _ as error) -> raise error
  | exception exn ->
    Log.Keeper.warn
      "context observation turn-record read failed keeper=%s: %s"
      keeper_name
      (Printexc.to_string exn);
    Turn_record_read_failed
;;

let observed_context_fields (record : Turn_record.t) =
  let opt_int = function
    | Some v -> `Int v
    | None -> `Null
  in
  let tokens = record.usage.input_tokens in
  let window = record.context_window in
  let ratio =
    match tokens, window with
    | Some tokens, Some window when window > 0 ->
      `Float (float_of_int tokens /. float_of_int window)
    | Some _, (Some _ | None) | None, _ -> `Null
  in
  let request_body_bytes =
    match record.request_wire_observation with
    | Some { body_bytes; _ } -> `Int body_bytes
    | None -> `Null
  in
  let context =
    `Assoc
      [ "source", `String turn_record_source
      ; "context_ratio", ratio
      ; "context_tokens", opt_int tokens
      ; "context_max", opt_int window
      ; "observed_at", `String (Masc_domain.iso8601_of_unix_seconds record.ts)
      ; "turn_ref", Ids.Turn_ref.to_yojson record.turn_ref
      ; "absolute_turn", `Int record.absolute_turn
      ; "request_body_bytes", request_body_bytes
      ; "metrics_unavailable", `Null
      ]
  in
  [ "context_ratio", ratio
  ; "context_tokens", opt_int tokens
  ; "context_max", opt_int window
  ; "context_source", `String turn_record_source
  ; "context_metrics_unavailable", `Null
  ; "context", context
  ]
;;

let context_fields ~config ~keeper_name ~current_trace_id =
  match latest_turn_observation ~config ~keeper_name with
  | No_turn_record ->
    context_fields_unavailable (not_observed_json ~reason:reason_measurement_missing)
  | Undecodable_turn_record ->
    context_fields_unavailable (not_observed_json ~reason:reason_undecodable)
  | Turn_record_read_failed ->
    context_fields_unavailable (not_observed_json ~reason:reason_read_failed)
  | Observed record ->
    (* A reseeded identity starts a new trace while the per-name store keeps
       the previous trace's rows: projecting those would show the prior
       generation's occupancy on a keeper whose context is empty. *)
    if not (String.equal record.trace_id current_trace_id)
    then context_fields_unavailable (not_observed_json ~reason:reason_trace_mismatch)
    else (
      match record.usage.input_tokens with
      | None ->
        context_fields_unavailable (not_observed_json ~reason:reason_without_usage)
      | Some _ -> observed_context_fields record)
;;

let last_turn_usage_json_of_meta
      (meta : Keeper_meta_contract.keeper_meta)
  =
  let usage = meta.runtime.usage in
  match usage.last_usage_reported_at with
  | None -> `Null
  | Some observed_at ->
    `Assoc
      [ "input_tokens", `Int usage.last_input_tokens
      ; "output_tokens", `Int usage.last_output_tokens
      ; "total_tokens", `Int usage.last_total_tokens
      ; ( "observed_at"
        , `String (Masc_domain.iso8601_of_unix_seconds observed_at) )
      ; "source", `String "keeper_runtime_usage"
      ]
;;

let last_turn_usage_json ~base_path
      (persisted_meta : Keeper_meta_contract.keeper_meta)
  =
  let observation_meta =
    match Keeper_registry.get ~base_path persisted_meta.name with
    | Some entry
      when Keeper_id.Trace_id.equal
             entry.meta.runtime.trace_id
             persisted_meta.runtime.trace_id ->
      entry.meta
    | Some _ | None -> persisted_meta
  in
  last_turn_usage_json_of_meta observation_meta
;;
