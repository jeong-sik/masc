(** #27898: same wire/model text, different explicit provider authority. *)
open Llm_provider

let catalog_text_for_endpoint endpoint = Printf.sprintf {|
[[providers]]
id = "label-a"
kind = "openai_compat"
base_url = "https://a.invalid"
request_path = "/v1/chat/completions"
auth = "none"
capabilities_base = "openai_chat"
[[providers]]
id = "label-b"
aliases = ["label-b-alias"]
default_model = "overlap"
kind = "openai_compat"
base_url = "https://b.invalid"
request_path = "/v1/chat/completions"
auth = "none"
capabilities_base = "openai_chat"
[[providers]]
id = "ollama"
kind = "ollama"
base_url = "%s"
request_path = "/api/chat"
auth = "none"
discovery_timeout_s = 4.0
capabilities_base = "ollama"
[[providers]]
id = "ollama-keyed"
kind = "ollama"
base_url = "%s"
request_path = "/api/chat"
auth = "api-key"
discovery_timeout_s = 4.0
capabilities_base = "ollama"
[[models]]
model_id = "overlap"
base = "openai_chat"
max_context_tokens = 1000000
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
[[models]]
model_id = "overlap"
provider_name = "label-a"
base = "openai_chat"
max_context_tokens = 8192
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
[[models]]
model_id = "overlap"
provider_name = "label-b"
base = "openai_chat"
max_context_tokens = 32768
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
|} endpoint endpoint

let catalog endpoint = match Model_catalog.of_toml_string ~source:"label binding fixture"
  (catalog_text_for_endpoint endpoint) with
  | Ok catalog -> catalog | Error detail -> Alcotest.fail detail
let with_catalog ?(endpoint="http://127.0.0.1:11434") f =
  let previous = Model_catalog.global () in
  Fun.protect ~finally:(fun () -> match previous with
    | Some catalog -> Model_catalog.set_global catalog | None -> Model_catalog.clear_global ())
    (fun () -> Model_catalog.set_global (catalog endpoint); f ())
let config provider = match Runtime_model_string.parse_model_string (provider ^ ":overlap") with
  | Some config -> config | None -> Alcotest.fail "registered model label was refused"
let caps config = match Provider_config.capabilities_for_config_model config with
  | Some caps -> caps | None -> Alcotest.fail "provider model capabilities disappeared"

let identity () = with_catalog (fun () ->
  List.iter (fun provider ->
    let config = config provider in
    Alcotest.(check (option string)) "explicit provider survives label resolution" (Some provider)
      config.Provider_config.provider_id;
    Alcotest.(check string) "resolved endpoint remains owned by provider"
      (if provider="label-a" then "https://a.invalid" else "https://b.invalid") config.base_url)
    ["label-a";"label-b"])
let context () = with_catalog (fun () ->
  List.iter (fun (provider,expected) ->
    let config = config provider in
    Alcotest.(check (option int)) "context excludes unrelated bare model declaration" (Some expected)
      (Provider_config.context_window config);
    Alcotest.(check (option int)) "config carries the same resolved window" (Some expected)
      config.max_context) ["label-a",8192;"label-b",32768])
let policy () = with_catalog (fun () ->
  let first = config "label-a" and second = config "label-b" in
  Alcotest.(check bool) "A rejects forcing despite the bare row allowing it" false
    (caps first).supports_required_tool_choice;
  Alcotest.(check bool) "B retains its separate forcing declaration" true
    (caps second).supports_required_tool_choice;
  let rotated = {first with Provider_config.base_url=second.base_url} in
  Alcotest.(check (option string)) "endpoint override preserves selected provider"
    (Some "label-a") rotated.provider_id;
  Alcotest.(check bool) "endpoint override cannot borrow B's policy" false
    (caps rotated).supports_required_tool_choice;
  Alcotest.(check bool) "A rejects required choice before dispatch" true
    (Result.is_error (Complete_common.validate_all {first with tool_choice=Some Types.Any}));
  Alcotest.(check bool) "B admits required choice" true
    (Result.is_ok (Complete_common.validate_all {second with tool_choice=Some Types.Any}));
  let tools = [`Assoc ["name",`String "lookup";"description",`String "Lookup";
    "input_schema",`Assoc ["type",`String "object";"properties",`Assoc []]]] in
  match Complete_common.serialize_http_request ~stream:false
      ~config:{second with tool_choice=Some Types.Any}
      ~messages:[Types.make_message ~role:Types.User [Types.Text "Look up the receipt"]] ~tools with
  | Error _ -> Alcotest.fail "admitted provider B failed final serialization"
  | Ok request ->
    Alcotest.(check string) "B forcing reaches final Chat body" "required"
      Yojson.Safe.Util.(Yojson.Safe.from_string request.Complete_common.body |> member "tool_choice" |> to_string))

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect ~finally:(fun () -> match previous with
    | None -> Unix.unsetenv key | Some previous -> Unix.putenv key previous)
    (fun () ->
      (match value with None -> Unix.unsetenv key | Some value -> Unix.putenv key value);
      f ())

let with_mock_server_on ~sw ~net handler f =
  let socket = Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> Alcotest.fail "expected a TCP listener" in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () -> Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  let endpoint = Printf.sprintf "http://127.0.0.1:%d" port in
  f ~endpoint

