(** MASC MCP - Main Library Entry Point (Eio-only) *)

(* Time compatibility - Eio-native with Unix fallback *)
module Time_compat = Time_compat

module Version = Version
module Build_identity = Build_identity
module Common = Common
module Json_util = Json_util
module Log = Log
module Types = Types
module Nickname = Nickname
module Response = Response
module Error = Error
module Validation = Validation
module Command_plane_v2 = Command_plane_v2
module Command_plane_orchestra = Command_plane_orchestra
module Cp_search_fabric = Cp_search_fabric
module Cp_cleanup = Cp_cleanup
module Config = Config
module Env_config = Env_config
module Resilience = Resilience
module Mode = Mode
module Notify = Notify

module Message_schema = Message_schema
module Verification = Verification
module Drift_guard = Drift_guard
module Lamport = Lamport
module Trace = Trace
module Room_utils = Room_utils
module Room = Room
module Room_walph_eio = Room_walph_eio
module Safe_parse = Safe_parse
module Prompt_registry = Prompt_registry
module Chain_types = Chain_types
module Chain_trace_types = Chain_trace_types
module Chain_category = Chain_category
module Chain_stats = Chain_stats
module Chain_utils = Chain_utils
module Chain_conversation = Chain_conversation
module Chain_iteration = Chain_iteration
module Chain_composer = Chain_composer
module Chain_evaluator = Chain_evaluator
module Chain_parser = Chain_parser
module Chain_mermaid_parser = Chain_mermaid_parser
module Chain_compiler = Chain_compiler
module Chain_registry = Chain_registry
module Chain_telemetry = Chain_telemetry
module Chain_error = Chain_error
module Chain_log = Chain_log
module Chain_retry = Chain_retry
module Chain_executor_retry = Chain_executor_retry
module Chain_adapter_eio = Chain_adapter_eio
module Checkpoint_store = Checkpoint_store
module Run_log_eio = Run_log_eio
module Langfuse = Langfuse
module Chain_spawn_registry = Chain_spawn_registry
module Chain_executor_eio = Chain_executor_eio
module Chain_orchestrator_eio = Chain_orchestrator_eio
module Chain_run_store = Chain_run_store
module Chain_native_eio = Chain_native_eio
module Room_git = Room_git
module Room_portal = Room_portal
module Room_worktree = Room_worktree
module Tool_args = Tool_args
module Tool_code = Tool_code
module Tool_help_registry = Tool_help_registry
module Room_eio = Room_eio

module Session = Session
module Shutdown_hooks = Shutdown_hooks
module Tools = Tools
module Auto_responder = Auto_responder
module Mcp_protocol = Mcp_protocol
module Mcp_prompt_surface = Mcp_prompt_surface
module Mcp_server = Mcp_server
module Mcp_server_eio = Mcp_server_eio
module Mcp_session = Mcp_session
module Http_server_eio = Http_server_eio
module Http_server_h2 = Http_server_h2
module Graphql_endpoint = Graphql_endpoint
module Graphql_client = Graphql_client
module Graphql_api = Graphql_api
module Safe_ops = Safe_ops
module Sse = Sse
module Streamable_http = Streamable_http
module Board = Board
module Board_pg = Board_pg
module Board_dispatch = Board_dispatch
module Board_listener = Board_listener
module Council = Council
module Social = Social
module Social_motion = Social_motion
module Social_runtime = Social_runtime
module Mention_inbox = Mention_inbox
module Agent_reputation = Agent_reputation
module Activity_feed = Activity_feed
module Task_pg = Task_pg
module Task_dispatch = Task_dispatch
module Web_dashboard = Web_dashboard
module Credits_dashboard = Credits_dashboard
module Lodge_dashboard = Lodge_dashboard
module Progress = Progress
module Pulse = Pulse
module Cancellation = Cancellation
module Subscriptions = Subscriptions

