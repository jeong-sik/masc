(** [keeper_cycle_failed_runtime_attribution] tests (masc#28762, masc#35043,
    audit-adversarial-20260912 L3).

    A keeper cycle is budgeted under a deferred-lane assignment (the lane
    key, e.g. "claude_code.claude-sonnet-5") whose [Runtime_lane_preference]
    sticky ordering dispatches other candidates first. Before the L3 fix the
    "keeper cycle FAILED" report substituted the dispatched candidate only
    when a same-turn deferral hint existed; every unhinted failure named the
    lane key, so 62 lines of "runtime=claude_code… error=Payment required"
    on 2026-09-10/11 pointed at a subscription lane for a 402 that deepseek
    answered. The report now takes the runtime from the attempt list the
    walk recorded, never from the execution record, and only from entries
    whose provider or client was actually invoked. The candidate whose error
    the lane returned is reported as its own fact. *)

open Alcotest

module Types = Masc.Keeper_unified_turn_types
module Driver = Masc.Keeper_turn_driver
module Dispatch = Masc.Keeper_attempt_dispatch

let malformed_payload_error =
  Agent_core.Error.Provider
    (Llm_provider.Error.ProviderWireError
       { provider = "unknown"
       ; format = Llm_provider.Http_client.Sse
       ; kind = Llm_provider.Http_client.Malformed_payload
       ; detail = "SSE parse failed: json_error: unexpected token"
       })
;;

let attempt ?(dispatch = Dispatch.Dispatched) ~runtime_id ~error ()
  : Types.runtime_attempt_error
  =
  { runtime_id; dispatch; error }
;;

let rejected ~runtime_id ~error =
  attempt ~dispatch:Dispatch.Rejected_before_dispatch ~runtime_id ~error ()
;;

let dispatched ~runtime_id ~error = attempt ~runtime_id ~error ()

let attribution
      ?deferred_runtime_lane
      ?lane_terminal_error
      ~lane_runtime_id
      runtime_attempt_errors
  =
  Types.keeper_cycle_failed_runtime_attribution
    ~deferred_runtime_lane
    ~lane_runtime_id
    ~runtime_attempt_errors
    ~lane_terminal_error
;;

let reported_runtime : Types.keeper_cycle_failed_runtime testable =
  testable
    (fun fmt r -> Format.pp_print_string fmt (Types.keeper_cycle_failed_runtime_to_string r))
    ( = )
;;

let terminal_origin : Types.keeper_cycle_failed_terminal_origin testable =
  testable
    (fun fmt o ->
       Format.pp_print_string fmt (Types.keeper_cycle_failed_terminal_origin_to_string o))
    ( = )
;;

(** Mirrors the real incident (masc#28761/#28762, 2026-08-15T11:49:38Z,
    turn=6595): the cycle's [execution.runtime_id] is the
    lane assignment "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731",
    but the candidate that was actually dispatched and failed is
    "glm-coding.glm-5-turbo". *)
let real_incident_lane =
  Driver.For_testing.make_deferred_runtime_lane
    ~assignment_id:"ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"
    ~failed_runtime_id:"glm-coding.glm-5-turbo"
    ~next_runtime_id:"ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"
    ~later_runtime_ids:[]
    ~failure:malformed_payload_error
;;

let test_deferred_lane_reports_the_dispatched_candidate () =
  let attribution =
    attribution
      ~deferred_runtime_lane:real_incident_lane
      ~lane_runtime_id:"ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"
      [ dispatched ~runtime_id:"glm-coding.glm-5-turbo" ~error:malformed_payload_error ]
  in
  check reported_runtime
    "runtime= names the candidate that actually dispatched and failed, \
     not the lane entry point"
    (Types.Dispatched_candidate "glm-coding.glm-5-turbo")
    attribution.Types.reported_runtime;
  check string
    "deferred_next_runtime= is a separate field for what the next cycle \
     will try"
    "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"
    attribution.Types.deferred_next_runtime_id
;;

(** L3 (2026-09-10T00:57:11Z, keeper goo-yang-bong): the lane keyed by
    claude_code.claude-sonnet-5 walked glm-coding then deepseek; deepseek
    answered 402. No deferral hint was recorded. Before the fix the report
    named the lane key. *)
