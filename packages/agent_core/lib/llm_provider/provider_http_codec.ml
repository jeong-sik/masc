type t =
  | Anthropic_messages
  | Openai_chat
  | Openai_responses
  | Ollama_chat
  | Gemini_generate_content
  | Glm_chat

type json_schema_wire =
  | Raw_schema
  | Openai_named_schema

let fingerprint_tag = function
  | Anthropic_messages -> "anthropic-messages"
  | Openai_chat -> "openai-chat"
  | Openai_responses -> "openai-responses"
  | Ollama_chat -> "ollama-chat"
  | Gemini_generate_content -> "gemini-generate-content"
  | Glm_chat -> "glm-chat"
;;

let json_schema_wire = function
  | Openai_chat | Openai_responses | Glm_chat -> Openai_named_schema
  | Anthropic_messages | Ollama_chat | Gemini_generate_content -> Raw_schema
;;

let supports_json_mode = function
  | Openai_chat | Openai_responses | Ollama_chat | Gemini_generate_content | Glm_chat ->
    true
  | Anthropic_messages -> false
;;

let of_config (config : Provider_config.t) =
  (* [kind] owns the wire contract. In particular, Kimi remains Anthropic
     Messages through custom proxy paths; callers targeting Kimi's OpenAI-
     compatible endpoint must declare [OpenAI_compat]. The only path-selected
     sub-protocol is the validated OpenAI Responses endpoint. *)
  match config.kind with
  | Provider_config.Anthropic | Provider_config.Kimi -> Anthropic_messages
  | Provider_config.OpenAI_compat
    when Provider_config.request_path_targets_responses_api config.request_path ->
    Openai_responses
  | Provider_config.OpenAI_compat | Provider_config.DashScope -> Openai_chat
  | Provider_config.Ollama -> Ollama_chat
  | Provider_config.Gemini -> Gemini_generate_content
  | Provider_config.Glm -> Glm_chat
;;

let%test "kind owns codec; path and model strings do not infer it" =
  let codec ?request_path ~kind ~model_id () =
    Provider_config.make ?request_path ~kind ~model_id ~base_url:"https://example.test" ()
    |> of_config
  in
  let cases =
    [ ( codec ~kind:Provider_config.Anthropic ~model_id:"model" ()
      , Anthropic_messages
      , false
      , Raw_schema )
    ; ( codec
          ~request_path:"/v1/chat/completions"
          ~kind:Provider_config.Kimi
          ~model_id:"kimi-for-coding"
          ()
      , Anthropic_messages
      , false
      , Raw_schema )
    ; ( codec ~kind:Provider_config.OpenAI_compat ~model_id:"kimi-for-coding" ()
      , Openai_chat
      , true
      , Openai_named_schema )
    ; ( codec
          ~request_path:"/v1/responses"
          ~kind:Provider_config.OpenAI_compat
          ~model_id:"model"
          ()
      , Openai_responses
      , true
      , Openai_named_schema )
    ; ( codec ~kind:Provider_config.Ollama ~model_id:"model" ()
      , Ollama_chat
      , true
      , Raw_schema )
    ; ( codec ~kind:Provider_config.Gemini ~model_id:"model" ()
      , Gemini_generate_content
      , true
      , Raw_schema )
    ; ( codec ~kind:Provider_config.Glm ~model_id:"model" ()
      , Glm_chat
      , true
      , Openai_named_schema )
    ; ( codec ~kind:Provider_config.DashScope ~model_id:"model" ()
      , Openai_chat
      , true
      , Openai_named_schema )
    ]
  in
  List.for_all
    (fun (actual, expected, json_mode, schema_wire) ->
       actual = expected
       && Bool.equal (supports_json_mode actual) json_mode
       && json_schema_wire actual = schema_wire)
    cases
;;
