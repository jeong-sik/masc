(** alphaTex text to a score.

    The subset read: the directives [\title], [\tempo], [\ts] and [\tuning],
    and the lone [.] that ends them; durations [:1] [:2] [:4] [:8] [:16];
    notes [fret.string] with an optional [.dur], the fret one or two digits or
    [x]; chords [(…).dur]; rests [r] and [r.dur]; and bars [|]. A beat that
    says its own duration sets it for the beats after it. [\title], [\tempo]
    and [\ts] are read and checked and carry nothing into the score.

    Technique markup in braces -- a [{…}] after a beat or on a chord member --
    marks its note and changes nothing else. Markup that changes a beat's
    length ([{d}], [{tu 3}], [{gr}]) fails the score.

    Anything else fails too. No word is skipped: a skipped word would take
    its beat with it and move every note after it. *)

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

(** Why a text is not a score in the subset. *)
type failure =
  | Unclosed of unclosed
  | Closes_nothing of char  (** a [)] or [}] with nothing open *)
  | Backslash_without_name
  | Unknown_directive of string  (** the name, without its backslash *)
  | Missing_argument of directive_argument
  | Second_tuning
  | Tuning_after_music
  | Quoted_without_title
  | Duration_outside_subset of string  (** the duration as written *)
  | Chord_dot_without_duration
  | Empty_chord
  | Not_a_note of string  (** the word as written *)
  | Fret_out_of_range of string  (** more digits than a fret has *)
  | Chord_string_twice of int  (** the string two chord members share *)
  | Effect_without_note
  | Unsupported_rhythm of string  (** the markup: a dot, a tuplet, a grace note *)
  | No_music  (** directives alone: no note and no rest *)
  | Too_many_strings of int
  | String_past_tuning of { string : int; strings : int }

val failure_text : failure -> string
(** The failure in a sentence a reader can show. *)

(** Counts are in sixteenth notes. *)

type note = {
  fret : string;  (** as written; [x] for a dead note *)
  on_string : int;  (** 1 is the highest string; always one the tuning has *)
  marked : bool;  (** technique markup rode on it *)
}

type beat = {
  start : int;  (** from the start of its measure *)
  span : int;
  notes : note list;  (** [[]] is a rest; at most one note on a string *)
}

type measure = {
  units : int;  (** the sum of its beats' spans *)
  beats : beat list;  (** never empty *)
}

type t = {
  tuning : string list;  (** line names, highest string first; 1 to 12 *)
  measures : measure list;  (** never empty *)
}

val read : string -> (t, failure) result
(** The music in the text: each beat on its count, or why the text is not a
    score in the subset. *)
