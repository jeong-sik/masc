(** Shared streaming decoder for exec-shim stderr control frames. Payload
    bytes retain their order; only the acceptance frame and final trailer are
    removed. The undecided suffix starts at the second-to-last RS (or the
    only RS). The wire has no trailer-size bound: observations and ambiguous
    payload bytes after an RS are retained in full until later delimiters or
    termination resolve them. Payload without an RS is delivered promptly.

    This preserves the protocol's last-pair semantics. A payload-authored
    final RS pair can look like a trailer; this decoder does not authenticate
    it. When the final suffix cannot be split into a trailer, the finite and
    interactive remote callers preserve it through their normal stderr
    delivery. It may contain
    control-looking bytes: discarding them would also discard
    indistinguishable payload bytes. This is not a valid receipt; callers
    still validate the actual transport outcome and completion. *)
type t

val create :
  ?callback:(string -> unit) -> acceptance_frame:bool ->
  on_accepted:(unit -> unit) -> unit -> t
val stream_chunk : t -> string -> unit
(** Advance control-frame retention for the entire received chunk before
    invoking payload callbacks. Callback exceptions still propagate; a caller
    that deliberately continues after one cannot lose already-received control
    bytes from that same chunk. *)
val settle_head : t -> unit
val tail : t -> string
(** Materialize the exact retained suffix. Repeated reads reuse it until
    another stream chunk or payload flush changes the decoder. *)
val flush_payload : t -> string -> unit
val split_final_trailer : string -> (string * string, string) result
