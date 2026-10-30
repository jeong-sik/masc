open Llm_provider
module D = Provider_declarations
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
  Alcotest.(check bool) "overlay capability" true selected.capabilities.supports_reasoning;
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
  | Ok _ | Error (D.Unknown_capability_base _) -> Alcotest.fail "collision must fail typed admission"

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
  let invalid = models {|[[providers]]
id = "unmapped-fixture"
kind = "openai_compat"
base_url = "https://example.invalid"
request_path = "/v1/chat/completions"
auth = "none"
|} in
  match D.of_catalogs ~models:(Some invalid) ~providers:None with
  | Error (D.Unknown_capability_base {provider_id;label}) ->
    Alcotest.(check string) "provider error identity" "unmapped-fixture" provider_id;
    Alcotest.(check string) "missing base is not a generic fallback" "unmapped-fixture" label
  | Ok _ | Error (D.Conflicting_identity _) -> Alcotest.fail "missing preset must fail closed"

let test_snapshot_survives_source_replacement () =
  let declarations = snapshot ~providers:(overlay ()) () in
  let replacement = overlay ~model:"later-model" () in
  Provider_catalog.set_global replacement;
  Fun.protect ~finally:Provider_catalog.clear_global (fun () ->
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

let test_current_rejects_invalid_combination () =
  Model_catalog.set_global seed;
  Provider_catalog.set_global (overlay ~id:"other-provider" ~alias:"old-alias" ());
  Fun.protect ~finally:(fun () -> Model_catalog.clear_global ();Provider_catalog.clear_global ())
    (fun () ->
      let check reject = match reject () with
        | () -> Alcotest.fail "invalid declarations cannot load fallback"
        | exception D.Invalid_declarations (D.Conflicting_identity _) -> () in
      check (fun () -> ignore (Provider_registry.default ()));
      check (fun () -> ignore (B.all ()));
      check (fun () -> ignore (B.find "snapshot-provider")))

let () = Alcotest.run "provider declarations"
  ["admission",[
    "exact overlay replacement",`Quick,test_exact_replacement;
    "declared spelling and lookup identity",`Quick,test_declared_spelling_and_lookup_identity;
    "alias versus canonical id",`Quick,(fun () -> test_cross_source_collision "snapshot-provider");
    "alias versus alias",`Quick,(fun () -> test_cross_source_collision "old-alias");
    "missing capability base",`Quick,test_missing_preset_fails_closed;
    "invalid current declaration has no fallback",`Quick,test_current_rejects_invalid_combination];
   "consumers",[
    "immutable captured selection",`Quick,test_snapshot_survives_source_replacement;
    "credential observation",`Quick,test_credential_observation_edge;
    "independent declared provider requests",`Quick,test_distinct_providers_keep_independent_policy]]
