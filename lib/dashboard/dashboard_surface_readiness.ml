type verification_refs = {
  fixture_harness : string option;
  live_spotcheck : string option;
  logs_ref : string option;
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
    Option.map (ref_json ~kind:"route" ~label:"proof") refs.proof_ref;
    Option.map (ref_json ~kind:"tool" ~label:"tool_name") refs.tool_name;
  ]
  |> List.filter_map (fun item -> item)

let nonempty = function
  | Some value -> String.trim value <> ""
  | None -> false

let verification_ref_label label value acc =
  if nonempty value then label :: acc else acc

let verification_ref_bar_for_refs (refs : verification_refs) =
  let labels =
    []
    |> verification_ref_label "fixture" refs.fixture_harness
    |> verification_ref_label "live_spotcheck" refs.live_spotcheck
    |> verification_ref_label "logs" refs.logs_ref
    |> verification_ref_label "proof" refs.proof_ref
    |> verification_ref_label "tool" refs.tool_name
    |> List.rev
  in
  match labels with
  | [] -> "none"
  | labels -> String.concat "+" labels

let entry_json (entry : surface_entry) =
  `Assoc
    [
      ("id", `String entry.id);
      ("label", `String entry.label);
      ("exposure_status", `String entry.exposure_status);
      ("hidden_from_nav", `Bool entry.hidden_from_nav);
      ("meets_main_gate", `Bool entry.meets_main_gate);
      ("verification_ref_bar", `String (verification_ref_bar_for_refs entry.refs));
      ("rationale", `String entry.rationale);
      ("route_hash", Json_util.string_opt_to_json entry.route_hash);
      ("verification_refs", `List (refs_json entry.refs));
    ]

let refs
      ?fixture_harness
      ?live_spotcheck
      ?(logs_ref = Some "/api/v1/dashboard/logs")
      ?proof_ref
      ?tool_name
      ()
  =
  { fixture_harness; live_spotcheck; logs_ref; proof_ref; tool_name }

let entry
      ~id
      ~label
      ~exposure_status
      ~hidden_from_nav
      ~meets_main_gate
      ~rationale
      ~route_hash
      ?fixture_harness
      ?live_spotcheck
      ?logs_ref
      ?proof_ref
      ?tool_name
      ()
  =
  { id
  ; label
  ; exposure_status
  ; hidden_from_nav
  ; meets_main_gate
  ; rationale
  ; route_hash = Some route_hash
  ; refs =
      refs
        ?fixture_harness
        ?live_spotcheck
        ?logs_ref
        ?proof_ref
        ?tool_name
        ()
  }

let all_entries =
  [ entry
      ~id:"cockpit"
      ~label:"MASC Cockpit"
      ~exposure_status:"diagnostic"
      ~hidden_from_nav:true
      ~meets_main_gate:false
      ~rationale:"Hidden cockpit command map retained as a diagnostic route."
      ~route_hash:"#cockpit"
      ~live_spotcheck:"/api/v1/dashboard/shell"
      ~tool_name:"masc_operator_snapshot"
      ()
  ; entry
      ~id:"overview"
      ~label:"Overview"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Front-door briefing surface for shell, mission, and project snapshots."
      ~route_hash:"#overview"
      ~fixture_harness:"./scripts/harness_dashboard_briefing_smoke.sh"
      ~live_spotcheck:"/api/v1/dashboard/shell"
      ~tool_name:"masc_operator_snapshot"
      ()
  ; entry
      ~id:"monitoring.agents"
      ~label:"Keeper Fleet"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Live agent and keeper roster surface."
      ~route_hash:"#monitoring?section=agents"
      ~fixture_harness:"./scripts/harness_keeper_continuity_validation.sh"
      ~live_spotcheck:"/api/v1/dashboard/namespace-truth"
      ~tool_name:"masc_operator_snapshot"
      ()
  ; entry
      ~id:"monitoring.fleet-health"
      ~label:"Tool Monitor"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"System-level telemetry for tools, governance, and fleet health."
      ~route_hash:"#monitoring?section=fleet-health"
      ~live_spotcheck:"/api/v1/dashboard/telemetry/summary"
      ~tool_name:"masc_operator_snapshot"
      ()
  ; entry
      ~id:"monitoring.runtime"
      ~label:"Runtime"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Canonical runtime surface for provider health."
      ~route_hash:"#monitoring?section=runtime"
      ~live_spotcheck:"/api/v1/providers"
      ~tool_name:"masc_operator_snapshot"
      ()
  ; entry
      ~id:"monitoring.observatory"
      ~label:"Observatory"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Live collaboration and investigation timeline promoted to Monitor."
      ~route_hash:"#monitoring?section=observatory"
      ~fixture_harness:"dune exec ./test/test_activity_graph.exe"
      ~live_spotcheck:"/api/v1/activity/graph"
      ()
  ; entry
      ~id:"monitoring.transport-health"
      ~label:"Transport Health"
      ~exposure_status:"diagnostic"
      ~hidden_from_nav:true
      ~meets_main_gate:false
      ~rationale:"Transport health read model for SSE, gRPC, WebSocket, and WebRTC."
      ~route_hash:"#monitoring?section=transport-health"
      ~live_spotcheck:"/api/v1/dashboard/transport-health"
      ~tool_name:"masc_operator_snapshot"
      ()
  ; entry
      ~id:"monitoring.feature-health"
      ~label:"Feature Flags"
      ~exposure_status:"diagnostic"
      ~hidden_from_nav:true
      ~meets_main_gate:false
      ~rationale:"Feature flag rollout and health snapshot promoted to Monitor."
      ~route_hash:"#monitoring?section=feature-health"
      ~live_spotcheck:"/api/v1/dashboard/feature-health"
      ~tool_name:"masc_operator_snapshot"
      ()
  ; entry
      ~id:"monitoring.journey"
      ~label:"Journey Map"
      ~exposure_status:"diagnostic"
      ~hidden_from_nav:true
      ~meets_main_gate:false
      ~rationale:"Execution-flow drill-down reachable from monitoring diagnostics."
      ~route_hash:"#monitoring?section=journey"
      ~live_spotcheck:"/api/v1/dashboard/journey"
      ~tool_name:"masc_operator_snapshot"
      ()
  ; entry
      ~id:"monitoring.cognition"
      ~label:"Keeper Cognition"
      ~exposure_status:"diagnostic"
      ~hidden_from_nav:true
      ~meets_main_gate:false
      ~rationale:"Keeper cognition and memory drill-down reachable from monitoring diagnostics."
      ~route_hash:"#monitoring?section=cognition"
      ~live_spotcheck:"/api/v1/dashboard/cognition"
      ~tool_name:"masc_operator_snapshot"
      ()
  ; entry
      ~id:"keepers"
      ~label:"Keepers"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Dedicated keeper roster, conversation, and context workspace."
      ~route_hash:"#keepers"
      ~fixture_harness:"./scripts/harness_dashboard_keeper_chat_contract_smoke.sh"
      ~live_spotcheck:"/api/v1/keepers/composite"
      ~tool_name:"masc_operator_snapshot"
      ()
  ; entry
      ~id:"board"
      ~label:"Board"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Top-level board surface for shared human, agent, automation, and system posts."
      ~route_hash:"#board"
      ~live_spotcheck:"/api/v1/dashboard/board"
      ~tool_name:"masc_board_list"
      ()
  ; entry
      ~id:"schedule"
      ~label:"Schedule"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Scheduled keeper automation and wake-signal queue."
      ~route_hash:"#schedule"
      ~live_spotcheck:"/api/v1/dashboard/tools"
      ()
  ; entry
      ~id:"approvals"
      ~label:"Approvals"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Keeper HITL approval queue for pending operator decisions."
      ~route_hash:"#approvals"
      ~live_spotcheck:"/api/v1/dashboard/governance"
      ()
  ; entry
      ~id:"fusion"
      ~label:"Fusion"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Panel and judge deliberation registry emitted by masc_fusion."
      ~route_hash:"#fusion"
      ~live_spotcheck:"/api/v1/dashboard/fusion-runs"
      ()
  ; entry
      ~id:"command.operations"
      ~label:"Actions"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Canonical command surface for operator actions and governance controls."
      ~route_hash:"#command?section=operations"
      ~fixture_harness:"./scripts/harness_dashboard_execution_smoke.sh"
      ~live_spotcheck:"./scripts/harness_dashboard_execution_smoke.sh"
      ~tool_name:"masc_operator_digest"
      ()
  ; entry
      ~id:"connectors.connector-status"
      ~label:"All"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"All connector sidecars and keeper bindings in one surface."
      ~route_hash:"#connectors?section=connector-status"
      ~live_spotcheck:"/api/v1/gate/connectors"
      ()
  ; entry
      ~id:"workspace.work"
      ~label:"Work"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Goal/job breakdown and keeper assignment board."
      ~route_hash:"#workspace?section=work"
      ~live_spotcheck:"/api/v1/dashboard/work"
      ~tool_name:"masc_tasks"
      ()
  ; entry
      ~id:"workspace.board"
      ~label:"Board"
      ~exposure_status:"diagnostic"
      ~hidden_from_nav:true
      ~meets_main_gate:false
      ~rationale:"Shared board surface for human, agent, automation, and system posts."
      ~route_hash:"#workspace?section=board"
      ~live_spotcheck:"/api/v1/dashboard/board"
      ~tool_name:"masc_board_list"
      ()
  ; entry
      ~id:"workspace.sub-boards"
      ~label:"Sub-Boards"
      ~exposure_status:"diagnostic"
      ~hidden_from_nav:true
      ~meets_main_gate:false
      ~rationale:"Named board spaces with distinct access policies."
      ~route_hash:"#workspace?section=sub-boards"
      ~live_spotcheck:"/api/v1/board/sub-boards"
      ~tool_name:"masc_board_list"
      ()
  ; entry
      ~id:"workspace.moderation"
      ~label:"Moderation"
      ~exposure_status:"diagnostic"
      ~hidden_from_nav:true
      ~meets_main_gate:false
      ~rationale:"Board moderation queue and action surface."
      ~route_hash:"#workspace?section=moderation"
      ~live_spotcheck:"/api/v1/dashboard/board/moderation/queue"
      ~tool_name:"masc_board_list"
      ()
  ; entry
      ~id:"workspace.planning"
      ~label:"Plans & Goals"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Goal loop, goal tree, and task kanban planning surface."
      ~route_hash:"#workspace?section=planning"
      ~live_spotcheck:"/api/v1/dashboard/planning"
      ~tool_name:"masc_plan_get"
      ()
  ; entry
      ~id:"workspace.repositories"
      ~label:"Repositories"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Registered repos, credentials, and keeper access scope."
      ~route_hash:"#workspace?section=repositories"
      ~live_spotcheck:"/api/v1/dashboard/surface-readiness"
      ~tool_name:"masc_surface_audit"
      ()
  ; entry
      ~id:"workspace.verification"
      ~label:"Verification"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Completion contract and evidence follow-up table."
      ~route_hash:"#workspace?section=verification"
      ~live_spotcheck:"/api/v1/verification/requests"
      ()
  ; entry
      ~id:"lab.tools"
      ~label:"Tools"
      ~exposure_status:"lab"
      ~hidden_from_nav:false
      ~meets_main_gate:false
      ~rationale:"MCP tool inventory and usage diagnostics."
      ~route_hash:"#lab?section=tools"
      ~live_spotcheck:"/api/v1/dashboard/tools"
      ~tool_name:"masc_surface_audit"
      ()
  ; entry
      ~id:"lab.harness"
      ~label:"Safety Harness"
      ~exposure_status:"lab"
      ~hidden_from_nav:false
      ~meets_main_gate:false
      ~rationale:"Evaluator, compaction, and handoff health harness."
      ~route_hash:"#lab?section=harness"
      ~live_spotcheck:"/api/v1/dashboard/harness-health"
      ~tool_name:"masc_surface_audit"
      ()
  ; entry
      ~id:"lab.performance"
      ~label:"Performance"
      ~exposure_status:"lab"
      ~hidden_from_nav:false
      ~meets_main_gate:false
      ~rationale:"FPS meter, VirtualList, content-visibility, native dialog, and observer probes."
      ~route_hash:"#lab?section=performance"
      ~live_spotcheck:"/api/v1/dashboard/surface-readiness"
      ~tool_name:"masc_surface_audit"
      ()
  ; entry
      ~id:"lab.memory-subsystems"
      ~label:"Memory OS"
      ~exposure_status:"lab"
      ~hidden_from_nav:false
      ~meets_main_gate:false
      ~rationale:"Live episodes, user model projection, Hebbian synapses, and gated memory entries."
      ~route_hash:"#lab?section=memory-subsystems"
      ~live_spotcheck:"/api/v1/dashboard/memory-subsystems"
      ~tool_name:"masc_surface_audit"
      ()
  ; entry
      ~id:"lab.keeper-memory-health"
      ~label:"키퍼 메모리 상태"
      ~exposure_status:"lab"
      ~hidden_from_nav:false
      ~meets_main_gate:false
      ~rationale:"Per-keeper fact-store size, GC statistics, and cadence counter."
      ~route_hash:"#lab?section=keeper-memory-health"
      ~live_spotcheck:"/api/v1/dashboard/keeper-memory-health"
      ~tool_name:"masc_surface_audit"
      ()
  ; entry
      ~id:"code.ide-shell"
      ~label:"Code IDE"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Keeper collaboration IDE shell."
      ~route_hash:"#code?section=ide-shell"
      ~live_spotcheck:"/api/v1/ide/presence"
      ()
  ; entry
      ~id:"settings"
      ~label:"Settings"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Operator console for keeper-v2 configuration."
      ~route_hash:"#settings"
      ~live_spotcheck:"/api/v1/dashboard/settings"
      ~tool_name:"masc_surface_audit"
      ()
  ; entry
      ~id:"logs"
      ~label:"Logs"
      ~exposure_status:"main"
      ~hidden_from_nav:false
      ~meets_main_gate:true
      ~rationale:"Primary operational log inspection surface."
      ~route_hash:"#logs"
      ~live_spotcheck:"/api/v1/dashboard/logs"
      ()
  ]

let find_entry surface_id =
  List.find_opt (fun (entry : surface_entry) -> String.equal entry.id surface_id) all_entries

let verification_ref_coverage_count selector entries =
  List.fold_left (fun count entry -> if selector entry.refs then count + 1 else count) 0 entries

let verification_ref_bar_for_entries entries =
  let total = List.length entries in
  if total = 0
  then "surfaces:0"
  else
    let live =
      verification_ref_coverage_count (fun refs -> nonempty refs.live_spotcheck) entries
    in
    let logs =
      verification_ref_coverage_count (fun refs -> nonempty refs.logs_ref) entries
    in
    Printf.sprintf "live:%d/%d logs:%d/%d" live total logs total

let json ?surface_id () =
  let surfaces =
    match surface_id with
    | Some value -> (
        match find_entry value with Some entry -> [ entry ] | None -> [])
    | None -> all_entries
  in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("verification_ref_bar", `String (verification_ref_bar_for_entries surfaces));
      ("surfaces", `List (List.map entry_json surfaces));
    ]
