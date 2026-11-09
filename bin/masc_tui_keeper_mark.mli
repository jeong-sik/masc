(** One character for what a keeper is doing, for the columns too narrow to
    carry a word.

    The mark used to come from a string match on the health label, and every
    label the match did not name drew the healthy dot. Each reading now gets
    its own mark, and a new member of the health vocabulary is a compile
    error here rather than a keeper that looks fine. *)

val glyph : paused:bool -> Masc.Tui_decode.keeper_health_reading option -> string
(** [None] is a roster that was not read -- not a health nothing could name. *)

val failing_glyph : string
(** Opens every line about a failing keeper's past: the FAILING group heading,
    its count in the summary, and the sentence of its last failure. *)

val activity_glyph : Masc_tui_keeper_list_model.activity -> string
(** The compact list's activity mark. The renderer adds the activity word and
    substitutes its existing animated mark for preparing/running turns. [!]
    belongs to a held call alone; a failed attempt in an open turn has its own
    mark. *)

val attempt_glyph : string
(** The mark beside an attempt node in the secondary-row attempt chain. *)

val badge_glyph : Masc_tui_keeper_list_model.badge -> string
(** The mark beside a secondary activity badge; the badge always keeps its
    own text label and count where applicable. *)

val legend : (string * string) list
(** Each mark and the word the wide surfaces print beside it, in the order a
    reader meets them. *)

val activation_letter : Masc.Tui_decode.keeper_activation_mode -> string
(** The Mode letter the roster draws for how a keeper is started. *)

type sandbox = Masc.Keeper_types_profile.sandbox_profile =
  | Docker
  | Micro_vm
  | Remote_ssh

val sandbox_of_profile : string -> sandbox option
(** The sandbox a roster row's profile names, or [None] for a profile this
    build does not know. *)

val sandbox_letter : sandbox -> string
(** The S letter the roster draws for a known sandbox. *)

val now_header : string
val age_header : string
(** The list's header words over the activity and age columns. The list draws
    them and {!column_legend} names them from these two values. *)

val operator_disposition_word :
  Masc.Keeper_execution_receipt.operator_disposition_kind -> string
(** The human disposition word displayed in the activity column for a turn
    requiring operator attention. *)

val shows_operator_disposition :
  activity:Masc_tui_keeper_list_model.activity -> bool
(** Whether the latest receipt's operator disposition may be drawn over the
    activity. It may where nothing on the row is newer than the receipt: Idle,
    Attempt_failed and Unknown. It may not where the activity is newer (an open
    turn, or work or a wait going on now), where no later receipt replaces it
    (Paused, Offline), or where a person is already asked (Held_call, Question,
    Confirmation). *)

val failing_since_word : string
(** The word that opens the failing-for cell of the Detailed second row. *)

val unknown_mark : string
(** What the second row's server-value cells draw for a value that is not
    known: the server did not record it, or it does not fit this screen's
    clock. *)

val pulse_hours : int
(** How many hours the turn pulse spans. It draws one mark per hour. *)

val pulse_ok_mark : string
(** The turn pulse's mark for an hour whose worst turn finished without
    failing or resting. {!unknown_mark} stands for an hour the server no longer
    holds. The pulse counts a keeper's autonomous turns; a chat turn leaves no
    mark. *)

val pulse_rested_mark : string
(** An hour whose worst turn rested. The mark of a spent quota. *)

val pulse_failed_mark : string
(** An hour with a failed turn. The mark of a failed attempt. *)

val pulse_quiet_mark : string
(** An hour in which no autonomous turn ran. The mark of a keeper with no turn
    yet. *)

val axis_next_glyph : string
(** ▹: what comes next. It opens the next cell of the views' header, and
    DETAIL puts it before the runtime the next dispatch of a failed turn takes. *)

val pulse_header : string
val axis_now_header : string
(** The header words over the views' axis row (RFC-0515 §2.4): the turn pulse
    and the NOW cell. {!column_legend} names them. *)

(** {1 The views' grid} (RFC-0515 §2.4.1 – §2.4.3) *)

val grid_gutter_glyph : string
(** [▌]: the first cell of a grid row, in the colour of the row's verdict. *)

val grid_now_line : string
(** [┃]: the two lines on either side of the now cell. *)

val grid_dot_mark : string
(** [·]: a strip cell with nothing in it. *)

val grid_failing_mark : string
val grid_paused_mark : string
val grid_recovered_mark : string
val grid_ok_mark : string
(** The row marks: [!] failing, [○] paused, [✓] recovered (the cause view
    only), [●] the rest. *)

val grid_late_word : string
val grid_held_word : string
(** The due column's words for a due run that has not started and for a held
    one. *)

val grid_keeper_header : string
val grid_due_header : string
val grid_lag_header : string

val grid_pulse_header : window:string -> string
(** [◂ 12h]: the pulse column's header for a pulse that spans [window]. *)

val grid_next_header : window:string -> string
(** [next ▹ 12h]: the strip column's header for a strip that spans [window]. *)

val grid_wait_glyph : string
(** [◌]: a next dispatch that waits out a rest, on the failure line. *)

val grid_full_mark : string
(** [█]: a filled cell of the lag bar. *)

val grid_chain_link : string
val grid_more_mark : string
(** [━] between two failed attempts of the failure line, and […] after the
    attempts it cuts. *)

val grid_open_mark : string
val grid_folded_mark : string
(** [−] an open group title, [+] a folded one. *)

val grid_renewed_mark : string
val grid_stale_mark : string
(** [+] before the age view's time since the memory changed, and [×] before
    its count of invalidated sources. *)

val grid_since_word : string
val grid_ago_word : string
val grid_wait_word : string
val grid_no_data_word : string
val grid_no_snapshot_word : string
val grid_turns_word : string
(** The words of the memory and age views and the failure line. *)

val grid_librarian_header : string
val grid_lag_bar_short_header : string
val grid_lag_bar_header : string
val grid_digest_header : string
val grid_gap_header : string
val grid_facts_by_age_header : string
val grid_renewed_header : string
val grid_stale_header : string
val grid_facts_header : string
(** The column headers of the memory and age views. The lag bar's header is
    [lag ▹], or [lag · unread turns ▹] over a bar wide enough for it. *)

val column_legend : (string * string) list
(** The Keepers header words, the sentence about a failing keeper's past and
    the Mode S letters, each with what it means. The sheet prints it; the
    roster does not repeat it above its rows. *)
