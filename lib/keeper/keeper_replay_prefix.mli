(** Typed replay-prefix contract shared by dispatch, provider retry inspection,
    and checkpoint persistence.

    A media-degraded provider receives a projected dispatch prefix, while the
    durable checkpoint must retain the canonical pre-turn prefix.  This pure
    module is the single authority for splitting and restoring those prefixes. *)

type prefix_mismatch =
  | Prefix_longer_than_messages
  | Prefix_message_mismatch

type restore_error
type projection

(** No dispatch projection was applied. *)
val unchanged : projection

(** Record the exact canonical and projected prefixes used for a
    media-degraded dispatch. *)
val media_degraded :
  canonical_prefix:Masc_agent_core.Types.message list ->
  dispatch_prefix:Masc_agent_core.Types.message list ->
  projection

(** Split [messages] after an exact structural [prefix]. *)
val split :
  prefix:Masc_agent_core.Types.message list ->
  Masc_agent_core.Types.message list ->
  (Masc_agent_core.Types.message list, prefix_mismatch) result

(** Restore a projected provider checkpoint to its canonical replay prefix.
    An unchanged projection is returned verbatim.  A media-degraded projection
    accepts either an already-canonical checkpoint or the exact dispatch prefix
    and fails explicitly for every other checkpoint. *)
val restore_messages :
  projection ->
  Masc_agent_core.Types.message list ->
  (Masc_agent_core.Types.message list, restore_error) result

val restore_checkpoint :
  projection ->
  Masc_agent_core.Checkpoint.t ->
  (Masc_agent_core.Checkpoint.t, restore_error) result

val restore_error_to_string : restore_error -> string
