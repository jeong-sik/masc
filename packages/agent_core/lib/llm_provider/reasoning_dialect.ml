(** Provider reasoning/thinking dialect semantics. *)

type toggle_default =
  | Enabled
  | Disabled
  | Provider_default

type toggle_wire =
  | No_toggle
  | Thinking_object of { includes_reasoning_effort : bool }
  | Thinking_object_adaptive
  | Thinking_object_only
  | Chat_template_kwargs
  | Chat_template_token
  | Ollama_think
  | Reasoning_effort
  | Enable_thinking
  | Anthropic_thinking
  | Gemini_thinking_config

type effort_alias_policy =
  | Preserve_effort
  | Deepseek_high_or_max

type sampling_policy =
  { ignored_always : Capabilities.sampling_parameter list
  ; ignored_when_thinking : Capabilities.sampling_parameter list
  }

type replay_policy = Reasoning_replay_contract.replay_policy =
  | No_replay
  | Tool_call_assistant_messages_all_history
  | Tool_call_assistant_messages_latest_user_turn
  | All_assistant_messages
  | Provider_opaque_state

type streaming_reasoning = Reasoning_replay_contract.streaming_reasoning =
  | No_streaming_reasoning
  | Delta_field of string
  | Delta_reasoning_details
  | Template_parser

type output_wire = Reasoning_replay_contract.output_wire =
  | No_output_control
  | Reasoning_split

type thinking_object_only_control =
  { enabled : bool option
  ; keep_all : bool
  }

type openai_request_wire =
  | Chat_completions
  | Responses

type explicit_enable_encoding =
  | Request_control_field
  | Chat_template_system_token

type explicit_enable_receipt =
  | Explicit_enable_not_requested
  | Explicit_enable_encoded of explicit_enable_encoding
  | Explicit_enable_not_encoded

type request_control_artifact =
  { fields : (string * Yojson.Safe.t) list
  ; explicit_enable_receipt : explicit_enable_receipt
  }

type request_control_rejection =
  | Thinking_budget_unsupported
  | Reasoning_effort_unsupported
  | Reasoning_effort_value_unsupported of Reasoning_effort.t

let request_control_rejection_to_message = function
  | Thinking_budget_unsupported ->
    "Reasoning_dialect.request_control_fields: thinking_budget is unsupported by the \
     selected provider wire"
  | Reasoning_effort_unsupported ->
    "Reasoning_dialect.request_control_fields: reasoning_effort is unsupported by the \
     selected provider wire"
  | Reasoning_effort_value_unsupported effort ->
    Printf.sprintf
      "Reasoning_dialect.request_control_fields: reasoning_effort %S is not supported by \
       the selected provider wire"
      (Reasoning_effort.to_string effort)
;;

type t =
  { toggle_default : toggle_default
  ; toggle_wire : toggle_wire
  ; preserve_wire : Capabilities.preserve_thinking_control_format
  ; effort_alias_policy : effort_alias_policy
  ; sampling_policy : sampling_policy
  ; replay_policy : replay_policy
  ; streaming : streaming_reasoning
  ; output_wire : output_wire
  }

let sampling_supported = { ignored_always = []; ignored_when_thinking = [] }

let default =
  { toggle_default = Provider_default
  ; toggle_wire = No_toggle
  ; preserve_wire = No_preserve_thinking_control
  ; effort_alias_policy = Preserve_effort
  ; sampling_policy = sampling_supported
  ; replay_policy = No_replay
  ; streaming = No_streaming_reasoning
  ; output_wire = No_output_control
  }
;;

let deepseek_ignored_sampling_params =
  [ Capabilities.Temperature
  ; Capabilities.Top_p
  ; Capabilities.Presence_penalty
  ; Capabilities.Frequency_penalty
  ]
;;

let sampling_policy_of_capabilities (caps : Capabilities.capabilities) =
  { sampling_supported with ignored_always = caps.ignored_sampling_parameters }
;;

