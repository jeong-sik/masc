open Alcotest
open Llm_provider
module EO = Agent_core.Exact_output

let schema = `Assoc [ "type", `String "object"
  ; "properties", `Assoc [ "ok", `Assoc [ "type", `String "boolean" ] ]
  ; "required", `List [ `String "ok" ]; "additionalProperties", `Bool false ]
let named = `Assoc [ "name", `String "answer"; "schema", schema; "strict", `Bool true ]
let messages = [ Types.user_msg "Return a JSON object with ok=true." ]
let expected = `Assoc [ "type", `String "json_object"; "schema", schema ]

let get_ok label = function Ok value -> value | Error _ -> fail label

let with_peer ~stream f =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let socket = Eio.Net.listen env#net ~sw ~backlog:1
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
    let port = match Eio.Net.listening_addr socket with
      | `Tcp (_, port) -> port | `Unix _ -> fail "expected TCP listener" in
    let captured = ref None in
    let response =
      if stream then
        "data: {\"id\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"{\\\"ok\\\":true}\"},\"finish_reason\":null}]}\n\n" ^
        "data: {\"id\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
      else {|{"id":"fixture","model":"command-r-plus","choices":[{"index":0,"message":{"role":"assistant","content":"{\"ok\":true}"},"finish_reason":"stop"}]}|} in
    let callback _ _ body =
      captured := Some (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all));
      let headers = Cohttp.Header.of_list [ "content-type",
        if stream then "text/event-stream" else "application/json" ] in
      Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:response () in
    let server = Cohttp_eio.Server.make ~callback () in
    Eio.Fiber.first
      (fun () -> Cohttp_eio.Server.run socket server ~on_error:raise)
      (fun () -> f ~sw ~net:env#net
          ~url:(Printf.sprintf "http://127.0.0.1:%d" port) captured)))

let test_complete_sync_and_sse () =
  List.iter (fun stream -> List.iter (fun requested_schema ->
    with_peer ~stream (fun ~sw ~net ~url captured ->
      let config = Provider_config.make ~kind:OpenAI_compat ~provider_id:"cohere"
        ~model_id:"command-r-plus" ~base_url:url ~request_path:"/chat/completions"
        ~api_key:"fixture-only" ~response_format:(Types.JsonSchema requested_schema) () in
      let result = if stream then
          Complete.complete_stream ~sw ~net ~config ~messages ~on_event:(fun _ -> ()) ()
        else Complete.complete ~sw ~net ~config ~messages () in
      ignore (get_ok "Complete must parse the peer response" result.Completion_outcome.result);
      let body = match !captured with Some body -> Yojson.Safe.from_string body
        | None -> fail "peer received no request" in
      check bool "actual peer receives Cohere schema envelope" true
        (Yojson.Safe.Util.member "response_format" body = expected);
      check string "wire model spelling retained" "command-r-plus"
        Yojson.Safe.Util.(body |> member "model" |> to_string))) [ schema; named ]) [ false; true ]

let test_explicit_override_and_provider_isolation () =
  let make ?model_capabilities_override provider_id =
    Provider_config.make ~kind:OpenAI_compat ~provider_id ~model_id:"command-r-plus"
      ~base_url:"https://opaque-proxy.example/v1" ~response_format:(Types.JsonSchema named)
      ?model_capabilities_override () in
  let wire config = Backend_openai.build_request ~config ~messages ()
    |> Yojson.Safe.from_string |> Yojson.Safe.Util.member "response_format" in
  check bool "unrelated provider does not borrow Cohere dialect" true
    (wire (make "foreign-provider") = `Assoc [ "type", `String "json_schema"; "json_schema", named ]);
  let caps = { Capabilities.openai_compat_chat_capabilities with
    json_schema_dialect = Capabilities.Json_object_schema } in
  check bool "explicit typed override controls arbitrary provider serializer" true
    (wire (make ~model_capabilities_override:caps "foreign-provider") = expected);
  let glm = { (make ~model_capabilities_override:caps "foreign-provider") with
    kind = Provider_config.Glm } in
  let glm_wire = Backend_glm.build_request ~config:glm ~messages ()
    |> Yojson.Safe.from_string |> Yojson.Safe.Util.member "response_format" in
  check bool "GLM shared builder retains its declared named-schema wire" true
    (glm_wire = `Assoc [ "type", `String "json_schema"; "json_schema", named ]);
  let denied = { caps with supports_structured_output = false } in
  check bool "dialect alone does not admit native schema" true
    (Result.is_error (Provider_config.validate_output_schema_request
       (make ~model_capabilities_override:denied "foreign-provider")));
  let json_mode = { (make "cohere") with response_format = Types.JsonMode } in
  check bool "JSON mode has no schema invented" true
    (wire json_mode = `Assoc [ "type", `String "json_object" ])

let test_mistral_and_kimi_declarations () =
  List.iter (fun stream -> with_peer ~stream (fun ~sw ~net ~url captured ->
    let config = Provider_config.make ~kind:OpenAI_compat ~provider_id:"mistral"
      ~model_id:"mistral-large" ~base_url:url ~api_key:"fixture-only"
      ~response_format:(Types.JsonSchema schema) () in
    let outcome = if stream then
        Complete.complete_stream ~sw ~net ~config ~messages ~on_event:(fun _ -> ()) ()
      else Complete.complete ~sw ~net ~config ~messages () in
    ignore (get_ok "Mistral peer completion" outcome.Completion_outcome.result);
    let body = match !captured with Some body -> Yojson.Safe.from_string body
      | None -> fail "Mistral peer received no request" in
    let format = Yojson.Safe.Util.member "response_format" body in
    check string "Mistral uses the named schema dialect" "json_schema"
      Yojson.Safe.Util.(format |> member "type" |> to_string);
    let payload = Yojson.Safe.Util.member "json_schema" format in
    check bool "Mistral strict is explicitly true" true
      Yojson.Safe.Util.(payload |> member "strict" |> to_bool);
    check bool "Mistral raw domain schema is retained" true
      (Yojson.Safe.Util.member "schema" payload = schema))) [ false; true ];
  let coding = Provider_config.make ~kind:Kimi ~provider_id:"kimi"
    ~model_id:"kimi-k2.7-code" ~base_url:"https://opaque-proxy.example"
    ~response_format:(Types.JsonSchema schema) () in
  check bool "coding capability does not promise platform schema support" true
    (Result.is_error (Provider_config.validate_output_schema_request coding));
  let platform = Provider_config.make ~kind:OpenAI_compat ~provider_id:"platform-fixture"
    ~model_id:"kimi-k2.7-code" ~base_url:"https://opaque-proxy.example"
    ~model_capabilities_override:Capabilities.openai_compat_chat_capabilities
    ~response_format:(Types.JsonSchema schema) () in
  check bool "explicit platform wire/capability is independently admitted" true
    (Result.is_ok (Provider_config.validate_output_schema_request platform));
  let body = Backend_openai.build_request ~config:platform ~messages () |> Yojson.Safe.from_string in
  check bool "platform declaration sends strict named schema" true
    Yojson.Safe.Util.(body |> member "response_format" |> member "json_schema" |> member "strict" |> to_bool)

let catalog ?(kind = "openai_compat") dialect = Printf.sprintf
  "[[providers]]\nid = \"fixture\"\nkind = %S\nbase_url = \"http://127.0.0.1:1\"\nrequest_path = \"/chat/completions\"\nauth = \"none\"\ncapabilities_base = \"openai_chat\"\n[[models]]\nmodel_id = \"same-model\"\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nsupports_structured_output = true\njson_schema_dialect = %S\n[[targets]]\nid = \"slot\"\nprovider_ref = \"fixture\"\nmodel_id = \"same-model\"\nconnect_timeout_s = 30.0\nbody_timeout_s = 30.0\n" kind dialect

let test_strict_declarations () =
  let valid = "json_object_schema" in
  let parsed = get_ok "typed TOML declaration" (Model_catalog.of_toml_string ~source:"dialect declaration" (catalog valid)) in
  (match Model_catalog.model_entries parsed with
   | [ row ] -> check bool "TOML carries typed dialect" true
       (row.json_schema_dialect = Some Capability_vocab.Json_object_schema)
   | _ -> fail "expected one model");
  let manifest dialect = `Assoc [ "schema_version", `Int 2; "models", `List [ `Assoc
    [ "model_id", `String "same-model"; "json_schema_dialect", `String dialect ] ] ] in
  let provider dialect = `Assoc [ "schema_version", `Int 1; "providers", `List [ `Assoc
    [ "id", `String "custom"; "kind", `String "openai_compat"
    ; "base_url", `String "https://example.test"; "request_path", `String "/chat/completions"
    ; "auth", `Assoc [ "type", `String "none" ]; "capabilities_base", `String "openai_chat"
    ; "capabilities", `Assoc [ "json_schema_dialect", `String dialect ] ] ] ] in
  let parsed_manifest = get_ok "typed manifest declaration" (Capability_manifest.of_json (manifest valid)) in
  (match Capability_manifest.entries parsed_manifest with
   | [ row ] -> check bool "manifest carries typed dialect" true
       (row.json_schema_dialect = Some Capability_vocab.Json_object_schema)
   | _ -> fail "expected one manifest entry");
  let parsed_provider = get_ok "typed provider override" (Provider_catalog.of_json (provider valid)) in
  (match Provider_catalog.entries parsed_provider with
   | [ row ] -> check bool "provider override carries typed dialect" true
       (row.capabilities.json_schema_dialect = Capabilities.Json_object_schema)
   | _ -> fail "expected one provider");
  List.iter (fun invalid ->
    check bool "unknown TOML dialect is an error" true
      (Result.is_error (Model_catalog.of_toml_string ~source:"dialect declaration" (catalog invalid)));
    check bool "unknown manifest dialect is an error" true
      (Result.is_error (Capability_manifest.of_json (manifest invalid)));
    check bool "unknown provider dialect is an error" true
      (Result.is_error (Provider_catalog.of_json (provider invalid)))) [ "unknown"; "" ]

let test_exact_frozen_contract () =
  let observe ?kind dialect =
    let snapshot = get_ok "exact snapshot" (EO.load_resolver_snapshot
      ~catalog:(EO.Full_replacement { source = "dialect fixture"; contents = catalog ?kind dialect }) ()) in
    let admitted = get_ok "exact target admission" (EO.admit_target_ref snapshot "slot") in
    let target = get_ok "exact target resolution" (EO.resolve_target admitted) in
    let requirement = EO.make_output_requirement ~schema ~minimum_guarantee:EO.Provider_schema in
    let plan = get_ok "native schema admission" (EO.admit ~target ~messages requirement) in
    let provenance = EO.plan_provenance plan in
    let source = EO.plan_provenance_source_schema_fingerprint provenance in
    let effective = match EO.plan_provenance_effective_schema_fingerprint provenance with
      | Some effective -> effective | None -> fail "native schema fingerprint missing" in
    EO.catalog_generation_fingerprint (EO.resolver_catalog_generation snapshot),
    EO.plan_fingerprint plan,
    EO.schema_fingerprint_to_string source = EO.schema_fingerprint_to_string effective in
  let raw_generation, raw_plan, raw_schema = observe "json_object_schema" in
  let named_generation, named_plan, named_schema = observe "openai_json_schema" in
  check bool "raw-schema dialect fingerprints its actual domain schema" true raw_schema;
  check bool "OpenAI envelope remains part of effective schema" false named_schema;
  check bool "dialect changes catalog evidence identity" true (raw_generation <> named_generation);
  check bool "dialect changes frozen plan identity" true (raw_plan <> named_plan);
  let _, _, glm_raw_schema = observe ~kind:"glm" "json_object_schema" in
  check bool "GLM exact admission keeps the named wire fingerprint" false glm_raw_schema

let () =
  Model_catalog.set_global (get_ok "embedded catalog" (Model_catalog.load_default ()));
  Capability_manifest.set_global Capability_manifest.empty;
  Provider_catalog.clear_global ();
  run "Cohere schema wire" [ "contract", [
    test_case "Complete sync/SSE reaches the peer with declared shape" `Quick test_complete_sync_and_sse;
    test_case "explicit override and provider isolation" `Quick test_explicit_override_and_provider_isolation;
    test_case "Mistral strict and typed Kimi route separation" `Quick test_mistral_and_kimi_declarations;
    test_case "strict typed declarations" `Quick test_strict_declarations;
    test_case "exact frozen schema contract" `Quick test_exact_frozen_contract ] ]
