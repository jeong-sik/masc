module Layout = Masc_tui_message_layout

(* Cells between a number and its text. The text of a continued entry starts
   this far past the number's column, so both rows take it from here. *)
let gap_cells = 2

let rows ~max_cells entries =
  let digits = String.length (string_of_int (List.length entries)) in
  let marker_cells = digits + gap_cells in
  let text_cells = max_cells - marker_cells in
  let gap = String.make gap_cells ' ' in
  let indent = String.make marker_cells ' ' in
  List.concat
    (List.mapi
       (fun index entry ->
          let number = Printf.sprintf "%*d" digits (index + 1) in
          match Layout.wrap_words ~max_cells:text_cells entry with
          | [] -> [ number ]
          | first :: continued ->
            (number ^ gap ^ first) :: List.map (fun row -> indent ^ row) continued)
       entries)
;;