let base_of_capabilities (caps : Capabilities.capabilities) =
  let preserve_wire = caps.preserve_thinking_control_format in
  let output_wire =
    match caps.reasoning_output_format with
    | No_reasoning_output_format -> No_output_control
    | Split_reasoning_fields -> Reasoning_split
  in
  let default = { default with sampling_policy = sampling_policy_of_capabilities caps } in
  match caps.thinking_control_format with
  | No_thinking_control ->
    let dialect = { default with preserve_wire; output_wire } in
    (match preserve_wire with
     | Always_preserved_thinking ->
       { dialect with
         replay_policy = All_assistant_messages
       ; streaming = Delta_field "reasoning_content"
       }
     | No_preserve_thinking_control
     | Thinking_object_keep_all
     | Chat_template_kwargs_preserve_thinking
     | Thinking_object_clear_thinking
     | Top_level_preserve_thinking -> dialect)
  | Thinking_object ->
    { toggle_default = Enabled
    ; toggle_wire = Thinking_object { includes_reasoning_effort = true }
    ; preserve_wire
    ; effort_alias_policy = Deepseek_high_or_max
    ; sampling_policy =
        { ignored_always = caps.ignored_sampling_parameters
        ; ignored_when_thinking = deepseek_ignored_sampling_params
        }
    ; replay_policy = Tool_call_assistant_messages_all_history
    ; streaming = Delta_field "reasoning_content"
    ; output_wire
    }
  | Thinking_object_adaptive ->
    { default with
      toggle_default = Enabled
    ; toggle_wire = Thinking_object_adaptive
    ; preserve_wire
    ; streaming =
        (match output_wire with
         | Reasoning_split -> Delta_reasoning_details
         | No_output_control -> Delta_field "reasoning_content")
    ; output_wire
    }
  | Thinking_object_only ->
    let replay_policy =
      match preserve_wire with
      | Thinking_object_keep_all -> Tool_call_assistant_messages_all_history
      | No_preserve_thinking_control
      | Chat_template_kwargs_preserve_thinking
      | Thinking_object_clear_thinking
      | Top_level_preserve_thinking
      | Always_preserved_thinking -> default.replay_policy
    in
    { default with
      toggle_default = Provider_default
    ; toggle_wire = Thinking_object_only
    ; preserve_wire
    ; replay_policy
    ; streaming = Delta_field "reasoning_content"
    ; output_wire
    }
  | Chat_template_kwargs ->
    { default with
      toggle_wire = Chat_template_kwargs
    ; preserve_wire
    ; streaming = Template_parser
    ; output_wire
    }
  | Chat_template_token _ ->
    { default with
      toggle_wire = Chat_template_token
    ; preserve_wire
    ; streaming = Template_parser
    ; output_wire
    }
  | Ollama_think ->
    { default with
      toggle_wire = Ollama_think
    ; preserve_wire
    ; streaming = Delta_field "thinking"
    ; output_wire
    }
  | Reasoning_effort ->
    { default with
      toggle_wire = Reasoning_effort
    ; preserve_wire
    ; streaming = Delta_field "reasoning"
    ; output_wire
    }
  | Enable_thinking ->
    { default with
      toggle_wire = Enable_thinking
    ; preserve_wire
    ; streaming = Delta_field "reasoning_content"
    ; output_wire
    }
;;

let apply_replay_override caps dialect =
  match caps.Capabilities.reasoning_replay_override with
  | Default_reasoning_replay -> dialect
  | Force_no_replay -> { dialect with replay_policy = No_replay }
  | Force_drop_without_tool_preserve_with_tool ->
    { dialect with replay_policy = Tool_call_assistant_messages_all_history }
  | Force_latest_user_turn_tool_calls ->
    { dialect with replay_policy = Tool_call_assistant_messages_latest_user_turn }
  | Force_preserve_always -> { dialect with replay_policy = All_assistant_messages }
;;

let apply_streaming_format caps dialect =
  match caps.Capabilities.reasoning_streaming_format with
  | Default_reasoning_streaming -> dialect
  | No_reasoning_streaming -> { dialect with streaming = No_streaming_reasoning }
  | Delta_reasoning_field field -> { dialect with streaming = Delta_field field }
  | Template_reasoning_streaming -> { dialect with streaming = Template_parser }
;;

let of_capabilities caps =
  base_of_capabilities caps |> apply_streaming_format caps |> apply_replay_override caps
;;

let with_preserve_thinking ~preserve_thinking dialect =
  match dialect.preserve_wire, preserve_thinking with
  | Always_preserved_thinking, _ ->
    { dialect with replay_policy = All_assistant_messages }
  | ( ( Thinking_object_keep_all
      | Chat_template_kwargs_preserve_thinking
      | Top_level_preserve_thinking )
    , Some true ) -> { dialect with replay_policy = All_assistant_messages }
  | ( ( No_preserve_thinking_control
      | Thinking_object_keep_all
      | Chat_template_kwargs_preserve_thinking
      | Thinking_object_clear_thinking
      | Top_level_preserve_thinking )
    , _ ) -> dialect
;;

let thinking_enabled ~enable_thinking =
  match enable_thinking with
  | Some false -> false
  | Some true | None -> true
;;

