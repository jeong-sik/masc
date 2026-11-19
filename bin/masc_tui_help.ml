module Message_layout = Masc_tui_message_layout

let two_column_minimum_cols = 96

(* The gutter the two columns leave: one border and one pad on each side. *)
let column_gutter_cols = 6

let column_width ~cols = (cols - column_gutter_cols) / 2

let line_cells ~cols =
  if cols < two_column_minimum_cols then Masc_tui_frame.inner_width ~cols
  else column_width ~cols

let rec zip left right =
  match left, right with
  | [], [] -> []
  | l :: lt, [] -> (l, "") :: zip lt []
  | [], r :: rt -> ("", r) :: zip [] rt
  | l :: lt, r :: rt -> (l, r) :: zip lt rt

(* The runs of lines between blank lines: a heading and its rows. *)
let sections lines =
  let close current found =
    match current with
    | [] -> found
    | _ :: _ -> List.rev current :: found
  in
  let rec gather current found = function
    | [] -> List.rev (close current found)
    | "" :: rest -> gather [] (close current found) rest
    | line :: rest -> gather (line :: current) found rest
  in
  gather [] [] lines

(* The rows of one column holding these sections, a blank row between two. *)
let column_rows sections =
  List.concat
    (List.mapi (fun index section -> if index = 0 then section else "" :: section) sections)

(* The left column takes the first sections and the right one the rest, cut
   where the taller of the two is shortest; on a tie the left one takes more.
   Each section stays whole, and the order written runs down the left column
   and on into the right one, so the part [one_section] cut from a section can
   only come after its heading.

   Each section used to go under whichever column was shorter. That kept the
   columns level, but a block set before a parted section -- the live Candle
   details on the Operations sheet -- made the left column the shorter one
   when the second part came: at 120x40 five keys stood under the Candle rows
   with no heading, and their heading sat in the right column beside them.
   Before that the sections were set two to a row, and at 100x30 on the
   Dashboard 32% of the sheet's cells were blank; the cut at the shortest
   taller column keeps that gain where the order allows it. *)
let fold_sections sections =
  let cut count =
    ( List.filteri (fun index _ -> index < count) sections,
      List.filteri (fun index _ -> index >= count) sections )
  in
  let taller count =
    let left, right = cut count in
    max (List.length (column_rows left)) (List.length (column_rows right))
  in
  let best =
    List.fold_left
      (fun best count -> if taller count <= taller best then count else best)
      0
      (List.init (List.length sections + 1) Fun.id)
  in
  let left, right = cut best in
  zip (column_rows left) (column_rows right)

let sheet ~cols lines =
  if cols < two_column_minimum_cols then lines
  else
    let width = column_width ~cols in
    let row (l, r) =
      Message_layout.fit_width l width ^ "  " ^ Message_layout.fit_width r width
    in
    List.map row (fold_sections (sections lines))

(* Blank to the eye and not to [sections], which parts columns at an empty
   line: it stands where the heading stands in the first column, so the two
   columns' first keys sit on one row. *)
let continuation_row = " "

let one_section ~cols ~heading entries =
  if cols < two_column_minimum_cols then heading :: List.concat entries
  else begin
    let total = List.fold_left (fun sum entry -> sum + List.length entry) 0 entries in
    let half = (total + 1) / 2 in
    let rec first_column taken count = function
      | entry :: rest when count < half ->
          first_column (entry :: taken) (count + List.length entry) rest
      | rest -> (List.rev taken, rest)
    in
    match first_column [] 0 entries with
    | left, [] -> heading :: List.concat left
    | left, (_ :: _ as right) ->
        (heading :: List.concat left)
        @ ("" :: continuation_row :: List.concat right)
  end

let filter_sections ~query ~heading sections =
  if String.equal query "" then sections
  else
    let holds text = Masc_tui_pick_list.lowercase_contains ~needle:query text in
    List.filter_map
      (fun (title, entries) ->
        if holds (heading title) then Some (title, entries)
        else
          match List.filter (fun (key, action) -> holds key || holds action) entries with
          | [] -> None
          | kept -> Some (title, kept))
      sections

type filter =
  | Off
  | Typing of string
  | Kept of string

let filter_query = function
  | Off -> ""
  | Typing query | Kept query -> query

type scope =
  | Here
  | Everything

let shows_everything filter scope =
  match scope with
  | Everything -> true
  | Here -> not (String.equal (filter_query filter) "")

type step =
  | Set_filter of { filter : filter; scroll_to_top : bool }
  | Widen
  | Close
  | Toggle_hints
  | Scroll of Masc_tui_scroll.key_move
  | Ignore

(* A key name that stands for text: one printable ASCII character, or a
   character outside ASCII, whose name leads with a byte from 0x80 up. *)
let names_text key =
  (String.length key = 1 && Char.code key.[0] >= 32)
  || (String.length key > 1 && Char.code key.[0] >= 0x80)

let retyped query = Set_filter { filter = Typing query; scroll_to_top = true }

let scrolled key =
  match Masc_tui_scroll.move_of_key key with
  | Some move -> Scroll move
  | None -> Ignore

let step filter ~scope ~key =
  match filter with
  | Typing query -> (
      match key with
      | "esc" -> Set_filter { filter = Off; scroll_to_top = true }
      | "\r" | "\n" ->
          let settled = if String.equal query "" then Off else Kept query in
          Set_filter { filter = settled; scroll_to_top = false }
      | "\127" | "\b" ->
          retyped (Masc_tui_message_layout.drop_last_utf8_scalar query)
      | "down" | "up" | "pageup" | "pagedown" -> scrolled key
      | text when names_text text ->
          retyped (query ^ Masc_tui_key_ime.latin_text text)
      | _ -> Ignore)
  | Kept _ when String.equal key "esc" ->
      Set_filter { filter = Off; scroll_to_top = true }
  | Off | Kept _ -> (
      match key with
      | "/" ->
          Set_filter { filter = Typing (filter_query filter); scroll_to_top = false }
      | "?" -> if shows_everything filter scope then Close else Widen
      | "esc" -> Close
      | "h" -> Toggle_hints
      | _ -> scrolled key)