let with_mock_server handler f =
  Eio_main.run @@ fun env ->
  try
    Eio.Switch.run @@ fun sw ->
    with_mock_server_on ~sw ~net:env#net handler (fun ~endpoint ->
      f ~sw ~net:env#net ~clock:env#clock ~endpoint;
      Eio.Switch.fail sw Exit)
  with
  | Unix.Unix_error ((Unix.EPERM | Unix.EADDRINUSE), "bind", _) -> Alcotest.skip ()
  | Exit -> ()

let missing_endpoint () = with_env "CUSTOM_LLM_BASE_URL" None (fun () ->
  Alcotest.(check bool) "custom label cannot borrow discovery endpoint" true
    (Runtime_model_string.parse_model_string "custom:overlap"=None))
let ambient_endpoint () = with_env "CUSTOM_LLM_BASE_URL" (Some "https://ambient.invalid") (fun () ->
  Alcotest.(check bool) "custom label cannot borrow environment endpoint" true
    (Runtime_model_string.parse_model_string "custom:overlap"=None);
  match Provider_kind_resolver.resolve "custom:overlap" with
  | Unknown _ -> ()
  | Custom_url _ | Registered _ -> Alcotest.fail "kind resolver invented a custom endpoint")
let invalid_endpoint () =
  List.iter (fun spec ->
    Alcotest.(check bool) "invalid custom endpoint is refused before request construction" true
      (Runtime_model_string.parse_model_string spec=None))
    ["custom:overlap@";"custom:@https://explicit.invalid";
     "custom:overlap@not-an-endpoint";"custom:overlap@ftp://explicit.invalid"]
let malformed_endpoint () =
  List.iter (fun endpoint ->
    Alcotest.(check bool) "custom URL parser must consume the complete endpoint" true
      (Runtime_model_string.parse_model_string ("custom:overlap@" ^ endpoint)=None))
    ["https://explicit.invalid:bogus";"https://explicit.invalid/path%ZZ";
     "https://explicit.invalid/path invalid"]
let endpoint_authority () =
  List.iter (fun endpoint ->
    Alcotest.(check bool) "invalid authority suffix cannot become a path" true
      (Runtime_model_string.parse_model_string ("custom:overlap@" ^ endpoint)=None))
    ["https://user@first.invalid@second.invalid";
     "https://explicit.invalid]garbage";"https://[::1]garbage"]
let endpoint_ports () =
  List.iter (fun endpoint ->
    Alcotest.(check bool) "invalid explicit port cannot become the default port" true
      (Runtime_model_string.parse_model_string ("custom:overlap@" ^ endpoint)=None))
    ["https://explicit.invalid:999999999999999999999999999999";
     "https://explicit.invalid:65536";"https://explicit.invalid:0"];
  List.iter (fun endpoint ->
    let config = match Runtime_model_string.parse_model_string ("custom:overlap@" ^ endpoint) with
      | Some config -> config | None -> Alcotest.fail "valid explicit authority was refused" in
    Alcotest.(check string) "valid authority and path/query bytes remain explicit"
      endpoint config.Provider_config.base_url)
    ["https://explicit.invalid:00443/v1";"http://[::1]:8080/v1";
     "http://[::1]/v1";"https://user:password@explicit.invalid/v1?q=a%2Fb"]
let explicit_endpoint () = with_env "CUSTOM_LLM_BASE_URL" (Some "https://ambient.invalid") (fun () ->
  let spec = "custom:overlap@https://explicit.invalid/v1" in
  (match Provider_kind_resolver.resolve spec with
   | Custom_url {model_id;base_url} ->
     Alcotest.(check string) "custom classification retains explicit model" "overlap" model_id;
     Alcotest.(check string) "custom classification retains explicit endpoint"
       "https://explicit.invalid/v1" base_url
   | Unknown _ | Registered _ -> Alcotest.fail "explicit custom URL was not classified");
  let config = match Runtime_model_string.parse_model_string ~max_tokens:128 spec with
    | Some config -> config | None -> Alcotest.fail "explicit custom URL was refused" in
  Alcotest.(check string) "custom config retains explicit endpoint" "https://explicit.invalid/v1" config.base_url;
  match Complete_common.serialize_http_request ~stream:false ~config ~tools:[]
      ~messages:[Types.make_message ~role:Types.User [Types.Text "Read the receipt"]] with
  | Error _ -> Alcotest.fail "explicit custom config failed final request serialization"
  | Ok request ->
    Alcotest.(check string) "custom wire retains explicitly selected model" "overlap"
      Yojson.Safe.Util.(Yojson.Safe.from_string request.Complete_common.body |> member "model" |> to_string))

let transport_config label = match Runtime_transport.resolve_provider_config_of_label label with
  | Ok config -> config | Error _ -> Alcotest.fail "declared runtime label was refused"
let no_default () = with_catalog (fun () ->
  Alcotest.(check bool) "auto without catalog default cannot reach execution" true
    (Result.is_error (Runtime_transport.resolve_provider_config_of_label "label-a:auto")))
