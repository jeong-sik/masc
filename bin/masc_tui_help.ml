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

type block =
  | Whole of string list
  | Continued of string list

(* The rows of these blocks down one column. A whole section after another
   block leaves a blank row between them; the part [one_section] cut from a
   section runs straight on under the part above it, so a section whose two
   parts land in one column reads as it was written.

   The sheet used to take its lines as text and part its sections at blank
   lines, so the cut part opened with a row of one space -- blank to the eye
   and not to the parting -- that stood level with the heading. Where both
   parts came to one column that row sat under the blank between them, and
   the reader saw two empty rows inside one section. *)
let column_rows blocks =
  List.concat
    (List.mapi
       (fun index block ->
         match block with
         | Whole rows -> if index = 0 then rows else "" :: rows
         | Continued rows -> rows)
       blocks)

(* The row of its column where the last of these blocks begins. *)
let last_block_row blocks =
  match List.rev blocks with
  | [] | [ _ ] -> 0
  | _ :: earlier -> List.length (column_rows (List.rev earlier)) + 1

(* The right column's rows beside these left ones. A right column that opens
   with the cut part of the left column's last section starts its first key
   level with that section's first key, under the heading's row; it started
   level with the left column's first row, so with the Candle details above
   the Operations keys its first key sat beside the Candle rows. *)
let right_column_rows ~left right =
  match right with
  | Continued _ :: _ ->
      List.init (last_block_row left + 1) (fun _ -> "") @ column_rows right
  | Whole _ :: _ | [] -> column_rows right

(* The left column takes the first blocks and the right one the rest, cut
   where the taller of the two is shortest; on a tie the left one takes more.
   Each block stays whole, and the order written runs down the left column
   and on into the right one, so the part [one_section] cut from a section can
   only come after its heading. A block is never parted here: one long block
   -- the slash commands on the full sheet -- stands whole in one column, and
   the cut balances the rest around it.

   Each section used to go under whichever column was shorter. That kept the
   columns level, but a block set before a parted section -- the live Candle
   details on the Operations sheet -- made the left column the shorter one
   when the second part came: at 120x40 five keys stood under the Candle rows
   with no heading, and their heading sat in the right column beside them.
   Before that the sections were set two to a row, and at 100x30 on the
   Dashboard 32% of the sheet's cells were blank; the cut at the shortest
   taller column keeps that gain where the order allows it. *)
let fold_blocks blocks =
  let cut count =
    ( List.filteri (fun index _ -> index < count) blocks,
      List.filteri (fun index _ -> index >= count) blocks )
  in
  let columns count =
    let left, right = cut count in
    (column_rows left, right_column_rows ~left right)
  in
  let taller count =
    let left, right = columns count in
    max (List.length left) (List.length right)
  in
  let best =
    List.fold_left
      (fun best count -> if taller count <= taller best then count else best)
      0
      (List.init (List.length blocks + 1) Fun.id)
  in
  let left, right = columns best in
  zip left right

let sheet ~cols blocks =
  if cols < two_column_minimum_cols then column_rows blocks
  else
    let width = column_width ~cols in
    let row (l, r) =
      Message_layout.fit_width l width ^ "  " ^ Message_layout.fit_width r width
    in
    List.map row (fold_blocks blocks)

let one_section ~heading entries =
  let total = List.fold_left (fun sum entry -> sum + List.length entry) 0 entries in
  let half = (total + 1) / 2 in
  let rec first_part taken count = function
    | entry :: rest when count < half ->
        first_part (entry :: taken) (count + List.length entry) rest
    | rest -> (List.rev taken, rest)
  in
  match first_part [] 0 entries with
  | first, [] -> [ Whole (heading :: List.concat first) ]
  | first, (_ :: _ as rest) ->
      [ Whole (heading :: List.concat first); Continued (List.concat rest) ]

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
