(** Anthropic Claude API response parsing and request building.

    Pure functions operating on {!Llm_provider.Types}.
    {!build_request} uses {!Provider_config.t} (no agent_sdk coupling).
    The legacy [build_body_assoc] in agent_sdk delegates here. *)

open Types

type request_artifact = string Request_artifact_internal.t

let request_payload = Request_artifact_internal.payload
let request_output_token_receipt = Request_artifact_internal.output_token_receipt

(** Parse Anthropic API response JSON into {!api_response}. *)
let parse_response json =
  let open Yojson.Safe.Util in
  let id = json |> member "id" |> to_string in
  let model = json |> member "model" |> to_string in
  let stop_reason_str = json |> member "stop_reason" |> to_string in
  let content_list = json |> member "content" |> to_list in
  let content =
    let rec loop acc = function
      | [] -> List.rev acc
      | block :: rest ->
        (match Api_common.content_block_of_json_result block with
         | Ok content_block -> loop (content_block :: acc) rest
         | Error err ->
           invalid_arg
             ("Backend_anthropic.parse_response: "
              ^ Api_common.content_block_decode_error_to_string err))
    in
    loop [] content_list
  in
  let usage =
    let u = json |> member "usage" in
    if u = `Null
    then None
    else (
      let input_tokens = u |> member "input_tokens" |> to_int in
      let output_tokens = u |> member "output_tokens" |> to_int in
      let cache_creation_input_tokens =
        Cli_common_json.member_int "cache_creation_input_tokens" u
      in
      let cache_read_input_tokens =
        Cli_common_json.member_int "cache_read_input_tokens" u
      in
      Some
        { input_tokens
        ; output_tokens
        ; cache_creation_input_tokens
        ; cache_read_input_tokens
        ; cost_usd = None
        })
  in
  let has_tool_blocks =
    List.exists
      (function
        | ToolUse _ -> true
        | Text _
        | Thinking _
        | ReasoningDetails _
        | RedactedThinking _
        | ToolResult _
        | Image _
        | Document _
        | Audio _ -> false)
      content
  in
  let stop_reason =
    stop_reason_of_string stop_reason_str |> Stop_reason_wire.reconcile ~has_tool_blocks
  in
  { id
  ; model
  ; stop_reason
  ; content
  ; usage
  ; telemetry = Some Types.default_inference_telemetry
  }
;;

let effort_for_config (config : Provider_config.t) =
  Option.map Reasoning_effort.to_string config.reasoning_effort
;;

let thinking_config_for_config mode (config : Provider_config.t) =
  match config.enable_thinking, mode with
  | Some true, Capabilities.Anthropic_always_adaptive -> None
  | ( Some true
    , ( Capabilities.Anthropic_adaptive_default
      | Capabilities.Anthropic_adaptive_only
      | Capabilities.Anthropic_adaptive_preferred ) ) ->
    Some (`Assoc [ "type", `String "adaptive" ])
  | Some true, Capabilities.Anthropic_manual_budget ->
    (match config.thinking_budget with
     | Some budget ->
       Some (`Assoc [ "type", `String "enabled"; "budget_tokens", `Int budget ])
     | None -> None)
  | Some false, Capabilities.Anthropic_adaptive_default ->
    Some (`Assoc [ "type", `String "disabled" ])
  | Some false, _ | None, _ -> None
;;

