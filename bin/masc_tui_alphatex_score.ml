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
  | Tempo_number
  | Time_signature_numbers
  | Tuning_notes

type failure =
  | Unclosed of unclosed
  | Closes_nothing of char
  | Backslash_without_name
  | Unknown_directive of string
  | Missing_argument of directive_argument
  | Second_tuning
  | Tuning_after_music
  | Quoted_without_title
  | Duration_outside_subset of string
  | Chord_dot_without_duration
  | Empty_chord
  | Not_a_note of string
  | Fret_out_of_range of string
  | Chord_string_twice of int
  | Effect_without_note
  | Unsupported_rhythm of string
  | No_music
  | Too_many_strings of int
  | String_past_tuning of { string : int; strings : int }

type note = {
  fret : string;
  on_string : int;
  marked : bool;
}

type beat = {
  start : int;
  span : int;
  notes : note list;
}

type measure = {
  units : int;
  beats : beat list;
}

type t = {
  tuning : string list;
  measures : measure list;
}

(* A failure quotes the text that caused it, and that text is as long as its
   author made it. A reader shows its start. *)
let quoted_limit = 24

let quoted text =
  if String.length text <= quoted_limit then text
  else begin
    (* Back off a UTF-8 continuation byte so the cut lands between characters. *)
    let rec boundary index =
      if index > 0 && Char.code text.[index] land 0xC0 = 0x80 then boundary (index - 1)
      else index
    in
    String.sub text 0 (boundary quoted_limit) ^ "\xe2\x80\xa6"
  end

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
  | Missing_argument Tempo_number -> "\\tempo expects a number"
  | Missing_argument Time_signature_numbers -> "\\ts expects two numbers"
  | Missing_argument Tuning_notes -> "\\tuning expects note names"
  | Second_tuning -> "a second \\tuning directive"
  | Tuning_after_music -> "a \\tuning after the first note"
  | Quoted_without_title -> "a quoted string with no \\title before it"
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
  | Effect_without_note -> "an effect with no note before it"
  | Unsupported_rhythm markup ->
      Printf.sprintf "{%s} changes a beat's length, which this does not draw"
        (quoted markup)
  | No_music -> "no notes or rests"
  | Too_many_strings strings -> Printf.sprintf "a tuning of %d strings" strings
  | String_past_tuning { string; strings } ->
      Printf.sprintf "string %d on a %d-string tuning" string strings

(* A beat's length in sixteenth notes, the unit every position is counted in. *)
let units_of_digits = function
  | "1" -> Some 16
  | "2" -> Some 8
  | "4" -> Some 4
  | "8" -> Some 2
  | "16" -> Some 1
  | _ -> None

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
  | Tempo
  | Time_signature
  | Tuning

type token =
  | Tk_directive of directive
  | Tk_unknown_directive of string
  | Tk_quoted
  | Tk_effect of string  (* a [{…}] group, its text between the braces *)
  | Tk_chord of string * int option  (* the bracketed members, [.dur] in units *)
  | Tk_bar
  | Tk_word of string

let directive_of_word = function
  | "title" -> Some Title
  | "tempo" -> Some Tempo
  | "ts" -> Some Time_signature
  | "tuning" -> Some Tuning
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
           not end the string. The text itself is not drawn. *)
        let rec quoted i =
          if i >= limit then None
          else if source.[i] = '\\' then quoted (i + 2)
          else if source.[i] = '"' then Some i
          else quoted (i + 1)
        in
        match quoted (index + 1) with
        | Some close -> scan (Tk_quoted :: tokens) (close + 1)
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
   it would sit on the wrong count. The one thing passed over is technique
   markup in braces: the note it rides on still sounds, so it keeps its count,
   its string and its fret, and is marked. Markup that changes how long a beat
   lasts (a dot, a tuplet, a grace note) cannot be passed over the same way
   and fails the score. *)

let default_tuning = [ "e"; "B"; "G"; "D"; "A"; "E" ]

(* More lines than any fretted instrument has; past it the input is not a
   tuning, and each line is a row in every measure a reader draws. *)
let max_strings = 12

(* A fret is one or two digits, or [x] for a dead note. Longer digit runs are
   not frets. *)
let max_fret_digits = 2

type item_error =
  | Item_not_a_note
  | Item_bad_duration of string
  | Item_fret_out_of_range of string

