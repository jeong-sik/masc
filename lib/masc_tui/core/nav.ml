type workspace =
  | Pulse
  | Work
  | Knowledge
  | Keepers
  | Runtime
  | Infra

type work_tab =
  | Work_pipeline
  | Work_tasks
  | Work_schedules
  | Work_inbox
  | Work_candle_scorecard
  | Work_harness

type knowledge_tab =
  | Knowledge_board
  | Knowledge_wiki
  | Knowledge_artifacts
  | Knowledge_memory

type keepers_fleet_mode =
  | Fleet_companies
  | Fleet_attention
  | Fleet_pulse_wall

type runtime_tab =
  | Runtime_quotas_credits
  | Runtime_efficiency_spend
  | Runtime_failover_lanes
  | Runtime_fusion
  | Runtime_tools_usage
  | Runtime_connectors
  | Runtime_addons_browser

type infra_tab =
  | Infra_sandboxes
  | Infra_repos_changes
  | Infra_code
  | Infra_activity_logs

type keeper_tab =
  | Keeper_chat
  | Keeper_context
  | Keeper_tool_calls
  | Keeper_memory
  | Keeper_work_candle
  | Keeper_sandbox
  | Keeper_config
  | Keeper_logs
  | Keeper_identity

type work_dive_target =
  | Goal_dive of string
  | Task_dive of string
  | Verification_dive of string

type knowledge_dive_target =
  | Thread_dive of string
  | Wiki_dive of string
  | Artifact_dive of string
  | Memory_diff_dive of { keeper : string option; from_rev : int; to_rev : int }

type runtime_dive_target =
  | Tool_dive of string
  | Fusion_dive of string
  | Skill_dive of string
  | Exact_run_dive of string

type infra_dive_target =
  | Sandbox_dive of string
  | Lane_dive of string
  | Incident_dive of int
  | Runtime_trace_dive of string
  | Log_detail_dive of int

type dive =
  | Dive_keeper of { name : string; tab : keeper_tab }
  | Dive_work of work_dive_target
  | Dive_knowledge of knowledge_dive_target
  | Dive_runtime of runtime_dive_target
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

type keeper_destructive_action =
  | Keeper_act_shutdown
  | Keeper_act_reset
  | Keeper_act_apply_purge
  | Keeper_act_delete_history

type inline_action_kind =
  | Btw_query
  | Gate_reject of string
  | Verification_reject of string
  | Harness_overrule of string
  | Task_cancel of string
  | Goal_drop of string
  | Schedule_form
  | Connector_form
  | Repo_add_form
  | Board_new_post
  | Board_comment of { post_id : string; parent_id : string option }
  | Github_token_form of string
  | Code_finder_form
  | Code_search_form
  | Runtime_lane_create
  | Runtime_lane_edit of {
      lane_id : string;
      exact_output : bool;
      opened_revision : string option;
    }
  | Runtime_lane_delete of {
      lane_id : string;
      opened_revision : string option;
    }
  | Task_create_form
  | Task_transition_form of { task_id : string }
  | Task_link_goal of { task_id : string }
  | Goal_upsert_form of string option
  | Board_delete_post of {
      post_id : string;
      title : string;
    }
  | Keeper_lifecycle_form of { keeper : string }
  | Keeper_purge_confirm of { keeper : string }
  | Addon_attach_form
  | Addon_detach_confirm of {
      instance_id : string;
      title : string;
    }
  | Addon_invoke_action of {
      instance_id : string;
      action_names : string list;
    }
  | Setup_login_input_form of { login_id : string }
  | Keeper_control_confirm of {
      keeper : string;
      action : keeper_destructive_action;
    }
  | Keeper_clear_form of string
  | Keeper_operator_note_form of string
  | Tool_execute_form of { tool_name : string option; args_json : string }
  | Skill_create_form
  | Skill_edit_form of { reference : string }
  | Skill_delete_confirm of { reference : string }
  | Prompt_override_form of { key : string }
  | Preset_create_form
  | Runtime_param_set_form of { param_key : string }
  | Default_route_edit
  | Lane_rename_form of { lane : string }
  | Addon_decl_form of {
      file_name : string;
      mode : [ `Create | `Save ];
      expected_source_revision : string option;
    }
  | Addon_act_form of {
      instance_id : string;
      expected_incarnation : string;
    }
  | Browser_interact_form of {
      client_id : string;
      tab_id : int;
      expected_url : string option;
    }

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
  | Ask_answer
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
  [
    Work_pipeline;
    Work_tasks;
    Work_schedules;
    Work_inbox;
    Work_candle_scorecard;
    Work_harness;
  ]

let work_tab_label = function
  | Work_pipeline -> Say.make ~ko:"목표" ~en:"Goals"
  | Work_tasks -> Say.make ~ko:"작업" ~en:"Tasks"
  | Work_schedules -> Say.make ~ko:"일정" ~en:"Schedules"
  | Work_inbox -> Say.make ~ko:"수신함" ~en:"Inbox"
  | Work_candle_scorecard -> Say.make ~ko:"캔들 · 성과" ~en:"Candle & Scorecard"
  | Work_harness -> Say.make ~ko:"하네스" ~en:"Harness"

