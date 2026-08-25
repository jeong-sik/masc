type envelope =
  | Openai_chat_max_tokens
  | Openai_responses_max_output_tokens
  | Anthropic_messages_max_tokens
  | Gemini_generation_config_max_output_tokens
  | Ollama_options_num_predict
[@@deriving show, eq]

type policy =
  | Omitted
  | Explicit
  | Explicit_clamped
  | Required_catalog_fallback
  | Required_capability_override_fallback
[@@deriving show, eq]

type ceiling_source =
  | Catalog_model
  | Declared_capability_override
  | Provider_default
[@@deriving show, eq]

let envelope_wire_name = function
  | Openai_chat_max_tokens -> "openai_chat_max_tokens"
  | Openai_responses_max_output_tokens -> "openai_responses_max_output_tokens"
  | Anthropic_messages_max_tokens -> "anthropic_messages_max_tokens"
  | Gemini_generation_config_max_output_tokens ->
    "gemini_generation_config_max_output_tokens"
  | Ollama_options_num_predict -> "ollama_options_num_predict"
;;

let envelope_to_yojson envelope = `String (envelope_wire_name envelope)

let envelope_of_yojson = function
  | `String value when String.equal value (envelope_wire_name Openai_chat_max_tokens) ->
    Ok Openai_chat_max_tokens
  | `String value
    when String.equal value (envelope_wire_name Openai_responses_max_output_tokens) ->
    Ok Openai_responses_max_output_tokens
  | `String value
    when String.equal value (envelope_wire_name Anthropic_messages_max_tokens) ->
    Ok Anthropic_messages_max_tokens
  | `String value
    when String.equal
           value
           (envelope_wire_name Gemini_generation_config_max_output_tokens) ->
    Ok Gemini_generation_config_max_output_tokens
  | `String value when String.equal value (envelope_wire_name Ollama_options_num_predict)
    -> Ok Ollama_options_num_predict
  | `String value -> Error (Printf.sprintf "unknown output-token envelope: %S" value)
  | _ -> Error "output-token envelope must be a string"
;;

let policy_wire_name = function
  | Omitted -> "omitted"
  | Explicit -> "explicit"
  | Explicit_clamped -> "explicit_clamped"
  | Required_catalog_fallback -> "required_catalog_fallback"
  | Required_capability_override_fallback -> "required_capability_override_fallback"
;;

let policy_to_yojson policy = `String (policy_wire_name policy)

let policy_of_yojson = function
  | `String value when String.equal value (policy_wire_name Omitted) -> Ok Omitted
  | `String value when String.equal value (policy_wire_name Explicit) -> Ok Explicit
  | `String value when String.equal value (policy_wire_name Explicit_clamped) ->
    Ok Explicit_clamped
  | `String value when String.equal value (policy_wire_name Required_catalog_fallback) ->
    Ok Required_catalog_fallback
  | `String value
    when String.equal value (policy_wire_name Required_capability_override_fallback) ->
    Ok Required_capability_override_fallback
  | `String value -> Error (Printf.sprintf "unknown output-token policy: %S" value)
  | _ -> Error "output-token policy must be a string"
;;

let ceiling_source_wire_name = function
  | Catalog_model -> "catalog_model"
  | Declared_capability_override -> "declared_capability_override"
  | Provider_default -> "provider_default"
;;

