open Masc_tui_protocol

type row =
  | Hunk_header of Wire_infra.git_diff_hunk
  | Single of Wire_infra.git_diff_line
  | Pair of {
      left : Wire_infra.git_diff_line option;
      right : Wire_infra.git_diff_line option;
    }

(* Two 60-cell halves (each with 6-cell line-number+marker gutter and >= 53-cell
   source column) plus a 1-cell center divider: below 120 cells of actual diff
   pane width, unified view stays cleaner and more readable. *)
let side_by_side_min_cols = 120

let effective_diff_pane_width ?(zoomed = false) ?(viewport_rows = 40)
    ~viewport_cols ~sidebar_docked () =
  let cols = max 0 viewport_cols in
  let rows = max 0 viewport_rows in
  let bp = Masc_tui_ui.Layout.classify_viewport ~cols ~rows in
  let outer_margin = Masc_tui_ui.Layout.outer_margin bp in
  let full_w =
    if outer_margin > 0 && cols > outer_margin * 2 then
      cols - (outer_margin * 2)
    else cols
  in
  let sidebar_width = 24 in
  let sidebar_gap = 1 in
  let body_w =
    if sidebar_docked && full_w >= sidebar_width + 20 then
      max 0 (full_w - sidebar_width - sidebar_gap)
    else full_w
  in
  let right_w =
    if zoomed then body_w
    else
      match bp with
      | Masc_tui_ui.Layout.Compact | Masc_tui_ui.Layout.Micro -> body_w
      | Masc_tui_ui.Layout.Wide | Masc_tui_ui.Layout.Standard ->
          let gap = Masc_tui_ui.Layout.card_gap_x bp in
          let avail = max 0 (body_w - gap) in
          let left_w = int_of_float (Float.floor (float_of_int avail *. 0.32)) in
          max 0 (avail - left_w)
  in
  let inner_w = max 0 (right_w - 2) in
  let pad_x = Masc_tui_ui.Layout.card_pad_x_for_width bp inner_w in
  max 0 (inner_w - (2 * pad_x))

let side_by_side ~cols = cols >= side_by_side_min_cols

(* Deletions and additions of one change block, newest first. *)
let flush ~deleted ~added acc =
  let rec zip dels adds acc =
    match (dels, adds) with
    | [], [] -> acc
    | d :: dels, a :: adds -> zip dels adds (Pair { left = Some d; right = Some a } :: acc)
    | d :: dels, [] -> zip dels [] (Pair { left = Some d; right = None } :: acc)
    | [], a :: adds -> zip [] adds (Pair { left = None; right = Some a } :: acc)
  in
  zip (List.rev deleted) (List.rev added) acc

let paired diff_rows =
  let rec go ~deleted ~added acc = function
    | [] -> List.rev (flush ~deleted ~added acc)
    | Wire_infra.Hunk h :: rest ->
        go ~deleted:[] ~added:[] (Hunk_header h :: flush ~deleted ~added acc) rest
    | Wire_infra.Line ({ kind = `Delete; _ } as l) :: rest when List.is_empty added ->
        go ~deleted:(l :: deleted) ~added acc rest
    | Wire_infra.Line ({ kind = `Delete; _ } as l) :: rest ->
        (* A deletion after additions starts a new change block. *)
        go ~deleted:[ l ] ~added:[] (flush ~deleted ~added acc) rest
    | Wire_infra.Line ({ kind = `Add; _ } as l) :: rest ->
        go ~deleted ~added:(l :: added) acc rest
    | Wire_infra.Line ({ kind = `Context; _ } as l) :: rest ->
        go ~deleted:[] ~added:[]
          (Pair { left = Some l; right = Some l } :: flush ~deleted ~added acc)
          rest
  in
  go ~deleted:[] ~added:[] [] diff_rows

let rows ~side_by_side diff_rows =
  if side_by_side then paired diff_rows
  else
    List.map
      (function
        | Wire_infra.Hunk h -> Hunk_header h
        | Wire_infra.Line l -> Single l)
      diff_rows

let step_hunk ~delta ~scroll rows =
  let headers =
    List.mapi (fun i r -> (i, r)) rows
    |> List.filter_map (function
         | i, Hunk_header _ -> Some i
         | _, (Single _ | Pair _) -> None)
  in
  if delta > 0 then List.find_opt (fun i -> i > scroll) headers
  else List.find_opt (fun i -> i < scroll) (List.rev headers)

let row_new_line = function
  | Hunk_header h -> Some (max 1 h.new_start)
  | Single l -> l.new_line
  | Pair { right = Some r; _ } -> r.new_line
  | Pair { right = None; _ } -> None

let jump_line ~scroll rows =
  List.filteri (fun i _ -> i >= scroll) rows |> List.find_map row_new_line
