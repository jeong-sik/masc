(* #37435 — [\[models.<id>.capabilities\]] keys carry exact TOML presence.

   An unwritten key used to parse as [false], so it was indistinguishable from
   a written [false]. That one conflation produced two opposite symptoms: on a
   model the AGENT_CORE catalog knows, the whole block had to be dropped or it
   would zero every flag the operator never mentioned; on a model the catalog
   does not know, it zeroed the provider wire's preset instead — while the
   comment above that code promised the dialect would decide.

   The asymmetry this suite pins: an unwritten capability key takes the wire's
   preset, an unwritten MEDIA key stays [false]. Media input is fail-closed on
   purpose (Runtime_agent.apply_runtime_model_input_capabilities), and a
   migration that "tidies up" the two into one rule breaks it. *)

open Alcotest

(* [fixture_novel_endpoint] names no catalog provider, so capability
   resolution takes the uncatalogued branch: no model row and no provider-wide
   base answer, and the wire preset is what the block is laid over. *)
let config_with_partial_capabilities =
  {|[providers.fixture_novel_endpoint]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1/v1"

[models.partial]
api-name = "fixture-partial-model"
max-context = 8192
tools-support = true

[models.partial.capabilities]
supports-image-input = true

[fixture_novel_endpoint.partial]

[runtime]
default = "fixture_novel_endpoint.partial"
|}
;;

let with_config config f =
  let saved = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "capability-presence-" ".toml" in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore saved;
      Sys.remove path)
    (fun () ->
       Out_channel.with_open_bin path (fun out -> output_string out config);
       (match Runtime.init_default ~config_path:path with
        | Ok () -> ()
        | Error detail -> fail detail);
       f ())
;;

let resolved_capabilities runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> failf "runtime %s did not materialize" runtime_id
  | Some runtime ->
    (match runtime.Runtime.execution with
     | Runtime_execution.Agent_core provider ->
       Provider_tool_support.agent_core_capabilities_of_config provider
     | Runtime_execution.Claude_code _
     | Runtime_execution.Codex_app_server _
     | Runtime_execution.Antigravity_cli _ ->
       failf "runtime %s is not an Agent Core binding" runtime_id)
;;

let test_unwritten_capability_takes_the_wire_preset () =
  with_config config_with_partial_capabilities
  @@ fun () ->
  let caps = resolved_capabilities "fixture_novel_endpoint.partial" in
  (* The block states none of these. The OpenAI-compatible preset does, and
     before #37435 every one of them arrived as false. *)
  check bool "tool_choice follows the wire" true caps.Llm_provider.Capabilities.supports_tool_choice;
  check
    bool
    "structured output follows the wire"
    true
    caps.Llm_provider.Capabilities.supports_structured_output;
  check
    bool
    "response_format follows the wire"
    true
    caps.Llm_provider.Capabilities.supports_response_format_json;
  check
    bool
    "system prompt follows the wire"
    true
    caps.Llm_provider.Capabilities.supports_system_prompt
;;

let test_unwritten_media_key_stays_closed () =
  with_config config_with_partial_capabilities
  @@ fun () ->
  let caps = resolved_capabilities "fixture_novel_endpoint.partial" in
  (* The wire preset carries image and multimodal input. The block states only
     the image one, and the rest must NOT open with it: media input is the one
     place MASC's model spec is the SSOT and absence means no. *)
  check bool "the stated media key is honored" true caps.Llm_provider.Capabilities.supports_image_input;
  check
    bool
    "an unstated media key stays closed"
    false
    caps.Llm_provider.Capabilities.supports_audio_input;
  check
    bool
    "an unstated media key stays closed"
    false
    caps.Llm_provider.Capabilities.supports_video_input;
  check
    bool
    "multimodal does not open with image"
    false
    caps.Llm_provider.Capabilities.supports_multimodal_inputs
;;

(* The declaration layer asks a different question from the resolution layer:
   "did the operator authorize this?", not "what can the wire do?". An
   undeclared sampling capability is not an authorization, exactly as a
   declared [false] is not. *)
let config_with_top_k_but_no_declaration =
  {|[providers.fixture_novel_endpoint]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1/v1"

[models.sampled]
api-name = "fixture-sampled-model"
max-context = 8192
tools-support = true
top-k = 20

[models.sampled.capabilities]
supports-image-input = true

[fixture_novel_endpoint.sampled]

[runtime]
default = "fixture_novel_endpoint.sampled"
|}
;;

let test_undeclared_sampling_support_still_refuses_top_k () =
  let path = Filename.temp_file "capability-presence-sampling-" ".toml" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
       Out_channel.with_open_bin path (fun out ->
         output_string out config_with_top_k_but_no_declaration);
       match Runtime_toml.parse_file path with
       | Ok _ -> fail "top-k without a supports-top-k declaration must not load"
       | Error errors ->
         check
           bool
           "the error names the undeclared support"
           true
           (List.exists
              (fun (error : Runtime_toml.parse_error) ->
                 String_util.contains_substring error.message "is not declared")
              errors))
;;

let () =
  run
    "model capability presence"
    [ ( "uncatalogued resolution"
      , [ test_case
            "an unwritten capability key takes the wire preset"
            `Quick
            test_unwritten_capability_takes_the_wire_preset
        ; test_case
            "an unwritten media key stays closed"
            `Quick
            test_unwritten_media_key_stays_closed
        ] )
    ; ( "declaration layer"
      , [ test_case
            "an undeclared sampling support still refuses top-k"
            `Quick
            test_undeclared_sampling_support_still_refuses_top_k
        ] )
    ]
;;
