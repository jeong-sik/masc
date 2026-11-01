open Llm_provider

let get = function Ok value -> value | Error detail -> Alcotest.fail detail

let catalog_source = {|
[[providers]]
id = "catalog-provider"
kind = "openai_compat"
base_url = "https://catalog.invalid"
request_path = "/v1/chat/completions"
auth = "none"
capabilities_base = "openai_chat"
default_model = "catalog-model"
serves_bare_models = ["catalog-model"]
[[models]]
model_id = "catalog-model"
supported_models = ["catalog-model"]
supports_reasoning = true
|}

let with_catalog run =
  let previous = Model_catalog.global () in
  let catalog = get (Model_catalog.of_toml_string ~source:"composition fixture" catalog_source) in
  Fun.protect ~finally:(fun () -> match previous with
    | Some previous -> Model_catalog.set_global previous
    | None -> Model_catalog.clear_global ()) (fun () ->
    Model_catalog.set_global catalog; run catalog)

let selected_config catalog =
  let declarations = Provider_declarations.of_catalogs ~models:(Some catalog) ~providers:None
      |> Result.map_error Provider_declarations.error_to_string |> get in
  let binding = match Agent_core.Provider_runtime_binding.find_in_declarations declarations "catalog-provider" with
    | Some binding -> binding | None -> Alcotest.fail "provider selection disappeared" in
  Agent_core.Provider_runtime_binding.to_provider_config binding
  |> Result.map_error Agent_core.Error.to_string |> get

let raw_config () = Provider_config.make ~kind:OpenAI_compat ~provider_id:"catalog-provider"
    ~model_id:"catalog-model" ~base_url:"https://catalog.invalid" ()

let resolved config = match Provider_config.capabilities_for_config_model config with
  | Some caps -> caps | None -> Alcotest.fail "exact admitted model policy disappeared"

let test_catalog_allowlist projection () = with_catalog (fun catalog ->
  let caps = projection catalog in
  Alcotest.(check (option (list string))) "catalog allow-list reaches the resolved policy"
    (Some ["catalog-model"]) caps.Capabilities.supported_models)

let test_bare_row_has_one_base () = with_catalog (fun catalog ->
  let selected = resolved (selected_config catalog) in
  let raw = resolved (raw_config ()) in
  Alcotest.(check bool) "provider-independent row has the same tools policy through selection"
    raw.supports_tools selected.supports_tools;
  Alcotest.(check bool) "base-less bare model does not inherit provider tool support" false
    selected.supports_tools)

let () = Alcotest.run "Model catalog composition"
  ["resolution",[
    Alcotest.test_case "bare catalog keeps model allow-list" `Quick
      (test_catalog_allowlist (fun _ -> match Capabilities.for_model_id "catalog-model" with
        | Some caps -> caps | None -> Alcotest.fail "model lookup failed"));
    Alcotest.test_case "raw provider config keeps model allow-list" `Quick
      (test_catalog_allowlist (fun _ -> resolved (raw_config ())));
    Alcotest.test_case "selected provider keeps model allow-list" `Quick
      (test_catalog_allowlist (fun catalog -> resolved (selected_config catalog)));
    Alcotest.test_case "selected and raw bare-row bases agree" `Quick test_bare_row_has_one_base
  ]]