let validate_thinking_controls mode (config : Provider_config.t) =
  match mode, config.enable_thinking, config.reasoning_effort with
  | _, Some false, Some effort ->
    Error
      (Printf.sprintf
         "model %S cannot set reasoning_effort %S when enable_thinking=false"
         config.model_id
         (Reasoning_effort.to_string effort))
  | Capabilities.Anthropic_always_adaptive, Some false, _ ->
    Error
      (Printf.sprintf
         "model %S cannot disable always-on adaptive thinking"
         config.model_id)
  | _, _, _ ->
    (match mode, config.thinking_budget with
     | Capabilities.Anthropic_manual_budget, Some _
       when config.enable_thinking = Some true ->
       Provider_config.validate_reasoning_effort_request config
     | Capabilities.Anthropic_manual_budget, Some _ ->
       Error "thinking_budget requires enable_thinking=true"
     | Capabilities.Anthropic_manual_budget, None when config.enable_thinking = Some true
       -> Error "manual-budget thinking requires an explicit thinking_budget"
     | ( ( Capabilities.Anthropic_adaptive_only
         | Capabilities.Anthropic_adaptive_default
         | Capabilities.Anthropic_adaptive_preferred
         | Capabilities.Anthropic_always_adaptive )
       , Some _ ) -> Error "thinking_budget is unsupported by adaptive thinking"
     | _, None -> Provider_config.validate_reasoning_effort_request config)
;;

let output_config_for_config _mode (config : Provider_config.t) =
  let output_format =
    match config.response_format with
    | JsonSchema schema -> Some schema
    | JsonMode | Off -> None
  in
  let fields =
    match output_format with
    | Some schema ->
      [ "format", `Assoc [ "type", `String "json_schema"; "schema", schema ] ]
    | None -> []
  in
  let fields =
    match effort_for_config config with
    | Some effort -> ("effort", `String effort) :: fields
    | None -> fields
  in
  match fields with
  | [] -> None
  | _ :: _ -> Some (`Assoc (List.rev fields))
;;

(* Anthropic and OpenAI-compatible request envelopes have different field
   names, but the optional-envelope output-budget policy (caller override
   clamped to the ceiling, omission on [None]) is owned by the OpenAI
   request module so the high-level Agent API and the standalone backend
   cannot drift. *)
let effective_max_output_tokens = Backend_openai_request.effective_max_output_tokens

