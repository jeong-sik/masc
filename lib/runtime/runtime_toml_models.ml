open Runtime_toml_base
open Runtime_toml_providers

(* --- Layer 2: Models --- *)

let thinking_control_token_key = "thinking-control-token"

let exact_non_empty_string_opt_field ~(path : string) (tbl : Otoml.t) (key : string)
  : (string option, parse_error list) result
  =
  match typed_find "a string" path tbl key Otoml.get_string with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) when String.trim value = "" ->
    Error (error (path ^ "." ^ key) (key ^ " must be non-empty"))
  | Ok (Some value) when value <> String.trim value ->
    Error (error (path ^ "." ^ key) (key ^ " must not have leading or trailing whitespace"))
  | Ok (Some value) -> Ok (Some value)
;;

let parse_thinking_control_format ~(path : string) ~(token : string option) (raw : string)
  : (Runtime_schema.thinking_control_format, parse_error list) result
  =
  (* Mirrors the AGENT_CORE catalog contract (agent-core boundary): [Chat_template_token]
     carries its token, so a chat-template-token declaration without a
     [thinking-control-token] key — or a blank/padded token, or a token on a
     non-token format — fails the load instead of detonating per request. *)
  let reject_orphan_token format =
    match token with
    | None -> Ok format
    | Some _ ->
      Error
        (error
           (path ^ "." ^ thinking_control_token_key)
           (Printf.sprintf
              "thinking-control-token is only valid with \
               thinking-control-format = \"chat-template-token\" (got %S)"
              raw))
  in
  match String.lowercase_ascii (String.trim raw) with
  | "" | "none" | "no-thinking-control" | "no_thinking_control" ->
    reject_orphan_token Runtime_schema.No_thinking_control
  | "thinking-object" | "thinking_object" ->
    reject_orphan_token Runtime_schema.Thinking_object
  | "thinking-object-adaptive" | "thinking_object_adaptive" ->
    reject_orphan_token Runtime_schema.Thinking_object_adaptive
  | "thinking-object-only" | "thinking_object_only" ->
    reject_orphan_token Runtime_schema.Thinking_object_only
  | "chat-template-kwargs" | "chat_template_kwargs" ->
    reject_orphan_token Runtime_schema.Chat_template_kwargs
  | "chat-template-token" | "chat_template_token" ->
    (match token with
     | Some t when String.trim t = t && t <> "" ->
       Ok (Runtime_schema.Chat_template_token t)
     | Some _ ->
       Error
         (error
            (path ^ "." ^ thinking_control_token_key)
            "thinking-control-token must be a non-empty string without \
             leading or trailing whitespace")
     | None ->
       Error
         (error
            (path ^ ".thinking-control-format")
            "chat-template-token requires a thinking-control-token key \
             naming the template token (e.g. \"<|think|>\")"))
  | "ollama-think" | "ollama_think" -> reject_orphan_token Runtime_schema.Ollama_think
  | "reasoning-effort" | "reasoning_effort" ->
    reject_orphan_token Runtime_schema.Reasoning_effort
  | "reasoning-effort-default-on" | "reasoning_effort_default_on" ->
    reject_orphan_token Runtime_schema.Reasoning_effort_default_on
  | "reasoning-enabled" | "reasoning_enabled" ->
    reject_orphan_token Runtime_schema.Reasoning_enabled
  | other ->
    (* Unknown enum members fail the load, mirroring how this parser already
       rejects unknown protocols / credential types. A silent downgrade to
       No_thinking_control hid config typos that disable thinking control for a
       model that needs it. *)
    Error
      (error
         (path ^ ".thinking-control-format")
         (Printf.sprintf
            "unknown thinking-control-format %S — expected one of \
             none|thinking-object|thinking-object-adaptive|thinking-object-only|chat-template-kwargs|chat-template-token|ollama-think|reasoning-effort|reasoning-effort-default-on"
            other))
;;

