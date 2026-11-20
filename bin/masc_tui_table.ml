(* One table row's cells.

   A screen describes its columns once -- the order, the width and the
   alignment -- and its header and every data row are drawn from that one
   description. Nothing here knows what any screen shows. It knows one thing:
   a header and the rows under it must not be able to disagree about where a
   column is.

   That disagreement is what this was pulled out of. A screen printing its
   widths twice, once in the header's format string and once in the row's, has
   two copies of one layout, and printf's width is a floor rather than a width:
   a value longer than the field is printed whole and every cell after it moves
   right. On the live fleet the Memory table drew a keeper named in 24 cells
   against a field of 18, which put that row's remaining cells six columns off
   the headers naming them. *)

type align =
  | Left
  | Right

type fold =
  | Fold_middle
  | Fold_tail

type cell = {
  header : string;
  width : int;
  align : align;
  fold : fold;
  value : string;
  style : string;
}

let cell ?(align = Left) ?(fold = Fold_middle) ?(style = "") ~header ~width
    value =
  { header; width; align; fold; value; style }

(* A cell's dress closes back to the row's own, not to a bare reset: a reset
   would strip the dimming or the selection band the caller wrapped the whole
   row in, and the rest of the row after a coloured cell would come out
   undressed. *)
let default_close = "\027[0m"

(* Two cells between columns, on every table on every screen
   (RFC tui-one-screen-grammar section 2). *)
let cell_gap = 2
let separator = String.make cell_gap ' '

let used_width cells =
  List.fold_left (fun total cell -> total + cell.width) 0 cells
  + (cell_gap * max 0 (List.length cells - 1))

(* Which columns a table draws at a width, and what its one flexible column
   gets.

   A table with a column whose reading is a sentence sized that column as
   whatever the named columns left, never below a floor. Below the floor the
   row ran past the frame and the frame cut its tail: at eighty columns the
   Board title sat at its floor and the row ran past the frame, so REPLIES
   was cut away, while the id column beside the title kept every one of its
   cells. Nothing said which of the columns mattered less, so the one that
   gave way was whichever sat last.

   A table now says it. Its columns are its own closed variant; [drop_order]
   names the ones that may go, first to go first. Columns it does not name,
   and the flexible one, stay. The flexible column counts at its floor while
   the table decides what fits and takes every cell the others leave. When
   everything that may go has gone and the rest still does not fit, the
   flexible column stays at its floor and the row is wider than the space,
   which is what the frame's cut is left for.

   Columns are compared as values of the table's variant, the way a match
   would read them; no header text is involved. *)
type 'col layout = {
  shown : 'col list;
  flex_width : int;
  dropped : int;
}

let fit ~inner_width ~width ~flex ~drop_order columns =
  (* The flexible column is counted once at its floor and then given every
     cell the others leave. Absent, nothing takes the slack; listed twice, its
     floor is counted twice while its share is computed once, and the row runs
     past [inner_width]. Either is a table described wrongly, not a width. *)
  let flex_count = List.length (List.filter (fun col -> col = flex) columns) in
  if flex_count = 0 then
    invalid_arg
      "Masc_tui_table.fit: the flexible column is not among the columns"
  else if flex_count > 1 then
    invalid_arg
      "Masc_tui_table.fit: the flexible column is listed more than once";
  let needs shown =
    List.fold_left (fun total col -> total + width col) 0 shown
    + (cell_gap * max 0 (List.length shown - 1))
  in
  let rec settle shown = function
    | [] -> shown
    | next :: later ->
        if needs shown <= inner_width then shown
        else if next = flex then settle shown later
        else settle (List.filter (fun col -> col <> next) shown) later
  in
  let shown = settle columns drop_order in
  let others =
    List.fold_left
      (fun total col -> if col = flex then total else total + width col)
      0 shown
  in
  let gaps = cell_gap * max 0 (List.length shown - 1) in
  let dropped = max 0 (List.length columns - List.length shown) in
  { shown; flex_width = max (width flex) (inner_width - others - gaps); dropped }

