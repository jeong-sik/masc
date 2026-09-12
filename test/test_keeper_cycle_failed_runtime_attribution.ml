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
    walk recorded, never from the execution record. *)

open Alcotest

module Types = Masc.Keeper_unified_turn_types
module Driver = Masc.Keeper_turn_driver

let malformed_payload_error =
  Agent_core.Error.Provider
    (Llm_provider.Error.ProviderWireError
       { provider = "unknown"
       ; format = Llm_provider.Http_client.Sse
       ; kind = Llm_provider.Http_client.Malformed_payload
       ; detail = "SSE parse failed: json_error: unexpected token"
       })
;;

let attempt ~runtime_id ~error : Types.dispatched_runtime_attempt =
  { runtime_id; error }
;;

let reported_runtime : Types.keeper_cycle_failed_runtime testable =
  testable
    (fun fmt r -> Format.pp_print_string fmt (Types.keeper_cycle_failed_runtime_to_string r))
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
    Types.keeper_cycle_failed_runtime_attribution
      ~deferred_runtime_lane:(Some real_incident_lane)
      ~lane_runtime_id:"ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"
      ~dispatched_attempts:
        [ attempt ~runtime_id:"glm-coding.glm-5-turbo" ~error:malformed_payload_error ]
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
    Types.keeper_cycle_failed_runtime_attribution
      ~deferred_runtime_lane:None
      ~lane_runtime_id:"claude_code.claude-sonnet-5"
      ~dispatched_attempts:
        [ attempt
            ~runtime_id:"glm-coding.glm-5.3"
            ~error:(Agent_core.Error.Internal "stream idle")
        ; attempt
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
       (fun (a : Types.dispatched_runtime_attempt) -> a.runtime_id)
       attribution.Types.attempts)
;;

let test_no_attempt_reports_no_candidate_not_the_lane () =
  let attribution =
    Types.keeper_cycle_failed_runtime_attribution
      ~deferred_runtime_lane:None
      ~lane_runtime_id:"claude_code.claude-sonnet-5"
      ~dispatched_attempts:[]
  in
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
    Types.dispatched_runtime_attempts_to_string
      [ attempt
          ~runtime_id:"glm-coding.glm-5.3"
          ~error:(Agent_core.Error.Internal "stream idle")
      ; attempt
          ~runtime_id:"ollama_cloud.deepseek-v4-flash"
          ~error:(Agent_core.Error.Internal "Payment required: Insufficient Balance")
      ]
  in
  check bool
    "rendering opens with the first candidate"
    true
    (String.starts_with ~prefix:"[glm-coding.glm-5.3=" rendered);
  check bool
    "rendering names the second candidate after the first"
    true
    (match String.split_on_char ',' rendered with
     | [ _first; second ] ->
       String.starts_with ~prefix:" ollama_cloud.deepseek-v4-flash=" second
     | _ -> false);
  check bool "rendering closes the list" true (String.ends_with ~suffix:"]" rendered);
  check string "an empty attempt list renders as []" "[]"
    (Types.dispatched_runtime_attempts_to_string [])
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
        ] )
    ]
;;