let next_work_tab = function
  | Work_pipeline -> Work_tasks
  | Work_tasks -> Work_schedules
  | Work_schedules -> Work_inbox
  | Work_inbox -> Work_candle_scorecard
  | Work_candle_scorecard -> Work_harness
  | Work_harness -> Work_pipeline

let prev_work_tab = function
  | Work_pipeline -> Work_harness
  | Work_tasks -> Work_pipeline
  | Work_schedules -> Work_tasks
  | Work_inbox -> Work_schedules
  | Work_candle_scorecard -> Work_inbox
  | Work_harness -> Work_candle_scorecard

let all_knowledge_tabs =
  [ Knowledge_board; Knowledge_wiki; Knowledge_artifacts; Knowledge_memory ]

let knowledge_tab_label = function
  | Knowledge_board -> Say.make ~ko:"보드" ~en:"Board"
  | Knowledge_wiki -> Say.make ~ko:"위키" ~en:"Wiki"
  | Knowledge_artifacts -> Say.make ~ko:"산출물" ~en:"Artifacts"
  | Knowledge_memory -> Say.make ~ko:"기억" ~en:"Memory"

let next_knowledge_tab = function
  | Knowledge_board -> Knowledge_wiki
  | Knowledge_wiki -> Knowledge_artifacts
  | Knowledge_artifacts -> Knowledge_memory
  | Knowledge_memory -> Knowledge_board

let prev_knowledge_tab = function
  | Knowledge_board -> Knowledge_memory
  | Knowledge_wiki -> Knowledge_board
  | Knowledge_artifacts -> Knowledge_wiki
  | Knowledge_memory -> Knowledge_artifacts

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

let prev_keepers_fleet_mode = function
  | Fleet_companies -> Fleet_pulse_wall
  | Fleet_attention -> Fleet_companies
  | Fleet_pulse_wall -> Fleet_attention

let all_runtime_tabs =
  [
    Runtime_quotas_credits;
    Runtime_efficiency_spend;
    Runtime_failover_lanes;
    Runtime_fusion;
    Runtime_tools_usage;
    Runtime_connectors;
    Runtime_addons_browser;
  ]

let runtime_tab_label = function
  | Runtime_quotas_credits -> Say.make ~ko:"할당 · 크레딧" ~en:"Quotas & Credits"
  | Runtime_efficiency_spend -> Say.make ~ko:"효율 · 지출" ~en:"Efficiency & Spend"
  | Runtime_failover_lanes -> Say.make ~ko:"페일오버 레인" ~en:"Failover Lanes"
  | Runtime_fusion -> Say.make ~ko:"퓨전" ~en:"Fusion"
  | Runtime_tools_usage -> Say.make ~ko:"도구 · 사용량" ~en:"Tools & Usage"
  | Runtime_connectors -> Say.make ~ko:"커넥터 · 클라이언트" ~en:"Connectors"
  | Runtime_addons_browser -> Say.make ~ko:"애드온 · 브라우저" ~en:"Addons & Browser"

let next_runtime_tab = function
  | Runtime_quotas_credits -> Runtime_efficiency_spend
  | Runtime_efficiency_spend -> Runtime_failover_lanes
  | Runtime_failover_lanes -> Runtime_fusion
  | Runtime_fusion -> Runtime_tools_usage
  | Runtime_tools_usage -> Runtime_connectors
  | Runtime_connectors -> Runtime_addons_browser
  | Runtime_addons_browser -> Runtime_quotas_credits

let prev_runtime_tab = function
  | Runtime_quotas_credits -> Runtime_addons_browser
  | Runtime_efficiency_spend -> Runtime_quotas_credits
  | Runtime_failover_lanes -> Runtime_efficiency_spend
  | Runtime_fusion -> Runtime_failover_lanes
  | Runtime_tools_usage -> Runtime_fusion
  | Runtime_connectors -> Runtime_tools_usage
  | Runtime_addons_browser -> Runtime_connectors

let all_infra_tabs =
  [ Infra_sandboxes; Infra_repos_changes; Infra_code; Infra_activity_logs ]

let infra_tab_label = function
  | Infra_sandboxes -> Say.make ~ko:"샌드박스" ~en:"Sandboxes"
  | Infra_repos_changes -> Say.make ~ko:"저장소 · 변경" ~en:"Repos & Changes"
  | Infra_code -> Say.make ~ko:"코드" ~en:"Code"
  | Infra_activity_logs -> Say.make ~ko:"활동 · 로그" ~en:"Activity & Logs"

let next_infra_tab = function
  | Infra_sandboxes -> Infra_repos_changes
  | Infra_repos_changes -> Infra_code
  | Infra_code -> Infra_activity_logs
  | Infra_activity_logs -> Infra_sandboxes

