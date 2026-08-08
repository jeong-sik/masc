(** Shared vocabulary for declarative capability fields.

    This module intentionally has no dependency on {!Capabilities},
    {!Capability_manifest}, or {!Model_catalog}.  Those modules all parse the
    same operator-facing strings, so the canonical wire vocabulary must live in
    a leaf module to avoid duplicate enum tables and dependency cycles. *)

type thinking_control_format =
  | No_thinking_control
  | Thinking_object
  | Thinking_object_adaptive
  | Thinking_object_only
  | Chat_template_kwargs
  | Chat_template_token of string
  (** Thinking is toggled by emitting a chat-template token (e.g. [<|think|>])
          in the system turn. The token is catalog/manifest data carried inside
          the constructor: a [chat_template_token] wire format cannot exist
          without its token, so a tokenless declaration fails closed at load
          instead of raising per request. *)
  | Ollama_think
  | Reasoning_effort
  | Enable_thinking

type preserve_thinking_control_format =
  | No_preserve_thinking_control
  | Thinking_object_keep_all
  | Chat_template_kwargs_preserve_thinking
  | Top_level_preserve_thinking
  | Always_preserved_thinking
  | Thinking_object_clear_thinking
  (** A provider [thinking] request object whose [clear_thinking] member both
          carries the toggle and gates prior-turn reasoning replay: the server
          only echoes prior reasoning back under "preserved thinking", i.e.
          thinking active AND [clear_thinking = false]. Declaring this wire is
          what makes replay conditional; no consumer re-derives the condition
          from a provider identity. *)

type reasoning_replay_override =
  | Default_reasoning_replay
  | Force_no_replay
  | Force_drop_without_tool_preserve_with_tool
  | Force_latest_user_turn_tool_calls
  | Force_preserve_always

type assistant_tool_content_format =
  | Assistant_tool_content_null
  | Assistant_tool_content_empty_string

type reasoning_output_format =
  | No_reasoning_output_format
  | Split_reasoning_fields

(** Structured-output tier a resolved model/provider capability advertises.

    This is the typed view the request-admission decision
    ({!Provider_config.validate_output_schema_request}) reads instead of
    branching on provider identity. It has no wire vocabulary of its own and is
    never parsed from a catalog/manifest string: it is projected from the two
    independent, already-threaded capability booleans
    [supports_structured_output] and [supports_response_format_json]
    ({!Capabilities.structured_output_support}). Keeping the tier as a closed sum
    lets the decision match all three cases exhaustively, so a new tier forces a
    compile error rather than a silent identity branch.

    - [Native_json_schema]: the provider exposes a native schema-constrained
      request field; the schema is enforced provider-side.
    - [Json_object_only]: the provider accepts JSON mode
      ([response_format = json_object]) but documents no native json_schema
      field, so a caller-supplied output schema cannot be honored on the wire.
    - [No_structured_output]: neither JSON mode nor native schema output. *)
type structured_output_support =
  | No_structured_output
  | Json_object_only
  | Native_json_schema

let structured_output_support_to_string = function
  | No_structured_output -> "none"
  | Json_object_only -> "json_object_only"
  | Native_json_schema -> "native_json_schema"
;;

type reasoning_streaming_format =
  | Default_reasoning_streaming
  | No_reasoning_streaming
  | Delta_reasoning_field of string
  | Template_reasoning_streaming

type sampling_parameter =
  | Temperature
  | Top_p
  | Top_k
  | Min_p
  | Presence_penalty
  | Frequency_penalty
  | Seed

(** Inference task a catalog entry declares for non-chat models (audio
    transcription, speech synthesis, image/video generation). Chat and
    completion models declare no task. *)
type task =
  | Transcription
  | Speech
  | Image_generation
  | Video_generation

let normalize raw = String.lowercase_ascii (String.trim raw)