(* Keys under [models.*.capabilities] a released masc once read and no longer
   reads. Recognized rather than rejected so a capabilities table written by
   an older build does not refuse every save of the file (#45985); exact-name
   matching keeps the misspelt-key typo guard whole. The value is ignored. *)
let legacy_model_capability_keys = [ "supports-reasoning-budget" ]

let parse_model_capabilities ~(path : string) (tbl : Otoml.t)
  : (Runtime_schema.model_capabilities, parse_error list) result
  =
  let keys =
    [ "max-output-tokens"
    ; "thinking-control-format"
    ; thinking_control_token_key
    ; "anthropic-thinking-control"
    ; "accepted-reasoning-efforts"
    ; "reasoning-streaming-format"
    ; "supports-tool-choice"
    ; "supports-required-tool-choice"
    ; "supports-named-tool-choice"
    ; "supports-parallel-tool-calls"
    ; "supports-image-input"
    ; "supports-audio-input"
    ; "supports-video-input"
    ; "supports-multimodal-inputs"
    ; "supports-response-format-json"
    ; "supports-structured-output"
    ; "supports-system-prompt"
    ; "supports-assistant-prefill"
    ; "supports-prompt-caching"
    ; "supports-top-k"
    ; "supports-min-p"
    ; "supports-seed"
    ; "emits-usage-tokens"
    ]
  in
  let unknown_key_errors =
    match tbl with
    | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
      List.concat_map
        (fun (key, _) ->
           if List.mem key keys
           then []
           else if List.mem key legacy_model_capability_keys
           then []
           else
             error
               (path ^ "." ^ key)
               (Printf.sprintf
                  "unknown model capabilities key %S; expected %s"
                  key
                  (String.concat ", " keys)))
        entries
    | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTableArray _ -> error path "capabilities must be a TOML table"
  in
  let ( let* ) = Result.bind in
  let* () =
    match unknown_key_errors with
    | [] -> Ok ()
    | errors -> Error errors
  in
  (* Exact TOML presence: [None] is "the operator wrote nothing here", which
     each consumer resolves against the layer it owns. A [false] default here
     made an unwritten key indistinguishable from a written [false] (#37435). *)
  let b key = typed_find "a boolean" path tbl key Otoml.get_boolean in
  let reasoning_streaming_format_result =
    match typed_find "a string" path tbl "reasoning-streaming-format" Otoml.get_string with
    | Error errors -> Error errors
    | Ok None -> Ok None
    | Ok (Some raw) ->
      (match Llm_provider.Capability_vocab.reasoning_streaming_format_of_string raw with
       | Some format -> Ok (Some format)
       | None ->
         Error
           (error
              (path ^ ".reasoning-streaming-format")
              (Printf.sprintf
                 "unknown reasoning-streaming-format %S — expected %s"
                 raw
                 Llm_provider.Capability_vocab.reasoning_streaming_format_syntax)))
  in
  let anthropic_thinking_control_result =
    match typed_find "a string" path tbl "anthropic-thinking-control" Otoml.get_string with
    | Error errors -> Error errors
    | Ok None -> Ok None
    | Ok (Some raw) ->
      (* Both spellings, like the sibling thinking-control-format: the catalog
         vocabulary is underscore-joined, the dashboard projection is
         hyphen-joined, and either must round-trip through this parser. *)
      let normalized = String.map (fun c -> if Char.equal c '-' then '_' else c) raw in
      (match Llm_provider.Capability_vocab.anthropic_thinking_control_of_string normalized with
       | Some policy ->
         Ok (Some (Llm_provider.Capabilities.anthropic_thinking_control_of_vocab_value policy))
       | None ->
         Error
           (error
              (path ^ ".anthropic-thinking-control")
              (Printf.sprintf
                 "unknown anthropic-thinking-control %S — expected %s"
                 raw
                 (String.concat
                    "|"
                    Llm_provider.Capability_vocab.anthropic_thinking_control_values))))
  in
  let positive_int_opt_field key =
    match typed_find "an integer" path tbl key Otoml.get_integer with
    | Error _ as error -> error
    | Ok None -> Ok None
    | Ok (Some n) when n > 0 -> Ok (Some n)
    | Ok (Some n) ->
      Log.Runtime.warn "runtime_toml: %s.capabilities.%s = %d — expected positive integer, ignoring"
          path
          key
          n;
      Ok None
  in
  let thinking_control_format_result =
    match
      ( typed_find "a string" path tbl "thinking-control-format" Otoml.get_string
      , exact_non_empty_string_opt_field ~path tbl thinking_control_token_key )
    with
    | Error errs, _ | _, Error errs -> Error errs
    | Ok None, Ok token ->
      (match token with
       | None -> Ok Runtime_schema.No_thinking_control
       | Some _ ->
         Error
           (error
              (path ^ "." ^ thinking_control_token_key)
              "thinking-control-token requires thinking-control-format = \
               \"chat-template-token\""))
    | Ok (Some raw), Ok token -> parse_thinking_control_format ~path ~token raw
  in
  (* The efforts a categorical reasoning-effort wire accepts from this model,
     probed against the operator's own endpoint. The dispatch check refuses
     an effort until some layer declares this list, and the catalog cannot
     know an operator's gateway: without this key the refusal has no
     operator-side answer (2026-11-04, opencode_go deepseek-v4.1-flash). *)
  let accepted_reasoning_efforts_result =
    match Otoml.find_opt tbl Fun.id [ "accepted-reasoning-efforts" ] with
    | None -> Ok None
    | Some (Otoml.TomlArray entries) ->
      let efforts, errs =
        List.fold_left
          (fun (efforts, errs) entry ->
             match entry with
             | Otoml.TomlString value ->
               (match Llm_provider.Reasoning_effort.of_string value with
                | Some effort -> efforts @ [ effort ], errs
                | None ->
                  ( efforts
                  , errs
                    @ error
                        (path ^ ".accepted-reasoning-efforts")
                        (Printf.sprintf
                           "unknown reasoning effort %S — expected one of %s"
                           value
                           (String.concat
                              ", "
                              Llm_provider.Reasoning_effort.all_wire_values)) ))
             | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
             | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
             | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
             | Otoml.TomlArray _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _
             | Otoml.TomlTableArray _ ->
               ( efforts
               , errs
                 @ error
                     (path ^ ".accepted-reasoning-efforts")
                     "accepted-reasoning-efforts entries must be strings" ))
          ([], [])
          entries
      in
      (match efforts, errs with
       | [], [] -> Ok None
       | efforts, [] -> Ok (Some efforts)
       | _, errs -> Error errs)
    | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
    | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
    | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _)
    | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlTable _)
    | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) ->
      Error (error (path ^ ".accepted-reasoning-efforts") "accepted-reasoning-efforts must be an array of strings")
  in
  let* thinking_control_format = thinking_control_format_result in
  let* reasoning_streaming_format = reasoning_streaming_format_result in
  let* anthropic_thinking_control = anthropic_thinking_control_result in
  let* accepted_reasoning_efforts = accepted_reasoning_efforts_result in
  let* max_output_tokens = positive_int_opt_field "max-output-tokens" in
  let* supports_tool_choice = b "supports-tool-choice" in
  let* supports_required_tool_choice = b "supports-required-tool-choice" in
  let* supports_named_tool_choice = b "supports-named-tool-choice" in
  let* supports_parallel_tool_calls = b "supports-parallel-tool-calls" in
  let* supports_image_input = b "supports-image-input" in
  let* supports_audio_input = b "supports-audio-input" in
  let* supports_video_input = b "supports-video-input" in
  let* supports_multimodal_inputs = b "supports-multimodal-inputs" in
  let* supports_response_format_json = b "supports-response-format-json" in
  let* supports_structured_output = b "supports-structured-output" in
  let* supports_system_prompt = b "supports-system-prompt" in
  let* supports_assistant_prefill = b "supports-assistant-prefill" in
  let* supports_prompt_caching = b "supports-prompt-caching" in
  let* supports_top_k = b "supports-top-k" in
  let* supports_min_p = b "supports-min-p" in
  let* supports_seed = b "supports-seed" in
  let* emits_usage_tokens = b "emits-usage-tokens" in
  Ok
    { Runtime_schema.max_output_tokens
    ; supports_tool_choice
    ; supports_required_tool_choice
    ; supports_named_tool_choice
    ; supports_parallel_tool_calls
    ; thinking_control_format
    ; declared_thinking_control_format =
        (match Otoml.find_opt tbl Fun.id [ "thinking-control-format" ] with
         | None -> None
         | Some _ -> Some thinking_control_format)
    ; accepted_reasoning_efforts
    ; anthropic_thinking_control
    ; reasoning_streaming_format
    ; supports_image_input
    ; supports_audio_input
    ; supports_video_input
    ; supports_multimodal_inputs
    ; supports_response_format_json
    ; supports_structured_output
    ; supports_system_prompt
    ; supports_assistant_prefill
    ; supports_prompt_caching
    ; supports_top_k
    ; supports_min_p
    ; supports_seed
    ; emits_usage_tokens
    }
