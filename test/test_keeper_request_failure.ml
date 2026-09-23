(** A failed keeper request is a value (RFC-0454 D2).

    This suite pins three things: which constructor each producer's input maps
    to, that the codec is symmetric and refuses everything it does not write,
    and that a summary is one line whatever the leaf text contains. *)

module Krf = Keeper_request_failure
module Kie = Keeper_internal_error
module Keeper_registry_types = Masc.Keeper_registry_types

let cause_testable =
  Alcotest.testable
    (fun fmt cause ->
       Format.pp_print_string fmt (Yojson.Safe.to_string (Krf.to_yojson { Krf.cause })))
    (fun left right ->
       Yojson.Safe.equal
         (Krf.to_yojson { Krf.cause = left })
         (Krf.to_yojson { Krf.cause = right }))
;;

let summary_of cause = Krf.summary { Krf.cause }

(* ------------------------------------------------------------------ *)
(* Producer -> constructor                                             *)
(* ------------------------------------------------------------------ *)

let network_error kind message =
  Agent_core.Error.Api (Agent_core.Retry.NetworkError { message; kind })
;;

let test_api_network_becomes_provider_network () =
  Alcotest.check
    cause_testable
    "an agent-core transport failure names the transport"
    (Krf.Provider_network
       { provider = None
       ; kind = Llm_provider.Http_client.Connection_refused
       ; detail = "refused"
       })
    (Krf.of_core_error
       (network_error Llm_provider.Http_client.Connection_refused "refused")).Krf.cause
;;

let test_provider_network_keeps_its_provider () =
  Alcotest.check
    cause_testable
    "a provider transport failure keeps the provider that failed"
    (Krf.Provider_network
       { provider = Some "codex_app_server"
       ; kind = Llm_provider.Http_client.End_of_file
       ; detail = "stdout closed"
       })
    (Krf.of_core_error
       (Agent_core.Error.Provider
          (Llm_provider.Error.NetworkError
             { provider = "codex_app_server"
             ; kind = Llm_provider.Http_client.End_of_file
             ; detail = "stdout closed"
             ; timeout_phase = None
             })))
      .Krf.cause
;;

let test_context_overflow_carries_the_window () =
  Alcotest.check
    cause_testable
    "a context overflow carries the window, not the provider diagnostic"
    (Krf.Context_overflow { limit = Some 200_000 })
    (Krf.of_core_error
       (Agent_core.Error.Api
          (Agent_core.Retry.ContextOverflow
             { limit = Some 200_000; message = "empty completion" })))
      .Krf.cause
;;

let test_carried_masc_error_stays_a_masc_value () =
  let masc_error =
    Kie.Host_stopped_turn
      { runtime_id = "claude_code.claude-sonnet-5"; stop = Kie.Host_graceful_shutdown }
  in
  Alcotest.check
    cause_testable
    "a MASC error on the carrier is lifted back, not re-rendered"
    (Krf.Masc masc_error)
    (Krf.of_core_error (Kie.core_error_of_masc_internal_error masc_error)).Krf.cause
;;

let test_unnamed_agent_core_failure_stays_core () =
  match (Krf.of_core_error (Agent_core.Error.Internal "boom")).Krf.cause with
  | Krf.Core core ->
    Alcotest.check
      Alcotest.string
      "the residual arm keeps agent-core's own text"
      "boom"
      core.Keeper_request_failure_core.message
  | _ -> Alcotest.fail "a plain agent-core internal failure must project to Core"
;;

let test_operator_interrupt_detail_is_the_typed_summary () =
  (* One sentence for the interrupt: the registry's detail and the chat row
     read the same value. *)
  Alcotest.check
    Alcotest.string
    "the registry detail is the typed summary"
    (summary_of Krf.Operator_cancelled)
    Keeper_registry_types.operator_interrupt_detail
;;

(* ------------------------------------------------------------------ *)
(* Summary                                                             *)
(* ------------------------------------------------------------------ *)

let test_a_summary_is_one_line () =
  let cause = Krf.Runtime_selection_failed { detail = "first\nsecond\rthird" } in
  Alcotest.check
    Alcotest.string
    "line breaks inside leaf text become spaces"
    "first second third"
    (summary_of cause)
;;

let test_a_raised_summary_names_its_site_and_is_one_line () =
  let cause =
    Krf.Raised { site = Krf.Stream_submit; exn = "Failure(\"a\nb\rc\")" }
  in
  let summary = summary_of cause in
  Alcotest.check
    Alcotest.bool
    "the site is named"
    true
    (String.length summary > 0
     && not (String.exists (function '\n' | '\r' -> true | _ -> false) summary))
