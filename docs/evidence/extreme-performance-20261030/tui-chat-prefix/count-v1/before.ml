type entry = int
type origin_display = Origin_row | Origin_bare
let rows_of_entry ?markdown:(_ : (int -> int) option) ~origin:_ ~inner_width:_ ~previous:_ entry =
  List.init entry Fun.id
type row_counts = {
  rc_entries : entry list;
  rc_inner_width : int;
  rc_origin : origin_display;
  rc_newest_first : entry array;
  rc_counts : int array;
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
          rc_counts = Array.make (Array.length newest_first) 0;
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
let count_rows_until held ?markdown ~wanted () =
  let entry_count = Array.length held.rc_newest_first in
  let rec walk index total =
    if total >= wanted || index >= entry_count then (index, total)
    else begin
      if index >= held.rc_filled
      then begin
        held.rc_counts.(index) <-
          List.length (entry_rows_at held ?markdown index);
        held.rc_filled <- index + 1
      end;
      walk (index + 1) (total + held.rc_counts.(index))
    end
  in
  walk 0 0
