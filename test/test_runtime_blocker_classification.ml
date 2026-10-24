(** Runtime-blocker classification: a provider runtime record reaches the
    bridge class its typed reason names, its summary is the record itself,
    every agent error follows its decision, and the dashboard's label fixture
    holds every class. *)

open Alcotest
module Kmc = Masc.Keeper_meta_contract
open Kmc

module KSB = Masc.Keeper_status_bridge_blocker
module KTD = Masc.Keeper_turn_driver
module Reg = Masc.Keeper_registry

(* ── Provider runtime record classification ────────────────────── *)

let provider_runtime_surface_exn
      ?(detail = "provider runtime failed")
      ~reason
      ~code
      ()
  =
  let failure_reason =
    Reg.Provider_runtime_error
      { code
      ; detail
      ; provider_id = None
      ; http_status = None
      ; runtime_id = Some "r"
      ; agent_core_timeout = None
      ; fenced_empty_turn_runtime = None
      ; reason
      }
  in
  match (KSB.runtime_blocker_surface_of_failure_reason
      ~latest_receipt:(fun () -> Masc.Keeper_execution_receipt.No_receipt)) failure_reason with
  | Some surface -> surface
  | None ->
    fail "runtime_blocker_surface_of_failure_reason returned None for Provider_runtime_error"
;;

(* This used to assert the fall-through: a Provider_runtime_error carrying a
   typed exhaustion reason still came out labelled "provider_runtime_error",
   even with a code that spelled the exhaustion out. That is what made the
   status bridge's runtime_exhausted arm unreachable (#30447) — the registry
   wraps exhaustion in this constructor and the reason was being dropped. *)
let test_typed_provider_reason_reaches_runtime_exhausted () =
  let surface =
    provider_runtime_surface_exn
      ~reason:(Some Connection_refused)
      ~code:"runtime_exhausted_connection_refused"
      ()
  in
  check string
    "a typed exhaustion reason is not flattened into the provider catch-all"
    "runtime_exhausted"
    (KSB.runtime_blocker_class_to_string surface.KSB.blocker_class)
;;

let test_reason_none_provider_error_falls_through () =
  let surface =
    provider_runtime_surface_exn ~reason:None ~code:"provider_error"
      ()
  in
  check string
    "reason=None provider error -> provider_runtime_error catch-all"
    "provider_runtime_error"
    (KSB.runtime_blocker_class_to_string surface.KSB.blocker_class)
;;

(* A typed provider code that is not a timeout retains the boundary's
   code and detail in the operator summary. *)
let test_typed_provider_code_summary_is_the_record () =
  let code = "provider_error_reported:rpc_error" in
  let detail = "The provider reported that the RPC request failed." in
  let surface = provider_runtime_surface_exn ~reason:None ~code ~detail () in
  check string "class" "provider_runtime_error" (KSB.runtime_blocker_class_to_string surface.KSB.blocker_class);
  check string "the summary is the record's code and detail"
    (Printf.sprintf "Provider runtime error (%s): %s" code detail)
    (Lazy.force surface.KSB.summary)
;;

let test_provider_timeout_catch_all_stays_provider_runtime_error () =
  let surface =
    provider_runtime_surface_exn
      ~reason:None
      ~code:"provider_error_timeout:http_operation"
      ~detail:
        "Provider 'unknown' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
      ()
  in
  check string
    "provider timeout catch-all remains provider_runtime_error"
    "provider_runtime_error"
    (KSB.runtime_blocker_class_to_string surface.KSB.blocker_class)
;;

let test_provider_timeout_detail_without_code_does_not_map_to_turn_timeout () =
  let surface =
    provider_runtime_surface_exn
      ~reason:None
      ~code:"provider_error"
      ~detail:
        "Provider 'unknown' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
      ()
  in
  check
    string
    "detail-only timeout text is not trusted"
    "provider_runtime_error"
    (KSB.runtime_blocker_class_to_string surface.KSB.blocker_class)
;;

let test_masc_accept_rejected_provider_record_does_not_reparse_detail () =
  let accept_error =
    KTD.core_error_of_masc_internal_error
      (KTD.Accept_rejected
         { scope = "runpod_fable5.gemma4-coder-fable5"
         ; model = Some "runtime"
         ; reason_kind = Some KTD.Accept_no_usable_progress
         ; response_shape = Some KTD.Accept_response_empty
         ; stop_reason = None
         ; reason = "shape=empty; stop_reason=end_turn"
         })
  in
  let surface =
    provider_runtime_surface_exn
      ~reason:None
      ~code:"accept_rejected"
      ~detail:(Agent_core.Error.to_string accept_error)
      ()
  in
  check string
    "provider runtime detail is not reparsed"
    "provider_runtime_error"
    (KSB.runtime_blocker_class_to_string surface.KSB.blocker_class)
;;

