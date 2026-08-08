(** Pure JSON decoders for session store artifacts.

    Stateless parsing functions bridging raw JSON to typed
    Sessions_types records. No file I/O or store access. *)

open Sessions_types

let json_parse_error = Util.json_parse_error

open Result_syntax

let parse_json_string raw =
  try Ok (Yojson.Safe.from_string raw) with
  | Yojson.Json_error detail -> Error (json_parse_error detail)
;;

let parse_runtime_json of_yojson raw =
  let* json = parse_json_string raw in
  match of_yojson json with
  | Ok value -> Ok value
  | Error detail -> Error (json_parse_error detail)
;;

let decode_json_with decoder raw =
  let* json = parse_json_string raw in
  (* Exception coverage mirrors Llm_provider.Json_util.decode_json_with
     (Json_error via parse_json_string, Type_error and Undefined here); the
     error type differs — this boundary reports typed session parse errors. *)
  try Ok (decoder json) with
  | Yojson.Safe.Util.Type_error (detail, _) | Yojson.Safe.Util.Undefined (detail, _) ->
    Error (json_parse_error detail)
;;

let tool_contract_of_json json =
  match Sessions_types.tool_contract_of_yojson json with
  | Ok contract -> contract
  | Error detail -> raise (Yojson.Safe.Util.Type_error (detail, json))
;;

let telemetry_of_json json =
  let open Yojson.Safe.Util in
  let event_counts : telemetry_event_count list =
    json
    |> member "event_counts"
    |> to_assoc
    |> List.map (fun (name, value) -> { name; count = to_int value })
  in
  let steps : telemetry_step list =
    json
    |> member "steps"
    |> to_list
    |> List.map (fun step ->
      { seq = step |> member "seq" |> to_int
      ; ts = step |> member "ts" |> to_float
      ; kind = step |> member "kind" |> to_string
      ; participant = step |> member "participant" |> to_string_option
      ; detail = step |> member "detail" |> to_string_option
      })
  in
  ({ session_id = json |> member "session_id" |> to_string
   ; generated_at = json |> member "generated_at" |> to_float
   ; step_count = json |> member "step_count" |> to_int
   ; event_counts
   ; steps
   }
   : telemetry)
;;

let infer_event_name_from_kind kind =
  let known =
    [ "Session_started", "session_started"
    ; "Session_settings_updated", "session_settings_updated"
    ; "Turn_recorded", "turn_recorded"
    ; "Agent_spawn_requested", "agent_spawn_requested"
    ; "Agent_became_live", "agent_became_live"
    ; "Agent_output_delta", "agent_output_delta"
    ; "Agent_completed", "agent_completed"
    ; "Agent_failed", "agent_failed"
    ; "Artifact_attached", "artifact_attached"
    ; "Checkpoint_saved", "checkpoint_saved"
    ; "Finalize_requested", "finalize_requested"
    ; "Session_completed", "session_completed"
    ; "Session_failed", "session_failed"
    ]
  in
  known
  |> List.find_opt (fun (needle, _) -> Util.string_contains ~needle kind)
  |> Option.map snd
  |> Option.value ~default:(String.lowercase_ascii kind)
;;

let structured_telemetry_of_json json =
  let open Yojson.Safe.Util in
  let event_counts : structured_event_count list =
    match json |> member "event_name_counts" with
    | `Null ->
      json
      |> member "event_counts"
      |> to_assoc
      |> List.map (fun (name, value) -> { event_name = name; count = to_int value })
    | counts_json ->
      counts_json
      |> to_list
      |> List.map (fun item ->
        { event_name = item |> member "event_name" |> to_string
        ; count = item |> member "count" |> to_int
        })
  in
  let steps : structured_telemetry_step list =
    json
    |> member "steps"
    |> to_list
    |> List.map (fun step ->
      let kind = step |> member "kind" |> to_string in
      { seq = step |> member "seq" |> to_int
      ; ts = step |> member "ts" |> to_float
      ; event_name =
          step
          |> member "event_name"
          |> to_string_option
          |> Option.value ~default:(infer_event_name_from_kind kind)
      ; participant = step |> member "participant" |> to_string_option
      ; detail = step |> member "detail" |> to_string_option
      ; actor = step |> member "actor" |> to_string_option
      ; role = step |> member "role" |> to_string_option
      ; provider = step |> member "provider" |> to_string_option
      ; model = step |> member "model" |> to_string_option
      ; raw_trace_run_id = step |> member "raw_trace_run_id" |> to_string_option
      ; stop_reason = step |> member "stop_reason" |> to_string_option
      ; artifact_id = step |> member "artifact_id" |> to_string_option
      ; artifact_name = step |> member "artifact_name" |> to_string_option
      ; artifact_kind = step |> member "artifact_kind" |> to_string_option
      ; checkpoint_label = step |> member "checkpoint_label" |> to_string_option
      ; outcome = step |> member "outcome" |> to_string_option
      ; dropped_output_deltas = step |> member "dropped_output_deltas" |> to_int_option
      ; persistence_failure_phase =
          step |> member "persistence_failure_phase" |> to_string_option
      })
  in
  ({ session_id = json |> member "session_id" |> to_string
   ; generated_at = json |> member "generated_at" |> to_float
   ; step_count = json |> member "step_count" |> to_int
   ; event_counts
   ; steps
   }
   : structured_telemetry)
;;

let evidence_of_json json =
  let open Yojson.Safe.Util in
  let files =
    json
    |> member "files"
    |> to_list
    |> List.map (fun file ->
      { label = file |> member "label" |> to_string
      ; path = file |> member "path" |> to_string
      ; size_bytes = file |> member "size_bytes" |> to_int
      ; md5 = file |> member "md5" |> to_string
      })
  in
  let missing_files =
    json
    |> member "missing_files"
    |> to_list
    |> List.map (fun file ->
      { label = file |> member "label" |> to_string
      ; path = file |> member "path" |> to_string
      })
  in
  { session_id = json |> member "session_id" |> to_string
  ; generated_at = json |> member "generated_at" |> to_float
  ; files
  ; missing_files
  }
;;

let raw_trace_manifest_of_json = raw_trace_manifest_of_yojson
