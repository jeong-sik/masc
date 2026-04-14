type verification_refs = {
  fixture_harness : string option;
  live_spotcheck : string option;
  logs_ref : string option;
  metrics_ref : string option;
  proof_ref : string option;
  tool_name : string option;
}

type surface_entry = {
  id : string;
  label : string;
  exposure_status : string;
  hidden_from_nav : bool;
  meets_main_gate : bool;
  rationale : string;
  route_hash : string option;
  refs : verification_refs;
}

let ref_json ~kind ~label value =
  `Assoc [ ("kind", `String kind); ("label", `String label); ("value", `String value) ]

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

let refs_json (refs : verification_refs) =
  [
    Option.map (ref_json ~kind:"script" ~label:"fixture_harness") refs.fixture_harness;
    Option.map
      (fun value ->
        ref_json
          ~kind:(live_spotcheck_kind value)
          ~label:"live_spotcheck"
          value)
      refs.live_spotcheck;
    Option.map (ref_json ~kind:"route" ~label:"logs") refs.logs_ref;
    Option.map (ref_json ~kind:"route" ~label:"metrics") refs.metrics_ref;
    Option.map (ref_json ~kind:"route" ~label:"proof") refs.proof_ref;
    Option.map (ref_json ~kind:"tool" ~label:"tool_name") refs.tool_name;
  ]
  |> List.filter_map (fun item -> item)

