module Table = Masc_tui_table
module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme

let effective_tool_name_width = 34
let catalog_tool_name_width = 32
let catalog_direct_width = 8

(* Catalog rows sit under a domain and a family heading, indented past both so
   the tree reads. The column header carries that same indent or it names
   columns the readings below do not start in, which is what it did. *)
let catalog_row_indent = "      "
let effective_row_indent = "   "

(* A keeper that ran a skill, in columns: who, then the three counts that
   say what came of it, then when it last ran. The counts are narrow and
   right-aligned so a skill with one keeper and one with six read down the
   same columns. *)
let skill_usage_keeper_name_width = 22
let skill_usage_count_width = 9

let skill_usage_keeper_cells ~keeper ~invocations ~deliveries ~actions =
  [ Table.cell ~header:"KEEPER" ~width:skill_usage_keeper_name_width keeper
  ; Table.cell ~align:Table.Right ~header:"TRIGGERED"
      ~width:skill_usage_count_width invocations
  ; Table.cell ~align:Table.Right ~header:"DELIVERED"
      ~width:skill_usage_count_width deliveries
  ; Table.cell ~align:Table.Right ~header:"ACTIONS"
      ~width:skill_usage_count_width actions
  ]

let effective_tool_cells name =
  [ Table.cell ~header:"TOOL" ~width:effective_tool_name_width name ]

type usage_reading =
  | Usage_unread
  | Never_called
  | Called of { calls : int; failures : int; p95_ms : float option }

(* A catalog row's columns, in the order they are drawn. The counts sit beside
   the name they count; the two columns that say where the tool can be reached
   stay behind them. *)
type catalog_column =
  | Col_name
  | Col_calls
  | Col_failures
  | Col_p95
  | Col_direct
  | Col_surfaces

let catalog_columns =
  [ Col_name; Col_calls; Col_failures; Col_p95; Col_direct; Col_surfaces ]

(* [compact_count] holds a count to six cells through ninety-nine billion and
   [elapsed_text] holds a duration to six, so a reading never folds in its
   column: a count cut at either end is a wrong count. *)
let catalog_reading_width = 6

(* What SURFACES had at eighty columns before the counts: the cells the frame
   left it after TOOL and DIRECT. It is the floor, so the counts take only
   room beyond it and an eighty-column terminal draws the table it drew. *)
let catalog_surfaces_floor = 30

(* Nothing was sent for this reading. A zero would say the tool was fast or
   never failed. *)
let unread_reading = "--"

let catalog_column_width = function
  | Col_name -> catalog_tool_name_width
  | Col_calls | Col_failures | Col_p95 -> catalog_reading_width
  | Col_direct -> catalog_direct_width
  | Col_surfaces -> catalog_surfaces_floor

let catalog_column_header = function
  | Col_name -> "TOOL"
  | Col_calls -> "CALLS"
  | Col_failures -> "FAIL"
  | Col_p95 -> "P95"
  | Col_direct -> "DIRECT"
  | Col_surfaces -> "SURFACES"

let catalog_column_align = function
  | Col_calls | Col_failures | Col_p95 -> Table.Right
  | Col_name | Col_direct | Col_surfaces -> Table.Left

let catalog_column_fold = function
  | Col_surfaces -> Table.Fold_tail
  | Col_name | Col_calls | Col_failures | Col_p95 | Col_direct ->
      Table.Fold_middle

(* The columns a line of [width] cells draws, the indent counted in it. The
   counts go before SURFACES shrinks below its floor: P95 first, FAIL next,
   CALLS last, and the table is TOOL DIRECT SURFACES again. *)
let catalog_layout ~width =
  let inner_width = max 0 (width - String.length catalog_row_indent) in
  Table.fit ~inner_width ~width:catalog_column_width ~flex:Col_surfaces
    ~drop_order:[ Col_p95; Col_failures; Col_calls ] catalog_columns

