module Layout = Masc_tui_message_layout

type item =
  { key : string
  ; label : string
  }

let text item = item.key ^ ": " ^ item.label

let wrap ~max_cells items =
  match items with
  | [] -> []
  | _ :: _ -> Layout.pack_clauses ~max_cells (List.map text items)
;;