let declared_default () = with_catalog (fun () ->
  with_env "LABEL_B_DEFAULT_MODEL" (Some "ambient-model") (fun () ->
    let config = transport_config "label-b:auto" in
    Alcotest.(check string) "catalog default wins independently of derived environment key" "overlap" config.model_id;
    Alcotest.(check (option string)) "auto retains canonical provider" (Some "label-b") config.provider_id;
    Alcotest.(check (option int)) "auto retains exact model context" (Some 32768)
      (Provider_config.context_window config);
    let configured = match Runtime_model_string.parse_model_string
        ~temperature:0.25 ~max_tokens:128 ~system_prompt:"explicit system"
        ~keep_alive:"5m" ~num_ctx:4096 "label-b:auto" with
      | Some config -> config | None -> Alcotest.fail "configured default was refused" in
    Alcotest.(check (option (float 0.001))) "binding construction preserves temperature"
      (Some 0.25) configured.temperature;
    Alcotest.(check (option int)) "binding construction preserves output limit"
      (Some 128) configured.max_tokens;
    Alcotest.(check (option string)) "binding construction preserves system prompt"
      (Some "explicit system") configured.system_prompt;
    Alcotest.(check (option string)) "binding construction preserves keep-alive"
      (Some "5m") configured.keep_alive;
    Alcotest.(check (option int)) "binding construction preserves context option"
      (Some 4096) configured.num_ctx))
let alias_default () = with_catalog (fun () ->
  let config = transport_config "label-b-alias:auto" in
  Alcotest.(check string) "alias resolves declared default" "overlap" config.model_id;
  Alcotest.(check (option string)) "alias carries canonical binding identity" (Some "label-b") config.provider_id)
let supported_is_not_default () = with_catalog (fun () ->
  let previous = Provider_catalog.global () in
  Fun.protect ~finally:(fun () -> match previous with
    | Some catalog -> Provider_catalog.set_global catalog | None -> Provider_catalog.clear_global ())
    (fun () ->
      let entry : Provider_catalog.entry =
        {id="label-a";aliases=[];kind=Provider_config.OpenAI_compat;
         base_url="https://a.invalid";request_path="/v1/chat/completions";
         api_key_env="";auth=Provider_catalog.No_auth;default_model=None;discovery_timeout_s=None;max_context=None;
         capabilities={Capabilities.default_capabilities with supported_models=Some ["supported-not-default"]};
         credential_scope=None} in
      let overlay = match Provider_catalog.of_entries [entry] with
        | Ok catalog -> catalog | Error detail -> Alcotest.fail detail in
      Provider_catalog.set_global overlay;
      Alcotest.(check bool) "supported-model metadata cannot invent an execution default" true
        (Result.is_error (Runtime_transport.resolve_provider_config_of_label "label-a:auto"))))
let projected_defaults () = with_catalog (fun () ->
  with_env "MASC_DEFAULT_RUNTIME" None (fun () ->
    with_env "MASC_DEFAULT_PROVIDER" None (fun () ->
      with_env "MASC_DEFAULT_MODEL" None (fun () ->
        with_env "LABEL_A_DEFAULT_MODEL" (Some "ambient-model") (fun () ->
          Alcotest.(check (list string)) "projection offers only explicitly declared catalog defaults"
            ["label-b:overlap"] (Provider_runtime_projection.default_execution_model_strings "fixture");
          with_env "MASC_DEFAULT_PROVIDER" (Some "label-a") (fun () ->
            Alcotest.(check (list string)) "incomplete explicit configuration cannot trigger a fallback"
              [] (Provider_runtime_projection.default_execution_model_strings "fixture"));
          List.iter (fun key -> List.iter (fun value ->
            with_env key (Some value) (fun () ->
              Alcotest.(check (list string)) "present blank configuration cannot trigger catalog defaults"
                [] (Provider_runtime_projection.default_execution_model_strings "fixture"))) ["";"  "])
            ["MASC_DEFAULT_RUNTIME";"MASC_DEFAULT_PROVIDER";"MASC_DEFAULT_MODEL"];
          with_env "MASC_DEFAULT_PROVIDER" (Some "") (fun () ->
            with_env "MASC_DEFAULT_MODEL" (Some " ") (fun () ->
              Alcotest.(check (list string)) "blank explicit pair cannot trigger catalog defaults"
                [] (Provider_runtime_projection.default_execution_model_strings "fixture"))))))))

let ollama_auto_uses_production_discovery_cache () =
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/health" -> Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok" ()
    | "/api/tags" -> Cohttp_eio.Server.respond_string ~status:`OK
      ~body:{|{"models":[{"name":"qwen-local"}]}|} ()
    | "/v1/models" -> Cohttp_eio.Server.respond_string ~status:`OK
      ~body:{|{"data":[{"id":"qwen-local","owned_by":"ollama"}]}|} ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock ~endpoint ->
    Discovery_cache.set_env ~sw ~net ~clock;
    with_catalog ~endpoint (fun () ->
      match Runtime_model_string.parse_model_string "ollama:auto" with
      | Some config ->
        Alcotest.(check string) "production discovery resolves the exact Ollama model"
          "qwen-local" config.Provider_config.model_id
      | None -> Alcotest.fail "production discovery cache did not resolve ollama:auto"))

let ollama_auto_sends_resolved_credential () =
  let authorize req response =
    match Cohttp.Header.get (Cohttp.Request.headers req) "authorization" with
    | Some "Bearer test-ollama-secret" -> response ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Unauthorized ~body:"missing credential" ()
  in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/health" -> authorize req (fun () -> Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok" ())
    | "/api/tags" -> authorize req (fun () -> Cohttp_eio.Server.respond_string ~status:`OK
      ~body:{|{"models":[{"name":"qwen-keyed"}]}|} ())
    | "/v1/models" -> authorize req (fun () -> Cohttp_eio.Server.respond_string ~status:`OK
      ~body:{|{"data":[{"id":"qwen-keyed","owned_by":"ollama"}]}|} ())
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock ~endpoint ->
    Discovery_cache.set_env ~sw ~net ~clock;
    with_env "MASC_TEST_OLLAMA_KEY" (Some "test-ollama-secret") (fun () ->
      with_catalog ~endpoint (fun () ->
        match Runtime_model_string.parse_model_string
          ~api_key_env_overrides:["ollama-keyed", "MASC_TEST_OLLAMA_KEY"] "ollama-keyed:auto" with
        | Some config ->
          Alcotest.(check string) "keyed discovery resolves the authenticated Ollama model"
            "qwen-keyed" config.Provider_config.model_id
        | None -> Alcotest.fail "authenticated Ollama discovery was refused")))