;;

(* LLM sampling temperature bounds. OpenAI/Kimi/DeepSeek accept [0.0, 2.0]; a
   value outside this range is a config error, not something to silently clamp.
   0.0 (greedy) is valid, so temperature is NOT parsed through the
   positive-float path. *)
let temperature_min = 0.0
let temperature_max = 2.0
let probability_min = 0.0
let probability_max = 1.0

let number_opt_field ~(path : string) ~(key : string) (tbl : Otoml.t)
  : (float option, parse_error list) result
  =
  match Otoml.find_opt tbl Fun.id [ key ] with
  | None -> Ok None
  | Some value ->
    let as_float =
      match value with
      | Otoml.TomlFloat v -> Some v
      | Otoml.TomlInteger v -> Some (float_of_int v)
      | Otoml.TomlString _ | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
      | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
      | Otoml.TomlArray _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ -> None
    in
    (match as_float with
     | None -> Error (error (path ^ "." ^ key) (key ^ " must be a number"))
     | Some value -> Ok (Some value))
;;

let bounded_number_opt_field
      ~(path : string)
      ~(key : string)
      ~(lower : float)
      ~(upper : float)
      (tbl : Otoml.t)
  : (float option, parse_error list) result
  =
  match number_opt_field ~path ~key tbl with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) when Float.is_finite value && value >= lower && value <= upper ->
    Ok (Some value)
  | Ok (Some value) ->
    Error
      (error
         (path ^ "." ^ key)
         (Printf.sprintf
            "%s must be a finite number in [%g, %g]; got %g"
            key
            lower
            upper
            value))
