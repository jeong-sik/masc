module Table = Masc_tui_table
module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme
module Say = Masc_tui_say

(* Column names in the screen's language, never in capitals only (RFC
   tui-one-screen-grammar section 5.1). Every row of a table is drawn once per
   language from these, so a header and the rows under it are laid out on the
   same cells in either language. *)
type names = {
  tool : string;
  origin : string;
  calls : string;
  failures : string;
  direct : string;
  surfaces : string;
}

let names = function
  | Say.Ko ->
    { tool = "도구"; origin = "출처"; calls = "호출"; failures = "실패"; direct = "직접";
      surfaces = "노출 위치" }
  | Say.En ->
    { tool = "Tool"; origin = "Origin"; calls = "Calls"; failures = "Fail"; direct = "Direct";
      surfaces = "Surfaces" }

(* The percentile names itself the same way in both languages. *)
let p95_name = "P95"

let effective_tool_name_width = 34
let catalog_tool_name_width = 32
let catalog_direct_width = 8

(* Catalog rows sit under a domain and a family heading, indented past both so
   the tree reads. The column header carries that same indent or it names
   columns the readings below do not start in, which is what it did. *)
let catalog_row_indent = "      "
let effective_row_indent = "   "

let effective_tool_cells names name =
  [ Table.cell ~header:names.tool ~width:effective_tool_name_width name ]

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
let catalog_layout ~language ~width ~surfaces_cells =
  let inner_width = max 0 (width - String.length catalog_row_indent) in
  let column_width = function
    | Col_name -> catalog_tool_name_width
    | Col_calls | Col_failures | Col_p95 -> catalog_reading_width
    | Col_direct -> catalog_direct_width
    | Col_surfaces ->
      max (Masc_tui_message_layout.display_width (names language).surfaces) surfaces_cells
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
  | Usage_unread -> unread_reading, Theme.recede ()
  | Never_called -> "0", Theme.recede ()
  | Called { calls; _ } -> Masc_tui_message_layout.compact_count calls, ""

(* A zero recedes, and a count is dressed only when every call failed. Most
   tools with any call have failed at least once, so a failure count alone
   says little; "every call failed" is the reading that is never routine. *)
let failures_reading = function
  | Usage_unread -> unread_reading, Theme.recede ()
  | Never_called -> "", ""
  | Called { calls; failures; _ } ->
      ( Masc_tui_message_layout.compact_count failures
      , if failures = 0 then Theme.recede ()
        else if failures = calls then Theme.bad ()
        else "" )

let p95_reading = function
  | Usage_unread | Called { p95_ms = None; _ } -> unread_reading, Theme.recede ()
  | Never_called -> "", ""
  | Called { p95_ms = Some ms; _ } -> (
      match Masc_tui_message_layout.elapsed_text (ms /. 1000.) with
      | Some text -> text, ""
      | None -> unread_reading, Theme.recede ())

(* The cells of one catalog line. The column names are drawn from the same
   cells with empty readings, so header and rows cannot place a column
   differently. *)
let catalog_cells names layout ~metadata ~name ~direct ~usage =
  let count header (value, style) =
    Table.cell ~align:Table.Right ~style ~header ~width:catalog_reading_width
      value
  in
  List.filter_map
    (function
      | Col_name ->
          Some
            (Table.cell ~header:names.tool ~width:catalog_tool_name_width name)
      | Col_calls -> Some (count names.calls (calls_reading usage))
      | Col_failures -> Some (count names.failures (failures_reading usage))
      | Col_p95 -> Some (count p95_name (p95_reading usage))
      | Col_direct ->
          Some
            (Table.cell ~style:metadata ~header:names.direct
               ~width:catalog_direct_width direct)
      | Col_surfaces -> None)
    layout

(* The indent before the first cell, written once for each table, and the free
   last column spaced the way the contract spaces the rest. A line that names
   the columns and a line that fills them are drawn through one function, so
   they cannot differ by an indent. *)
let framed ~indent ~cells ~tail =
  indent ^ cells ^ String.make Table.cell_gap ' ' ^ tail

(* Each table row in both languages: the same cells, named in each. *)
let in_each_language draw = Say.per_language (fun language -> draw language (names language))

let effective_tool_header =
  in_each_language (fun _ names ->
    framed ~indent:effective_row_indent
      ~cells:(Table.header_row (effective_tool_cells names ""))
      ~tail:names.origin)

let effective_tool_line ~name ~origin =
  in_each_language (fun _ names ->
    framed ~indent:effective_row_indent
      ~cells:(Table.row (effective_tool_cells names name))
      ~tail:origin)

let catalog_tool_header layout =
  in_each_language (fun _ names ->
    framed ~indent:catalog_row_indent
      ~cells:
        (Table.header_row
           (catalog_cells names layout ~metadata:"" ~name:"" ~direct:""
              ~usage:Usage_unread))
      ~tail:names.surfaces)

let catalog_tool_line layout ~metadata ~name ~direct ~usage ~surfaces =
  in_each_language (fun language names ->
    let surface_text = Say.render language surfaces in
    let styled_tail =
      if String.equal metadata "" then surface_text
      else metadata ^ surface_text ^ Ansi.reset
    in
    framed ~indent:catalog_row_indent
      ~cells:
        (Table.row
           (catalog_cells names layout ~metadata ~name
              ~direct:(Say.render language direct) ~usage))
      ~tail:styled_tail)