(* Each count column reads a tool's usage as (text, dress). A tool nobody
   called has no failures and no latency to report, so those two stay empty and
   only CALLS says [0]: a column of dashes under the tools nobody called would
   read as a column of missing data. *)
let calls_reading = function
  | Usage_unread -> unread_reading, Ansi.dim
  | Never_called -> "0", Ansi.dim
  | Called { calls; _ } -> Masc_tui_message_layout.compact_count calls, ""

(* A zero is dim, and a count is dressed only when every call failed. Most
   tools with any call have failed at least once, so a failure count alone
   says little; "every call failed" is the reading that is never routine. *)
let failures_reading = function
  | Usage_unread -> unread_reading, Ansi.dim
  | Never_called -> "", ""
  | Called { calls; failures; _ } ->
      ( Masc_tui_message_layout.compact_count failures
      , if failures = 0 then Ansi.dim
        else if failures = calls then Theme.bad ()
        else "" )

let p95_reading = function
  | Usage_unread | Called { p95_ms = None; _ } -> unread_reading, Ansi.dim
  | Never_called -> "", ""
  | Called { p95_ms = Some ms; _ } -> (
      match Masc_tui_message_layout.elapsed_text (ms /. 1000.) with
      | Some text -> text, ""
      | None -> unread_reading, Ansi.dim)

(* The cells of one line at [width]: the column names when [reading] is [None],
   a tool when it is [Some]. Header and rows come out of this one description
   at the same offsets whatever a row carries. *)
let catalog_cells ~width reading =
  let layout = catalog_layout ~width in
  List.map
    (fun column ->
      let value, style =
        match reading with None -> "", "" | Some read -> read column
      in
      let cell_width =
        match column with
        | Col_surfaces -> layout.Table.flex_width
        | Col_name | Col_calls | Col_failures | Col_p95 | Col_direct ->
            catalog_column_width column
      in
      Table.cell ~align:(catalog_column_align column)
        ~fold:(catalog_column_fold column) ~style
        ~header:(catalog_column_header column) ~width:cell_width value)
    layout.Table.shown

(* The indent before the first cell, written once for each table, and the free
   last column spaced the way the contract spaces the rest. A line that names
   the columns and a line that fills them are drawn through one function, so
   they cannot differ by an indent. *)
let framed ~indent ~cells ~tail =
  indent ^ cells ^ String.make Table.cell_gap ' ' ^ tail

let effective_tool_header =
  framed ~indent:effective_row_indent
    ~cells:(Table.header_row (effective_tool_cells ""))
    ~tail:"ORIGIN"

let effective_tool_line ~name ~origin =
  framed ~indent:effective_row_indent
    ~cells:(Table.row (effective_tool_cells name))
    ~tail:origin

let catalog_tool_header ~width =
  catalog_row_indent ^ Table.header_row (catalog_cells ~width None)

let catalog_tool_line ~width ~metadata ~name ~direct ~usage ~surfaces =
  let read = function
    | Col_name -> name, ""
    | Col_direct -> direct, metadata
    | Col_surfaces -> surfaces, metadata
    | Col_calls -> calls_reading usage
    | Col_failures -> failures_reading usage
    | Col_p95 -> p95_reading usage
  in
  catalog_row_indent ^ Table.row (catalog_cells ~width (Some read))

let skill_usage_keeper_header =
  framed ~indent:""
    ~cells:
      (Table.header_row
         (skill_usage_keeper_cells ~keeper:"" ~invocations:"" ~deliveries:""
            ~actions:""))
    ~tail:"LAST USED"

let skill_usage_keeper_line ~keeper ~invocations ~deliveries ~actions ~last_used =
  framed ~indent:""
    ~cells:
      (Table.row
         (skill_usage_keeper_cells ~keeper
            ~invocations:(string_of_int invocations)
            ~deliveries:(string_of_int deliveries)
            ~actions:(string_of_int actions)))
    ~tail:last_used