;;

(* Read the optional per-model [reasoning-effort]. Parsed into the typed
   effort at load time rather than carried as a string: an unknown value is
   an operator typo, and rejecting it here means no later consumer has to
   decide what an unparseable effort means. *)
let reasoning_effort_opt_field ~(path : string) (tbl : Otoml.t)
  : (Llm_provider.Reasoning_effort.t option, parse_error list) result
  =
  match typed_find "a string" path tbl "reasoning-effort" Otoml.get_string with
  | Error errors -> Error errors
  | Ok None -> Ok None
  | Ok (Some raw) ->
    (match Llm_provider.Reasoning_effort.of_string raw with
     | Some effort -> Ok (Some effort)
     | None ->
       Error
         [ { path
           ; message =
               Printf.sprintf
                 "reasoning-effort %S is not a known effort; expected one of %s"
                 raw
                 Llm_provider.Reasoning_effort.values_for_log
           }
         ])
;;

(* Read the optional per-model [turn-timeout-s]. Named distinctly from the
   antigravity provider key [timeout-s] because the two sit at different layers
   and the model value wins: an operator reading a config with both should be
   able to tell which one bounds the turn without consulting the resolver. *)
(* Unlike the other float fields, [0] is meaningful here rather than invalid:
   it declares that no deadline is installed, so the spawned client decides
   when its own turn ends. Absent stays distinct from [0] — absent keeps the
   adapter default, [0] removes the bound — so the two cannot be confused
   downstream. Negative and non-finite remain rejected. *)
let turn_timeout_opt_field ~(path : string) (tbl : Otoml.t)
  : (float option, parse_error list) result
  =
  match number_opt_field ~path ~key:"turn-timeout-s" tbl with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) when value >= 0.0 && Float.is_finite value -> Ok (Some value)
  | Ok (Some value) ->
    Error
      (error
         (path ^ ".turn-timeout-s")
         (Printf.sprintf
            "turn-timeout-s must be a non-negative finite number (0 removes \
             the deadline), got %g"
            value))
;;

(* Read the optional per-model [temperature]. A TOML integer (1) or float (1.0)
   both read as a float so an operator is not tripped by "1 vs 1.0". Absent →
   [Ok None] (caller keeps its fallback). Wrong type or out of
   [temperature_min, temperature_max] → parse error: reject at load rather than
   send an out-of-range value the provider would reject at request time. *)