(* The Messages API requires [max_tokens] on every request, so this wire
   cannot express omission the way the optional-field envelopes do (#2517).
   Explicit required-envelope policy, distinct from the optional-envelope
   resolver above:
   - caller [Some n] -> clamped to the catalog ceiling with a one-shot
     WARN (shared clamp semantics via [effective_max_output_tokens]).
   - caller [None] -> the model-catalog maximum or the caller's declared
     capability-override maximum. This is OAS's explicit required-envelope
     fallback, not a claim that the provider supplies that value as its
     default. The receipt preserves which declaration supplied the value;
     callers that need a smaller request bound can still pass one explicitly.
   - neither declared -> fail loudly naming the model; an invented
     constant is shared by thinking and answer and silently truncates
     long reasoning. *)
let required_output_token_receipt (config : Provider_config.t) =
  Backend_openai_request.output_token_receipt
    ~envelope:Types.Anthropic_messages_max_tokens
    config
  |> Types.required_output_token_receipt
;;

let required_output_token_error_message (config : Provider_config.t) = function
  | Types.Required_output_token_ceiling_missing ->
    Printf.sprintf
      "Backend_anthropic.required_max_output_tokens: model %s declares no \
       max_output_tokens and the caller passed none; the Anthropic Messages API requires \
       max_tokens — declare max_output_tokens in the model catalog, provide an explicit \
       capability override, or pass ~max_tokens"
      config.model_id
;;

let required_output_token_value receipt =
  match Types.output_token_receipt_effective receipt with
  | Some value -> value
  | None ->
    invalid_arg
      "Backend_anthropic: required output-token receipt has no effective wire value"
;;

let required_max_output_tokens config =
  match required_output_token_receipt config with
  | Ok receipt -> required_output_token_value receipt
  | Error error -> invalid_arg (required_output_token_error_message config error)
;;

(** Build Anthropic Messages API request body from {!Provider_config.t}.
    Returns a JSON string ready for HTTP POST. *)
type request_mode =
  | Completion of
      { output_token_receipt : Types.output_token_receipt
      ; stream : bool
      }
  | Count_tokens

let build_request_payload
      ~request_mode
      ?anthropic_thinking_control
      ~(config : Provider_config.t)
      ~(messages : message list)
      ?(tools : Yojson.Safe.t list = [])
      ()
  =
  (match Provider_config.validate_tool_choice_request config with
   | Ok () -> ()
   | Error reason -> invalid_arg ("Backend_anthropic.build_request: " ^ reason));
  let caps =
    match Provider_config.capabilities_for_config_model config with
    | Some caps -> caps
    | None ->
      (match config.kind with
       | Provider_config.Anthropic -> Capabilities.anthropic_capabilities
       | Provider_config.Kimi -> Capabilities.kimi_capabilities
       | Provider_config.OpenAI_compat
       | Provider_config.Ollama
       | Provider_config.Gemini
       | Provider_config.Glm
       | Provider_config.DashScope -> Capabilities.default_capabilities)
  in
  (match request_mode, config.seed with
   | Completion _, Some _ ->
     invalid_arg
       (Printf.sprintf
          "Backend_anthropic.build_request: the Anthropic Messages wire does not support \
           seed for model %S"
          config.model_id)
   | Count_tokens, _ | Completion _, None -> ());
  let tools_present = tools <> [] in
  let disable_parallel_tool_use =
    Capabilities.effective_disable_parallel_tool_use
      ~caller_disabled:config.disable_parallel_tool_use
      ~supports_parallel_tool_calls:caps.supports_parallel_tool_calls
      ~tools_present
  in
  (match request_mode, config.min_p with
   | Completion _, Some _ ->
     Backend_openai_request.warn_capability_drop ~model_id:config.model_id ~field:"min_p"
   | Count_tokens, _ | Completion _, None -> ());
  let thinking_mode =
    match config.kind with
    | Provider_config.Kimi -> Capabilities.Anthropic_manual_budget
    | Provider_config.Anthropic ->
      (match anthropic_thinking_control with
       | Some mode -> mode
       | None when Option.is_some config.enable_thinking ->
         invalid_arg
           (Printf.sprintf
              "Backend_anthropic.build_request: model %S has no catalog-declared \
               Anthropic thinking-control policy"
              config.model_id)
       | None -> Capabilities.Anthropic_manual_budget)
    | Provider_config.OpenAI_compat
    | Provider_config.Ollama
    | Provider_config.Gemini
    | Provider_config.Glm
    | Provider_config.DashScope ->
      invalid_arg
        (Printf.sprintf
           "Backend_anthropic.build_request: unsupported provider kind %s"
           (Provider_config.string_of_provider_kind config.kind))
  in
  (match validate_thinking_controls thinking_mode config with
   | Ok () -> ()
   | Error reason -> invalid_arg ("Backend_anthropic.build_request: " ^ reason));
  let projected_messages =
    match
      Reasoning_history_projection.project_for_provider_config
        ~assistant_has_payload:(fun content -> content <> [])
        ~reasoning_block_supported:(function
          | Thinking _ | RedactedThinking _ -> true
          | ReasoningDetails _
          | Text _
          | ToolUse _
          | ToolResult _
          | Image _
          | Document _
          | Audio _ -> false)
        config
        messages
    with
    | Error error ->
      invalid_arg
        ("Backend_anthropic.build_request: "
         ^ Reasoning_history_projection.error_to_string error)
    | Ok projection ->
      Reasoning_history_projection.observe ~component:"backend_anthropic" projection;
      projection.messages
  in
  let messages = Api_common.merge_tool_result_followup_user_messages projected_messages in
  let message_to_json =
    match config.kind with
    | Provider_config.Anthropic -> Api_common.message_to_json
    | Provider_config.Kimi -> Api_common.kimi_message_to_json
    | Provider_config.OpenAI_compat
    | Provider_config.Ollama
    | Provider_config.Gemini
    | Provider_config.Glm
    | Provider_config.DashScope ->
      invalid_arg
        (Printf.sprintf
           "Backend_anthropic.build_request: unsupported provider kind %s"
           (Provider_config.string_of_provider_kind config.kind))
  in
  let msgs_json = List.map message_to_json messages in
  let body =
    match request_mode with
    | Completion { output_token_receipt; stream } ->
      [ "model", `String config.model_id
      ; "max_tokens", `Int (required_output_token_value output_token_receipt)
      ; "messages", `List msgs_json
      ; "stream", `Bool stream
      ]
    | Count_tokens -> [ "model", `String config.model_id; "messages", `List msgs_json ]
  in
  let body =
    match config.system_prompt with
    | Some s when not (Api_common.string_is_blank s) ->
      let s = Utf8_sanitize.sanitize s in
      if config.cache_system_prompt
      then (
        (* The caller owns the cache opt-in. Anthropic applies the
           model/platform-specific minimum-token rule server-side; OAS has no
           tokenizer-independent way to turn that rule into a character
           threshold. *)
        let block =
          `Assoc
            [ "type", `String "text"
            ; "text", `String s
            ; "cache_control", `Assoc [ "type", `String "ephemeral" ]
            ]
        in
        ("system", `List [ block ]) :: body)
      else ("system", `String s) :: body
    | _ -> body
  in
  let body =
    match request_mode, config.temperature with
    | Completion _, Some t -> ("temperature", `Float t) :: body
    | Count_tokens, _ | Completion _, None -> body
  in
  let body =
    match request_mode, config.top_p with
    | Completion _, Some p -> ("top_p", `Float p) :: body
    | Count_tokens, _ | Completion _, None -> body
  in
  let body =
    match request_mode, config.top_k with
    | Completion _, Some k -> ("top_k", `Int k) :: body
    | Count_tokens, _ | Completion _, None -> body
  in
  let body =
    match thinking_config_for_config thinking_mode config with
    | Some thinking -> ("thinking", thinking) :: body
    | None -> body
  in
  let body =
    match output_config_for_config thinking_mode config with
    | Some output_config -> ("output_config", output_config) :: body
    | None -> body
  in
  let body =
    match tools with
    | [] -> body
    | ts ->
      if config.cache_system_prompt
      then (
        (* Add cache_control to last tool for extended cache prefix *)
        let ts_with_cache =
          (* ts is non-empty (outer match guarantees), safe to destructure *)
          let rev = List.rev ts in
          let last = List.hd rev
          and rest = List.tl rev in
          let last_with_cache =
            match last with
            | `Assoc fields ->
              `Assoc (("cache_control", `Assoc [ "type", `String "ephemeral" ]) :: fields)
            | other -> other
          in
          List.rev (last_with_cache :: rest)
        in
        ("tools", `List ts_with_cache) :: body)
      else ("tools", `List ts) :: body
  in
  (* Anthropic Messages API nests [disable_parallel_tool_use] INSIDE
     the [tool_choice] object — it is NOT a top-level body field.
     See docs.anthropic.com/en/api/messages body params:
       tool_choice.disable_parallel_tool_use: boolean

     The previous implementation emitted [disable_parallel_tool_use]
     as a top-level key, which Anthropic silently ignores, so any
     caller with [disable_parallel_tool_use = true] and
     tools was still receiving parallel tool calls. Same class of
     silent-drop bug as #834 but for a different field; also fixes
     the drift with the agent_sdk path in lib/api_anthropic.ml which
     already nests correctly. *)
  let tool_choice_json_with_disable choice =
    let base = tool_choice_to_json choice in
    if disable_parallel_tool_use
    then (
      match base with
      | `Assoc fields -> `Assoc (("disable_parallel_tool_use", `Bool true) :: fields)
      | other -> other)
    else base
  in
  let body =
    match config.tool_choice with
    | Some choice -> ("tool_choice", tool_choice_json_with_disable choice) :: body
    | None ->
      if disable_parallel_tool_use && tools_present
      then (
        (* No explicit tool_choice but caller still wants to disable
           parallel tool use — synthesize an [auto] choice to carry
           the flag, matching the agent_sdk path at
           lib/api_anthropic.ml. *)
        let tc =
          `Assoc [ "type", `String "auto"; "disable_parallel_tool_use", `Bool true ]
        in
        ("tool_choice", tc) :: body)
      else body
  in
  Yojson.Safe.to_string (`Assoc body)
;;

let build_request_artifact_from_receipt
      ~output_token_receipt
      ?(stream = false)
      ?anthropic_thinking_control
      ~config
      ~messages
      ?tools
      ()
  =
  let payload =
    build_request_payload
      ~request_mode:(Completion { output_token_receipt; stream })
      ?anthropic_thinking_control
      ~config
      ~messages
      ?tools
      ()
  in
  Request_artifact_internal.create ~payload ~output_token_receipt
;;

let build_request_artifact_with_thinking_control
      ?stream
      ~anthropic_thinking_control
      ~config
      ~messages
      ?tools
      ()
  =
  match required_output_token_receipt config with
  | Error _ as error -> error
  | Ok output_token_receipt ->
    Ok
      (build_request_artifact_from_receipt
         ~output_token_receipt
         ?stream
         ?anthropic_thinking_control
         ~config
         ~messages
         ?tools
         ())
;;

(* Legacy/non-exact boundary. Exact output never calls this resolver-backed
   wrapper; it calls [build_request_artifact_with_thinking_control] with the
   snapshot-frozen option, including an explicit [None]. *)
let nonexact_anthropic_thinking_control (config : Provider_config.t) =
  match config.kind with
  | Provider_config.Anthropic ->
    Capabilities.anthropic_thinking_control_for_model_id config.model_id
  | Provider_config.Kimi
  | Provider_config.OpenAI_compat
  | Provider_config.Ollama
  | Provider_config.Gemini
  | Provider_config.Glm
  | Provider_config.DashScope -> None
;;

let validate_nonexact_thinking_controls (config : Provider_config.t) =
  match config.kind with
  | Provider_config.Anthropic ->
    (match nonexact_anthropic_thinking_control config with
     | Some mode -> validate_thinking_controls mode config
     | None when Option.is_some config.enable_thinking ->
       Error
         (Printf.sprintf
            "model %S has no catalog-declared Anthropic thinking-control policy; an \
             explicit enable_thinking value cannot be encoded safely"
            config.model_id)
     | None -> Ok ())
  | Provider_config.Kimi ->
    validate_thinking_controls Capabilities.Anthropic_manual_budget config
  | Provider_config.OpenAI_compat
  | Provider_config.Ollama
  | Provider_config.Gemini
  | Provider_config.Glm
  | Provider_config.DashScope -> Ok ()
;;

let build_request_artifact ?stream ~config ~messages ?tools () =
  build_request_artifact_with_thinking_control
    ?stream
    ~anthropic_thinking_control:(nonexact_anthropic_thinking_control config)
    ~config
    ~messages
    ?tools
    ()
;;

let build_request ?stream ~config ~messages ?tools () =
  match build_request_artifact ?stream ~config ~messages ?tools () with
  | Ok artifact -> request_payload artifact
  | Error error -> invalid_arg (required_output_token_error_message config error)
;;

let build_count_tokens_request ~config ~messages ?tools () =
  match config.Provider_config.kind with
  | Provider_config.Anthropic | Provider_config.Kimi ->
    build_request_payload
      ~request_mode:Count_tokens
      ?anthropic_thinking_control:(nonexact_anthropic_thinking_control config)
      ~config
      ~messages
      ?tools
      ()
  | Provider_config.OpenAI_compat
  | Provider_config.Ollama
  | Provider_config.Gemini
  | Provider_config.Glm
  | Provider_config.DashScope ->
    invalid_arg
      ("Backend_anthropic.build_count_tokens_request: Anthropic-compatible Messages "
       ^ "provider required")
;;