module Checkpoint_types = Checkpoint_types
module Auth = Auth
module Institution_eio = Institution_eio
module Telemetry_eio = Telemetry_eio
module Swarm_eio = Swarm_eio
module Swarm_behaviors_eio = Swarm_behaviors_eio
module Handover_eio = Handover_eio
module Backend = Backend
module Backend_eio = Backend_eio
module Cache_eio = Cache_eio
module Llm_response_cache = Llm_response_cache
module Lodge_cascade = Lodge_cascade
module Prometheus = Prometheus
module Rate_limit = Rate_limit
module Circuit_breaker = Circuit_breaker
module Mind_eio = Mind_eio
module Noosphere_eio = Noosphere_eio
module Metrics_store_eio = Metrics_store_eio
module Planning_eio = Planning_eio
module Post_verifier = Post_verifier
module Post_verifier_llm = Post_verifier_llm
module Provider_adapter = Provider_adapter
module Process_eio = Process_eio
module Eio_context = Eio_context
module Run_eio = Run_eio
module Team_session_types = Team_session_types
module Team_session_store = Team_session_store
module Team_session_report = Team_session_report
module Team_session_engine_eio = Team_session_engine_eio
module Hebbian_eio = Hebbian_eio
module Spawn = Spawn
module Spawn_eio = Spawn_eio
module Spawn_registry = Spawn_registry
module Glm_pool = Glm_pool
module Bounded = Bounded
module Mdal = Mdal
module Mdal_swarm = Mdal_swarm
module Mdal_store = Mdal_store
module Mdal_worker = Mdal_worker
module Orchestrator = Orchestrator
module Agent_card = Agent_card
module Agent_identity = Agent_identity
module Agent_tool_surfaces = Agent_tool_surfaces
module Agent_ecosystem = Agent_ecosystem
module Agent_health = Agent_health
module Agent_neo4j = Agent_neo4j
module Agent_registry_eio = Agent_registry_eio
module Agent_planner = Agent_planner
module A2a_tools = A2a_tools
module Ag_ui = Ag_ui
module Capability_registry = Capability_registry
module Capability_match = Capability_match
module Context_router = Context_router
module Masc_pb = Masc_pb
module Transport = Transport
module Transport_grpc_next = Transport_grpc_next
module Encryption = Encryption
module Gcm_compat = Gcm_compat
module Mention = Mention
module Hat = Hat
module Heartbeat = Heartbeat
module Guardian = Guardian
module Sentinel = Sentinel
module Mitosis = Mitosis
module Mitosis_metrics = Mitosis_metrics
module Generational_metrics = Generational_metrics
module Handoff_quality = Handoff_quality
module Adaptive_thresholds = Adaptive_thresholds
module Dashboard = Dashboard
module Dashboard_cache = Dashboard_cache
module Dashboard_governance = Dashboard_governance
module Dashboard_governance_judge = Dashboard_governance_judge
module Dashboard_operator_judge = Dashboard_operator_judge
module Operator_judgment = Operator_judgment
module Dashboard_semantics = Dashboard_semantics
module Dashboard_execution = Dashboard_execution
module Dashboard_mission = Dashboard_mission
module Dashboard_proof = Dashboard_proof
module Dashboard_mission_briefing = Dashboard_mission_briefing
module Server_utils = Server_utils
module Server_auth = Server_auth
module Server_tts_proxy = Server_tts_proxy
module Server_trpg_rest = Server_trpg_rest
module Server_dashboard_http = Server_dashboard_http
module Server_routes_http = Server_routes_http
module Server_h2_gateway = Server_h2_gateway
module Server_runtime_bootstrap = Server_runtime_bootstrap
module Server_command_plane_http = Server_command_plane_http
module Server_social_http = Server_social_http
module Server_mcp_transport_http = Server_mcp_transport_http
module Swarm_status = Swarm_status
module Tempo = Tempo
module Federation = Federation
module Lodge_decision = Lodge_decision
module Lodge_worker = Lodge_worker
module Level2_config = Level2_config
module Level4_config = Level4_config
module Local_runtime_pool = Local_runtime_pool
module Local_agent_eio = Local_agent_eio
module Agent_swarm_client = Agent_swarm_client
module Agent_swarm_dev_tools = Agent_swarm_dev_tools
module Agent_swarm_external_agent = Agent_swarm_external_agent
module Agent_swarm_fleet = Agent_swarm_fleet
module Agent_swarm_live_harness = Agent_swarm_live_harness
module Agent_swarm_prompts = Agent_swarm_prompts
module Agent_swarm_runner = Agent_swarm_runner
module Agent_swarm_swarm = Agent_swarm_swarm
module Agent_swarm_tool_input = Agent_swarm_tool_input
module Agent_swarm_tools = Agent_swarm_tools
module Relay = Relay
module Goal_store = Goal_store
module Operator_control = Operator_control
module Goal_guard = Goal_guard
module Goal_orchestrator = Goal_orchestrator
module Goal_scheduler = Goal_scheduler
module Swarm_goal_loop = Swarm_goal_loop
module Swarm_checkpoint = Swarm_checkpoint
module Compression_dict = Compression_dict
(* Redis_common module removed - PostgreSQL is now the only distributed backend *)