let ceiling_source_to_yojson source = `String (ceiling_source_wire_name source)

let ceiling_source_of_yojson = function
  | `String value when String.equal value (ceiling_source_wire_name Catalog_model) ->
    Ok Catalog_model
  | `String value
    when String.equal value (ceiling_source_wire_name Declared_capability_override) ->
    Ok Declared_capability_override
  | `String value when String.equal value (ceiling_source_wire_name Provider_default) ->
    Ok Provider_default
  | `String value ->
    Error (Printf.sprintf "unknown output-token ceiling source: %S" value)
  | _ -> Error "output-token ceiling source must be a string"
;;

type ceiling =
  { value : int
  ; source : ceiling_source
  }
[@@deriving show, eq]

let ceiling ~value ~source =
  if value <= 0
  then invalid_arg "output_token_ceiling: value must be positive"
  else { value; source }
;;

type required_fallback_source =
  | Required_catalog_source
  | Required_capability_override_source
[@@deriving show, eq]

type resolution =
  | Omitted_resolution of { ceiling : ceiling option }
  | Explicit_resolution of
      { value : int
      ; ceiling : ceiling option
      }
  | Explicit_clamped_resolution of
      { requested : int
      ; ceiling : ceiling
      }
  | Required_fallback_resolution of
      { ceiling : ceiling
      ; source : required_fallback_source
      }
[@@deriving show, eq]

type receipt =
  { envelope : envelope
  ; resolution : resolution
  }
[@@deriving show, eq]

type required_error = Required_output_token_ceiling_missing [@@deriving show, eq]

let receipt_envelope receipt = receipt.envelope

let receipt_requested receipt =
  match receipt.resolution with
  | Omitted_resolution _ | Required_fallback_resolution _ -> None
  | Explicit_resolution { value; _ } -> Some value
  | Explicit_clamped_resolution { requested; _ } -> Some requested
;;

let receipt_effective receipt =
  match receipt.resolution with
  | Omitted_resolution _ -> None
  | Explicit_resolution { value; _ } -> Some value
  | Explicit_clamped_resolution { ceiling; _ } | Required_fallback_resolution { ceiling }
    -> Some ceiling.value
;;

let receipt_policy receipt =
  match receipt.resolution with
  | Omitted_resolution _ -> Omitted
  | Explicit_resolution _ -> Explicit
  | Explicit_clamped_resolution _ -> Explicit_clamped
  | Required_fallback_resolution { source = Required_catalog_source; _ } ->
    Required_catalog_fallback
  | Required_fallback_resolution { source = Required_capability_override_source; _ } ->
    Required_capability_override_fallback
;;

let receipt_ceiling_value receipt =
  match receipt.resolution with
  | Omitted_resolution { ceiling } | Explicit_resolution { ceiling; _ } -> ceiling
  | Explicit_clamped_resolution { ceiling; _ } | Required_fallback_resolution { ceiling }
    -> Some ceiling
;;

let receipt_ceiling receipt =
  Option.map (fun ceiling -> ceiling.value) (receipt_ceiling_value receipt)
;;

let receipt_ceiling_source receipt =
  Option.map (fun ceiling -> ceiling.source) (receipt_ceiling_value receipt)
;;

let optional_receipt ~envelope ~requested ~ceiling =
  (match requested with
   | Some value when value < 0 ->
     invalid_arg "optional_output_token_receipt: requested value must be non-negative"
   | None | Some _ -> ());
  let resolution =
    match requested, ceiling with
    | None, ceiling -> Omitted_resolution { ceiling }
    | Some requested, Some ceiling when requested > ceiling.value ->
      Explicit_clamped_resolution { requested; ceiling }
    | Some value, ceiling -> Explicit_resolution { value; ceiling }
  in
  { envelope; resolution }
;;

let required_receipt receipt =
  match receipt.resolution with
  | Omitted_resolution { ceiling = Some ({ source = Catalog_model; _ } as ceiling) } ->
    Ok
      { receipt with
        resolution =
          Required_fallback_resolution { ceiling; source = Required_catalog_source }
      }
  | Omitted_resolution
      { ceiling = Some ({ source = Declared_capability_override; _ } as ceiling) } ->
    Ok
      { receipt with
        resolution =
          Required_fallback_resolution
            { ceiling; source = Required_capability_override_source }
      }
  | Omitted_resolution { ceiling = None | Some { source = Provider_default; _ } } ->
    Error Required_output_token_ceiling_missing
  | Explicit_resolution _ | Explicit_clamped_resolution _ | Required_fallback_resolution _
    -> Ok receipt
;;

let receipt_to_yojson receipt =
  let option_int_to_yojson = function
    | Some value -> `Int value
    | None -> `Null
  in
  `Assoc
    [ "requested", option_int_to_yojson (receipt_requested receipt)
    ; "effective", option_int_to_yojson (receipt_effective receipt)
    ; "policy", policy_to_yojson (receipt_policy receipt)
    ; "ceiling", option_int_to_yojson (receipt_ceiling receipt)
    ; ( "ceiling_source"
      , match receipt_ceiling_source receipt with
        | Some source -> ceiling_source_to_yojson source
        | None -> `Null )
    ; "envelope", envelope_to_yojson receipt.envelope
    ]
;;

let receipt_of_yojson json =
  let open Yojson.Safe.Util in
  let token_value_option = function
    | `Null -> Ok None
    | `Int value when value >= 0 -> Ok (Some value)
    | `Int _ -> Error "output_token_receipt: token values must be non-negative"
    | _ -> Error "output_token_receipt: expected integer or null"
  in
  let ceiling_option = function
    | `Null -> Ok None
    | `Int value when value > 0 -> Ok (Some value)
    | `Int _ -> Error "output_token_receipt: ceiling must be positive"
    | _ -> Error "output_token_receipt: expected integer or null"
  in
  let ( let* ) result f = Result.bind result f in
  try
    let* requested = token_value_option (member "requested" json) in
    let* effective = token_value_option (member "effective" json) in
    let* ceiling_value = ceiling_option (member "ceiling" json) in
    let* ceiling_source =
      match member "ceiling_source" json with
      | `Null -> Ok None
      | source_json ->
        Result.map (fun source -> Some source) (ceiling_source_of_yojson source_json)
    in
    let* ceiling =
      match ceiling_value, ceiling_source with
      | None, None -> Ok None
      | Some value, Some source -> Ok (Some (ceiling ~value ~source))
      | Some _, None | None, Some _ ->
        Error "output_token_receipt: ceiling and ceiling_source must appear together"
    in
    let* policy = policy_of_yojson (member "policy" json) in
    let* envelope = envelope_of_yojson (member "envelope" json) in
    match policy, requested, effective, ceiling with
    | Omitted, None, None, ceiling ->
      Ok { envelope; resolution = Omitted_resolution { ceiling } }
    | Explicit, Some requested, Some effective, ceiling
      when requested = effective
           &&
           match ceiling with
           | Some cap -> effective <= cap.value
           | None -> true ->
      Ok { envelope; resolution = Explicit_resolution { value = effective; ceiling } }
    | Explicit_clamped, Some requested, Some effective, Some ceiling
      when effective = ceiling.value && requested > ceiling.value ->
      Ok { envelope; resolution = Explicit_clamped_resolution { requested; ceiling } }
    | Required_catalog_fallback, None, Some effective, Some ceiling
      when ceiling.source = Catalog_model && effective = ceiling.value ->
      Ok
        { envelope
        ; resolution =
            Required_fallback_resolution { ceiling; source = Required_catalog_source }
        }
    | Required_capability_override_fallback, None, Some effective, Some ceiling
      when ceiling.source = Declared_capability_override && effective = ceiling.value ->
      Ok
        { envelope
        ; resolution =
            Required_fallback_resolution
              { ceiling; source = Required_capability_override_source }
        }
    | _ -> Error "output_token_receipt: inconsistent requested/effective policy fields"
  with
  | Yojson.Safe.Util.Type_error (message, _) -> Error message
;;
