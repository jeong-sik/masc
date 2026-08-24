(** The tool inventory as rows: domain headings, family headings, tool rows.

    A hundred tools drawn as a flat list is a hundred rows an operator reads
    one at a time. The names carry a spelling-level grouping, and spelling is
    a poor proxy for purpose -- the task tools spread across five families
    and two family-less names -- so a domain layer says what the tools are
    for above what they are called. *)

type row =
  | Domain of {
      name : string;
      count : int;
    }
      (** What the tools under it are for. [count] is the tools in the
          domain, not the families. *)
  | Family of {
      name : string;
      count : int;
    }
      (** A heading for the tools that follow it. *)
  | Tool of Masc.Tui_decode.tool_entry

val domain_of_tool : string -> string option
(** The domain a tool name puts it in -- one rule per domain, matched on the
    name; [None] for a name no rule claims, which surfaces as [unsorted]
    rather than silently borrowing a neighbour's domain. *)

val family_of : string -> string option
(** The family a tool name puts it in: everything up to its second underscore.
    [None] for a name with fewer than three segments, which is a name that
    groups with nothing. *)

val rows : Masc.Tui_decode.tool_entry list -> row list
(** Tools in a fixed domain order (board, work, run, keeper ops, keeper
    self, system, unsorted), name order within a domain, with a domain
    heading wherever the domain changes and a family heading wherever the
    family changes. Unlike the family layer, a domain heading appears over a
    single tool: grouping is the domain's job, so a family of one stays a
    plain family row rather than being dissolved. *)

val tool_count : row list -> int
(** How many of the rows are tools. What the header should say it is showing:
    the row count includes headings, which are not tools. *)
