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
   stay behind them. SURFACES is the free last column: it is described here so
   that [Table.fit] knows how much room it needs, and drawn by [framed]. *)
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

(* Nothing was sent for this reading. A zero would say the tool was fast or
   never failed. *)
let unread_reading = "--"

(* The columns of a catalog line, less SURFACES. *)
type catalog_layout = catalog_column list

(* SURFACES needs the room of its widest reading, or a row with three surfaces
   wraps onto a second row; the counts take what is left. They go before
   SURFACES loses any: P95 first, FAIL next, CALLS last, and the table is
   TOOL DIRECT SURFACES again, which is what a terminal too narrow for them
   drew before they existed. *)
let catalog_layout ~width ~surfaces_cells =
  let inner_width = max 0 (width - String.length catalog_row_indent) in
  let column_width = function
    | Col_name -> catalog_tool_name_width
    | Col_calls | Col_failures | Col_p95 -> catalog_reading_width
    | Col_direct -> catalog_direct_width
    | Col_surfaces -> max (String.length "SURFACES") surfaces_cells
  in
  let fitted =
    Table.fit ~inner_width ~width:column_width ~flex:Col_surfaces
      ~drop_order:[ Col_p95; Col_failures; Col_calls ] catalog_columns
  in
  List.filter (fun column -> column <> Col_surfaces) fitted.Table.shown

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

(* The cells of one catalog line. The column names are drawn from the same
   cells with empty readings, so header and rows cannot place a column
   differently. *)
let catalog_cells layout ~metadata ~name ~direct ~usage =
  let count header (value, style) =
    Table.cell ~align:Table.Right ~style ~header ~width:catalog_reading_width
      value
  in
  List.filter_map
    (function
      | Col_name ->
          Some
            (Table.cell ~header:"TOOL" ~width:catalog_tool_name_width name)
      | Col_calls -> Some (count "CALLS" (calls_reading usage))
      | Col_failures -> Some (count "FAIL" (failures_reading usage))
      | Col_p95 -> Some (count "P95" (p95_reading usage))
      | Col_direct ->
          Some
            (Table.cell ~style:metadata ~header:"DIRECT"
               ~width:catalog_direct_width direct)
      | Col_surfaces -> None)
    layout

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

let catalog_tool_header layout =
  framed ~indent:catalog_row_indent
    ~cells:
      (Table.header_row
         (catalog_cells layout ~metadata:"" ~name:"" ~direct:""
            ~usage:Usage_unread))
    ~tail:"SURFACES"

let catalog_tool_line layout ~metadata ~name ~direct ~usage ~surfaces =
  framed ~indent:catalog_row_indent
    ~cells:(Table.row (catalog_cells layout ~metadata ~name ~direct ~usage))
    ~tail:(metadata ^ surfaces)

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
