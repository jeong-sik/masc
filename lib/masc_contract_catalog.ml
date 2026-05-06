type contract_spec =
  { name : string
  ; description : string
  ; invariants : string list
  ; requested_execution_mode : Agent_sdk.Execution_mode.t
  ; risk_class : Agent_sdk.Risk_class.t
  ; allowed_mutations : string list
  ; review_requirement : string option
  }

let cascade_critical =
  { name = "masc-cascade-critical"
  ; description = "MASC cascade의 영속성을 보장하는 계약"
  ; invariants =
      [ "reaction_chain_never_empty"
      ; "provider_health_min_threshold"
      ; "cascade_step_timeout_max_5s"
      ; "keeper_stall_max_60s"
      ]
  ; requested_execution_mode = Agent_sdk.Execution_mode.Execute
  ; risk_class = Agent_sdk.Risk_class.Critical
  ; allowed_mutations = [ "cascade_route"; "provider_fallback"; "telemetry_emit" ]
  ; review_requirement = Some "operator_approval"
  }
;;

let keeper_lifecycle =
  { name = "masc-keeper-lifecycle"
  ; description = "Keeper의 생명주기 관리 계약"
  ; invariants =
      [ "zombie_phase_reports_to_supervisor"
      ; "fiber_isolation_no_propagation"
      ; "state_drift_detected_within_30s"
      ]
  ; requested_execution_mode = Agent_sdk.Execution_mode.Draft
  ; risk_class = Agent_sdk.Risk_class.High
  ; allowed_mutations =
      [ "keeper_lifecycle_update"; "supervisor_restart"; "telemetry_emit" ]
  ; review_requirement = Some "supervisor_review"
  }
;;

let dashboard_telemetry =
  { name = "masc-dashboard-telemetry"
  ; description = "대시보드 텔레메트리 계약"
  ; invariants =
      [ "all_keeper_states_telemetryzed"
      ; "operator_nudge_response_5s"
      ; "cascade_hits_visible_realtime"
      ]
  ; requested_execution_mode = Agent_sdk.Execution_mode.Diagnose
  ; risk_class = Agent_sdk.Risk_class.Medium
  ; allowed_mutations = []
  ; review_requirement = None
  }
;;

let all = [ cascade_critical; keeper_lifecycle; dashboard_telemetry ]

let find name =
  List.find_opt (fun spec -> String.equal spec.name name) all
;;

let eval_criteria spec =
  `Assoc
    [ "contract_name", `String spec.name
    ; "description", `String spec.description
    ; "invariants", `List (List.map (fun invariant -> `String invariant) spec.invariants)
    ]
;;

let to_risk_contract spec : Agent_sdk.Risk_contract.t =
  { runtime_constraints =
      { requested_execution_mode = spec.requested_execution_mode
      ; risk_class = spec.risk_class
      ; allowed_mutations = spec.allowed_mutations
      ; review_requirement = spec.review_requirement
      }
  ; eval_criteria = eval_criteria spec
  }
;;
