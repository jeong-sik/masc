module Layout = Masc_tui_message_layout

type item =
  { key : string
  ; label : string
  }

let separator = " \xc2\xb7 "
let text item = item.key ^ ": " ^ item.label

let wrap ~max_cells items =
  let separator_cells = Layout.display_width separator in
  let close row rows =
    match row with
    | [] -> rows
    | _ :: _ -> String.concat separator (List.rev row) :: rows
  in
  let rec pack row row_cells rows = function
    | [] -> List.rev (close row rows)
    | item :: rest ->
      let hint = text item in
      let cells = Layout.display_width hint in
      if cells > max_cells
      then (
        let own_rows = Layout.wrap_words ~max_cells hint in
        pack [] 0 (List.rev_append own_rows (close row rows)) rest)
      else (
        match row with
        | [] -> pack [ hint ] cells rows rest
        | _ :: _ ->
          let joined = row_cells + separator_cells + cells in
          if joined <= max_cells
          then pack (hint :: row) joined rows rest
          else pack [ hint ] cells (close row rows) rest)
  in
  pack [] 0 [] items
;;
