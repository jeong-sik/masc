(** Immutable state for the turn-local durable media collector.
    Configuration lookup, diagnostic output and persistence belong to its owner. *)

type t

type finalized = {
  index : int;
  media_type : string;
  source : Llm_provider.Types.media_source;
}

type wire_drop = {
  media_type : string;
  encoded_bytes : int;
  max_wire_bytes : int;
}

type completed =
  | Persistable of finalized
  | Wire_dropped of wire_drop

type metadata_drift = {
  index : int;
  expected_media_type : string;
  received_media_type : string;
  expected_source_type : Agent_core.Types.media_source_kind;
  received_source_type : Agent_core.Types.media_source_kind;
}

type pending_media
(** One captured active block, including the turn's frozen wire cap. *)

type terminal =
  | Stop_reason of Agent_core.Types.stop_reason
  | Message_stop

type event_result =
  | Unchanged
  | Updated of t
  | Metadata_drift of metadata_drift
  | Wire_rejected of int * wire_drop
  | Finalize of pending_media list * terminal option
(** [Metadata_drift] only reports a warning. [Wire_rejected] must warn before
    recording a drop and rejecting that index. Apply both changes to the owner's
    current state after the warning, which may have invoked an observer.

    [Finalize] captures blocks in completion order. Finalize, record and close
    each block before moving to the next, then publish the terminal if present.
    [None] means a single content-block stop without a message phase change. *)

val create : max_wire_bytes:int -> t
val start_runtime_attempt : t -> t
val enter_stream_scope : t -> int -> t
(** Publish scope entry before evaluating the event or emitting its diagnostic. *)

val on_event : t -> Agent_core.Types.sse_event -> event_result
val finalize_media : pending_media -> (finalized, int * wire_drop) result
(** Return one captured block's accumulated source, or retain its index and
    wire-cap refusal. *)

val record_completed : t -> completed -> t
val close_block : t -> int -> t
val reject_block : t -> int -> t
val finish_message : t -> terminal -> t
val completed : t -> completed list
(** Completed values in stream completion order, without draining the state. *)
