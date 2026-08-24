(** The tool inventory as rows with its families shown.

    A hundred tools drawn as a flat list is a hundred rows an operator reads
    one at a time. The names already carry the grouping -- [masc_board_post]
    and [masc_board_list] are named as if they belong together -- so the rows
    say so. *)

type row =
  | Family of {
      name : string;
      count : int;
    }
      (** A heading for the tools that follow it. *)
  | Tool of Masc.Tui_decode.tool_entry

val family_of : string -> string option
(** The family a tool name puts it in: everything up to its second underscore.
    [None] for a name with fewer than three segments, which is a name that
    groups with nothing. *)

val rows : ?filter:string -> Masc.Tui_decode.tool_entry list -> row list
(** The given order, with a heading inserted wherever the family changes.

    A family is a prefix two or more of these tools share, not a list this
    build keeps: the names decide, so a family appears by being used twice and
    a prefix only one tool has is left as a plain row rather than made a
    heading over itself. The order is the caller's -- the server sorts by name,
    which is what puts a family's tools next to each other.

    [~filter] narrows the rows to tools whose name or description contains
    the substring, case-blind; the empty string (the default) is no filter.
    Headings and their counts are computed over what survived, so a count is
    always "what is shown", never "what exists". *)

val tool_count : row list -> int
(** How many of the rows are tools. What the header should say it is showing:
    the row count includes headings, which are not tools. *)
