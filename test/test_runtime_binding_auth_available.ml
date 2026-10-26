(** Auto-detection must gate on usability, not on the auth requirement fact.

    A catalog row that says "this endpoint takes a key" must still join the
    auto-detected model labels when its credential is actually present;
    gating on the requirement alone silently drops every keyed provider and
    collapses deployments without an explicit default model onto the local
    fallback label. *)

open Alcotest

module Binding = Agent_core.Provider_runtime_binding

let make_binding ~auth ~available () : Binding.t =
  let env = "MASC_TEST_BINDING_AUTH_CAPTURE" in
  let saved = Sys.getenv_opt env in
  Fun.protect ~finally:(fun () -> match saved with
    | Some value -> Unix.putenv env value | None -> Unix.unsetenv env) (fun () ->
    Unix.putenv env (if available then "fixture-key" else "");
    let auth = match auth with
      | Binding.No_auth -> `Assoc ["type",`String "none"]
      | Api_key -> `Assoc ["type",`String "api_key_env";"env",`String env]
      | Setup_token -> `Assoc ["type",`String "setup_token_env";"env",`String env] in
    let json = `Assoc ["schema_version",`Int 1;"providers",`List [`Assoc
      ["id",`String "keyed-provider";"kind",`String "anthropic";
       "base_url",`String "https://api.example.com";"request_path",`String "/v1/messages";
       "auth",auth;"default_model",`String "model-a";
       "capabilities_base",`String "anthropic"]]] in
    let providers = match Llm_provider.Provider_catalog.of_json json with
      | Ok catalog -> catalog | Error error -> fail error in
    let declarations = match Llm_provider.Provider_declarations.of_catalogs
        ~models:None ~providers:(Some providers) with
      | Ok declarations -> declarations
      | Error error -> fail (Llm_provider.Provider_declarations.error_to_string error) in
    match Binding.find_in_declarations declarations "keyed-provider" with
    | Some binding -> binding | None -> fail "missing admitted auth binding")


let test_keyed_available_participates () =
  let binding = make_binding ~auth:Binding.Api_key ~available:true () in
  check bool "available keyed binding qualifies" true
    (Provider_runtime_projection.binding_auth_available binding)

let test_keyed_unavailable_does_not () =
  let binding = make_binding ~auth:Binding.Api_key ~available:false () in
  check bool "unavailable keyed binding does not qualify" false
    (Provider_runtime_projection.binding_auth_available binding)

let test_setup_token_follows_availability () =
  let present = make_binding ~auth:Binding.Setup_token ~available:true () in
  let absent = make_binding ~auth:Binding.Setup_token ~available:false () in
  check bool "available setup-token binding qualifies" true
    (Provider_runtime_projection.binding_auth_available present);
  check bool "unavailable setup-token binding does not qualify" false
    (Provider_runtime_projection.binding_auth_available absent)

let test_keyless_always_participates () =
  let binding = make_binding ~auth:Binding.No_auth ~available:false () in
  check bool "keyless binding qualifies without availability" true
    (Provider_runtime_projection.binding_auth_available binding)

let () =
  run
    "runtime_binding_auth_available"
    [ ( "gate"
      , [ test_case "keyed available participates" `Quick test_keyed_available_participates
        ; test_case "keyed unavailable does not" `Quick test_keyed_unavailable_does_not
        ; test_case "setup token follows availability" `Quick
            test_setup_token_follows_availability
        ; test_case "keyless always participates" `Quick test_keyless_always_participates
        ] )
    ]