let ollama_auto_does_not_reuse_unauthenticated_cache_for_keyed_binding () =
  let authenticated_tag_requests = ref 0 in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/api/tags" ->
      (match Cohttp.Header.get (Cohttp.Request.headers req) "authorization" with
       | Some "Bearer test-ollama-secret" ->
         incr authenticated_tag_requests;
         Cohttp_eio.Server.respond_string ~status:`OK
           ~body:{|{"models":[{"name":"keyed-model"}]}|} ()
       | _ ->
         Cohttp_eio.Server.respond_string ~status:`OK
           ~body:{|{"models":[{"name":"public-model"}]}|} ())
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock ~endpoint ->
    Discovery_cache.set_env ~sw ~net ~clock;
    let declared = Llm_provider.Discovery.endpoint
      ~protocol:Llm_provider.Discovery.Ollama_native
      ~capabilities:Llm_provider.Capabilities.ollama_capabilities endpoint in
    ignore (Llm_provider.Provider_registry.refresh_llama_endpoints ~sw ~net ~endpoints:[declared] ());
    ignore (Discovery_cache.get_cached_or_refresh ());
    with_env "MASC_TEST_OLLAMA_KEY" (Some "test-ollama-secret") (fun () ->
      with_catalog ~endpoint (fun () ->
        match Runtime_model_string.parse_model_string
          ~api_key_env_overrides:["ollama-keyed", "MASC_TEST_OLLAMA_KEY"] "ollama-keyed:auto" with
        | Some config ->
          Alcotest.(check string) "keyed auto cannot borrow the public model"
            "keyed-model" config.Provider_config.model_id;
          Alcotest.(check int) "fresh public cache cannot suppress the authenticated probe"
            1 !authenticated_tag_requests
        | None -> Alcotest.fail "authenticated Ollama discovery was refused")))

