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
    column of the other tables is the one reading with no widest form and is
    left to the frame: nothing follows it that a long one could push, and
    [box_line_styled] cuts what will not fit. The catalog's last column is the
    flexible column of {!Masc_tui_table.fit} instead, because its counts
    leave when the line is too narrow for them. *)

val effective_tool_header : string
(** [TOOL] over the selected Keeper's turn surface, then [ORIGIN]. *)

val effective_tool_line : name:string -> origin:string -> string
(** One tool on that surface. [origin] is the free last column. *)

(** What the server counted about one tool's calls, as the catalog row draws
    it. Three answers, because "no counts were sent" and "counts were sent and
    this tool has none" are different facts and one zero cannot say both. *)
type usage_reading =
  | Usage_unread
      (** The server sent no per-tool counts, so no tool has an answer. *)
  | Never_called
      (** Counts were sent and this tool has no row in them. *)
  | Called of { calls : int; failures : int; p95_ms : float option }

val catalog_tool_header : width:int -> string
(** [TOOL CALLS FAIL P95 DIRECT SURFACES] over the process-wide catalog.
    [width] is the cells the line has, indent included. [SURFACES] keeps the
    width it had at 80 columns before the counts were read, so when the line
    cannot hold every column [P95] goes first, then [FAIL], then [CALLS], and
    at 80 columns the table is [TOOL DIRECT SURFACES] as it was. *)

val catalog_tool_line :
  width:int ->
  metadata:string ->
  name:string ->
  direct:string ->
  usage:usage_reading ->
  surfaces:string ->
  string
(** One registered tool, on the columns {!catalog_tool_header} names at the
    same [width]. [metadata] dresses the two columns that answer about the tool
    rather than the name being answered about: a tool on no surface is
    unreachable, and [surfaces] is the column that says so. A tool with
    failures says so in the [FAIL] reading and nowhere else on the row. *)

val skill_usage_keeper_header : string
(** The column names over the keeper rows below one skill. *)

val skill_usage_keeper_line :
  keeper:string ->
  invocations:int ->
  deliveries:int ->
  actions:int ->
  last_used:string ->
  string
(** One keeper's use of one skill: who, how many times it was triggered, how
    many of those were delivered, what the model did after, and when it last
    ran. The counts are right-aligned so one keeper and six read down the same
    columns. *)
