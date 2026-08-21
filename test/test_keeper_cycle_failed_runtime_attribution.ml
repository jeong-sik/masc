(** [keeper_cycle_failed_runtime_attribution] tests (masc#28762).

    Reproduces the observed defect: a keeper cycle budgeted under a
    deferred-lane assignment (e.g. "ollama_cloud...deepseek...") whose
    [Runtime_lane_preference] sticky ordering actually dispatches a
    different candidate first (e.g. "glm-coding.glm-5-turbo"). Before the
    fix, the "keeper cycle FAILED" log named the untried lane assignment
    instead of the runtime that actually errored — misattributing every
    provider-wire failure on that lane to a provider that was never
    contacted. *)

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

(** Mirrors the real incident (masc#28761/#28762, 2026-08-15T11:49:38Z,
    keeper=alpha, turn=6595): the cycle's [execution.runtime_id] is the
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
      ~execution_runtime_id:"ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"
  in
  check string
    "runtime= names the candidate that actually dispatched and failed, \
     not the lane entry point"
    "glm-coding.glm-5-turbo"
    attribution.Types.reported_runtime_id;
  check string
    "deferred_next_runtime= is a separate field for what the next cycle \
     will try"
    "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"
    attribution.Types.deferred_next_runtime_id
;;

let test_no_deferral_reports_the_execution_runtime_unchanged () =
  let attribution =
    Types.keeper_cycle_failed_runtime_attribution
      ~deferred_runtime_lane:None
      ~execution_runtime_id:"glm-coding.glm-5-turbo"
  in
  check string
    "with no same-turn deferral, [execution_runtime_id] is already the \
     dispatched candidate"
    "glm-coding.glm-5-turbo"
    attribution.Types.reported_runtime_id;
  check string
    "no deferral occurred, so there is no next-runtime hint to report"
    "none"
    attribution.Types.deferred_next_runtime_id
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
            "no deferral reports the execution runtime unchanged"
            `Quick
            test_no_deferral_reports_the_execution_runtime_unchanged
        ] )
    ]
;;