(* Where a reading gives way is the column's choice. An identifier keeps both
   ends and folds in the middle: cut at the head it reads as a different
   identifier, and a number cut at either end is a wrong number. A sentence
   keeps its head and gives way at the tail, because it is read from the front
   and its subject is there.

   Only a reading that overruns its column is folded. [fit_middle] pads a short
   reading out to the column on the left, which left no slack for this to place
   and made {!Right} a column that declared an alignment it never got: every
   count and size drew flush left under a right-aligned name. *)
let pad cell text =
  let fitted =
    if Masc_tui_message_layout.display_width text <= cell.width then text
    else
      match cell.fold with
      | Fold_middle -> Masc_tui_message_layout.fit_middle cell.width text
      | Fold_tail -> Masc_tui_message_layout.fit_width text cell.width
  in
  let slack =
    max 0 (cell.width - Masc_tui_message_layout.display_width fitted)
  in
  match cell.align with
  | Left -> fitted ^ String.make slack ' '
  | Right -> String.make slack ' ' ^ fitted

let line ~pick ~dress cells =
  String.concat separator
    (List.map (fun cell -> dress cell (pad cell (pick cell))) cells)

(* Column names carry no reading, so they carry no reading's colour. The header
   wears whatever the caller dressed the line in. *)
let header_row cells =
  line ~pick:(fun cell -> cell.header) ~dress:(fun _ text -> text) cells

(* Columns the width left out: a cut-off count, never "+N" (RFC
   tui-one-screen-grammar 6.3). *)
let dropped_columns_badge ~ko dropped =
  if dropped <= 0 then None
  else
    Some
      (Masc_tui_value.Count.more ~ko dropped
       ^ if ko then "열" else if dropped = 1 then " col" else " cols")

let trim_trailing_spaces s =
  let len = ref (String.length s) in
  while !len > 0 && Char.equal s.[!len - 1] ' ' do
    decr len
  done;
  if !len = String.length s then s else String.sub s 0 !len

(* Place [badge] inside the widest left-aligned column header whose trailing
   slack holds [" · " ^ badge] whole. This keeps every column at its exact
   width and preserves right-aligned trailing headers (e.g. numeric counts)
   instead of cutting them off the right edge. *)
let place_badge_in_left_slack ~badge cells =
  let suffix = " \xc2\xb7 " ^ badge in
  let suffix_cells = Masc_tui_message_layout.display_width suffix in
  let best =
    List.mapi
      (fun index cell ->
        match cell.align with
        | Right -> None
        | Left ->
            let header_cells =
              Masc_tui_message_layout.display_width cell.header
            in
            let slack = cell.width - header_cells in
            if header_cells <= cell.width && slack >= suffix_cells then
              Some (index, slack)
            else None)
      cells
    |> List.filter_map Fun.id
    |> List.fold_left
         (fun acc ((_, slack) as cand) ->
           match acc with
           | None -> Some cand
           | Some (_, best_slack) ->
               if slack > best_slack then Some cand else acc)
         None
  in
  match best with
  | None -> None
  | Some (target_index, _) ->
      let updated =
        List.mapi
          (fun index cell ->
            if index = target_index then
              { cell with header = cell.header ^ suffix }
            else cell)
          cells
      in
      Some (header_row updated)

let header_row_with_dropped ~ko ~inner_width ~dropped cells =
  let base = header_row cells in
  match dropped_columns_badge ~ko dropped with
  | None -> base
  | Some badge ->
    let trimmed = trim_trailing_spaces base in
    let badge_cells = Masc_tui_message_layout.display_width badge in
    let trimmed_cells = Masc_tui_message_layout.display_width trimmed in
    if trimmed_cells + cell_gap + badge_cells <= inner_width then
      trimmed ^ String.make (inner_width - trimmed_cells - badge_cells) ' ' ^ badge
    else
      let in_slack =
        if used_width cells <= inner_width then
          place_badge_in_left_slack ~badge cells
        else None
      in
      match in_slack with
      | Some placed -> placed
      | None ->
          if inner_width >= badge_cells + cell_gap + 1 then
            let keep = inner_width - badge_cells - cell_gap in
            Masc_tui_message_layout.fit_width trimmed keep ^ separator ^ badge
          else base

let row ?(close = default_close) cells =
  line
    ~pick:(fun cell -> cell.value)
    ~dress:(fun cell text ->
      if String.equal cell.style "" then text else cell.style ^ text ^ close)
    cells
