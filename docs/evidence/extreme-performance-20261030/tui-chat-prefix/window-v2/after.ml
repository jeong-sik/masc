type entry = int
type origin_display = Origin_row | Origin_bare
type row_kind = Body | Metadata of unit | Spacing | Viewport_gap of unit
type row = { kind : row_kind }
type body_row_position = {entry_index:int;body_row:int;rows_below:int}
let rows_of_entry ?markdown:(_ : (int -> int) option) ~origin:_ ~inner_width:_ ~previous:_ entry =
 List.init entry (fun i -> {kind=if i mod 7=0 then Metadata () else if i mod 11=0 then Spacing else Body})
let visible_rows_with_positions ?markdown ?origin ~inner_width ~height entries =
 let _=markdown,origin,inner_width in
 let all=List.concat (List.mapi (fun entry_index count ->
   let body=ref 0 in List.map (fun row -> let ordinal= !body in
     if row.kind=Body then incr body;row,entry_index,ordinal)
     (rows_of_entry ~origin:Origin_row ~inner_width:80 ~previous:None count)) entries) in
 let count=List.length all in
 let selected=List.filteri (fun i _ -> i>=count-max 0 height) all in
 List.map (fun (row,_,_)->row) selected,
 List.filter_map (fun (i,(row,entry_index,body_row)) -> if row.kind=Body then
   Some {entry_index;body_row;rows_below=List.length selected-i-1} else None)
   (List.mapi (fun i x->i,x) selected)
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

(* The window, and the scroll it had to be clamped to.

   Rows are numbered from the oldest of the entries the walk visited, which is
   the numbering the window is expressed in. Entry [index] -- counting from
   the newest -- holds the rows [total - before - count] up to
   [total - before], where [before] is what the entries newer than it take. *)

type scroll_window = {
  scroll : int;
  rows : row list;
  body_positions : body_row_position list;
}

let clamped_scrolled_rows ?markdown ?origin ~inner_width ~height ~requested entries =
  if requested <= 0 then
    let rows, body_positions = visible_rows_with_positions ?markdown ?origin ~inner_width ~height entries in
    { scroll = requested; rows; body_positions }
  else begin
    let inner_width = Int.max 1 inner_width in
    let origin = Option.value origin ~default:Origin_row in
    let window_height = Int.max 0 height in
    let bound_height = Int.max 1 height in
    let held = row_counts_for entries ~inner_width ~origin in
    let visited, total =
      count_rows_until held ?markdown ~wanted:(requested + bound_height) ()
    in
    let from_bottom = Int.min requested (Int.max 0 (total - bound_height)) in
    let bottom = Int.max 0 (total - from_bottom) in
    let first = Int.max 0 (bottom - window_height) in
    let rec gather index before (selected, positions) =
      if index >= visited then selected, positions
      else begin
        let count = held.rc_row_ends.(index)
          - (if index = 0 then 0 else held.rc_row_ends.(index - 1)) in
        let low = total - before - count in
        let high = total - before in
        let selected, positions =
          if high <= first || low >= bottom then selected, positions
          else begin
            let rows = entry_rows_at held ?markdown index in
            let take_from = Int.max first low and take_to = Int.min bottom high in
            let _, _, chosen, chosen_positions =
              List.fold_left
                (fun (offset, body_row, chosen, positions) row ->
                  let position = low + offset in
                  let is_body = match row.kind with Body -> true | Metadata _ | Spacing | Viewport_gap _ -> false in
                  let chosen, positions =
                    if position < take_from || position >= take_to then chosen, positions
                    else row :: chosen,
                      (if is_body then
                         { entry_index = Array.length held.rc_newest_first - index - 1;
                           body_row; rows_below = bottom - position - 1 } :: positions
                       else positions)
                  in
                  offset + 1, (if is_body then body_row + 1 else body_row), chosen, positions)
                (0, 0, [], []) rows
            in
            List.rev_append chosen selected, List.rev_append chosen_positions positions
          end
        in
        gather (index + 1) (before + count) (selected, positions)
      end
    in
    let first_entry = first_row_count_at_least held ~wanted:(from_bottom + 1) in
    let before = if first_entry = 0 then 0 else held.rc_row_ends.(first_entry - 1) in
    let rows, body_positions = gather first_entry before ([], []) in
    { scroll = from_bottom; rows; body_positions }
  end

(* Resolve a physical body row against this exact layout, measuring only its
   newer suffix. This is shared by search and by the next frame's origin pin. *)
let scroll_for_body_row ?markdown ?(origin = Origin_row) ~inner_width
    ~entry_index ~body_row entries =
  let held = row_counts_for entries ~inner_width:(Int.max 1 inner_width) ~origin in
  let index = Array.length held.rc_newest_first - entry_index - 1 in
  if index < 0 || index >= Array.length held.rc_newest_first || body_row < 0 then None
  else
    let rec fill_newer at =
      if at < index then begin
        ignore (extend_row_count held ?markdown at : int);
        fill_newer (at + 1)
      end
    in
    fill_newer held.rc_filled;
    let suffix = if index = 0 then 0 else held.rc_row_ends.(index - 1) in
    let rows = entry_rows_at held ?markdown index in
    let rec locate offset ordinal = function
      | [] -> None
      | row :: rest ->
          match row.kind with
          | Body when ordinal = body_row -> Some (suffix + List.length rows - offset - 1)
          | Body -> locate (offset + 1) (ordinal + 1) rest
          | Metadata _ | Spacing | Viewport_gap _ -> locate (offset + 1) ordinal rest
    in
    locate 0 0 rows