(** Anthropic Messages API thinking-control policy.  This is model catalog
    data, not a model-id classifier: an entry must declare which request
    shape it accepts before a thinking-enabled request is built. *)
type anthropic_thinking_control =
  | Manual_budget
  | Adaptive_default
  | Adaptive_preferred
  | Adaptive_only
  | Always_adaptive

let anthropic_thinking_control_table =
  [ "manual_budget", Manual_budget
  ; "adaptive_default", Adaptive_default
  ; "adaptive_preferred", Adaptive_preferred
  ; "adaptive_only", Adaptive_only
  ; "always_adaptive", Always_adaptive
  ]
;;

let anthropic_thinking_control_values = List.map fst anthropic_thinking_control_table

let anthropic_thinking_control_of_string raw =
  List.assoc_opt (normalize raw) anthropic_thinking_control_table
;;

(** The one canonical label projection for thinking-control formats. This match
    is deliberately exhaustive: the encoder, exact decoder lookup, and
    advertised vocabulary below derive their labels from it. *)
let canonical_label_of_thinking_control_format = function
  | No_thinking_control -> "none"
  | Thinking_object -> "thinking_object"
  | Thinking_object_adaptive -> "thinking_object_adaptive"
  | Thinking_object_only -> "thinking_object_only"
  | Chat_template_kwargs -> "chat_template_kwargs"
  | Chat_template_token _ -> "chat_template_token"
  | Ollama_think -> "ollama_think"
  | Reasoning_effort -> "reasoning_effort"
  | Enable_thinking -> "enable_thinking"
;;

(* These formats carry no companion token and can therefore serve directly as
   exact decoder results. Their labels are always obtained from the exhaustive
   canonical projection above; this list contains no second wire vocabulary. *)
let tokenless_thinking_control_formats =
  [ No_thinking_control
  ; Thinking_object
  ; Thinking_object_adaptive
  ; Thinking_object_only
  ; Chat_template_kwargs
  ; Ollama_think
  ; Reasoning_effort
  ; Enable_thinking
  ]
;;

let chat_template_token_label =
  canonical_label_of_thinking_control_format (Chat_template_token "")
;;

let thinking_control_format_values =
  List.map canonical_label_of_thinking_control_format tokenless_thinking_control_formats
  @ [ chat_template_token_label ]
;;

type thinking_control_format_fields =
  { label : string
  ; token : string option
  }

type thinking_control_token_invalidity =
  | Empty_token
  | Leading_or_trailing_whitespace

type thinking_control_format_codec_error =
  | Unknown_label of string
  | Token_required
  | Token_forbidden
  | Invalid_token of
      { token : string
      ; invalidity : thinking_control_token_invalidity
      }

(* The chat-template thinking token carried by [Chat_template_token], or [None]
   for every other wire format. Exhaustive so adding a format requires an
   explicit token-policy decision. *)
let token_of_thinking_control_format = function
  | Chat_template_token token -> Some token
  | No_thinking_control
  | Thinking_object
  | Thinking_object_adaptive
  | Thinking_object_only
  | Chat_template_kwargs
  | Ollama_think
  | Reasoning_effort
  | Enable_thinking -> None
;;

let validate_thinking_control_token token =
  let trimmed = String.trim token in
  if String.equal trimmed ""
  then Error (Invalid_token { token; invalidity = Empty_token })
  else if not (String.equal token trimmed)
  then Error (Invalid_token { token; invalidity = Leading_or_trailing_whitespace })
  else Ok token
;;

let validate_optional_thinking_control_token = function
  | None -> Ok None
  | Some token -> Result.map Option.some (validate_thinking_control_token token)
;;

(** The canonical, lossless operator representation of a thinking-control
    format. Both fields derive from exhaustive projections rather than carrying
    their own wire-label table. The public constructor can carry any string, so
    encoding validates its token and returns a typed error instead of emitting
    an invalid declaration. *)