let prev_infra_tab = function
  | Infra_sandboxes -> Infra_activity_logs
  | Infra_repos_changes -> Infra_sandboxes
  | Infra_code -> Infra_repos_changes
  | Infra_activity_logs -> Infra_code

let all_keeper_tabs =
  [
    Keeper_chat;
    Keeper_context;
    Keeper_tool_calls;
    Keeper_memory;
    Keeper_work_candle;
    Keeper_sandbox;
    Keeper_config;
    Keeper_logs;
    Keeper_identity;
  ]

let keeper_tab_label = function
  | Keeper_chat -> Say.make ~ko:"대화 · 스트림" ~en:"Chat"
  | Keeper_context -> Say.make ~ko:"컨텍스트 · 턴" ~en:"Context & Turns"
  | Keeper_tool_calls -> Say.make ~ko:"도구 호출" ~en:"Tool Calls"
  | Keeper_memory -> Say.make ~ko:"기억" ~en:"Memory"
  | Keeper_work_candle -> Say.make ~ko:"작업 · 캔들" ~en:"Work & Candle"
  | Keeper_sandbox -> Say.make ~ko:"샌드박스" ~en:"Sandbox"
  | Keeper_config -> Say.make ~ko:"설정" ~en:"Config"
  | Keeper_logs -> Say.make ~ko:"로그 · 지표" ~en:"Logs & Metrics"
  | Keeper_identity -> Say.make ~ko:"아이덴티티" ~en:"Identity"

let next_keeper_tab = function
  | Keeper_chat -> Keeper_context
  | Keeper_context -> Keeper_tool_calls
  | Keeper_tool_calls -> Keeper_memory
  | Keeper_memory -> Keeper_work_candle
  | Keeper_work_candle -> Keeper_sandbox
  | Keeper_sandbox -> Keeper_config
  | Keeper_config -> Keeper_logs
  | Keeper_logs -> Keeper_identity
  | Keeper_identity -> Keeper_chat

let prev_keeper_tab = function
  | Keeper_chat -> Keeper_identity
  | Keeper_context -> Keeper_chat
  | Keeper_tool_calls -> Keeper_context
  | Keeper_memory -> Keeper_tool_calls
  | Keeper_work_candle -> Keeper_memory
  | Keeper_sandbox -> Keeper_work_candle
  | Keeper_config -> Keeper_sandbox
  | Keeper_logs -> Keeper_config
  | Keeper_identity -> Keeper_logs

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
  | Work_tasks -> 1
  | Work_schedules -> 2
  | Work_inbox -> 3
  | Work_candle_scorecard -> 4
  | Work_harness -> 5

let equal_work_tab a b = Int.equal (work_tab_index a) (work_tab_index b)

let knowledge_tab_index = function
  | Knowledge_board -> 0
  | Knowledge_wiki -> 1
  | Knowledge_artifacts -> 2
  | Knowledge_memory -> 3

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
  | Runtime_fusion -> 3
  | Runtime_tools_usage -> 4
  | Runtime_connectors -> 5
  | Runtime_addons_browser -> 6

let equal_runtime_tab a b =
  Int.equal (runtime_tab_index a) (runtime_tab_index b)

let infra_tab_index = function
  | Infra_sandboxes -> 0
  | Infra_repos_changes -> 1
  | Infra_code -> 2
  | Infra_activity_logs -> 3

let equal_infra_tab a b = Int.equal (infra_tab_index a) (infra_tab_index b)

let keeper_tab_index = function
  | Keeper_chat -> 0
  | Keeper_context -> 1
  | Keeper_tool_calls -> 2
  | Keeper_memory -> 3
  | Keeper_work_candle -> 4
  | Keeper_sandbox -> 5
  | Keeper_config -> 6
  | Keeper_logs -> 7
  | Keeper_identity -> 8

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

let equal_runtime_dive_target a b =
  match a, b with
  | Tool_dive x, Tool_dive y
  | Fusion_dive x, Fusion_dive y
  | Skill_dive x, Skill_dive y
  | Exact_run_dive x, Exact_run_dive y ->
      String.equal x y
  | Tool_dive _, (Fusion_dive _ | Skill_dive _ | Exact_run_dive _)
  | Fusion_dive _, (Tool_dive _ | Skill_dive _ | Exact_run_dive _)
  | Skill_dive _, (Tool_dive _ | Fusion_dive _ | Exact_run_dive _)
  | Exact_run_dive _, (Tool_dive _ | Fusion_dive _ | Skill_dive _) ->
      false

