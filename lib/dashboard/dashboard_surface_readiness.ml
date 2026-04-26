type verification_refs =
  { fixture_harness : string option
  ; live_spotcheck : string option
  ; logs_ref : string option
  ; metrics_ref : string option
  ; proof_ref : string option
  ; tool_name : string option
  }

type surface_entry =
  { id : string
  ; label : string
  ; exposure_status : string
  ; hidden_from_nav : bool
  ; meets_main_gate : bool
  ; rationale : string
  ; route_hash : string option
  ; refs : verification_refs
  }

let ref_json ~kind ~label value =
  `Assoc [ "kind", `String kind; "label", `String label; "value", `String value ]
;;

let route_ref_prefix = '/'
let route_ref_prefix_string = String.make 1 route_ref_prefix

(** Surface readiness inventories historically stored live spotchecks as a single
    string field. Values that begin with a route prefix are dashboard endpoints;
    all other values are script or command references. Empty strings fall back to
    [script] so malformed values do not get misclassified as routes. *)
let live_spotcheck_kind (value : string) =
  if value = ""
  then "script"
  else if String.starts_with ~prefix:route_ref_prefix_string value
  then "route"
  else "script"
;;

let refs_json (refs : verification_refs) =
  [ Option.map (ref_json ~kind:"script" ~label:"fixture_harness") refs.fixture_harness
  ; Option.map
      (fun value ->
         ref_json ~kind:(live_spotcheck_kind value) ~label:"live_spotcheck" value)
      refs.live_spotcheck
  ; Option.map (ref_json ~kind:"route" ~label:"logs") refs.logs_ref
  ; Option.map (ref_json ~kind:"route" ~label:"metrics") refs.metrics_ref
  ; Option.map (ref_json ~kind:"route" ~label:"proof") refs.proof_ref
  ; Option.map (ref_json ~kind:"tool" ~label:"tool_name") refs.tool_name
  ]
  |> List.filter_map (fun item -> item)
;;