let ollama_auto_renews_stale_selected_endpoint () =
  let model_name = ref "cached-model" in
  let tag_requests = ref 0 in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/api/tags" ->
      incr tag_requests;
      let body = Yojson.Safe.to_string
        (`Assoc ["models", `List [`Assoc ["name", `String !model_name]]]) in
      Cohttp_eio.Server.respond_string ~status:`OK ~body ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock ~endpoint ->
    Discovery_cache.set_env ~sw ~net ~clock;
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock 1000.;
    Time_compat.set_clock (clock :> float Eio.Time.clock_ty Eio.Resource.t);
    Fun.protect ~finally:Time_compat.clear_clock (fun () ->
      let declared = Llm_provider.Discovery.endpoint
        ~protocol:Llm_provider.Discovery.Ollama_native
        ~capabilities:Llm_provider.Capabilities.ollama_capabilities endpoint in
      ignore (Llm_provider.Provider_registry.refresh_llama_endpoints ~sw ~net ~endpoints:[declared] ());
      ignore (Discovery_cache.get_cached_or_refresh ());
      with_catalog ~endpoint (fun () ->
        let initial = Runtime_model_string.parse_model_string "ollama:auto" in
        (match initial with
         | Some config -> Alcotest.(check string) "fresh cache supplies its model"
           "cached-model" config.Provider_config.model_id
         | None -> Alcotest.fail "production cache did not retain the selected endpoint");
        let requests_before_expiry = !tag_requests in
        model_name := "fresh-model";
        Eio_mock.Clock.set_time clock 1031.;
        match Runtime_model_string.parse_model_string "ollama:auto" with
        | Some config ->
          Alcotest.(check string) "stale cache cannot hide a model change"
            "fresh-model" config.Provider_config.model_id;
          Alcotest.(check int) "only the expired selected endpoint is probed again"
            (requests_before_expiry + 1) !tag_requests
        | None -> Alcotest.fail "expired Ollama discovery was refused")))

let ollama_auto_does_not_reuse_openai_compatible_cache () =
  let native_requests = ref 0 in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/health" -> Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok" ()
    | "/v1/models" -> Cohttp_eio.Server.respond_string ~status:`OK
      ~body:{|{"data":[{"id":"openai-model","owned_by":"local"}]}|} ()
    | "/api/tags" ->
      incr native_requests;
      Cohttp_eio.Server.respond_string ~status:`OK
        ~body:{|{"models":[{"name":"native-model"}]}|} ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock ~endpoint ->
    Discovery_cache.set_env ~sw ~net ~clock;
    let declared = Llm_provider.Discovery.endpoint
      ~protocol:Llm_provider.Discovery.Openai_compatible
      ~capabilities:Llm_provider.Capabilities.openai_compat_chat_capabilities endpoint in
    ignore (Llm_provider.Provider_registry.refresh_llama_endpoints ~sw ~net ~endpoints:[declared] ());
    ignore (Discovery_cache.get_cached_or_refresh ());
    with_catalog ~endpoint (fun () ->
      match Runtime_model_string.parse_model_string "ollama:auto" with
      | Some config ->
        Alcotest.(check string) "OpenAI inventory cannot satisfy Ollama auto"
          "native-model" config.Provider_config.model_id;
        Alcotest.(check int) "wrong-protocol cache falls through to native discovery"
          1 !native_requests
      | None -> Alcotest.fail "same-URL native Ollama discovery was refused"))

let ollama_auto_does_not_refresh_other_endpoints () =
  let other_hits = ref 0 in
  let other_handler _conn req body =
    incr other_hits;
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/health" -> Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok" ()
    | "/api/tags" -> Cohttp_eio.Server.respond_string ~status:`OK
      ~body:{|{"models":[{"name":"other-model"}]}|} ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  let selected_handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/health" -> Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok" ()
    | "/api/tags" -> Cohttp_eio.Server.respond_string ~status:`OK
      ~body:{|{"models":[{"name":"qwen-local"}]}|} ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server selected_handler (fun ~sw ~net ~clock ~endpoint ->
    Discovery_cache.set_env ~sw ~net ~clock;
    with_mock_server_on ~sw ~net other_handler (fun ~endpoint:other_endpoint ->
      let declared = Llm_provider.Discovery.endpoint
        ~protocol:Llm_provider.Discovery.Ollama_native
        ~capabilities:Llm_provider.Capabilities.ollama_capabilities other_endpoint in
      ignore (Llm_provider.Provider_registry.refresh_llama_endpoints ~sw ~net ~endpoints:[declared] ());
      other_hits := 0;
      with_catalog ~endpoint (fun () ->
        match Runtime_model_string.parse_model_string "ollama:auto" with
        | Some config ->
          Alcotest.(check string) "selected endpoint resolves its own model"
            "qwen-local" config.Provider_config.model_id;
          Alcotest.(check int) "cold cache does not refresh unrelated endpoints" 0 !other_hits
        | None -> Alcotest.fail "cold-cache Ollama discovery was refused")))

let ollama_auto_reuses_cold_public_observation () =
  let tag_requests = ref 0 in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/api/tags" ->
      incr tag_requests;
      Cohttp_eio.Server.respond_string ~status:`OK
        ~body:{|{"models":[{"name":"public-model"}]}|} ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock ~endpoint ->
    Discovery_cache.set_env ~sw ~net ~clock;
    with_catalog ~endpoint (fun () ->
      match Runtime_model_string.parse_model_string "ollama:auto",
        Runtime_model_string.parse_model_string "ollama:auto" with
      | Some first, Some second ->
        Alcotest.(check string) "cold probe supplies its own public model"
          "public-model" first.Provider_config.model_id;
        Alcotest.(check string) "the same public observation supplies the next resolution"
          "public-model" second.Provider_config.model_id;
        Alcotest.(check int) "a fresh cold observation does not probe twice"
          1 !tag_requests
      | _ -> Alcotest.fail "public Ollama auto discovery was refused"))

let ollama_auto_preserves_public_observation_through_global_refresh () =
  let selected_tag_requests = ref 0 in
  let handler model hits _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/api/tags" ->
      incr hits;
      Cohttp_eio.Server.respond_string ~status:`OK
        ~body:(Printf.sprintf "{\"models\":[{\"name\":%S}]}" model) ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server (handler "selected-model" selected_tag_requests) (fun ~sw ~net ~clock ~endpoint ->
    Discovery_cache.set_env ~sw ~net ~clock;
    with_mock_server_on ~sw ~net (handler "other-model" (ref 0)) (fun ~endpoint:other_endpoint ->
      let declared = Llm_provider.Discovery.endpoint
        ~protocol:Llm_provider.Discovery.Ollama_native
        ~capabilities:Llm_provider.Capabilities.ollama_capabilities other_endpoint in
      ignore (Llm_provider.Provider_registry.refresh_llama_endpoints ~sw ~net ~endpoints:[declared] ());
      with_catalog ~endpoint (fun () ->
        (match Runtime_model_string.parse_model_string "ollama:auto" with
         | Some config -> Alcotest.(check string) "cold public discovery resolves its model"
           "selected-model" config.Provider_config.model_id
         | None -> Alcotest.fail "cold public Ollama discovery was refused");
        ignore (Discovery_cache.get_cached_or_refresh ());
        match Runtime_model_string.parse_model_string "ollama:auto" with
        | Some config ->
          Alcotest.(check string) "an unrelated refresh preserves the selected public model"
            "selected-model" config.Provider_config.model_id;
          Alcotest.(check int) "fresh public observation survives an unrelated refresh"
            1 !selected_tag_requests
        | None -> Alcotest.fail "an unrelated refresh discarded the selected public model")))

let ollama_auto_scopes_cached_models_to_the_credential () =
  let requests = ref [] in
  let record account =
    let count = Option.value (List.assoc_opt account !requests) ~default:0 + 1 in
    requests := (account, count) :: List.remove_assoc account !requests;
    account
  in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/api/tags" ->
      let account = match Cohttp.Header.get (Cohttp.Request.headers req) "authorization" with
        | Some "Bearer test-key-a" -> record "a"
        | Some "Bearer test-key-b" -> record "b"
        | _ -> record "unexpected" in
      Cohttp_eio.Server.respond_string ~status:`OK
        ~body:(Printf.sprintf "{\"models\":[{\"name\":\"model-%s\"}]}" account) ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  let resolve_twice ~endpoint key expected =
    with_env "MASC_TEST_OLLAMA_KEY" (Some key) (fun () ->
      with_catalog ~endpoint (fun () ->
        List.iter (fun _ ->
          match Runtime_model_string.parse_model_string
            ~api_key_env_overrides:["ollama-keyed", "MASC_TEST_OLLAMA_KEY"] "ollama-keyed:auto" with
          | Some config -> Alcotest.(check string) "credential owns its discovered model"
            expected config.Provider_config.model_id
          | None -> Alcotest.fail "authenticated Ollama discovery was refused") [(); ()]))
  in
  with_mock_server handler (fun ~sw ~net ~clock ~endpoint ->
    Discovery_cache.set_env ~sw ~net ~clock;
    resolve_twice ~endpoint "test-key-a" "model-a";
    resolve_twice ~endpoint "test-key-b" "model-b";
    Alcotest.(check (list (pair string int))) "each credential probes once, not globally or per call"
      ["a", 1; "b", 1] (List.sort compare !requests))

