module Table = Masc_tui_table

let effective_tool_name_width = 34
let effective_tool_cell_gap = 1
let catalog_tool_name_width = 32
let catalog_direct_width = 8
let catalog_cell_gap = 1

(* Catalog rows sit under a domain and a family heading, indented past both so
   the tree reads. The column header carries that same indent or it names
   columns the readings below do not start in, which is what it did. *)
let catalog_row_indent = "      "
let effective_row_indent = "   "
let skill_usage_name_indent = "   "
let skill_usage_keeper_indent = "     "

let effective_tool_cells name =
  [ Table.cell ~header:"TOOL" ~width:effective_tool_name_width name ]

let catalog_tool_cells ?(direct_style = "") ~name ~direct () =
  [ Table.cell ~header:"TOOL" ~width:catalog_tool_name_width name
  ; Table.cell ~style:direct_style ~header:"DIRECT" ~width:catalog_direct_width
      direct
  ]

(* The indent before the first cell and the gap before the free last column,
   written once for each table. The header and the rows differed by exactly
   these two on the catalog -- three cells of indent against six -- so a line
   that names the columns and a line that fills them are drawn through one
   function here. *)
let framed ~indent ~gap ~cells ~tail = indent ^ cells ^ String.make gap ' ' ^ tail

let effective_tool_header =
  framed ~indent:effective_row_indent ~gap:effective_tool_cell_gap
    ~cells:(Table.header_row ~gap:effective_tool_cell_gap (effective_tool_cells ""))
    ~tail:"ORIGIN"

let effective_tool_line ~name ~origin =
  framed ~indent:effective_row_indent ~gap:effective_tool_cell_gap
    ~cells:(Table.row ~gap:effective_tool_cell_gap (effective_tool_cells name))
    ~tail:origin

let catalog_tool_header =
  framed ~indent:catalog_row_indent ~gap:catalog_cell_gap
    ~cells:
      (Table.header_row ~gap:catalog_cell_gap
         (catalog_tool_cells ~name:"" ~direct:"" ()))
    ~tail:"SURFACES"

let catalog_tool_line ~metadata ~name ~direct ~surfaces =
  framed ~indent:catalog_row_indent ~gap:catalog_cell_gap
    ~cells:
      (Table.row ~gap:catalog_cell_gap
         (catalog_tool_cells ~direct_style:metadata ~name ~direct ()))
    ~tail:(metadata ^ surfaces)