let equal_infra_dive_target a b =
  match a, b with
  | Sandbox_dive x, Sandbox_dive y
  | Lane_dive x, Lane_dive y
  | Runtime_trace_dive x, Runtime_trace_dive y ->
      String.equal x y
  | Incident_dive x, Incident_dive y | Log_detail_dive x, Log_detail_dive y ->
      Int.equal x y
  | Sandbox_dive _, (Lane_dive _ | Incident_dive _ | Runtime_trace_dive _ | Log_detail_dive _)
  | Lane_dive _, (Sandbox_dive _ | Incident_dive _ | Runtime_trace_dive _ | Log_detail_dive _)
  | Incident_dive _, (Sandbox_dive _ | Lane_dive _ | Runtime_trace_dive _ | Log_detail_dive _)
  | Runtime_trace_dive _, (Sandbox_dive _ | Lane_dive _ | Incident_dive _ | Log_detail_dive _)
  | Log_detail_dive _, (Sandbox_dive _ | Lane_dive _ | Incident_dive _ | Runtime_trace_dive _) ->
      false

let equal_dive a b =
  match a, b with
  | Dive_keeper x, Dive_keeper y ->
      String.equal x.name y.name && equal_keeper_tab x.tab y.tab
  | Dive_work x, Dive_work y -> equal_work_dive_target x y
  | Dive_knowledge x, Dive_knowledge y -> equal_knowledge_dive_target x y
  | Dive_runtime x, Dive_runtime y -> equal_runtime_dive_target x y
  | Dive_infra x, Dive_infra y -> equal_infra_dive_target x y
  | Dive_keeper _, (Dive_work _ | Dive_knowledge _ | Dive_runtime _ | Dive_infra _)
  | Dive_work _, (Dive_keeper _ | Dive_knowledge _ | Dive_runtime _ | Dive_infra _)
  | Dive_knowledge _, (Dive_keeper _ | Dive_work _ | Dive_runtime _ | Dive_infra _)
  | Dive_runtime _, (Dive_keeper _ | Dive_work _ | Dive_knowledge _ | Dive_infra _)
  | Dive_infra _, (Dive_keeper _ | Dive_work _ | Dive_knowledge _ | Dive_runtime _) ->
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

let keeper_destructive_action_index = function
  | Keeper_act_shutdown -> 0
  | Keeper_act_reset -> 1
  | Keeper_act_apply_purge -> 2
  | Keeper_act_delete_history -> 3

let equal_keeper_destructive_action a b =
  Int.equal (keeper_destructive_action_index a)
    (keeper_destructive_action_index b)

let inline_action_tag = function
  | Btw_query -> 0
  | Gate_reject _ -> 1
  | Verification_reject _ -> 2
  | Harness_overrule _ -> 3
  | Task_cancel _ -> 4
  | Goal_drop _ -> 5
  | Schedule_form -> 6
  | Connector_form -> 7
  | Repo_add_form -> 8
  | Board_new_post -> 9
  | Board_comment _ -> 10
  | Github_token_form _ -> 11
  | Code_finder_form -> 12
  | Code_search_form -> 13
  | Runtime_lane_create -> 14
  | Runtime_lane_edit _ -> 15
  | Runtime_lane_delete _ -> 16
  | Task_create_form -> 17
  | Task_transition_form _ -> 18
  | Task_link_goal _ -> 19
  | Goal_upsert_form _ -> 20
  | Board_delete_post _ -> 21
  | Keeper_lifecycle_form _ -> 22
  | Keeper_purge_confirm _ -> 23
  | Addon_attach_form -> 24
  | Addon_detach_confirm _ -> 25
  | Addon_invoke_action _ -> 26
  | Setup_login_input_form _ -> 27
  | Keeper_control_confirm _ -> 28
  | Keeper_clear_form _ -> 29
  | Keeper_operator_note_form _ -> 30
  | Tool_execute_form _ -> 31
  | Skill_create_form -> 32
  | Skill_edit_form _ -> 33
  | Skill_delete_confirm _ -> 34
  | Prompt_override_form _ -> 35
  | Preset_create_form -> 36
  | Runtime_param_set_form _ -> 37
  | Default_route_edit -> 38
  | Lane_rename_form _ -> 40
  | Addon_decl_form _ -> 42
  | Addon_act_form _ -> 43
  | Browser_interact_form _ -> 44
