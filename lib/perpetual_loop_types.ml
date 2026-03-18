(** Perpetual_loop types — event, config, and state definitions.

    @since 2.61.0 *)

type event =
  | TurnStart of int
  | TurnEnd of { turn : int; tokens_used : int; cost : float }
  | Compacted of { before_tokens : int; after_tokens : int; offloaded_path : string option }
  | Prepared of { dna_size : int }
  | Handoff of { to_model : string; generation : int }
  | Verified of { action : string; verdict : string }
  | Heartbeat of { turn : int; context_pct : float }
  | Error of string
  | IdleDetected of int
  | Terminated of string
  | CodingSpawn of { agent : string; exit_code : int; elapsed_ms : int }
  | TaskClaimed of { task_id : string; title : string; priority : int }
  | TaskCompleted of { task_id : string }
  | ClaimSkipped of string

type loop_config = {
  initial_goal : string;
  model_cascade : Llm_types.model_spec list;
  tools : Llm_types.tool_def list;
  heartbeat_interval_s : float;
  max_idle_turns : int;
  feedback_enabled : bool;
  verifier_model : Llm_types.model_spec;
  compact_threshold : float;
  prepare_threshold : float;
  handoff_threshold : float;
  compact_strategies : Context_manager.compaction_strategy list;
  session_base_dir : string;
  on_event : event -> unit;
  event_bus : Agent_sdk.Event_bus.t option;
  (* Coding mode: spawn Claude Code instead of LLM direct calls *)
  coding_mode : bool;
  coding_agent : string;
  coding_timeout_s : int;
  coding_sw : Eio.Switch.t option;
  coding_proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  (* Auto-claim: connect perpetual agent to Room task backlog *)
  room_config : Room_utils_backend_setup.config option;
  agent_name : string;
  auto_claim_cooldown_s : float;
}

type loop_state = {
  mutable context : Context_manager.working_context;
  mutable session : Context_manager.session_context;
  mutable generation : int;
  mutable turn_count : int;
  mutable idle_turns : int;
  mutable total_cost : float;
  mutable total_tokens : int;
  mutable last_heartbeat : float;
  mutable started_at : float;
  mutable last_turn_ts : float;
  mutable last_model_used : string;
  mutable last_usage : Agent_sdk.Types.api_usage;
  mutable last_latency_ms : int;
  mutable compaction_count : int;
  mutable compaction_tokens_saved : int;
  mutable last_compaction_ts : float;
  mutable last_compaction_before_tokens : int;
  mutable last_compaction_after_tokens : int;
  mutable events : (float * event) list;
  mutable running : bool;
  trace_id : string;
  (* Auto-claim state *)
  mutable current_task_id : string option;
  mutable last_claim_attempt_ts : float;
  mutable claim_failure_count : int;
}