let ollama_auto_probe_uses_declared_deadline () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  let tag_requests = ref 0 in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/api/tags" ->
      incr tag_requests;
      Eio_mock.Clock.advance clock;
      let pending, _ = Eio.Promise.create () in
      Eio.Promise.await pending
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock:_ ~endpoint ->
    Discovery_cache.set_env ~sw ~net ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t);
    with_catalog ~endpoint (fun () ->
      (match Eio.Time.with_timeout clock 5. (fun () ->
        Ok (Runtime_model_string.parse_model_string "ollama:auto")) with
       | Ok None -> ()
       | Ok (Some _) -> Alcotest.fail "an unanswered probe invented a model"
       | Error `Timeout -> Alcotest.fail "the Ollama probe escaped its declared deadline");
      Alcotest.(check (float 0.001)) "Ollama probe expires at its declared four seconds"
        1004.0 (Eio.Time.now clock);
      Alcotest.(check int) "the bounded discovery attempt really reached the endpoint"
        1 !tag_requests))

let ollama_cloud_auto_uses_declared_discovery () =
  let deadlines = ref [] in
  with_env "MASC_TEST_OLLAMA_KEY" (Some "cloud-test-secret") (fun () ->
    let discover ~headers:_ ~timeout_s _ =
      deadlines := timeout_s :: !deadlines;
      Some "cloud-model" in
    match Runtime_model_string.parse_model_string ~discover
      ~api_key_env_overrides:["ollama_cloud", "MASC_TEST_OLLAMA_KEY"] "ollama_cloud:auto" with
    | Some config ->
      Alcotest.(check string) "cloud auto keeps its discovered model"
        "cloud-model" config.Provider_config.model_id;
      Alcotest.(check (option string)) "cloud auto preserves its provider"
        (Some "ollama_cloud") config.Provider_config.provider_id;
      Alcotest.(check (list (float 0.0))) "cloud auto uses its declared full deadline"
        [600.0] !deadlines
    | None -> Alcotest.fail "cloud auto was disabled by a missing discovery deadline")

let expect_timeout clock request =
  match Eio.Time.with_timeout clock 5. (fun () -> Ok (request ())) with
  | Ok (Error (Http_client.TimeoutError _)) ->
    Alcotest.(check (float 0.001)) "timeout fires at the declared four seconds"
      1004.0 (Eio.Time.now clock)
  | Ok (Error _) -> Alcotest.fail "the request failed before its declared deadline"
  | Ok (Ok _) -> Alcotest.fail "the request succeeded without observing its deadline"
  | Error `Timeout -> Alcotest.fail "the request escaped its declared deadline"

let expect_stalled_dns_timeout clock request =
  Eio_main.run @@ fun _ ->
  Eio.Switch.run @@ fun sw ->
  let pending, _ = Eio.Promise.create () in
  let module Stalled_dns = struct
    type t = unit
    type tag = [`Generic | `Unix]
    let unsupported _ = invalid_arg "stalled DNS fixture supports only getaddrinfo"
    let listen = unsupported
    let connect = unsupported
    let datagram_socket = unsupported
    let getaddrinfo () ~service:_ _ =
      Eio_mock.Clock.advance clock;
      Eio.Promise.await pending
    let getnameinfo = unsupported
  end in
  let net : [`Generic | `Unix] Eio.Net.ty Eio.Resource.t =
    Eio.Resource.T ((), Eio.Resource.handler
      (Eio.Resource.bindings (Eio.Net.Pi.network (module Stalled_dns)))) in
  expect_timeout clock (fun () -> request ~sw ~net)

let get_sync_deadline_covers_dns_resolution () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  expect_stalled_dns_timeout clock (fun ~sw ~net ->
    Http_client.get_sync ~sw ~net ~clock ~timeout_s:4.0
      ~url:"http://stalled-dns.invalid/api/tags" ~headers:[] ())

let delete_sync_deadline_covers_dns_resolution () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  expect_stalled_dns_timeout clock (fun ~sw ~net ->
    Http_client.delete_sync ~sw ~net ~clock ~timeout_s:4.0
      ~url:"http://stalled-dns.invalid/api/tags" ~headers:[] ())

let post_sync_deadline_covers_dns_resolution () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  expect_stalled_dns_timeout clock (fun ~sw ~net ->
    Http_client.post_sync ~sw ~net ~clock ~timeout_s:4.0
      ~url:"http://stalled-dns.invalid/api/tags" ~headers:[] ~body:"{}" ())

let get_sync_deadline_covers_stalled_body () =
  Eio_main.run @@ fun env ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  try
    Eio.Switch.run @@ fun sw ->
    let socket = Eio.Net.listen env#net ~sw ~backlog:128 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
    let port = match Eio.Net.listening_addr socket with
      | `Tcp (_, port) -> port
      | `Unix _ -> Alcotest.fail "expected a TCP listener" in
    Eio.Fiber.fork ~sw (fun () ->
      let flow, _ = Eio.Net.accept ~sw socket in
      let reader = Eio.Buf_read.of_flow ~max_size:65536 flow in
      let rec drain_headers () =
        match Eio.Buf_read.line reader with
        | "" -> ()
        | _ -> drain_headers ()
      in
      drain_headers ();
      Eio.Flow.copy_string
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n" flow;
      Eio_mock.Clock.advance clock;
      let pending, _ = Eio.Promise.create () in
      Eio.Promise.await pending);
    let endpoint = Printf.sprintf "http://127.0.0.1:%d/api/tags" port in
    expect_timeout clock (fun () ->
      Http_client.get_sync ~sw ~net:env#net ~clock ~timeout_s:4.0
        ~url:endpoint ~headers:[] ());
    Eio.Switch.fail sw Exit
  with
  | Unix.Unix_error ((Unix.EPERM | Unix.EADDRINUSE), "bind", _) -> Alcotest.skip ()
  | Exit -> ()

let ollama_auto_without_declared_deadline_does_not_probe () =
  let tag_requests = ref 0 in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/api/tags" ->
      incr tag_requests;
      Cohttp_eio.Server.respond_string ~status:`OK
        ~body:{|{"models":[{"name":"unbounded-model"}]}|} ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock ~endpoint ->
    Discovery_cache.set_env ~sw ~net ~clock;
    with_catalog ~endpoint (fun () ->
      let previous = Provider_catalog.global () in
      Fun.protect
        ~finally:(fun () -> match previous with
          | Some catalog -> Provider_catalog.set_global catalog
          | None -> Provider_catalog.clear_global ())
        (fun () ->
          let overlay = Provider_catalog.of_json (`Assoc [
            "schema_version", `Int 1;
            "providers", `List [`Assoc [
              "id", `String "ollama";
              "kind", `String "ollama";
              "base_url", `String endpoint;
              "request_path", `String "/api/chat";
              "auth", `Assoc ["type", `String "none"];
              "capabilities_base", `String "ollama"]]]) in
          (match overlay with
           | Ok catalog -> Provider_catalog.set_global catalog
           | Error detail -> Alcotest.fail detail);
          Alcotest.(check bool) "an undeclared deadline refuses discovery instead of waiting"
            true (Runtime_model_string.parse_model_string "ollama:auto" = None);
          Alcotest.(check int) "an undeclared deadline never starts a probe"
            0 !tag_requests)))

