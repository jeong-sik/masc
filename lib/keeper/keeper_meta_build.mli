(** Keeper_meta_build — pure construction of the initial [keeper_meta].

    No I/O, no config reads, no mutation: every non-deterministic input is a
    parameter. Callers own the effects — [created_at] is the caller's clock
    reading (used for both [created_at] and [updated_at]), [now_ts] the epoch
    counterpart for runtime bookkeeping, [keeper_uid] a freshly generated uid,
    [generation] the per-(keeper, trace) counter, [compaction_mode] the
    config-resolved default. Keeping this a total pure function lets the boot
    create path and a create-without-boot path share one metadata shape. *)

val initial_meta :
  name:string ->
  agent_name:string ->
  persona_extended:string ->
  goal:string ->
  instructions:string ->
  sandbox_profile:Keeper_types_profile.sandbox_profile ->
  network_mode:Keeper_types_profile.network_mode ->
  multimodal_policy:Keeper_types_profile.multimodal_policy ->
  allowed_paths:string list ->
  mention_targets:string list ->
  proactive_enabled:bool ->
  compaction_profile:string ->
  compaction_mode:Keeper_config.compaction_mode ->
  compaction_ratio_gate:float ->
  compaction_message_gate:int ->
  compaction_token_gate:int ->
  compaction_cooldown_sec:int ->
  auto_handoff:bool ->
  handoff_threshold:float ->
  handoff_cooldown_sec:int ->
  created_at:string ->
  max_context_override:int option ->
  active_goal_ids:string list ->
  autoboot_enabled:bool ->
  telemetry_feedback_enabled:bool option ->
  telemetry_feedback_window_hours:int option ->
  always_allow:bool option ->
  now_ts:float ->
  generation:int ->
  trace_id:Keeper_id.Trace_id.t ->
  keeper_uid:Keeper_id.Uid.t ->
  oas_env:(string * string) list ->
  unit ->
  Keeper_meta_contract.keeper_meta
