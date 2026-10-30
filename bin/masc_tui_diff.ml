type row =
  | Context of string
  | Removed of string
  | Added of string

(* Text ending in a newline is the same lines as text without one. Splitting on
   the separator alone would give a trailing empty line, and a row that says an
   empty line was added is a change nobody made. *)
let lines text =
  (* Empty text has no lines. [split_on_char] gives [[""]], and reading that as
     one empty line makes a write into an empty file report a line removed. *)
  if String.length text = 0 then []
  else
    match String.split_on_char '\n' text with
    | [] -> []
    | split -> (
        match List.rev split with
        | "" :: rest when List.length split > 1 -> List.rev rest
        | _ -> split)

let common_prefix before after =
  let rec walk taken before after =
    match (before, after) with
    | b :: brest, a :: arest when String.equal b a -> walk (b :: taken) brest arest
    | _ -> (List.rev taken, before, after)
  in
  walk [] before after

(* The suffix is the prefix of the reversed remainders. Sharing the walk keeps
   one definition of "these lines are the same" rather than two that could
   disagree about, say, trailing whitespace. *)
let common_suffix before after =
  let shared, before_rest, after_rest =
    common_prefix (List.rev before) (List.rev after)
  in
  (List.rev shared, List.rev before_rest, List.rev after_rest)

let rows ~before ~after =
  let before_lines = lines before and after_lines = lines after in
  let prefix, before_rest, after_rest = common_prefix before_lines after_lines in
  let suffix, before_middle, after_middle = common_suffix before_rest after_rest in
  List.concat
    [ List.map (fun line -> Context line) prefix
    ; List.map (fun line -> Removed line) before_middle
    ; List.map (fun line -> Added line) after_middle
    ; List.map (fun line -> Context line) suffix
    ]

let counts rows =
  List.fold_left
    (fun (removed, added) row ->
      match row with
      | Removed _ -> (removed + 1, added)
      | Added _ -> (removed, added + 1)
      | Context _ -> (removed, added))
    (0, 0) rows

let rec take count rows =
  match count, rows with
  | count, _ when count <= 0 -> []
  | _, [] -> []
  | count, row :: rest -> row :: take (count - 1) rest

let take_last count rows = rows |> List.rev |> take count |> List.rev

let is_context = function
  | Context _ -> true
  | Removed _ | Added _ -> false

let leading_context ~is_context rows =
  let rec walk reversed = function
    | row :: rest when is_context row -> walk (row :: reversed) rest
    | rest -> List.rev reversed, rest
  in
  walk [] rows

(* [rows] has the shape produced above: context, then every removal/addition,
   then context. Split that shape rather than discovering changes again from
   rendered [+-] prefixes, which would make a line of source that starts with
   one indistinguishable from a diff marker. *)
let split_around_change ~is_context rows =
  let before, after_before = leading_context ~is_context rows in
  let after_reversed, changed_reversed =
    leading_context ~is_context (List.rev after_before)
  in
  before, List.rev changed_reversed, List.rev after_reversed

(* The windowing itself, shared by [preview] and [preview_numbered]: the
   changed middle takes the budget before context, and the leftover context
   budget favours the leading side first. One copy so the two cannot window
   the same change differently. *)
let window ~context ~max_rows ~before ~changed ~after =
  let total =
    List.length before + List.length changed + List.length after
  in
  if context < 0 || max_rows <= 0 then [], total
  else
    let changed_count = List.length changed in
    let shown =
      if changed_count >= max_rows then take max_rows changed
      else
        let remaining = max_rows - changed_count in
        let before_cap = take_last context before in
        let after_cap = take context after in
        let before_first = min (List.length before_cap) ((remaining + 1) / 2) in
        let after_first = min (List.length after_cap) (remaining - before_first) in
        let unused = remaining - before_first - after_first in
        let before_extra = min (List.length before_cap - before_first) unused in
        let after_extra =
          min (List.length after_cap - after_first) (unused - before_extra)
        in
        let before_count = before_first + before_extra in
        let after_count = after_first + after_extra in
        take_last before_count before_cap @ changed @ take after_count after_cap
    in
    shown, max 0 (total - List.length shown)

let preview ~context ~max_rows rows =
  let before, changed, after = split_around_change ~is_context rows in
  window ~context ~max_rows ~before ~changed ~after

type numbered = {
  nrow : row;
  old_line : int option;
  new_line : int option;
}

let number ~old_start ~new_start rows =
  let old_cursor = ref old_start and new_cursor = ref new_start in
  List.map
    (fun row ->
      match row with
      | Context _ ->
          let numbered =
            { nrow = row
            ; old_line = Some !old_cursor
            ; new_line = !new_cursor
            }
          in
          incr old_cursor;
          new_cursor := Option.map succ !new_cursor;
          numbered
      | Removed _ ->
          let numbered =
            { nrow = row; old_line = Some !old_cursor; new_line = None }
          in
          incr old_cursor;
          numbered
      | Added _ ->
          let numbered =
            { nrow = row; old_line = None; new_line = !new_cursor }
          in
          new_cursor := Option.map succ !new_cursor;
          numbered)
    rows

let preview_numbered ~context ~max_rows numbered =
  let before, changed, after =
    split_around_change
      ~is_context:(fun numbered -> is_context numbered.nrow)
      numbered
  in
  window ~context ~max_rows ~before ~changed ~after

(* A line-number cell.

   An added line has no number on the old side and a removed line none on the
   new one. A blank there would read as an alignment slip and a zero would
   read as line zero, so absence is spelled: the column says "there is none"
   in the same width as a number. *)
let line_number_cell = function
  | None -> "    -"
  | Some line -> Printf.sprintf "%5d" line

let numbered_gutter_cells = 14

let numbered_gutter ~old_line ~new_line ~marker =
  Printf.sprintf "%s %s %c "
    (line_number_cell old_line)
    (line_number_cell new_line)
    marker
