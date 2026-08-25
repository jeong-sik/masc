(** Canonical replay checkpoint projection and response-capture policy. *)

type replay_suffix_prune_reason

val replay_suffix_prune_reason_to_string :
  replay_suffix_prune_reason -> string

val consume_replay_response :
  suppress_visible_response:bool ->
  response_text:string ->
  consume:(response_text:string -> 'a) ->
  'a option

type wire_capture_response_suppression_reason

val wire_capture_response_suppression_reasons :
     control_checkpoint:bool
  -> terminal_effect_settled:bool
  -> wire_capture_response_suppression_reason list
(** [terminal_effect_settled] is the turn outcome saying the effect already
    reached the reader. It is a separate question from [control_checkpoint],
    which reads [stop_reason]: a turn whose effect a Gate replay settled before
    the model spoke still stops at [Completed] when the model answers in plain
    text, so only the outcome can tell that the visible text would be a second
    message about work already delivered. *)

val wire_capture_response_suppression_reason_label :
  wire_capture_response_suppression_reason -> string

val emit_wire_capture_response_suppressed_metrics :
  keeper_name:string -> wire_capture_response_suppression_reason list -> unit

val checkpoint_for_replay_persistence :
  history_messages:Agent_core.Types.message list ->
  session_id:string ->
  response_text:string ->
  ?suppress_visible_response:bool ->
  ?stop_reason:Runtime_agent.stop_reason ->
  exclude_thought_from_replay:bool ->
  Agent_core.Checkpoint.t ->
  (Agent_core.Checkpoint.t * replay_suffix_prune_reason option, string) result
(** [exclude_thought_from_replay] says this turn's wake cue and final text are
    an internal thought rather than conversation (RFC-0385). The caller reads it
    from the history source label the turn already carries, so nothing here
    inspects the text.

    A turn whose suffix records a ToolUse/ToolResult keeps that record and loses
    only the trailing Assistant note. A turn that called nothing leaves replay
    unchanged: its wake cue and note both go, because neither is something the
    next turn should read as dialogue. Direct turns pass [false] and behave
    exactly as before (RFC-0376 4.3). The argument is labelled and required so a
    new caller states which kind of turn it is finalizing. *)

val select_finalization_checkpoint :
  last_persisted_checkpoint:Agent_core.Checkpoint.t option ->
  Agent_core.Checkpoint.t ->
  Agent_core.Checkpoint.t * bool

val finalization_checkpoint_already_persisted :
  source_already_persisted:bool ->
  source:Agent_core.Checkpoint.t ->
  patched:Agent_core.Checkpoint.t ->
  replay_suffix_pruned:replay_suffix_prune_reason option ->
  bool