let equal_inline_action_kind a b =
  if not (Int.equal (inline_action_tag a) (inline_action_tag b)) then false
  else
    match a, b with
    | Btw_query, Btw_query
    | Schedule_form, Schedule_form
    | Connector_form, Connector_form
    | Repo_add_form, Repo_add_form
    | Board_new_post, Board_new_post
    | Code_finder_form, Code_finder_form
    | Code_search_form, Code_search_form
    | Skill_create_form, Skill_create_form
    | Preset_create_form, Preset_create_form
    | Default_route_edit, Default_route_edit
    | Runtime_lane_create, Runtime_lane_create
    | Task_create_form, Task_create_form
    | Addon_attach_form, Addon_attach_form ->
        true
    | Gate_reject x, Gate_reject y
    | Verification_reject x, Verification_reject y
    | Harness_overrule x, Harness_overrule y
    | Task_cancel x, Task_cancel y
    | Goal_drop x, Goal_drop y
    | Github_token_form x, Github_token_form y
    | Keeper_clear_form x, Keeper_clear_form y
    | Keeper_operator_note_form x, Keeper_operator_note_form y ->
        String.equal x y
    | Keeper_control_confirm x, Keeper_control_confirm y ->
        String.equal x.keeper y.keeper
        && equal_keeper_destructive_action x.action y.action
    | Tool_execute_form x, Tool_execute_form y ->
        Option.equal String.equal x.tool_name y.tool_name
        && String.equal x.args_json y.args_json
    | Skill_edit_form x, Skill_edit_form y ->
        String.equal x.reference y.reference
    | Skill_delete_confirm x, Skill_delete_confirm y ->
        String.equal x.reference y.reference
    | Prompt_override_form x, Prompt_override_form y ->
        String.equal x.key y.key
    | Runtime_param_set_form x, Runtime_param_set_form y ->
        String.equal x.param_key y.param_key
    | Lane_rename_form x, Lane_rename_form y -> String.equal x.lane y.lane
    | Addon_decl_form x, Addon_decl_form y ->
        String.equal x.file_name y.file_name
        && (match (x.mode, y.mode) with
           | `Create, `Create | `Save, `Save -> true
           | `Create, `Save | `Save, `Create -> false)
        && Option.equal String.equal x.expected_source_revision
             y.expected_source_revision
    | Addon_act_form x, Addon_act_form y ->
        String.equal x.instance_id y.instance_id
        && String.equal x.expected_incarnation y.expected_incarnation
    | Browser_interact_form x, Browser_interact_form y ->
        String.equal x.client_id y.client_id
        && Int.equal x.tab_id y.tab_id
        && Option.equal String.equal x.expected_url y.expected_url
    | Board_comment x, Board_comment y ->
        String.equal x.post_id y.post_id
        && Option.equal String.equal x.parent_id y.parent_id
    | Runtime_lane_edit x, Runtime_lane_edit y ->
        String.equal x.lane_id y.lane_id
        && Bool.equal x.exact_output y.exact_output
        && Option.equal String.equal x.opened_revision y.opened_revision
    | Runtime_lane_delete x, Runtime_lane_delete y ->
        String.equal x.lane_id y.lane_id
        && Option.equal String.equal x.opened_revision y.opened_revision
    | Task_transition_form x, Task_transition_form y ->
        String.equal x.task_id y.task_id
    | Task_link_goal x, Task_link_goal y ->
        String.equal x.task_id y.task_id
    | Goal_upsert_form x, Goal_upsert_form y ->
        Option.equal String.equal x y
    | Board_delete_post x, Board_delete_post y ->
        String.equal x.post_id y.post_id && String.equal x.title y.title
    | Keeper_lifecycle_form x, Keeper_lifecycle_form y ->
        String.equal x.keeper y.keeper
    | Keeper_purge_confirm x, Keeper_purge_confirm y ->
        String.equal x.keeper y.keeper
    | Addon_detach_confirm x, Addon_detach_confirm y ->
        String.equal x.instance_id y.instance_id
        && String.equal x.title y.title
    | Addon_invoke_action x, Addon_invoke_action y ->
        String.equal x.instance_id y.instance_id
        && List.equal String.equal x.action_names y.action_names
    | Setup_login_input_form x, Setup_login_input_form y ->
        String.equal x.login_id y.login_id
    | ( Btw_query
      | Gate_reject _
      | Verification_reject _
      | Harness_overrule _
      | Task_cancel _
      | Goal_drop _
      | Schedule_form
      | Connector_form
      | Repo_add_form
      | Board_new_post
      | Board_comment _
      | Github_token_form _
      | Code_finder_form
      | Code_search_form
      | Keeper_control_confirm _
      | Keeper_clear_form _
      | Keeper_operator_note_form _
      | Tool_execute_form _
      | Skill_create_form
      | Skill_edit_form _
      | Skill_delete_confirm _
      | Prompt_override_form _
      | Preset_create_form
      | Runtime_param_set_form _
      | Default_route_edit
      | Lane_rename_form _
      | Addon_decl_form _
      | Addon_act_form _
      | Browser_interact_form _
      | Runtime_lane_create
      | Runtime_lane_edit _
      | Runtime_lane_delete _
      | Task_create_form
      | Task_transition_form _
      | Task_link_goal _
      | Goal_upsert_form _
      | Board_delete_post _
      | Keeper_lifecycle_form _
      | Keeper_purge_confirm _
      | Addon_attach_form
      | Addon_detach_confirm _
      | Addon_invoke_action _
      | Setup_login_input_form _ ), _ ->
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
  | Palette, Palette | Incidents, Incidents | Ask_answer, Ask_answer | Help, Help ->
      true
  | Settings x, Settings y -> equal_settings_tab x y
  | Queue_context x, Queue_context y -> equal_queue_context_tab x y
  | Inline_action x, Inline_action y -> equal_inline_action_kind x y
  | System_gate x, System_gate y -> equal_system_gate_kind x y
  | Palette, (Settings _ | Incidents | Queue_context _ | Inline_action _ | Ask_answer | Help | System_gate _)
  | Settings _, (Palette | Incidents | Queue_context _ | Inline_action _ | Ask_answer | Help | System_gate _)
  | Incidents, (Palette | Settings _ | Queue_context _ | Inline_action _ | Ask_answer | Help | System_gate _)
  | Queue_context _, (Palette | Settings _ | Incidents | Inline_action _ | Ask_answer | Help | System_gate _)
  | Inline_action _, (Palette | Settings _ | Incidents | Queue_context _ | Ask_answer | Help | System_gate _)
  | Ask_answer, (Palette | Settings _ | Incidents | Queue_context _ | Inline_action _ | Help | System_gate _)
  | Help, (Palette | Settings _ | Incidents | Queue_context _ | Inline_action _ | Ask_answer | System_gate _)
  | System_gate _, (Palette | Settings _ | Incidents | Queue_context _ | Inline_action _ | Ask_answer | Help) ->
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