let entry_json (entry : surface_entry) =
  `Assoc
    [
      ("id", `String entry.id);
      ("label", `String entry.label);
      ("exposure_status", `String entry.exposure_status);
      ("hidden_from_nav", `Bool entry.hidden_from_nav);
      ("meets_main_gate", `Bool entry.meets_main_gate);
      ("proof_bar", `String "fixture+live_spotcheck");
      ("rationale", `String entry.rationale);
      ("route_hash", Json_util.string_opt_to_json entry.route_hash);
      ("verification_refs", `List (refs_json entry.refs));
    ]

let all_entries =
  [
    {
      id = "overview";
      label = "오버뷰";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale =
        "오버뷰는 shell/mission/namespace truth를 묶는 front-door 브리핑 surface라 메인에서 유지합니다.";
      route_hash = Some "#overview";
      refs =
        {
          fixture_harness = Some "./scripts/harness_dashboard_mission_smoke.sh";
          live_spotcheck = Some "/api/v1/dashboard/shell";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = Some "/api/v1/dashboard/proof";
          tool_name = Some "masc_operator_snapshot";
        };
    };
    {
      id = "monitoring.sessions";
      label = "세션 & 네임스페이스";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale =
        "세션 운영은 fixture smoke, live session smoke, logs, metrics, proof 경로를 모두 갖춘 메인 surface입니다.";
      route_hash = Some "#monitoring?section=sessions";
      refs =
        {
          fixture_harness = Some "./scripts/harness_dashboard_mission_smoke.sh";
          live_spotcheck = None;
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = Some "/api/v1/dashboard/proof";
          tool_name = None;
        };
    };
    {
      id = "monitoring.agents";
      label = "에이전트 & 키퍼";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale = "에이전트/키퍼 관찰은 메인 운영 surface로 유지합니다.";
      route_hash = Some "#monitoring?section=agents";
      refs =
        {
          fixture_harness = None;
          live_spotcheck = Some "./scripts/harness/workload/keeper_continuity_validation.sh";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = Some "masc_operator_snapshot";
        };
    };
    {
      id = "monitoring.activity";
      label = "활동 그래프";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale = "실시간 활동은 activity graph test와 SSE/log 경로가 있어 메인에서 유지합니다.";
      route_hash = Some "#monitoring?section=activity";
      refs =
        {
          fixture_harness = Some "dune exec ./test/test_activity_graph.exe";
          live_spotcheck = Some "/api/v1/activity/graph";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = None;
        };
    };
    {
      id = "command.intervene";
      label = "운영 큐";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale = "review queue, 추천 액션, 승인 대기를 한 화면에서 처리하는 canonical operator surface라 메인에 유지합니다.";
      route_hash = Some "#command?section=intervene";
      refs =
        {
          fixture_harness = Some "./scripts/harness_dashboard_mission_smoke.sh";
          live_spotcheck = Some "./scripts/harness/workload/supervisor_execution_session.sh";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = Some "/api/v1/dashboard/proof";
          tool_name = Some "masc_operator_digest";
        };
    };
    {
      id = "command.namespace";
      label = "네임스페이스 관제";
      exposure_status = "lab";
      hidden_from_nav = true;
      meets_main_gate = false;
      rationale =
        "오케스트라/스웜/체인/제어는 operator-facing session evidence bundle이 아직 약해 메인 탐색에서 숨기고 실험 surface로 유지합니다.";
      route_hash = Some "#command?section=namespace";
      refs =
        {
          fixture_harness = Some "./scripts/harness_agent_swarm_live.sh";
          live_spotcheck = Some "./scripts/harness/workload/agent_swarm_live.sh";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = Some "/api/v1/dashboard/proof";
          tool_name = Some "masc_surface_audit";
        };
    };
    {
      id = "command.governance";
      label = "거버넌스";
      exposure_status = "lab";
      hidden_from_nav = true;
      meets_main_gate = false;
      rationale = "거버넌스 전용 화면은 judge-only 보조 surface로 축소하고, 메인 운영 판단/개입은 command.intervene의 ops queue에 수렴합니다.";
      route_hash = None;
      refs =
        {
          fixture_harness = None;
          live_spotcheck = Some "/api/v1/dashboard/governance";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = None;
        };
    };
    {
      id = "workspace.evidence";
      label = "근거 및 이력";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale = "Proof와 audit trail 확인 경로라 메인에 유지합니다.";
      route_hash = Some "#workspace?section=evidence";
      refs =
        {
          fixture_harness = Some "./scripts/harness_dashboard_execution_smoke.sh";
          live_spotcheck = None;
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = Some "/api/v1/dashboard/proof";
          tool_name = Some "masc_surface_audit";
        };
    };
    {
      id = "workspace.board";
      label = "작업 게시판";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale =
        "게시판은 에이전트 간 공유 사실을 확인하는 기본 협업 surface라 메인에서 유지합니다.";
      route_hash = Some "#workspace?section=board";
      refs =
        {
          fixture_harness = None;
          live_spotcheck = Some "/api/v1/dashboard/board";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = Some "masc_board_list";
        };
    };
    {
      id = "workspace.planning";
      label = "작업 큐";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale =
        "계획/goal 진행 상태는 작업 운영의 기본 읽기 surface라 메인에서 유지합니다.";
      route_hash = Some "#workspace?section=planning";
      refs =
        {
          fixture_harness = None;
          live_spotcheck = Some "/api/v1/dashboard/planning";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = Some "masc_plan_get";
        };
    };
    {
      id = "workspace.goals";
      label = "목표 트리";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale =
        "목표 트리는 planning read model 위에서 목표 계층을 읽는 메인 작업 surface로 유지합니다.";
      route_hash = Some "#workspace?section=goals";
      refs =
        {
          fixture_harness = None;
          live_spotcheck = Some "/api/v1/dashboard/planning";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = Some "masc_plan_get";
        };
    };
    {
      id = "workspace.worktrees";
      label = "워크트리";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale =
        "현재 활성 worktree inventory는 충돌 회피와 작업 격리에 직접 연결되므로 메인 작업 surface로 유지합니다.";
      route_hash = Some "#workspace?section=worktrees";
      refs =
        {
          fixture_harness = None;
          live_spotcheck = None;
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = Some "masc_worktree_list";
        };
    };
    {
      id = "lab.tools";
      label = "도구 & 실험";
      exposure_status = "lab";
      hidden_from_nav = false;
      meets_main_gate = false;
      rationale = "실험적 표면과 준비도 감사는 Lab에서 유지합니다.";
      route_hash = Some "#lab?section=tools";
      refs =
        {
          fixture_harness = None;
          live_spotcheck = Some "/api/v1/tool-metrics";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = Some "masc_surface_audit";
        };
    };
    {
      id = "lab.autoresearch";
      label = "오토리서치";
      exposure_status = "lab";
      hidden_from_nav = false;
      meets_main_gate = false;
      rationale =
        "오토리서치는 유용하지만 research loop 성격이 강해 Lab에서 유지하며 readiness만 명시합니다.";
      route_hash = Some "#lab?section=autoresearch";
      refs =
        {
          fixture_harness = None;
          live_spotcheck = Some "/api/v1/autoresearch/loops";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = Some "masc_autoresearch_status";
        };
    };
    {
      id = "lab.harness";
      label = "세이프티 하네스";
      exposure_status = "lab";
      hidden_from_nav = false;
      meets_main_gate = false;
      rationale =
        "하네스는 evaluator/compaction/handoff rail의 건강도를 읽는 실험·진단 surface로 Lab에서 유지합니다.";
      route_hash = Some "#lab?section=harness";
      refs =
        {
          fixture_harness = None;
          live_spotcheck = Some "/api/v1/dashboard/harness-health";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = Some "masc_surface_audit";
        };
    };
    {
      id = "lab.features";
      label = "피처 플래그";
      exposure_status = "lab";
      hidden_from_nav = false;
      meets_main_gate = false;
      rationale =
        "피처 플래그 헬스는 supporting read surface지만 제품 문서상 아직 split 상태라 Lab에서 유지합니다.";
      route_hash = Some "#lab?section=features";
      refs =
        {
          fixture_harness = None;
          live_spotcheck = Some "/api/v1/dashboard/feature-health";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = Some "masc_surface_audit";
        };
    };
    {
      id = "lab.config";
      label = "서버 설정";
      exposure_status = "lab";
      hidden_from_nav = false;
      meets_main_gate = false;
      rationale =
        "config introspection은 working but split 상태라 readiness를 공개하되 Lab 진단 surface로 유지합니다.";
      route_hash = Some "#lab?section=config";
      refs =
        {
          fixture_harness = None;
          live_spotcheck = Some "/api/v1/dashboard/config";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = Some "masc_config";
        };
    };
    {
      id = "logs";
      label = "로그";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale =
        "로그는 모든 surface의 운영 확인 기본선이라 메인 탐색에 남기고 readiness 기준도 함께 노출합니다.";
      route_hash = Some "#logs";
      refs =
        {
          fixture_harness = None;
          live_spotcheck = Some "/api/v1/dashboard/logs";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = None;
          tool_name = None;
        };
    };
  ]

let find_entry surface_id =
  List.find_opt (fun (entry : surface_entry) -> String.equal entry.id surface_id) all_entries

let json ?surface_id () =
  let surfaces =
    match surface_id with
    | Some value -> (
        match find_entry value with Some entry -> [ entry ] | None -> [])
    | None -> all_entries
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("proof_bar", `String "fixture+live_spotcheck");
      ("surfaces", `List (List.map entry_json surfaces));
    ]
