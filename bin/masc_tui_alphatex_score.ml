(* alphaTex text to a score: measures of beats placed on their counts, or the
   reason the text is not a score in the subset. Tokens first, then beats.
   Nothing here knows how wide a pane is or what a cell looks like. *)

type unclosed =
  | Comment
  | Quoted_string
  | Effect_group
  | Chord

type directive_argument =
  | Title_text
  | Subtitle_text
  | Artist_text
  | Section_text
  | Key_signature_name
  | Clef_name
  | Instrument_name
  | Tempo_number
  | Time_signature_numbers
  | Tuning_notes
  | Repeat_count
  | Alternate_ending_numbers

type failure =
  | Unclosed of unclosed
  | Closes_nothing of char
  | Backslash_without_name
  | Unknown_directive of string
  | Missing_argument of directive_argument
  | Second_tuning
  | Tuning_after_music
  | Invalid_tuning_group of string
  | Additional_track
  | Additional_staff
  | Unsupported_track_properties of string
  | Unsupported_staff_properties of string
  | Unsupported_instrument of string
  | Instrument_without_tuning
  | Instrument_after_music
  | Invalid_key_signature of string
  | Invalid_clef of string
  | Key_signature_after_note
  | Clef_after_note
  | Section_after_note
  | Quoted_without_metadata
  | Duration_outside_subset of string
  | Chord_dot_without_duration
  | Empty_chord
  | Not_a_note of string
  | Fret_out_of_range of string
  | Chord_string_twice of int
  | Tie_without_note of int
  | Tie_to_dead_note of int
  | Effect_without_note
  | Unsupported_rhythm of string
  | No_music
  | Too_many_strings of int
  | String_past_tuning of { string : int; strings : int }
  | Repeat_count_out_of_range of string
  | Alternate_ending_out_of_range of string
  | Repeat_without_bar

(* How a note sounds on its beat: picked, picked dead ([x] where the fret
   goes), or held on from the earlier note on its string ([-] there). *)
type attack =
  | Struck
  | Muted
  | Tied

type note = {
  fret : string;
  on_string : int;
  marked : bool;
  attack : attack;
}

(* A beat's duration, the way a reader shows it: the plain lengths, the dot
   that adds half again, the double dot that adds half and a quarter, the
   tuplet that divides what the plain length would take, and the grace note
   that takes no time at all. A beat the parser cannot time — a tuplet on a
   length too small to divide — has no duration. *)
type duration =
  | Plain of int
  | Dotted of int
  | Double_dotted of int
  | Tuplet of int * int  (* base length, divide by *)
  | Grace
  | No_duration