type menu_section =
  | Sec_overview
  | Sec_work
  | Sec_knowledge
  | Sec_fleet
  | Sec_runtime
  | Sec_infra
  | Sec_system

type menu_target =
  | Menu_pulse
  | Menu_work of work_tab
  | Menu_knowledge of knowledge_tab
  | Menu_keepers
  | Menu_keeper_tab of keeper_tab
  | Menu_runtime of runtime_tab
  | Menu_infra of infra_tab
  | Menu_settings
  | Menu_incidents
  | Menu_queue_context
  | Menu_help

type menu_item = {
  section : menu_section;
  target : menu_target;
  label : Say.t;
  shortcut : string option;
}

let menu_section_label = function
  | Sec_overview -> Say.make ~ko:"홈" ~en:"Overview"
  | Sec_work -> Say.make ~ko:"작업" ~en:"Work"
  | Sec_knowledge -> Say.make ~ko:"지식" ~en:"Knowledge"
  | Sec_fleet -> Say.make ~ko:"플릿" ~en:"Fleet"
  | Sec_runtime -> Say.make ~ko:"런타임" ~en:"Runtime"
  | Sec_infra -> Say.make ~ko:"인프라" ~en:"Infra"
  | Sec_system -> Say.make ~ko:"시스템" ~en:"System"

let menu_section_shortcut = function
  | Sec_work -> Some "2"
  | Sec_knowledge -> Some "3"
  | Sec_runtime -> Some "5"
  | Sec_infra -> Some "6"
  | Sec_overview | Sec_fleet | Sec_system -> None

let menu_section_index = function
  | Sec_overview -> 0
  | Sec_work -> 1
  | Sec_knowledge -> 2
  | Sec_fleet -> 3
  | Sec_runtime -> 4
  | Sec_infra -> 5
  | Sec_system -> 6

let equal_menu_section a b =
  Int.equal (menu_section_index a) (menu_section_index b)

let equal_menu_target a b =
  match a, b with
  | Menu_pulse, Menu_pulse
  | Menu_keepers, Menu_keepers
  | Menu_settings, Menu_settings
  | Menu_incidents, Menu_incidents
  | Menu_queue_context, Menu_queue_context
  | Menu_help, Menu_help ->
      true
  | Menu_work x, Menu_work y -> equal_work_tab x y
  | Menu_knowledge x, Menu_knowledge y -> equal_knowledge_tab x y
  | Menu_keeper_tab x, Menu_keeper_tab y -> equal_keeper_tab x y
  | Menu_runtime x, Menu_runtime y -> equal_runtime_tab x y
  | Menu_infra x, Menu_infra y -> equal_infra_tab x y
  | Menu_pulse, (Menu_work _ | Menu_knowledge _ | Menu_keepers | Menu_keeper_tab _ | Menu_runtime _ | Menu_infra _ | Menu_settings | Menu_incidents | Menu_queue_context | Menu_help)
  | Menu_work _, (Menu_pulse | Menu_knowledge _ | Menu_keepers | Menu_keeper_tab _ | Menu_runtime _ | Menu_infra _ | Menu_settings | Menu_incidents | Menu_queue_context | Menu_help)
  | Menu_knowledge _, (Menu_pulse | Menu_work _ | Menu_keepers | Menu_keeper_tab _ | Menu_runtime _ | Menu_infra _ | Menu_settings | Menu_incidents | Menu_queue_context | Menu_help)
  | Menu_keepers, (Menu_pulse | Menu_work _ | Menu_knowledge _ | Menu_keeper_tab _ | Menu_runtime _ | Menu_infra _ | Menu_settings | Menu_incidents | Menu_queue_context | Menu_help)
  | Menu_keeper_tab _, (Menu_pulse | Menu_work _ | Menu_knowledge _ | Menu_keepers | Menu_runtime _ | Menu_infra _ | Menu_settings | Menu_incidents | Menu_queue_context | Menu_help)
  | Menu_runtime _, (Menu_pulse | Menu_work _ | Menu_knowledge _ | Menu_keepers | Menu_keeper_tab _ | Menu_infra _ | Menu_settings | Menu_incidents | Menu_queue_context | Menu_help)
  | Menu_infra _, (Menu_pulse | Menu_work _ | Menu_knowledge _ | Menu_keepers | Menu_keeper_tab _ | Menu_runtime _ | Menu_settings | Menu_incidents | Menu_queue_context | Menu_help)
  | Menu_settings, (Menu_pulse | Menu_work _ | Menu_knowledge _ | Menu_keepers | Menu_keeper_tab _ | Menu_runtime _ | Menu_infra _ | Menu_incidents | Menu_queue_context | Menu_help)
  | Menu_incidents, (Menu_pulse | Menu_work _ | Menu_knowledge _ | Menu_keepers | Menu_keeper_tab _ | Menu_runtime _ | Menu_infra _ | Menu_settings | Menu_queue_context | Menu_help)
  | Menu_queue_context, (Menu_pulse | Menu_work _ | Menu_knowledge _ | Menu_keepers | Menu_keeper_tab _ | Menu_runtime _ | Menu_infra _ | Menu_settings | Menu_incidents | Menu_help)
  | Menu_help, (Menu_pulse | Menu_work _ | Menu_knowledge _ | Menu_keepers | Menu_keeper_tab _ | Menu_runtime _ | Menu_infra _ | Menu_settings | Menu_incidents | Menu_queue_context) ->
      false