let ollama_auto_uses_binding_endpoint () = with_catalog (fun () ->
  let calls = ref [] in
  let discover ~headers:_ ~timeout_s:_ endpoint = calls := endpoint :: !calls; Some "qwen-local" in
  let config = match Runtime_model_string.parse_model_string ~discover "ollama:auto" with
    | Some config -> config | None -> Alcotest.fail "discovered Ollama model was refused" in
  Alcotest.(check string) "auto resolves the model discovered for this binding"
    "qwen-local" config.Provider_config.model_id;
  Alcotest.(check (list string)) "discovery is scoped to the selected endpoint"
    ["http://127.0.0.1:11434"] !calls)
let ollama_auto_without_discovered_model_stays_refused () = with_catalog (fun () ->
  let calls = ref [] in
  let discover ~headers:_ ~timeout_s:_ endpoint = calls := endpoint :: !calls; None in
  Alcotest.(check bool) "missing discovered model does not invent a config" true
    (Runtime_model_string.parse_model_string ~discover "ollama:auto" = None);
  Alcotest.(check (list string)) "absence is checked only at the selected endpoint"
    ["http://127.0.0.1:11434"] !calls)
let declared_default_skips_discovery () = with_catalog (fun () ->
  let discover ~headers:_ ~timeout_s:_ _ = Alcotest.fail "declared default must not consult discovery" in
  let config = match Runtime_model_string.parse_model_string ~discover "label-b:auto" with
    | Some config -> config | None -> Alcotest.fail "declared default was refused" in
  Alcotest.(check string) "declared default wins without discovery" "overlap" config.model_id)