let encode_thinking_control_format format
  : (thinking_control_format_fields, thinking_control_format_codec_error) result
  =
  Result.map
    (fun token -> { label = canonical_label_of_thinking_control_format format; token })
    (validate_optional_thinking_control_token (token_of_thinking_control_format format))
;;

(** Decode only exact canonical labels. No trimming, case folding, aliasing, or
    default selection occurs here. [thinking_control_token] is part of the same
    declaration: it is required by [chat_template_token], forbidden elsewhere,
    and retained byte-for-byte when valid. *)
let decode_thinking_control_format ({ label; token } : thinking_control_format_fields)
  : (thinking_control_format, thinking_control_format_codec_error) result
  =
  Result.bind (validate_optional_thinking_control_token token) (fun token ->
    if String.equal label chat_template_token_label
    then (
      match token with
      | None -> Error Token_required
      | Some token -> Ok (Chat_template_token token))
    else (
      match
        List.find_opt
          (fun format ->
             String.equal label (canonical_label_of_thinking_control_format format))
          tokenless_thinking_control_formats
      with
      | None -> Error (Unknown_label label)
      | Some _ when Option.is_some token -> Error Token_forbidden
      | Some format -> Ok format))
;;

(** Optional catalog/manifest declaration wrapper. Absence is preserved as
    absence; it never selects [No_thinking_control]. An orphan token is rejected
    by the same typed error as a token attached to a tokenless format. *)
let decode_optional_thinking_control_format ~label ~token
  : (thinking_control_format option, thinking_control_format_codec_error) result
  =
  match label with
  | None ->
    Result.bind (validate_optional_thinking_control_token token) (function
      | None -> Ok None
      | Some _ -> Error Token_forbidden)
  | Some label -> Result.map Option.some (decode_thinking_control_format { label; token })
;;

let thinking_control_format_codec_error_to_string = function
  | Unknown_label label ->
    Printf.sprintf
      "unknown thinking_control_format %S (canonical: %s)"
      label
      (String.concat ", " thinking_control_format_values)
  | Token_required ->
    Printf.sprintf
      "thinking_control_format %S requires a non-empty thinking_control_token"
      chat_template_token_label
  | Token_forbidden ->
    Printf.sprintf
      "thinking_control_token is only valid with thinking_control_format = %S"
      chat_template_token_label
  | Invalid_token { invalidity = Empty_token; _ } ->
    "thinking_control_token must not be empty"
  | Invalid_token { invalidity = Leading_or_trailing_whitespace; _ } ->
    "thinking_control_token must not have leading or trailing whitespace"
;;

let preserve_thinking_control_format_table =
  [ "none", No_preserve_thinking_control
  ; "thinking_object_keep_all", Thinking_object_keep_all
  ; "chat_template_kwargs_preserve_thinking", Chat_template_kwargs_preserve_thinking
  ; "top_level_preserve_thinking", Top_level_preserve_thinking
  ; "always_preserved", Always_preserved_thinking
  ; "thinking_object_clear_thinking", Thinking_object_clear_thinking
  ]
;;

(* [true] when the preserve wire is a provider [thinking] request object that
   carries the thinking toggle itself. Such a row encodes an explicit
   enable/disable on the wire even when its [thinking_control_format] is
   [No_thinking_control], so admission must not report the request as
   unencodable. Exhaustive: a new preserve wire has to state its answer. *)
let preserve_wire_owns_thinking_object = function
  | Thinking_object_clear_thinking -> true
  | No_preserve_thinking_control
  | Thinking_object_keep_all
  | Chat_template_kwargs_preserve_thinking
  | Top_level_preserve_thinking
  | Always_preserved_thinking -> false
;;

let preserve_thinking_control_format_values =
  List.map fst preserve_thinking_control_format_table
;;

let preserve_thinking_control_format_of_string raw =
  match normalize raw with
  | "" -> None
  | normalized -> List.assoc_opt normalized preserve_thinking_control_format_table
;;

