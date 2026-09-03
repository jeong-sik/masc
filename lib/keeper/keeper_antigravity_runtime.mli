(** Keeper projection for the official Antigravity subscription runtime. *)

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }
(** One Antigravity candidate result plus its typed effect observation.
    Validation, setup, process spawn, and provider work before the first
    dynamic tool invocation are provably effect-free. Entering a dynamic tool
    closes the same-turn retry boundary before user/tool code can run. *)

val run :
  runtime_id:string ->
  keeper_name:string ->
  pre_tool_rejects:Keeper_official_client_host.rejected_tool_call list ref ->
  base_path:string ->
  goal:string ->
  goal_blocks:Agent_core.Types.content_block list option ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  initial_messages:Agent_core.Types.message list ->
  model_input_projection:Agent_core.Agent.model_input_projection option ->
  on_transmitted_model_input:(Agent_core.Types.message list -> unit) ->
  hooks:Agent_core.Hooks.hooks option ->
  context_injector:Agent_core.Hooks.context_injector option ->
  context:Agent_core.Context.t option ->
  ?terminal_effect_state:(unit -> Keeper_tools_agent_core.terminal_effect_state) ->
  ?on_model_input_window_observation:
    (Runtime_model_input_tail_window.window_observation -> unit) ->
  ?on_official_client_result_handoff:
    (invocation:Agent_core.Tool_contract.Invocation.t -> content:string -> unit) ->
  ?on_native_action:(official_turn:int ->
    identity:Runtime_native_tools.action_identity -> tool_name:string -> unit) ->
  event_bus:Agent_core.Event_bus.t option ->
  raw_trace:Agent_core.Raw_trace.t option ->
  on_event:(Agent_core.Types.sse_event -> unit) option ->
  config:Runtime_execution.antigravity_cli ->
  unit ->
  attempt_outcome
(** [on_transmitted_model_input] receives the history list this runtime hands
    to the Antigravity CLI, once per projection call, after the admission
    window has cut it. Required rather than optional: a lane that reports
    nothing is what wrote every Antigravity turn's input attribution as zero
    (masc#32995). The list is what masc handed over, not what crossed the
    wire -- the CLI assembles the request, and on a resumed conversation it
    re-sends only the new turn. That is the same [Durable_shape] reading the
    window observation reports. *)

module For_testing : sig
  val capacity_bounded_model_input_projection
    :  declared_max_prompt_bytes:int option
    -> system_prompt:string
    -> goal:string
    -> ?on_model_input_window_observation:
         (Runtime_model_input_tail_window.window_observation -> unit)
    -> Agent_core.Agent.model_input_projection option
    -> (Agent_core.Agent.model_input_projection option, Agent_core.Error.t) result
  (** The admission contract over the provider-bound history. [None] declared
      capacity passes the source projection through unchanged. A declared
      capacity returns a projection that runs the source projection first
      (the production source appends a bounded typed Gate replay reference)
      and then windows the result to the capacity minus the bytes the fixed
      prompt sections always occupy, refusing with a typed config error when
      those fixed sections alone leave no room. agy truncates oversized stdin
      prompts silently instead of refusing them, so this window is the only
      bound the turn gets. *)

  val start_prompt_bytes :
    system_prompt:string ->
    goal:string ->
    Agent_core.Types.message list ->
    (int, string) result
  (** Render through the production start-turn formatter and return the exact
      transmitted prompt byte count. *)

  val reserved_prompt_bytes : system_prompt:string -> goal:string -> int
  (** The bytes the admission contract reserves for the fixed prompt sections
      out of a declared capacity. One byte more than this is the smallest
      admissible declared capacity; the tail window can still refuse such a
      capacity when its constant undroppable preamble does not fit in what
      remains. Not the rendered empty-history prompt: the reserve charges
      both separators (the with-history worst case), while an empty-history
      render joins its two sections with one. *)
end