let global_registry_probe_uses_declared_deadline () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  let tag_requests = ref 0 in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/api/tags" ->
      incr tag_requests;
      Eio_mock.Clock.advance clock;
      let pending, _ = Eio.Promise.create () in
      Eio.Promise.await pending
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock:_ ~endpoint ->
    let declared = Discovery.endpoint
      ~discovery_timeout_s:4.0
      ~protocol:Discovery.Ollama_native
      ~capabilities:Capabilities.ollama_capabilities endpoint in
    (match Eio.Time.with_timeout clock 5. (fun () ->
       Ok (Provider_registry.refresh_llama_endpoints
         ~sw ~net ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
         ~endpoints:[declared] ())) with
     | Ok (Error (Provider_registry.No_healthy_endpoints [ status ])) ->
       Alcotest.(check bool) "declared timeout produces an unhealthy endpoint"
         false status.healthy
     | Ok (Error Provider_registry.No_endpoints_declared) ->
       Alcotest.fail "the declared endpoint disappeared"
     | Ok (Error (Provider_registry.No_healthy_endpoints _)) ->
       Alcotest.fail "registry returned an unexpected endpoint count"
     | Ok (Ok _) -> Alcotest.fail "an unanswered registry probe became healthy"
     | Error `Timeout -> Alcotest.fail "the registry probe escaped its declared deadline");
    Alcotest.(check (float 0.001)) "registry probe expires at its declared four seconds"
      1004.0 (Eio.Time.now clock);
    Alcotest.(check int) "the bounded registry attempt reached the endpoint"
      1 !tag_requests)

let global_cache_probe_preserves_declared_deadline () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  let tag_requests = ref 0 in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/api/tags" ->
      incr tag_requests;
      if !tag_requests = 1 then
        Cohttp_eio.Server.respond_string ~status:`OK
          ~body:{|{"models":[{"name":"global-model"}]}|} ()
      else
        (Eio_mock.Clock.advance clock;
         let pending, _ = Eio.Promise.create () in
         Eio.Promise.await pending)
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock:_ ~endpoint ->
    Discovery_cache.set_env ~sw ~net
      ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t);
    let declared = Discovery.endpoint
      ~discovery_timeout_s:4.0
      ~protocol:Discovery.Ollama_native
      ~capabilities:Capabilities.ollama_capabilities endpoint in
    (match Provider_registry.refresh_llama_endpoints
       ~sw ~net ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
       ~endpoints:[declared] () with
     | Ok [ status ] ->
       Alcotest.(check bool) "initial registry activation succeeds" true status.healthy
     | Ok _ -> Alcotest.fail "registry returned an unexpected activation count"
     | Error Provider_registry.No_endpoints_declared ->
       Alcotest.fail "the declared endpoint disappeared"
     | Error (Provider_registry.No_healthy_endpoints _) ->
       Alcotest.fail "the immediate activation probe failed");
    (match Eio.Time.with_timeout clock 5. (fun () ->
       Ok (Discovery_cache.get_cached_or_refresh ())) with
     | Ok [ status ] ->
       Alcotest.(check bool) "global cache observes the declared timeout"
         false status.healthy
     | Ok _ -> Alcotest.fail "global cache returned an unexpected endpoint count"
     | Error `Timeout -> Alcotest.fail "the global cache escaped its declared deadline");
    Alcotest.(check (float 0.001)) "global cache expires at its declared four seconds"
      1004.0 (Eio.Time.now clock);
    Alcotest.(check int) "activation and bounded refresh both reached the endpoint"
      2 !tag_requests)

let () = Alcotest.run "runtime model label binding"
  ["provider authority",["identity",`Quick,identity;"context",`Quick,context;"policy and wire",`Quick,policy];
   "custom endpoint",["missing",`Quick,missing_endpoint;"ambient",`Quick,ambient_endpoint;
     "invalid",`Quick,invalid_endpoint;"malformed",`Quick,malformed_endpoint;
     "ports",`Quick,endpoint_ports;"authority",`Quick,endpoint_authority;
     "explicit",`Quick,explicit_endpoint];
   "catalog defaults",["missing default",`Quick,no_default;"declared default",`Quick,declared_default;
     "canonical alias",`Quick,alias_default;"supported is not default",`Quick,supported_is_not_default;
     "projection",`Quick,projected_defaults];
   "ollama auto",["production cache",`Quick,ollama_auto_uses_production_discovery_cache;
     "cold public cache",`Quick,ollama_auto_reuses_cold_public_observation;
     "public cache survives refresh",`Quick,ollama_auto_preserves_public_observation_through_global_refresh;
     "credential-scoped cache",`Quick,ollama_auto_scopes_cached_models_to_the_credential;
     "declared probe deadline",`Quick,ollama_auto_probe_uses_declared_deadline;
     "cloud declared discovery",`Quick,ollama_cloud_auto_uses_declared_discovery;
     "DNS deadline",`Quick,get_sync_deadline_covers_dns_resolution;
     "DELETE DNS deadline",`Quick,delete_sync_deadline_covers_dns_resolution;
     "POST DNS deadline",`Quick,post_sync_deadline_covers_dns_resolution;
     "stalled body deadline",`Quick,get_sync_deadline_covers_stalled_body;
     "missing probe deadline",`Quick,ollama_auto_without_declared_deadline_does_not_probe;
     "endpoint discovery",`Quick,ollama_auto_uses_binding_endpoint;
     "no discovered model",`Quick,ollama_auto_without_discovered_model_stays_refused;
     "declared default skips discovery",`Quick,declared_default_skips_discovery;
     "authenticated discovery",`Quick,ollama_auto_sends_resolved_credential;
     "authenticated fresh cache isolation",`Quick,ollama_auto_does_not_reuse_unauthenticated_cache_for_keyed_binding;
     "stale selected endpoint",`Quick,ollama_auto_renews_stale_selected_endpoint;
     "wrong protocol cache",`Quick,ollama_auto_does_not_reuse_openai_compatible_cache;
     "cold cache endpoint isolation",`Quick,ollama_auto_does_not_refresh_other_endpoints;
     "global registry declared deadline",`Quick,global_registry_probe_uses_declared_deadline;
     "global cache declared deadline",`Quick,global_cache_probe_preserves_declared_deadline]]
