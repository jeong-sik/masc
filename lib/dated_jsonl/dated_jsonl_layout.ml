(** Pure calendar and segment layout shared by store readers and writers. *)

let year_is_leap year =
  year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0)
;;

let days_in_month ~year = function
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> Some 31
  | 4 | 6 | 9 | 11 -> Some 30
  | 2 -> Some (if year_is_leap year then 29 else 28)
  | _ -> None
;;

let substring_is_ascii_digits value ~position ~length =
  let rec loop index =
    if index >= position + length
    then true
    else
      match value.[index] with
      | '0' .. '9' -> loop (index + 1)
      | _ -> false
  in
  loop position
;;

(** Parse ["YYYY-MM-DD"] into [("YYYY-MM", "DD")].
    Returns [None] for malformed strings. *)
let parse_date s =
  if String.length s <> 10
     || s.[4] <> '-'
     || s.[7] <> '-'
     || not (substring_is_ascii_digits s ~position:0 ~length:4)
     || not (substring_is_ascii_digits s ~position:5 ~length:2)
     || not (substring_is_ascii_digits s ~position:8 ~length:2)
  then None
  else
    match
      int_of_string_opt (String.sub s 0 4),
      int_of_string_opt (String.sub s 5 2),
      int_of_string_opt (String.sub s 8 2)
    with
    | Some year, Some month, Some day ->
      (match days_in_month ~year month with
       | Some maximum when day >= 1 && day <= maximum ->
         Some (String.sub s 0 7, String.sub s 8 2)
       | Some _ | None -> None)
    | _ -> None

(* A completed file uses a canonical decimal sequence with at least three
   digits. Parse once for validation, writer allocation and every read/prune
   ordering; lexicographic order is wrong as soon as 999 becomes 1000. *)
let rotation_sequence_digits = 3

let day_file_parts name =
  let length = String.length name in
  if length < 8 || not (substring_is_ascii_digits name ~position:0 ~length:2)
     || not (Filename.check_suffix name ".jsonl")
  then None
  else
    let day = String.sub name 0 2 in
    if length = 8 then Some (day, None)
    else if length >= 9 + rotation_sequence_digits && Char.equal name.[2] '.' then
      let digits = String.sub name 3 (length - 9) in
      if not (substring_is_ascii_digits digits ~position:0 ~length:(String.length digits))
      then None
      else match int_of_string_opt digits with
        | Some sequence when sequence > 0
            && String.equal digits (Printf.sprintf "%0*d" rotation_sequence_digits sequence) ->
            Some (day, Some sequence)
        | Some _ | None -> None
    else None

let compare_day_files left right =
  match day_file_parts left, day_file_parts right with
  | Some (left_day, left_sequence), Some (right_day, right_sequence) ->
      let day_order = String.compare left_day right_day in
      if day_order <> 0 then day_order else
      (match left_sequence, right_sequence with
       | None, None -> 0
       | None, Some _ -> 1
       | Some _, None -> -1
       | Some left, Some right -> Int.compare left right)
  | None, None -> String.compare left right
  | None, Some _ -> -1
  | Some _, None -> 1

(* The day number is always the leading two characters — for both the
   current [DD.jsonl] and rotated [DD.NNN.jsonl] segments.
   [Filename.remove_extension] must not be used for this: it maps a
   segment to ["DD.NNN"], which compares greater than its own day and
   silently drops segments from range boundaries. *)
let day_number_of_day_file_name name =
  if String.length name >= 2 then String.sub name 0 2 else name
;;

let year_and_month_of_directory_name name =
  if String.length name = 7
     && name.[4] = '-'
     && substring_is_ascii_digits name ~position:0 ~length:4
     && substring_is_ascii_digits name ~position:5 ~length:2
  then
    match
      int_of_string_opt (String.sub name 0 4),
      int_of_string_opt (String.sub name 5 2)
    with
    | Some year, Some month when month >= 1 && month <= 12 -> Some (year, month)
    | _ -> None
  else None
;;

let month_directory_name_is_valid name =
  Option.is_some (year_and_month_of_directory_name name)
;;

let day_number_is_valid ~year ~month day_text =
  match int_of_string_opt day_text, days_in_month ~year month with
  | Some day, Some maximum -> day >= 1 && day <= maximum
  | None, _ | _, None -> false
;;

let day_file_name_is_valid ~year ~month name =
  match day_file_parts name with
  | Some (day, _) -> day_number_is_valid ~year ~month day
  | None -> false
;;

(* A name this layout can never produce is a foreign file, not a corrupted
   member of it. Month directories are [YYYY-MM] and day files are
   [DD.jsonl]; neither can begin with a dot, so a dotfile was written by
   something other than this store.

   macOS writes [.DS_Store] into any directory Finder opens, and the live
   store sits under a browsed home, so failing the whole read for one would
   take every reader of that store down for the rest of a Finder visit.
   Entries that do belong to the layout stay strict: a directory named
   [2026-13] or a file named [32.jsonl] is corruption and still fails. *)
let entry_is_foreign_to_layout entry =
  String.length entry > 0 && Char.equal entry.[0] '.'
;;

let rotated_segment_name ~day_prefix ~sequence =
  Printf.sprintf "%s.%0*d.jsonl" day_prefix rotation_sequence_digits sequence