;;

let test_a_masc_summary_without_one_keeps_the_envelope () =
  (* Two kinds answer [None] on purpose until the row carries the value
     (RFC-0454 D3); the pane reads the envelope back to draw its badge, so the
     summary must still be that envelope. *)
  let masc_error =
    Kie.Runtime_connection_closed
      { runtime_id = "codex_app_server"; detail = "stdout closed"; turn_accepted = false }
  in
  Alcotest.check
    Alcotest.string
    "the envelope survives a kind with no summary"
    (Agent_core.Error.to_string (Kie.core_error_of_masc_internal_error masc_error))
    (summary_of (Krf.Masc masc_error))
;;

(* ------------------------------------------------------------------ *)
(* Codec                                                               *)
(* ------------------------------------------------------------------ *)

let every_cause =
  [ Krf.Core
      (Keeper_request_failure_core.of_core_error (Agent_core.Error.Internal "boom"))
  ; Krf.Masc (Kie.Receipt_persistence_failed { detail = "disk full" })
  ; Krf.Provider_network
      { provider = Some "ollama_cloud"
      ; kind = Llm_provider.Http_client.Dns_failure
      ; detail = "no such host"
      }
  ; Krf.Provider_network
      { provider = None; kind = Llm_provider.Http_client.Unknown; detail = "" }
  ; Krf.Context_overflow { limit = Some 128_000 }
  ; Krf.Context_overflow { limit = None }
  ; Krf.Input_capacity
  ; Krf.Operator_cancelled
  ; Krf.Server_not_initialized
  ; Krf.Server_restarted
  ; Krf.Dispatch_unavailable
  ; Krf.Keeper_meta_unresolved { keeper = "aria"; detail = "keeper not found: aria" }
  ; Krf.Keeper_not_registered { keeper = "aria" }
  ; Krf.Invocation_rejected { detail = "keeper name is empty" }
  ; Krf.Chat_identity_mismatch
  ; Krf.Turn_resources_unavailable
      { resource = Krf.Registry_entry_missing; detail = "no entry" }
  ; Krf.Turn_resources_unavailable
      { resource = Krf.Registry_entry_unhealthy; detail = "stale pid" }
  ; Krf.Runtime_selection_failed { detail = "no runtime for lane" }
  ; Krf.Turn_continuation_unpersisted
      { stage = Krf.Continuation_load; detail = "decode failed" }
  ; Krf.Turn_continuation_unpersisted { stage = Krf.Gate_suspend; detail = "no slot" }
  ; Krf.Turn_continuation_unpersisted
      { stage = Krf.Runtime_continuation_defer; detail = "write failed" }
  ; Krf.Turn_continuation_unpersisted
      { stage = Krf.Checkpoint_retain; detail = "no receipt" }
  ; Krf.User_row_unpersisted { detail = "append failed" }
  ; Krf.Gate_session_full
      { approval_id = "approval-1"
      ; runtime_id = "claude_code"
      ; session_id = "session-1"
      ; recovery_id = "00000000-0000-4000-8000-000000000001"
      ; activity = Kie.No_activity_observed
      }
  ; Krf.Gate_session_full
      { approval_id = "approval-2"
      ; runtime_id = "codex"
      ; session_id = "thread-1"
      ; recovery_id = "00000000-0000-4000-8000-000000000002"
      ; activity = Kie.Activity_observed
      }
  ; Krf.Reply_contract_rejected { field = Krf.Reply_payload; detail = "not an object" }
  ; Krf.Reply_contract_rejected { field = Krf.Turn_outcome; detail = "missing" }
  ; Krf.Reply_contract_rejected { field = Krf.Turn_ref; detail = "invalid" }
  ; Krf.Reply_contract_rejected
      { field = Krf.External_effect_target; detail = "unknown target" }
  ; Krf.No_visible_reply { stage = Krf.Terminal_projection; had_blocks = false }
  ; Krf.No_visible_reply { stage = Krf.Queued_delivery; had_blocks = true }
  ; Krf.Raised { site = Krf.Stream_dispatch; exn = "Not_found" }
  ; Krf.Raised { site = Krf.Stream_streaming_call; exn = "Not_found" }
  ; Krf.Raised { site = Krf.Stream_turn_body; exn = "Not_found" }
  ; Krf.Raised { site = Krf.Stream_submit; exn = "Not_found" }
  ]
;;