(* ── Agent_core agent_error decision (#38940 review) ────────────── *)

(* Every [Agent_core.Error.agent_error] constructor is decided here, on the
   live path: [classify_masc_internal_error] is what turns a core error into a
   typed internal error, and so into a runtime blocker. The match below has no
   catch-all, so a constructor added to agent core fails to compile until
   someone decides whether it reaches the operator as a typed internal error
   ([true]) or only through the turn receipt ([false]). The test then holds
   the live function to that decision. *)
let reaches_typed_internal_error : Agent_core.Error.agent_error -> bool = function
  | Agent_core.Error.TerminalToolEffectFailed _
  | Agent_core.Error.TerminalToolDurabilityFailed _ -> true
  | Agent_core.Error.UnrecognizedStopReason _
  | Agent_core.Error.ToolRoundLimitExceeded _
  | Agent_core.Error.HookExecutionFailed _
  | Agent_core.Error.GuardrailViolation _
  | Agent_core.Error.TripwireViolation _
  | Agent_core.Error.InputRequired _ -> false
;;

let one_of_each_agent_error : Agent_core.Error.agent_error list =
  let module E = Agent_core.Error in
  let invocation =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"tool-durable"
      ~turn:3
      ~schedule:
        { planned_index = 1
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial
        }
      ~completion:
        (Agent_core.Tool_contract.Terminal_after_success
           Agent_core.Tool_contract.Effect_outcome_unknown)
  in
  [ E.UnrecognizedStopReason { reason = "abrupt" }
  ; E.ToolRoundLimitExceeded { rounds = 9; limit = 8 }
  ; E.HookExecutionFailed
      { hook_name = "post_tool_use"
      ; stage = "execute"
      ; tool_name = Some "Execute"
      ; tool_use_id = Some "tool-1"
      ; detail = "hook failed"
      }
  ; E.TerminalToolEffectFailed
      { tool_use_id = "tool-terminal"
      ; effect_disposition = E.proven_post_terminal_effect
      ; detail = "terminal effect failed"
      }
  ; E.TerminalToolDurabilityFailed
      { invocation
      ; effect_disposition = E.unknown_terminal_effect
      ; detail = "receipt persistence failed"
      }
  ; E.GuardrailViolation { validator = "content_filter"; reason = "toxic" }
  ; E.TripwireViolation { tripwire = "disallow_shell"; reason = "exec detected" }
  ; E.InputRequired
      { request_id = "req-1"
      ; participant_name = Some "user"
      ; question = "What should I do?"
      ; schema = None
      ; timeout_s = None
      ; created_at = 0.0
      }
  ]
;;

let test_agent_errors_follow_their_decision () =
  List.iter
    (fun agent_error ->
       let expected = reaches_typed_internal_error agent_error in
       let actual =
         Option.is_some
           (KTD.classify_masc_internal_error (Agent_core.Error.Agent agent_error))
       in
       check
         bool
         (Agent_core.Error.to_string (Agent_core.Error.Agent agent_error))
         expected
         actual)
    one_of_each_agent_error
;;

(* ── Labels the dashboard reads ───────────────────────────────── *)

(* The dashboard narrows [runtime_blocker_class] to its own closed list. Its
   vitest suite checks that list against this fixture, and this test checks
   the fixture against every class here, so a label added, renamed or removed
   on one side fails until both sides and the fixture agree. *)
let test_dashboard_fixture_holds_every_label () =
  let fixture =
    In_channel.with_open_text
      "../dashboard/src/api/fixtures/runtime-blocker-classes.json"
      In_channel.input_all
    |> Yojson.Safe.from_string
  in
  let labels =
    match fixture with
    | `List items ->
      List.mapi
        (fun index -> function
           | `String label -> label
           | other ->
             failf "fixture item %d is not a string: %s" index
               (Yojson.Safe.to_string other))
        items
    | other -> failf "fixture is not a list: %s" (Yojson.Safe.to_string other)
  in
  check (list string) "fixture holds one label per class, in declaration order"
    (List.map KSB.runtime_blocker_class_to_string KSB.all_of_runtime_blocker_class)
    labels
;;

(* ── Runner ────────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "runtime_blocker_classification"
    [ ( "provider_runtime_record"
      , [ test_case "typed reason reaches runtime_exhausted" `Quick
            test_typed_provider_reason_reaches_runtime_exhausted
        ; test_case "reason=None provider error falls through" `Quick
            test_reason_none_provider_error_falls_through
        ; test_case "a typed provider code is summarised as its own record" `Quick
            test_typed_provider_code_summary_is_the_record
        ; test_case "provider timeout catch-all stays provider runtime" `Quick
            test_provider_timeout_catch_all_stays_provider_runtime_error
        ; test_case
            "provider timeout detail without code stays provider runtime"
            `Quick
            test_provider_timeout_detail_without_code_does_not_map_to_turn_timeout
        ; test_case "provider runtime detail is not reparsed" `Quick
            test_masc_accept_rejected_provider_record_does_not_reparse_detail
        ] )
    ; ( "agent_error_decision"
      , [ test_case "every agent_error follows its decision" `Quick
            test_agent_errors_follow_their_decision
        ] )
    ; ( "dashboard_labels"
      , [ test_case "the dashboard fixture holds every class" `Quick
            test_dashboard_fixture_holds_every_label
        ] )
    ]
;;