let%test "thinking_control_format exact codec round-trips every format" =
  List.for_all
    (fun format ->
       match encode_thinking_control_format format with
       | Error _ -> false
       | Ok encoded ->
         (match decode_thinking_control_format encoded with
          | Ok decoded -> decoded = format
          | Error _ -> false))
    (Chat_template_token "<|think|>" :: tokenless_thinking_control_formats)
;;

let%test "thinking_control_format encoder preserves the exact template token" =
  encode_thinking_control_format (Chat_template_token "<|exact token|>")
  = Ok { label = chat_template_token_label; token = Some "<|exact token|>" }
;;

let%test "thinking_control_format encoder rejects an empty public token" =
  match encode_thinking_control_format (Chat_template_token "") with
  | Error (Invalid_token { token = ""; invalidity = Empty_token }) -> true
  | Ok _ | Error _ -> false
;;

let%test "thinking_control_format encoder rejects a whitespace-only public token" =
  match encode_thinking_control_format (Chat_template_token " \t ") with
  | Error (Invalid_token { token = " \t "; invalidity = Empty_token }) -> true
  | Ok _ | Error _ -> false
;;

let%test "thinking_control_format encoder rejects a padded public token" =
  match encode_thinking_control_format (Chat_template_token " <|think|> ") with
  | Error
      (Invalid_token
         { token = " <|think|> "; invalidity = Leading_or_trailing_whitespace }) -> true
  | Ok _ | Error _ -> false
;;

let%test "thinking_control_format canonical labels are unique" =
  List.length (List.sort_uniq String.compare thinking_control_format_values)
  = List.length thinking_control_format_values
;;

let%test "thinking_control_format decoder rejects noncanonical labels exactly" =
  List.for_all
    (fun label ->
       match decode_thinking_control_format { label; token = None } with
       | Error (Unknown_label rejected) -> String.equal rejected label
       | Ok _ | Error _ -> false)
    [ " thinking_object"
    ; "thinking_object "
    ; "Thinking_object"
    ; "thinking-object"
    ; "no_thinking_control"
    ; ""
    ]
;;

let%test "chat_template_token requires a token" =
  decode_thinking_control_format { label = chat_template_token_label; token = None }
  = Error Token_required
;;

let%test "tokenless thinking_control_format forbids a token" =
  decode_thinking_control_format
    { label = canonical_label_of_thinking_control_format Thinking_object
    ; token = Some "<|think|>"
    }
  = Error Token_forbidden
;;

let%test "chat_template_token rejects an empty token" =
  match
    decode_thinking_control_format { label = chat_template_token_label; token = Some "" }
  with
  | Error (Invalid_token { invalidity = Empty_token; _ }) -> true
  | Ok _ | Error _ -> false
;;

let%test "chat_template_token rejects a whitespace-only token as empty" =
  match
    decode_thinking_control_format
      { label = chat_template_token_label; token = Some " \t " }
  with
  | Error (Invalid_token { token = " \t "; invalidity = Empty_token }) -> true
  | Ok _ | Error _ -> false
;;

let%test "chat_template_token rejects a padded token without normalizing it" =
  match
    decode_thinking_control_format
      { label = chat_template_token_label; token = Some " <|think|> " }
  with
  | Error
      (Invalid_token
         { token = " <|think|> "; invalidity = Leading_or_trailing_whitespace }) -> true
  | Ok _ | Error _ -> false
;;

let%test "optional thinking_control_format preserves absence without a default" =
  decode_optional_thinking_control_format ~label:None ~token:None = Ok None
;;

let%test "optional thinking_control_format rejects an orphan token" =
  decode_optional_thinking_control_format ~label:None ~token:(Some "<|think|>")
  = Error Token_forbidden
;;

let%test "preserve_thinking_control_format values parse through the canonical table" =
  List.for_all
    (fun raw -> Option.is_some (preserve_thinking_control_format_of_string raw))
    preserve_thinking_control_format_values
