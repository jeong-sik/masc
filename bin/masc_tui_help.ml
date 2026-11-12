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

(* One column of the folded sheet: the sections set in it, the last first, and
   the rows they take with a blank row between two sections. *)
type column = { sections : string list list; height : int }

let empty_column = { sections = []; height = 0 }

let add_section column section =
  let gap = match column.sections with [] -> 0 | _ :: _ -> 1 in
  { sections = section :: column.sections;
    height = column.height + gap + List.length section }

let column_rows column =
  List.concat
    (List.mapi
       (fun index section -> if index = 0 then section else "" :: section)
       (List.rev column.sections))

(* Each section, whole and in the order written, goes under the shorter column,
   the left one when they are as tall. A heading stays above its own rows; a
   column cut at a line count starts under no heading, partway through someone
   else's keys.

   The sections were set two to a row, left then right, so the shorter of each
   pair stood beside blank rows. Measured at 100x30 on the Dashboard, the slash
   commands (138 rows) stood beside the surface's own keys (20 rows), and 32%
   of the sheet's cells were blank. *)
let fold_sections sections =
  let left, right =
    List.fold_left
      (fun (left, right) section ->
        if right.height < left.height then (left, add_section right section)
        else (add_section left section, right))
      (empty_column, empty_column) sections
  in
  zip (column_rows left) (column_rows right)

let sheet ?(header = []) ~cols lines =
  let body =
    if cols < two_column_minimum_cols then lines
    else begin
      let width = column_width ~cols in
      let row (l, r) =
        Message_layout.fit_width l width ^ "  " ^ Message_layout.fit_width r width
      in
      List.map row (fold_sections (sections lines))
    end
  in
  header @ body

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
