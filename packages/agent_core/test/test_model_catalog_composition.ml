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
  let previous = Llm_provider.Catalog_snapshot.current () in
  let catalog = get (Model_catalog.of_toml_string ~source:"composition fixture" catalog_source) in
  Fun.protect ~finally:(fun () -> Llm_provider.Catalog_snapshot.publish previous) (fun () ->
    (Llm_provider.Catalog_snapshot.publish (Agent_core_test_deps.admit_catalogs ~models:(Some (catalog)) ~providers:(None))); run catalog)

let selected_config catalog =
  let declarations = Catalog_snapshot.of_catalogs ~models:(Some catalog) ~providers:None
      |> Result.map_error Catalog_snapshot.error_to_string |> get in
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

let declaration ?(extra=[]) model_id =
  `Assoc (("model_id", `String model_id) :: extra)

let overrides entries = Capability_manifest.of_json
  (`Assoc ["schema_version",`Int 2;"models",`List entries]) |> get

let with_catalog_value catalog run =
  let previous = Llm_provider.Catalog_snapshot.current () in
  Fun.protect ~finally:(fun () -> Llm_provider.Catalog_snapshot.publish previous)
    (fun () -> (Llm_provider.Catalog_snapshot.publish (Agent_core_test_deps.admit_catalogs ~models:(Some (catalog)) ~providers:(None))); run ())

let row catalog name =
  match Model_catalog.lookup catalog (get (Model_identifiers.Model_id.of_string name)) with
  | Some row -> row | None -> Alcotest.fail "composed bare model missing"

let test_json_selected_and_raw_agree () = with_catalog (fun catalog ->
  let composed = Model_catalog.with_model_overrides catalog (overrides
    [declaration "CATALOG-MODEL" ~extra:[
      "max_context_tokens",`Int 65536;"supports_reasoning",`Bool true;
      "emits_usage_tokens",`Bool false;"supported_models",`List [`String "catalog-model"];
      "anthropic_thinking_control",`String "adaptive_default"]]) in
  with_catalog_value composed (fun () ->
    let selected = resolved (selected_config composed) and raw = resolved (raw_config ()) in
    Alcotest.(check bool) "all capability fields agree across selected and raw paths" true (selected=raw);
    Alcotest.(check (option int)) "JSON context reaches request policy" (Some 65536) selected.max_context_tokens;
    Alcotest.(check bool) "base-less JSON does not inherit provider tools" false selected.supports_tools;
    Alcotest.(check bool) "JSON usage declaration survives catalog projection" false selected.emits_usage_tokens;
    Alcotest.(check (option (list string))) "JSON model allow-list survives"
      (Some ["catalog-model"]) selected.supported_models;
    Alcotest.(check bool) "JSON thinking control is read from the same row" true
      (Capabilities.anthropic_thinking_control_for_provider_model_id
        ~provider:(Model_catalog.Declared_provider "catalog-provider") ~model_id:"catalog-model"
       =Some Capabilities.Anthropic_adaptive_default);
    Alcotest.(check bool) "original catalog remains immutable" true
      ((row catalog "catalog-model").max_context_tokens=None)))

let test_composed_policy_reaches_request_body () = with_catalog (fun catalog ->
  let composed=Model_catalog.with_model_overrides catalog (overrides
    [declaration "catalog-model" ~extra:["base",`String "openai_chat";
      "max_output_tokens",`Int 17;"supports_reasoning",`Bool true;
      "thinking_control_format",`String "reasoning_effort";
      "accepted_reasoning_efforts",`List [`String "high"]]]) in
  with_catalog_value composed (fun () ->
    let selected=selected_config composed in
    List.iter (fun config ->
      let config={config with Provider_config.max_tokens=Some 64;
        reasoning_effort=Some Reasoning_effort.High} in
      let body=Backend_openai_request.build_request_assoc ~config
        ~messages:[Types.user_msg "return an answer"] () in
      let open Yojson.Safe.Util in
      Alcotest.(check int) "composed output ceiling reaches serialized request"
        17 (body |> member "max_tokens" |> to_int);
      Alcotest.(check string) "composed reasoning dialect reaches serialized request"
        "high" (body |> member "reasoning_effort" |> to_string))
      [selected;raw_config ();{selected with Provider_config.base_url="https://rotated.invalid"}]))

let test_preserve_exact_metadata () =
  let source = catalog_source ^ {|
suggested_clients = ["codex"]
task = "transcription"
max_context_tokens = 8192
input_per_million = 2.0
output_per_million = 4.0
cache_write_multiplier = 1.25
cache_read_multiplier = 0.1
serving_constraint_source_kind = "probe"
serving_constraint_source = "probe://composition"
serving_constraint_checked_at_unix_s = 100
serving_constraint_expires_at_unix_s = 200
serving_constraint_confidence = "high"
serving_constraint_accepted_through_tokens = 4000
serving_constraint_rejected_from_tokens = 5000
|} in
  let original = Model_catalog.of_toml_string ~source:"metadata fixture" source |> get in
  let composed = Model_catalog.with_model_overrides original (overrides [
    declaration "catalog-model" ~extra:["max_context_tokens",`Int 65536];
    declaration "new-model"] ) in
  let before = row original "catalog-model" and after = row composed "CATALOG-MODEL" in
  Alcotest.(check bool) "exact row's serving evidence remains distinct from context" true
    (after.serving_constraint=before.serving_constraint && Option.is_some after.serving_constraint);
  Alcotest.(check bool) "task and client suggestions are retained" true
    (after.task=before.task && after.suggested_clients=before.suggested_clients);
  with_catalog_value original (fun () ->
    let before = Pricing.pricing_for_model_opt "catalog-model" in
    with_catalog_value composed (fun () ->
      Alcotest.(check bool) "complete price and cache multipliers are retained" true
        (Option.is_some before && Pricing.pricing_for_model_opt "catalog-model"=before);
      Alcotest.(check bool) "new row has no invented price" true
        (Pricing.pricing_for_model_opt "new-model"=None)));
  Alcotest.(check bool) "new row borrows no unrelated metadata" true
    (let row=row composed "new-model" in row.serving_constraint=None && row.task=None
      && row.suggested_clients=[] && row.input_per_million=None)