(* [fret.string] with an optional [.dur], and nothing after it. *)
let note_item word =
  let limit = String.length word in
  let rec digits i = if i < limit && is_digit word.[i] then digits (i + 1) else i in
  let fret_stop = if limit > 0 && word.[0] = 'x' then 1 else digits 0 in
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
          let note = { fret = String.sub word 0 fret_stop; on_string; marked = false } in
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

(* An effect group either decorates a beat or changes how long it lasts. The
   second kind -- [d] and [dd] dot a beat, [tu] makes a tuplet, [gr] a grace
   note that takes no time -- moves every later note, so drawing the score
   without it would draw a different rhythm. *)
let effect_changes_length text =
  String.split_on_char ' ' text
  |> List.concat_map (String.split_on_char '\n')
  |> List.concat_map (String.split_on_char '\t')
  |> List.concat_map (String.split_on_char '\r')
  |> List.exists (fun word -> List.mem word [ "d"; "dd"; "tu"; "gr" ])

(* A note names a string the tuning has. The tuning is settled before the
   first note ([Tuning_after_music]), so this is known as each note is read. *)
let on_tuning ~strings note =
  if note.on_string < 1 || note.on_string > strings then
    Error (String_past_tuning { string = note.on_string; strings })
  else Ok note

(* The bracketed members, whitespace apart. A chord's time is the bracket's
   [.dur] alone, so a member carries none. A member may carry technique markup
   in braces, written against it or after a space, which marks that note. Two
   notes on one string cannot both be drawn in the cell they share, so a chord
   never holds more notes than the tuning has strings. *)
let chord_notes ~strings inner =
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
          if effect_changes_length markup then Error (Unsupported_rhythm markup)
          else (
            match found with
            | (word, _) :: earlier -> members ((word, true) :: earlier) (close + 1)
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
        | Ok (note, None) ->
            let* note = on_tuning ~strings note in
            if List.exists (fun earlier -> earlier.on_string = note.on_string) placed then
              Error (Chord_string_twice note.on_string)
            else notes ({ note with marked } :: placed) rest)
  in
  let* found = members [] 0 in
  match found with
  | [] -> Error Empty_chord
  | _ :: _ -> notes [] found

(* A beat while the score is being read: how long it lasts and what sounds.
   Its count within the measure is fixed once the measure is whole. *)
type sounding = {
  s_span : int;
  s_notes : note list;  (* [] is a rest *)
}

(* Measures and the open measure are both kept newest beat first, so the beat
   an effect or a trailing duration belongs to is at hand whichever side of a
   bar line it is on. *)
type builder = {
  b_tuning : string list option;
  b_default : int;
  b_measures : sounding list list;  (* newest measure first, each newest beat first *)
  b_beats : sounding list;          (* the open measure, newest beat first *)
}

(* A beat that says its own length sets the length for the beats after it,
   the way a [:n] does. *)
let push_beat ?said notes state =
  let span = Option.value said ~default:state.b_default in
  { state with b_beats = { s_span = span; s_notes = notes } :: state.b_beats; b_default = span }

let mark_latest_beat state =
  let mark beat = { beat with s_notes = List.map (fun note -> { note with marked = true }) beat.s_notes } in
  match state.b_beats, state.b_measures with
  | beat :: earlier, _ -> Ok { state with b_beats = mark beat :: earlier }
  | [], (beat :: earlier) :: measures ->
      Ok { state with b_measures = (mark beat :: earlier) :: measures }
  | [], ([] :: _ | []) -> Error Effect_without_note

