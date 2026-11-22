type workspace =
  | Pulse
  | Work
  | Knowledge
  | Keepers
  | Runtime
  | Infra

type work_tab =
  | Work_pipeline
  | Work_tasks_schedules
  | Work_inbox
  | Work_candle_scorecard

type knowledge_tab =
  | Knowledge_board
  | Knowledge_wiki_artifacts
  | Knowledge_memory

type keepers_fleet_mode =
  | Fleet_companies
  | Fleet_attention
  | Fleet_pulse_wall

type runtime_tab =
  | Runtime_quotas_credits
  | Runtime_efficiency_spend
  | Runtime_failover_lanes
  | Runtime_tools_connectors

type infra_tab =
  | Infra_sandboxes
  | Infra_repos_changes
  | Infra_activity_logs

type keeper_tab =
  | Keeper_chat
  | Keeper_memory
  | Keeper_work_candle
  | Keeper_sandbox
  | Keeper_config

type work_dive_target =
  | Goal_dive of string
  | Task_dive of string
  | Verification_dive of string

type knowledge_dive_target =
  | Thread_dive of string
  | Wiki_dive of string
  | Artifact_dive of string
  | Memory_diff_dive of { keeper : string option; from_rev : int; to_rev : int }

type infra_dive_target =
  | Sandbox_dive of string
  | Lane_dive of string
  | Incident_dive of int

type dive =
  | Dive_keeper of { name : string; tab : keeper_tab }
  | Dive_work of work_dive_target
  | Dive_knowledge of knowledge_dive_target
  | Dive_infra of infra_dive_target

type settings_tab =
  | Settings_general_ui
  | Settings_providers_models
  | Settings_routing_failover
  | Settings_keepers_companies
  | Settings_sandbox_ssh
  | Settings_voice_integrations
  | Settings_board_memory_candle

type queue_context_tab =
  | Drawer_queue
  | Drawer_context
  | Drawer_schedules

type inline_action_kind =
  | Btw_query
  | Gate_reject of string
  | Verification_reject of string
  | Harness_overrule of string
  | Task_cancel of string
  | Schedule_form
  | Connector_form
  | Repo_add_form
  | Board_new_post

type system_gate_kind =
  | Micro_viewport
  | Auth_gate
  | Server_offline
  | Media_viewer

type overlay =
  | Palette
  | Settings of settings_tab
  | Incidents
  | Queue_context of queue_context_tab
  | Inline_action of inline_action_kind
  | Help
  | System_gate of system_gate_kind

type focus_scope =
  | Global
  | Workspace_focused of workspace
  | Dive_focused of dive
  | Composer_focused
  | Ask_choice_focused
  | Approval_strip_focused
  | Overlay_focused of overlay

let all_workspaces = [ Pulse; Work; Knowledge; Keepers; Runtime; Infra ]

let workspace_index = function
  | Pulse -> 1
  | Work -> 2
  | Knowledge -> 3
  | Keepers -> 4
  | Runtime -> 5
  | Infra -> 6

let workspace_of_index = function
  | 1 -> Some Pulse
  | 2 -> Some Work
  | 3 -> Some Knowledge
  | 4 -> Some Keepers
  | 5 -> Some Runtime
  | 6 -> Some Infra
  | _ -> None

let workspace_label = function
  | Pulse -> Say.make ~ko:"펄스" ~en:"Pulse"
  | Work -> Say.make ~ko:"작업" ~en:"Work"
  | Knowledge -> Say.make ~ko:"지식" ~en:"Knowledge"
  | Keepers -> Say.make ~ko:"키퍼" ~en:"Keepers"
  | Runtime -> Say.make ~ko:"런타임" ~en:"Runtime"
  | Infra -> Say.make ~ko:"인프라" ~en:"Infra"

let all_work_tabs =
  [ Work_pipeline; Work_tasks_schedules; Work_inbox; Work_candle_scorecard ]

let work_tab_label = function
  | Work_pipeline -> Say.make ~ko:"파이프라인" ~en:"Pipeline"
  | Work_tasks_schedules -> Say.make ~ko:"작업 · 일정" ~en:"Tasks & Schedules"
  | Work_inbox -> Say.make ~ko:"수신함" ~en:"Inbox"
  | Work_candle_scorecard -> Say.make ~ko:"캔들 · 성과" ~en:"Candle & Scorecard"

let next_work_tab = function
  | Work_pipeline -> Work_tasks_schedules
  | Work_tasks_schedules -> Work_inbox
  | Work_inbox -> Work_candle_scorecard
  | Work_candle_scorecard -> Work_pipeline