let thinking_object_only_control dialect ~enable_thinking ~preserve_thinking =
  let keep_all =
    match dialect.preserve_wire with
    | Thinking_object_keep_all ->
      (match preserve_thinking, enable_thinking with
       | Some true, (None | Some true) -> true
       | Some true, Some false | Some false, _ | None, _ -> false)
    | No_preserve_thinking_control
    | Chat_template_kwargs_preserve_thinking
    | Thinking_object_clear_thinking
    | Top_level_preserve_thinking
    | Always_preserved_thinking -> false
  in
  let enabled =
    match enable_thinking with
    | Some _ as enabled -> enabled
    | None when keep_all -> Some true
    | None -> None
  in
  { enabled; keep_all }
;;

let chat_template_kwargs_preserve_field dialect ~preserve_thinking =
  match dialect.preserve_wire with
  | Chat_template_kwargs_preserve_thinking -> preserve_thinking
  | No_preserve_thinking_control
  | Thinking_object_keep_all
  | Thinking_object_clear_thinking
  | Top_level_preserve_thinking
  | Always_preserved_thinking -> None
;;

let top_level_preserve_field dialect ~preserve_thinking =
  match dialect.preserve_wire with
  | Top_level_preserve_thinking -> preserve_thinking
  | No_preserve_thinking_control
  | Thinking_object_keep_all
  | Chat_template_kwargs_preserve_thinking
  | Thinking_object_clear_thinking
  | Always_preserved_thinking -> None
;;

let ignores_sampling_param dialect ~enable_thinking parameter =
  List.mem parameter dialect.sampling_policy.ignored_always
  || (thinking_enabled ~enable_thinking
      && List.mem parameter dialect.sampling_policy.ignored_when_thinking)
;;

let bool_field name = function
  | Some value -> [ name, `Bool value ]
  | None -> []
;;

let reasoning_output_fields dialect ~enable_thinking =
  match dialect.output_wire, thinking_enabled ~enable_thinking with
  | Reasoning_split, true -> [ "reasoning_split", `Bool true ]
  | Reasoning_split, false | No_output_control, _ -> []
;;

let normalize_effort_value dialect effort =
  match dialect.effort_alias_policy, (effort : Reasoning_effort.t) with
  | Deepseek_high_or_max, Reasoning_effort.High -> Some "high"
  | Deepseek_high_or_max, Reasoning_effort.Max -> Some "max"
  | ( Deepseek_high_or_max
    , ( Reasoning_effort.None_
      | Reasoning_effort.Minimal
      | Reasoning_effort.Low
      | Reasoning_effort.Medium
      | Reasoning_effort.XHigh ) ) -> None
  | Preserve_effort, effort -> Some (Reasoning_effort.to_string effort)
;;

let validate_request_control_inputs
      request_wire
      dialect
      ~thinking_budget
      ~reasoning_effort
  =
  let thinking_budget_result =
    match thinking_budget, request_wire, dialect.toggle_wire with
    | None, _, _ | Some _, Chat_completions, Enable_thinking -> Ok ()
    | Some _, _, _ -> Error Thinking_budget_unsupported
  in
  match thinking_budget_result with
  | Error _ as error -> error
  | Ok () ->
    (match reasoning_effort, request_wire, dialect.toggle_wire with
     | None, _, _
     | Some _, (Chat_completions | Responses), Reasoning_effort
     | Some _, Chat_completions, Thinking_object { includes_reasoning_effort = true } ->
       Ok ()
     | Some _, _, _ -> Error Reasoning_effort_unsupported)
;;

let normalized_effort_for_request dialect = function
  | None -> Ok None
  | Some effort ->
    (match normalize_effort_value dialect effort with
     | Some normalized -> Ok (Some normalized)
     | None -> Error (Reasoning_effort_value_unsupported effort))
;;

