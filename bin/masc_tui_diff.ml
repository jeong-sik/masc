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

let leading_context rows =
  let rec walk reversed = function
    | (Context _ as row) :: rest -> walk (row :: reversed) rest
    | rest -> List.rev reversed, rest
  in
  walk [] rows

(* [rows] has the shape produced above: context, then every removal/addition,
   then context. Split that shape rather than discovering changes again from
   rendered [+-] prefixes, which would make a line of source that starts with
   one indistinguishable from a diff marker. *)
let split_around_change rows =
  let before, after_before = leading_context rows in
  let after_reversed, changed_reversed =
    leading_context (List.rev after_before)
  in
  before, List.rev changed_reversed, List.rev after_reversed

let preview ~context ~max_rows rows =
  let total = List.length rows in
  if context < 0 || max_rows <= 0 then [], total
  else
    let before, changed, after = split_around_change rows in
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

(* A line-number cell.

   An added line has no number on the old side and a removed line none on the
   new one. A blank there would read as an alignment slip and a zero would
   read as line zero, so absence is spelled: the column says "there is none"
   in the same width as a number. *)
let line_number_cell = function
  | None -> "    -"
  | Some line -> Printf.sprintf "%5d" line
