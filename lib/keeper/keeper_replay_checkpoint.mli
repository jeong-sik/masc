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
  control_checkpoint:bool -> wire_capture_response_suppression_reason list

val wire_capture_response_suppression_reason_label :
  wire_capture_response_suppression_reason -> string

val emit_wire_capture_response_suppressed_metrics :
  keeper_name:string -> wire_capture_response_suppression_reason list -> unit

val checkpoint_for_replay_persistence :
  history_messages:Agent_sdk.Types.message list ->
  session_id:string ->
  response_text:string ->
  ?stop_reason:Runtime_agent.stop_reason ->
  Agent_sdk.Checkpoint.t ->
  (Agent_sdk.Checkpoint.t * replay_suffix_prune_reason option, string) result

val select_finalization_checkpoint :
  last_persisted_checkpoint:Agent_sdk.Checkpoint.t option ->
  Agent_sdk.Checkpoint.t ->
  Agent_sdk.Checkpoint.t * bool

val finalization_checkpoint_already_persisted :
  source_already_persisted:bool ->
  source:Agent_sdk.Checkpoint.t ->
  patched:Agent_sdk.Checkpoint.t ->
  replay_suffix_pruned:replay_suffix_prune_reason option ->
  bool