(* WebRTC protocol modules (Sdp, Dtls, Sctp, Datachannel, etc.)
   removed — use the ocaml-webrtc library directly. *)

module Voice_stream = Voice_stream
module Voice_session_manager = Voice_session_manager
module Voice_bridge = Voice_bridge_eio
module Void = Void
module Udp_socket_eio = Udp_socket_eio

(* Tool handler modules (extracted for testability) *)
module Tool_plan = Tool_plan
module Tool_run = Tool_run
module Tool_cache = Tool_cache
module Tool_tempo = Tool_tempo
module Tool_mitosis = Tool_mitosis
module Tool_portal = Tool_portal
module Tool_worktree = Tool_worktree
module Tool_vote = Tool_vote
module Tool_a2a = Tool_a2a
module Tool_handover = Tool_handover
module Tool_relay = Tool_relay
module Tool_operator = Tool_operator
module Tool_team_session_support = Tool_team_session_support
module Tool_team_session_handlers = Tool_team_session_handlers
module Tool_team_session = Tool_team_session
module Tool_heartbeat = Tool_heartbeat
module Tool_encryption = Tool_encryption
module Tool_auth = Tool_auth
module Tool_hat = Tool_hat
module Tool_audit = Tool_audit
module Tool_suspend = Tool_suspend
module Tool_shard = Tool_shard
module Tool_social = Tool_social
module Tool_council = Tool_council
module Tool_experiment = Tool_experiment
module Tool_rate_limit = Tool_rate_limit
module Tool_cost = Tool_cost
module Tool_walph = Tool_walph
module Tool_agent = Tool_agent
module Tool_task = Tool_task
module Tool_room = Tool_room
module Tool_control = Tool_control
module Tool_verification = Tool_verification
module Tool_misc = Tool_misc
module Tool_registry = Tool_registry
module Tool_catalog = Tool_catalog
module Tool_result = Tool_result
module Tool_dispatch = Tool_dispatch
module Tool_trace_hooks = Tool_trace_hooks
module Tool_permissions = Tool_permissions
module Sse_room_filter = Sse_room_filter
module Room_checkpoint = Room_checkpoint
module Tool_metrics = Tool_metrics
module Tool_harness_health = Tool_harness_health
module Tool_unified = Tool_unified
module Tool_llama = Tool_llama
module Tool_board = Tool_board
module Tool_command_plane = Tool_command_plane
module Tool_lodge = Tool_lodge
module Tool_mdal = Tool_mdal
module Tool_notifications = Tool_notifications
module Tool_voice = Tool_voice

(* Lodge subsystem *)
module Lodge_atmosphere = Lodge_atmosphere
module Lodge_broadcast = Lodge_broadcast
module Lodge_daemon = Lodge_daemon
module Lodge_heartbeat = Lodge_heartbeat
module Lodge_memory = Lodge_memory
module Lodge_personality = Lodge_personality
module Lodge_selection = Lodge_selection
module Lodge_reaction = Lodge_reaction
module Lodge_topic = Lodge_topic
module Lodge_tom = Lodge_tom

