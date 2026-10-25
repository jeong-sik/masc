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

let with_endpoint_env value f =
  let key = "CUSTOM_LLM_BASE_URL" in
  let previous = Sys.getenv_opt key in
  Fun.protect ~finally:(fun () -> match previous with
    | None -> Unix.unsetenv key | Some previous -> Unix.putenv key previous)
    (fun () ->
      (match value with None -> Unix.unsetenv key | Some value -> Unix.putenv key value);
      f ())
let missing_endpoint () = with_endpoint_env None (fun () ->
  Alcotest.(check bool) "custom label cannot borrow discovery endpoint" true
    (Runtime_model_string.parse_model_string "custom:overlap"=None))
let ambient_endpoint () = with_endpoint_env (Some "https://ambient.invalid") (fun () ->
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
let explicit_endpoint () = with_endpoint_env (Some "https://ambient.invalid") (fun () ->
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

let () = Alcotest.run "runtime model label binding"
  ["provider authority",["identity",`Quick,identity;"context",`Quick,context;"policy and wire",`Quick,policy];
   "custom endpoint",["missing",`Quick,missing_endpoint;"ambient",`Quick,ambient_endpoint;
     "invalid",`Quick,invalid_endpoint;"explicit",`Quick,explicit_endpoint]]
