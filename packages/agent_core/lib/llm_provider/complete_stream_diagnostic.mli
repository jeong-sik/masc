(** Append a refused frame when [MASC_WIRE_PARSE_DUMP] names a nonempty path.
    Redacts the full frame before writing, retaining the original byte count
    and whether redaction changed the payload. [Sys_error] does not replace
    the stream failure; other exceptions retain their existing behavior. *)
val dump_refused_frame : Complete_stream_error.refused_frame -> unit
