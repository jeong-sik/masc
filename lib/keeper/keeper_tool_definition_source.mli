(** Which file a tool's definition was read from.

    A tool that behaved unexpectedly is one an operator wants to open, and
    "which file do I open" has two answers depending on how the tool got
    here: a shipped descriptor is a TOML asset, and a composition tool is a
    fence inside the [SKILL.md] the catalog read to create it. Neither
    lookup answers for the other, so every reader that wants the file has
    had to try both in order.

    The post-tool log line has done exactly that since it started naming the
    definition, and the tool-call inspector wanted the same answer. Two
    copies of a two-step fallback drift on the step one of them forgets, so
    the order lives here once. *)

val resolve : string -> string option
(** [resolve tool_name] is the file the tool's definition came from,
    relative to the masc directory: ["tools/<name>.toml"] for a shipped
    descriptor, ["skills/<name>/SKILL.md"] for a composition materialised
    from a skill. [None] is a built-in, which ships no file — an answer, not
    a failure to look. *)

val annotate_row : Yojson.Safe.t -> Yojson.Safe.t
(** Add [definition_source] to one tool-call log row, read from its ["tool"]
    field. Rows that are not objects, carry no tool name, or name a built-in
    come back untouched — an absent field says "no file ships this", which is
    what a reader needs to distinguish from a file it failed to find.

    Derived on read rather than written onto the row: the path is a fact
    about the name, so rows written before this projection existed answer it
    too, and a definition that moves answers where it is now. *)
