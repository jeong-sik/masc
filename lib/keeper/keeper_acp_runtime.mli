(** Unified Keeper projection for persistent ACP v1 official runtimes:
    Antigravity ([agy acp]), Kimi Code ([kimi acp]), Mistral Vibe
    ([vibe-acp]), and Muse Code ([muse acp]).

    Each Keeper owns an isolated persistent child process and loopback HTTP MCP
    bridge under its own [Eio.Switch.t], amortizing CLI cold start while
    preventing cross-Keeper crash or stall blast radius. *)

val evict_keeper : keeper_name:string -> unit
(** Stop and remove any persistent ACP child processes owned by [keeper_name].
    Safe to call when no child is running. *)

val evict_keeper_for_workspace : base_path:string -> keeper_name:string -> unit
(** Stop and remove any persistent ACP child processes owned by [keeper_name]
    and clear any armed ACP rollover marker under [base_path] so no marker
    lingers after keeper teardown/purge. *)

val evict_all : unit -> unit
(** Stop and remove every persistent ACP child process in the pool (used during
    server shutdown and root-switch teardown). Safe to call multiple times. *)

val run :
  ?on_guidance_prepared:(unit -> (unit, Agent_core.Error.t) result) ->
  input_limit:Llm_provider.Input_budget.t ->
  (* The declared [max-context] of the runtime this attempt runs on
     ({!Keeper_turn_driver_try_provider.input_limit_of_runtime}). *)
  input_source:Keeper_request_source.t ->
  media_store:Agent_core.History.media_store ->
  ?argument_source:Keeper_official_client_host.argument_source ->
  ?official_task_reference:Keeper_official_task_reference.t ->
  ?composed_context:(unit -> Keeper_official_client_host.composed_context option) ->
  accepts_image_input:bool ->
  ?required_native_posture:Runtime_native_tools.posture ->
  ?official_client_continuation:Keeper_semantic_execution.official_client_checkpoint ->
  runtime_id:string ->
  host:Runtime_account_access.host_account ->
  configured_reasoning_effort:Llm_provider.Reasoning_effort.t option ->
  turn_timeout_s:float option ->
  keeper_name:string ->
  pre_tool_rejects:Keeper_official_client_host.rejected_tool_call list ref ->
  base_path:string ->
  outbox_viewer:Keeper_client_tool_outbox.viewer ->
  read_retained_media:Keeper_client_tool_outbox.media_reader option ->
  goal:string ->
  goal_blocks:Agent_core.Types.content_block list option ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  ?loading_plan:Keeper_official_client_host.loading_plan ->
  initial_messages:Agent_core.Types.message list ->
  model_input_projection:Keeper_history_projection.t option ->
  on_transmitted_model_input:
    (Keeper_official_client_host.transmitted_model_input -> unit) ->
  hooks:Agent_core.Hooks.hooks option ->
  context_injector:Agent_core.Hooks.context_injector option ->
  context:Agent_core.Context.t option ->
  ?terminal_effect_state:(unit -> Keeper_tools_agent_core.terminal_effect_state) ->
  ?on_model_input_window_observation:
    (Runtime_model_input_tail_window.window_observation -> unit) ->
  ?carried_front_seed:Keeper_carried_front.seed_reader ->
  ?librarian_front:Keeper_turn_driver_try_provider.continuity ->
  ?on_carried_front:Keeper_official_client_host.carried_front_observer ->
  turn_start:Keeper_carried_front.turn_start ->
  ?on_official_client_tool_boundary:
    (tool_name:string ->
     (Keeper_official_client_host.host_stop option, Agent_core.Error.t) result) ->
  ?on_official_client_result_handoff:
    (invocation:Agent_core.Tool_contract.Invocation.t -> content:string -> unit) ->
  ?on_native_tool_completion:
    (block_index:int ->
     tool_call_id:string option ->
     Runtime_native_tools.completion ->
     unit) ->
  ?on_native_action:
    (official_turn:int ->
     identity:Runtime_native_tools.action_identity ->
     tool_name:string ->
     unit) ->
  ?on_usage_report:(Keeper_client_usage_report.t -> unit) ->
  ?on_tool_execution:
    (block_index:int -> tool_call_id:string -> execution_id:Ids.Execution_id.t -> unit) ->
  event_bus:Agent_core.Event_bus.t option ->
  raw_trace:Agent_core.Raw_trace.t option ->
  on_event:(Agent_core.Types.sse_event -> unit) option ->
  config:Runtime_execution.acp_client ->
  unit ->
  Keeper_official_client_attempt.outcome