let request_control_fields
      request_wire
      dialect
      ~enable_thinking
      ~preserve_thinking
      ~thinking_budget
      ~reasoning_effort
      ?clear_thinking_object
      ()
  =
  match
    validate_request_control_inputs
      request_wire
      dialect
      ~thinking_budget
      ~reasoning_effort
  with
  | Error _ as error -> error
  | Ok () ->
    (match normalized_effort_for_request dialect reasoning_effort with
     | Error _ as error -> error
     | Ok normalized_effort ->
       let normalized_effort_field () =
         match normalized_effort with
         | Some effort -> [ "reasoning_effort", `String effort ]
         | None -> []
       in
       let explicit_field_encoding =
         match enable_thinking with
         | Some true -> Some Request_control_field
         | Some false | None -> None
       in
       let explicit_reasoning_effort_encoding =
         (* [None_] is the typed no-reasoning setting, not proof that an
            explicit enable request reached the wire. Keep this decision on
            the constructor so admission never interprets the wire string. *)
         match enable_thinking, reasoning_effort with
         | ( Some true
           , Some
               ( Reasoning_effort.Minimal
               | Reasoning_effort.Low
               | Reasoning_effort.Medium
               | Reasoning_effort.High
               | Reasoning_effort.XHigh
               | Reasoning_effort.Max ) ) -> Some Request_control_field
         | Some true, (Some Reasoning_effort.None_ | None) | (Some false | None), _ ->
           None
       in
       let fields, explicit_enable_encoding =
         match request_wire, dialect.toggle_wire with
         | Responses, Reasoning_effort ->
           (match normalized_effort with
            | Some effort ->
              ( [ "reasoning", `Assoc [ "effort", `String effort ] ]
              , explicit_reasoning_effort_encoding )
            | None -> [], None)
         | ( Responses
           , ( No_toggle
             | Thinking_object _
             | Thinking_object_adaptive
             | Thinking_object_only
             | Chat_template_kwargs
             | Chat_template_token
             | Ollama_think
             | Enable_thinking
             | Anthropic_thinking
             | Gemini_thinking_config ) ) -> [], None
         | Chat_completions, Chat_template_kwargs ->
           let fields =
             bool_field "enable_thinking" enable_thinking
             @ bool_field
                 "preserve_thinking"
                 (chat_template_kwargs_preserve_field dialect ~preserve_thinking)
           in
           ( (match fields with
              | [] -> []
              | fields -> [ "chat_template_kwargs", `Assoc fields ])
           , explicit_field_encoding )
         | Chat_completions, Chat_template_token ->
           let encoding =
             match enable_thinking with
             | Some true -> Some Chat_template_system_token
             | Some false | None -> None
           in
           [], encoding
         | Chat_completions, Ollama_think -> [], None
         | Chat_completions, Enable_thinking ->
           let fields =
             bool_field "enable_thinking" enable_thinking
             @ bool_field
                 "preserve_thinking"
                 (top_level_preserve_field dialect ~preserve_thinking)
           in
           let fields =
             match enable_thinking, thinking_budget with
             | Some true, Some budget -> ("thinking_budget", `Int budget) :: fields
             | _ -> fields
           in
           fields, explicit_field_encoding
         | Chat_completions, Reasoning_effort ->
           let fields = normalized_effort_field () in
           fields, explicit_reasoning_effort_encoding
         | Chat_completions, Thinking_object _ ->
           let fields =
             match enable_thinking with
             | Some true ->
               ("thinking", `Assoc [ "type", `String "enabled" ])
               :: normalized_effort_field ()
             | Some false -> [ "thinking", `Assoc [ "type", `String "disabled" ] ]
             | None -> []
           in
           fields, explicit_field_encoding
         | Chat_completions, Thinking_object_adaptive ->
           let fields =
             match enable_thinking with
             | Some true -> [ "thinking", `Assoc [ "type", `String "adaptive" ] ]
             | Some false -> [ "thinking", `Assoc [ "type", `String "disabled" ] ]
             | None -> []
           in
           fields, explicit_field_encoding
         | Chat_completions, Thinking_object_only ->
           let control =
             thinking_object_only_control dialect ~enable_thinking ~preserve_thinking
           in
           let fields =
             match control.enabled with
             | Some enabled ->
               [ "type", `String (if enabled then "enabled" else "disabled") ]
             | None -> []
           in
           let fields =
             if control.keep_all then fields @ [ "keep", `String "all" ] else fields
           in
           ( (match fields with
              | [] -> []
              | fields -> [ "thinking", `Assoc fields ])
           , explicit_field_encoding )
         | Chat_completions, No_toggle ->
           (match clear_thinking_object, enable_thinking with
            | Some clear_thinking, Some true ->
              ( [ ( "thinking"
                  , `Assoc
                      [ "type", `String "enabled"
                      ; "clear_thinking", `Bool clear_thinking
                      ] )
                ]
              , explicit_field_encoding )
            | Some _, Some false ->
              [ "thinking", `Assoc [ "type", `String "disabled" ] ], None
            | Some _, None | None, _ -> [], None)
         | Chat_completions, (Anthropic_thinking | Gemini_thinking_config) -> [], None
       in
       let output_fields =
         match request_wire with
         | Chat_completions -> reasoning_output_fields dialect ~enable_thinking
         | Responses -> []
       in
       let explicit_enable_receipt =
         match enable_thinking, explicit_enable_encoding with
         | Some true, Some encoding -> Explicit_enable_encoded encoding
         | Some true, None -> Explicit_enable_not_encoded
         | Some false, _ | None, _ -> Explicit_enable_not_requested
       in
       Ok { fields = output_fields @ fields; explicit_enable_receipt })
;;

let provider_capabilities_of_kind kind = Capabilities.capabilities_of_kind kind

let base_for_provider_config (config : Provider_config.t) =
  match config.kind with
  | Anthropic ->
    { default with
      toggle_wire = Anthropic_thinking
    ; replay_policy = All_assistant_messages
    ; streaming = Delta_field "thinking_delta"
    }
  | Gemini ->
    { default with
      toggle_wire = Gemini_thinking_config
    ; (* GenerateContent is stateless. Signed parts must remain attached to the
         exact model response part and be returned unchanged. *)
      replay_policy = All_assistant_messages
    ; streaming = Delta_field "thought"
    }
  | Ollama ->
    let caps =
      match Provider_config.capabilities_for_config_model config with
      | Some caps -> caps
      | None -> provider_capabilities_of_kind config.kind
    in
    let dialect = of_capabilities caps in
    (* Ollama native [/api/chat] tool-loop history must return the accumulated
       assistant [thinking] together with its tool calls in the next request.
       The structural latest-user-turn policy preserves exactly those active
       tool-call artifacts without recursively replaying old-turn traces.

       Official Ollama tool-calling and streaming guides, checked 2026-07-20:
       https://docs.ollama.com/capabilities/tool-calling
       https://docs.ollama.com/capabilities/streaming

       A catalog/manifest override remains authoritative: the transport
       default applies only when the capability row says [Default]. *)
    (match caps.reasoning_replay_override with
     | Default_reasoning_replay ->
       { dialect with replay_policy = Tool_call_assistant_messages_latest_user_turn }
     | Force_no_replay
     | Force_drop_without_tool_preserve_with_tool
     | Force_latest_user_turn_tool_calls
     | Force_preserve_always -> dialect)
  | Kimi | OpenAI_compat | Glm ->
    (match Provider_config.capabilities_for_config_model config with
     | Some caps -> of_capabilities caps
     | None -> provider_capabilities_of_kind config.kind |> of_capabilities)
  | DashScope ->
    (* DashScope emits top-level enable_thinking/preserve_thinking regardless of
       the model catalog. *)
    of_capabilities Capabilities.dashscope_capabilities
;;

(* Replay activation for the [Thinking_object_clear_thinking] preserve wire.
   That wire declares that the provider only echoes prior-turn reasoning under
   "preserved thinking": thinking active AND [clear_thinking = false]. Under the
   wire default [clear_thinking = true] the server discards prior reasoning, so
   sending it back violates the contract and grows the request every turn.

   RFC-OAS-029 S1.1/S3.1: the branch predicate is the typed capability the
   catalog row declares, exactly like the [Thinking_object] arm of
   [base_of_capabilities]. No provider identity participates, so an operator can
   move this contract onto another row without touching OCaml. *)
let apply_clear_thinking_replay_gate (config : Provider_config.t) dialect =
  match dialect.preserve_wire with
  | Thinking_object_clear_thinking ->
    { dialect with
      replay_policy =
        (if
           Provider_config.preserved_thinking_active
             ~enable_thinking:config.enable_thinking
             ~clear_thinking:config.clear_thinking
             ~preserve_thinking:config.preserve_thinking
         then All_assistant_messages
         else No_replay)
    }
  | No_preserve_thinking_control
  | Thinking_object_keep_all
  | Chat_template_kwargs_preserve_thinking
  | Top_level_preserve_thinking
  | Always_preserved_thinking -> dialect
;;

(* The OpenAI Responses envelope keeps reasoning as provider-held state rather
   than as replayable content. This is the transport fact owned by
   {!Provider_http_codec} (the single kind-keyed dispatch this module is allowed
   to consult), applied identically to the stable and the request-local dialect
   so the stamped contract and the consuming contract cannot disagree. *)
let apply_transport_replay_override (config : Provider_config.t) dialect =
  match Provider_http_codec.of_config config with
  | Provider_http_codec.Openai_responses ->
    { dialect with replay_policy = Provider_opaque_state }
  | Anthropic_messages | Openai_chat | Ollama_chat | Gemini_generate_content | Glm_chat ->
    dialect
;;

let for_provider_config (config : Provider_config.t) =
  base_for_provider_config config
  |> with_preserve_thinking ~preserve_thinking:config.preserve_thinking
  |> apply_clear_thinking_replay_gate config
  |> apply_transport_replay_override config
;;

(* Field projection, not a translation table: {!replay_policy},
   {!streaming_reasoning} and {!output_wire} are the leaf
   {!Reasoning_replay_contract} types by type equation. *)
let replay_contract dialect : Reasoning_replay_contract.t =
  { replay_policy = dialect.replay_policy
  ; streaming = dialect.streaming
  ; output_wire = dialect.output_wire
  }
;;

(* Which stored reasoning a rotation may still carry, decided from the dialect's
   own typed wire facts.

   [Require_identical_source] is for artifacts the producing endpoint has to
   validate: [Provider_opaque_state] is a handle to state the provider holds,
   and the Anthropic/Gemini thinking wires return signed blocks whose signature
   is checked on replay. Every other wire carries reasoning as self-contained
   text in a side channel, which the same model on a rotated endpoint accepts
   unchanged.

   Both matches are exhaustive: a new replay policy or toggle wire has to state
   its rotation answer instead of inheriting one. *)
let rotation_policy dialect : Reasoning_replay_contract.rotation_policy =
  match dialect.replay_policy with
  | Provider_opaque_state -> Require_identical_source
  | No_replay
  | Tool_call_assistant_messages_all_history
  | Tool_call_assistant_messages_latest_user_turn
  | All_assistant_messages ->
    (match dialect.toggle_wire with
     | Anthropic_thinking | Gemini_thinking_config -> Require_identical_source
     | No_toggle
     | Thinking_object _
     | Thinking_object_adaptive
     | Thinking_object_only
     | Chat_template_kwargs
     | Chat_template_token
     | Ollama_think
     | Reasoning_effort
     | Enable_thinking -> Allow_endpoint_rotation)
;;

(* Artifact provenance is derived from the stable provider/model/transport
   shape. Request-local replay selection (for example [preserve_thinking] or the
   clear-thinking gate) is applied by [for_provider_config] at the consuming
   boundary and must not rewrite the identity of an already-produced artifact. *)
let stable_dialect_for_provider_config config =
  base_for_provider_config config |> apply_transport_replay_override config
;;

let reasoning_source_for_provider_config config =
  Types.Reasoning_source.create
    ~provider_kind:config.Provider_config.kind
    ~provider_instance:
      (Types.Reasoning_source.provider_instance
         ~base_url:config.base_url
         ~request_path:config.request_path)
    ~canonical_model_id:config.model_id
    ~replay_contract:(replay_contract (stable_dialect_for_provider_config config))
;;

type replay_capability =
  { target : Types.Reasoning_source.t
  ; contract : Reasoning_replay_contract.t
  ; rotation : Reasoning_replay_contract.rotation_policy
  }

let replay_capability_for_provider_config config =
  Result.map
    (fun target ->
       let dialect = for_provider_config config in
       { target; contract = replay_contract dialect; rotation = rotation_policy dialect })
    (reasoning_source_for_provider_config config)
;;

let sampling_params_ignored_when_thinking dialect =
  let params =
    dialect.sampling_policy.ignored_always @ dialect.sampling_policy.ignored_when_thinking
  in
  List.fold_left
    (fun acc parameter -> if List.mem parameter acc then acc else acc @ [ parameter ])
    []
    params
;;

(* Sampling params a wire format ignores while thinking is enabled, keyed purely
   by the format so both request builders can consult it without a full dialect.
   Only DeepSeek-style [Thinking_object] suppresses sampling; the constant is the
   single source of truth, also used by [of_capabilities] above. *)
let sampling_params_ignored_for_format
  : Capabilities.thinking_control_format -> Capabilities.sampling_parameter list
  = function
  | Capabilities.Thinking_object -> deepseek_ignored_sampling_params
  | Capabilities.No_thinking_control
  | Capabilities.Thinking_object_adaptive
  | Capabilities.Thinking_object_only
  | Capabilities.Chat_template_kwargs
  | Capabilities.Chat_template_token _
  | Capabilities.Ollama_think
  | Capabilities.Reasoning_effort
  | Capabilities.Enable_thinking -> []
;;

let sampling_field_ignored_when_thinking
      ~thinking_control_format
      ~enable_thinking
      ~parameter
  =
  let thinking_active =
    match enable_thinking with
    | Some false -> false
    | Some true | None -> true
  in
  thinking_active
  && List.mem parameter (sampling_params_ignored_for_format thinking_control_format)
;;

let should_replay_reasoning dialect ~assistant_had_tool_call =
  match dialect.replay_policy with
  | No_replay | Provider_opaque_state -> false
  | All_assistant_messages -> true
  | Tool_call_assistant_messages_all_history
  | Tool_call_assistant_messages_latest_user_turn -> assistant_had_tool_call
;;

let requires_reasoning_replay_on_tool_call dialect =
  should_replay_reasoning dialect ~assistant_had_tool_call:true
  && not (should_replay_reasoning dialect ~assistant_had_tool_call:false)
;;

let toggle_wire_to_string = function
  | No_toggle -> "no_toggle"
  | Thinking_object { includes_reasoning_effort = true } -> "thinking_object"
  | Thinking_object { includes_reasoning_effort = false } -> "thinking_object_no_effort"
  | Thinking_object_adaptive -> "thinking_object_adaptive"
  | Thinking_object_only -> "thinking_object_only"
  | Chat_template_kwargs -> "chat_template_kwargs"
  | Chat_template_token -> "chat_template_token"
  | Ollama_think -> "ollama_think"
  | Reasoning_effort -> "reasoning_effort"
  | Enable_thinking -> "enable_thinking"
  | Anthropic_thinking -> "anthropic_thinking"
  | Gemini_thinking_config -> "gemini_thinking_config"
;;

let replay_policy_to_string = function
  | No_replay -> "no_replay"
  | Tool_call_assistant_messages_all_history -> "drop_without_tool_preserve_with_tool"
  | Tool_call_assistant_messages_latest_user_turn -> "latest_user_turn_tool_calls"
  | All_assistant_messages -> "preserve_always"
  | Provider_opaque_state -> "provider_hidden_replay"
;;

[@@@coverage off]

let%test "reasoning_replay_override Force_preserve_always lifts base no_replay" =
  let caps =
    { Capabilities.default_capabilities with
      supports_reasoning = true
    ; thinking_control_format = Capabilities.Reasoning_effort
    ; reasoning_replay_override = Capabilities.Force_preserve_always
    }
  in
  let dialect = of_capabilities caps in
  (* base Reasoning_effort yields No_replay; the override lifts it to All_assistant_messages
     so reasoning is replayed on both plain and tool turns. *)
  should_replay_reasoning dialect ~assistant_had_tool_call:false
  && should_replay_reasoning dialect ~assistant_had_tool_call:true
;;

let%test "reasoning_replay_override drop_without_tool replays only on tool turns" =
  let caps =
    { Capabilities.default_capabilities with
      supports_reasoning = true
    ; thinking_control_format = Capabilities.Reasoning_effort
    ; reasoning_replay_override = Capabilities.Force_drop_without_tool_preserve_with_tool
    }
  in
  let dialect = of_capabilities caps in
  (not (should_replay_reasoning dialect ~assistant_had_tool_call:false))
  && should_replay_reasoning dialect ~assistant_had_tool_call:true
;;

let%test "reasoning_replay_override latest_user_turn stays structurally distinct" =
  let caps =
    { Capabilities.default_capabilities with
      supports_reasoning = true
    ; thinking_control_format = Capabilities.Chat_template_kwargs
    ; reasoning_replay_override = Capabilities.Force_latest_user_turn_tool_calls
    }
  in
  let dialect = of_capabilities caps in
  replay_policy_to_string dialect.replay_policy = "latest_user_turn_tool_calls"
  && should_replay_reasoning dialect ~assistant_had_tool_call:true
  && not (should_replay_reasoning dialect ~assistant_had_tool_call:false)
;;

let%test
    "reasoning_replay_override default keeps base policy (Reasoning_effort = no_replay)"
  =
  let caps =
    { Capabilities.default_capabilities with
      supports_reasoning = true
    ; thinking_control_format = Capabilities.Reasoning_effort
    }
  in
  not (should_replay_reasoning (of_capabilities caps) ~assistant_had_tool_call:false)
;;

let%test
    "kimi base profile replays reasoning on every turn (live path: bare kimi-k2.* -> \
     base=kimi)"
  =
  (* A consumer may send a bare API name (e.g. "kimi-k2.6"). Longest-prefix
     matching resolves it to the native "kimi-k2" catalog row whose base="kimi",
     so this profile is the dialect applied on that path. Kimi requires
     reasoning replay (hard-required on tool turns, recommended always). The
     Kimi base profile now carries both Always_preserved_thinking and
     Force_preserve_always so catalog inheritance keeps replay explicit. Revert
     that override -> both arms go false. *)
  let dialect = of_capabilities Capabilities.kimi_capabilities in
  should_replay_reasoning dialect ~assistant_had_tool_call:false
  && should_replay_reasoning dialect ~assistant_had_tool_call:true
;;

let%test "request_control_fields emits qwen chat_template kwargs" =
  let dialect =
    of_capabilities
      { Capabilities.default_capabilities with
        supports_reasoning = true
      ; thinking_control_format = Capabilities.Chat_template_kwargs
      ; preserve_thinking_control_format =
          Capabilities.Chat_template_kwargs_preserve_thinking
      }
  in
  request_control_fields
    Chat_completions
    dialect
    ~enable_thinking:(Some false)
    ~preserve_thinking:(Some true)
    ~thinking_budget:None
    ~reasoning_effort:None
    ()
  = Ok
      { fields =
          [ ( "chat_template_kwargs"
            , `Assoc [ "enable_thinking", `Bool false; "preserve_thinking", `Bool true ] )
          ]
      ; explicit_enable_receipt = Explicit_enable_not_requested
      }
;;

let%test "request_control_fields emits thinking object with explicitly supported effort" =
  let dialect =
    of_capabilities
      { Capabilities.default_capabilities with
        supports_reasoning = true
      ; thinking_control_format = Capabilities.Thinking_object
      }
  in
  request_control_fields
    Chat_completions
    dialect
    ~enable_thinking:(Some true)
    ~preserve_thinking:None
    ~thinking_budget:None
    ~reasoning_effort:(Some Reasoning_effort.High)
    ()
  = Ok
      { fields =
          [ "thinking", `Assoc [ "type", `String "enabled" ]
          ; "reasoning_effort", `String "high"
          ]
      ; explicit_enable_receipt = Explicit_enable_encoded Request_control_field
      }
;;

let%test "request_control_fields keeps zai glm no-toggle exception explicit" =
  request_control_fields
    Chat_completions
    default
    ~enable_thinking:(Some true)
    ~preserve_thinking:(Some true)
    ~thinking_budget:None
    ~reasoning_effort:None
    ~clear_thinking_object:false
    ()
  = Ok
      { fields =
          [ ( "thinking"
            , `Assoc [ "type", `String "enabled"; "clear_thinking", `Bool false ] )
          ]
      ; explicit_enable_receipt = Explicit_enable_encoded Request_control_field
      }
;;

let%test "explicit enable receipt follows the selected OpenAI request wire" =
  let dialect format =
    of_capabilities
      { Capabilities.default_capabilities with
        supports_reasoning = true
      ; thinking_control_format = format
      }
  in
  let request request_wire dialect ?reasoning_effort () =
    request_control_fields
      request_wire
      dialect
      ~enable_thinking:(Some true)
      ~preserve_thinking:None
      ~thinking_budget:None
      ~reasoning_effort
      ()
  in
  let reasoning_effort_dialect = dialect Capabilities.Reasoning_effort in
  let thinking_object_dialect = dialect Capabilities.Thinking_object in
  request Chat_completions reasoning_effort_dialect ()
  = Ok { fields = []; explicit_enable_receipt = Explicit_enable_not_encoded }
  && request
       Responses
       reasoning_effort_dialect
       ~reasoning_effort:Reasoning_effort.Medium
       ()
     = Ok
         { fields = [ "reasoning", `Assoc [ "effort", `String "medium" ] ]
         ; explicit_enable_receipt = Explicit_enable_encoded Request_control_field
         }
  && request
       Responses
       reasoning_effort_dialect
       ~reasoning_effort:Reasoning_effort.None_
       ()
     = Ok
         { fields = [ "reasoning", `Assoc [ "effort", `String "none" ] ]
         ; explicit_enable_receipt = Explicit_enable_not_encoded
         }
  && request Responses thinking_object_dialect ()
     = Ok { fields = []; explicit_enable_receipt = Explicit_enable_not_encoded }
