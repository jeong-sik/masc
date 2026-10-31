type entry = int
type origin_display = Origin_row | Origin_bare
let rows_of_entry ?markdown:(_ : (int -> int) option) ~origin:_ ~inner_width:_ ~previous:_ entry =
  List.init entry Fun.id
type row_counts = {
  rc_entries : entry list;
  rc_inner_width : int;
  rc_origin : origin_display;
  rc_newest_first : entry array;
  rc_row_ends : int array;
  mutable rc_filled : int;
      (** Entries from the newest whose count is known, so a frame that
          scrolled further extends this rather than starting again. *)
}

let row_counts_memo : row_counts option ref = ref None

let row_counts_for entries ~inner_width ~origin =
  match !row_counts_memo with
  | Some held
    when held.rc_entries == entries
         && held.rc_inner_width = inner_width
         && held.rc_origin = origin ->
      held
  | Some _ | None ->
      let newest_first = Array.of_list (List.rev entries) in
      let held =
        { rc_entries = entries;
          rc_inner_width = inner_width;
          rc_origin = origin;
          rc_newest_first = newest_first;
          rc_row_ends = Array.make (Array.length newest_first) 0;
          rc_filled = 0;
        }
      in
      row_counts_memo := Some held;
      held

let entry_rows_at held ?markdown index =
  let count = Array.length held.rc_newest_first in
  let previous =
    if index + 1 < count then Some held.rc_newest_first.(index + 1) else None
  in
  rows_of_entry ?markdown ~origin:held.rc_origin ~inner_width:held.rc_inner_width
    ~previous held.rc_newest_first.(index)

(* Extend the known counts from the newest until they cover [wanted] rows, or
   until the conversation runs out. Answers how many rows and how many entries
   that took, which is the walk the window is then cut out of. *)
(* Locate the first measured newest-prefix whose cumulative count reaches
   [wanted]. Empty entries can share an end, so keep the first equal end. *)
let first_row_count_at_least held ~wanted =
  let rec search low high =
    if low >= high then low
    else
      let middle = low + (high - low) / 2 in
      if held.rc_row_ends.(middle) >= wanted then search low middle
      else search (middle + 1) high
  in
  search 0 held.rc_filled

let extend_row_count held ?markdown index =
  let before = if index = 0 then 0 else held.rc_row_ends.(index - 1) in
  let total = before + List.length (entry_rows_at held ?markdown index) in
  held.rc_row_ends.(index) <- total;
  held.rc_filled <- index + 1;
  total

let count_rows_until held ?markdown ~wanted () =
  if wanted <= 0 then 0, 0
  else
    let known = first_row_count_at_least held ~wanted in
    if known < held.rc_filled then known + 1, held.rc_row_ends.(known)
    else
      let entry_count = Array.length held.rc_newest_first in
      let total = if known = 0 then 0 else held.rc_row_ends.(known - 1) in
      let rec extend index total =
        if total >= wanted || index >= entry_count then index, total
        else extend (index + 1) (extend_row_count held ?markdown index)
      in
      extend known total
