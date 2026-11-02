open Llm_provider
module D = Catalog_snapshot
module B = Agent_core.Provider_runtime_binding

let ok = function Ok value -> value | Error message -> Alcotest.fail message
let admitted = function Ok value -> value | Error error -> Alcotest.fail (D.error_to_string error)
let models text = Model_catalog.of_toml_string ~source:"provider-declaration-fixture" text |> ok
let providers text = Provider_catalog.of_json (Yojson.Safe.from_string text) |> ok
let seed = models {|[[providers]]
id = "snapshot-provider"
aliases = ["old-alias"]
kind = "openai_compat"
base_url = "https://seed.example.invalid"
request_path = "/v1/chat/completions"
auth = "api-key"
default_model = "seed-model"
capabilities_base = "openai_chat"
|}
let overlay ?(id="snapshot-provider") ?(alias="new-alias") ?(model="overlay-model") () =
  providers (Printf.sprintf {|{"schema_version":1,"providers":[{
    "id":%S,"aliases":[%S],"kind":"openai_compat",
    "base_url":"https://overlay.example.invalid","request_path":"/v1/responses",
    "auth":{"type":"api_key_env","env":"MASC_TEST_PROVIDER_SNAPSHOT_KEY"},
    "default_model":%S,"max_context":8192,"capabilities_base":"openai_chat",
    "capabilities":{"supports_reasoning":true},"credential_scope":"fixture"}]}|} id alias model)
let snapshot ?providers () = D.of_catalogs ~models:(Some seed) ~providers |> admitted
let entry declarations label = match D.find declarations label with
  | Some entry -> entry | None -> Alcotest.failf "missing declared identity %S" label

let test_exact_replacement () =
  let declarations = snapshot ~providers:(overlay ()) () in
  Alcotest.(check int) "one canonical provider remains" 1 (List.length (D.entries declarations));
  let selected = entry declarations " NEW-ALIAS " in
  Alcotest.(check string) "canonical id" "snapshot-provider" selected.id;
  Alcotest.(check string) "overlay endpoint" "https://overlay.example.invalid" selected.base_url;
  Alcotest.(check string) "overlay codec path" "/v1/responses" selected.request_path;
  Alcotest.(check (option string)) "overlay default" (Some "overlay-model") selected.default_model;
  Alcotest.(check (option int)) "explicit context" (Some 8192) selected.max_context;
  Alcotest.(check bool) "overlay capability" true (Option.fold ~none:false ~some:(fun capabilities -> capabilities.Capability_profile.supports_reasoning) selected.capabilities);
  Alcotest.(check bool) "old seed alias loses authority" true (D.find declarations "old-alias"=None);
  Alcotest.(check bool) "environment auth is explicit data" true
    (selected.authentication=D.Api_key_env "MASC_TEST_PROVIDER_SNAPSHOT_KEY")

let test_declared_spelling_and_lookup_identity () =
  let declarations = snapshot
    ~providers:(overlay ~id:"Snapshot-Provider" ~alias:"New-Alias" ()) () in
  Alcotest.(check int) "case-equivalent exact replacement" 1
    (List.length (D.entries declarations));
  Alcotest.(check string) "declared spelling is retained" "Snapshot-Provider"
    (entry declarations "snapshot-provider").id;
  let registry = Provider_registry.of_declarations declarations in
  Alcotest.(check bool) "registry retains its exact declared key" true
    (Option.is_some (Provider_registry.find registry "Snapshot-Provider"));
  Alcotest.(check bool) "registry invents no lowercase alias" true
    (Option.is_none (Provider_registry.find registry "snapshot-provider"));
  let binding = match B.find_in_declarations declarations " NEW-ALIAS " with
    | Some binding -> binding | None -> Alcotest.fail "missing folded runtime alias" in
  Alcotest.(check string) "runtime canonical identity remains normalized"
    "snapshot-provider" binding.id

let test_cross_source_collision alias =
  match D.of_catalogs ~models:(Some seed)
      ~providers:(Some (overlay ~id:"other-provider" ~alias ())) with
  | Error (D.Conflicting_identity {identity;provider_ids}) ->
    Alcotest.(check string) "conflicting exact identity" alias identity;
    Alcotest.(check (list string)) "both declarations retained in error"
      ["snapshot-provider";"other-provider"] provider_ids
  | Ok _ -> Alcotest.fail "collision must fail typed admission"

