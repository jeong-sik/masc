open Alcotest
open Llm_provider

let contains ~needle text =
  let needle_len = String.length needle in
  let text_len = String.length text in
  let rec loop idx =
    if idx + needle_len > text_len
    then false
    else if String.sub text idx needle_len = needle
    then true
    else loop (idx + 1)
  in
  needle_len = 0 || loop 0
;;

let catalog_of_string text =
  match Provider_catalog.of_json (Yojson.Safe.from_string text) with
  | Ok catalog -> catalog
  | Error msg -> fail msg
;;

let provider_with_connection_defaults = function
  | `Assoc fields ->
    let add_default name value fields =
      if List.exists (fun (field, _) -> String.equal field name) fields
      then fields
      else (name, `String value) :: fields
    in
    fields
    |> add_default "base_url" "https://provider.test/v1"
    |> add_default "request_path" "/v1/chat/completions"
    |> fun fields -> `Assoc fields
  | other -> other
;;

let catalog_with_provider provider =
  let provider = provider_with_connection_defaults provider in
  `Assoc [ "schema_version", `Int 1; "providers", `List [ provider ] ]
;;

let require_rejected ?(needle = "") label json =
  match Provider_catalog.of_json json with
  | Error message -> check bool (label ^ " error") true (contains ~needle message)
  | Ok _ -> failf "%s must be rejected" label
;;

let require_lookup catalog id =
  match Provider_catalog.lookup catalog id with
  | Some entry -> entry
  | None -> failf "expected catalog entry %S" id
;;

let valid_typed_entry
      ?(id = "typed-provider")
      ?(aliases = [])
      ?(kind = Provider_config.OpenAI_compat)
      ?(base_url = "https://provider.test/v1")
      ?(request_path = "/v1/chat/completions")
      ?(api_key_env = "")
      ?(auth = Provider_catalog.No_auth)
      ?(default_model = None)
      ?(max_context = None)
      ?(capabilities = Capabilities.default_capabilities)
      ?(credential_scope = None)
      ()
  =
  { Provider_catalog.id
  ; aliases
  ; kind
  ; base_url
  ; request_path
  ; api_key_env
  ; auth
  ; default_model
  ; max_context
  ; capabilities
  ; credential_scope
  }
;;

let require_typed_rejected ~needle label entries =
  match Provider_catalog.of_entries entries with
  | Error message -> check bool (label ^ " error") true (contains ~needle message)
  | Ok _ -> failf "%s must be rejected by Provider_catalog.of_entries" label
;;

let test_full_entry_parses_auth_and_capabilities () =
  let catalog =
    catalog_of_string
      {|{
        "schema_version": 1,
        "providers": [
          {
            "id": "rich-http",
            "aliases": ["Alias", "second"],
            "kind": "openai_compat",
            "base_url": "https://rich.example/v1",
            "request_path": "/chat/completions",
            "default_model": "rich-model",
            "credential_scope": "workspace",
            "auth": {"type": "setup_token_env", "env": "SETUP_TOKEN"},
            "max_context": 32000,
            "capabilities_base": "openai_chat",
            "capabilities": {
              "max_context_tokens": 64000,
              "max_output_tokens": 4096,
              "supports_tools": true,
              "supports_tool_choice": true,
              "supports_parallel_tool_calls": true,
              "supports_reasoning": true,
              "supports_extended_thinking": true,
              "supports_reasoning_budget": true,
              "supports_response_format_json": true,
              "supports_structured_output": true,
              "supports_multimodal_inputs": true,
              "supports_image_input": true,
              "supports_audio_input": true,
              "supports_video_input": true,
              "supports_native_streaming": true,
              "supports_system_prompt": false,
              "supports_caching": true,
              "supports_prompt_caching": true,
              "prompt_cache_alignment": 128,
              "supports_top_k": true,
              "supports_min_p": true,
              "supports_seed": true,
              "supports_seed_with_images": true,
              "ignored_sampling_parameters": ["temperature", "top_p"],
              "supports_computer_use": true,
              "supports_code_execution": true,
              "emits_usage_tokens": true,
              "thinking_control_format": "chat_template_kwargs",
              "accepted_reasoning_efforts": ["low", "high"],
              "modality_priority": "visual_first",
              "reasoning_replay": "preserve_always",
              "supported_models": ["rich-model", "rich-fast"]
            }
          }
        ]
      }|}
  in
  let rich = require_lookup catalog "alias" in
  check string "id" "rich-http" rich.id;
  check (list string) "aliases" [ "Alias"; "second" ] rich.aliases;
  check bool "setup auth" true (rich.auth = Provider_catalog.Setup_token_env "SETUP_TOKEN");
  check string "api key from setup auth" "SETUP_TOKEN" rich.api_key_env;
  check (option string) "default model" (Some "rich-model") rich.default_model;
  check (option int) "explicit max context" (Some 32000) rich.max_context;
  check (option string) "credential scope" (Some "workspace") rich.credential_scope;
  let caps = rich.capabilities in
  check (option int) "cap max context" (Some 64000) caps.max_context_tokens;
  check (option int) "cap max output" (Some 4096) caps.max_output_tokens;
  check bool "supports tools" true caps.supports_tools;
  check bool "supports tool choice" true caps.supports_tool_choice;
  check bool "supports parallel calls" true caps.supports_parallel_tool_calls;
  check bool "reasoning" true caps.supports_reasoning;
  check bool "extended thinking" true caps.supports_extended_thinking;
  check bool "reasoning budget" true caps.supports_reasoning_budget;
  check bool "json response" true caps.supports_response_format_json;
  check bool "structured output" true caps.supports_structured_output;
  check bool "multimodal" true caps.supports_multimodal_inputs;
  check bool "image" true caps.supports_image_input;
  check bool "audio" true caps.supports_audio_input;
  check bool "video" true caps.supports_video_input;
  check bool "native streaming" true caps.supports_native_streaming;
  check bool "system prompt override" false caps.supports_system_prompt;
  check bool "caching" true caps.supports_caching;
  check bool "prompt caching" true caps.supports_prompt_caching;
  check (option int) "cache alignment" (Some 128) caps.prompt_cache_alignment;
  check bool "top k" true caps.supports_top_k;
  check bool "min p" true caps.supports_min_p;
  check bool "seed" true caps.supports_seed;
  check bool "seed images" true caps.supports_seed_with_images;
  check
    (list string)
    "ignored sampling"
    [ "temperature"; "top_p" ]
    (List.map Capabilities.sampling_parameter_to_string caps.ignored_sampling_parameters);
  check bool "computer use" true caps.supports_computer_use;
  check bool "code execution" true caps.supports_code_execution;
  check bool "usage tokens" true caps.emits_usage_tokens;
  check
    (option (list string))
    "accepted reasoning efforts"
    (Some [ "low"; "high" ])
    (Option.map (List.map Reasoning_effort.to_string) caps.accepted_reasoning_efforts);
  check bool "visual first" true (caps.modality_priority = Modality.Visual_first);
  check
    bool
    "thinking format"
    true
    (caps.thinking_control_format = Capabilities.Chat_template_kwargs);
  check
    bool
    "reasoning replay"
    true
    (caps.reasoning_replay_override = Capabilities.Force_preserve_always);
  check
    (option (list string))
    "supported models"
    (Some [ "rich-model"; "rich-fast" ])
    caps.supported_models;
  check
    (option string)
    "default model helper"
    (Some "rich-model")
    (Provider_catalog.default_model_for_provider catalog "rich-http")
