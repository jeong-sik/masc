(** The two tool tables on the Tools surface, described once.

    Each wrote its header with one format string and its rows with another, so
    the two agreed only by hand -- and the catalog's did not: the header
    indented three cells and named a 32-cell column, the rows indented six and
    filled 30, which drew DIRECT one cell left of the readings under it and
    SURFACES one cell left of theirs. Both tables also padded the tool name
    without ever cutting it, and an MCP tool name runs past fifty cells, so on
    every row carrying one the later columns moved with it.

    The header and the rows are drawn from one description here, through
    {!Masc_tui_table}, which is what keeps them at the same offsets. The last
    column of each table is the one reading with no widest form and is left to
    the frame: nothing follows it that a long one could push, and
    [box_line_styled] cuts what will not fit. *)

val effective_tool_header : string
(** [TOOL] over the selected Keeper's turn surface, then [ORIGIN]. *)

val effective_tool_line : name:string -> origin:string -> string
(** One tool on that surface. [origin] is the free last column. *)

val catalog_tool_header : string
(** [TOOL DIRECT] over the process-wide catalog, then [SURFACES]. *)

val catalog_tool_line :
  metadata:string -> name:string -> direct:string -> surfaces:string -> string
(** One registered tool. [metadata] dresses the two columns that answer about
    the tool rather than the name being answered about: a tool on no surface is
    unreachable, and [surfaces] is the column that says so. *)

val skill_usage_name_indent : string
(** Skill usage stacks rather than columns: a skill's keepers do not fit beside
    its name, so they are on the line below at {!skill_usage_keeper_indent}.
    The header names each reading where the reading stands. *)

val skill_usage_keeper_indent : string
