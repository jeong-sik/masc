(** Keeper_rollover — OAS handoff rollover logic.

    When a keeper's context ratio exceeds the handoff threshold
    and cooldown has elapsed, a new session is created with the
    current context carried forward to the next generation.

    Extracted from [Keeper_exec_context] as part of #4955 god-file split. *)

(** Outcome of [maybe_rollover_oas_handoff].
    [updated_meta] reflects post-rollover state when the rollover
    succeeded; otherwise it equals the input [meta] (with the
    generation possibly synced to the checkpoint).
    [handoff_json] carries the legacy MASC handoff envelope. *)
type handoff_rollover =
  { updated_meta : Keeper_types.keeper_meta
  ; handoff_json : Yojson.Safe.t option
  ; attempted : bool
  ; failure_reason : string option
  ; context_ratio : float
  ; context_tokens : int
  ; context_max : int
  ; message_count : int
  }

(** Returns [true] when [blocker] matches any provider-specific
    context-overflow string (GLM / OpenAI / Ollama / Anthropic
    wording). Pure — exposed for unit testing. *)
val blocker_indicates_overflow : string -> bool

(** Verdict from [classify_rollover_gate]; [Skip] carries a stable
    skip reason, [Go] carries the trigger reason that will appear
    in the handoff envelope. *)
type rollover_gate_decision =
  | Skip of string
  | Go of string

(** Append lineage telemetry artifacts; logs and swallows non-cancel
    exceptions (rollover succeeds even if lineage append fails). *)
val append_lineage_artifacts_best_effort :
  config:Coord.config ->
  parent:Keeper_types.keeper_meta ->
  child:Keeper_types.keeper_meta ->
  parent_trace_id:string ->
  trigger_reason:string ->
  context_ratio:float ->
  model:string ->
  unit

(** Classify the rollover gate without side effects. The [signal_gate]
    branch fires on a current-turn or last-turn provider overflow
    blocker even when the [ratio_gate] structurally cannot fire after
    compaction (umbrella #7036). *)
val classify_rollover_gate :
  auto_handoff:bool ->
  cooldown_elapsed:bool ->
  ratio:float ->
  handoff_threshold:float ->
  last_outcome:Keeper_types.proactive_cycle_outcome ->
  last_blocker:string ->
  ?current_turn_overflow_blocker:string option ->
  unit ->
  rollover_gate_decision

(** Attempt an OAS handoff rollover when the gate fires. Always
    returns a [handoff_rollover] — [attempted=false] when the gate
    skipped, [attempted=true; handoff_json=Some _] on success, and
    [attempted=true; failure_reason=Some _] on save failure. *)
val maybe_rollover_oas_handoff :
  on_started:(unit -> unit) ->
  base_dir:string ->
  meta:Keeper_types.keeper_meta ->
  model:string ->
  primary_model_max_tokens:int ->
  current_turn_overflow_blocker:string option ->
  checkpoint:Agent_sdk.Checkpoint.t option ->
  handoff_rollover
