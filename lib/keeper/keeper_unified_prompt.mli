(** Keeper_unified_prompt — Build a single unified prompt from keeper identity
    and world observation.

    Only reactive triggers and resource state are included in the user message;
    runtime telemetry remains on the decision-audit path.

    @since Unified Keeper Loop *)

(** Three-channel turn prompt. The observation frame is separated from the
    persisted user message so it can be injected per-turn (via
    [dynamic_context]) instead of accumulating in the AGENT_CORE conversation.

    Feedback-loop invariant (#25193, RFC PR #25246, operator decision
    2026-07-20): [world_state] must never be persisted as a conversation
    message. A live audit found 943/945 user messages in one keeper's
    checkpoint were byte-identical world-state frames (59% of payload),
    which exhausted the request window and re-fed the model its own observations. *)
type turn_prompt_parts = {
  system_prompt : string;
      (** Keeper identity, instructions, and turn intent. Stable across
          turns of a generation. *)
  world_state : string;
      (** The "## Current World State" observation frame, rebuilt fresh
          every turn. Inject as per-turn [dynamic_context]; never append
          to the persisted message history. *)
  user_message : string;
      (** Current user-turn input. Operator utterances are durable. An
          autonomous continuation uses the fleet wake prompt, which is also
          durable: each cycle is an ordinary next user turn followed by its
          assistant/tool suffix. HITL resolutions are appended by the turn
          driver. *)
}

val autonomous_wake_marker : string
(** Last-resort input for an autonomous continuation, used when the fleet
    does not configure one. It is appended to the same checkpoint
    as the following assistant/tool suffix. The fresh observation frame lives
    separately in {!turn_prompt_parts.world_state} and is never persisted.

    Do not compare a turn's [user_message] against this to decide whether the
    turn was autonomous: operators can change the value, and that classifier
    would then be wrong for exactly the deployments that configured it. *)

val format_current_task :
  ?skill_surfaces:Keeper_skill_catalog.exact_surface list ->
  Masc_domain.task ->
  string

val format_held_task_skills
  :  ?skill_surfaces_by_task:
       (string * Keeper_skill_catalog.exact_surface list) list
  -> Keeper_world_observation_inputs.held_task_skills list
  -> string option
(** One line per other held task that names skills, under its own heading;
    [None] when there is none. The current task's block carries its own
    skills, so this covers a keeper holding several tasks (task-364). *)

val format_current_task_observation
  :  ?skill_surfaces:Keeper_skill_catalog.exact_surface list
  -> Keeper_world_observation_inputs.current_task_observation
  -> string option
(** Render one held task as per-turn observation context. The direct-message
    lane reuses this renderer so it sees the same task identity, status,
    provenance, and handoff as an autonomous wake without persisting that
    context. Storage error text is not model-facing content. *)

val format_approval_authority_observation :
  Keeper_world_observation.approval_authority_observation -> string
(** Render the current durable Gate projection. A complete empty projection is
    explicit so old chat claims about pending approvals cannot silently remain
    current; partial/unavailable projections forbid that inference. *)

val effective_instructions :
  meta:Keeper_meta_contract.keeper_meta ->
  ?profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  unit ->
  string
(** Resolve the instruction body: the profile default when the keeper TOML
    states one, else the persisted keeper instructions. *)

(** What the prompt knows about one active goal: id, title, and the stored
    phase. [summary_phase] is [None] only for an id the store cannot resolve
    (a dangling assignment, kept visible). RFC-0387 stage 2 carries the phase
    so a [Verifying] goal renders annotated in the Active Goals layer — the
    gate must not make the goal disappear from the keeper (review P0-1). *)
type goal_summary = {
  summary_goal_id : string;
  summary_title : string;
  summary_phase : Goal_phase.t option;
}

val active_goal_summaries_for_task :
  config:Workspace.config ->
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  goal_summary list
(** The Goals this turn's task is linked to and still open enough to progress.

    A Goal is shared intent and names no keeper, so the store answers the same
    list for everyone; the task the keeper holds is what makes a subset of it
    this turn's context. {!Goal_phase.admits_self_directed_progress} decides
    which of the linked Goals stay -- [Verifying] stays in (the gate holds the
    phase, not the work) and terminal phases drop out. A turn holding no task
    carries none of them; [masc_goal_list] answers the rest. *)

val build_system_prompt :
  meta:Keeper_meta_contract.keeper_meta ->
  config:Workspace.config ->
  ?profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  unit ->
  string
(** Build the model-facing stable Keeper contract shared by direct and
    autonomous turns. Channel-specific input belongs in dynamic context or the
    persisted user message, not in a second system-prompt implementation.

    [config] is the caller-owned workspace generation admitted for the turn.
    Prompt construction never resolves a second default config. *)

(** Build the three-channel unified prompt from keeper state.

    @param meta Keeper metadata (identity, soul, goals, instructions)
    @param config Caller-owned workspace generation for this turn
    @param observation Current world snapshot *)
val build_prompt :
  meta:Keeper_meta_contract.keeper_meta ->
  config:Workspace.config ->
  ?profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  turn_decision:Keeper_world_observation.keeper_cycle_decision ->
  ?previous_turn_stop:Keeper_turn_checkpoint_reason.t ->
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  ?task_skill_surfaces:(string * Keeper_skill_catalog.exact_surface list) list ->
  ?active_goal_summaries:goal_summary list ->
  ?repository_freshness:Keeper_sandbox_control.freshness_row list ->
  ?context_budget_bytes:int ->
  observation:Keeper_world_observation.world_observation ->
  unit ->
  turn_prompt_parts
(** When [?profile_defaults] is omitted, [instructions] falls back to
    [meta.instructions]. Production hot path supplies profile defaults;
    tests can keep the bare call.

    [?previous_turn_stop]: why this keeper's last turn in this process ended
    before completing, rendered as one line in the Autonomous Trigger layer.
    Omitted (the turn completed, failed, or this is the first turn since the
    process started), the layer says nothing about it.

    RFC-0315 wake-turn self-description:
    - [turn_decision]: the scheduler's actual cycle decision, required so the
      rendered wake reason matches the decision that fired the turn.
    - [current_task] renders the held task or its explicit missing/unavailable
      state. [No_current_task] omits the layer.
    - [?active_goal_summaries]: renders goal titles next to ids in the Active
      Goals layer, with a proof-pending annotation on [Verifying] goals
      (RFC-0387 stage 2). Omitted or empty: bare ids.
    - [?repository_freshness]: rows for the Repository Checkouts layer,
      measured by {!Keeper_sandbox_control.checkout_freshness_rows}. Omitted
      or empty, the layer is absent. *)

val build_prompt_preview :
  meta:Keeper_meta_contract.keeper_meta ->
  config:Workspace.config ->
  ?profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  ?task_skill_surfaces:(string * Keeper_skill_catalog.exact_surface list) list ->
  ?active_goal_summaries:goal_summary list ->
  ?repository_freshness:Keeper_sandbox_control.freshness_row list ->
  observation:Keeper_world_observation.world_observation ->
  unit ->
  turn_prompt_parts
(** Build a dashboard preview from current state without inventing a scheduler
    decision. Scheduler wake reasons are absent because no turn fired. *)

module For_testing : sig
  val board_event_fields :
    Keeper_world_observation.pending_board_event -> (string * string) list
  (** Structured Board observation immediately before prompt-field quoting. *)

  val scheduled_wake_fields :
    occurrence_id:string ->
    Keeper_event_queue.scheduled_wake ->
    (string * string) list
  (** Structured scheduled-wake observation immediately before prompt-field
      quoting. *)
end
