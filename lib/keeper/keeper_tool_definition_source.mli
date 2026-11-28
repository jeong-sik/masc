(** Which file a tool's definition was read from.

    A tool that behaved unexpectedly is one an operator wants to open. A
    shipped tool is defined by a TOML asset. The post-tool log line and the
    tool-call inspector both name that file, and both ask here, so the two
    give one answer. *)

val resolve : string -> string option
(** [resolve tool_name] is the file the tool's definition came from,
    relative to the masc directory: ["tools/<name>.toml"]. [None] means no
    file under [tools/] ships under that name — an answer, not a failure to
    look. *)

val annotate_row : Yojson.Safe.t -> Yojson.Safe.t
(** Add [definition_source] to one tool-call log row, read from its ["tool"]
    field. Rows that are not objects, carry no tool name, or name a tool no
    file ships come back untouched — an absent field says "no file ships this", which is
    what a reader needs to distinguish from a file it failed to find.

    Derived on read rather than written onto the row: the path is a fact
    about the name, so rows written before this projection existed answer it
    too, and a definition that moves answers where it is now. *)