let test_scoped_shadow_and_provider_isolation () =
  let catalog = Model_catalog.of_toml_string ~source:"scoped fixture" (catalog_source ^ {|
[[models]]
model_id = "catalog-model"
provider_name = "catalog-provider"
max_context_tokens = 1234
|}) |> get in
  let composed=Model_catalog.with_model_overrides catalog (overrides [
    declaration "catalog-model" ~extra:["max_context_tokens",`Int 65536;
      "anthropic_thinking_control",`String "adaptive_default"];
    declaration "new-model" ~extra:["max_context_tokens",`Int 8888]]) in
  with_catalog_value composed (fun () ->
    let selected=resolved (selected_config composed) in
    Alcotest.(check (option int)) "scoped row shadows bare JSON" (Some 1234) selected.max_context_tokens;
    Alcotest.(check bool) "scoped absence does not borrow bare thinking" true
      (Capabilities.anthropic_thinking_control_for_provider_model_id
        ~provider:(Model_catalog.Declared_provider "catalog-provider") ~model_id:"catalog-model"=None);
    List.iter (fun provider ->
      Alcotest.(check bool) "unowned bare row grants no capabilities" true
        (Capabilities.for_provider_model_id ~wire:(Some Provider_kind.OpenAI_compat)
          ~provider ~model_id:"new-model"=None))
      [Model_catalog.Declared_provider "unknown";Model_catalog.Anonymous_wire Provider_kind.OpenAI_compat];
    Alcotest.(check (option int)) "anonymous native retains explicit bare row"
      (Some 8888) (resolved (Provider_config.make ~kind:Anthropic ~model_id:"new-model"
        ~base_url:"https://native.invalid" ())).max_context_tokens;
    Alcotest.(check bool) "composition leaves provider permissions unchanged" true
      (Model_catalog.provider_entries catalog=Model_catalog.provider_entries composed))

let test_frozen_selection_and_endpoint () = with_catalog (fun original ->
  let compose context = Model_catalog.with_model_overrides original (overrides
    [declaration "catalog-model" ~extra:["max_context_tokens",`Int context]]) in
  let first=compose 4096 and second=compose 65536 in
  with_catalog_value first (fun () ->
    let selected=selected_config first in
    let raw=raw_config () in
    let frozen=Provider_config.freeze_for_request raw in
    (Llm_provider.Catalog_snapshot.publish (Agent_core_test_deps.admit_catalogs ~models:(Some (second)) ~providers:(None)));
    List.iter (fun config ->
      Alcotest.(check (option int)) "admitted policy survives catalog replacement"
        (Some 4096) (resolved config).max_context_tokens) [selected;frozen];
    Alcotest.(check (option int)) "new raw request sees composed replacement"
      (Some 65536) (resolved raw).max_context_tokens;
    Alcotest.(check (option int)) "new selected binding sees composed replacement"
      (Some 65536) (resolved (selected_config second)).max_context_tokens;
    Alcotest.(check bool) "endpoint override preserves selected policy" true
      (resolved selected=resolved {selected with Provider_config.base_url="https://rotated.invalid"})))

