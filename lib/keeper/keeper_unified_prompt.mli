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
  world_state : string;
  world_partition : Keeper_context_layers.rendered;
      (** The "## Current World State" observation frame, rebuilt fresh
          every turn. Inject as per-turn [dynamic_context]; never append
          to the persisted message history. *)
  user_message : string;
      (** Current user-turn input. Operator utterances are durable. An
          answered Ask carries its attributed answer here so it survives
          subsequent tool rounds and checkpoint reloads. An autonomous
          continuation uses the fleet wake prompt, which is also
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

(** Whether the task that admitted this turn (its Current Task) is linked to
    the goal. Other tasks the keeper holds do not mark goals.
    [Held_task_link_unreadable]: the keeper holds a task but neither the
    goal-task link registry nor its recovery copy could be read, so the answer
    is unknown. A turn with no held task is [Not_served_by_held_task] for
    every goal. *)
type held_task_link =
  | Served_by_held_task
  | Not_served_by_held_task
  | Held_task_link_unreadable

(** Stored criterion and review note travel with the goal, so the model can
    pursue its success conditions without a second read. [summary_criterion]
    and [summary_phase] are options for a caller that states a summary
    directly; {!active_goal_summaries} always fills both from the store.
    RFC-0387 stage 2 carries the phase so a [Verifying] goal renders annotated
    in the Active Goals layer — the gate must not make the goal disappear from
    the keeper (review P0-1). *)
type goal_summary = {
  summary_goal_id : string;
  summary_title : string;
  summary_phase : Goal_phase.t option;
  summary_criterion : Goal_store.criterion option;
  summary_review_note : string option;
  summary_held_task_link : held_task_link;
}

val active_goal_summaries :
  config:Workspace.config ->
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  (goal_summary list, Goal_store.unavailable) result
(** Every Goal still open enough to progress. [Error] is the typed store
    failure (RFC-0444 §2.3 row 6); the Active Goals layer renders it with
    reason, file, mirror and reset step.

    A Goal is shared intent and names no keeper, so every turn carries the
    same Goals, with or without a held task. [current_task] only sets
    [summary_held_task_link] from the link registry (recovery copy included,
    read only when a task is held and a Goal is open); it never removes a
    Goal. {!Goal_phase.admits_self_directed_progress} decides which
    Goals stay -- [Verifying] stays in (the gate holds the phase, not the work)
    and terminal phases drop out. An unreadable primary returns [Error]
    without using or repairing the recovery copy. *)

val build_system_prompt :
  meta:Keeper_meta_contract.keeper_meta ->
  config:Workspace.config ->
  ?profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  unit ->
  (string, World_constitution_store.read_error) result
(** Build the model-facing stable Keeper contract shared by direct and
    autonomous turns. Channel-specific input belongs in dynamic context or the
    persisted user message, not in a second system-prompt implementation.

    [config] is the caller-owned workspace generation admitted for the turn.
    Prompt construction never resolves a second default config.

    The world's constitution articles are part of the contract. A world with
    no ledger yet renders none. A ledger that exists but cannot be read is
    [Error]: the prompt is not built without its articles (#38354). When
    [?profile_defaults] is omitted, [instructions] falls back to
    [meta.instructions]. *)

val emit_prompt_metrics :
  meta:Keeper_meta_contract.keeper_meta ->
  system_prompt:string ->
  turn_prompt_parts ->
  unit
(** Publish the per-segment byte gauges and the instruction hash after an
    autonomous request has been assembled using its offered tool surface.
    Inputs are the request's system prompt, projected world state and model
    message, not the pre-tool source placeholder. This observes prepared input,
    not provider delivery; omitted post-tool context does not replace it. *)

type prepared_prompt
(** Complete immutable common world text/digests owned by one preparation call.
    A new turn or world snapshot requires a new product. *)

val prepare_prompt :
  turn_decision:Keeper_world_observation.keeper_cycle_decision ->
  ?previous_turn_stop:Keeper_turn_checkpoint_reason.t ->
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  ?task_skill_surfaces:(string * Keeper_skill_catalog.exact_surface list) list ->
  ?active_goal_summaries:(goal_summary list, Goal_store.unavailable) result ->
  ?workspace_memory:Workspace_memory_ledger.observation ->
  ?wiki_contents:Keeper_wiki_contents.t ->
  ?lane_updates:(Yojson.Safe.t, string) result ->
  ?repository_freshness:Keeper_sandbox_control.freshness_row list ->
  observation:Keeper_world_observation.world_observation ->
  unit -> prepared_prompt
(** Render common layers, frame provenance and durable user input once from
    this exact turn's data and prompt fragments. No process-global cache or
    permission result is retained. Tool-dependent layers are deferred to
    {!project_prompt}; new preparations observe current inputs/fragments. *)

val project_prompt :
  prepared_prompt ->
  ?workspace_memory_access:Keeper_request_tool_access.t ->
  ?own_recent_actions:(Keeper_own_recent_actions.turn list, Keeper_tool_call_log.index_error) result ->
  ?recent_work:Keeper_recent_work.transmission ->
  unit -> turn_prompt_parts
(** Reassemble canonical ordered spans from the captured common layers and
    this request's memory/wiki access, recent-action projection and actual
    recent-work transmission. Omitted recent actions use the captured source;
    omitted recent work is absent. Shared products are immutable and can be
    projected concurrently; caller-owned effects such as artifact publication
    remain on the actual offered-tool path. User input retains the original
    answered Ask; the transient world frame never becomes conversation input. *)

(** Build the per-turn channels of the unified prompt: the observation frame
    and the user message. The system prompt is not built here; the turn sends
    the one {!Keeper_run_context.prepare_run_context} built.

    @param observation Current world snapshot *)
val build_prompt :
  turn_decision:Keeper_world_observation.keeper_cycle_decision ->
  ?previous_turn_stop:Keeper_turn_checkpoint_reason.t ->
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  ?task_skill_surfaces:(string * Keeper_skill_catalog.exact_surface list) list ->
  ?active_goal_summaries:(goal_summary list, Goal_store.unavailable) result ->
  ?workspace_memory:Workspace_memory_ledger.observation ->
  ?workspace_memory_access:Keeper_request_tool_access.t ->
  ?wiki_contents:Keeper_wiki_contents.t ->
  ?lane_updates:(Yojson.Safe.t, string) result ->
  ?repository_freshness:Keeper_sandbox_control.freshness_row list ->
  ?recent_work:Keeper_recent_work.transmission ->
  observation:Keeper_world_observation.world_observation ->
  unit ->
  turn_prompt_parts
(** [?previous_turn_stop]: why this keeper's last turn in this process ended
    before completing, rendered as one line in the Autonomous Trigger layer.
    Omitted (the turn completed, failed, or this is the first turn since the
    process started), the layer says nothing about it.

    RFC-0315 wake-turn self-description:
    - [turn_decision]: the scheduler's actual cycle decision, required so the
      rendered wake reason matches the decision that fired the turn.
    - [current_task] renders the held task or its explicit missing/unavailable
      state. [No_current_task] omits the layer.
    - [?active_goal_summaries]: the Active Goals layer, with a proof-pending
      annotation on [Verifying] goals (RFC-0387 stage 2), a [yours]
      annotation on goals the held task serves, and an unknown-link
      annotation on every goal when the link registry cannot be read. These
      are the workspace's open goals ({!active_goal_summaries}). Omitted or
      [Ok []], the layer is absent when the world Goal source is available.
      [Error] is the typed store failure ({!Goal_store.unavailable}, RFC-0444
      §2.3 row 6): a failed world or summary source renders its reason,
      file, mirror and reset step without blocking other context.
    - [?recent_work]: recent attributed conversation and the latest autonomous
      conclusion, read from the selected Keeper trace. Historical context only;
      missing history and unavailable sources do not infer work completion.
    - [?repository_freshness]: rows for the Repository Checkouts layer,
      measured by {!Keeper_sandbox_control.checkout_freshness_rows}. Omitted
      or empty, the layer is absent.
    - [?wiki_contents]: the Wiki layer, {!format_wiki_observation} with the
      request's [?workspace_memory_access]. Omitted, the layer is absent. *)

val build_prompt_preview :
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  ?task_skill_surfaces:(string * Keeper_skill_catalog.exact_surface list) list ->
  ?active_goal_summaries:(goal_summary list, Goal_store.unavailable) result ->
  ?workspace_memory:Workspace_memory_ledger.observation ->
  ?workspace_memory_access:Keeper_request_tool_access.t ->
  ?wiki_contents:Keeper_wiki_contents.t ->
  ?lane_updates:(Yojson.Safe.t, string) result ->
  ?repository_freshness:Keeper_sandbox_control.freshness_row list ->
  ?recent_work:Keeper_recent_work.transmission ->
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

type answered_ask_turn_input = {
  ask_id : string;
  evidence_fingerprint : string;
  text : string;
  answered_by : Keeper_input_speaker.person;
}

val answered_ask_evidence_fingerprint :
  Keeper_world_observation.answered_ask_input -> string
(** Canonical answer fingerprint derived from [ask_id], [answered_at], and
    canonical [answers], independent of prompt-row rendering changes. *)

val answered_ask_inputs :
  Keeper_world_observation.world_observation ->
  answered_ask_turn_input list
(** Ask correlation identity, canonical answer fingerprint, quoted canonical
    question/answer input with its original Task/Goal/context, and who answered.
    This is the ordinary durable user turn's copy; transient Board context
    excludes it. Original bindings are historical data and never replace current
    Task/Goal ownership. Excludes all other world observations. *)

val autonomous_input_speaker :
  Keeper_world_observation.world_observation -> Keeper_input_speaker.t
(** The speaker of the autonomous turn's User message: the host's wake cue,
    naming who answered each quoted Ask row in the order the rows appear. *)

val format_workspace_memory_observation :
  ?access:Keeper_request_tool_access.t ->
  Workspace_memory_ledger.observation -> string option
(** Discovery metadata and the actual request's retrieval route only.
    Without [access], render an operator preview with no callable-route claim.
    Captured proposal facts are not injected or compared with current memory.
    Read failures carry no model-facing IO text. *)

val format_wiki_observation :
  ?access:Keeper_request_tool_access.t -> Keeper_wiki_contents.t -> string option
(** The wiki table of contents: one line per file, then the actual request's
    route to [keeper_wiki_read]. Without [access], render an operator preview
    with no callable-route claim. [Off] and [Listed \[\]] render nothing.
    [Unlisted] renders a fixed line with no model-facing IO text. Page bodies
    are never included. *)