;;

let modality_priority_values =
  [ "preserve_input_order"
  ; "preserve-input-order"
  ; "preserve"
  ; "visual_first"
  ; "visual-first"
  ]
;;

let capability_fields =
  [ "max_context_tokens"
  ; "max_output_tokens"
  ; "supports_tools"
  ; "supports_tool_choice"
  ; "supports_required_tool_choice"
  ; "supports_named_tool_choice"
  ; "supports_parallel_tool_calls"
  ; "assistant_tool_content_format"
  ; "supports_reasoning"
  ; "supports_extended_thinking"
  ; "supports_reasoning_budget"
  ; "accepted_reasoning_efforts"
  ; "thinking_control_format"
  ; "thinking_control_token"
  ; "preserve_thinking_control_format"
  ; "reasoning_output_format"
  ; "reasoning_streaming_format"
  ; "reasoning_replay"
  ; "supports_response_format_json"
  ; "supports_structured_output"
  ; "supports_multimodal_inputs"
  ; "supports_image_input"
  ; "supports_audio_input"
  ; "supports_video_input"
  ; "supports_document_input"
  ; "modality_priority"
  ; "supports_native_streaming"
  ; "supports_system_prompt"
  ; "supports_caching"
  ; "supports_prompt_caching"
  ; "prompt_cache_alignment"
  ; "supports_top_k"
  ; "supports_min_p"
  ; "supports_seed"
  ; "supports_seed_with_images"
  ; "ignored_sampling_parameters"
  ; "supports_computer_use"
  ; "supports_code_execution"
  ; "emits_usage_tokens"
  ; "supported_models"
  ; "supports_runtime_mcp_tools"
  ; "supports_runtime_tool_events"
  ]
;;

let task_table =
  [ "transcription", Transcription
  ; "speech", Speech
  ; "image_generation", Image_generation
  ; "video_generation", Video_generation
  ]
;;

let task_values = List.map fst task_table

let task_of_string raw =
  match normalize raw with
  | "" -> None
  | normalized -> List.assoc_opt normalized task_table
;;

let task_to_string = function
  | Transcription -> "transcription"
  | Speech -> "speech"
  | Image_generation -> "image_generation"
  | Video_generation -> "video_generation"
;;

let%test "task values parse through the canonical table" =
  List.for_all (fun raw -> Option.is_some (task_of_string raw)) task_values
;;

let%test "task round-trips through to_string and of_string" =
  List.for_all
    (fun (raw, task) ->
       task_to_string task = raw && task_of_string (task_to_string task) = Some task)
    task_table
;;

let reasoning_replay_table =
  [ "default", Default_reasoning_replay
  ; "no_replay", Force_no_replay
  ; "drop_without_tool", Force_drop_without_tool_preserve_with_tool
  ; "drop_without_tool_preserve_with_tool", Force_drop_without_tool_preserve_with_tool
  ; "latest_user_turn_tool_calls", Force_latest_user_turn_tool_calls
  ; "preserve_always", Force_preserve_always
  ]
;;

let reasoning_replay_values = List.map fst reasoning_replay_table

let reasoning_replay_override_of_string raw =
  match normalize raw with
  | "" -> Some Default_reasoning_replay
  | normalized -> List.assoc_opt normalized reasoning_replay_table
;;

let assistant_tool_content_format_table =
  [ "null", Assistant_tool_content_null
  ; "empty_string", Assistant_tool_content_empty_string
  ]
;;

let assistant_tool_content_format_values =
  List.map fst assistant_tool_content_format_table
;;

let assistant_tool_content_format_of_string raw =
  match normalize raw with
  | "" -> Some Assistant_tool_content_null
  | normalized -> List.assoc_opt normalized assistant_tool_content_format_table
;;

let reasoning_output_format_table =
  [ "none", No_reasoning_output_format; "split_reasoning_fields", Split_reasoning_fields ]
