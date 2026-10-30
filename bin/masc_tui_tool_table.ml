module Table = Masc_tui_table

let effective_tool_name_width = 34
let catalog_tool_name_width = 32
let catalog_direct_width = 8

(* Catalog rows sit under a domain and a family heading, indented past both so
   the tree reads. The column header carries that same indent or it names
   columns the readings below do not start in, which is what it did. *)
let catalog_row_indent = "      "
let effective_row_indent = "   "
let skill_usage_name_indent = "   "
let skill_usage_keeper_indent = "     "

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

let catalog_tool_cells ?(direct_style = "") ~name ~direct () =
  [ Table.cell ~header:"TOOL" ~width:catalog_tool_name_width name
  ; Table.cell ~style:direct_style ~header:"DIRECT" ~width:catalog_direct_width
      direct
  ]

(* The indent before the first cell, written once for each table, and the free
   last column spaced the way the contract spaces the rest. The header and the
   rows differed by exactly the indent on the catalog -- three cells against
   six -- so a line that names the columns and a line that fills them are drawn
   through one function here. *)
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

let catalog_tool_header =
  framed ~indent:catalog_row_indent
    ~cells:
      (Table.header_row
         (catalog_tool_cells ~name:"" ~direct:"" ()))
    ~tail:"SURFACES"

let catalog_tool_line ~metadata ~name ~direct ~surfaces =
  framed ~indent:catalog_row_indent
    ~cells:
      (Table.row
         (catalog_tool_cells ~direct_style:metadata ~name ~direct ()))
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
