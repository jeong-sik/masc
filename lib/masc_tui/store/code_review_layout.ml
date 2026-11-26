open Masc_tui_protocol

type row =
  | Hunk_header of Wire_infra.git_diff_hunk
  | Single of Wire_infra.git_diff_line
  | Pair of {
      left : Wire_infra.git_diff_line option;
      right : Wire_infra.git_diff_line option;
    }

(* Two 14-cell gutters plus two columns of 70 cells: below this an 80-column
   source line no longer fits on either side. *)
let side_by_side_min_cols = 160

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
