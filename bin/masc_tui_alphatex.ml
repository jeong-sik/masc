(* alphaTex → ASCII tablature.

   [Masc_tui_alphatex_score] reads the text into measures of beats. Here the
   measures are laid across the pane and drawn: [systems] decides which
   measures share a row, and drawing writes them out. *)

module Score = Masc_tui_alphatex_score

type tab_failure =
  | Unreadable of Score.failure
  | Too_wide of { needed : int; available : int }

let failure_text = function
  | Unreadable failure -> Score.failure_text failure
  | Too_wide { needed; available } ->
      Printf.sprintf "one measure needs %d cells and this pane has %d" needed available

(* {1 Systems}

   A sixteenth note is [cells_per_unit] character cells in its measure. That
   is one until a fret would touch the slot after it: two-digit frets on
   eighth notes drew [1210], which reads as four notes. A measure takes the
   smallest count that leaves each of its frets a dash before the next slot.
   It is the measure's own count: one crowded measure widens and the rest of
   the score stays as it was.

   A system is the run of measures drawn side by side. Measures fill a system
   until the next one would pass the pane, and the tab is its systems top to
   bottom -- the way printed tablature breaks at bar lines. A measure is never
   split, so one wider than the pane on its own is the failure. The widths
   are known before anything is drawn, so a measure the pane cannot hold
   fails before a cell of it is allocated: no measure costs more than a pane's
   width for each string. The whole tab still grows with the score -- about
   three lines of pane for every measure of whole rests on twelve strings. *)

(* What a note writes on its line: its fret, and a [*] after it when it
   carried technique markup that is not drawn. *)
let note_text (note : Score.note) = if note.marked then note.fret ^ "*" else note.fret

(* The rhythm line names each beat's length with one letter at its first
   cell, the way ASCII tab writes them: [w h q e s] for the whole, half,
   quarter, eighth and sixteenth the reader's subset allows. The reader
   refuses any other count, so a span without a letter here is a span the
   subset gained without this line gaining its letter; it draws blank
   rather than a wrong letter. *)
let rhythm_letter (beat : Score.beat) =
  match beat.span with
  | 16 -> Some 'w'
  | 8 -> Some 'h'
  | 4 -> Some 'q'
  | 2 -> Some 'e'
  | 1 -> Some 's'
  | _ -> None

let cells_per_unit (measure : Score.measure) =
  List.fold_left
    (fun cells (beat : Score.beat) ->
      List.fold_left
        (fun cells note ->
          let needed = String.length (note_text note) + 1 in
          max cells ((needed + beat.span - 1) / beat.span))
        cells beat.notes)
    1 measure.beats

(* The line names share one column, so a two-letter name (Eb) does not push
   its line a cell to the right of the others. Every cell is one ASCII
   character -- a line name, a fret, a dash, a bar -- so a length is a width. *)
let name_width (score : Score.t) =
  List.fold_left (fun widest name -> max widest (String.length name)) 0 score.tuning

(* The barlines a measure brings. The left edge adds past the bar line the
   measure shares with the one before it -- a [:] for an [\ro], an ending
   tag, or both -- and the right edge is whole, a [:|xN|] for an [\rc N].
   The close edge ends at a barline so the next bar's marks join past one:
   without it a count would run into them ([:|x21|]). A plain measure adds
   nothing on the left and one [|] on the right, as before. *)
let left_marks (measure : Score.measure) =
  let start = if measure.repeat_start then ":" else "" in
  match measure.endings with
  | [] -> start
  | _ :: _ as endings ->
      start ^ String.concat "," (List.map string_of_int endings) ^ "|"

let right_marks (measure : Score.measure) =
  match measure.repeat_end with
  | None -> "|"
  | Some count -> ":|x" ^ string_of_int count ^ "|"

let systems ~max_width (score : Score.t) =
  let lead = name_width score + 1 in
  let rec fill systems current used = function
    | [] ->
        Ok
          (List.rev
             (match current with
              | [] -> systems
              | _ :: _ -> List.rev current :: systems))
    | (measure : Score.measure) :: rest ->
        let width =
          String.length (left_marks measure)
          + (cells_per_unit measure * measure.units)
          + String.length (right_marks measure)
        in
        if lead + width > max_width then
          Error (Too_wide { needed = lead + width; available = max_width })
        else (
          match current with
          | _ :: _ when used + width > max_width ->
              fill (List.rev current :: systems) [ measure ] (lead + width) rest
          | _ -> fill systems (measure :: current) (used + width) rest)
  in
  fill [] [] lead score.measures

(* {1 Drawing} *)

let draw_measure ~strings (measure : Score.measure) =
  let cells = cells_per_unit measure in
  let rows = Array.init (strings + 1) (fun _ -> Bytes.make (cells * measure.units) '-') in
  List.iter
    (fun (beat : Score.beat) ->
      (match rhythm_letter beat with
       | Some letter -> Bytes.set rows.(strings) (cells * beat.start) letter
       | None -> ());
      List.iter
        (fun (note : Score.note) ->
          (* [Score.read] kept the string within the tuning and [cells_per_unit]
             made the slot wider than the text. *)
          let text = note_text note in
          Bytes.blit_string text 0 rows.(note.on_string - 1) (cells * beat.start)
            (String.length text))
        beat.notes)
    measure.beats;
  rows

let draw ?(rhythm = false) (score : Score.t) systems =
  let strings = List.length score.tuning in
  let name_width = name_width score in
  let system_lines system =
    (* The drawn rows keep the measures' order, one block of rows per
       measure, so the barlines below join the measure they belong to. The
       rhythm row rides last, under the lowest string, and shares the
       measures' barlines. *)
    let drawn = List.map (draw_measure ~strings) system in
    List.mapi
      (fun line name ->
        let text = Buffer.create 32 in
        Buffer.add_string text name;
        Buffer.add_string text (String.make (name_width - String.length name) ' ');
        Buffer.add_char text '|';
        List.iter2
          (fun (measure : Score.measure) rows ->
            Buffer.add_string text (left_marks measure);
            Buffer.add_bytes text rows.(line);
            Buffer.add_string text (right_marks measure))
          system drawn;
        Buffer.contents text)
      (if rhythm then score.tuning @ [ "" ] else score.tuning)
  in
  (* A blank line between systems, none before the first. *)
  List.concat
    (List.mapi
       (fun index system ->
         if index = 0 then system_lines system else "" :: system_lines system)
       systems)

let render_tab ?(rhythm = false) ~max_width source =
  match Score.read source with
  | Error failure -> Error (Unreadable failure)
  | Ok score -> Result.map (draw ~rhythm score) (systems ~max_width score)
