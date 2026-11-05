module Layout = Masc_tui_message_layout

let rows ~max_cells entries =
  let digits = String.length (string_of_int (List.length entries)) in
  let marker_cells = digits + 2 in
  let text_cells = max_cells - marker_cells in
  let indent = String.make marker_cells ' ' in
  List.concat
    (List.mapi
       (fun index entry ->
          let number = Printf.sprintf "%*d" digits (index + 1) in
          match Layout.wrap_words ~max_cells:text_cells entry with
          | [] -> [ number ]
          | first :: continued ->
            (number ^ "  " ^ first) :: List.map (fun row -> indent ^ row) continued)
       entries)
;;
