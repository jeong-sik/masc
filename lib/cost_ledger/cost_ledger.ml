type inference_identity =
  { trace_id : string
  ; keeper_turn_id : int
  ; agent_core_turn_ordinal : int
  }

type source =
  | Manual_cli
  | Auto_trajectory of inference_identity

type usage_projection = Raw_observation | Resolved_delta

type usage =
  | Usage_missing
  | Usage_reported of
      { input_tokens : int
      ; output_tokens : int
      ; cost_usd : float
      }

type t =
  { agent : string
  ; task_id : string option
  ; model : string
  ; usage : usage
  ; usage_projection : usage_projection
  ; timestamp : string
  ; ts_unix : float
  ; source : source
  }

type decode_error =
  { field : string
  ; expectation : string
  }

let ( let* ) = Result.bind

let decode_error_to_string error =
  Printf.sprintf "%s %s" error.field error.expectation
;;

let invalid field expectation = Error { field; expectation }

let nonblank value =
  let value = String.trim value in
  if String.equal value "" then None else Some value
;;

let required_string fields key =
  match List.assoc_opt key fields with
  | Some (`String value) ->
    (match nonblank value with
     | Some value -> Ok value
     | None -> invalid key "must be a non-empty string")
  | _ -> invalid key "must be a non-empty string"
;;

let required_nullable_string fields key =
  match List.assoc_opt key fields with
  | Some `Null -> Ok None
  | Some (`String value) ->
    (match nonblank value with
     | Some value -> Ok (Some value)
     | None -> invalid key "must be null or a non-empty string")
  | _ -> invalid key "must be null or a non-empty string"
;;

let required_bool fields key =
  match List.assoc_opt key fields with
  | Some (`Bool value) -> Ok value
  | _ -> invalid key "must be a boolean"
;;

let required_int fields key =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Ok value
  | _ -> invalid key "must be an integer"
;;

let required_positive_int fields key =
  let* value = required_int fields key in
  if value > 0 then Ok value else invalid key "must be a positive integer"
;;

let required_nonnegative_int fields key =
  let* value = required_int fields key in
  if value >= 0 then Ok value else invalid key "must be a non-negative integer"
;;

let required_finite_float fields key =
  let value =
    match List.assoc_opt key fields with
    | Some (`Float value) -> Some value
    | Some (`Int value) -> Some (Float.of_int value)
    | _ -> None
  in
  match value with
  | Some value when Float.is_finite value -> Ok value
  | _ -> invalid key "must be a finite number"
;;

let required_null fields key =
  match List.assoc_opt key fields with
  | Some `Null -> Ok ()
  | _ -> invalid key "must be null"
;;

let source_to_string = function
  | Manual_cli -> "manual_cli"
  | Auto_trajectory _ -> "auto_trajectory"
;;

let usage_projection_to_string = function
  | Raw_observation -> "raw_observation"
  | Resolved_delta -> "resolved_delta"
;;

let usage_projection_of_fields fields source =
  let* projection = required_string fields "usage_projection" in
  match projection, source with
  | "resolved_delta", _ -> Ok Resolved_delta
  | "raw_observation", Auto_trajectory _ -> Ok Raw_observation
  | "raw_observation", Manual_cli ->
    invalid "usage_projection" "must be resolved_delta for manual_cli"
  | _ -> invalid "usage_projection" "must be raw_observation or resolved_delta"
;;

let compare_inference_identity left right =
  let by_trace = String.compare left.trace_id right.trace_id in
  if by_trace <> 0
  then by_trace
  else (
    let by_keeper_turn = Int.compare left.keeper_turn_id right.keeper_turn_id in
    if by_keeper_turn <> 0
    then by_keeper_turn
    else Int.compare left.agent_core_turn_ordinal right.agent_core_turn_ordinal)
;;

let inference_identity row =
  match row.source with
  | Manual_cli -> None
  | Auto_trajectory identity -> Some identity
;;

let source_of_fields fields =
  let* source = required_string fields "source" in
  match source with
  | "manual_cli" ->
    let* () = required_null fields "trace_id" in
    let* () = required_null fields "keeper_turn_id" in
    let* () = required_null fields "agent_core_turn_ordinal" in
    Ok Manual_cli
  | "auto_trajectory" ->
    let* trace_id = required_string fields "trace_id" in
    let* keeper_turn_id = required_positive_int fields "keeper_turn_id" in
    let* agent_core_turn_ordinal =
      required_nonnegative_int fields "agent_core_turn_ordinal"
    in
    Ok (Auto_trajectory { trace_id; keeper_turn_id; agent_core_turn_ordinal })
  | _ -> invalid "source" "must be manual_cli or auto_trajectory"
;;

let usage_of_fields fields source =
  let* usage_missing = required_bool fields "usage_missing" in
  if usage_missing
  then (
    match source with
    | Manual_cli -> invalid "usage_missing" "must be false for manual_cli"
    | Auto_trajectory _ ->
      let* () = required_null fields "input_tokens" in
      let* () = required_null fields "output_tokens" in
      let* () = required_null fields "cost_usd" in
      Ok Usage_missing)
  else (
    let* input_tokens = required_int fields "input_tokens" in
    let* output_tokens = required_int fields "output_tokens" in
    let* cost_usd = required_finite_float fields "cost_usd" in
    match source with
    | Manual_cli
      when input_tokens < 0 || output_tokens < 0 || Float.compare cost_usd 0.0 < 0 ->
      invalid
        "manual_cli usage"
        "must contain non-negative token counts and cost_usd"
    | Manual_cli | Auto_trajectory _ ->
      Ok (Usage_reported { input_tokens; output_tokens; cost_usd }))
;;

let of_json = function
  | `Assoc fields ->
    let* agent = required_string fields "agent" in
    let* task_id = required_nullable_string fields "task_id" in
    let* model = required_string fields "model" in
    let* timestamp = required_string fields "timestamp" in
    let* ts_unix =
      match Masc_domain.parse_iso8601_opt timestamp with
      | Some value -> Ok value
      | None -> invalid "timestamp" "must be a valid ISO-8601 value"
    in
    let* source = source_of_fields fields in
    let* usage_projection = usage_projection_of_fields fields source in
    let* usage = usage_of_fields fields source in
    Ok { agent; task_id; model; usage; usage_projection; timestamp; ts_unix; source }
  | _ -> invalid "cost row" "must be a JSON object"
;;

let reserved_fields =
  [ "agent"
  ; "task_id"
  ; "model"
  ; "input_tokens"
  ; "output_tokens"
  ; "cost_usd"
  ; "usage_missing"
  ; "usage_projection"
  ; "timestamp"
  ; "ts_unix"
  ; "source"
  ; "trace_id"
  ; "keeper_turn_id"
  ; "agent_core_turn_ordinal"
  ]
;;

let to_json ?(extra_fields = []) row =
  let input_tokens, output_tokens, cost_usd, usage_missing =
    match row.usage with
    | Usage_missing -> `Null, `Null, `Null, true
    | Usage_reported { input_tokens; output_tokens; cost_usd } ->
      `Int input_tokens, `Int output_tokens, `Float cost_usd, false
  in
  let trace_id, keeper_turn_id, agent_core_turn_ordinal =
    match row.source with
    | Manual_cli -> `Null, `Null, `Null
    | Auto_trajectory identity ->
      ( `String identity.trace_id
      , `Int identity.keeper_turn_id
      , `Int identity.agent_core_turn_ordinal )
  in
  let extra_fields =
    List.filter
      (fun (key, _) -> not (List.mem key reserved_fields))
      extra_fields
  in
  `Assoc
    ([ "agent", `String row.agent
     ; "task_id", Json_util.string_opt_to_json row.task_id
     ; "model", `String row.model
     ; "input_tokens", input_tokens
     ; "output_tokens", output_tokens
     ; "cost_usd", cost_usd
     ; "usage_missing", `Bool usage_missing
     ; "usage_projection", `String (usage_projection_to_string row.usage_projection)
     ; "timestamp", `String row.timestamp
     ; "source", `String (source_to_string row.source)
     ; "trace_id", trace_id
     ; "keeper_turn_id", keeper_turn_id
     ; "agent_core_turn_ordinal", agent_core_turn_ordinal
     ]
     @ extra_fields)
;;

let directory_name = "costs"
let dir_of_masc_root masc_root = Filename.concat masc_root directory_name

let dir_of_base_path ~base_path =
  dir_of_masc_root (Common.masc_dir_from_base_path ~base_path)
;;

let store_of_masc_root masc_root =
  Dated_jsonl.create ~base_dir:(dir_of_masc_root masc_root) ()
;;

let store_of_base_path ~base_path =
  Dated_jsonl.create ~base_dir:(dir_of_base_path ~base_path) ()
;;
