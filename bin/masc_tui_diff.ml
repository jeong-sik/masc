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
