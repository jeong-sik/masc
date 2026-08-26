(** Sequential shell around the canonical pure stream state.

    A stream reader owns one accumulator and feeds it events in wire order. The
    shell mutates only the pointer to the current immutable snapshot; all stream
    decisions and final projection live in the pure state module. *)

type stream_acc

(** Create a shell owning the empty immutable stream snapshot. *)
val create_stream_acc : unit -> stream_acc

(** [true] after the first typed provider or wire failure. *)
val stream_failed : stream_acc -> bool

(** The first typed failure captured by the canonical state machine. *)
val failure : stream_acc -> Types.stream_error option

(** Resolve and install one raw event, returning the canonical projection
    decision for live/durable consumers. *)
val resolve_event : stream_acc -> Types.sse_event -> Types.stream_event_resolution

(** Assembly-only compatibility API. Resolve one event into a new immutable
    snapshot and install it as the shell's current state. Live projection must
    use {!resolve_event}. *)
val accumulate_event : stream_acc -> Types.sse_event -> unit

(** Project the current snapshot into the existing provider-facing result
    contract. *)
val finalize_stream_acc : stream_acc -> (Types.api_response, Types.stream_error) result
