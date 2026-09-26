type inference_identity =
  { trace_id : string
  ; keeper_turn_id : int
  ; agent_core_turn_ordinal : int
  }

type source =
  | Manual_cli
  | Auto_trajectory of inference_identity

type attempt_reading =
  { lane_attempt_index : int
  ; reading_index : int
  }

type usage_projection =
  | Raw_observation of Runtime_usage_scope.t
  | Resolved_delta
  | Resolved_attempt_delta of attempt_reading

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
  | Raw_observation _ -> "raw_observation"
  | Resolved_delta -> "resolved_delta"
  | Resolved_attempt_delta _ -> "resolved_attempt_delta"
;;

let lane_attempt_index_field = "lane_attempt_index"
let reading_index_field = "reading_index"

let usage_scope_field = "usage_scope"

(* A raw row carries the scope of its counts; without it the counts cannot
   be read, so a row that lacks it, or names a scope this build does not
   know, is a decode error. *)
let raw_observation_scope_of_fields fields =
  match List.assoc_opt usage_scope_field fields with
  | None -> invalid usage_scope_field "is required on a raw_observation row"
  | Some (`String wire) ->
    (match Runtime_usage_scope.of_string wire with
     | Some scope -> Ok scope
     | None -> invalid usage_scope_field "must name a runtime usage scope")
  | Some _ -> invalid usage_scope_field "must be a string"
;;

let required_index fields key =
  match List.assoc_opt key fields with
  | Some (`Int value) when value >= 0 -> Ok value
  | _ -> invalid key "must be a non-negative integer"
;;

let usage_projection_of_fields fields source =
  let* projection = required_string fields "usage_projection" in
  let resolved_scope_null projection =
    match List.assoc_opt usage_scope_field fields with
    | None | Some `Null -> Ok ()
    | Some _ -> invalid usage_scope_field ("must be null for " ^ projection)
  in
  match projection with
  | "resolved_delta" ->
    let* () = resolved_scope_null projection in
    Ok Resolved_delta
  | "resolved_attempt_delta" ->
    (match source with
     | Auto_trajectory _ ->
       let* () = resolved_scope_null projection in
       let* lane_attempt_index = required_index fields lane_attempt_index_field in
       let* reading_index = required_index fields reading_index_field in
       Ok (Resolved_attempt_delta { lane_attempt_index; reading_index })
     | Manual_cli ->
       invalid "usage_projection" "must be resolved_delta for manual_cli")
  | "raw_observation" ->
    (match source with
     | Auto_trajectory _ ->
       let* scope = raw_observation_scope_of_fields fields in
       Ok (Raw_observation scope)
     | Manual_cli ->
       invalid "usage_projection" "must be resolved_delta for manual_cli")
  | _ ->
    invalid
      "usage_projection"
      "must be raw_observation, resolved_delta or resolved_attempt_delta"
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

type inference_key =
  | Turn_inference of inference_identity
  | Attempt_inference of
      { turn : inference_identity
      ; attempt : attempt_reading
      }

let compare_attempt_reading left right =
  let by_lane = Int.compare left.lane_attempt_index right.lane_attempt_index in
  if by_lane <> 0 then by_lane else Int.compare left.reading_index right.reading_index
;;

let compare_inference_key left right =
  match left, right with
  | Turn_inference left, Turn_inference right -> compare_inference_identity left right
  | Turn_inference _, Attempt_inference _ -> -1
  | Attempt_inference _, Turn_inference _ -> 1
  | Attempt_inference left, Attempt_inference right ->
    let by_turn = compare_inference_identity left.turn right.turn in
    if by_turn <> 0 then by_turn else compare_attempt_reading left.attempt right.attempt
;;

let inference_key row =
  match row.source, row.usage_projection with
  | Manual_cli, (Raw_observation _ | Resolved_delta | Resolved_attempt_delta _) -> None
  | Auto_trajectory turn, (Raw_observation _ | Resolved_delta) -> Some (Turn_inference turn)
  | Auto_trajectory turn, Resolved_attempt_delta attempt ->
    Some (Attempt_inference { turn; attempt })
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
  ; "usage_scope"
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
  (* An attempt row's reading is part of its identity, so the row writes it
     and a caller's field of the same name cannot replace it. *)
  let attempt_fields =
    match row.usage_projection with
    | Resolved_attempt_delta attempt ->
      [ lane_attempt_index_field, `Int attempt.lane_attempt_index
      ; reading_index_field, `Int attempt.reading_index
      ]
    | Raw_observation _ | Resolved_delta -> []
  in
  let extra_fields =
    List.filter
      (fun (key, _) ->
         not (List.mem key reserved_fields || List.mem_assoc key attempt_fields))
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
     ; ( usage_scope_field
       , match row.usage_projection with
         | Raw_observation scope -> `String (Runtime_usage_scope.to_string scope)
         | Resolved_delta | Resolved_attempt_delta _ -> `Null )
     ; "timestamp", `String row.timestamp
     ; "source", `String (source_to_string row.source)
     ; "trace_id", trace_id
     ; "keeper_turn_id", keeper_turn_id
     ; "agent_core_turn_ordinal", agent_core_turn_ordinal
     ]
     @ attempt_fields
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