;;

let reasoning_output_format_values = List.map fst reasoning_output_format_table

let reasoning_output_format_of_string raw =
  match normalize raw with
  | "" -> Some No_reasoning_output_format
  | normalized -> List.assoc_opt normalized reasoning_output_format_table
;;

let reasoning_streaming_format_values =
  [ "default"; "none"; "template_parser"; "delta:<field>" ]
;;

let reasoning_streaming_format_syntax =
  String.concat ", " reasoning_streaming_format_values
;;

let reasoning_streaming_delta_prefix = "delta:"

let reasoning_streaming_format_of_string raw =
  match normalize raw with
  | "" | "default" -> Some Default_reasoning_streaming
  | "none" -> Some No_reasoning_streaming
  | "template_parser" -> Some Template_reasoning_streaming
  | normalized when String.starts_with ~prefix:reasoning_streaming_delta_prefix normalized
    ->
    let prefix_len = String.length reasoning_streaming_delta_prefix in
    let field =
      String.sub normalized prefix_len (String.length normalized - prefix_len)
    in
    if field = "" || String.contains field ' '
    then None
    else Some (Delta_reasoning_field field)
  | _ -> None
;;

let sampling_parameter_table =
  [ "temperature", Temperature
  ; "top_p", Top_p
  ; "top_k", Top_k
  ; "min_p", Min_p
  ; "presence_penalty", Presence_penalty
  ; "frequency_penalty", Frequency_penalty
  ; "seed", Seed
  ]
;;

let sampling_parameter_values = List.map fst sampling_parameter_table

let sampling_parameter_of_string raw =
  match normalize raw with
  | "" -> None
  | normalized -> List.assoc_opt normalized sampling_parameter_table
;;

let sampling_parameter_to_string = function
  | Temperature -> "temperature"
  | Top_p -> "top_p"
  | Top_k -> "top_k"
  | Min_p -> "min_p"
  | Presence_penalty -> "presence_penalty"
  | Frequency_penalty -> "frequency_penalty"
  | Seed -> "seed"
;;

let%test "sampling_parameter values parse through the canonical table" =
  List.for_all
    (fun raw -> Option.is_some (sampling_parameter_of_string raw))
    sampling_parameter_values
;;

let%test "sampling_parameter round-trips through to_string and of_string" =
  List.for_all
    (fun (_raw, parameter) ->
       sampling_parameter_of_string (sampling_parameter_to_string parameter)
       = Some parameter)
    sampling_parameter_table
;;

(* Closed vocabulary of catalog/manifest [base] labels — the provider presets a
   model entry may name as its capability base. This is the SSOT that the catalog
   ([Model_catalog.parse_entry]) and manifest ([Capability_manifest]) parsers
   validate against at parse time, so an unknown/misspelled [base] fails closed
   instead of silently resolving to [default_capabilities]
   (RFC-OAS-034 §2 rule 4 — unknown -> None, not permissive default).

   Must stay in sync with the set of labels [Capabilities.capabilities_for_provider_label]
   resolves to [Some]; a drift-guard test in [Capabilities] pins the forward
   direction (every value here resolves). Labels are normalized
   (lowercase + trim) before membership checks, matching that resolver. *)
let base_label_values =
  [ (* Provider_kind.of_string canonical kinds *)
    "anthropic"
  ; "kimi"
  ; "openai_compat"
  ; "ollama"
  ; "gemini"
  ; "glm"
  ; "dashscope"
  ; (* provider-kind aliases *)
    "claude"
  ; "openai"
  ; "openai_chat"
  ; "zhipu"
  ; "glm-coding"
  ; (* string-only presets not expressible as a Provider_kind.t *)
    "openai_compat_chat_extended"
  ; "openai_chat_extended"
  ; "xai"
  ; "mistral"
  ; "cohere"
  ; "mimo"
  ; "ollama_cloud"
  ; "nvidia"
  ]
;;
