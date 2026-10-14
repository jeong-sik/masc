(** Auto-detection must gate on usability, not on the auth requirement fact.

    A catalog row that says "this endpoint takes a key" must still join the
    auto-detected model labels when its credential is actually present;
    gating on the requirement alone silently drops every keyed provider and
    collapses deployments without an explicit default model onto the local
    fallback label. *)

open Alcotest

module Binding = Agent_core.Provider_runtime_binding

let make_binding ~auth ~available () : Binding.t =
  { id = "keyed-provider"
  ; aliases = []
  ; kind = Llm_provider.Provider_config.Anthropic
  ; base_url = "https://api.example.com"
  ; request_path = "/v1/messages"
  ; requires_api_key = true
  ; auth
  ; default_model = Some "model-a"
  ; max_context = None
  ; capabilities = Llm_provider.Capabilities.default_capabilities
  ; available
  ; credential_scope = None
  }

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
