(** alphaTex text to a score.

    The subset read: the directives [\title], [\tempo], [\ts] and [\tuning],
    and the lone [.] that ends them; durations [:1] [:2] [:4] [:8] [:16];
    notes [fret.string] with an optional [.dur], the fret one or two digits or
    [x], or [-] for a tie; chords [(…).dur]; rests [r] and [r.dur]; and bars
    [|]. A tie holds the latest earlier note on its string, past rests and
    notes on other strings, in its bar or the three before it -- where
    alphaTab 1.8.4 looks. Those bars are counted as alphaTab counts them: an
    empty bar is one, and a directive after a beat opens the next one even
    though the measure drawn here keeps it. A tie with no such note, or one
    that holds a dead note, fails: alphaTab reads the first as a struck open
    string and the second as a held one, [(0)], neither of which [-] says. A
    beat that
    says its own duration sets it for the beats after it. [\title],
    [\subtitle], [\tempo] and [\ts] are kept on the score: the pane draws them
    on the header line ahead of the tab, with the subtitle behind the title. A
    tempo or signature whose digits do not fit an int is kept as [None] and the
    header omits it, the way an absent one is.

    Tuning accepts either bare note names or a parenthesized list, with every
    member checked. A single initial [\track] and [\staff] may describe the
    part. Track names and short names, [\artist], [\ks], [\clef] and [\section]
    are checked presentation metadata; this fret-and-string projection does not
    draw them. Key signatures and clefs do not change explicit fret numbers.
    Track
    properties and an initial standalone [\instrument] support a guitar or bass MIDI [instrument] (programs 24--39,
    or their standard names). Its playback timbre is not drawn, and an
    explicit [\tuning] before music is required rather than guessing the
    instrument's strings. Staff properties may select [tabs] or [score tabs];
    a staff with no properties uses the default that includes tabs. Additional
    tracks/staves, structure after music, percussion, unknown properties and
    staff modes without tabs fail instead of flattening independent parts.
    [\ks], [\clef] and [\section] require the start of a bar (initially or
    after [|]); their implicit bar-boundary form after notes is outside this
    subset. A [\clef] names alphaTab's clefs -- [treble], [bass], [alto],
    [tenor], [neutral] or their sign forms [g2], [f4], [c3], [c4], [n] -- and
    is not drawn.

    Repeat signs stand in the bar they mark: [\ro] opens the repeat, [\rc N]
    closes it with the count of total plays, and [\ae n …] names the ending
    passes the bar plays on. [\ae] also takes alphaTab's own parenthesized
    list, [\ae (1 2 3)], which is the form the writer emits; a single pass
    may carry or drop the parentheses. [N] counts total plays the way
    alphaTab's example does: [\ro … \rc 2] plays the passage twice. A second
    [\rc] says the count again; [\ae]
    numbers gather across the bar. A sign with no bar of its own -- on a bar
    with no beat, or after the last bar -- fails rather than being dropped.
    Open and close are not paired: a close without an open, or an open
    without a close, reads fine.

    Technique markup in braces -- a [{…}] after a beat or on a chord member --
    marks its note. A dot ([{d}]), a double dot ([{dd}]), a tuplet ([{tu 3}])
    or a grace note ([{gr}]) changes the latest beat's length: a dotted beat
    lasts half again, a double-dotted beat half and a quarter again, a
    tuplet divides the plain length, and a grace note takes no time. A tuplet
    on a length the ticks cannot divide is not drawn.

    Anything else fails too. No word is skipped: a skipped word would take
    its beat with it and move every note after it. *)

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

(** Why a text is not a score in the subset. *)
type failure =
  | Unclosed of unclosed
  | Closes_nothing of char  (** a [)] or [}] with nothing open *)
  | Backslash_without_name
  | Unknown_directive of string  (** the name, without its backslash *)
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
  | Duration_outside_subset of string  (** the duration as written *)
  | Chord_dot_without_duration
  | Empty_chord
  | Not_a_note of string  (** the word as written *)
  | Fret_out_of_range of string  (** more digits than a fret has *)
  | Chord_string_twice of int  (** the string two chord members share *)
  | Tie_without_note of int  (** the string of a tie with no note to hold *)
  | Tie_to_dead_note of int  (** the string of a tie whose note is dead *)
  | Effect_without_note
  | Unsupported_rhythm of string  (** the markup: a dot, a tuplet, a grace note *)
  | No_music  (** directives alone: no note and no rest *)
  | Too_many_strings of int
  | String_past_tuning of { string : int; strings : int }
  | Repeat_count_out_of_range of string  (** the count as written *)
  | Alternate_ending_out_of_range of string  (** the ending as written *)
  | Repeat_without_bar  (** a repeat sign with no bar of its own *)

val failure_text : failure -> string
(** The failure in a sentence a reader can show. *)

(** Counts are in ticks: a whole note is 384, so every plain length and
    every dotted or tuplet form lands on an integer. *)

(** How a note sounds on its beat. *)
type attack =
  | Struck  (** picked on its beat *)
  | Muted  (** [x]: picked dead *)
  | Tied  (** [-]: held on from the earlier note on its string *)

type note = {
  fret : string;  (** as written, [x] for a dead note; a tie's is the fret it holds *)
  on_string : int;  (** 1 is the highest string; always one the tuning has *)
  marked : bool;  (** technique markup rode on it *)
  attack : attack;
}

type duration =
  | Plain of int
  | Dotted of int
  | Double_dotted of int
  | Tuplet of int * int
  | Grace
  | No_duration

type beat = {
  start : int;  (** in ticks, from the start of its measure *)
  span : int;  (** in ticks *)
  dur : duration;  (** how the beat reads, for a cell to draw *)
  marked : bool;  (** a rhythm effect rode on it *)
  notes : note list;  (** [[]] is a rest; at most one note on a string *)
}

type measure = {
  ticks : int;  (** the ticks a whole measure takes *)
  beats : beat list;  (** never empty *)
  repeat_start : bool;  (** a [\ro] opened this bar *)
  repeat_end : int option;  (** a [\rc N] closed it: the count of total plays *)
  endings : int list;  (** [\ae] numbers, ascending, no two alike *)
}

type t = {
  tuning : string list;  (** line names, highest string first; 1 to 12 *)
  measures : measure list;  (** never empty *)
  title : string option;  (** [\title]; [None] when none was said *)
  subtitle : string option;  (** [\subtitle]; [None] when none was said *)
  tempo : int option;  (** [\tempo] in BPM; [None] when none fit an int *)
  time_signature : (int * int) option;  (** [\ts] numerator and denominator *)
}

val read : string -> (t, failure) result
(** The music in the text: each beat on its count, or why the text is not a
    score in the subset. *)
