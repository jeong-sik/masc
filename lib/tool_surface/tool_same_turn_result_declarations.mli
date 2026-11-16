(** Which built-in tools declare that a result repeating an earlier result of
    the same turn may leave as a pointer to the first one (RFC-0510 D6).

    The declaration lives in each tool's own [config/tools/<name>.toml] as
    [same_turn_result_stub = true], next to [defer_loading]. This module only
    reads the files; it holds no list of its own. A file without the key
    declares {!Tool_definition_toml.Repeat_sent_whole}, which is what every
    tool did before the key existed.

    A file that does not parse raises on first ask, for the reason
    {!Tool_loading_declarations} gives: a misplaced key and no key are the
    same answer at every call site. *)

(** [declared name] is what [config/tools/<name>.toml] declares, or [None]
    when there is no such file. *)
val declared : string -> Tool_definition_toml.same_turn_result option

(** The names of the tool files that declare
    {!Tool_definition_toml.Repeat_sent_as_pointer}, sorted. It is a report of
    the files, read by the descriptor lookup that turns file names into the
    names a model calls and by the test that checks every such file belongs
    to a descriptor. *)
val sent_as_pointer : unit -> string list