let entry_json (entry : surface_entry) =
  `Assoc
    [ "id", `String entry.id
    ; "label", `String entry.label
    ; "exposure_status", `String entry.exposure_status
    ; "hidden_from_nav", `Bool entry.hidden_from_nav
    ; "meets_main_gate", `Bool entry.meets_main_gate
    ; "proof_bar", `String "fixture+live_spotcheck"
    ; "rationale", `String entry.rationale
    ; "route_hash", Json_util.string_opt_to_json entry.route_hash
    ; "verification_refs", `List (refs_json entry.refs)
    ]
;;

let all_entries =
  [ { id = "overview"
    ; label = "오버뷰"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "오버뷰는 shell/mission/project snapshot을 묶는 front-door 브리핑 surface라 메인에서 유지합니다."
    ; route_hash = Some "#overview"
    ; refs =
        { fixture_harness = Some "./scripts/harness_dashboard_mission_smoke.sh"
        ; live_spotcheck = Some "/api/v1/dashboard/shell"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_operator_snapshot"
        }
    }
  ; { id = "monitoring.journey"
    ; label = "여정 맵"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "여정 맵은 task, run, contract, keeper 흐름을 한 read model에 묶는 canonical monitoring \
         entry point입니다."
    ; route_hash = Some "#monitoring?section=journey"
    ; refs =
        { fixture_harness = Some "./scripts/harness_dashboard_mission_smoke.sh"
        ; live_spotcheck = Some "/api/v1/dashboard/namespace-truth"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_operator_snapshot"
        }
    }
  ; { id = "monitoring.observatory"
    ; label = "관찰소 (beta)"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "관찰소는 라이브 밴드와 activity-derived investigation 패널을 통합한 canonical monitoring \
         surface입니다."
    ; route_hash = Some "#monitoring?section=observatory"
    ; refs =
        { fixture_harness = Some "dune exec ./test/test_activity_graph.exe"
        ; live_spotcheck = Some "/api/v1/activity/graph"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = None
        }
    }
  ; { id = "monitoring.agents"
    ; label = "에이전트 디렉터리"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale = "에이전트 디렉터리는 살아 있는 agent와 keeper 상태를 빠르게 훑는 기본 monitoring surface입니다."
    ; route_hash = Some "#monitoring?section=agents"
    ; refs =
        { fixture_harness = Some "./scripts/harness_keeper_continuity_validation.sh"
        ; live_spotcheck = Some "/api/v1/dashboard/namespace-truth"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_operator_snapshot"
        }
    }
  ; { id = "monitoring.runtime"
    ; label = "캐스케이드"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "캐스케이드는 provider 건강도, 모델 선택, runtime resolution을 보여주는 canonical monitoring \
         surface입니다."
    ; route_hash = Some "#monitoring?section=runtime"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/dashboard/shell"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_operator_snapshot"
        }
    }
  ; { id = "monitoring.fleet-health"
    ; label = "플릿 텔레메트리"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "플릿 텔레메트리는 event-log, comparison, tool-quality, governance sub-view를 한 surface로 \
         수렴한 canonical monitoring surface입니다."
    ; route_hash = Some "#monitoring?section=fleet-health"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/dashboard/telemetry/summary"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_operator_snapshot"
        }
    }
  ; { id = "monitoring.safe-autonomy"
    ; label = "세이프 오토노미"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "세이프 오토노미는 도구, 샌드박스, 승인, 캐스케이드/FSM, 감사 추적을 keeper별 scorecard로 모아 보는 canonical \
         monitoring surface입니다."
    ; route_hash = Some "#monitoring?section=safe-autonomy"
    ; refs =
        { fixture_harness = Some "dune exec ./test/test_dashboard_safe_autonomy.exe"
        ; live_spotcheck = Some "/api/v1/dashboard/safe-autonomy"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = Some "/api/v1/dashboard/proof"
        ; tool_name = Some "masc_surface_audit"
        }
    }
  ; { id = "monitoring.memory-subsystems"
    ; label = "기억 서브시스템"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "기억 서브시스템은 Hebbian, episodic, compaction health를 읽는 canonical monitoring \
         surface입니다."
    ; route_hash = Some "#monitoring?section=memory-subsystems"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/dashboard/memory-subsystems"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_surface_audit"
        }
    }
  ; { id = "monitoring.attribution"
    ; label = "Attribution"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "Attribution은 gate별 outcome과 최근 이벤트를 관찰하는 canonical monitoring surface입니다."
    ; route_hash = Some "#monitoring?section=attribution"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/attribution/summary"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = None
        }
    }
  ; { id = "command.operations"
    ; label = "운영 행동"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "운영 행동은 ops, governance, inspector sub-view를 하나로 묶은 command surface의 canonical \
         entry입니다."
    ; route_hash = Some "#command?section=operations"
    ; refs =
        { fixture_harness = Some "./scripts/harness_dashboard_execution_smoke.sh"
        ; live_spotcheck = Some "./scripts/harness_dashboard_execution_smoke.sh"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_operator_digest"
        }
    }
  ; { id = "connectors.connector-status"
    ; label = "전체"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "전체 커넥터 상태는 Discord, iMessage, Slack, Telegram sidecar를 한 화면에서 보는 canonical \
         connectors surface입니다."
    ; route_hash = Some "#connectors?section=connector-status"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/gate/connectors"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = None
        }
    }
  ; { id = "connectors.connector-discord"
    ; label = "Discord"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "Discord connector view는 sidecar 상태와 keeper binding을 점검하는 canonical \
         per-connector surface입니다."
    ; route_hash = Some "#connectors?section=connector-discord"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/gate/connectors"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = None
        }
    }
  ; { id = "connectors.connector-imessage"
    ; label = "iMessage"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "iMessage connector view는 self-chat/polling 상태를 점검하는 canonical per-connector \
         surface입니다."
    ; route_hash = Some "#connectors?section=connector-imessage"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/gate/connectors"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = None
        }
    }
  ; { id = "connectors.connector-slack"
    ; label = "Slack"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "Slack connector view는 Socket Mode와 bot/app token wiring을 점검하는 canonical \
         per-connector surface입니다."
    ; route_hash = Some "#connectors?section=connector-slack"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/gate/connectors"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = None
        }
    }
  ; { id = "connectors.connector-telegram"
    ; label = "Telegram"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "Telegram connector view는 bot token과 admin wiring을 점검하는 canonical per-connector \
         surface입니다."
    ; route_hash = Some "#connectors?section=connector-telegram"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/gate/connectors"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = None
        }
    }
  ; { id = "workspace.board"
    ; label = "작업 게시판"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale = "게시판은 에이전트 간 공유 사실을 확인하는 기본 협업 surface라 메인에서 유지합니다."
    ; route_hash = Some "#workspace?section=board"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/dashboard/board"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_board_list"
        }
    }
  ; { id = "workspace.planning"
    ; label = "계획 & 목표"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "계획과 goal tree는 하나의 planning surface로 수렴했으므로 workspace의 canonical planning \
         entry로 유지합니다."
    ; route_hash = Some "#workspace?section=planning"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/dashboard/planning"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_plan_get"
        }
    }
  ; { id = "workspace.verification"
    ; label = "검증"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale =
        "검증 요청 테이블은 completion contract와 evidence follow-up을 보는 canonical workspace \
         surface입니다."
    ; route_hash = Some "#workspace?section=verification"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/verification/requests"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = None
        }
    }
  ; { id = "lab.tools"
    ; label = "도구"
    ; exposure_status = "lab"
    ; hidden_from_nav = false
    ; meets_main_gate = false
    ; rationale = "도구 surface는 등록된 MCP inventory와 사용 현황을 점검하는 Lab의 canonical entry입니다."
    ; route_hash = Some "#lab?section=tools"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/dashboard/tools"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_surface_audit"
        }
    }
  ; { id = "lab.autoresearch"
    ; label = "오토리서치"
    ; exposure_status = "lab"
    ; hidden_from_nav = false
    ; meets_main_gate = false
    ; rationale = "오토리서치는 유용하지만 research loop 성격이 강해 Lab에서 유지하며 readiness만 명시합니다."
    ; route_hash = Some "#lab?section=autoresearch"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/autoresearch/loops"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_autoresearch_status"
        }
    }
  ; { id = "lab.harness"
    ; label = "세이프티 하네스"
    ; exposure_status = "lab"
    ; hidden_from_nav = false
    ; meets_main_gate = false
    ; rationale =
        "하네스는 evaluator/compaction/handoff rail의 건강도를 읽는 실험·진단 surface로 Lab에서 유지합니다."
    ; route_hash = Some "#lab?section=harness"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/dashboard/harness-health"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = Some "masc_surface_audit"
        }
    }
  ; { id = "logs"
    ; label = "로그"
    ; exposure_status = "main"
    ; hidden_from_nav = false
    ; meets_main_gate = true
    ; rationale = "로그는 모든 surface의 운영 확인 기본선이라 메인 탐색에 남기고 readiness 기준도 함께 노출합니다."
    ; route_hash = Some "#logs"
    ; refs =
        { fixture_harness = None
        ; live_spotcheck = Some "/api/v1/dashboard/logs"
        ; logs_ref = Some "/api/v1/dashboard/logs"
        ; metrics_ref = Some "/metrics"
        ; proof_ref = None
        ; tool_name = None
        }
    }
  ]
;;

let find_entry surface_id =
  List.find_opt
    (fun (entry : surface_entry) -> String.equal entry.id surface_id)
    all_entries
;;

let json ?surface_id () =
  let surfaces =
    match surface_id with
    | Some value ->
      (match find_entry value with
       | Some entry -> [ entry ]
       | None -> [])
    | None -> all_entries
  in
  `Assoc
    [ "generated_at", `String (Types.now_iso ())
    ; "proof_bar", `String "fixture+live_spotcheck"
    ; "surfaces", `List (List.map entry_json surfaces)
    ]
;;
