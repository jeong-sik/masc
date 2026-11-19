module Message_layout = Masc_tui_message_layout

let two_column_minimum_cols = 96
let three_column_minimum_cols = 132

(* The gutter the two columns leave: one border and one pad on each side,
   plus a 2-cell gap between columns (4 + 2 = 6). Three columns add one more
   2-cell gap (4 + 4 = 8). *)
let column_gutter_cols = 6
let three_column_gutter_cols = 8

let columns_for ~cols =
  if cols >= three_column_minimum_cols then 3
  else if cols >= two_column_minimum_cols then 2
  else 1

let column_width ~cols = (cols - column_gutter_cols) / 2
let three_column_width ~cols = (cols - three_column_gutter_cols) / 3

let line_cells ~cols =
  match columns_for ~cols with
  | 3 -> three_column_width ~cols
  | 2 -> column_width ~cols
  | _ -> Masc_tui_frame.inner_width ~cols

let rec zip left right =
  match left, right with
  | [], [] -> []
  | l :: lt, [] -> (l, "") :: zip lt []
  | [], r :: rt -> ("", r) :: zip [] rt
  | l :: lt, r :: rt -> (l, r) :: zip lt rt

let rec zip3 c1 c2 c3 =
  match c1, c2, c3 with
  | [], [], [] -> []
  | _ ->
      let hd_tl = function [] -> ("", []) | h :: t -> (h, t) in
      let a, t1 = hd_tl c1 in
      let b, t2 = hd_tl c2 in
      let c, t3 = hd_tl c3 in
      (a, b, c) :: zip3 t1 t2 t3

type block =
  | Whole of string list
  | Parted of { first : string list; rest : string list }

(* What the columns are cut between. A [Parted] block is two pieces, its
   first part and the rest after it, so the fold may cut between them. The
   rest piece is made only here, right after the piece of its own heading;
   [right_column_rows] leans on that when a right column opens with one. *)
type piece =
  | Block of string list
  | Rest of string list

let pieces blocks =
  List.concat_map
    (function
      | Whole rows -> [ Block rows ]
      | Parted { first; rest } -> [ Block first; Rest rest ])
    blocks

(* The rows of these pieces down one column. A block after another piece
   leaves a blank row between them; the rest of a parted section runs
   straight on under its first part, so a section whose two parts land in one
   column reads as it was written.

   The sheet used to take its lines as text and part its sections at blank
   lines, so the cut part opened with a row of one space -- blank to the eye
   and not to the parting -- that stood level with the heading. Where both
   parts came to one column that row sat under the blank between them, and
   the reader saw two empty rows inside one section. *)
let column_rows pieces =
  List.concat
    (List.mapi
       (fun index piece ->
         match piece with
         | Block rows -> if index = 0 then rows else "" :: rows
         | Rest rows -> rows)
       pieces)

(* The row of its column where the last of these pieces begins. *)
let last_piece_row pieces =
  match List.rev pieces with
  | [] | [ _ ] -> 0
  | _ :: earlier -> List.length (column_rows (List.rev earlier)) + 1

(* The right column's rows beside these left ones. A right column that opens
   with the rest of a parted section has that section's first part as the
   left column's last piece, so the rest starts its first key level with the
   first part's first key, under the heading's row. It started level with the
   left column's first row, so with the Candle details above the Operations
   keys its first key sat beside the Candle rows. *)
let right_column_rows_aligned ~left_offset ~left right =
  match right with
  | Rest _ :: _ ->
      let offset = left_offset + last_piece_row left + 1 in
      (offset, List.init offset (fun _ -> "") @ column_rows right)
  | Block _ :: _ | [] -> (0, column_rows right)

let right_column_rows ~left right =
  snd (right_column_rows_aligned ~left_offset:0 ~left right)

(* The left column takes the first pieces and the right one the rest, cut
   where the taller of the two is shortest; on a tie the left one takes more.
   Each piece stays whole, and the order written runs down the left column
   and on into the right one, so the rest of a parted section can only come
   after its heading. A block is never parted here: one long block -- the
   slash commands on the full sheet -- stands whole in one column, and the
   cut balances the rest around it.

   Each section used to go under whichever column was shorter. That kept the
   columns level, but a block set before a parted section -- the live Candle
   details on the Operations sheet -- made the left column the shorter one
   when the second part came: at 120x40 five keys stood under the Candle rows
   with no heading, and their heading sat in the right column beside them.
   Before that the sections were set two to a row, and at 100x30 on the
   Dashboard 32% of the sheet's cells were blank; the cut at the shortest
   taller column keeps that gain where the order allows it.

   Each cut's two columns are made once and kept with the cut, so the one
   chosen is drawn from the rows it was measured by. *)
let fold_pieces pieces =
  let columns count =
    let left = List.filteri (fun index _ -> index < count) pieces in
    let right = List.filteri (fun index _ -> index >= count) pieces in
    (column_rows left, right_column_rows ~left right)
  in
  let taller (left, right) = max (List.length left) (List.length right) in
  let first = columns 0 in
  let left, right =
    List.fold_left
      (fun best count ->
        let candidate = columns count in
        if taller candidate <= taller best then candidate else best)
      first
      (List.init (List.length pieces) (fun index -> index + 1))
  in
  zip left right

let fold_three_pieces pieces =
  let n = List.length pieces in
  if n = 0 then []
  else
    let slice lo hi =
      List.filteri (fun index _ -> index >= lo && index < hi) pieces
    in
    let columns i j =
      let p1 = slice 0 i in
      let p2 = slice i j in
      let p3 = slice j n in
      let c1 = column_rows p1 in
      let c2_offset, c2 = right_column_rows_aligned ~left_offset:0 ~left:p1 p2 in
      let _, c3 = right_column_rows_aligned ~left_offset:c2_offset ~left:p2 p3 in
      (c1, c2, c3)
    in
    let tallest (c1, c2, c3) =
      max (List.length c1) (max (List.length c2) (List.length c3))
    in
    let best = ref (columns n n) in
    (* Scan from left-filled splits downwards so earlier columns are never left
       blank on a height tie, and never leave column 2 empty while column 3
       holds pieces (j > i whenever i < n). *)
    for i = n - 1 downto 1 do
      for j = n downto i + 1 do
        let candidate = columns i j in
        if tallest candidate < tallest !best then best := candidate
      done
    done;
    let c1, c2, c3 = !best in
    zip3 c1 c2 c3

let sheet ~cols blocks =
  let ps = pieces blocks in
  match columns_for ~cols with
  | 3 ->
      let width = three_column_width ~cols in
      let row (a, b, c) =
        Message_layout.fit_width a width
        ^ "  "
        ^ Message_layout.fit_width b width
        ^ "  "
        ^ Message_layout.fit_width c width
      in
      List.map row (fold_three_pieces ps)
  | 2 ->
      let width = column_width ~cols in
      let row (l, r) =
        Message_layout.fit_width l width ^ "  " ^ Message_layout.fit_width r width
      in
      List.map row (fold_pieces ps)
  | _ -> column_rows ps

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
      [ Parted { first = heading :: List.concat first; rest = List.concat rest } ]

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
