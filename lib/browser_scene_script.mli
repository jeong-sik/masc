(** Fixed DOM observation and reference resolver, shared with the extension. *)
val runtime : string
(** The body a read runs after [runtime] is defined; [arguments[0]] is the
    scene arguments. *)
val read_call : string

(** [runtime] followed by [read_call]. *)
val read : string

(** A fixed page script as one JavaScript function of one argument. The
    function defines [runtime], runs [body] with that argument as
    [arguments[0]], and answers the JSON text of what [body] returned, or
    the length of that text in UTF-16 units when it is longer than
    [answer_limit_units]. A connection whose reply has a size limit passes
    the most it can carry. *)
val page_function : answer_limit_units:int -> string -> string
