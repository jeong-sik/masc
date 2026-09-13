module Message_layout = Masc_tui_message_layout

let two_column_minimum_cols = 96

(* The gutter the two columns leave: one border and one pad on each side. *)
let column_gutter_cols = 6

let column_width ~cols = (cols - column_gutter_cols) / 2

let rec zip left right =
  match left, right with
  | [], [] -> []
  | l :: lt, [] -> (l, "") :: zip lt []
  | [], r :: rt -> ("", r) :: zip [] rt
  | l :: lt, r :: rt -> (l, r) :: zip lt rt

(* The runs of lines between blank lines: a heading and its rows. *)
let sections lines =
  let close current found =
    match current with
    | [] -> found
    | _ :: _ -> List.rev current :: found
  in
  let rec gather current found = function
    | [] -> List.rev (close current found)
    | "" :: rest -> gather [] (close current found) rest
    | line :: rest -> gather (line :: current) found rest
  in
  gather [] [] lines

let sheet ?(header = []) ~cols lines =
  let body =
    if cols < two_column_minimum_cols then lines
    else begin
      let width = column_width ~cols in
      let row (l, r) =
        Message_layout.fit_width l width ^ "  " ^ Message_layout.fit_width r width
      in
      (* Two sections to a row, each whole, read left then right then down.
         A heading stays above its own rows; a column cut at a line count
         starts under no heading, partway through someone else's keys. *)
      let rec pairs = function
        | [] -> []
        | [ last ] -> List.map (fun line -> row (line, "")) last
        | left :: right :: rest ->
            List.map row (zip left right)
            @ (match rest with [] -> [] | _ :: _ -> [ row ("", "") ])
            @ pairs rest
      in
      pairs (sections lines)
    end
  in
  header @ body
