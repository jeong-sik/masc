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

let refs_json (refs : verification_refs) =
  [
    Option.map (ref_json ~kind:"script" ~label:"fixture_harness") refs.fixture_harness;
    Option.map (ref_json ~kind:"script" ~label:"live_spotcheck") refs.live_spotcheck;
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
          live_spotcheck = Some "./scripts/harness_dashboard_collaboration_evidence_smoke.sh";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = Some "/api/v1/dashboard/proof";
          tool_name = Some "masc_operator_snapshot";
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
          tool_name = Some "masc_operator_snapshot";
        };
    };
    {
      id = "command.intervene";
      label = "실시간 개입";
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale = "namespace/session/keeper 액션은 운영자 개입 surface로 메인에 유지합니다.";
      route_hash = Some "#command?section=intervene";
      refs =
        {
          fixture_harness = Some "./scripts/harness_dashboard_mission_smoke.sh";
          live_spotcheck = Some "./scripts/harness/workload/supervisor_team_session.sh";
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
      exposure_status = "main";
      hidden_from_nav = false;
      meets_main_gate = true;
      rationale = "거버넌스는 메인 운영 판단 surface로 유지합니다.";
      route_hash = Some "#command?section=governance";
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
          live_spotcheck = Some "./scripts/harness_dashboard_collaboration_evidence_smoke.sh";
          logs_ref = Some "/api/v1/dashboard/logs";
          metrics_ref = Some "/metrics";
          proof_ref = Some "/api/v1/dashboard/proof";
          tool_name = Some "masc_surface_audit";
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
