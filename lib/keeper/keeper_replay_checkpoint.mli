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
  ?stop_reason:Runtime_agent.stop_reason ->
  Agent_core.Checkpoint.t ->
  (Agent_core.Checkpoint.t * replay_suffix_prune_reason option, string) result

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