module For_testing : sig
  val acp_error_to_core_error : Runtime_acp_client.error -> Agent_core.Error.t
  val should_evict_persistent_child_on_error : Runtime_acp_client.error -> bool

  (** The folder a Keeper's host runs in, as its pool key holds it. *)
  type host_cwd =
    | Isolated_per_spawn  (** A new empty folder each time the host spawns. *)
    | Keeper_folder of string  (** The Keeper's own folder. *)

  val native_cwd_of_posture
    :  base_path:string
    -> keeper_name:string
    -> required_native_posture:Runtime_native_tools.posture option
    -> Runtime_native_tools.posture
    -> (host_cwd, Agent_core.Error.t) result
  (** [Native_none] is [Isolated_per_spawn]. [Native_read] and [Native_full]
      are the [Keeper_folder] {!Keeper_native_cwd.resolve} gives for [Acp]. *)

  val recovery_failure_of_acp_error
    :  Runtime_acp_client.error
    -> Keeper_official_client_session_store.recovery_failure

  val classify_prompt_error
    :  is_gate_continuation:bool
    -> activity_observed:bool
    -> Runtime_acp_client.error
    -> Keeper_official_client_session_store.recovery_failure * Agent_core.Error.t

  val api_usage_of_acp_usage
    :  driver:Runtime_acp_client.driver
    -> Runtime_acp_client.usage
    -> Agent_core.Types.api_usage

  val usage_is_nonzero : Agent_core.Types.api_usage -> bool

  val effective_context_used : Runtime_acp_client.usage -> int option

  val held_context_of_usage
    :  Runtime_acp_client.usage
    -> Runtime_observation.request_context option

  val stop_reason_of_acp_stop_reason
    :  Runtime_acp_client.stop_reason
    -> Agent_core.Types.stop_reason

  val effective_context_limit_tokens
    :  context_size:int option
    -> input_limit:Llm_provider.Input_budget.t
    -> int

  (** [Some (used_tokens, limit_tokens)] when the agent's own count reached
      {!rollover_threshold} of the smaller of its reported window and the
      declared limit. *)
  val rollover_of_usage
    :  context_used:int option
    -> context_size:int option
    -> input_limit:Llm_provider.Input_budget.t
    -> threshold:float option
    -> (int * int) option

  val first_atom_of_sends_from : Agent_core.Types.message list -> sends_from:int -> int

  val should_fence_tool_call_started
    :  ?server_isolation:Runtime_acp_client.mcp_server_isolation
    -> native_posture:Runtime_native_tools.posture
    -> mcp_server_name:string
    -> allowed_tool_names:string list
    -> Runtime_acp_client.tool_call_identity
    -> bool

  val process_config_sha256
    :  native_posture:Runtime_native_tools.posture
    -> skills_dirs:string list
    -> agent_compaction:Runtime_acp_client.agent_compaction option
    -> Runtime_execution.acp_client
    -> string

  val rollover_threshold : float
  val default_keep_ratio : float

  val record_rollover_marker
    :  base_path:string
    -> keeper_id:string
    -> runtime_id:string
    -> session_id:string
    -> unit

  val rollover_marker_matches
    :  base_path:string
    -> keeper_id:string
    -> runtime_id:string
    -> session_id:string
    -> bool

  val clear_rollover_marker : base_path:string -> keeper_id:string -> unit

  val split_older_for_rollover
    :  ?keep_ratio:float
    -> Agent_core.Types.message list
    -> Agent_core.Types.message list

  val prefer_handoff_for_start
    :  planned_fresh_rollover:bool
    -> force_fresh_retry:bool
    -> bool

  val hydrate_start_messages
    :  ?appended_nudges:Agent_core.Types.message list
    -> keepers_dir:string
    -> keeper_id:string
    -> prefer_handoff:bool
    -> Agent_core.Types.message list
    -> Agent_core.Types.message list

  val compact_once_for_overflow
    :  already_compacted:bool ref
    -> keepers_dir:string
    -> keeper_id:string
    -> input_limit:Llm_provider.Input_budget.t
    -> previous_capacity:int
    -> refused_sent_bytes:int option
    -> capacity:int
    -> initial_messages:Agent_core.Types.message list
    -> unit

  val overflow_trigger
    :  input_limit:Llm_provider.Input_budget.t
    -> previous_capacity:int
    -> refused_sent_bytes:int option
    -> capacity:int
    -> Keeper_compaction.compaction_trigger

  val project_stream_for_testing
    :  ?server_isolation:Runtime_acp_client.mcp_server_isolation
    -> ?official_turn:int
    -> ?on_effect_attempted:(unit -> unit)
    -> ?on_native_action:
         (official_turn:int
          -> identity:Runtime_native_tools.action_identity
          -> tool_name:string
          -> unit)
    -> ?on_native_tool_completion:
         (block_index:int
          -> tool_call_id:string option
          -> Runtime_native_tools.completion
          -> unit)
    -> ?on_usage_report:(Keeper_client_usage_report.t -> unit)
    -> ?on_tool_execution:
         (block_index:int -> tool_call_id:string -> execution_id:Ids.Execution_id.t -> unit)
    -> ?on_event:(Agent_core.Types.sse_event -> unit)
    -> driver:Runtime_acp_client.driver
    -> mcp_server_name:string
    -> model:string
    -> session_id:string
    -> turn_count:int
    -> native_posture:Runtime_native_tools.posture
    -> allowed_tool_names:string list
    -> unit
    -> (Runtime_acp_client.stream_event -> unit)
       * (call_id:string -> tool_name:string -> arguments:Yojson.Safe.t -> bool)
       * (call_id:string -> unit)
       * (stop_reason:Agent_core.Types.stop_reason
          -> usage:Agent_core.Types.api_usage option
          -> unit)
       * (unit -> Yojson.Safe.t)

  val reconcile_prepared_tools
    :  ?account_home:string
    -> ?continuation:Keeper_semantic_execution.official_client_checkpoint
    -> native_posture:Runtime_native_tools.posture
    -> claim_plan:Keeper_official_client_session_store.claim_plan
    -> Keeper_official_client_host.prepared_turn
    -> (Keeper_official_client_session_store.claim_plan * string, Agent_core.Error.t) result

  val start_mcp_bridge_for_specs
    :  driver:Runtime_acp_client.driver
    -> keeper_name:string
    -> sw:Eio.Switch.t
    -> env:Eio_unix.Stdenv.base
    -> pinned_tool_specs:Yojson.Safe.t list
    -> Runtime_official_client_mcp_http.t

  type pool_key =
    { keeper_name : string
    ; runtime_id : string
    ; tool_surface_sha256 : string
    ; process_config_sha256 : string
    ; cwd : host_cwd
    ; dangerously_skip_permissions : bool
    }

  val run_serialized_turn
    :  mutex:Eio.Mutex.t
    -> on_holder_exception:(unit -> unit)
    -> (unit -> ('a, Agent_core.Error.t) result)
    -> ('a, Agent_core.Error.t) result

  module Pool : sig
    type 'a t

    val create : unit -> 'a t
    val count : 'a t -> int
    val find_opt : 'a t -> pool_key -> 'a option

    val install_for_keeper
      :  'a t
      -> key:pool_key
      -> fresh:'a
      -> is_alive:('a -> bool)
      -> close:('a -> unit)
      -> 'a

    val evict_if_same : 'a t -> key:pool_key -> target:'a -> close:('a -> unit) -> unit
    val evict_keeper : 'a t -> keeper_name:string -> close:('a -> unit) -> unit
    val evict_all : 'a t -> close:('a -> unit) -> unit

    val evict_idle
      :  'a t
      -> now:float
      -> idle_ttl_s:float
      -> last_used_at:('a -> float)
      -> is_busy:('a -> bool)
      -> close:('a -> unit)
      -> unit
  end
end