let prev_work_tab = function
  | Work_pipeline -> Work_candle_scorecard
  | Work_tasks_schedules -> Work_pipeline
  | Work_inbox -> Work_tasks_schedules
  | Work_candle_scorecard -> Work_inbox

let all_knowledge_tabs =
  [ Knowledge_board; Knowledge_wiki_artifacts; Knowledge_memory ]

let knowledge_tab_label = function
  | Knowledge_board -> Say.make ~ko:"보드" ~en:"Board"
  | Knowledge_wiki_artifacts -> Say.make ~ko:"위키 · 산출물" ~en:"Wiki & Artifacts"
  | Knowledge_memory -> Say.make ~ko:"기억" ~en:"Memory"

let next_knowledge_tab = function
  | Knowledge_board -> Knowledge_wiki_artifacts
  | Knowledge_wiki_artifacts -> Knowledge_memory
  | Knowledge_memory -> Knowledge_board

let prev_knowledge_tab = function
  | Knowledge_board -> Knowledge_memory
  | Knowledge_wiki_artifacts -> Knowledge_board
  | Knowledge_memory -> Knowledge_wiki_artifacts

let all_keepers_fleet_modes =
  [ Fleet_companies; Fleet_attention; Fleet_pulse_wall ]

let keepers_fleet_mode_label = function
  | Fleet_companies -> Say.make ~ko:"회사별" ~en:"Companies"
  | Fleet_attention -> Say.make ~ko:"확인 우선" ~en:"Attention"
  | Fleet_pulse_wall -> Say.make ~ko:"24h 펄스" ~en:"24h Wall"

let next_keepers_fleet_mode = function
  | Fleet_companies -> Fleet_attention
  | Fleet_attention -> Fleet_pulse_wall
  | Fleet_pulse_wall -> Fleet_companies

let all_runtime_tabs =
  [
    Runtime_quotas_credits;
    Runtime_efficiency_spend;
    Runtime_failover_lanes;
    Runtime_tools_connectors;
  ]

let runtime_tab_label = function
  | Runtime_quotas_credits -> Say.make ~ko:"할당 · 크레딧" ~en:"Quotas & Credits"
  | Runtime_efficiency_spend -> Say.make ~ko:"효율 · 지출" ~en:"Efficiency & Spend"
  | Runtime_failover_lanes -> Say.make ~ko:"페일오버 레인" ~en:"Failover Lanes"
  | Runtime_tools_connectors -> Say.make ~ko:"도구 · 커넥터" ~en:"Tools & Connectors"

let next_runtime_tab = function
  | Runtime_quotas_credits -> Runtime_efficiency_spend
  | Runtime_efficiency_spend -> Runtime_failover_lanes
  | Runtime_failover_lanes -> Runtime_tools_connectors
  | Runtime_tools_connectors -> Runtime_quotas_credits

let prev_runtime_tab = function
  | Runtime_quotas_credits -> Runtime_tools_connectors
  | Runtime_efficiency_spend -> Runtime_quotas_credits
  | Runtime_failover_lanes -> Runtime_efficiency_spend
  | Runtime_tools_connectors -> Runtime_failover_lanes

let all_infra_tabs =
  [ Infra_sandboxes; Infra_repos_changes; Infra_activity_logs ]

let infra_tab_label = function
  | Infra_sandboxes -> Say.make ~ko:"샌드박스" ~en:"Sandboxes"
  | Infra_repos_changes -> Say.make ~ko:"저장소 · 변경" ~en:"Repos & Changes"
  | Infra_activity_logs -> Say.make ~ko:"활동 · 로그" ~en:"Activity & Logs"

let next_infra_tab = function
  | Infra_sandboxes -> Infra_repos_changes
  | Infra_repos_changes -> Infra_activity_logs
  | Infra_activity_logs -> Infra_sandboxes

let prev_infra_tab = function
  | Infra_sandboxes -> Infra_activity_logs
  | Infra_repos_changes -> Infra_sandboxes
  | Infra_activity_logs -> Infra_repos_changes

let all_keeper_tabs =
  [ Keeper_chat; Keeper_memory; Keeper_work_candle; Keeper_sandbox; Keeper_config ]

let keeper_tab_label = function
  | Keeper_chat -> Say.make ~ko:"대화 · 스트림" ~en:"Chat & Stream"
  | Keeper_memory -> Say.make ~ko:"기억" ~en:"Memory"
  | Keeper_work_candle -> Say.make ~ko:"작업 · 캔들" ~en:"Work & Candle"
  | Keeper_sandbox -> Say.make ~ko:"샌드박스" ~en:"Sandbox"
  | Keeper_config -> Say.make ~ko:"설정" ~en:"Config"

