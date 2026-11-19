(** One character for what a keeper is doing, for the columns too narrow to
    carry a word.

    The mark used to come from a string match on the health label, and every
    label the match did not name drew the healthy dot. Each reading now gets
    its own mark, and a new member of the health vocabulary is a compile
    error here rather than a keeper that looks fine. *)

val state_mark :
  paused:bool -> Masc.Tui_decode.keeper_health_reading option -> Masc_tui_value.Mark.t option
(** The status mark of a Keeper's health (RFC tui-one-screen-grammar §7.2):
    running is settled, idle waiting, failing failed, and offline or paused
    is paused. [None] is a roster that was not read -- not a health nothing
    could name. *)

val glyph : paused:bool -> Masc.Tui_decode.keeper_health_reading option -> string
(** {!state_mark}'s glyph, or the not-read-yet mark for [None]. *)

val failing_glyph : string
(** Opens every line about a failing keeper's past: the FAILING group heading,
    its count in the summary, and the sentence of its last failure. *)

val attention_mark : Masc_tui_keeper_list_model.attention -> Masc_tui_value.Mark.t option
(** The status mark of a state-view group: the operator's turn, failed,
    under way, waiting; the inactive group waits too. [None] is the group of
    activities not read. *)

val activity_mark : Masc_tui_keeper_list_model.activity -> Masc_tui_value.Mark.t option
(** The status mark of what a Keeper is doing now (§7.2): the mark of its
    activity's group ({!attention_mark} of
    {!Masc_tui_keeper_list_model.group_of_activity}). A pause and offline are
    paused instead. The word beside the mark says which. A row whose health
    failed stands under the failing group while its activity keeps its own
    mark. [None] is an activity that was not read. *)

val offline_unexpectedly : Masc_tui_keeper_list_model.row -> bool
(** The row is offline, and its Keeper starts on its own and is not paused:
    it should be running. *)

val row_activity_mark : Masc_tui_keeper_list_model.row -> Masc_tui_value.Mark.t option
(** {!activity_mark} of the row's activity, except that an offline Keeper
    which starts on its own and is not paused is a caution: it should be
    running. *)

val row_activity_glyph : Masc_tui_keeper_list_model.row -> string
(** {!row_activity_mark}'s glyph, or the not-read-yet mark. *)

val activity_glyph : Masc_tui_keeper_list_model.activity -> string
(** The compact list's activity mark: {!activity_mark}'s glyph, or the
    not-read-yet mark. The renderer adds the activity word. *)

val attempt_glyph : string
(** The mark beside an attempt node in the secondary-row attempt chain. *)

val badge_glyph : Masc_tui_keeper_list_model.badge -> string
(** The status mark (RFC tui-one-screen-grammar §7.2) beside a secondary
    activity badge; the badge always keeps its own word and count where
    applicable. A list that could not be read wears the read-failed mark of
    a missing value (§6.4). *)

val due_glyph : Masc_tui_keeper_list_model.due -> string
(** The mark of a due group's heading in the time view: late is caution, held
    paused, a coming run waiting, no schedule the dash of a value read as
    none, and an unknown next time the unreported mark. *)

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
  ko:bool -> Masc.Keeper_execution_receipt.operator_disposition_kind -> string
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
(** An hour whose worst turn rested. *)

val pulse_failed_mark : string
(** An hour with a failed turn. The mark of a failed attempt. *)

val pulse_quiet_mark : string
(** An hour in which no autonomous turn ran. The mark of a keeper with no turn
    yet. *)

val axis_next_glyph : string
(** ▹: what comes next. It opens the next cell of the views' header, and
    DETAIL puts it before the runtime the next dispatch of a failed turn takes. *)

val axis_now_header : string
(** The header word over the NOW cell of the views' axis row (RFC-0515 §2.4).
    {!column_legend} names it. *)

(** {1 The views' grid} (RFC-0515 §2.4.1 – §2.4.3) *)

val grid_gutter_glyph : string
(** [▌]: the retained rail mark for the world row and runtime matrix.
    Activity rows use two leading spaces before the verdict mark. *)

val grid_now_line : string
(** [│]: the quiet separators on either side of the now cell. *)

val grid_dot_mark : string
(** [·]: the quiet pulse model mark and the unfilled lag-bar background.
    Activity history and scheduled-wake views leave known empty slots blank. *)

val grid_wake_mark : string
(** [▁]: a strip half hour that holds one scheduled wake or more. Adjacent
    scheduled slots join into a low bar; the schedule badge stays a clock. *)

val grid_unknown_range_mark : string
(** [─]: a strip half hour without a known wake whose schedule is unknown.
    An entirely unknown window is labelled once by the strip renderer. *)

val grid_failing_mark : string
val grid_paused_mark : string
val grid_recovered_mark : string
val grid_ok_mark : string
(** The row marks, status marks of RFC tui-one-screen-grammar §7.2: [✕]
    failing, [‖] paused, [▲] recovered (the cause view only), [●] the rest. *)

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

val grid_pulse_ok_mark : string
val grid_pulse_failed_and_ok_mark : string
(** [▁] a pulse half hour of ok turns only, [▄] one that holds a failed turn
    and an ok one. A half hour of failed turns only draws {!grid_full_mark}. *)

val grid_wait_glyph : string
(** [○], the waiting mark: a next dispatch that waits out a rest, on the
    failure line. *)

val grid_full_mark : string
(** [▆]: a filled cell of a pulse half hour of failed turns only. *)

val grid_chain_link : string
val grid_more_mark : string
(** [━] between two failed attempts of the failure line, and […] after the
    attempts it cuts. *)

val grid_open_mark : string
val grid_folded_mark : string
(** [▾] an open group title, [▸] a folded one. *)

val grid_saved_mark : string
val grid_stale_mark : string
(** [+] before the age view's time since the memory snapshot was saved, and
    [×] before its count of invalidated sources. *)

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
val grid_saved_header : string
val grid_stale_header : string
val grid_facts_header : string

type grid_column =
  | Keeper_column
  | Now_column
  | Due_column
  | Lag_column
  | Turns_column
  | Librarian_column
  | Lag_bar_column
  | Lag_bar_short_column
  | Digest_column
  | Gap_column
  | Facts_by_age_column
  | Saved_column
  | Stale_column
  | Facts_column

val grid_column_word : ko:bool -> grid_column -> string
(** A view's column header in the screen's language (RFC tui-one-screen-grammar
    7.1). In English it is the [grid_*_header] word the legend names. *)

type grid_word = Late_word | Held_word | Wait_word | No_data_word | No_snapshot_word

val grid_word : ko:bool -> grid_word -> string
(** A word inside a view's cell in the screen's language; in English it is the
    [grid_*_word] the legend names. *)

val grid_since_text : ko:bool -> string -> string
(** [since 15:43] / [15:43부터]. *)

val grid_ago_text : ko:bool -> string -> string
(** [5m ago] / [5m 전]. *)

val grid_next_column_word : ko:bool -> window:string -> string
(** {!grid_next_header} in the screen's language: [다음 ▹ 12h]. *)
(** The column headers of the memory and age views. The lag bar's header is
    [lag ▹], or [lag · unread turns ▹] over a bar wide enough for it. [saved]
    is the snapshot's saved time, not a source-revalidation result. *)

val column_legend : (string * string) list
(** The Keepers header words, the sentence about a failing keeper's past and
    the Mode S letters, each with what it means. The sheet prints it; the
    roster does not repeat it above its rows. *)
