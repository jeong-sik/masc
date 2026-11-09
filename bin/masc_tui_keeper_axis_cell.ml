type tone =
  | Quiet
  | Attention
  | Failure

type t =
  { text : string
  ; tone : tone
  }

let separator = "  "

(* The columns between the text on the left of a row and its first cell. *)
let left_gap = 1

type 'a fit =
  { drawn : 'a list
  ; cells_width : int
  ; left_width : int
  }

let fit ~available ~detail_floor ~width cells =
  let reserved =
    match detail_floor with
    | None -> 0
    | Some columns -> columns + left_gap
  in
  let separator_width = String.length separator in
  let rec take drawn_rev used = function
    | [] -> drawn_rev, used
    | cell :: rest ->
        let cell_width = width cell in
        let used_with, room =
          match drawn_rev with
          | [] -> cell_width, available
          | _ :: _ -> used + separator_width + cell_width, available - reserved
        in
        if used_with <= room then take (cell :: drawn_rev) used_with rest
        else drawn_rev, used
  in
  let drawn_rev, cells_width = take [] 0 cells in
  let left_width =
    match drawn_rev with
    | [] -> available
    | _ :: _ -> max 0 (available - cells_width - left_gap)
  in
  { drawn = List.rev drawn_rev; cells_width; left_width }
;;
