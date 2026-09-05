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

let sheet ?(header = []) ~cols lines =
  let body =
    if cols < two_column_minimum_cols then lines
    else begin
      (* The split point keeps groups readable by cutting at the overall middle
         rather than balancing exact heights. *)
      let half = (List.length lines + 1) / 2 in
      let left = List.filteri (fun i _ -> i < half) lines in
      let right = List.filteri (fun i _ -> i >= half) lines in
      let width = column_width ~cols in
      List.map
        (fun (l, r) ->
          Message_layout.fit_width l width ^ "  " ^ Message_layout.fit_width r width)
        (zip left right)
    end
  in
  header @ body