let test_distinct_providers_keep_independent_policy () =
  let declarations = snapshot ~providers:(overlay ~id:"other-provider" ~alias:"other-alias" ()) () in
  let registry = Provider_registry.of_declarations declarations in
  let names = Provider_registry.all registry
    |> List.map (fun (entry : Provider_registry.entry) -> entry.name) in
  Alcotest.(check (list string)) "both explicitly declared providers survive projection"
    ["other-provider";"snapshot-provider"] names;
  let select label = match B.find_in_declarations declarations label with
    | Some binding -> binding | None -> Alcotest.failf "missing selected provider %s" label in
  let seed_binding = select "old-alias" in
  let overlay_binding = select "other-alias" in
  Alcotest.(check int) "runtime listing retains both independent providers" 2
    (List.length (B.all_from_declarations declarations));
  Alcotest.(check string) "seed endpoint remains its own" "https://seed.example.invalid"
    seed_binding.base_url;
  Alcotest.(check string) "second endpoint remains its own" "https://overlay.example.invalid"
    overlay_binding.base_url;
  let config binding = match B.to_provider_config binding with
    | Ok config -> config | Error error -> Alcotest.fail (Agent_core.Error.to_string error) in
  let first = config seed_binding in
  let second = config overlay_binding in
  Alcotest.(check (option string)) "first request carries first identity"
    (Some "snapshot-provider") first.provider_id;
  Alcotest.(check (option string)) "second request carries second identity"
    (Some "other-provider") second.provider_id;
  Alcotest.(check bool) "first request does not acquire second reasoning policy" false
    (B.capabilities_for_provider_config first).supports_reasoning;
  Alcotest.(check bool) "second request retains its declared reasoning policy" true
    (B.capabilities_for_provider_config second).supports_reasoning

let test_missing_preset_fails_closed () =
  List.iter (fun id ->
    match Model_catalog.of_toml_string ~source:"missing provider policy"
      (Printf.sprintf {|[[providers]]
id = %S
kind = "openai_compat"
base_url = "https://example.invalid"
request_path = "/v1/chat/completions"
auth = "none"
|} id) with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "a provider id cannot supply a missing capability declaration")
    ["unmapped-fixture"; "openai"; "anthropic"]

let test_snapshot_survives_source_replacement () =
  let previous = D.current () in
  let declarations = snapshot ~providers:(overlay ()) () in
  let replacement = overlay ~model:"later-model" () in
  D.publish (snapshot ~providers:replacement ());
  Fun.protect ~finally:(fun () -> D.publish previous) (fun () ->
    let registry = Provider_registry.of_declarations declarations in
    let registered = match Provider_registry.find registry "snapshot-provider" with
      | Some entry -> entry | None -> Alcotest.fail "missing registry projection" in
    let binding = match B.find_in_declarations declarations "new-alias" with
      | Some binding -> binding | None -> Alcotest.fail "missing binding projection" in
    let listed = B.all_from_declarations declarations in
    Alcotest.(check int) "listing uses admitted canonical entries" 1 (List.length listed);
    Alcotest.(check (option string)) "captured default survives global replacement"
      (Some "overlay-model") binding.default_model;
    Alcotest.(check string) "registry and binding endpoint agree" registered.defaults.base_url binding.base_url;
    Alcotest.(check bool) "registry and binding capability agree" true
      (registered.capabilities=binding.capabilities);
    let config = match B.to_provider_config binding with
      | Ok config -> config | Error error -> Alcotest.fail (Agent_core.Error.to_string error) in
    Alcotest.(check string) "selected request model uses captured default" "overlay-model" config.model_id;
    Alcotest.(check string) "selected request uses captured endpoint" binding.base_url config.base_url;
    Alcotest.(check bool) "selected request retains declared policy" true
      (B.capabilities_for_provider_config config).supports_reasoning)

let test_credential_observation_edge () =
  let name = "MASC_TEST_PROVIDER_SNAPSHOT_KEY" in
  let saved = Sys.getenv_opt name in
  Fun.protect ~finally:(fun () -> match saved with
    | Some value -> Unix.putenv name value | None -> Unix.unsetenv name) (fun () ->
    let declarations = snapshot ~providers:(overlay ()) () in
    let registry = Provider_registry.of_declarations declarations in
    let registered = match Provider_registry.find registry "snapshot-provider" with
      | Some entry -> entry | None -> Alcotest.fail "missing credential projection" in
    Unix.putenv name " ";
    Alcotest.(check bool) "blank credential unavailable" false (registered.is_available ());
    Unix.putenv name "fixture-value";
    Alcotest.(check bool) "credential is observed at the edge" true (registered.is_available ());
    let binding = match B.find_in_declarations declarations "new-alias" with
      | Some binding -> binding | None -> Alcotest.fail "missing credential binding" in
    Alcotest.(check bool) "binding and registry credential observation agree" true binding.available;
    Alcotest.(check bool) "auth requirement remains immutable" true binding.requires_api_key)