let temperature_opt_field ~(path : string) (tbl : Otoml.t)
  : (float option, parse_error list) result
  =
  bounded_number_opt_field
    ~path
    ~key:"temperature"
    ~lower:temperature_min
    ~upper:temperature_max
    tbl
;;

let probability_opt_field ~(path : string) ~(key : string) (tbl : Otoml.t)
  : (float option, parse_error list) result
  =
  bounded_number_opt_field
    ~path
    ~key
    ~lower:probability_min
    ~upper:probability_max
    tbl
;;

let sampling_capability_errors
      ~(path : string)
      ~(capabilities : Runtime_schema.model_capabilities option)
      ~(top_k : int option)
      ~(min_p : float option)
  : parse_error list
  =
  match capabilities with
  | None -> []
  | Some capabilities ->
    (* A declaration-layer question: did the operator authorize this sampling
       field for this model? Not declared is not authorized, exactly as before
       #37435 — the wire's preset does not answer it, because the operator is
       the one asserting the model accepts the field. *)
    let sampling_error ~key ~declared =
      match declared with
      | Some true -> []
      | Some false ->
        error
          (path ^ "." ^ key)
          (Printf.sprintf "%s is set but %s.capabilities.supports-%s is false" key path key)
      | None ->
        error
          (path ^ "." ^ key)
          (Printf.sprintf
             "%s is set but %s.capabilities.supports-%s is not declared"
             key
             path
             key)
    in
    let top_k_errors =
      match top_k with
      | Some _ -> sampling_error ~key:"top-k" ~declared:capabilities.supports_top_k
      | None -> []
    in
    let min_p_errors =
      match min_p with
      | Some _ -> sampling_error ~key:"min-p" ~declared:capabilities.supports_min_p
      | None -> []
    in
    top_k_errors @ min_p_errors
;;

(* Every key [parse_model] reads. Any other key fails the load: a misspelt
   [tools_support = true] would otherwise load as a model without tool
   support and the keeper would run with an empty tool list. *)
let model_keys =
  [ "api-name"
  ; "model-name"
  ; "max-context"
  ; "tools-support"
  ; "thinking-support"
  ; "preserve-thinking"
  ; "streaming"
  ; "capabilities"
  ; "temperature"
  ; "top-p"
  ; "top-k"
  ; "min-p"
  ; "reasoning-effort"
  ; "reasoning-uncontrolled"
  ; "turn-timeout-s"
  ]
;;