let next_keeper_tab = function
  | Keeper_chat -> Keeper_memory
  | Keeper_memory -> Keeper_work_candle
  | Keeper_work_candle -> Keeper_sandbox
  | Keeper_sandbox -> Keeper_config
  | Keeper_config -> Keeper_chat

let prev_keeper_tab = function
  | Keeper_chat -> Keeper_config
  | Keeper_memory -> Keeper_chat
  | Keeper_work_candle -> Keeper_memory
  | Keeper_sandbox -> Keeper_work_candle
  | Keeper_config -> Keeper_sandbox

let all_settings_tabs =
  [
    Settings_general_ui;
    Settings_providers_models;
    Settings_routing_failover;
    Settings_keepers_companies;
    Settings_sandbox_ssh;
    Settings_voice_integrations;
    Settings_board_memory_candle;
  ]

let settings_tab_label = function
  | Settings_general_ui -> Say.make ~ko:"일반 · UI" ~en:"General & UI"
  | Settings_providers_models -> Say.make ~ko:"프로바이더 · 모델" ~en:"Providers & Models"
  | Settings_routing_failover -> Say.make ~ko:"라우팅 · 페일오버" ~en:"Routing & Failover"
  | Settings_keepers_companies -> Say.make ~ko:"키퍼 · 회사" ~en:"Keepers & Companies"
  | Settings_sandbox_ssh -> Say.make ~ko:"샌드박스 · SSH" ~en:"Sandbox & SSH"
  | Settings_voice_integrations -> Say.make ~ko:"음성 · 연동" ~en:"Voice & Integrations"
  | Settings_board_memory_candle -> Say.make ~ko:"보드 · 기억 · 캔들" ~en:"Board, Memory & Candle"

let next_settings_tab = function
  | Settings_general_ui -> Settings_providers_models
  | Settings_providers_models -> Settings_routing_failover
  | Settings_routing_failover -> Settings_keepers_companies
  | Settings_keepers_companies -> Settings_sandbox_ssh
  | Settings_sandbox_ssh -> Settings_voice_integrations
  | Settings_voice_integrations -> Settings_board_memory_candle
  | Settings_board_memory_candle -> Settings_general_ui

let prev_settings_tab = function
  | Settings_general_ui -> Settings_board_memory_candle
  | Settings_providers_models -> Settings_general_ui
  | Settings_routing_failover -> Settings_providers_models
  | Settings_keepers_companies -> Settings_routing_failover
  | Settings_sandbox_ssh -> Settings_keepers_companies
  | Settings_voice_integrations -> Settings_sandbox_ssh
  | Settings_board_memory_candle -> Settings_voice_integrations

let all_queue_context_tabs = [ Drawer_queue; Drawer_context; Drawer_schedules ]

let queue_context_tab_label = function
  | Drawer_queue -> Say.make ~ko:"대기열" ~en:"Queue"
  | Drawer_context -> Say.make ~ko:"컨텍스트" ~en:"Context"
  | Drawer_schedules -> Say.make ~ko:"일정" ~en:"Schedules"

let next_queue_context_tab = function
  | Drawer_queue -> Drawer_context
  | Drawer_context -> Drawer_schedules
  | Drawer_schedules -> Drawer_queue

let prev_queue_context_tab = function
  | Drawer_queue -> Drawer_schedules
  | Drawer_context -> Drawer_queue
  | Drawer_schedules -> Drawer_context

let equal_workspace a b =
  Int.equal (workspace_index a) (workspace_index b)

let work_tab_index = function
  | Work_pipeline -> 0
  | Work_tasks_schedules -> 1
  | Work_inbox -> 2
  | Work_candle_scorecard -> 3

let equal_work_tab a b = Int.equal (work_tab_index a) (work_tab_index b)

let knowledge_tab_index = function
  | Knowledge_board -> 0
  | Knowledge_wiki_artifacts -> 1
  | Knowledge_memory -> 2

let equal_knowledge_tab a b =
  Int.equal (knowledge_tab_index a) (knowledge_tab_index b)

let keepers_fleet_mode_index = function
  | Fleet_companies -> 0
  | Fleet_attention -> 1
  | Fleet_pulse_wall -> 2

let equal_keepers_fleet_mode a b =
  Int.equal (keepers_fleet_mode_index a) (keepers_fleet_mode_index b)

let runtime_tab_index = function
  | Runtime_quotas_credits -> 0
  | Runtime_efficiency_spend -> 1
  | Runtime_failover_lanes -> 2
  | Runtime_tools_connectors -> 3