let with_publication run =
  let previous = D.current () in
  Fun.protect ~finally:(fun () -> D.publish previous) run

let test_admission_rejects_invalid_combination () = with_publication (fun () ->
  let selected = snapshot () in
  D.publish selected;
  (match D.of_catalogs ~models:(Some seed)
      ~providers:(Some (overlay ~id:"other-provider" ~alias:"old-alias" ())) with
   | Error (D.Conflicting_identity _) -> ()
   | Ok _ ->
     Alcotest.fail "invalid complete pair must fail before publication");
  Alcotest.(check bool) "failed admission retains the exact publication" true
    (D.current () == selected);
  Alcotest.(check bool) "registry retains previous canonical provider" true
    (Option.is_some (Provider_registry.find (Provider_registry.default ()) "snapshot-provider"));
  Alcotest.(check int) "runtime listing retains previous provider" 1 (List.length (B.all ()));
  Alcotest.(check (option string)) "runtime selection retains previous default"
    (Some "seed-model") (Option.bind (B.find "snapshot-provider") (fun entry -> entry.default_model)))

let replacement_policy_selection () =
  let catalog = models {|[[providers]]
id = "snapshot-provider"
aliases = ["old-alias"]
kind = "anthropic"
base_url = "https://seed.invalid"
request_path = "/v1/messages"
auth = "api-key"
capabilities_base = "anthropic"
serves_bare_models = ["bare-policy"]
[[models]]
model_id = "scoped-policy"
provider_name = "snapshot-provider"
base = "anthropic"
supports_tools = false
anthropic_thinking_control = "adaptive_default"
input_per_million = 1.0
output_per_million = 2.0
[[models]]
model_id = "bare-policy"
base = "anthropic"
anthropic_thinking_control = "always_adaptive"
input_per_million = 2.0
output_per_million = 4.0
[[models]]
model_id = "custom-model"
provider_name = "custom-endpoint"
base = "openai_chat"
supports_tools = false
input_per_million = 3.0
output_per_million = 6.0
|} in
  D.of_catalogs ~models:(Some catalog) ~providers:(Some (overlay ())) |> admitted

let test_removed_alias_does_not_recover_policy model_id () =
  let declarations = replacement_policy_selection () in
  Alcotest.(check bool) "old alias is absent from the admitted selection" true
    (D.find declarations "old-alias" = None);
  let policy = Capabilities.resolve_snapshot_request_policy ~snapshot:declarations ~wire:Provider_kind.Anthropic
      ~provider_id:"old-alias" ~model_id in
  Alcotest.(check bool) "old alias cannot recover seed capabilities" true
    (Capabilities.request_policy_capabilities policy = None);
  Alcotest.(check bool) "old alias cannot recover seed thinking controls" true
    (Capabilities.request_policy_anthropic_thinking_control policy = None);
  Alcotest.(check bool) "old alias cannot recover seed pricing" true
    (Pricing.pricing_for_model (Capabilities.request_policy_pricing_source policy) model_id = None)

let test_custom_scoped_policy_survives_absent_provider () =
  let declarations = replacement_policy_selection () in
  Alcotest.(check bool) "custom endpoint has no provider declaration" true
    (D.find declarations "custom-endpoint" = None);
  let policy = Capabilities.resolve_snapshot_request_policy ~snapshot:declarations ~wire:Provider_kind.OpenAI_compat
      ~provider_id:"custom-endpoint" ~model_id:"custom-model" in
  Alcotest.(check (option bool)) "exact custom row remains authoritative"
    (Some false)
    (Option.map (fun (caps : Capabilities.capabilities) -> caps.supports_tools)
       (Capabilities.request_policy_capabilities policy));
  Alcotest.(check (option (float 0.000001))) "exact custom row retains its own price"
    (Some 3.)
    (Option.map (fun (pricing : Pricing.pricing) -> pricing.input_per_million)
       (Pricing.pricing_for_model (Capabilities.request_policy_pricing_source policy) "custom-model"))