(* Digits, and nothing is done with their value: a tempo is read and not
   drawn, so its size is not this module's to refuse. *)
let number_argument missing tokens =
  match tokens with
  | Tk_word word :: rest ->
    (if String.length word > 0 && String.for_all is_digit word
     then Ok rest
     else Error (Missing_argument missing))
  | [] -> Error (Missing_argument missing)
  | (Tk_directive _ | Tk_unknown_directive _ | Tk_quoted | Tk_effect _ | Tk_chord _ | Tk_bar) :: _ ->
    Error (Missing_argument missing)

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
    | (Tk_directive _ | Tk_unknown_directive _ | Tk_quoted | Tk_effect _ | Tk_chord _ | Tk_bar) :: _ ->
      List.rev names, tokens
  in
  collect [] tokens

let string_count state =
  List.length (Option.value state.b_tuning ~default:default_tuning)

let beat_of_word state word =
  let limit = String.length word in
  if limit = 0 then Error (Not_a_note word)
  else
  match word.[0] with
  | ':' ->
      (match units_of_digits (String.sub word 1 (limit - 1)) with
       | Some units -> Ok { state with b_default = units }
       | None -> Error (Duration_outside_subset word))
  | 'r' | 'R' when limit = 1 -> Ok (push_beat [] state)
  | 'r' | 'R' when word.[1] = '.' ->
      (match units_of_digits (String.sub word 2 (limit - 2)) with
       | Some units -> Ok (push_beat ~said:units [] state)
       | None -> Error (Duration_outside_subset (String.sub word 1 (limit - 1))))
  (* A duration written after a beat's effects ([19.2{v f}.4]) arrives as a
     word of its own; it is that beat's length, and the length after it. *)
  | '.' when limit > 1 ->
      (match units_of_digits (String.sub word 1 (limit - 1)), state.b_beats with
       | Some units, beat :: earlier ->
           Ok { state with b_beats = { beat with s_span = units } :: earlier; b_default = units }
       | Some _, [] -> Error (Not_a_note word)
       | None, _ -> Error (Duration_outside_subset word))
  | '0'..'9' | 'x' ->
      (match note_item word with
       | Ok (note, said) ->
           Result.map
             (fun note -> push_beat ?said [ note ] state)
             (on_tuning ~strings:(string_count state) note)
       | Error error -> Error (item_failure word error))
  | _ -> Error (Not_a_note word)

let started state =
  not (List.is_empty state.b_beats && List.is_empty state.b_measures)

(* The counts are settled once a measure is whole: each beat starts where the
   one before it ended. *)
let place_beats soundings =
  let beats, units =
    List.fold_left
      (fun (beats, start) sounding ->
        { start; span = sounding.s_span; notes = sounding.s_notes } :: beats, start + sounding.s_span)
      ([], 0) soundings
  in
  { units; beats = List.rev beats }

let read source =
  let ( let* ) = Result.bind in
  let* tokens = tokenize source in
  let rec step state tokens =
    match tokens with
    | [] ->
        (* A bar line with nothing between it and the next -- a leading or a
           doubled [|] -- holds no beat and is no measure. *)
        let measures =
          List.rev_map List.rev (state.b_beats :: state.b_measures)
          |> List.filter_map (function [] -> None | soundings -> Some (place_beats soundings))
        in
        let tuning = Option.value state.b_tuning ~default:default_tuning in
        (match measures with
         | [] -> Error No_music
         | _ :: _ -> Ok { tuning; measures })
    | Tk_directive Title :: rest ->
        (match rest with
         | Tk_quoted :: after -> step state after
         | [] -> Error (Missing_argument Title_text)
         | (Tk_directive _ | Tk_unknown_directive _ | Tk_effect _ | Tk_chord _ | Tk_bar | Tk_word _) :: _ ->
           Error (Missing_argument Title_text))
    | Tk_directive Tempo :: rest ->
        let* after = number_argument Tempo_number rest in
        step state after
    | Tk_directive Time_signature :: rest ->
        let* after = number_argument Time_signature_numbers rest in
        let* after = number_argument Time_signature_numbers after in
        step state after
    | Tk_directive Tuning :: rest ->
        (match state.b_tuning with
         | Some _ -> Error Second_tuning
         (* The tuning names every line of the score, the measures already
            read included. *)
         | None when started state -> Error Tuning_after_music
         | None ->
             let names, after = collect_tuning rest in
             (match List.length names with
              | 0 -> Error (Missing_argument Tuning_notes)
              | strings when strings > max_strings -> Error (Too_many_strings strings)
              | _ -> step { state with b_tuning = Some names } after))
    | Tk_unknown_directive name :: _ -> Error (Unknown_directive name)
    | Tk_quoted :: _ -> Error Quoted_without_title
    | Tk_effect text :: rest ->
        if effect_changes_length text then Error (Unsupported_rhythm text)
        else
          let* state = mark_latest_beat state in
          step state rest
    | Tk_chord (inner, said) :: rest ->
        let* notes = chord_notes ~strings:(string_count state) inner in
        step (push_beat ?said notes state) rest
    | Tk_bar :: rest ->
        step { state with b_measures = state.b_beats :: state.b_measures; b_beats = [] } rest
    (* alphaTex ends its metadata with a lone [.]: it separates the directives
       from the music and is no beat. *)
    | Tk_word "." :: rest when not (started state) -> step state rest
    | Tk_word word :: rest ->
        let* state = beat_of_word state word in
        step state rest
  in
  step { b_tuning = None; b_default = quarter; b_measures = []; b_beats = [] } tokens
