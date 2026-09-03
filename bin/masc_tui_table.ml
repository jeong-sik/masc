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

type cell = {
  header : string;
  width : int;
  align : align;
  value : string;
  style : string;
}

let cell ?(align = Left) ?(style = "") ~header ~width value =
  { header; width; align; value; style }

(* A cell's dress closes back to the row's own, not to a bare reset: a reset
   would strip the dimming or the selection band the caller wrapped the whole
   row in, and the rest of the row after a coloured cell would come out
   undressed. *)
let default_close = "\027[0m"

let used_width ~gap cells =
  List.fold_left (fun total cell -> total + cell.width) 0 cells
  + (max 0 gap * max 0 (List.length cells - 1))

(* Fitted before it is padded, and folded in the middle rather than cut at one
   end: an identifier cut at the head reads as a different identifier, and a
   number cut at either end is a wrong number where a folded one is visibly
   incomplete. *)
let pad cell text =
  let fitted = Masc_tui_message_layout.fit_middle cell.width text in
  let slack =
    max 0 (cell.width - Masc_tui_message_layout.display_width fitted)
  in
  match cell.align with
  | Left -> fitted ^ String.make slack ' '
  | Right -> String.make slack ' ' ^ fitted

let line ~gap ~pick ~dress cells =
  String.concat
    (String.make (max 0 gap) ' ')
    (List.map (fun cell -> dress cell (pad cell (pick cell))) cells)

(* Column names carry no reading, so they carry no reading's colour. The header
   wears whatever the caller dressed the line in. *)
let header_row ~gap cells =
  line ~gap ~pick:(fun cell -> cell.header) ~dress:(fun _ text -> text) cells

let row ~gap ?(close = default_close) cells =
  line ~gap
    ~pick:(fun cell -> cell.value)
    ~dress:(fun cell text ->
      if String.equal cell.style "" then text else cell.style ^ text ^ close)
    cells