let test_no_hint_two_attempts_reports_the_second_candidate () =
  let attribution =
    attribution
      ~lane_runtime_id:"claude_code.claude-sonnet-5"
      [ dispatched
          ~runtime_id:"glm-coding.glm-5.3"
          ~error:(Agent_core.Error.Internal "stream idle")
      ; dispatched
          ~runtime_id:"ollama_cloud.deepseek-v4-flash"
          ~error:(Agent_core.Error.Internal "Payment required: Insufficient Balance")
      ]
  in
  check reported_runtime
    "with no deferral hint the report names the last dispatched candidate, \
     not the lane key"
    (Types.Dispatched_candidate "ollama_cloud.deepseek-v4-flash")
    attribution.Types.reported_runtime;
  check string
    "the lane key is reported as its own field"
    "claude_code.claude-sonnet-5"
    attribution.Types.lane_runtime_id;
  check string
    "no deferral occurred, so there is no next-runtime hint to report"
    "none"
    attribution.Types.deferred_next_runtime_id;
  check (list string)
    "the attempt list is carried in dispatch order"
    [ "glm-coding.glm-5.3"; "ollama_cloud.deepseek-v4-flash" ]
    (List.map
       (fun (a : Types.runtime_attempt_error) -> a.runtime_id)
       attribution.Types.attempts);
  check terminal_origin
    "with no lane terminal error there is no error origin to name"
    Types.Terminal_error_not_from_a_candidate
    attribution.Types.terminal_error_origin
;;

let test_no_attempt_reports_no_candidate_not_the_lane () =
  let attribution = attribution ~lane_runtime_id:"claude_code.claude-sonnet-5" [] in
  check reported_runtime
    "a failure before any dispatch names no candidate; the lane key is never \
     substituted"
    Types.No_candidate_dispatched
    attribution.Types.reported_runtime;
  check string
    "No_candidate_dispatched renders as none"
    "none"
    (Types.keeper_cycle_failed_runtime_to_string attribution.Types.reported_runtime);
  check string
    "the lane key is still reported separately"
    "claude_code.claude-sonnet-5"
    attribution.Types.lane_runtime_id
;;

let test_attempts_render_in_dispatch_order () =
  let rendered =
    Types.runtime_attempt_errors_to_string
      [ dispatched
          ~runtime_id:"glm-coding.glm-5.3"
          ~error:(Agent_core.Error.Internal "stream idle")
      ; rejected
          ~runtime_id:"ollama_cloud.deepseek-v4-flash"
          ~error:(Agent_core.Error.Internal "runtime candidate missing")
      ]
  in
  check bool
    "rendering opens with the first candidate and its dispatch disposition"
    true
    (String.starts_with ~prefix:"[glm-coding.glm-5.3@dispatched=" rendered);
  check bool
    "rendering names the second candidate after the first, labelled as refused"
    true
    (match String.split_on_char ',' rendered with
     | [ _first; second ] ->
       String.starts_with
         ~prefix:" ollama_cloud.deepseek-v4-flash@rejected_before_dispatch="
         second
     | _ -> false);
  check bool "rendering closes the list" true (String.ends_with ~suffix:"]" rendered);
  check string "an empty attempt list renders as []" "[]"
    (Types.runtime_attempt_errors_to_string [])
;;

(** Every candidate was refused before dispatch (for example a lane whose
    candidates all vanished from the runtime table). The refusals stay in the
    attempt list as evidence, but none of them is named as the runtime that
    answered. *)
let test_pre_dispatch_refusals_alone_name_no_candidate () =
  let missing = Agent_core.Error.Internal "runtime candidate missing" in
  let attribution =
    attribution
      ~lane_runtime_id:"claude_code.claude-sonnet-5"
      [ rejected ~runtime_id:"glm-coding.glm-5.3" ~error:missing
      ; rejected ~runtime_id:"ollama_cloud.deepseek-v4-flash" ~error:missing
      ]
  in
  check reported_runtime
    "a refusal the walk made before dispatch never becomes the reported runtime"
    Types.No_candidate_dispatched
    attribution.Types.reported_runtime;
  check int
    "the refusals are kept as evidence in the attempt list"
    2
    (List.length attribution.Types.attempts)
;;