;;

let%test "chat-template token receipt names its out-of-band wire encoding" =
  let dialect =
    of_capabilities
      { Capabilities.default_capabilities with
        supports_reasoning = true
      ; thinking_control_format = Capabilities.Chat_template_token "<THINK>"
      }
  in
  request_control_fields
    Chat_completions
    dialect
    ~enable_thinking:(Some true)
    ~preserve_thinking:None
    ~thinking_budget:None
    ~reasoning_effort:None
    ()
  = Ok
      { fields = []
      ; explicit_enable_receipt = Explicit_enable_encoded Chat_template_system_token
      }
;;

let%test "unrelated output field cannot satisfy explicit enable receipt" =
  let dialect =
    of_capabilities
      { Capabilities.default_capabilities with
        supports_reasoning = true
      ; thinking_control_format = Capabilities.Ollama_think
      ; reasoning_output_format = Capabilities.Split_reasoning_fields
      }
  in
  request_control_fields
    Chat_completions
    dialect
    ~enable_thinking:(Some true)
    ~preserve_thinking:None
    ~thinking_budget:None
    ~reasoning_effort:None
    ()
  = Ok
      { fields = [ "reasoning_split", `Bool true ]
      ; explicit_enable_receipt = Explicit_enable_not_encoded
      }
;;