let equal_runtime_tab a b =
  Int.equal (runtime_tab_index a) (runtime_tab_index b)

let infra_tab_index = function
  | Infra_sandboxes -> 0
  | Infra_repos_changes -> 1
  | Infra_activity_logs -> 2

let equal_infra_tab a b = Int.equal (infra_tab_index a) (infra_tab_index b)

let keeper_tab_index = function
  | Keeper_chat -> 0
  | Keeper_memory -> 1
  | Keeper_work_candle -> 2
  | Keeper_sandbox -> 3
  | Keeper_config -> 4

let equal_keeper_tab a b = Int.equal (keeper_tab_index a) (keeper_tab_index b)

let equal_work_dive_target a b =
  match a, b with
  | Goal_dive x, Goal_dive y
  | Task_dive x, Task_dive y
  | Verification_dive x, Verification_dive y ->
      String.equal x y
  | Goal_dive _, (Task_dive _ | Verification_dive _)
  | Task_dive _, (Goal_dive _ | Verification_dive _)
  | Verification_dive _, (Goal_dive _ | Task_dive _) ->
      false

let equal_knowledge_dive_target a b =
  match a, b with
  | Thread_dive x, Thread_dive y
  | Wiki_dive x, Wiki_dive y
  | Artifact_dive x, Artifact_dive y ->
      String.equal x y
  | Memory_diff_dive x, Memory_diff_dive y ->
      Option.equal String.equal x.keeper y.keeper
      && Int.equal x.from_rev y.from_rev
      && Int.equal x.to_rev y.to_rev
  | Thread_dive _, (Wiki_dive _ | Artifact_dive _ | Memory_diff_dive _)
  | Wiki_dive _, (Thread_dive _ | Artifact_dive _ | Memory_diff_dive _)
  | Artifact_dive _, (Thread_dive _ | Wiki_dive _ | Memory_diff_dive _)
  | Memory_diff_dive _, (Thread_dive _ | Wiki_dive _ | Artifact_dive _) ->
      false

let equal_infra_dive_target a b =
  match a, b with
  | Sandbox_dive x, Sandbox_dive y | Lane_dive x, Lane_dive y ->
      String.equal x y
  | Incident_dive x, Incident_dive y -> Int.equal x y
  | Sandbox_dive _, (Lane_dive _ | Incident_dive _)
  | Lane_dive _, (Sandbox_dive _ | Incident_dive _)
  | Incident_dive _, (Sandbox_dive _ | Lane_dive _) ->
      false

let equal_dive a b =
  match a, b with
  | Dive_keeper x, Dive_keeper y ->
      String.equal x.name y.name && equal_keeper_tab x.tab y.tab
  | Dive_work x, Dive_work y -> equal_work_dive_target x y
  | Dive_knowledge x, Dive_knowledge y -> equal_knowledge_dive_target x y
  | Dive_infra x, Dive_infra y -> equal_infra_dive_target x y
  | Dive_keeper _, (Dive_work _ | Dive_knowledge _ | Dive_infra _)
  | Dive_work _, (Dive_keeper _ | Dive_knowledge _ | Dive_infra _)
  | Dive_knowledge _, (Dive_keeper _ | Dive_work _ | Dive_infra _)
  | Dive_infra _, (Dive_keeper _ | Dive_work _ | Dive_knowledge _) ->
      false

let settings_tab_index = function
  | Settings_general_ui -> 0
  | Settings_providers_models -> 1
  | Settings_routing_failover -> 2
  | Settings_keepers_companies -> 3
  | Settings_sandbox_ssh -> 4
  | Settings_voice_integrations -> 5
  | Settings_board_memory_candle -> 6

let equal_settings_tab a b =
  Int.equal (settings_tab_index a) (settings_tab_index b)

let queue_context_tab_index = function
  | Drawer_queue -> 0
  | Drawer_context -> 1
  | Drawer_schedules -> 2

let equal_queue_context_tab a b =
  Int.equal (queue_context_tab_index a) (queue_context_tab_index b)