let test_every_constructor_round_trips () =
  List.iter
    (fun cause ->
       let failure = { Krf.cause } in
       match Krf.of_yojson (Krf.to_yojson failure) with
       | Ok decoded -> Alcotest.check cause_testable "round trip" cause decoded.Krf.cause
       | Error detail -> Alcotest.fail ("round trip refused its own output: " ^ detail))
    every_cause
;;

let test_every_constructor_has_a_one_line_summary () =
  List.iter
    (fun cause ->
       let summary = summary_of cause in
       if String.trim summary = ""
       then Alcotest.fail "a cause with no summary leaves the operator nothing";
       if String.exists (function '\n' | '\r' -> true | _ -> false) summary
       then Alcotest.fail ("summary spans lines: " ^ summary))
    every_cause
;;

let refused what json =
  match Krf.of_yojson json with
  | Ok _ -> Alcotest.fail (what ^ " was accepted")
  | Error _ -> ()
;;

let test_the_decoder_refuses_what_it_does_not_write () =
  refused "an unknown kind" (`Assoc [ "cause", `Assoc [ "kind", `String "vibes" ] ]);
  refused
    "a missing field"
    (`Assoc [ "cause", `Assoc [ "kind", `String "keeper_not_registered" ] ]);
  refused
    "an extra field"
    (`Assoc
       [ ( "cause"
         , `Assoc
             [ "kind", `String "server_restarted"; "detail", `String "why" ] )
       ]);
  refused
    "a field of the wrong type"
    (`Assoc
       [ ( "cause"
         , `Assoc
             [ "kind", `String "no_visible_reply"
             ; "stage", `String "queued_delivery"
             ; "had_blocks", `String "true"
             ] )
       ]);
  refused
    "an unknown labelled value"
    (`Assoc
       [ ( "cause"
         , `Assoc
             [ "kind", `String "turn_continuation_unpersisted"
             ; "stage", `String "somewhere_else"
             ; "detail", `String "x"
             ] )
       ]);
  refused "an extra top-level field"
    (`Assoc
       [ "cause", `Assoc [ "kind", `String "input_capacity" ]
       ; "summary", `String "derived state does not belong on the wire"
       ]);
  refused "a cause that is not an object" (`Assoc [ "cause", `String "input_capacity" ]);
  refused "a failure that is not an object" (`String "input_capacity")
;;

let test_a_nested_masc_error_is_an_object_not_a_string () =
  let failure =
    { Krf.cause = Krf.Masc (Kie.Receipt_persistence_failed { detail = "disk full" }) }
  in
  match Krf.to_yojson failure with
  | `Assoc [ ("cause", `Assoc fields) ] ->
    (match List.assoc_opt "error" fields with
     | Some (`Assoc _) -> ()
     | Some _ | None ->
       Alcotest.fail "a nested MASC error must be written as the object it is")
  | _ -> Alcotest.fail "a failure is a one-field object"
;;

let () =
  Alcotest.run
    "keeper request failure"
    [ ( "producer to constructor"
      , [ Alcotest.test_case
            "an agent-core transport failure"
            `Quick
            test_api_network_becomes_provider_network
        ; Alcotest.test_case
            "a provider transport failure"
            `Quick
            test_provider_network_keeps_its_provider
        ; Alcotest.test_case
            "a context overflow"
            `Quick
            test_context_overflow_carries_the_window
        ; Alcotest.test_case
            "a carried MASC error"
            `Quick
            test_carried_masc_error_stays_a_masc_value
        ; Alcotest.test_case
            "an agent-core failure with no arm of its own"
            `Quick
            test_unnamed_agent_core_failure_stays_core
        ; Alcotest.test_case
            "the operator interrupt detail"
            `Quick
            test_operator_interrupt_detail_is_the_typed_summary
        ] )
    ; ( "summary"
      , [ Alcotest.test_case "one line" `Quick test_a_summary_is_one_line
        ; Alcotest.test_case
            "a caught exception"
            `Quick
            test_a_raised_summary_names_its_site_and_is_one_line
        ; Alcotest.test_case
            "a MASC kind with no summary"
            `Quick
            test_a_masc_summary_without_one_keeps_the_envelope
        ; Alcotest.test_case
            "every constructor answers"
            `Quick
            test_every_constructor_has_a_one_line_summary
        ] )
    ; ( "codec"
      , [ Alcotest.test_case
            "every constructor round trips"
            `Quick
            test_every_constructor_round_trips
        ; Alcotest.test_case
            "strict decoding"
            `Quick
            test_the_decoder_refuses_what_it_does_not_write
        ; Alcotest.test_case
            "a nested MASC error"
            `Quick
            test_a_nested_masc_error_is_an_object_not_a_string
        ] )
    ]
;;