(** A dispatched candidate errored, then the walk refused a vanished tail
    before dispatch. The tail is the last attempt error, but the reported
    runtime is the candidate that was actually invoked. *)
let test_missing_tail_does_not_replace_the_dispatched_candidate () =
  let attribution =
    attribution
      ~lane_runtime_id:"claude_code.claude-sonnet-5"
      [ dispatched
          ~runtime_id:"ollama_cloud.deepseek-v4-flash"
          ~error:(Agent_core.Error.Internal "Payment required: Insufficient Balance")
      ; rejected
          ~runtime_id:"glm-coding.glm-5.3"
          ~error:(Agent_core.Error.Internal "runtime candidate missing")
      ]
  in
  check reported_runtime
    "the last dispatched candidate is reported, not the refused tail"
    (Types.Dispatched_candidate "ollama_cloud.deepseek-v4-flash")
    attribution.Types.reported_runtime;
  check (list string)
    "the attempt list still carries the refused tail after the dispatched candidate"
    [ "ollama_cloud.deepseek-v4-flash"; "glm-coding.glm-5.3" ]
    (List.map
       (fun (a : Types.runtime_attempt_error) -> a.runtime_id)
       attribution.Types.attempts)
;;

(** The exhausted-lane overflow precedence of [attempt_runtime_candidates]:
    the first candidate overflowed, the fallback was rate-limited, and the
    lane returned the overflow. The last dispatched candidate and the
    candidate whose error the lane returned are then two different
    runtimes, and the report keeps them apart. *)
let test_terminal_error_origin_can_differ_from_the_last_dispatched () =
  let overflow =
    Agent_core.Error.Api
      (Agent_core.Retry.ContextOverflow
         { message = "prompt exceeds context window"; limit = Some 1024 })
  in
  let rate_limited =
    Agent_core.Error.Api
      (Agent_core.Retry.RateLimited { retry_after = None; message = "weekly usage limit" })
  in
  let attribution =
    attribution
      ~lane_runtime_id:"claude_code.claude-sonnet-5"
      ~lane_terminal_error:
        { Driver.origin_runtime_id = "glm-coding.glm-5.3"
        ; origin_attempt = 0
        ; lane_error = overflow
        }
      [ dispatched ~runtime_id:"glm-coding.glm-5.3" ~error:overflow
      ; dispatched ~runtime_id:"ollama_cloud.deepseek-v4-flash" ~error:rate_limited
      ]
  in
  check reported_runtime
    "runtime= names the last dispatched candidate"
    (Types.Dispatched_candidate "ollama_cloud.deepseek-v4-flash")
    attribution.Types.reported_runtime;
  check terminal_origin
    "error_origin= names the earlier candidate whose overflow the lane returned"
    (Types.Terminal_error_from { runtime_id = "glm-coding.glm-5.3"; attempt = 0 })
    attribution.Types.terminal_error_origin;
  check string
    "the origin renders as runtime#attempt"
    "glm-coding.glm-5.3#0"
    (Types.keeper_cycle_failed_terminal_origin_to_string attribution.Types.terminal_error_origin)
;;

let () =
  run "keeper_cycle_failed_runtime_attribution"
    [ ( "attribution"
      , [ test_case
            "same-turn deferral reports the dispatched candidate, not the \
             lane assignment"
            `Quick
            test_deferred_lane_reports_the_dispatched_candidate
        ; test_case
            "no hint with two attempts reports the second candidate, not the \
             lane key"
            `Quick
            test_no_hint_two_attempts_reports_the_second_candidate
        ; test_case
            "no attempt reports no candidate, not the lane key"
            `Quick
            test_no_attempt_reports_no_candidate_not_the_lane
        ; test_case
            "attempts render in dispatch order"
            `Quick
            test_attempts_render_in_dispatch_order
        ; test_case
            "pre-dispatch refusals alone name no candidate"
            `Quick
            test_pre_dispatch_refusals_alone_name_no_candidate
        ; test_case
            "a refused missing tail does not replace the dispatched candidate"
            `Quick
            test_missing_tail_does_not_replace_the_dispatched_candidate
        ; test_case
            "terminal error origin can differ from the last dispatched candidate"
            `Quick
            test_terminal_error_origin_can_differ_from_the_last_dispatched
        ] )
    ]
;;