let equal_inline_action_kind a b =
  match a, b with
  | Btw_query, Btw_query
  | Schedule_form, Schedule_form
  | Connector_form, Connector_form
  | Repo_add_form, Repo_add_form
  | Board_new_post, Board_new_post ->
      true
  | Gate_reject x, Gate_reject y
  | Verification_reject x, Verification_reject y
  | Harness_overrule x, Harness_overrule y
  | Task_cancel x, Task_cancel y ->
      String.equal x y
  | Btw_query, (Gate_reject _ | Verification_reject _ | Harness_overrule _ | Task_cancel _ | Schedule_form | Connector_form | Repo_add_form | Board_new_post)
  | Gate_reject _, (Btw_query | Verification_reject _ | Harness_overrule _ | Task_cancel _ | Schedule_form | Connector_form | Repo_add_form | Board_new_post)
  | Verification_reject _, (Btw_query | Gate_reject _ | Harness_overrule _ | Task_cancel _ | Schedule_form | Connector_form | Repo_add_form | Board_new_post)
  | Harness_overrule _, (Btw_query | Gate_reject _ | Verification_reject _ | Task_cancel _ | Schedule_form | Connector_form | Repo_add_form | Board_new_post)
  | Task_cancel _, (Btw_query | Gate_reject _ | Verification_reject _ | Harness_overrule _ | Schedule_form | Connector_form | Repo_add_form | Board_new_post)
  | Schedule_form, (Btw_query | Gate_reject _ | Verification_reject _ | Harness_overrule _ | Task_cancel _ | Connector_form | Repo_add_form | Board_new_post)
  | Connector_form, (Btw_query | Gate_reject _ | Verification_reject _ | Harness_overrule _ | Task_cancel _ | Schedule_form | Repo_add_form | Board_new_post)
  | Repo_add_form, (Btw_query | Gate_reject _ | Verification_reject _ | Harness_overrule _ | Task_cancel _ | Schedule_form | Connector_form | Board_new_post)
  | Board_new_post, (Btw_query | Gate_reject _ | Verification_reject _ | Harness_overrule _ | Task_cancel _ | Schedule_form | Connector_form | Repo_add_form) ->
      false

let system_gate_index = function
  | Micro_viewport -> 0
  | Auth_gate -> 1
  | Server_offline -> 2
  | Media_viewer -> 3

let equal_system_gate_kind a b =
  Int.equal (system_gate_index a) (system_gate_index b)

let equal_overlay a b =
  match a, b with
  | Palette, Palette | Incidents, Incidents | Help, Help -> true
  | Settings x, Settings y -> equal_settings_tab x y
  | Queue_context x, Queue_context y -> equal_queue_context_tab x y
  | Inline_action x, Inline_action y -> equal_inline_action_kind x y
  | System_gate x, System_gate y -> equal_system_gate_kind x y
  | Palette, (Settings _ | Incidents | Queue_context _ | Inline_action _ | Help | System_gate _)
  | Settings _, (Palette | Incidents | Queue_context _ | Inline_action _ | Help | System_gate _)
  | Incidents, (Palette | Settings _ | Queue_context _ | Inline_action _ | Help | System_gate _)
  | Queue_context _, (Palette | Settings _ | Incidents | Inline_action _ | Help | System_gate _)
  | Inline_action _, (Palette | Settings _ | Incidents | Queue_context _ | Help | System_gate _)
  | Help, (Palette | Settings _ | Incidents | Queue_context _ | Inline_action _ | System_gate _)
  | System_gate _, (Palette | Settings _ | Incidents | Queue_context _ | Inline_action _ | Help) ->
      false

let equal_focus_scope a b =
  match a, b with
  | Global, Global
  | Composer_focused, Composer_focused
  | Ask_choice_focused, Ask_choice_focused
  | Approval_strip_focused, Approval_strip_focused ->
      true
  | Workspace_focused x, Workspace_focused y -> equal_workspace x y
  | Dive_focused x, Dive_focused y -> equal_dive x y
  | Overlay_focused x, Overlay_focused y -> equal_overlay x y
  | Global, (Workspace_focused _ | Dive_focused _ | Composer_focused | Ask_choice_focused | Approval_strip_focused | Overlay_focused _)
  | Workspace_focused _, (Global | Dive_focused _ | Composer_focused | Ask_choice_focused | Approval_strip_focused | Overlay_focused _)
  | Dive_focused _, (Global | Workspace_focused _ | Composer_focused | Ask_choice_focused | Approval_strip_focused | Overlay_focused _)
  | Composer_focused, (Global | Workspace_focused _ | Dive_focused _ | Ask_choice_focused | Approval_strip_focused | Overlay_focused _)
  | Ask_choice_focused, (Global | Workspace_focused _ | Dive_focused _ | Composer_focused | Approval_strip_focused | Overlay_focused _)
  | Approval_strip_focused, (Global | Workspace_focused _ | Dive_focused _ | Composer_focused | Ask_choice_focused | Overlay_focused _)
  | Overlay_focused _, (Global | Workspace_focused _ | Dive_focused _ | Composer_focused | Ask_choice_focused | Approval_strip_focused) ->
      false
