(** Direct-turn prompt context prepared from one turn's observations. This is
    prompt-only data; it must never enter durable conversation history or grant
    permission to perform an effect. *)
type t

val prepare :
  active_goal_summaries:
    (Keeper_unified_prompt.goal_summary list, Goal_store.unavailable) result ->
  current_task:Keeper_world_observation_inputs.current_task_observation ->
  held_task_skills:Keeper_world_observation_inputs.held_task_skills list ->
  task_skill_surfaces:(string * Keeper_skill_catalog.exact_surface list) list ->
  workspace_memory:Workspace_memory_ledger.observation ->
  wiki_contents:Keeper_wiki_contents.t ->
  lane_updates:(Yojson.Safe.t, string) result ->
  approval_authority_text:string ->
  recent_direct_conversation_text:string ->
  worktree_text:string ->
  telemetry_feedback_text:string ->
  turn_instructions_text:string ->
  unit ->
  t
(** Eagerly render the common Goal, Task, Skills and Lane context once. The original
    conversation, approval observation, worktree, telemetry and instructions
    are retained with it. Memory and wiki observations are captured, while their
    retrieval routes remain request-specific. A new turn, changed observation or
    changed common prompt fragment needs a new preparation. No global cache or
    effect result is shared. *)

val project :
  t -> workspace_memory_access:Keeper_request_tool_access.t option -> string
(** Assemble the original common context with memory and wiki guidance rendered
    from this request's actual offered/discoverable Tools. [None] renders preview
    guidance; [Some access] never borrows another projection's route. Empty
    fragments are omitted, preserving all remaining bytes and separators.
    Projection neither reloads nor acknowledges the captured observations. *)

val project_partition :
  t -> workspace_memory_access:Keeper_request_tool_access.t option -> Keeper_context_layers.rendered
(** The same bytes as [project], with the captured Goal snapshot attributed to
    [Active_goals] so request assembly can keep it through the tool loop. *)