type beat = {
  start : int;  (* in ticks, counted from the measure's first beat *)
  span : int;  (* in ticks *)
  dur : duration;  (* how the beat reads, for a cell to draw *)
  marked : bool;  (* a rhythm effect rode on it, and a cell draws that *)
  notes : note list;
}

type measure = {
  ticks : int;  (* the ticks a whole measure takes *)
  beats : beat list;
  repeat_start : bool;
  repeat_end : int option;
  endings : int list;
}

type t = {
  tuning : string list;
  measures : measure list;
  title : string option;
  subtitle : string option;
  tempo : int option;
  time_signature : (int * int) option;
}

(* A failure quotes the text that caused it, and that text is as long as its
   author made it. A reader shows its start. *)
let quoted_limit = 24

let quoted text =
  let shown =
    if String.length text <= quoted_limit then text
    else String_util.utf8_prefix ~max_bytes:quoted_limit text ^ "\xe2\x80\xa6"
  in
  (* The text is the author's, and the sentence is printed. The terminal
     sanitizer every other TUI row uses escapes C0, DEL, C1 (raw and UTF-8),
     malformed UTF-8 and invisible code points such as bidi controls. It runs
     after the cut, so the limit counts the author's characters, not the
     escapes. *)
  Masc.Tui_terminal_text.sanitize_terminal_text shown

let failure_text = function
  | Unclosed Comment -> "an unclosed comment"
  | Unclosed Quoted_string -> "an unclosed quoted string"
  | Unclosed Effect_group -> "an unclosed effect group"
  | Unclosed Chord -> "an unclosed chord"
  | Closes_nothing char -> Printf.sprintf "a '%c' that closes nothing" char
  | Backslash_without_name -> "a '\\' with no directive name"
  | Unknown_directive name ->
      Printf.sprintf "the \\%s directive is not in the subset" (quoted name)
  | Missing_argument Title_text -> "\\title expects a quoted string"
  | Missing_argument Subtitle_text -> "\\subtitle expects a quoted string"
  | Missing_argument Artist_text -> "\\artist expects a quoted string"
  | Missing_argument Section_text -> "\\section expects a quoted string"
  | Missing_argument Key_signature_name -> "\\ks expects a key signature"
  | Missing_argument Clef_name -> "\\clef expects a clef name"
  | Missing_argument Instrument_name -> "\\instrument expects a guitar or bass program or name"
  | Missing_argument Tempo_number -> "\\tempo expects a number"
  | Missing_argument Time_signature_numbers -> "\\ts expects two numbers"
  | Missing_argument Tuning_notes -> "\\tuning expects note names"
  | Missing_argument Repeat_count -> "\\rc expects a number"
  | Missing_argument Alternate_ending_numbers -> "\\ae expects numbers"
  | Second_tuning -> "a second \\tuning directive"
  | Tuning_after_music -> "a \\tuning after the first note"
  | Invalid_tuning_group text ->
      Printf.sprintf "\\tuning expects only note names in (%s)" (quoted text)
  | Additional_track -> "only one initial \\track can be drawn"
  | Additional_staff -> "only one initial \\staff can be drawn"
  | Unsupported_track_properties text ->
      Printf.sprintf "track properties {%s} are outside the subset" (quoted text)
  | Unsupported_staff_properties text ->
      Printf.sprintf "staff properties {%s} do not select supported tablature" (quoted text)
  | Unsupported_instrument name ->
      Printf.sprintf "instrument \"%s\" is not a supported guitar or bass" (quoted name)
  | Instrument_without_tuning -> "an instrument requires explicit \\tuning before the music"
  | Instrument_after_music -> "an \\instrument after the first note cannot be drawn"
  | Invalid_key_signature name ->
      Printf.sprintf "\"%s\" is not a key signature" (quoted name)
  | Invalid_clef name ->
      Printf.sprintf "\"%s\" is not a clef" (quoted name)
  | Key_signature_after_note -> "\\ks requires a bar line before it after notes"
  | Clef_after_note -> "\\clef requires a bar line before it after notes"
  | Section_after_note -> "\\section requires a bar line before it after notes"
  | Quoted_without_metadata -> "a quoted string with no metadata directive before it"
  | Duration_outside_subset what ->
      Printf.sprintf "a duration \"%s\" outside :1 :2 :4 :8 :16" (quoted what)
  | Chord_dot_without_duration -> "a '.' after a chord with no duration"
  | Empty_chord -> "an empty chord"
  | Not_a_note word ->
      Printf.sprintf "\"%s\" is not a note (fret.string)" (quoted word)
  | Fret_out_of_range fret ->
      Printf.sprintf "fret %s is not a fret this draws" (quoted fret)
  | Chord_string_twice string ->
      Printf.sprintf "a chord with two notes on string %d" string
  | Tie_without_note string ->
      Printf.sprintf "a tie on string %d with no note on that string in its bar or the three before"
        string
  | Tie_to_dead_note string -> Printf.sprintf "a tie on string %d holds a dead note" string
  | Effect_without_note -> "an effect with no note before it"
  | Unsupported_rhythm markup ->
      Printf.sprintf "{%s} changes a beat's length, which this does not draw"
        (quoted markup)
  | No_music -> "no notes or rests"
  | Too_many_strings strings -> Printf.sprintf "a tuning of %d strings" strings
  | String_past_tuning { string; strings } ->
      Printf.sprintf "string %d on a %d-string tuning" string strings
  | Repeat_count_out_of_range count ->
      Printf.sprintf "a repeat count of \"%s\" is not 1 or more" (quoted count)
  | Alternate_ending_out_of_range ending ->
      Printf.sprintf "an alternate ending of \"%s\" is not 1 to 31" (quoted ending)
  | Repeat_without_bar -> "a repeat sign with no bar"

(* A beat's length in sixteenth notes, the unit every position is counted in. *)
let units_of_digits = function
  | "1" -> Some 1
  | "2" -> Some 2
  | "4" -> Some 4
  | "8" -> Some 8
  | "16" -> Some 16
  | _ -> None

(* The default length before a [:n] says one: a quarter note. *)
let quarter = 4

let is_whitespace = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false
let is_digit char = char >= '0' && char <= '9'
let is_letter char = (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z')

(* {1 Tokens}

   A token is one directive, one quoted string, one effect group, one chord
   bracket, one bar, or one whitespace-delimited word. A quote, group, chord
   or block comment that never closes is a hard error: guessing its boundary
   would mis-time every beat after it. *)

type directive =
  | Title
  | Subtitle
  | Artist
  | Track
  | Staff
  | Instrument
  | Key_signature
  | Clef
  | Section
  | Tempo
  | Time_signature
  | Tuning
  | Repeat_open
  | Repeat_close
  | Alternate_endings

type token =
  | Tk_directive of directive
  | Tk_unknown_directive of string
  | Tk_quoted of string  (* metadata text, escapes resolved *)
  | Tk_effect of string  (* a [{…}] group, its text between the braces *)
  | Tk_chord of string * int option  (* the bracketed members, [.dur] in units *)
  | Tk_bar
  | Tk_word of string

let directive_of_word = function
  | "title" -> Some Title
  | "subtitle" -> Some Subtitle
  | "artist" -> Some Artist
  | "track" -> Some Track
  | "staff" -> Some Staff
  | "instrument" -> Some Instrument
  | "ks" -> Some Key_signature
  | "clef" -> Some Clef
  | "section" -> Some Section
  | "tempo" -> Some Tempo
  | "ts" -> Some Time_signature
  | "tuning" -> Some Tuning
  | "ro" -> Some Repeat_open
  | "rc" -> Some Repeat_close
  | "ae" -> Some Alternate_endings
  | _ -> None

let tokenize source =
  let limit = String.length source in
  let rec scan tokens index =
    if index >= limit then Ok (List.rev tokens)
    else
      let char = source.[index] in
      if is_whitespace char then scan tokens (index + 1)
      else if index + 1 < limit && char = '/' && source.[index + 1] = '/' then begin
        let rec line i = if i >= limit || source.[i] = '\n' then i else line (i + 1) in
        scan tokens (line index)
      end
      else if index + 1 < limit && char = '/' && source.[index + 1] = '*' then begin
        let rec block i =
          if i + 1 >= limit then None
          else if source.[i] = '*' && source.[i + 1] = '/' then Some (i + 2)
          else block (i + 1)
        in
        match block (index + 2) with
        | Some stop -> scan tokens stop
        | None -> Error (Unclosed Comment)
      end
      else if char = '\\' then
        if index + 1 < limit && is_letter source.[index + 1] then begin
          let rec word i = if i < limit && is_letter source.[i] then word (i + 1) else i in
          let stop = word (index + 1) in
          let name = String.sub source (index + 1) (stop - index - 1) in
          let token =
            match directive_of_word name with
            | Some directive -> Tk_directive directive
            | None -> Tk_unknown_directive name
          in
          scan (token :: tokens) stop
        end
        else Error Backslash_without_name
      else if char = '"' then begin
        (* A backslash keeps the character after it, so an escaped quote does
           not end a metadata string. *)
        let rec quoted i =
          if i >= limit then None
          else if source.[i] = '\\' then quoted (i + 2)
          else if source.[i] = '"' then Some i
          else quoted (i + 1)
        in
        match quoted (index + 1) with
        | Some close ->
            let inner = String.sub source (index + 1) (close - index - 1) in
            let text = Buffer.create (String.length inner) in
            let rec unescape i =
              if i < String.length inner then
                if inner.[i] = '\\' && i + 1 < String.length inner then begin
                  Buffer.add_char text inner.[i + 1];
                  unescape (i + 2)
                end else begin
                  Buffer.add_char text inner.[i];
                  unescape (i + 1)
                end
            in
            unescape 0;
            scan (Tk_quoted (Buffer.contents text) :: tokens) (close + 1)
        | None -> Error (Unclosed Quoted_string)
      end
      else if char = '{' then begin
        match String.index_from_opt source index '}' with
        | Some close ->
            let text = String.sub source (index + 1) (close - index - 1) in
            scan (Tk_effect text :: tokens) (close + 1)
        | None -> Error (Unclosed Effect_group)
      end
      else if char = '(' then begin
        (* A member's effect group may hold parentheses of its own
           ([{b (0 4)}]), so the bracket closes at the first [)] outside
           braces. *)
        let rec chord i braces =
          if i >= limit then None
          else
            match source.[i] with
            | '{' -> chord (i + 1) (braces + 1)
            | '}' when braces > 0 -> chord (i + 1) (braces - 1)
            | ')' when braces = 0 -> Some i
            | _ -> chord (i + 1) braces
        in
        match chord (index + 1) 0 with
        | None -> Error (Unclosed Chord)
        | Some close ->
            let inner = String.sub source (index + 1) (close - index - 1) in
            (* An optional [.dur] rides on the closing bracket. *)
            let after = close + 1 in
            if after < limit && source.[after] = '.' then begin
              let rec digits i =
                if i < limit && is_digit source.[i] then digits (i + 1) else i
              in
              let stop = digits (after + 1) in
              if stop = after + 1 then Error Chord_dot_without_duration
              else
                match units_of_digits (String.sub source (after + 1) (stop - after - 1)) with
                | Some units -> scan (Tk_chord (inner, Some units) :: tokens) stop
                | None ->
                    Error (Duration_outside_subset (String.sub source after (stop - after)))
            end
            else scan (Tk_chord (inner, None) :: tokens) after
      end
      else if char = '|' then scan (Tk_bar :: tokens) (index + 1)
      else if char = ')' || char = '}' then Error (Closes_nothing char)
      else begin
        let rec word i =
          if i >= limit then i
          else
            match source.[i] with
            | ' ' | '\t' | '\n' | '\r' | '(' | ')' | '{' | '}' | '"' | '|' | '\\' -> i
            | _ -> word (i + 1)
        in
        let stop = word index in
        scan (Tk_word (String.sub source index (stop - index)) :: tokens) stop
      end
  in
  scan [] 0

(* {1 Beats}

   The parse is strict: a token outside the subset fails the score rather than
   being given a meaning. A word that is not a duration, a note or a rest is
   not skipped -- skipped, it would take its beat with it and every note after
   it would sit on the wrong count. Recognized presentation metadata is read
   with its own argument shape. Technique markup in braces keeps the note's
   count, string and fret and marks it. Rhythm markup must have a supported
   duration interpretation; otherwise the score fails. *)

let default_tuning = [ "e"; "B"; "G"; "D"; "A"; "E" ]

(* More lines than any fretted instrument has; past it the input is not a
   tuning, and each line is a row in every measure a reader draws. *)
let max_strings = 12

(* A fret is one or two digits, or [x] for a dead note. Longer digit runs are
   not frets. *)
let max_fret_digits = 2

(* What stands where the fret goes: a fret, [x] for a dead note, or [-] for
   a tie, which has no fret of its own until the note it holds is found. *)
type written =
  | Fret of string
  | Dead
  | Tie

type item_error =
  | Item_not_a_note
  | Item_bad_duration of string
  | Item_fret_out_of_range of string

(* [fret.string] with an optional [.dur], and nothing after it. *)
let note_item word =
  let limit = String.length word in
  let rec digits i = if i < limit && is_digit word.[i] then digits (i + 1) else i in
  let fret_stop =
    if limit > 0 && (word.[0] = 'x' || word.[0] = '-') then 1 else digits 0
  in
  if fret_stop = 0 || fret_stop >= limit || word.[fret_stop] <> '.' then
    Error Item_not_a_note
  else if fret_stop > max_fret_digits then
    Error (Item_fret_out_of_range (String.sub word 0 fret_stop))
  else begin
    let string_stop = digits (fret_stop + 1) in
    if string_stop = fret_stop + 1 then Error Item_not_a_note
    else
      match int_of_string_opt (String.sub word (fret_stop + 1) (string_stop - fret_stop - 1)) with
      | None -> Error Item_not_a_note
      | Some on_string ->
          let written =
            match word.[0] with
            | 'x' -> Dead
            | '-' -> Tie
            | _ -> Fret (String.sub word 0 fret_stop)
          in
          let note = (written, on_string) in
          if string_stop = limit then Ok (note, None)
          else if word.[string_stop] <> '.' then Error Item_not_a_note
          else begin
            let dur_stop = digits (string_stop + 1) in
            if dur_stop = string_stop + 1 || dur_stop <> limit then Error Item_not_a_note
            else
              match
                units_of_digits (String.sub word (string_stop + 1) (dur_stop - string_stop - 1))
              with
              | Some units -> Ok (note, Some units)
              | None ->
                  Error (Item_bad_duration (String.sub word string_stop (dur_stop - string_stop)))
          end
  end

let item_failure word = function
  | Item_not_a_note -> Not_a_note word
  | Item_bad_duration what -> Duration_outside_subset what
  | Item_fret_out_of_range fret -> Fret_out_of_range fret

(* The rhythm effect words, and the lengths they can ride on. *)
let dot_effect word = word = "d" || word = "dd"
let tuplet_effect word = word = "tu"
let grace_effect word = word = "gr"

(* A rhythm effect reads a beat's length. Inside a chord there is no single
   beat for it to change, so [chord_notes] rejects it rather than draw the
   note at a length the effect did not take. *)
let chord_rhythm_effect text =
  let words =
    text
    |> String.map (fun char -> if is_whitespace char then ' ' else char)
    |> String.split_on_char ' '
    |> List.filter (fun word -> not (String.equal word ""))
  in
  if List.exists dot_effect words || List.exists tuplet_effect words
     || List.exists grace_effect words
  then Some (String.concat " " words)
  else None

(* The ticks a whole note takes: every other length is a fraction of it, so
   one unit serves them all and a tuplet divides cleanly. *)
let whole_note_ticks = 384
let ticks_of_unit unit = whole_note_ticks / unit

(* The ticks a duration takes, or none when a tuplet rides on a length too
   small to divide. *)
let span_of_duration = function
  | Plain unit -> Some (ticks_of_unit unit)
  | Dotted unit -> Some ((ticks_of_unit unit * 3) / 2)
  | Double_dotted unit -> Some ((ticks_of_unit unit * 7) / 4)
  | Tuplet (unit, divide) ->
      (* [divide] notes sound where [divide - 1] would: three in the time of
         two, five in the time of four. *)
      let base = ticks_of_unit unit in
      let numerator = base * (divide - 1) in
      if numerator mod divide = 0 then Some (numerator / divide) else None
  | Grace -> Some 0
  | No_duration -> None

(* The ticks a plain unit names, for a length read before a beat carries it. *)
let ticks_of_said said = span_of_duration (Plain said)

(* A note names a string the tuning has. The tuning is settled before the
   first note ([Tuning_after_music]), so this is known as each note is read. *)
let on_tuning ~strings on_string =
  if on_string < 1 || on_string > strings then
    Error (String_past_tuning { string = on_string; strings })
  else Ok on_string

(* The text a dead note draws where its fret goes, as alphaTex writes it. *)
let dead_fret = "x"

(* A written note with its fret known. A tie takes the fret of the note it
   holds, which [held] finds by string among the beats already read. A tie
   that holds a dead note is refused: alphaTab 1.8.4 copies only the dead
   note's internal fret 0 and reads the tie as a held open string, [(0)]. *)
let sounding_note ~held written on_string =
  match written with
  | Fret fret -> Ok { fret; on_string; marked = false; attack = Struck }
  | Dead -> Ok { fret = dead_fret; on_string; marked = false; attack = Muted }
  | Tie -> (
      match held on_string with
      | None -> Error (Tie_without_note on_string)
      | Some { attack = Muted; _ } -> Error (Tie_to_dead_note on_string)
      | Some { fret; attack = Struck | Tied; _ } ->
          Ok { fret; on_string; marked = false; attack = Tied })

(* The bracketed members, whitespace apart. A chord's time is the bracket's
   [.dur] alone, so a member carries none. A member may carry technique markup
   in braces, written against it or after a space, which marks that note. Two
   notes on one string cannot both be drawn in the cell they share, so a chord
   never holds more notes than the tuning has strings. A tied member holds a
   note from an earlier beat, never one of its own chord. *)
let chord_notes ~strings ~held inner =
  let ( let* ) = Result.bind in
  let limit = String.length inner in
  let rec members found index =
    if index >= limit then Ok (List.rev found)
    else if is_whitespace inner.[index] then members found (index + 1)
    else if inner.[index] = '{' then
      match String.index_from_opt inner index '}' with
      | None -> Error (Unclosed Effect_group)
      | Some close ->
          let markup = String.sub inner (index + 1) (close - index - 1) in
          (* A chord sounds as one beat: a rhythm effect inside it (a dot, a
             tuplet, a grace) cannot change the beat's length the way one on a
             lone note does -- there is no "latest beat" inside the chord for
             it to apply to. Reading it as a no-op would draw the dotted note
             at its plain length and pull every beat after it one count early,
             so the chord is rejected instead of silently misread. Technique
             markup ({v}, {f}, ...) still marks the member it rides. *)
          (match found with
           | (word, _) :: earlier ->
               (match chord_rhythm_effect markup with
                | Some rhythm -> Error (Unsupported_rhythm rhythm)
                | None -> members ((word, true) :: earlier) (close + 1))
           | [] -> Error Effect_without_note)
    else begin
      let rec word_stop i =
        if i < limit && (not (is_whitespace inner.[i])) && inner.[i] <> '{' then
          word_stop (i + 1)
        else i
      in
      let stop = word_stop index in
      members ((String.sub inner index (stop - index), false) :: found) stop
    end
  in
  let rec notes placed = function
    | [] -> Ok (List.rev placed)
    | (word, marked) :: rest -> (
        match note_item word with
        | Ok (_, Some _) -> Error (Not_a_note word)
        | Error error -> Error (item_failure word error)
        | Ok ((written, on_string), None) ->
            let* on_string = on_tuning ~strings on_string in
            if List.exists (fun earlier -> earlier.on_string = on_string) placed then
              Error (Chord_string_twice on_string)
            else
              let* note = sounding_note ~held written on_string in
              notes ({ note with marked } :: placed) rest)
  in
  let* found = members [] 0 in
  match found with
  | [] -> Error Empty_chord
  | _ :: _ -> notes [] found

(* A beat while the score is being read: how long it lasts and what sounds.
   Its count within the measure is fixed once the measure is whole. *)
type sounding = {
  s_dur : duration;
  s_span : int;
  s_notes : note list;  (* [] is a rest *)
  s_marked : bool;  (* a rhythm effect rode on it, and a cell draws that *)
  s_bar : int;  (* the bar alphaTab puts it in, which a tie's search counts *)
}

(* The repeat signs read since the last bar line, waiting for the open
   measure to close: an [\ro], the latest [\rc] count, and every [\ae]
   number. A sign belongs to the bar it stands in. *)
type marks = {
  m_start : bool;
  m_end : int option;
  m_endings : int list;
}

let no_marks = { m_start = false; m_end = None; m_endings = [] }

let marks_pending marks =
  marks.m_start || Option.is_some marks.m_end || not (List.is_empty marks.m_endings)

(* Measures and the open measure are both kept newest beat first, so the beat
   an effect or a trailing duration belongs to is at hand whichever side of a
   bar line it is on. A closed measure keeps the signs its bar carried. *)
type builder = {
  b_tuning : string list option;
  b_track_declared : bool;
  b_staff_declared : bool;
  b_instrument_declared : bool;
  b_default : int;
  b_measures : (marks * sounding list) list;  (* newest measure first, each newest beat first *)
  b_beats : sounding list;  (* the open measure, newest beat first *)
  b_marks : marks;  (* the signs of the open measure *)
  b_title : string option;  (* the last [\title] said *)
  b_subtitle : string option;  (* the last [\subtitle] said *)
  b_tempo : int option;  (* the last [\tempo] that fit an int *)
  b_ts : (int * int) option;  (* the last [\ts] whose numbers fit *)
  b_bar : int;  (* alphaTab's bar count so far, for a tie's search *)
  b_bar_has_beat : bool;  (* a beat stands in alphaTab's current bar *)
}

(* A beat that says its own length sets the length for the beats after it,
   the way a [:n] does. [said] is the unit a trailing [.n] names; the tick
   span is the unit's ticks, found now so a length the ticks cannot hold
   fails here, before another beat reads it as the new default. *)
let push_beat ?said notes state =
  if state.b_instrument_declared && Option.is_none state.b_tuning then
    Error Instrument_without_tuning
  else
  let unit = Option.value said ~default:state.b_default in
  let dur = Plain unit in
  match span_of_duration dur with
  | Some span ->
      Ok
        { state with
          b_beats =
            { s_dur = dur; s_span = span; s_notes = notes; s_marked = false; s_bar = state.b_bar }
            :: state.b_beats
        ; b_default = unit
        ; b_bar_has_beat = true
        }
  | None -> Error (Duration_outside_subset (Printf.sprintf ":%d" unit))

(* The words inside an effect group, read the way the group reads: a dot
   dots, [tu] with a number divides, [gr] takes the note before its time.
   A group that holds both a dot and a tuplet is not a rhythm this draws:
   the two change one beat's length different ways, and a cell that drew
   both would draw neither. *)
let effect_rhythm text : (int -> duration) option =
  let words =
    String.map (fun char -> if is_whitespace char then ' ' else char) text
    |> String.split_on_char ' '
    |> List.filter (fun word -> not (String.equal word ""))
  in
  let dots = List.filter dot_effect words in
  let tuplets = List.filter tuplet_effect words in
  let graces = List.filter grace_effect words in
  let tuplet_divide = function
    | [ "tu"; n ] -> int_of_string_opt n
    | _ -> None
  in
  if List.length words = 0 then None
  else
    match dots, tuplets, graces with
    | [ "dd" ], [], [] -> Some (fun unit -> Double_dotted unit)
    | [ "d" ], [], [] -> Some (fun unit -> Dotted unit)
    | [], _ :: _, [] when List.length words = 2 && List.exists tuplet_effect words -> (
        match tuplet_divide words with
        (* Three in the time of two is the only tuplet the ticks divide
           exactly on every length the reader allows: a quarter is 64, an
           eighth 32, a sixteenth 16. A five-tuplet (or any other count)
           would read a length the ticks cannot hold -- a quarter is 96, and
           96 times four is not divisible by five -- and pull every later
           beat onto the wrong count. *)
        | Some 3 -> Some (fun unit -> Tuplet (unit, 3))
        | _ -> None)
    | [], [], [ "gr" ] -> Some (fun _ -> Grace)
    | _ -> None

(* The span one of [d], [dd], [tu] or [gr] gives a beat, from the plain unit
   the beat already had. A tuplet on a length the ticks cannot divide is not
   drawn, and neither is a group the words do not say. *)
let span_with_effect make_dur markup unit =
  let dur = make_dur unit in
  match span_of_duration dur with
  | Some span -> Ok (dur, span)
  | None -> Error (Unsupported_rhythm markup)

(* [d] or [dd] rides the latest beat; a tuplet does too, when it can. Either
   way the default is unchanged: the length after the beat is what it was. *)
let apply_effect_to_latest state ~make_dur ~markup =
  let ( let* ) = Result.bind in
  let unit_of_sound sounding =
    match sounding.s_dur with
    | Plain unit -> Some unit
    | Dotted unit -> Some unit
    | Double_dotted unit -> Some unit
    | Tuplet (unit, _) -> Some unit
    | Grace | No_duration -> None
  in
  let apply sounding =
    match unit_of_sound sounding with
    | None -> Error (Unsupported_rhythm markup)
    | Some unit ->
        let* dur, span = span_with_effect make_dur markup unit in
        Ok { sounding with s_dur = dur; s_span = span; s_marked = true }
  in
  match state.b_beats with
  | beat :: earlier ->
      let* beat = apply beat in
      Ok { state with b_beats = beat :: earlier }
  | [] -> (
      match state.b_measures with
      | (marks, beat :: earlier) :: measures ->
          let* beat = apply beat in
          Ok { state with b_measures = (marks, beat :: earlier) :: measures }
      | (_, []) :: _ | [] -> Error Effect_without_note)

let mark_latest_beat state =
  let mark (sounding : sounding) =
    { sounding with
      s_notes =
        List.map
          (fun (note : note) -> { note with marked = true })
          sounding.s_notes
    }
  in
  match state.b_beats, state.b_measures with
  | beat :: earlier, _ -> Ok { state with b_beats = mark beat :: earlier }
  | [], (marks, beat :: earlier) :: measures ->
      Ok { state with b_measures = (marks, mark beat :: earlier) :: measures }
  | [], ((_, []) :: _ | []) -> Error Effect_without_note

(* Digits: all of them, and the value fits an int or it does not -- a tempo
   too large to draw reads fine and the header omits it, the way an absent
   one is. The caller decides what the value means. *)
let number_argument missing tokens =
  match tokens with
  | Tk_word word :: rest ->
    (if String.length word > 0 && String.for_all is_digit word
     then Ok (int_of_string_opt word, rest)
     else Error (Missing_argument missing))
  | [] -> Error (Missing_argument missing)
  | (Tk_directive _ | Tk_unknown_directive _ | Tk_quoted _ | Tk_effect _ | Tk_chord _ | Tk_bar) :: _ ->
    Error (Missing_argument missing)

let text_argument missing = function
  | Tk_quoted text :: rest -> Ok (text, rest)
  | []
  | (Tk_directive _ | Tk_unknown_directive _ | Tk_effect _ | Tk_chord _ | Tk_bar | Tk_word _) :: _ ->
      Error (Missing_argument missing)

(* These signatures change standard notation, not the string/fret coordinates
   of tablature. Validate alphaTab's finite signature vocabulary before leaving
   that presentation metadata out of this projection. *)
let valid_key_signature name =
  match String.lowercase_ascii name with
  | "cb" | "gb" | "db" | "ab" | "eb" | "bb" | "f" | "c"
  | "g" | "d" | "a" | "e" | "b" | "f#" | "c#"
  | "cbmajor" | "gbmajor" | "dbmajor" | "abmajor" | "ebmajor" | "bbmajor"
  | "fmajor" | "cmajor" | "gmajor" | "dmajor" | "amajor" | "emajor"
  | "bmajor" | "f#major" | "c#major"
  | "abminor" | "ebminor" | "bbminor" | "fminor" | "cminor" | "gminor"
  | "dminor" | "aminor" | "eminor" | "bminor" | "f#minor" | "c#minor"
  | "g#minor" | "d#minor" | "a#minor" -> true
  | _ -> false

(* A clef, too, changes standard notation, not the string/fret coordinates of
   tablature. Validate alphaTab's finite clef vocabulary before leaving that
   presentation metadata out of this projection. *)
let valid_clef name =
  match String.lowercase_ascii name with
  | "neutral" | "n" | "c3" | "alto" | "c4" | "tenor"
  | "f4" | "bass" | "g2" | "treble" -> true
  | _ -> false

(* General MIDI programs 24--39 are guitars and basses. Their timbres do not
   alter explicit fret coordinates, but their default string sets differ, so
   accepting one below also requires an explicit tuning before any beat. *)
let fretted_instrument name =
  match String.lowercase_ascii name with
  | "acoustic guitar nylon" | "acoustic guitar steel" | "electric guitar jazz"
  | "electric guitar clean" | "electric guitar muted" | "overdriven guitar"
  | "distortion guitar" | "guitar harmonics" | "acoustic bass"
  | "electric bass finger" | "electric bass pick" | "fretless bass"
  | "slap bass 1" | "slap bass 2" | "synth bass 1" | "synth bass 2" -> true
  | _ ->
      String.length name > 0 && String.for_all is_digit name
      && (match int_of_string_opt name with
          | Some program -> program >= 24 && program <= 39
          | None -> false)

let track_properties text =
  let ( let* ) = Result.bind in
  let* tokens = tokenize text in
  match tokens with
  | [] -> Ok false
  | [ Tk_word "instrument"; (Tk_quoted name | Tk_word name) ] ->
      if fretted_instrument name then Ok true
      else Error (Unsupported_instrument name)
  | (Tk_directive _ | Tk_unknown_directive _ | Tk_quoted _ | Tk_effect _ | Tk_chord _ | Tk_bar | Tk_word _) :: _ ->
      Error (Unsupported_track_properties text)

let staff_properties text =
  let ( let* ) = Result.bind in
  let* tokens = tokenize text in
  match tokens with
  | [] | [ Tk_word "tabs" ]
  | [ Tk_word "score"; Tk_word "tabs" ]
  | [ Tk_word "tabs"; Tk_word "score" ] -> Ok ()
  | (Tk_directive _ | Tk_unknown_directive _ | Tk_quoted _ | Tk_effect _ | Tk_chord _ | Tk_bar | Tk_word _) :: _ ->
      Error (Unsupported_staff_properties text)

(* A track's two optional quoted arguments are its name and short name. They
   label one part; they are never music and do not change its timing. *)
let after_track_names = function
  | Tk_quoted _ :: Tk_quoted _ :: rest | Tk_quoted _ :: rest -> rest
  | ([] | (Tk_directive _ | Tk_unknown_directive _ | Tk_effect _ | Tk_chord _ | Tk_bar | Tk_word _) :: _) as tokens ->
      tokens

(* A tuning's note names, highest string first, as written: [E4] names its
   line [E]. The collection stops at the first token that is not a note name,
   which is where the music resumes. *)
let note_name word =
  let limit = String.length word in
  if limit < 2 then None
  else
    match word.[0] with
    | 'a'..'g' | 'A'..'G' ->
        let accidental = word.[1] = '#' || word.[1] = 'b' in
        let octave_start = if accidental then 2 else 1 in
        if octave_start >= limit then None
        else begin
          let rec digits i =
            if i >= limit then Some i
            else if is_digit word.[i] then digits (i + 1)
            else None
          in
          match digits octave_start with
          | Some _ -> Some (String.sub word 0 octave_start)
          | None -> None
        end
    | _ -> None

let collect_tuning tokens =
  let rec collect names tokens =
    match tokens with
    | Tk_word word :: rest ->
        (match note_name word with
         | Some name -> collect (name :: names) rest
         | None -> List.rev names, tokens)
    | [] -> List.rev names, tokens
    | (Tk_directive _ | Tk_unknown_directive _ | Tk_quoted _ | Tk_effect _ | Tk_chord _ | Tk_bar) :: _ ->
      List.rev names, tokens
  in
  match tokens with
  | Tk_chord (inner, None) :: rest ->
      let ( let* ) = Result.bind in
      let* members = tokenize inner in
      (match collect [] members with
       | names, [] -> Ok (names, rest)
       | _, _ :: _ -> Error (Invalid_tuning_group inner))
  | Tk_chord (inner, Some _) :: _ -> Error (Invalid_tuning_group inner)
  | []
  | (Tk_directive _ | Tk_unknown_directive _ | Tk_quoted _ | Tk_effect _ | Tk_bar | Tk_word _) :: _ ->
      Ok (collect [] tokens)

(* A repeat count is drawn, so unlike a tempo its size is this module's to
   refuse: all digits, fitting in an int, and a count that plays. A word
   that is no number is a missing count, the way a [\tempo] with no number
   is. *)
let repeat_count word =
  if String.length word = 0 || not (String.for_all is_digit word) then
    Error (Missing_argument Repeat_count)
  else
    match int_of_string_opt word with
    | Some count when count >= 1 -> Ok count
    | _ -> Error (Repeat_count_out_of_range word)

(* Alternate endings are the passes 1 to 31, the way alphaTab numbers them.
   The collection stops at the first token that is not a number, which is
   where the music resumes. alphaTab's syntax and the writer's canonical form
   wrap several endings in parentheses, [\ae (1 2 3)], which the tokenizer
   delivers as one chord token; its members are unpacked as that list. *)
let collect_endings tokens =
  let endings_of_members members =
    let parsed =
      List.map
        (fun member ->
          if String.length member > 0 && String.for_all is_digit member then
            int_of_string_opt member
          else None)
        members
    in
    let numbers = List.filter_map (fun ending -> ending) parsed in
    if
      List.for_all Option.is_some parsed
      && numbers <> []
      && List.for_all (fun ending -> ending >= 1 && ending <= 31) numbers
    then Some numbers
    else None
  in
  let rec collect found tokens =
    match tokens with
    | Tk_word word :: rest when String.length word > 0 && String.for_all is_digit word -> (
        match int_of_string_opt word with
        | Some ending when ending >= 1 && ending <= 31 -> collect (ending :: found) rest
        | _ -> Error (Alternate_ending_out_of_range word))
    | Tk_chord (inner, None) :: rest when found = [] -> (
        let members =
          String.split_on_char ' ' inner
          |> List.filter (fun member -> not (String.equal member ""))
        in
        match endings_of_members members with
        | Some endings -> collect (List.rev_append endings found) rest
        | None -> Error (Alternate_ending_out_of_range inner))
    | []
    | ( Tk_word _
      | Tk_chord (_, (None | Some _))
      | Tk_directive _
      | Tk_unknown_directive _
      | Tk_quoted _
      | Tk_effect _
      | Tk_bar )
      :: _ -> Ok (List.rev found, tokens)
  in
  collect [] tokens

let string_count state =
  List.length (Option.value state.b_tuning ~default:default_tuning)

(* The bars before a tie's own that alphaTab 1.8.4 looks back through for the
   note the tie holds (Note.findTieOrigin, _maxOffsetForSameLineSearch). *)
let tie_bars_back = 3

(* The note a tie on [on_string] holds, found the way alphaTab finds it: the
   latest earlier note on that string, past rests and notes on other strings,
   in the tie's bar or the three before it. The bars are alphaTab's, not the
   measures this reader draws: an empty bar counts as one, as alphaTab reads
   it as a bar of rest, and so does a bar a directive opened after a beat.
   With none there, alphaTab plays the tie as an open string; the reader
   refuses it instead. *)
let held_note state on_string =
  let earliest_bar = state.b_bar - tie_bars_back in
  Seq.append (List.to_seq state.b_beats)
    (Seq.concat_map (fun (_, beats) -> List.to_seq beats) (List.to_seq state.b_measures))
  |> Seq.take_while (fun (sounding : sounding) -> sounding.s_bar >= earliest_bar)
  |> Seq.find_map (fun (sounding : sounding) ->
         List.find_opt (fun (note : note) -> note.on_string = on_string) sounding.s_notes)

let beat_of_word state word =
  let ( let* ) = Result.bind in
  let limit = String.length word in
  if limit = 0 then Error (Not_a_note word)
  else
  match word.[0] with
  | ':' ->
      (match units_of_digits (String.sub word 1 (limit - 1)) with
       | Some units -> Ok { state with b_default = units }
       | None -> Error (Duration_outside_subset word))
  | 'r' | 'R' when limit = 1 ->
      (match ticks_of_said state.b_default with
       | Some _ -> push_beat [] state
       | None -> Error (Duration_outside_subset (Printf.sprintf ":%d" state.b_default)))
  | 'r' | 'R' when word.[1] = '.' ->
      (match units_of_digits (String.sub word 2 (limit - 2)) with
       | Some units ->
           (match ticks_of_said units with
            | Some _ -> push_beat ~said:units [] state
            | None -> Error (Duration_outside_subset (String.sub word 1 (limit - 1))))
       | None -> Error (Duration_outside_subset (String.sub word 1 (limit - 1))))
  (* A duration written after a beat's effects ([19.2{v f}.4]) arrives as a
     word of its own; it is that beat's length, and the length after it. *)
  | '.' when limit > 1 ->
      (match units_of_digits (String.sub word 1 (limit - 1)), state.b_beats with
       | Some unit, beat :: earlier ->
           let dur = Plain unit in
           (match span_of_duration dur with
            | Some span ->
                Ok
                  { state with
                    b_beats = { beat with s_dur = dur; s_span = span } :: earlier
                  ; b_default = unit
                  }
            | None -> Error (Duration_outside_subset word))
       | Some _, [] -> Error (Not_a_note word)
       | None, _ -> Error (Duration_outside_subset word))
  | '0'..'9' | 'x' | '-' ->
      (match note_item word with
       | Ok ((written, on_string), said) ->
           let* on_string = on_tuning ~strings:(string_count state) on_string in
           let* note = sounding_note ~held:(held_note state) written on_string in
           push_beat ?said [ note ] state
       | Error error -> Error (item_failure word error))
  | _ -> Error (Not_a_note word)

let started state =
  not (List.is_empty state.b_beats && List.is_empty state.b_measures)

(* The counts are settled once a measure is whole: each beat starts where the
   one before it ended. The bar's signs settle with it: an [\ro], the latest
   [\rc] count, and the [\ae] numbers as a set. *)
let place_beats marks soundings =
  let beats, ticks =
    List.fold_left
      (fun (beats, start) sounding ->
        { start
        ; span = sounding.s_span
        ; dur = sounding.s_dur
        ; marked = sounding.s_marked
        ; notes = sounding.s_notes
        }
        :: beats, start + sounding.s_span)
      ([], 0) soundings
  in
  { ticks
  ; beats = List.rev beats
  ; repeat_start = marks.m_start
  ; repeat_end = marks.m_end
  ; endings = List.sort_uniq Int.compare marks.m_endings
  }

let read source =
  let ( let* ) = Result.bind in
  let* tokens = tokenize source in
  let rec step state tokens =
    match tokens with
    | [] ->
        (* A sign with no bar of its own fails before the music is counted:
           with no bar it marks nothing, whether or not earlier bars sang. *)
        if List.is_empty state.b_beats && marks_pending state.b_marks then Error Repeat_without_bar
        else
          (* A bar line with nothing between it and the next -- a leading or a
             doubled [|] -- holds no beat and is no measure. *)
          let measures =
            List.rev ((state.b_marks, state.b_beats) :: state.b_measures)
            |> List.filter_map (function
                 | _, [] -> None
                 | marks, soundings -> Some (place_beats marks (List.rev soundings)))
          in
          let tuning = Option.value state.b_tuning ~default:default_tuning in
          (match measures with
           | [] -> Error No_music
           | _ :: _ ->
               Ok
                 { tuning
                 ; measures
                 ; title = state.b_title
                 ; subtitle = state.b_subtitle
                 ; tempo = state.b_tempo
                 ; time_signature = state.b_ts
                 })
    (* alphaTab 1.8.4 ends its bar at any directive that follows a beat in
       it, and the directive opens the next bar. The measure drawn here keeps
       the directive; only the bar count a tie's search reads moves on. *)
    | Tk_directive _ :: _ when state.b_bar_has_beat ->
        step { state with b_bar = state.b_bar + 1; b_bar_has_beat = false } tokens
    | Tk_directive Title :: rest ->
        let* text, after = text_argument Title_text rest in
        (* The latest title wins, the way the latest tempo does. *)
        step { state with b_title = Some text } after
    | Tk_directive Subtitle :: rest ->
        let* text, after = text_argument Subtitle_text rest in
        (* The latest subtitle wins, the way the latest title does. It rides
           the header behind the title. *)
        step { state with b_subtitle = Some text } after
    | Tk_directive Artist :: rest ->
        let* _, after = text_argument Artist_text rest in
        step state after
    | Tk_directive Section :: rest ->
        if not (List.is_empty state.b_beats) then Error Section_after_note
        else
        let* _, after = text_argument Section_text rest in
        (* The two-string form adds a section marker before its name. Neither
           label changes fret coordinates or starts another timeline. *)
        let after =
          match after with
          | Tk_quoted _ :: rest -> rest
          | ([] | (Tk_directive _ | Tk_unknown_directive _ | Tk_effect _ | Tk_chord _ | Tk_bar | Tk_word _) :: _) as tokens ->
              tokens
        in
        step state after
    | Tk_directive Key_signature :: rest ->
        if not (List.is_empty state.b_beats) then Error Key_signature_after_note
        else
        (match rest with
         | Tk_word name :: after ->
             if valid_key_signature name then step state after
             else Error (Invalid_key_signature name)
         | []
         | (Tk_directive _ | Tk_unknown_directive _ | Tk_quoted _ | Tk_effect _ | Tk_chord _ | Tk_bar) :: _ ->
             Error (Missing_argument Key_signature_name))
    | Tk_directive Clef :: rest ->
        if not (List.is_empty state.b_beats) then Error Clef_after_note
        else
        (match rest with
         | Tk_word name :: after ->
             if valid_clef name then step state after
             else Error (Invalid_clef name)
         | []
         | (Tk_directive _ | Tk_unknown_directive _ | Tk_quoted _ | Tk_effect _ | Tk_chord _ | Tk_bar) :: _ ->
             Error (Missing_argument Clef_name))
    | Tk_directive Track :: rest ->
        if state.b_track_declared || state.b_staff_declared || started state then
          Error Additional_track
        else
          let rest = after_track_names rest in
          let* has_instrument, after =
            match rest with
            | Tk_effect text :: after ->
                let* has_instrument = track_properties text in
                Ok (has_instrument, after)
            | []
            | (Tk_directive _ | Tk_unknown_directive _ | Tk_quoted _ | Tk_chord _ | Tk_bar | Tk_word _) :: _ ->
                Ok (false, rest)
          in
          step { state with b_track_declared = true;
            b_instrument_declared = state.b_instrument_declared || has_instrument } after
    | Tk_directive Instrument :: rest ->
        if started state then Error Instrument_after_music
        else
          (match rest with
           | (Tk_quoted name | Tk_word name) :: after ->
               if fretted_instrument name then
                 step { state with b_instrument_declared = true } after
               else Error (Unsupported_instrument name)
           | []
           | (Tk_directive _ | Tk_unknown_directive _ | Tk_effect _ | Tk_chord _ | Tk_bar) :: _ ->
               Error (Missing_argument Instrument_name))
    | Tk_directive Staff :: rest ->
        if state.b_staff_declared || started state then Error Additional_staff
        else
          let* after =
            match rest with
            | Tk_effect text :: after ->
                let* () = staff_properties text in
                Ok after
            | []
            | (Tk_directive _ | Tk_unknown_directive _ | Tk_quoted _ | Tk_chord _ | Tk_bar | Tk_word _) :: _ ->
                Ok rest
          in
          step { state with b_staff_declared = true } after
    | Tk_directive Tempo :: rest ->
        let* value, after = number_argument Tempo_number rest in
        step { state with b_tempo = value } after
    | Tk_directive Time_signature :: rest ->
        let* top, after = number_argument Time_signature_numbers rest in
        let* bottom, after = number_argument Time_signature_numbers after in
        let ts =
          match top, bottom with
          | Some top, Some bottom -> Some (top, bottom)
          | _ -> None
        in
        step { state with b_ts = ts } after
    | Tk_directive Tuning :: rest ->
        (match state.b_tuning with
         | Some _ -> Error Second_tuning
         (* The tuning names every line of the score, the measures already
            read included. *)
         | None when started state -> Error Tuning_after_music
         | None ->
             let* names, after = collect_tuning rest in
             (match List.length names with
              | 0 -> Error (Missing_argument Tuning_notes)
              | strings when strings > max_strings -> Error (Too_many_strings strings)
              | _ -> step { state with b_tuning = Some names } after))
    | Tk_directive Repeat_open :: rest ->
        step { state with b_marks = { state.b_marks with m_start = true } } rest
    | Tk_directive Repeat_close :: rest -> (
        match rest with
        | Tk_word word :: after -> (
            match repeat_count word with
            | Ok count ->
                step { state with b_marks = { state.b_marks with m_end = Some count } } after
            | Error failure -> Error failure)
        | []
        | ( Tk_directive _
          | Tk_unknown_directive _
          | Tk_quoted _
          | Tk_effect _
          | Tk_chord _
          | Tk_bar )
          :: _ -> Error (Missing_argument Repeat_count))
    | Tk_directive Alternate_endings :: rest -> (
        match collect_endings rest with
        | Error failure -> Error failure
        | Ok ([], _) -> Error (Missing_argument Alternate_ending_numbers)
        | Ok (endings, after) ->
            step
              { state with
                b_marks = { state.b_marks with m_endings = state.b_marks.m_endings @ endings }
              }
              after)
    | Tk_unknown_directive name :: _ -> Error (Unknown_directive name)
    | Tk_quoted _ :: _ -> Error Quoted_without_metadata
    | Tk_effect text :: rest -> (
        match effect_rhythm text with
        | Some make_dur ->
            (* [d], [dd], [tu] and [gr] change the latest beat's length. *)
            let* state = apply_effect_to_latest state ~make_dur ~markup:text in
            step state rest
        | None ->
            (* Markup that names a rhythm effect but does not form one of the
               supported shapes is not drawn. *)
            let words =
              String.map (fun char -> if is_whitespace char then ' ' else char) text
              |> String.split_on_char ' '
              |> List.filter (fun word -> not (String.equal word ""))
            in
            if List.exists (fun word -> dot_effect word || tuplet_effect word || grace_effect word) words then
              Error (Unsupported_rhythm text)
            else (
              (* Other markup decorates the note; the beat keeps its count. *)
              let* state = mark_latest_beat state in
              step state rest))
    | Tk_chord (inner, said) :: rest ->
        let* notes = chord_notes ~strings:(string_count state) ~held:(held_note state) inner in
        let* state = push_beat ?said notes state in
        step state rest
    | Tk_bar :: rest ->
        (* A sign on a bar with no beat marks a measure that is dropped, and
           with it the sign's meaning. *)
        if List.is_empty state.b_beats && marks_pending state.b_marks then Error Repeat_without_bar
        else
          step
            { state with
              b_measures = (state.b_marks, state.b_beats) :: state.b_measures
            ; b_beats = []
            ; b_marks = no_marks
            ; b_bar = state.b_bar + 1
            ; b_bar_has_beat = false
            }
            rest
    (* alphaTex ends its metadata with a lone [.]: it separates the directives
       from the music and is no beat. *)
    | Tk_word "." :: rest when not (started state) -> step state rest
    | Tk_word word :: rest ->
        let* state = beat_of_word state word in
        step state rest
  in
  step
    { b_tuning = None
    ; b_track_declared = false
    ; b_staff_declared = false
    ; b_instrument_declared = false
    ; b_default = quarter
    ; b_measures = []
    ; b_beats = []
    ; b_marks = no_marks
    ; b_title = None
    ; b_subtitle = None
    ; b_tempo = None
    ; b_ts = None
    ; b_bar = 0
    ; b_bar_has_beat = false
    }
    tokens