let all_menu_items =
  [
    {
      section = Sec_overview;
      target = Menu_pulse;
      label = workspace_label Pulse;
      shortcut = Some "1";
    };
    {
      section = Sec_work;
      target = Menu_work Work_pipeline;
      label = work_tab_label Work_pipeline;
      shortcut = None;
    };
    {
      section = Sec_work;
      target = Menu_work Work_tasks;
      label = work_tab_label Work_tasks;
      shortcut = None;
    };
    {
      section = Sec_work;
      target = Menu_work Work_schedules;
      label = work_tab_label Work_schedules;
      shortcut = None;
    };
    {
      section = Sec_work;
      target = Menu_work Work_inbox;
      label = work_tab_label Work_inbox;
      shortcut = None;
    };
    {
      section = Sec_work;
      target = Menu_work Work_candle_scorecard;
      label = work_tab_label Work_candle_scorecard;
      shortcut = None;
    };
    {
      section = Sec_work;
      target = Menu_work Work_harness;
      label = work_tab_label Work_harness;
      shortcut = None;
    };
    {
      section = Sec_knowledge;
      target = Menu_knowledge Knowledge_board;
      label = knowledge_tab_label Knowledge_board;
      shortcut = None;
    };
    {
      section = Sec_knowledge;
      target = Menu_knowledge Knowledge_wiki;
      label = knowledge_tab_label Knowledge_wiki;
      shortcut = None;
    };
    {
      section = Sec_knowledge;
      target = Menu_knowledge Knowledge_artifacts;
      label = knowledge_tab_label Knowledge_artifacts;
      shortcut = None;
    };
    {
      section = Sec_knowledge;
      target = Menu_knowledge Knowledge_memory;
      label = knowledge_tab_label Knowledge_memory;
      shortcut = None;
    };
    {
      section = Sec_fleet;
      target = Menu_keepers;
      label = workspace_label Keepers;
      shortcut = Some "4";
    };
    {
      section = Sec_fleet;
      target = Menu_keeper_tab Keeper_chat;
      label = keeper_tab_label Keeper_chat;
      shortcut = None;
    };
    {
      section = Sec_fleet;
      target = Menu_keeper_tab Keeper_context;
      label = keeper_tab_label Keeper_context;
      shortcut = None;
    };
    {
      section = Sec_fleet;
      target = Menu_keeper_tab Keeper_tool_calls;
      label = keeper_tab_label Keeper_tool_calls;
      shortcut = None;
    };
    {
      section = Sec_fleet;
      target = Menu_keeper_tab Keeper_memory;
      label = keeper_tab_label Keeper_memory;
      shortcut = None;
    };
    {
      section = Sec_fleet;
      target = Menu_keeper_tab Keeper_work_candle;
      label = keeper_tab_label Keeper_work_candle;
      shortcut = None;
    };
    {
      section = Sec_fleet;
      target = Menu_keeper_tab Keeper_sandbox;
      label = keeper_tab_label Keeper_sandbox;
      shortcut = None;
    };
    {
      section = Sec_fleet;
      target = Menu_keeper_tab Keeper_config;
      label = keeper_tab_label Keeper_config;
      shortcut = None;
    };
    {
      section = Sec_fleet;
      target = Menu_keeper_tab Keeper_logs;
      label = keeper_tab_label Keeper_logs;
      shortcut = None;
    };
    {
      section = Sec_fleet;
      target = Menu_keeper_tab Keeper_identity;
      label = keeper_tab_label Keeper_identity;
      shortcut = None;
    };
    {
      section = Sec_runtime;
      target = Menu_runtime Runtime_quotas_credits;
      label = runtime_tab_label Runtime_quotas_credits;
      shortcut = None;
    };
    {
      section = Sec_runtime;
      target = Menu_runtime Runtime_efficiency_spend;
      label = runtime_tab_label Runtime_efficiency_spend;
      shortcut = None;
    };
    {
      section = Sec_runtime;
      target = Menu_runtime Runtime_failover_lanes;
      label = runtime_tab_label Runtime_failover_lanes;
      shortcut = None;
    };
    {
      section = Sec_runtime;
      target = Menu_runtime Runtime_fusion;
      label = runtime_tab_label Runtime_fusion;
      shortcut = None;
    };
    {
      section = Sec_runtime;
      target = Menu_runtime Runtime_tools_usage;
      label = runtime_tab_label Runtime_tools_usage;
      shortcut = None;
    };
    {
      section = Sec_runtime;
      target = Menu_runtime Runtime_connectors;
      label = runtime_tab_label Runtime_connectors;
      shortcut = None;
    };
    {
      section = Sec_runtime;
      target = Menu_runtime Runtime_addons_browser;
      label = runtime_tab_label Runtime_addons_browser;
      shortcut = None;
    };
    {
      section = Sec_infra;
      target = Menu_infra Infra_sandboxes;
      label = infra_tab_label Infra_sandboxes;
      shortcut = None;
    };
    {
      section = Sec_infra;
      target = Menu_infra Infra_repos_changes;
      label = infra_tab_label Infra_repos_changes;
      shortcut = None;
    };
    {
      section = Sec_infra;
      target = Menu_infra Infra_code;
      label = infra_tab_label Infra_code;
      shortcut = None;
    };
    {
      section = Sec_infra;
      target = Menu_infra Infra_activity_logs;
      label = infra_tab_label Infra_activity_logs;
      shortcut = None;
    };
    {
      section = Sec_system;
      target = Menu_settings;
      label = Say.make ~ko:"설정" ~en:"Settings";
      shortcut = Some "7/,";
    };
    {
      section = Sec_system;
      target = Menu_incidents;
      label = Say.make ~ko:"장애 이력" ~en:"Incidents";
      shortcut = Some "8/I";
    };
    {
      section = Sec_system;
      target = Menu_queue_context;
      label = Say.make ~ko:"큐 · 컨텍스트" ~en:"Queue & Ctx";
      shortcut = Some "9/^T";
    };
    {
      section = Sec_system;
      target = Menu_help;
      label = Say.make ~ko:"도움말" ~en:"Help";
      shortcut = Some "0/?";
    };
  ]