type generation = First | Second

let generation_facts = function
  | First -> "first", 2048, 1., true, D.Setup_token_env "SNAPSHOT_FIRST_TOKEN"
  | Second -> "second", 8192, 9., false, D.No_auth

let generation_snapshot generation =
  let label, context, price, tools, authentication = generation_facts generation in
  let model_catalog = models (Printf.sprintf {|[[models]]
model_id = "coherent-model"
provider_name = "snapshot-provider"
max_context_tokens = %d
input_per_million = %.1f
output_per_million = %.1f
|} context price (price *. 2.)) in
  let auth = match authentication with
    | D.Setup_token_env name -> `Assoc ["type", `String "setup_token_env"; "env", `String name]
    | D.No_auth -> `Assoc ["type", `String "none"]
    | D.Caller_api_key | D.Api_key_env _ -> assert false in
  let provider_catalog = Provider_catalog.of_json
    (`Assoc ["schema_version", `Int 1; "providers", `List [`Assoc [
      "id", `String "snapshot-provider";
      "aliases", `List [`String label];
      "kind", `String "openai_compat";
      "base_url", `String ("https://" ^ label ^ ".example.invalid");
      "request_path", `String "/v1/chat/completions";
      "auth", auth;
      "credential_scope", `String label;
      "default_model", `String "coherent-model";
      "max_context", `Int context;
      "capabilities_base", `String "openai_chat";
      "capabilities", `Assoc ["supports_tools", `Bool tools]]]]) |> ok in
  D.of_catalogs ~models:(Some model_catalog) ~providers:(Some provider_catalog) |> admitted

let check_generation generation selected =
  let label, context, price, tools, authentication = generation_facts generation in
  let declared = entry selected label in
  Alcotest.(check bool) "provider auth belongs to this selection" true
    (declared.authentication = authentication);
  Alcotest.(check (option string)) "provider scope belongs to this selection"
    (Some label) declared.credential_scope;
  let binding = match B.find_in_declarations selected label with
    | Some binding -> binding | None -> Alcotest.fail "generation alias disappeared" in
  let config = B.to_provider_config binding
    |> Result.map_error Agent_core.Error.to_string |> ok in
  Alcotest.(check string) "endpoint belongs to this selection"
    ("https://" ^ label ^ ".example.invalid") config.base_url;
  let caps = match Provider_config.capabilities_for_config_model config with
    | Some caps -> caps | None -> Alcotest.fail "selected model policy disappeared" in
  Alcotest.(check (option int)) "model context belongs to this selection"
    (Some context) caps.max_context_tokens;
  Alcotest.(check bool) "provider policy belongs to this selection" tools caps.supports_tools;
  Alcotest.(check (option (float 0.000001))) "model price belongs to this selection"
    (Some price)
    (Option.map (fun (price : Pricing.pricing) -> price.input_per_million)
       (Pricing.pricing_for_model (Provider_config.pricing_source config) "coherent-model"));
  let identity = match Provider_config.selected_provider_identity config with
    | Some identity -> identity | None -> Alcotest.fail "selected auth scope disappeared" in
  Alcotest.(check (option string)) "config freezes selected credential scope"
    (Some label) identity.credential_scope;
  Alcotest.(check bool) "config freezes selected authentication" true
    (identity.authentication = match authentication with
     | D.No_auth -> Provider_config.No_auth
     | D.Setup_token_env _ -> Provider_config.Setup_token
     | D.Caller_api_key | D.Api_key_env _ -> Provider_config.Api_key)

let test_complete_replacement () = with_publication (fun () ->
  let first = generation_snapshot First in
  let second = generation_snapshot Second in
  D.publish first;
  let captured = D.current () in
  D.publish second;
  check_generation First captured;
  check_generation Second (D.current ());
  Alcotest.(check bool) "replaced alias loses current authority" true
    (D.find (D.current ()) "first" = None);
  let source_models, source_providers = D.sources captured in
  Alcotest.(check bool) "complete source pair is retained" true
    (Option.is_some source_models && Option.is_some source_providers))

type handoff = Await_capture | Captured | Replacement_published

let test_domain_handoff () = with_publication (fun () ->
  let first = generation_snapshot First in
  let second = generation_snapshot Second in
  D.publish first;
  let mutex = Mutex.create () in
  let changed = Condition.create () in
  let state = ref Await_capture in
  let reader = Domain.spawn (fun () ->
    let captured = D.current () in
    Mutex.lock mutex;
    state := Captured;
    Condition.broadcast changed;
    while !state <> Replacement_published do Condition.wait changed mutex done;
    Mutex.unlock mutex;
    captured, D.current ()) in
  Mutex.lock mutex;
  while !state = Await_capture do Condition.wait changed mutex done;
  D.publish second;
  state := Replacement_published;
  Condition.broadcast changed;
  Mutex.unlock mutex;
  let captured, fresh = Domain.join reader in
  check_generation First captured;
  check_generation Second fresh)

let test_explicit_absence () = with_publication (fun () ->
  let first = generation_snapshot First in
  D.publish first;
  let absent = D.of_catalogs ~models:None ~providers:None |> admitted in
  D.publish absent;
  Alcotest.(check bool) "explicit absence does not select embedded model facts" true
    (D.models (D.current ()) = None);
  Alcotest.(check int) "explicit absence has no providers" 0 (List.length (B.all ()));
  let policy = Capabilities.resolve_snapshot_request_policy ~snapshot:absent
      ~wire:Provider_kind.OpenAI_compat ~provider_id:"snapshot-provider"
      ~model_id:"coherent-model" in
  Alcotest.(check bool) "absent model policy remains absent" true
    (Capabilities.request_policy_capabilities policy = None);
  Alcotest.(check bool) "absent price remains absent" true
    (Pricing.pricing_for_model (Capabilities.request_policy_pricing_source policy)
       "coherent-model" = None);
  check_generation First first)

let test_reset_embedded () = with_publication (fun () ->
  let selected = generation_snapshot First in
  D.publish selected;
  D.reset ();
  let current = D.current () in
  Alcotest.(check bool) "reset selects embedded model facts" true
    (Option.is_some (D.models current));
  Alcotest.(check bool) "reset selects no JSON overlay" true
    (snd (D.sources current) = None);
  Alcotest.(check bool) "reset does not preserve the explicit provider" true
    (D.find current "snapshot-provider" = None);
  check_generation First selected)

let test_pure_admission () = with_publication (fun () ->
  let first = generation_snapshot First in
  D.publish first;
  let second = generation_snapshot Second in
  check_generation Second second;
  Alcotest.(check bool) "successful construction does not publish" true
    (D.current () == first))

let test_raw_removed_alias model_id () = with_publication (fun () ->
  D.publish (replacement_policy_selection ());
  let provider = Model_catalog.Declared_provider "old-alias" in
  let config = Provider_config.make ~kind:Anthropic ~provider_id:"old-alias"
      ~model_id ~base_url:"https://raw.example.invalid" ()
    |> Provider_config.freeze_for_request in
  Alcotest.(check bool) "raw config cannot recover removed seed policy" true
    (Provider_config.capabilities_for_config_model config = None);
  Alcotest.(check bool) "raw config cannot recover removed seed thinking" true
    (Provider_config.anthropic_thinking_control config = None);
  Alcotest.(check bool) "raw config cannot recover removed seed price" true
    (Pricing.pricing_for_model (Provider_config.pricing_source config) model_id = None);
  Alcotest.(check bool) "raw capability observation respects admission" true
    (Capabilities.for_provider_model_id ~wire:None ~provider ~model_id = None);
  Alcotest.(check bool) "raw thinking observation respects admission" true
    (Capabilities.anthropic_thinking_control_for_provider_model_id ~provider ~model_id = None);
  Alcotest.(check bool) "raw pricing observation respects admission" true
    (Pricing.pricing_for_model_opt ~provider model_id = None))

let test_raw_overlay_revokes_seed_bare_permission () = with_publication (fun () ->
  D.publish (replacement_policy_selection ());
  let config = Provider_config.make ~kind:Anthropic ~provider_id:"snapshot-provider"
      ~model_id:"bare-policy" ~base_url:"https://raw.example.invalid" ()
    |> Provider_config.freeze_for_request in
  Alcotest.(check bool) "raw canonical id cannot retain revoked bare model policy" true
    (Provider_config.capabilities_for_config_model config = None);
  Alcotest.(check bool) "raw canonical id cannot retain revoked bare price" true
    (Pricing.pricing_for_model (Provider_config.pricing_source config) "bare-policy" = None);
  Alcotest.(check bool) "raw id does not acquire selected attribution" true
    (Provider_config.selected_provider_identity config = None))

let test_raw_alias_scoped_precedence () = with_publication (fun () ->
  let model_catalog = models {|[[providers]]
id = "canonical-provider"
aliases = ["requested-alias"]
kind = "openai_compat"
base_url = "https://precedence.example.invalid"
request_path = "/v1/chat/completions"
auth = "none"
capabilities_base = "openai_chat"
[[models]]
model_id = "same-model"
provider_name = "requested-alias"
max_context_tokens = 2048
input_per_million = 7.0
output_per_million = 14.0
[[models]]
model_id = "same-model"
provider_name = "canonical-provider"
max_context_tokens = 8192
input_per_million = 9.0
output_per_million = 18.0
|} in
  D.publish (D.of_catalogs ~models:(Some model_catalog) ~providers:None |> admitted);
  let config = Provider_config.make ~kind:OpenAI_compat ~provider_id:"requested-alias"
      ~model_id:"same-model" ~base_url:"https://raw.example.invalid" ()
    |> Provider_config.freeze_for_request in
  Alcotest.(check (option int)) "verbatim scoped row precedes canonical row"
    (Some 2048)
    (Option.bind (Provider_config.capabilities_for_config_model config)
       (fun caps -> caps.Capabilities.max_context_tokens));
  let input = Option.map (fun (price : Pricing.pricing) -> price.input_per_million) in
  Alcotest.(check (option (float 0.000001))) "captured request preserves requested alias price"
    (Some 7.) (input (Pricing.pricing_for_model (Provider_config.pricing_source config) "same-model"));
  Alcotest.(check (option (float 0.000001))) "price observation preserves requested alias price"
    (Some 7.) (input (Pricing.pricing_for_model_opt
      ~provider:(Model_catalog.Declared_provider "requested-alias") "same-model")))

let test_token_does_not_use_bare_row () = with_publication (fun () ->
  let model_catalog = models {|[[providers]]
id = "token-provider"
kind = "ollama"
base_url = "https://token.example.invalid"
request_path = "/api/chat"
auth = "none"
capabilities_base = "ollama"
serves_bare_models = ["bare-token"]
[[models]]
model_id = "bare-token"
base = "ollama"
thinking_control_format = "chat_template_token"
thinking_control_token = "<|bare|>"
|} in
  D.publish (D.of_catalogs ~models:(Some model_catalog) ~providers:None |> admitted);
  List.iter (fun (label, provider) ->
    Alcotest.(check bool) "generic capability lookup permits this exact bare row" true
      (Option.is_some (Capabilities.for_provider_model_id ~wire:None ~provider ~model_id:"bare-token"));
    Alcotest.(check (option string)) "token getter still requires an exact scoped row" None
      (Capabilities.thinking_control_token_for_provider_model_id
        ~provider_label:label ~model_id:"bare-token"))
    ["token-provider", Model_catalog.Declared_provider "token-provider";
     "ollama", Model_catalog.Anonymous_wire Provider_kind.Ollama])

let test_provider_required_fields () =
  let fields = [
    "id", "\"openai\"";
    "kind", "\"openai_compat\"";
    "base_url", "\"https://required.example.invalid\"";
    "request_path", "\"/v1/chat/completions\"";
    "auth", "\"none\"";
    "capabilities_base", "\"models_only\"" ] in
  let decode fields =
    "[[providers]]\n" ^ String.concat "\n"
      (List.map (fun (key, value) -> key ^ " = " ^ value) fields)
    |> Model_catalog.of_toml_string ~source:"required provider declarations" in
  (match decode fields with Ok _ -> ()
    | Error detail -> Alcotest.fail detail);
  List.iter (fun (omitted, _) ->
    match decode (List.filter (fun (key, _) -> not (String.equal key omitted)) fields) with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "provider admitted without required %s" omitted) fields;
  List.iter (fun value ->
    match decode (List.map (fun (key, prior) -> key,
      if String.equal key "capabilities_base" then value else prior) fields) with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "invalid capability declaration admitted: %s" value)
    ["true"; "12"; "\"\""; "\"unknown-preset\""; "\" models_only \"";
      "\"openai_compat_typo\""];
  (match Model_catalog.of_toml_string ~source:"model row cannot name provider policy"
    {|[[models]]
model_id = "invalid-model-base"
base = "models_only"
|} with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "provider-only models_only choice accepted as a model preset")

let test_models_only_selected_and_raw_policy () = with_publication (fun () ->
  let catalog = models {|[[providers]]
id = "openai"
aliases = ["fixture-alias"]
kind = "openai_compat"
base_url = "https://models-only.example.invalid"
request_path = "/v1/chat/completions"
auth = "none"
capabilities_base = "models_only"
[[models]]
model_id = "declared-model"
provider_name = "openai"
base = "openai_chat"
supports_structured_output = true
input_per_million = 2.0
output_per_million = 3.0
|} in
  let snapshot = D.of_catalogs ~models:(Some catalog) ~providers:None |> admitted in
  D.publish snapshot;
  Alcotest.(check bool) "provider identity supplies no capability profile" true
    ((entry snapshot "openai").capabilities = None);
  let registry = Provider_registry.of_declarations snapshot in
  Alcotest.(check int) "model-only provider remains discoverable" 1
    (List.length (Provider_registry.all registry));
  Alcotest.(check int) "no invented provider capability satisfies a predicate" 0
    (List.length (Provider_registry.find_capable registry (fun _ -> true)));
  let binding = match B.find_in_declarations snapshot "fixture-alias" with
    | Some binding -> binding | None -> Alcotest.fail "missing model-only binding" in
  List.iter (fun id ->
    let policy = Capabilities.resolve_snapshot_request_policy ~snapshot
      ~wire:Provider_kind.OpenAI_compat ~provider_id:id ~model_id:"unknown-model" in
    Alcotest.(check bool) "selected unknown model retains absent policy" true
      (Capabilities.request_policy_capabilities policy = None);
    Alcotest.(check bool) "raw unknown model retains absent policy" true
      (Capabilities.for_provider_model_id ~wire:(Some Provider_kind.OpenAI_compat)
        ~provider:(Model_catalog.Declared_provider id) ~model_id:"unknown-model" = None))
    ["openai"; "fixture-alias"];
  let config model = match B.to_provider_config ~model binding with
    | Ok config -> config | Error error -> Alcotest.fail (Agent_core.Error.to_string error) in
  Alcotest.(check bool) "captured unknown-model config gains no preset" true
    (Provider_config.capabilities_for_config_model (config "unknown-model") = None);
  let known = config "declared-model" in
  Alcotest.(check bool) "exact declared model retains its own structured policy" true
    (Option.fold ~none:false ~some:(fun capabilities -> capabilities.Capabilities.supports_structured_output)
      (Provider_config.capabilities_for_config_model known));
  Alcotest.(check (option (float 0.000001))) "exact model retains selected pricing"
    (Some 2.)
    (Option.map (fun (pricing : Pricing.pricing) -> pricing.input_per_million)
      (Pricing.pricing_for_model (Provider_config.pricing_source known) "declared-model")))

let test_packaged_openai_is_models_only () =
  let catalog = Model_catalog.load_default () |> ok in
  let snapshot = D.of_catalogs ~models:(Some catalog) ~providers:None |> admitted in
  Alcotest.(check bool) "packaged OpenAI has no provider-wide policy" true
    ((entry snapshot "openai").capabilities = None);
  let policy model_id = Capabilities.resolve_snapshot_request_policy ~snapshot
      ~wire:Provider_kind.OpenAI_compat ~provider_id:"openai" ~model_id
    |> Capabilities.request_policy_capabilities in
  Alcotest.(check bool) "packaged exact GPT-4o policy remains available" true
    (Option.fold ~none:false ~some:(fun capabilities -> capabilities.Capabilities.supports_structured_output)
      (policy "gpt-4o"));
  Alcotest.(check bool) "undeclared GPT-4o variant inherits no provider policy" true
    (policy "gpt-4o-unlisted-fixture" = None)

let test_models_only_refuses_provider_wide_wire_override () =
  match Model_catalog.of_toml_string ~source:"contradictory models-only provider"
    {|[[providers]]
id = "contradictory"
kind = "openai_compat"
identity_kinds = ["openai_compat", "ollama"]
base_url = "https://models-only.example.invalid"
request_path = "/v1/chat/completions"
auth = "none"
capabilities_base = "models_only"
capabilities_base_by_identity_kind = { ollama = "ollama" }
|} with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "models-only provider admitted a provider-wide wire preset"

let test_typed_view_cannot_retain_wire_policy_after_models_only () =
  let catalog = models {|[[providers]]
id = "typed-view"
kind = "anthropic"
identity_kinds = ["anthropic", "openai_compat"]
base_url = "https://typed-view.example.invalid"
request_path = "/v1/messages"
auth = "none"
capabilities_base = "anthropic"
capabilities_base_by_identity_kind = { openai_compat = "openai_chat_extended" }
|} in
  let admit catalog = D.of_catalogs ~models:(Some catalog) ~providers:None |> admitted in
  let policy snapshot wire = Capabilities.resolve_snapshot_request_policy
    ~snapshot ~wire ~provider_id:"typed-view" ~model_id:"unknown-model"
    |> Capabilities.request_policy_capabilities in
  Alcotest.(check bool) "explicit wire default is a real positive control" true
    (Option.is_some (policy (admit catalog) Provider_kind.OpenAI_compat));
  let provider = match Model_catalog.provider_entries catalog with
    | [provider] -> provider | _ -> Alcotest.fail "expected one typed provider" in
  let models_only = {provider with
    capability_policy=Model_provider_catalog.Models_only} in
  let view = Model_catalog.with_provider_entry catalog models_only in
  let snapshot = admit view in
  Alcotest.(check bool) "typed view exposes no provider-wide record" true
    ((entry snapshot "typed-view").capabilities = None);
  List.iter (fun wire ->
    Alcotest.(check bool) "typed models-only state retains no hidden wire preset" true
      (policy snapshot wire = None)) [Provider_kind.Anthropic;OpenAI_compat]

let () = Alcotest.run "catalog snapshot"
  ["admission",[
    "exact overlay replacement",`Quick,test_exact_replacement;
    "declared spelling and lookup identity",`Quick,test_declared_spelling_and_lookup_identity;
    "alias versus canonical id",`Quick,(fun () -> test_cross_source_collision "snapshot-provider");
    "alias versus alias",`Quick,(fun () -> test_cross_source_collision "old-alias");
    "missing capability base",`Quick,test_missing_preset_fails_closed;
    "provider fields require explicit declarations",`Quick,test_provider_required_fields;
    "models-only forbids provider-wide wire policy",`Quick,test_models_only_refuses_provider_wide_wire_override;
    "typed view cannot retain wire policy in models-only state",`Quick,test_typed_view_cannot_retain_wire_policy_after_models_only;
    "invalid complete pair retains prior publication",`Quick,test_admission_rejects_invalid_combination];
   "consumers",[
    "immutable captured selection",`Quick,test_snapshot_survives_source_replacement;
    "credential observation",`Quick,test_credential_observation_edge;
    "models-only selected and raw request policy",`Quick,test_models_only_selected_and_raw_policy;
    "packaged OpenAI retains only exact model policy",`Quick,test_packaged_openai_is_models_only;
    "independent declared provider requests",`Quick,test_distinct_providers_keep_independent_policy];
   "publication",[
    "complete provider model auth price replacement",`Quick,test_complete_replacement;
    "domain handoff retains coherent old and new selections",`Quick,test_domain_handoff;
    "explicit absence is not an embedded fallback",`Quick,test_explicit_absence;
    "reset selects embedded default and retains captures",`Quick,test_reset_embedded;
    "pure successful admission does not publish",`Quick,test_pure_admission];
   "replacement policy",[
    "raw removed alias cannot recover scoped policy",`Quick,test_raw_removed_alias "scoped-policy";
    "raw removed alias cannot recover bare policy",`Quick,test_raw_removed_alias "bare-policy";
    "raw removed alias cannot recover defaults",`Quick,test_raw_removed_alias "missing-model";
    "raw canonical overlay revokes seed bare permission",`Quick,test_raw_overlay_revokes_seed_bare_permission;
    "raw requested alias retains exact scoped precedence",`Quick,test_raw_alias_scoped_precedence;
    "token lookup does not gain bare fallback",`Quick,test_token_does_not_use_bare_row;
    "removed alias cannot recover scoped policy",`Quick,test_removed_alias_does_not_recover_policy "scoped-policy";
    "removed alias cannot recover bare policy",`Quick,test_removed_alias_does_not_recover_policy "bare-policy";
    "removed alias cannot recover provider defaults",`Quick,test_removed_alias_does_not_recover_policy "missing-model";
    "unknown custom endpoint retains its scoped row",`Quick,test_custom_scoped_policy_survives_absent_provider]]
