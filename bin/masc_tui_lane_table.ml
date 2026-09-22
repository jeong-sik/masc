module Message_layout = Masc_tui_message_layout

let fit_width = Message_layout.fit_width

type reading = {
  label : string;
  slots : string;
}

type columns = {
  label_cells : int;
  slots_cells : int;
  observed_cells : int;
}

let status_cells = 14
let ok_fail_cancel_cells = 14
let p50_cells = 6
let active_cells = 6
let runs_cells = 4

(* One column and the next. *)
let gap_cells = 2
let gap = String.make gap_cells ' '

(* The row's indent, its mark, and the space after it. The header leaves the
   whole field blank. *)
let mark_field_cells = 4

(* A name past this is a name the table is not the place to read; the selected
   lane's block under the table prints it whole. *)
let label_cap_cells = 24

(* A slot list narrower than this says which provider and nothing else, which
   is not worth a column; below it the list leaves and the block under the
   table is where it is read. *)
let slots_floor_cells = 16

(* What the slot list may take while the histogram is still drawn beside it.
   With the histogram gone the cap has nothing left to protect, and the list
   takes what it needs of the room instead of leaving the row blank behind a
   reading it cut. *)
let slots_shared_cap_cells = 28

(* The same for the observed histogram, which is the wider of the two: a
   runtime id and a count. *)
let observed_floor_cells = 20

(* What a row spends before its two measured columns: the mark field, the
   name, the status word, the two counts, the outcome triple, p50, and the gap
   between each. It ends at p50; a measured column pays for the gap that
   brings it. The header is laid out on the same numbers, so the two cannot
   place a column differently. *)
let fixed_cells ~label_cells =
  mark_field_cells + label_cells + gap_cells + status_cells + gap_cells
  + active_cells + gap_cells + runs_cells + gap_cells + ok_fail_cancel_cells
  + gap_cells + p50_cells

let pad_left text cells =
  let width = Message_layout.display_width text in
  if width >= cells then fit_width text cells
  else String.make (cells - width) ' ' ^ text

let widest header value_of cap readings =
  List.fold_left
    (fun widest reading ->
      max widest (Message_layout.display_width (value_of reading)))
    (Message_layout.display_width header)
    readings
  |> min cap

(* The table's two measured columns. Both lists can run past any width, and a
   list cut at the end of the line is half a runtime id under a half-word
   header. So a column with no room is left out, and the one that stays is
   fitted to the room there is; the selected lane's block under the table
   prints both lists whole. *)
let columns ~inner readings =
  let label_cells =
    widest "LANE" (fun reading -> reading.label) label_cap_cells readings
  in
  let room = max 0 (inner - fixed_cells ~label_cells) in
  let wanted = widest "SLOTS" (fun reading -> reading.slots) max_int readings in
  let shared = min wanted slots_shared_cap_cells in
  let rest_after cells = room - gap_cells - cells - gap_cells in
  if room >= gap_cells + shared && rest_after shared >= observed_floor_cells
  then { label_cells; slots_cells = shared; observed_cells = rest_after shared }
  else
    let alone = min wanted (room - gap_cells) in
    if alone >= slots_floor_cells then
      { label_cells; slots_cells = alone; observed_cells = 0 }
    else { label_cells; slots_cells = 0; observed_cells = 0 }

(* The counts come before the slot list. They are what a reader compares down
   the column, and they are fixed-width; the slot list is the one cell that
   can run long, and the block under the list prints the selected lane's slots
   in full, so it is the cell to lose first when the frame is narrow. *)
let tail columns ~slots ~observed =
  match columns.slots_cells > 0, columns.observed_cells > 0 with
  | false, _ -> ""
  | true, false -> gap ^ fit_width slots columns.slots_cells
  | true, true ->
    gap ^ fit_width slots columns.slots_cells ^ gap
    ^ fit_width observed columns.observed_cells

(* The header the rows share, so a reader meets each label once instead of on
   every row: the rows carried "slots", "active", "runs", "ok/fail/cancel",
   "p50" and "observed" as words of their own, which beside the roster pane
   cut every row at "runs 12" and left the failure counts off the screen for
   all five lanes. The mark's field is blank here. *)
let header columns width =
  fit_width
    (String.concat gap
       [ String.make mark_field_cells ' ' ^ fit_width "LANE" columns.label_cells
       ; fit_width "STATUS" status_cells
       ; pad_left "ACTIVE" active_cells
       ; pad_left "RUNS" runs_cells
       ; fit_width "OK/FAIL/CANCEL" ok_fail_cancel_cells
       ; fit_width "P50" p50_cells
       ]
    ^ tail columns ~slots:"SLOTS" ~observed:"OBSERVED")
    width