let menu_item_index = function
  | Menu_pulse -> 0
  | Menu_work Work_pipeline -> 1
  | Menu_work Work_tasks -> 2
  | Menu_work Work_schedules -> 3
  | Menu_work Work_inbox -> 4
  | Menu_work Work_candle_scorecard -> 5
  | Menu_work Work_harness -> 6
  | Menu_knowledge Knowledge_board -> 7
  | Menu_knowledge Knowledge_wiki -> 8
  | Menu_knowledge Knowledge_artifacts -> 9
  | Menu_knowledge Knowledge_memory -> 10
  | Menu_keepers -> 11
  | Menu_keeper_tab Keeper_chat -> 12
  | Menu_keeper_tab Keeper_context -> 13
  | Menu_keeper_tab Keeper_tool_calls -> 14
  | Menu_keeper_tab Keeper_memory -> 15
  | Menu_keeper_tab Keeper_work_candle -> 16
  | Menu_keeper_tab Keeper_sandbox -> 17
  | Menu_keeper_tab Keeper_config -> 18
  | Menu_keeper_tab Keeper_logs -> 19
  | Menu_keeper_tab Keeper_identity -> 20
  | Menu_runtime Runtime_quotas_credits -> 21
  | Menu_runtime Runtime_efficiency_spend -> 22
  | Menu_runtime Runtime_failover_lanes -> 23
  | Menu_runtime Runtime_fusion -> 24
  | Menu_runtime Runtime_tools_usage -> 25
  | Menu_runtime Runtime_connectors -> 26
  | Menu_runtime Runtime_addons_browser -> 27
  | Menu_infra Infra_sandboxes -> 28
  | Menu_infra Infra_repos_changes -> 29
  | Menu_infra Infra_code -> 30
  | Menu_infra Infra_activity_logs -> 31
  | Menu_settings -> 32
  | Menu_incidents -> 33
  | Menu_queue_context -> 34
  | Menu_help -> 35

let menu_item_of_index idx = List.nth_opt all_menu_items idx

let is_overlay_menu_target = function
  | Menu_settings | Menu_incidents | Menu_queue_context | Menu_help -> true
  | Menu_pulse
  | Menu_work _
  | Menu_knowledge _
  | Menu_keepers
  | Menu_keeper_tab _
  | Menu_runtime _
  | Menu_infra _ ->
      false
