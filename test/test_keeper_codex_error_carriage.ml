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
  | Agent_core.Error.Provider (Llm_provider.Error.AuthError _) -> "provider:auth"
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
  (* A MASC error rides the carrier, so the class is the constructor it
     carries, not the sentence the carrier's message renders (RFC-0454). *)
  | Agent_core.Error.Internal_carried _ as carried ->
    (match Keeper_internal_error.classify_masc_internal_error carried with
     | Some internal ->
       "masc:" ^ Keeper_internal_error.kind_of_masc_internal_error internal
     | None -> "internal")
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
    "provider:auth";
  check "context overflow pre-tool"
    (Codex.Context_window_exceeded
       { message = "full"; tool_effect_attempted = false })
    "api:context_overflow";
  check "context overflow post-tool"
    (Codex.Context_window_exceeded
       { message = "full"; tool_effect_attempted = true })
    "provider:reported:context_window_exceeded_after_tool_effect";
  check "spawn_failed" (Codex.Spawn_failed "no exe") "provider:unavailable";
  (* Split from [Spawn_failed] by RFC-0454 P2: a client that died after it
     started is a closed connection, and the pane needs to say so without
     reading the rendered sentence. Rotation is unchanged —
     [Keeper_runtime_attempt] rebuilds the same [ProviderUnavailable]. *)
  check "process_exited"
    (Codex.Process_exited { detail = "killed"; turn_accepted = false })
    "masc:runtime_connection_closed";
  check "protocol_error"
    (Codex.Protocol_error { stage = "turn"; detail = "bad frame" })
    "provider:parse_error";
  check "rpc_error"
    (Codex.Rpc_error { method_ = "thread/start"; code = Some 3; message = "no"; data = None })
    "provider:reported:rpc_error";
  check "unsupported_server_request"
    (Codex.Unsupported_server_request "applyPatch")
    "provider:unknown_variant";
  (* Effectful failed turns are fenced out of same-turn retry by
     [Keeper_provider_attempt_effect] at the driver level; the mapping itself
     stays descriptive. *)
  check "turn input write failure"
    (Codex.Turn_input_write_failed "pipe closed") "provider:unavailable";
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
  (* Both are the host stopping a running turn. They stay off the rotation
     chain (the carrier is still an agent-core internal error) and carry the
     reason as a value instead of a sentence. *)
  check "turn_interrupted is a typed host stop"
    Codex.Turn_interrupted
    "masc:host_stopped_turn";
  check "runtime shutdown is a typed host stop"
    Codex.Runtime_shutting_down
    "masc:host_stopped_turn"
;;

(* The class above says which constructor; this says the fields survive, which
   is what the chat pane and the operator read. *)
let test_host_stop_and_closed_connection_carry_their_fields () =
  let classify error =
    Keeper_internal_error.classify_masc_internal_error
      (Map.codex_error_to_core_error error)
  in
  (match classify Codex.Runtime_shutting_down with
   | Some (Keeper_internal_error.Host_stopped_turn { runtime_id; stop }) ->
     Alcotest.(check string) "runtime" "codex_app_server" runtime_id;
     Alcotest.(check bool)
       "graceful shutdown"
       true
       (stop = Keeper_internal_error.Host_graceful_shutdown)
   | Some _ | None -> Alcotest.fail "host shutdown did not decode");
  (match classify Codex.Turn_interrupted with
   | Some (Keeper_internal_error.Host_stopped_turn { stop; _ }) ->
     Alcotest.(check bool)
       "runtime-reported interrupt"
       true
       (stop = Keeper_internal_error.Runtime_reported_interrupt)
   | Some _ | None -> Alcotest.fail "turn interrupt did not decode");
  match
    classify (Codex.Process_exited { detail = "stdout closed"; turn_accepted = true })
  with
  | Some
      (Keeper_internal_error.Runtime_connection_closed
         { runtime_id; detail; turn_accepted }) ->
    Alcotest.(check string) "runtime" "codex_app_server" runtime_id;
    Alcotest.(check string) "detail" "stdout closed" detail;
    Alcotest.(check bool) "turn was submitted" true turn_accepted
  | Some _ | None -> Alcotest.fail "closed connection did not decode"

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

(* A Gate continuation's thread that overflowed after a tool effect cannot
   take the continuation again, so the Gate ends; an observation-free overflow
   keeps the same-thread shrink retry. *)
let test_gate_resume_overflow_after_effect_is_session_full () =
  let recovery = Map.recovery_failure_of_attempt in
  let overflow tool_effect_attempted =
    Codex.Context_window_exceeded { message = "full"; tool_effect_attempted } in
  let resume = Codex.Resume { thread_id = "thread-1" } in
  Alcotest.(check bool)
    "Gate resume after a tool effect is session-full"
    (recovery ~thread_mode:resume ~gate_continuation:true (overflow true)
     = Masc.Keeper_official_client_session_store.(Vendor_session_full Activity_observed))
    true;
  Alcotest.(check bool)
    "Gate resume without activity keeps the shrink retry"
    (recovery ~thread_mode:resume ~gate_continuation:true (overflow false)
     = Masc.Keeper_official_client_session_store.(Input_rejected Bootstrap_floor_exceeded))
    true;
  Alcotest.(check bool)
    "an ordinary resume after a tool effect stays effect-fenced"
    (recovery ~thread_mode:resume ~gate_continuation:false (overflow true)
     = Masc.Keeper_official_client_session_store.(Input_rejected Effect_fenced))
    true
;;

let test_transport_uncertainty_preserves_stronger_evidence () =
  let module Effect = Masc.Keeper_provider_attempt_effect in
  List.iter (fun (before, expected) ->
    let observation = Atomic.make before in
    Map.note_transport_uncertainty observation;
    Map.note_transport_uncertainty observation;
    Alcotest.(check string) "uncertainty joins without losing effect evidence"
      (Effect.to_string expected) (Effect.to_string (Atomic.get observation));
    Alcotest.(check bool) "uncertainty cannot reopen same-run retry" false
      (Effect.allows_same_turn_retry (Atomic.get observation)))
    Effect.[ No_effect_observed, Observation_unavailable;
             Observation_unavailable, Observation_unavailable;
             Effect_attempted, Effect_attempted ]
;;

let () =
  Alcotest.run
    "keeper_codex_error_carriage"
    [ ( "carriage"
      , [ Alcotest.test_case "transport uncertainty preserves prior effects" `Quick
            test_transport_uncertainty_preserves_stronger_evidence
        ; Alcotest.test_case
            "every variant lands in its class"
            `Quick
            test_every_variant_lands_in_its_class
        ; Alcotest.test_case
            "a host stop and a closed connection carry their fields"
            `Quick
            test_host_stop_and_closed_connection_carry_their_fields
        ; Alcotest.test_case
            "context overflow maps to input-rejected recovery"
            `Quick
            test_context_overflow_maps_to_input_rejected_recovery
        ; Alcotest.test_case
            "Gate resume overflow after a tool effect is session-full"
            `Quick
            test_gate_resume_overflow_after_effect_is_session_full
        ] )
    ]