(* Keys a released masc once read from [models.*] and no longer reads. They
   are recognized rather than rejected so an operator's file written by an
   older build still saves: a save revalidates the whole file, and one dead
   key anywhere in it would otherwise refuse every unrelated edit (#45985).
   Recognition is by exact name, not a prefix rule, so a genuinely misspelt
   key still fails the load with the "unknown key" the typo guard exists to
   give. The value is ignored -- the semantics moved to [max-context] in
   18b85e62df -- and [ignored_legacy_model_keys] says it was seen. *)
let legacy_model_keys = [ "max-prompt-bytes" ]

let model_unknown_key_errors ~path (tbl : Otoml.t) =
  match tbl with
  | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
    List.concat_map
      (fun (key, _) ->
         if List.mem key model_keys
         then []
         else if List.mem key legacy_model_keys
         then []
         else
           error
             (path ^ "." ^ key)
             (Printf.sprintf
                "unknown model key %S; expected one of %s"
                key
                (String.concat ", " model_keys)))
      entries
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlTableArray _ ->
    error path (Printf.sprintf "[%s] must be a TOML table" path)
;;

let parse_model (id : string) (tbl : Otoml.t)
  : (Runtime_schema.model_spec, parse_error list) result
  =
  let path = Ns.(path Models) id in
  match model_unknown_key_errors ~path tbl with
  | _ :: _ as errors -> Error errors
  | [] ->
  let api_name_result =
    match
      ( typed_find "a string" path tbl "api-name" Otoml.get_string
      , typed_find "a string" path tbl "model-name" Otoml.get_string )
    with
    | Error errors, _ | _, Error errors -> Error errors
    | Ok (Some name), Ok _ | Ok None, Ok (Some name) -> Ok name
    | Ok None, Ok None -> Ok id
  in
  (* [max-context] is an explicit operator override, not a required field: a
     runtime whose model is covered by the AGENT_CORE capability catalog can leave it
     unset and inherit the catalog's max-context (see
     [Runtime_instance.resolve_max_context_of_runtime]). An operator-supplied value
     must still be positive; [materialize_config] fail-closes at load time on
     a runtime that resolves neither source (RFC-0206 §2.1). *)
  let max_context_result = positive_int_opt_field ~path ~key:"max-context" tbl in
  (
    let tools_support_result =
      typed_find_or "a boolean" path tbl "tools-support" Otoml.get_boolean ~default:false
    in
    let thinking_support_result =
      typed_find "a boolean" path tbl "thinking-support" Otoml.get_boolean
    in
    let preserve_thinking_result =
      typed_find "a boolean" path tbl "preserve-thinking" Otoml.get_boolean
    in
    let streaming_result =
      typed_find_or "a boolean" path tbl "streaming" Otoml.get_boolean ~default:true
    in
    let capabilities_result =
      match Otoml.find_opt tbl Fun.id [ "capabilities" ] with
      | None -> Ok None
      | Some t ->
        Result.map Option.some (parse_model_capabilities ~path:(path ^ ".capabilities") t)
    in
    let temperature_result = temperature_opt_field ~path tbl in
    let top_p_result = probability_opt_field ~path ~key:"top-p" tbl in
    let top_k_result = positive_int_opt_field ~path ~key:"top-k" tbl in
    let min_p_result = probability_opt_field ~path ~key:"min-p" tbl in
    let reasoning_effort_result = reasoning_effort_opt_field ~path tbl in
    let reasoning_uncontrolled_result =
      typed_find_or
        "a boolean"
        path
        tbl
        "reasoning-uncontrolled"
        Otoml.get_boolean
        ~default:false
    in
    let turn_timeout_result = turn_timeout_opt_field ~path tbl in
    let ( let* ) = Result.bind in
    let* api_name = api_name_result in
    let* tools_support = tools_support_result in
    let* thinking_support = thinking_support_result in
    let* preserve_thinking = preserve_thinking_result in
    let* streaming = streaming_result in
    let* max_context = max_context_result in
    let* capabilities = capabilities_result in
    let* temperature = temperature_result in
    let* top_p = top_p_result in
    let* top_k = top_k_result in
    let* min_p = min_p_result in
    let* reasoning_effort = reasoning_effort_result in
    let* reasoning_uncontrolled = reasoning_uncontrolled_result in
    (* A row that names an effort and also says it sends no control asks for
       two different requests, and nothing downstream can honour both. Letting
       one silently win is how a lane ends up reasoning while the config reads
       as if it does not, which is the confusion this key exists to remove. *)
    let* () =
      match reasoning_effort, reasoning_uncontrolled with
      | Some _, true ->
        Error
          (error
             (path ^ ".reasoning-uncontrolled")
             "reasoning-uncontrolled cannot sit on a model that also declares \
              reasoning-effort: one sends the declared effort, the other sends \
              no control at all")
      | Some _, false | None, (true | false) -> Ok ()
    in
    let* turn_timeout_s = turn_timeout_result in
    match sampling_capability_errors ~path ~capabilities ~top_k ~min_p with
    | _ :: _ as errors -> Error errors
    | [] ->
      Ok
        { Runtime_schema.id
        ; api_name
        ; tools_support
        ; max_context
        ; thinking_support
        ; preserve_thinking
        ; streaming
        ; temperature
        ; top_p
        ; top_k
        ; min_p
        ; reasoning_effort
        ; reasoning_uncontrolled
        ; turn_timeout_s
        ; capabilities        })
;;

let parse_models (toml : Otoml.t)
  : (Runtime_schema.model_spec list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ Ns.(key Models) ] with
  | None -> Ok []
  | Some
      ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
      | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ) ->
    Error (error (Ns.(key Models)) "[models] must be a TOML table")
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    partition_results
      (List.map
         (fun (id, tbl) ->
            match
              validate_runtime_id_component
                ~allow_dot:true
                ~kind:"model"
                ~path:(Ns.(path Models) id)
                id
            with
            | Error _ as error -> error
            | Ok () -> parse_model id tbl)
         entries)
;;
