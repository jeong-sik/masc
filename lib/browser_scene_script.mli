(** Fixed DOM observation and reference resolver, shared with the extension. *)
val runtime : string
(** The body a read runs after [runtime] is defined; [arguments[0]] is the
    scene arguments. *)
val read_call : string

(** [runtime] followed by [read_call]. *)
val read : string
