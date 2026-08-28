(* Pins the typed carriage of every Codex app-server client error variant
   (RFC-0370 §3.1). The census (test_keeper_rotation_eligibility_census)
   pins what each agent-core class does in the rotation loop; this test pins
   which class each client error lands in, so the boundary cannot silently
   fall back to [Internal] for a provider-side failure. *)

module Codex = Runtime_codex_app_server
module Map = Masc.Keeper_codex_runtime.For_testing

let class_of (err : Agent_core.Error.t) =
  match err with
  | Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; _ }) ->
    "config:" ^ field
  | Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _) ->
    "api:context_overflow"
  | Agent_core.Error.Api (Agent_core.Retry.Timeout _) -> "api:timeout"
  | Agent_core.Error.Provider (Llm_provider.Error.ProviderUnavailable _) ->
    "provider:unavailable"
  | Agent_core.Error.Provider (Llm_provider.Error.ParseError _) ->
    "provider:parse_error"
  | Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError { error_type; _ }) ->
    "provider:reported:" ^ Option.value error_type ~default:"?"
  | Agent_core.Error.Provider (Llm_provider.Error.UnknownVariant _) ->
    "provider:unknown_variant"
  | Agent_core.Error.Internal _ -> "internal"
  | other -> "unexpected:" ^ Agent_core.Error.to_string other

let check label error expected =
  Alcotest.(check string) label expected (class_of (Map.codex_error_to_core_error error))

(* Every constructor appears exactly once; a new variant fails to compile in
   [codex_error_to_core_error] (no catch-all) before it can be missed here. *)
let test_every_variant_lands_in_its_class () =
  check "invalid_config"
    (Codex.Invalid_config "bad path")
    "config:codex_app_server";
  check "subscription_required"
    (Codex.Subscription_required "login")
    "config:codex_subscription";
  check "context overflow pre-tool"
    (Codex.Context_window_exceeded
       { message = "full"; tool_effect_attempted = false })
    "api:context_overflow";
  check "context overflow post-tool"
    (Codex.Context_window_exceeded
       { message = "full"; tool_effect_attempted = true })
    "provider:reported:context_window_exceeded_after_tool_effect";
  check "spawn_failed" (Codex.Spawn_failed "no exe") "provider:unavailable";
  check "process_exited" (Codex.Process_exited "killed") "provider:unavailable";
  check "protocol_error"
    (Codex.Protocol_error { stage = "turn"; detail = "bad frame" })
    "provider:parse_error";
  check "rpc_error"
    (Codex.Rpc_error { method_ = "thread/start"; code = Some 3; message = "no" })
    "provider:reported:rpc_error";
  check "unsupported_server_request"
    (Codex.Unsupported_server_request "applyPatch")
    "provider:unknown_variant";
  (* Effectful failed turns are fenced out of same-turn retry by
     [Keeper_provider_attempt_effect] at the driver level; the mapping itself
     stays descriptive. *)
  check "turn_failed"
    (Codex.Turn_failed "stream disconnected before completion")
    "provider:reported:turn_failed";
  check "idle timeout before turn/start rotates"
    (Codex.Timeout { seconds = 300.0; turn_accepted = false })
    "api:timeout";
  (* Idle after turn/start acceptance is ambiguous: the upstream turn may
     still commit (PR #28192 review P1). *)
  check "idle timeout after turn/start stays internal"
    (Codex.Timeout { seconds = 300.0; turn_accepted = true })
    "internal";
  check "turn_interrupted (deliberate stop stays internal)"
    Codex.Turn_interrupted
    "internal";
  check "runtime shutdown stays internal"
    Codex.Runtime_shutting_down
    "internal"

(* The durable recovery failure follows the same activity axis as the
   agent-core carriage above: an overflow the provider proved over capacity
   becomes [Input_rejected] so the session admission fence holds, everything
   else keeps its previous class. *)
let test_context_overflow_maps_to_input_rejected_recovery () =
  let recovery = Map.recovery_failure_of_client_error in
  Alcotest.(check bool)
    "pre-tool overflow is floor-exceeded"
    (recovery
       (Codex.Context_window_exceeded
          { message = "full"; tool_effect_attempted = false })
     = Masc.Keeper_official_client_session_store.(
         Input_rejected Bootstrap_floor_exceeded))
    true;
  Alcotest.(check bool)
    "post-tool overflow is effect-fenced"
    (recovery
       (Codex.Context_window_exceeded
          { message = "full"; tool_effect_attempted = true })
     = Masc.Keeper_official_client_session_store.(Input_rejected Effect_fenced))
    true;
  Alcotest.(check bool)
    "turn failures stay generic provider rejections"
    (recovery (Codex.Turn_failed "stream disconnected")
     = Masc.Keeper_official_client_session_store.Provider_rejected)
    true
  ; Alcotest.(check bool)
      "runtime shutdown records transport interruption"
      (recovery Codex.Runtime_shutting_down
       = Masc.Keeper_official_client_session_store.Transport_interrupted)
      true
;;

let () =
  Alcotest.run
    "keeper_codex_error_carriage"
    [ ( "carriage"
      , [ Alcotest.test_case
            "every variant lands in its class"
            `Quick
            test_every_variant_lands_in_its_class
        ; Alcotest.test_case
            "context overflow maps to input-rejected recovery"
            `Quick
            test_context_overflow_maps_to_input_rejected_recovery
        ] )
    ]
