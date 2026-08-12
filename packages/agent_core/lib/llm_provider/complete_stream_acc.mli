(** Sequential shell around {!Complete_stream_state}.

    A stream reader owns one accumulator and feeds it events in wire order. The
    shell mutates only the pointer to the current immutable snapshot; all stream
    decisions and final projection live in the pure state module. *)

type stream_acc

(** Create a shell owning the empty immutable stream snapshot. *)
val create_stream_acc : unit -> stream_acc

(** [true] after the first typed provider or wire failure. *)
val stream_failed : stream_acc -> bool

(** Resolve one event into a new immutable snapshot and install it as the
    shell's current state. *)
val accumulate_event : stream_acc -> Types.sse_event -> unit

(** Project the current snapshot into the existing provider-facing result
    contract. *)
val finalize_stream_acc : stream_acc -> (Types.api_response, Types.stream_error) result