module Game_view_state = Game_view_state
module Tool_protocol_game_view = Tool_protocol_game_view

(* Gardener — Self-Organizing Agent Ecosystem *)
module Gardener_types = Gardener_types
module Gardener = Gardener
module Tool_gardener = Tool_gardener

(* Library — Agent Knowledge Base *)
module Tool_library = Tool_library

(* Perpetual Agent Runtime — Infinite Context System *)
module Llm_client = Llm_client
module Context_manager = Context_manager
module Verifier = Verifier
module Succession = Succession
module Perpetual_loop = Perpetual_loop
module Tool_perpetual = Tool_perpetual
module Tool_keeper = Tool_keeper

(* Keeper Agent Harness — trajectory + eval gates + scenarios *)
module Trajectory = Trajectory
module Eval_gate = Eval_gate
module Eval_harness = Eval_harness
module Anti_fake = Anti_fake

(* Keeper Autonomy Engine (Phase 2: autonomy slider + verifier) *)
module Keeper_autonomy = Keeper_autonomy
module Keeper_verifier = Keeper_verifier
module Keeper_contract = Keeper_contract
module Keeper_deliberation = Keeper_deliberation
module Keeper_types = Keeper_types
module Keeper_memory = Keeper_memory
module Keeper_alerting = Keeper_alerting
module Keeper_exec_tools = Keeper_exec_tools
module Keeper_exec_status = Keeper_exec_status
module Keeper_execution = Keeper_execution
module Keeper_learning = Keeper_learning
module Keeper_feedback_tool = Keeper_feedback_tool
module Keeper_keepalive = Keeper_keepalive
module Keeper_runtime = Keeper_runtime

(* Autonomy Adjuster — Feedback Closure (Phase 4) *)
module Autonomy_adjuster = Autonomy_adjuster

module Tool_goals = Tool_goals
module Tool_trpg = Tool_trpg
module Trpg_store = Trpg_store
module Trpg_preset_store = Trpg_preset_store
module Trpg_engine_types = Trpg_engine_types
module Trpg_engine_event = Trpg_engine_event
module Trpg_engine_state_machine = Trpg_engine_state_machine
module Trpg_engine_store = Trpg_engine_store
module Trpg_engine_store_sqlite = Trpg_engine_store_sqlite
module Trpg_world_projection = Trpg_world_projection
module Trpg_visibility = Trpg_visibility
module Trpg_rule = Trpg_rule
module Trpg_rule_dnd5e_lite = Trpg_rule_dnd5e_lite
module Trpg_engine_replay = Trpg_engine_replay
module Trpg_bdi = Trpg_bdi
module Trpg_harness = Trpg_harness
module Trpg_dm_intent = Trpg_dm_intent
module Trpg_actor_match = Trpg_actor_match

(* Autoresearch — Karpathy-inspired autonomous experiment loop *)
module Autoresearch = Autoresearch
module Tool_autoresearch = Tool_autoresearch

(* SWARM-RISC Agent ISA (Phase 1: types + pipeline + tools) *)
module Risc_types = Risc_types
module Risc_pipeline = Risc_pipeline
module Tool_risc = Tool_risc

(* SWARM-RISC Phase 2: MESI cache coherence *)
module Cache_coherence = Cache_coherence

(* SWARM-RISC Phase 3: OoO + Work-Stealing *)
module Reservation_station = Reservation_station
module Work_stealing = Work_stealing

(* SWARM-RISC Phase 4: Speculative Execution + MCTS *)
module Mcts_tree = Mcts_tree
module Speculative_engine = Speculative_engine

(* OAS Integration — Agent SDK v0.24+ bridge *)
module Oas_events = Oas_events
module Oas_checkpoint_bridge = Oas_checkpoint_bridge