;;

let test_present_type_mismatches_are_rejected () =
  let entry_field_cases =
    [ "kind", `Int 42
    ; "aliases", `String "not-array"
    ; "base_url", `Bool true
    ; "request_path", `List []
    ; "default_model", `Int 2
    ; "max_context", `String "many"
    ; "capabilities_base", `Bool false
    ; "credential_scope", `Int 3
    ]
  in
  List.iter
    (fun (field, value) ->
       require_rejected
         ~needle:field
         ("entry " ^ field ^ " type")
         (catalog_with_provider
            (`Assoc [ "id", `String ("typed-" ^ field); field, value ])))
    entry_field_cases;
  let capability_cases =
    [ "supports_tools", `String "yes"
    ; "max_output_tokens", `String "many"
    ; "supported_models", `String "single"
    ; "accepted_reasoning_efforts", `Bool true
    ; "ignored_sampling_parameters", `Int 4
    ; "thinking_control_format", `Bool false
    ]
  in
  List.iter
    (fun (field, value) ->
       require_rejected
         ~needle:field
         ("capability " ^ field ^ " type")
         (catalog_with_provider
            (`Assoc
                [ "id", `String ("typed-cap-" ^ field)
                ; "capabilities", `Assoc [ field, value ]
                ])))
    capability_cases
;;

let test_auth_shape_contract () =
  let catalog_json =
    `Assoc
      [ "schema_version", `Int 1
      ; ( "providers"
        , `List
            [ provider_with_connection_defaults (`Assoc [ "id", `String "absent-auth" ])
            ; provider_with_connection_defaults
                (`Assoc [ "id", `String "null-auth"; "auth", `Null ])
            ] )
      ]
  in
  let catalog =
    match Provider_catalog.of_json catalog_json with
    | Ok catalog -> catalog
    | Error message -> fail message
  in
  let absent = require_lookup catalog "absent-auth" in
  let null = require_lookup catalog "null-auth" in
  check bool "absent auth is no_auth" true (absent.auth = Provider_catalog.No_auth);
  check bool "null auth is no_auth" true (null.auth = Provider_catalog.No_auth);
  let malformed_shapes : (string * Yojson.Safe.t) list =
    [ "boolean", `Bool false
    ; "integer", `Int 17
    ; "integer literal", `Intlit "17"
    ; "float", `Float 1.0
    ; "string", `String "none"
    ; "array", `List []
    ]
  in
  List.iter
    (fun (label, auth) ->
       let result =
         Provider_catalog.of_json
           (`Assoc
               [ "schema_version", `Int 1
               ; ( "providers"
                 , `List
                     [ provider_with_connection_defaults
                         (`Assoc [ "id", `String ("malformed-" ^ label); "auth", auth ])
                     ] )
               ])
       in
       match result with
       | Error message ->
         check
           bool
           (label ^ " error identifies auth")
           true
           (contains ~needle:"auth" message)
       | Ok _ -> failf "%s auth shape must be rejected" label)
    malformed_shapes
;;

let test_closed_object_contract () =
  require_rejected
    ~needle:"entry expected object"
    "provider entry object"
    (`Assoc [ "schema_version", `Int 1; "providers", `List [ `String "provider" ] ]);
  require_rejected
    ~needle:"unknown field"
    "root unknown field"
    (`Assoc [ "schema_version", `Int 1; "providers", `List []; "future", `Bool true ]);
  require_rejected
    ~needle:"duplicate field"
    "root duplicate field"
    (`Assoc [ "schema_version", `Int 1; "schema_version", `Int 1; "providers", `List [] ]);
  require_rejected
    ~needle:"unknown field"
    "entry unknown field"
    (catalog_with_provider
       (`Assoc [ "id", `String "unknown-entry"; "future", `Bool true ]));
  require_rejected
    ~needle:"duplicate field"
    "entry duplicate field"
    (catalog_with_provider
       (`Assoc [ "id", `String "duplicate-entry"; "id", `String "duplicate-entry" ]));
  require_rejected
    ~needle:"unknown field"
    "auth unknown field"
    (catalog_with_provider
       (`Assoc
           [ "id", `String "unknown-auth"
           ; "auth", `Assoc [ "type", `String "none"; "future", `Bool true ]
           ]));
  require_rejected
    ~needle:"duplicate field"
    "auth duplicate field"
    (catalog_with_provider
       (`Assoc
           [ "id", `String "duplicate-auth"
           ; "auth", `Assoc [ "type", `String "none"; "type", `String "none" ]
           ]));
  require_rejected
    ~needle:"unknown field"
    "capabilities unknown field"
    (catalog_with_provider
       (`Assoc
           [ "id", `String "unknown-capability"
           ; "capabilities", `Assoc [ "future", `Bool true ]
           ]));
  require_rejected
    ~needle:"duplicate field"
    "capabilities duplicate field"
    (catalog_with_provider
       (`Assoc
           [ "id", `String "duplicate-capability"
           ; ( "capabilities"
             , `Assoc [ "supports_tools", `Bool true; "supports_tools", `Bool true ] )
           ]));
  require_rejected
    ~needle:"capabilities expected object"
    "capabilities array shape"
    (catalog_with_provider
       (`Assoc [ "id", `String "array-capability"; "capabilities", `List [] ]));
  require_rejected
    ~needle:"unknown field"
    "capability override outside nested object"
    (catalog_with_provider
       (`Assoc [ "id", `String "top-level-capability"; "supports_tools", `Bool true ]))
;;

let test_values_fail_closed_without_coercion () =
  let reject_entry field value label needle =
    require_rejected
      ~needle
      label
      (catalog_with_provider (`Assoc [ "id", `String label; field, value ]))
  in
  reject_entry
    "max_context"
    (`Intlit "9223372036854775807999")
    "entry integer overflow"
    "out of range";
  reject_entry "max_context" (`Int 0) "entry zero integer" "positive integer";
  reject_entry "max_context" (`Int (-1)) "entry negative integer" "positive integer";
  let reject_capability field value label needle =
    require_rejected
      ~needle
      label
      (catalog_with_provider
         (`Assoc [ "id", `String label; "capabilities", `Assoc [ field, value ] ]))
  in
  reject_capability
    "max_output_tokens"
    (`Intlit "9223372036854775807999")
    "capability integer overflow"
    "out of range";
  reject_capability
    "prompt_cache_alignment"
    (`Int 0)
    "capability zero integer"
    "positive integer";
  reject_entry "aliases" (`List [ `String "" ]) "empty alias item" "must not be empty";
  reject_entry
    "aliases"
    (`List [ `String " padded" ])
    "padded alias item"
    "leading or trailing whitespace";
  reject_entry "aliases" (`List [ `Int 1 ]) "non-string alias item" "expected string";
  reject_capability
    "supported_models"
    (`List [ `String "" ])
    "empty supported model item"
    "must not be empty";
  reject_capability
    "accepted_reasoning_efforts"
    (`List [ `String "" ])
    "empty reasoning effort item"
    "must not be empty";
  reject_capability
    "ignored_sampling_parameters"
    (`List [ `Bool true ])
    "non-string sampling item"
    "expected string";
  require_rejected
    ~needle:"requires non-empty"
    "auth env is required"
    (catalog_with_provider
       (`Assoc
           [ "id", `String "missing-env"
           ; "auth", `Assoc [ "type", `String "api_key_env" ]
           ]));
  require_rejected
    ~needle:"does not accept"
    "unused auth env is rejected"
    (catalog_with_provider
       (`Assoc
           [ "id", `String "unused-env"
           ; "auth", `Assoc [ "type", `String "none"; "env", `String "UNUSED" ]
           ]));
  require_rejected
    ~needle:"require supports_tool_choice=true"
    "contradictory named tool choice"
    (catalog_with_provider
       (`Assoc
           [ "id", `String "contradictory-tools"
           ; ( "capabilities"
             , `Assoc
                 [ "supports_tool_choice", `Bool false
                 ; "supports_named_tool_choice", `Bool true
                 ] )
           ]))
;;

let test_null_optional_fields_use_declared_defaults () =
  let entry =
    catalog_of_string
      {|{
        "schema_version": 1,
        "providers": [{
          "id": "null-defaults",
          "aliases": null,
          "kind": null,
          "base_url": "https://provider.test/v1",
          "request_path": "/v1/chat/completions",
          "auth": null,
          "default_model": null,
          "max_context": null,
          "capabilities_base": null,
          "capabilities": null,
          "credential_scope": null
        }]
      }|}
    |> fun catalog -> require_lookup catalog "null-defaults"
  in
  check bool "default kind" true (entry.kind = Provider_config.OpenAI_compat);
  check (list string) "default aliases" [] entry.aliases;
  check bool "default auth" true (entry.auth = Provider_catalog.No_auth);
  check bool "default capabilities" false entry.capabilities.supports_tools
;;

let test_auth_and_thinking_canonical_matrix () =
  let catalog =
    catalog_of_string
      {|{
        "schema_version": 1,
        "providers": [
          {
            "id": "http-none",
            "kind": "openai_compat",
            "base_url": "https://provider.test/v1",
            "request_path": "/v1/chat/completions",
            "auth": {"type": "none"},
            "capabilities": {
              "thinking_control_format": "none",
              "preserve_thinking_control_format": "always_preserved"
            }
          },
          {
            "id": "cli-env",
            "kind": "openai_compat",
            "base_url": "https://provider.test/v1",
            "request_path": "/v1/chat/completions",
            "auth": {"type": "api_key_env", "env": "ENV_KEY"},
            "capabilities": {"thinking_control_format": "thinking_object"}
          },
      {
            "id": "http-direct",
            "kind": "openai_compat",
            "base_url": "https://provider.test/v1",
            "request_path": "/v1/chat/completions",
            "auth": {"type": "api_key_env", "env": "SHORT_ENV"},
            "capabilities": {"thinking_control_format": "thinking_object_only"}
          },
          {
            "id": "reasoning",
            "kind": "openai_compat",
            "base_url": "https://provider.test/v1",
            "request_path": "/v1/chat/completions",
            "auth": {"type": "api_key_env", "env": "REASON_KEY"},
            "capabilities": {"thinking_control_format": "reasoning_effort"}
          },
          {
            "id": "ollama-think",
            "kind": "ollama",
            "base_url": "http://127.0.0.1:11434",
            "request_path": "/api/chat",
            "capabilities": {"thinking_control_format": "ollama_think"}
          },
          {
            "id": "enable",
            "kind": "openai_compat",
            "base_url": "https://provider.test/v1",
            "request_path": "/v1/chat/completions",
            "auth": {"type": "api_key_env", "env": "ENABLE_KEY"},
            "capabilities": {"thinking_control_format": "enable_thinking"}
          },
          {
            "id": "template-token",
            "kind": "ollama",
            "base_url": "http://127.0.0.1:11434",
            "request_path": "/api/chat",
            "capabilities": {"thinking_control_format": "chat_template_token", "thinking_control_token": "<|think|>"}
          },
          {
            "id": "base-entry",
            "kind": "openai_compat",
            "base_url": "https://provider.test/v1",
            "request_path": "/v1/chat/completions",
            "capabilities_base": "openai_chat",
            "max_context": 128000,
            "capabilities": {
              "prompt_cache_alignment": 128
            }
          }
        ]
      }|}
  in
  let http_none = require_lookup catalog "http-none" in
  check bool "none auth" true (http_none.auth = Provider_catalog.No_auth);
  check
    bool
    "none thinking format"
    true
    (http_none.capabilities.thinking_control_format = Capabilities.No_thinking_control);
  check
    bool
    "always preserved format"
    true
    (http_none.capabilities.preserve_thinking_control_format
     = Capabilities.Always_preserved_thinking);
  let cli_env = require_lookup catalog "cli-env" in
  check bool "api key auth" true (cli_env.auth = Provider_catalog.Api_key_env "ENV_KEY");
  check
    bool
    "thinking object"
    true
    (cli_env.capabilities.thinking_control_format = Capabilities.Thinking_object);
  let compat = require_lookup catalog "http-direct" in
  check bool "env auth" true (compat.auth = Provider_catalog.Api_key_env "SHORT_ENV");
  check
    bool
    "thinking object only"
    true
    (compat.capabilities.thinking_control_format = Capabilities.Thinking_object_only);
  let reasoning = require_lookup catalog "reasoning" in
  check
    bool
    "reasoning effort"
    true
    (reasoning.capabilities.thinking_control_format = Capabilities.Reasoning_effort);
  let ollama_think = require_lookup catalog "ollama-think" in
  check
    bool
    "ollama think"
    true
    (ollama_think.capabilities.thinking_control_format = Capabilities.Ollama_think);
  let enable = require_lookup catalog "enable" in
  check bool "enable env" true (enable.auth = Provider_catalog.Api_key_env "ENABLE_KEY");
  check
    bool
    "enable thinking"
    true
    (enable.capabilities.thinking_control_format = Capabilities.Enable_thinking);
  let template_token = require_lookup catalog "template-token" in
  check
    bool
    "template token thinking"
    true
    (template_token.capabilities.thinking_control_format
     = Capabilities.Chat_template_token "<|think|>");
  let base = require_lookup catalog "base-entry" in
  check bool "capabilities_base supports tools" true base.capabilities.supports_tools;
  check
    (option int)
    "prompt alignment"
    (Some 128)
    base.capabilities.prompt_cache_alignment;
  check int "catalog size" 8 (Provider_catalog.entries catalog |> List.length)
;;

let test_removed_catalog_fields_and_aliases_are_rejected () =
  let assert_reject label json_text needle =
    match Provider_catalog.of_json (Yojson.Safe.from_string json_text) with
    | Error msg -> check bool label true (contains ~needle msg)
    | Ok _ -> failf "%s should be rejected" label
  in
  assert_reject
    "transport field rejected"
    {|{"schema_version":1,"providers":[{"id":"p","transport":"http"}]}|}
    "unknown field \"transport\"";
  assert_reject
    "command field rejected"
    {|{"schema_version":1,"providers":[{"id":"p","command":"tool-a"}]}|}
    "unknown field \"command\"";
  assert_reject
    "top-level api_key_env rejected"
    {|{"schema_version":1,"providers":[{"id":"p","api_key_env":"LEGACY_KEY"}]}|}
    "removed provider catalog field";
  assert_reject
    "top-level api_key_env null rejected"
    {|{"schema_version":1,"providers":[{"id":"p","api_key_env":null}]}|}
    "removed provider catalog field";
  assert_reject
    "auth key rejected"
    {|{"schema_version":1,"providers":[{"id":"p","auth":{"type":"api_key_env","key":"LEGACY_KEY"}}]}|}
    "removed provider catalog auth field";
  assert_reject
    "capability base alias rejected"
    {|{"schema_version":1,"providers":[{"id":"p","base":"openai_chat"}]}|}
    "removed provider catalog field \"base\"";
  assert_reject
    "auth alias rejected"
    {|{"schema_version":1,"providers":[{"id":"p","auth":{"type":"api-key-env","env":"K"}}]}|}
    "unknown auth type";
  assert_reject
    "thinking alias rejected"
    {|{"schema_version":1,"providers":[{"id":"p","capabilities":{"thinking_control_format":"thinking-object"}}]}|}
    "unknown thinking_control_format";
  assert_reject
    "chat template token without token rejected"
    {|{"schema_version":1,"providers":[{"id":"p","capabilities":{"thinking_control_format":"chat_template_token"}}]}|}
    "thinking_control_token";
  assert_reject
    "thinking token without chat template format rejected"
    {|{"schema_version":1,"providers":[{"id":"p","capabilities":{"thinking_control_token":"<|think|>"}}]}|}
    "thinking_control_token is only valid";
  assert_reject
    "padded thinking token rejected"
    {|{"schema_version":1,"providers":[{"id":"p","capabilities":{"thinking_control_format":"chat_template_token","thinking_control_token":" <|think|> "}}]}|}
    "leading or trailing whitespace";
  assert_reject
    "reasoning replay alias rejected"
    {|{"schema_version":1,"providers":[{"id":"p","capabilities":{"reasoning_replay":"preserve-allways"}}]}|}
    "unknown reasoning_replay";
  assert_reject
    "reasoning replay type rejected"
    {|{"schema_version":1,"providers":[{"id":"p","capabilities":{"reasoning_replay":true}}]}|}
    "expected string";
  assert_reject
    "accepted reasoning effort rejected"
    {|{"schema_version":1,"providers":[{"id":"p","capabilities":{"accepted_reasoning_efforts":["low","turbo"]}}]}|}
    "unknown accepted_reasoning_efforts";
  assert_reject
    "ignored sampling parameter rejected"
    {|{"schema_version":1,"providers":[{"id":"p","capabilities":{"ignored_sampling_parameters":["temp"]}}]}|}
    "unknown ignored_sampling_parameters";
  assert_reject
    "modality priority rejected"
    {|{"schema_version":1,"providers":[{"id":"p","capabilities":{"modality_priority":"image_only"}}]}|}
    "unknown modality_priority";
  assert_reject
    "removed runtime MCP capability rejected"
    {|{"schema_version":1,"providers":[{"id":"p","capabilities":{"supports_runtime_mcp_tools":true}}]}|}
    "removed provider catalog capability";
  assert_reject
    "removed runtime tool-event capability rejected"
    {|{"schema_version":1,"providers":[{"id":"p","capabilities":{"supports_runtime_tool_events":true}}]}|}
    "removed provider catalog capability"
;;

let test_catalog_root_shape_is_explicit () =
  let rejected label json expected =
    match Provider_catalog.of_json (Yojson.Safe.from_string json) with
    | Error message -> check bool label true (contains ~needle:expected message)
    | Ok _ -> failf "%s must be rejected" label
  in
  rejected
    "providers object"
    {|{"schema_version": 1, "providers": {}}|}
    "providers expected array";
  rejected "providers missing" {|{"schema_version": 1}|} "providers expected array";
  rejected
    "schema version type"
    {|{"schema_version": "1", "providers": []}|}
    "schema_version expected int";
  rejected "catalog root" {|[]|} "catalog expected object";
  let empty = catalog_of_string {|{"schema_version": 1, "providers": []}|} in
  check int "explicit empty catalog" 0 (Provider_catalog.entries empty |> List.length)
;;

let test_catalog_identities_are_unique () =
  let reject label providers =
    let providers = List.map provider_with_connection_defaults providers in
    require_rejected
      ~needle:"declared by both"
      label
      (`Assoc [ "schema_version", `Int 1; "providers", `List providers ])
  in
  reject
    "duplicate provider ids"
    [ `Assoc [ "id", `String "Alpha" ]; `Assoc [ "id", `String "alpha" ] ];
  reject
    "provider alias collides with id"
    [ `Assoc [ "id", `String "first"; "aliases", `List [ `String "shared" ] ]
    ; `Assoc [ "id", `String "SHARED" ]
    ];
  reject
    "provider aliases collide"
    [ `Assoc [ "id", `String "first"; "aliases", `List [ `String "shared" ] ]
    ; `Assoc [ "id", `String "second"; "aliases", `List [ `String "SHARED" ] ]
    ]
;;

let test_typed_entries_accept_a_complete_valid_contract () =
  let capabilities =
    { Capabilities.default_capabilities with
      max_context_tokens = Some 32_000
    ; max_output_tokens = Some 4_096
    ; prompt_cache_alignment = Some 128
    ; supported_models = Some [ "typed-model"; "typed-fast" ]
    }
  in
  let primary =
    valid_typed_entry
      ~id:"typed-primary"
      ~aliases:[ "typed-alias" ]
      ~api_key_env:"TYPED_PROVIDER_KEY"
      ~auth:(Provider_catalog.Api_key_env "TYPED_PROVIDER_KEY")
      ~default_model:(Some "typed-model")
      ~max_context:(Some 32_000)
      ~capabilities
      ~credential_scope:(Some "workspace")
      ()
  in
  let secondary = valid_typed_entry ~id:"typed-secondary" () in
  let gemini =
    valid_typed_entry ~id:"typed-gemini" ~kind:Provider_config.Gemini ~request_path:"" ()
  in
  match Provider_catalog.of_entries [ primary; secondary; gemini ] with
  | Error message -> failf "valid typed entries must be accepted: %s" message
  | Ok catalog ->
    check int "typed catalog size" 3 (Provider_catalog.entries catalog |> List.length);
    check
      (option string)
      "typed alias resolves canonical provider"
      (Some "typed-primary")
      (Provider_catalog.lookup catalog "TYPED-ALIAS"
       |> Option.map (fun (entry : Provider_catalog.entry) -> entry.id))
;;

let test_typed_entries_fail_closed () =
  let reject ~needle label entry = require_typed_rejected ~needle label [ entry ] in
  reject
    ~needle:"field \"base_url\" must not be empty"
    "typed empty base_url"
    (valid_typed_entry ~base_url:"" ());
  reject
    ~needle:"field \"base_url\" must not have leading or trailing whitespace"
    "typed padded base_url"
    (valid_typed_entry ~base_url:" https://provider.test/v1 " ());
  reject
    ~needle:"field \"request_path\" must not be empty"
    "typed empty non-Gemini request path"
    (valid_typed_entry ~request_path:"" ());
  reject
    ~needle:"field \"request_path\" must not have leading or trailing whitespace"
    "typed padded request path"
    (valid_typed_entry ~request_path:" /v1/chat/completions " ());
  reject ~needle:"empty id or alias" "typed empty id" (valid_typed_entry ~id:"" ());
  reject
    ~needle:"leading or trailing whitespace"
    "typed padded id"
    (valid_typed_entry ~id:" typed-provider " ());
  reject
    ~needle:"field \"default_model\" must not be empty"
    "typed empty default model"
    (valid_typed_entry ~default_model:(Some "") ());
  reject
    ~needle:"field \"default_model\" must not have leading or trailing whitespace"
    "typed padded default model"
    (valid_typed_entry ~default_model:(Some " typed-model ") ());
  reject
    ~needle:"field \"auth.env\" must not be empty"
    "typed empty auth env"
    (valid_typed_entry ~auth:(Provider_catalog.Api_key_env "") ());
  reject
    ~needle:"field \"auth.env\" must not have leading or trailing whitespace"
    "typed padded auth env"
    (valid_typed_entry
       ~api_key_env:" TYPED_PROVIDER_KEY "
       ~auth:(Provider_catalog.Api_key_env " TYPED_PROVIDER_KEY ")
       ());
  reject
    ~needle:"api_key_env must equal the typed auth env"
    "typed auth env mismatch"
    (valid_typed_entry
       ~api_key_env:"OTHER_PROVIDER_KEY"
       ~auth:(Provider_catalog.Api_key_env "TYPED_PROVIDER_KEY")
       ());
  reject
    ~needle:"auth=none requires an empty api_key_env"
    "typed no-auth env mismatch"
    (valid_typed_entry ~api_key_env:"UNDECLARED_PROVIDER_KEY" ());
  reject
    ~needle:"max_context must be positive"
    "typed zero max_context"
    (valid_typed_entry ~max_context:(Some 0) ());
  reject
    ~needle:"max_context must be positive"
    "typed negative max_context"
    (valid_typed_entry ~max_context:(Some (-1)) ());
  let invalid_max_context_capability =
    { Capabilities.default_capabilities with max_context_tokens = Some 0 }
  in
  reject
    ~needle:"capability \"max_context_tokens\" must be positive"
    "typed zero capability max context"
    (valid_typed_entry ~capabilities:invalid_max_context_capability ());
  let invalid_max_output_capability =
    { Capabilities.default_capabilities with max_output_tokens = Some (-1) }
  in
  reject
    ~needle:"capability \"max_output_tokens\" must be positive"
    "typed negative capability max output"
    (valid_typed_entry ~capabilities:invalid_max_output_capability ());
  let invalid_cache_alignment =
    { Capabilities.default_capabilities with prompt_cache_alignment = Some 0 }
  in
  reject
    ~needle:"capability \"prompt_cache_alignment\" must be positive"
    "typed zero prompt cache alignment"
    (valid_typed_entry ~capabilities:invalid_cache_alignment ());
  let empty_supported_model =
    { Capabilities.default_capabilities with supported_models = Some [ "" ] }
  in
  reject
    ~needle:"field \"capabilities.supported_models\" must not be empty"
    "typed empty supported model"
    (valid_typed_entry ~capabilities:empty_supported_model ());
  let padded_supported_model =
    { Capabilities.default_capabilities with supported_models = Some [ " model " ] }
  in
  reject
    ~needle:
      "field \"capabilities.supported_models\" must not have leading or trailing \
       whitespace"
    "typed padded supported model"
    (valid_typed_entry ~capabilities:padded_supported_model ());
  reject
    ~needle:"field \"credential_scope\" must not be empty"
    "typed empty credential scope"
    (valid_typed_entry ~credential_scope:(Some "") ());
  reject
    ~needle:"field \"credential_scope\" must not have leading or trailing whitespace"
    "typed padded credential scope"
    (valid_typed_entry ~credential_scope:(Some " workspace ") ());
  let required_without_tool_choice =
    { Capabilities.default_capabilities with
      supports_required_tool_choice = true
    ; supports_tool_choice = false
    }
  in
  reject
    ~needle:"required/named tool choice requires supports_tool_choice=true"
    "typed required tool choice dependency"
    (valid_typed_entry ~capabilities:required_without_tool_choice ());
  let named_without_tool_choice =
    { Capabilities.default_capabilities with
      supports_named_tool_choice = true
    ; supports_tool_choice = false
    }
  in
  reject
    ~needle:"required/named tool choice requires supports_tool_choice=true"
    "typed named tool choice dependency"
    (valid_typed_entry ~capabilities:named_without_tool_choice ())
;;

let test_typed_entry_identities_are_unique () =
  require_typed_rejected
    ~needle:"declared by both"
    "typed duplicate provider ids"
    [ valid_typed_entry ~id:"Alpha" (); valid_typed_entry ~id:"alpha" () ];
  require_typed_rejected
    ~needle:"declared by both"
    "typed alias collides with provider id"
    [ valid_typed_entry ~id:"first" ~aliases:[ "shared" ] ()
    ; valid_typed_entry ~id:"SHARED" ()
    ];
  require_typed_rejected
    ~needle:"declared by both"
    "typed aliases collide"
    [ valid_typed_entry ~id:"first" ~aliases:[ "shared" ] ()
    ; valid_typed_entry ~id:"second" ~aliases:[ "SHARED" ] ()
    ]
;;

let test_removed_auth_types_are_rejected () =
  let catalog_json auth_type extra_fields =
    Printf.sprintf
      {|{
        "schema_version": 1,
        "providers": [
          {
            "id": "legacy-auth",
            "kind": "openai_compat",
            "auth": {"type": "%s"%s}
          }
        ]
      }|}
      auth_type
      extra_fields
  in
  let check_rejected auth_type extrafields =
    match
      Provider_catalog.of_json
        (Yojson.Safe.from_string (catalog_json auth_type extrafields))
    with
    | Ok _ -> failf "expected auth type %S to be rejected" auth_type
    | Error msg ->
      check
        bool
        (Printf.sprintf "%S rejected" auth_type)
        true
        (contains ~needle:"removed" msg || contains ~needle:"unknown" msg)
  in
  check_rejected "file" ", \"path\": \"/tmp/token\"";
  check_rejected "exec" ", \"command\": \"op read token\"";
  check_rejected "oauth_cached_login" ""
;;

let test_rejects_schema_version_and_accumulates_entry_errors () =
  (match Provider_catalog.of_json (Yojson.Safe.from_string {|{"schema_version": 2}|}) with
   | Error msg ->
     check bool "schema version message" true (contains ~needle:"schema_version" msg)
   | Ok _ -> fail "unsupported schema_version should be rejected");
  match
    Provider_catalog.of_json
      (Yojson.Safe.from_string
         {|{
           "schema_version": 1,
           "providers": [
             {"kind": "openai_compat"},
             {"id": "bad-kind", "kind": "missing_kind"},
             {"id": "bad-auth", "auth": {"type": "unknown"}}
           ]
         }|})
  with
  | Error msg ->
    check bool "missing id surfaced" true (contains ~needle:"missing required" msg);
    check bool "unknown kind surfaced" true (contains ~needle:"unknown kind" msg);
    check bool "unknown auth surfaced" true (contains ~needle:"unknown auth type" msg)
  | Ok _ -> fail "entry errors should be accumulated"
;;

let test_load_file_edges () =
  let valid_path = Filename.temp_file "provider-catalog-coverage" ".json" in
  let invalid_path = Filename.temp_file "provider-catalog-invalid" ".json" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove valid_path with
       | Sys_error _ -> ());
      try Sys.remove invalid_path with
      | Sys_error _ -> ())
    (fun () ->
       let write_file path contents =
         let oc = open_out path in
         Fun.protect
           ~finally:(fun () -> close_out_noerr oc)
           (fun () -> output_string oc contents)
       in
       write_file
         valid_path
         {|{"schema_version":1,"providers":[{"id":"runtime","kind":"openai_compat","base_url":"https://provider.test/v1","request_path":"/v1/chat/completions"}]}|};
       write_file invalid_path {|{"schema_version":|};
       (match Provider_catalog.load_file valid_path with
        | Ok catalog ->
          check
            bool
            "load_file lookup"
            true
            (Option.is_some (Provider_catalog.lookup catalog "runtime"))
        | Error msg -> fail msg);
       (match Provider_catalog.load_file invalid_path with
        | Error msg ->
          check bool "parse error mentions path" true (contains ~needle:invalid_path msg)
        | Ok _ -> fail "invalid JSON should fail");
       match Provider_catalog.load_file (valid_path ^ ".missing") with
       | Error msg ->
         check bool "missing file mentions path" true (contains ~needle:valid_path msg)
       | Ok _ -> fail "missing file should fail")
;;

let test_global_override_lifecycle () =
  Provider_catalog.clear_global ();
  let catalog =
    catalog_of_string
      {|{"schema_version":1,"providers":[{"id":"override","kind":"openai_compat","base_url":"https://provider.test/v1","request_path":"/v1/chat/completions"}]}|}
  in
  Provider_catalog.set_global catalog;
  (match Provider_catalog.global () with
   | Some loaded ->
     check
       bool
       "override visible"
       true
       (Option.is_some (Provider_catalog.lookup loaded "override"))
   | None -> fail "expected global override");
  Provider_catalog.clear_global ();
  check (option reject) "clear removes overlay" None (Provider_catalog.global ())
;;

let () =
  run
    "provider_catalog_coverage"
    [ ( "parse"
      , [ test_case
            "full entry auth capabilities"
            `Quick
            test_full_entry_parses_auth_and_capabilities
        ; test_case
            "present type mismatches fail closed"
            `Quick
            test_present_type_mismatches_are_rejected
        ; test_case "auth shape contract" `Quick test_auth_shape_contract
        ; test_case "closed object contract" `Quick test_closed_object_contract
        ; test_case
            "values fail closed without coercion"
            `Quick
            test_values_fail_closed_without_coercion
        ; test_case
            "null optional fields use defaults"
            `Quick
            test_null_optional_fields_use_declared_defaults
        ; test_case
            "auth thinking canonical"
            `Quick
            test_auth_and_thinking_canonical_matrix
        ; test_case
            "removed catalog fields and aliases rejected"
            `Quick
            test_removed_catalog_fields_and_aliases_are_rejected
        ; test_case
            "catalog root shape is explicit"
            `Quick
            test_catalog_root_shape_is_explicit
        ; test_case
            "catalog identities are unique"
            `Quick
            test_catalog_identities_are_unique
        ; test_case
            "typed entries accept a complete valid contract"
            `Quick
            test_typed_entries_accept_a_complete_valid_contract
        ; test_case "typed entries fail closed" `Quick test_typed_entries_fail_closed
        ; test_case
            "typed entry identities are unique"
            `Quick
            test_typed_entry_identities_are_unique
        ; test_case
            "schema and entry errors"
            `Quick
            test_rejects_schema_version_and_accumulates_entry_errors
        ; test_case
            "removed auth types rejected"
            `Quick
            test_removed_auth_types_are_rejected
        ] )
    ; ( "load"
      , [ test_case "load_file edges" `Quick test_load_file_edges
        ; test_case "global override lifecycle" `Quick test_global_override_lifecycle
        ] )
    ]
;;
