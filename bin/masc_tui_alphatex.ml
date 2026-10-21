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

(* What a note writes on its line: its fret, in parentheses when it is tied
   and held on rather than picked, and a [*] after it when it carried
   technique markup that is not drawn. alphaTab's own tablature hides a tied
   note inside a bar; this tab has no tie arc or stem to show it by, and a
   hidden note would read as a rest, so every tied note keeps its fret in the
   parentheses alphaTab gives one at the start of a bar. *)
let note_text (note : Score.note) =
  let fret =
    match note.attack with
    | Score.Struck | Score.Muted -> note.fret
    | Score.Tied -> "(" ^ note.fret ^ ")"
  in
  if note.marked then fret ^ "*" else fret

(* The rhythm line names each beat's length with one letter at its first
   cell, the way ASCII tab writes them: [w h q e s] for the whole, half,
   quarter, eighth and sixteenth the reader's subset allows. Counts are in
   ticks (a whole note 384), so the letter rides the plain length a beat
   still carries after a dot, a tuplet or a grace has changed its span. The
   reader refuses any other count, so a beat without a plain length here is
   one the rhythm effects reshaped; it draws blank rather than a wrong
   letter. *)
let rhythm_letter (beat : Score.beat) =
  match beat.dur with
  | Score.Plain 1 | Score.Double_dotted 1 -> Some 'w'
  | Score.Plain 2 | Score.Double_dotted 2 -> Some 'h'
  | Score.Plain 4 | Score.Double_dotted 4 -> Some 'q'
  | Score.Plain 8 | Score.Double_dotted 8 -> Some 'e'
  | Score.Plain 16 | Score.Double_dotted 16 -> Some 's'
  | Score.Dotted _ | Score.Tuplet _ | Score.Grace | Score.No_duration | Score.Plain _ | Score.Double_dotted _ ->
      None

(* The cells a measure draws: a cell is one ASCII character, and the ticks
   a cell holds is fixed, so a beat's width in cells is its ticks divided
   by the cell's plus the room its note text needs. *)
let ticks_per_cell = 24

(* The column a beat's notes draw at: the widest of its ticks and its note
   text, so a two-letter fret never runs into the beat that follows it, and
   the next beat starts past it. A beat the ticks do not fill alone (a
   tuplet, a two-letter fret in a sixteenth) still holds the column its text
   needs, and a column a grace note takes back gives the next beat one cell
   so the grace does not erase it. *)
let beat_width (beat : Score.beat) =
  let text_len =
    List.fold_left (fun len note -> len + String.length (note_text note) + 1) 0 beat.notes
  in
  if beat.span = 0 then
    (* A grace note takes no time, but its text still draws: as wide as the
       fret number, so a two-digit fret (12{gr}) is not erased by the note
       it leads into. It does not crowd the beat before it. *)
    max 1 text_len
  else
    let span_cells = (beat.span + ticks_per_cell - 1) / ticks_per_cell in
    max span_cells text_len

let beat_cells = beat_width

let measure_cells (measure : Score.measure) =
  List.fold_left (fun cells beat -> cells + beat_cells beat) 1 measure.beats

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

let measure_width (measure : Score.measure) =
  String.length (left_marks measure)
  + measure_cells measure
  + String.length (right_marks measure)

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
        let width = measure_width measure in
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
  let cells = measure_cells measure in
  let rows = Array.init (strings + 1) (fun _ -> Bytes.make cells '-') in
  (* Each beat takes the column after the one before it, so the beats never
     overlap and no note is dropped to keep inside the row. *)
  let (_ : int) =
    List.fold_left
      (fun column (beat : Score.beat) ->
        (match rhythm_letter beat with
         | Some letter ->
           if column < cells then Bytes.set rows.(strings) column letter
         | None -> ());
        List.iter
          (fun (note : Score.note) ->
            (* [Score.read] kept the string within the tuning and
               [beat_width] gave the beat at least as many cells as its
               text. *)
            let text = note_text note in
            if column + String.length text <= cells then
              Bytes.blit_string text 0 rows.(note.on_string - 1) column (String.length text))
          beat.notes;
        column + beat_width beat)
      0 measure.beats
  in
  rows

(* The header ahead of the tab: what the directives said, and nothing when
   none of them did. The title and subtitle are the author's text, shown as
   written between quotes -- %S is not used because it escapes every
   non-ASCII byte into decimal numbers, and these titles are not ASCII. The
   subtitle rides right behind the title. *)
let quoted_title title =
  let escaped = Buffer.create (String.length title) in
  String.iter
    (fun char ->
       if char = '"' || char = '\\' then Buffer.add_char escaped '\\';
       Buffer.add_char escaped char)
    title;
  "\"" ^ Buffer.contents escaped ^ "\""

let header_line (score : Score.t) =
  let pieces =
    (match score.tempo with
     | Some tempo -> [ Printf.sprintf "♩=%d" tempo ]
     | None -> [])
    @ (match score.time_signature with
       | Some (top, bottom) -> [ Printf.sprintf "%d/%d" top bottom ]
       | None -> [])
    @ (match score.title with
       | Some title -> [ quoted_title title ]
       | None -> [])
    @ (match score.subtitle with
       | Some subtitle -> [ quoted_title subtitle ]
       | None -> [])
  in
  match pieces with
  | [] -> None
  | _ :: _ -> Some (String.concat " · " pieces)

let draw ?(rhythm = false) (score : Score.t) systems =
  let strings = List.length score.tuning in
  let name_width = name_width score in
  (* The numbers are physical measures, counted across the systems, so the
     second system opens where the first one left off. *)
  let next_number = ref 1 in
  let number_row system =
    let lead = name_width + 1 in
    let width = lead + List.fold_left (fun sum m -> sum + measure_width m) 0 system in
    let row = Bytes.make width ' ' in
    let written_end = ref lead in
    let place at (measure : Score.measure) =
      let text = string_of_int !next_number in
      next_number := !next_number + 1;
      (* The number rides at the measure's first cell, past its left marks,
         the way fret cells do below. *)
      let start = at + String.length (left_marks measure) in
      Bytes.blit_string text 0 row start (String.length text);
      written_end := max !written_end (start + String.length text)
    in
    let (_ : int) =
      List.fold_left (fun at m -> place at m; at + measure_width m) lead system
    in
    Bytes.sub_string row 0 !written_end
  in
  let system_lines system =
    (* The drawn rows keep the measures' order, one block of rows per
       measure, so the barlines below join the measure they belong to. The
       rhythm row rides last, under the lowest string, and shares the
       measures' barlines. The number row rides first, above the highest
       string, at the measures' first cells. *)
    let drawn = List.map (draw_measure ~strings) system in
    number_row system
    :: List.mapi
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
  | Ok score ->
      Result.map
        (fun systems ->
           (match header_line score with
            | Some line -> [ line ]
            | None -> [])
           @ draw ~rhythm score systems)
        (systems ~max_width score)
