(** #27898: same wire/model text, different explicit provider authority. *)
open Llm_provider

let catalog_text = {|
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
|}

let catalog () = match Model_catalog.of_toml_string ~source:"label binding fixture" catalog_text with
  | Ok catalog -> catalog | Error detail -> Alcotest.fail detail
let with_catalog f =
  let previous = Model_catalog.global () in
  Fun.protect ~finally:(fun () -> match previous with
    | Some catalog -> Model_catalog.set_global catalog | None -> Model_catalog.clear_global ())
    (fun () -> Model_catalog.set_global (catalog ()); f ())
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
         api_key_env="";auth=Provider_catalog.No_auth;default_model=None;max_context=None;
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
              [] (Provider_runtime_projection.default_execution_model_strings "fixture")))))))

let () = Alcotest.run "runtime model label binding"
  ["provider authority",["identity",`Quick,identity;"context",`Quick,context;"policy and wire",`Quick,policy];
   "custom endpoint",["missing",`Quick,missing_endpoint;"ambient",`Quick,ambient_endpoint;
     "invalid",`Quick,invalid_endpoint;"malformed",`Quick,malformed_endpoint;
     "ports",`Quick,endpoint_ports;"authority",`Quick,endpoint_authority;
     "explicit",`Quick,explicit_endpoint];
   "catalog defaults",["missing default",`Quick,no_default;"declared default",`Quick,declared_default;
     "canonical alias",`Quick,alias_default;"supported is not default",`Quick,supported_is_not_default;
     "projection",`Quick,projected_defaults]]