let test_provider_overlay_cannot_inherit_seed_permission () = with_catalog (fun original ->
  let composed=Model_catalog.with_model_overrides original (overrides
    [declaration "catalog-model" ~extra:["max_context_tokens",`Int 65536]]) in
  let providers=Provider_catalog.of_json (Yojson.Safe.from_string
    {|{"schema_version":1,"providers":[{"id":"catalog-provider","kind":"openai_compat","base_url":"https://replacement.invalid","request_path":"/v1/chat/completions","auth":{"type":"none"},"default_model":"catalog-model","capabilities_base":"openai_chat"}]}|}) |> get in
  let declarations=Catalog_snapshot.of_catalogs ~models:(Some composed) ~providers:(Some providers)
    |> Result.map_error Catalog_snapshot.error_to_string |> get in
  let policy=Capabilities.resolve_snapshot_request_policy ~snapshot:declarations ~wire:Provider_kind.OpenAI_compat
    ~provider_id:"catalog-provider" ~model_id:"catalog-model" in
  Alcotest.(check bool) "replacement provider cannot borrow seed bare authorization" true
    (Capabilities.request_policy_capabilities policy=Some Capabilities.openai_compat_chat_capabilities))

let test_json_rejection_and_catalog_usage_flag () =
  List.iter (fun json -> Alcotest.(check bool) "invalid declaration is rejected before composition"
    true (Result.is_error (Capability_manifest.of_json (Yojson.Safe.from_string json))))
    [ {|{"schema_version":2,"models":[{"model_id":"same"},{"model_id":"SAME"}]}|};
      {|{"schema_version":2,"models":[{"model_id":"bad","emits_usage_tokens":"false"}]}|};
      {|{"schema_version":2,"models":[{"model_id":"bad","unknown":true}]}|} ];
  let catalog=Model_catalog.of_toml_string ~source:"usage declaration"
    "[[models]]\nmodel_id=\"usage-model\"\nemits_usage_tokens=false\n" |> get in
  with_catalog_value catalog (fun () ->
    let caps=Option.get (Capabilities.for_model_id "usage-model") in
    Alcotest.(check bool) "TOML usage flag reaches the same projection" false caps.emits_usage_tokens);
  Alcotest.(check bool) "wrong TOML usage flag type is rejected" true
    (Result.is_error (Model_catalog.of_toml_string ~source:"bad usage declaration"
      "[[models]]\nmodel_id=\"usage-model\"\nemits_usage_tokens=\"false\"\n"))

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
    ; Alcotest.test_case "composed JSON agrees across request paths" `Quick test_json_selected_and_raw_agree
    ; Alcotest.test_case "composed policy reaches serialized request" `Quick test_composed_policy_reaches_request_body
    ; Alcotest.test_case "exact metadata and unknown prices survive composition" `Quick test_preserve_exact_metadata
    ; Alcotest.test_case "scoped shadowing and provider isolation survive composition" `Quick test_scoped_shadow_and_provider_isolation
    ; Alcotest.test_case "selected and frozen policies survive recomposition" `Quick test_frozen_selection_and_endpoint
    ; Alcotest.test_case "provider overlay cannot inherit bare permission" `Quick test_provider_overlay_cannot_inherit_seed_permission
    ; Alcotest.test_case "strict JSON and TOML usage declarations" `Quick test_json_rejection_and_catalog_usage_flag
  ]]
