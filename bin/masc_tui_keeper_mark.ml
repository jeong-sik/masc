module Reading = Masc.Tui_decode
module Status = Masc_tui_value.Mark

(* A Keeper's state wears one of the seven status marks (RFC
   tui-one-screen-grammar §7.2); its word says which state of that kind it
   is. The mark of each state is chosen here and nowhere else, so the roster,
   the NOW cell, the grid and the strip agree, and the colour comes from the
   mark through [Theme.status_tone]. *)

(* Operator pause outranks the health reading: it is a person's decision about
   a keeper that may well be healthy, and a reader looking for why a keeper is
   quiet wants that answer first. *)
let paused_glyph = Status.glyph Status.Paused

(* A Keeper whose health was not read has no state to mark: the not-read-yet
   mark of a missing value (§6.4). *)
let unread_glyph = Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unread

(* Opens every line about a failing keeper's past: the FAILING group heading,
   its count in the summary, and the sentence of its last failure. *)
let failing_glyph = "\xe2\x97\x82" (* ◂ *)

(* The filled dot: the now cell of the views' header. *)
let filled_dot = Status.glyph Status.Settled

(* An offline process is stopped, not failing: whether that is odd for this
   Keeper is the strip's reading ([Masc_tui_keeper_strip.odd_dormant]). *)
let health_mark : Reading.keeper_health_reading -> Status.t = function
  | Reading.Health_running -> Status.Settled
  | Reading.Health_idle -> Status.Waiting
  | Reading.Health_failing -> Status.Failed
  | Reading.Health_offline -> Status.Paused

let health_glyph reading = Status.glyph (health_mark reading)

(* The mark of the roster's health cell; [None] when the health was not
   read. *)
let state_mark ~paused reading =
  match reading with
  | None -> None
  | Some _ when paused -> Some Status.Paused
  | Some value -> Some (health_mark value)

let glyph ~paused reading =
  match state_mark ~paused reading with
  | Some mark -> Status.glyph mark
  | None -> unread_glyph

(* What the Keeper is doing now. The operator's turn is a held call, a
   question or a confirmation; work under way is any turn the Keeper is
   running, verifying included; a wait for a tool, a model, a delegate or the
   world is waiting, and so is a Keeper at rest. [None] is an activity that
   was not read. *)
let activity_mark : Masc_tui_keeper_list_model.activity -> Status.t option = function
  | Held_call | Question | Confirmation -> Some Status.Yours
  | Attempt_failed -> Some Status.Failed
  | Preparing | Running | Streaming | Async_working _ | Verifying -> Some Status.Under_way
  | Deferred | Tool_waiting | Model_waiting | External_waiting | Delegate_result | Idle ->
      Some Status.Waiting
  | Paused | Offline -> Some Status.Paused
  | Unknown -> None

let activity_glyph activity =
  match activity_mark activity with
  | Some mark -> Status.glyph mark
  | None -> unread_glyph

let attempt_glyph = "\xe2\x9c\x97" (* ✗: an attempt failed *)

let badge_glyph : Masc_tui_keeper_list_model.badge -> string = function
  | Badge_read_error -> "!"
  | Badge_waiting_unavailable -> "!"
  | Badge_async _ -> "&"
  | Badge_async_queued _ -> ">"
  | Badge_async_cancelling _ -> "\xc3\x97" (* × *)
  | Badge_delegate -> "\xe2\x86\xa9" (* ↩ *)
  | Badge_verification -> "\xe2\x97\x87" (* ◇ *)
  | Badge_schedule -> "\xe2\x97\xb7" (* ◷ *)
  | Badge_quota_spent -> "\xe2\x8a\x98" (* ⊘ *)

let legend =
  [ health_glyph Reading.Health_running, "healthy"
  ; health_glyph Reading.Health_failing, "failing"
  ; health_glyph Reading.Health_idle, "idle"
  ; paused_glyph, "paused, or offline"
  ; unread_glyph, "unread"
  ]

(* The roster's Mode S cell: a letter for how the keeper is started and a
   letter for the sandbox its row declares. The letters and the words the
   sheet prints for them are declared together, so the cell and its
   explanation cannot drift apart. *)
let activation_letter : Reading.keeper_activation_mode -> string = function
  | Reading.Activation_manual -> "M"
  | Reading.Activation_on_demand -> "D"
  | Reading.Activation_autonomous -> "A"

let activation_word : Reading.keeper_activation_mode -> string = function
  | Reading.Activation_manual -> "manual"
  | Reading.Activation_on_demand -> "on demand"
  | Reading.Activation_autonomous -> "autonomous"

let activations =
  [ Reading.Activation_manual; Reading.Activation_on_demand; Reading.Activation_autonomous ]

type sandbox = Masc.Keeper_types_profile.sandbox_profile =
  | Docker
  | Micro_vm
  | Remote_ssh

let sandbox_of_profile = Masc.Keeper_types_profile.sandbox_profile_of_string
let sandbox_letter = function Docker -> "D" | Micro_vm -> "M" | Remote_ssh -> "R"
let sandbox_word = Masc.Keeper_types_profile.sandbox_profile_to_string
let sandboxes = Masc.Keeper_types_profile.all_sandbox_profiles

(* The list's header words that the sheet explains, declared once. The list
   draws them and [column_legend] names them from these values, so a column
   that is renamed cannot keep its old name on the sheet. *)
let now_header = "NOW"
let age_header = "AGE"

let operator_disposition_word : Masc.Keeper_execution_receipt.operator_disposition_kind -> string = function
  | Disp_operator_action_required -> "사람 몫"
  | Disp_effect_review_required -> "효과 확인"
  | Disp_unknown -> "분류 안 됨"
  | Disp_pass -> "pass"
  | Disp_fail_open_next_runtime -> "fail open"
  | Disp_retry_later -> "retry later"
  | Disp_pass_next_model -> "next model"
  | Disp_user_cancelled -> "cancelled"
  | Disp_skipped -> "skipped"
;;

let shows_operator_disposition ~(activity : Masc_tui_keeper_list_model.activity) =
  match activity with
  (* Only idle/unmapped states and attempt failures of the open turn show
     historical operator intervention requirements from the last receipt.
     During active turns (preparing, executing, waiting on tools/models, async,
     delegation, verification) or operator holds, the current turn is live and
     has not yet produced a new receipt. *)
  | Attempt_failed | Idle | Unknown -> true
  | Preparing | Running | Streaming
  | Paused | Offline
  | Held_call | Question | Confirmation
  | Tool_waiting | Model_waiting
  | Async_working _ | Deferred
  | Delegate_result | Verifying | External_waiting -> false
;;

(* The turn cells of the Detailed second row (RFC-0511 D1). The cells draw
   these words and marks and [column_legend] names them from the same values,
   so a mark that changes cannot keep its old meaning on the sheet. Three of
   the marks are the ones the row already draws for the same meaning: a failed
   attempt, a spent quota and a keeper with no turn. *)
let failing_since_word = "failing"
let unknown_mark = "?"
let pulse_hours = 12
let pulse_ok_mark = "\xe2\x9c\x93" (* ✓: the turn finished without failing or resting *)
let pulse_rested_mark = badge_glyph Masc_tui_keeper_list_model.Badge_quota_spent
let pulse_failed_mark = attempt_glyph
(* A quiet hour in the pulse is a small dot, not a status mark: the pulse
   counts turns, it does not state the Keeper's state. *)
let pulse_quiet_mark = "\xc2\xb7" (* · *)

(* The header of the views' axis row (RFC-0515 §2.4): before, now and next.
   Before takes the mark of the failure sentence, which also looks back. *)
let axis_before_glyph = failing_glyph
let axis_now_glyph = filled_dot
let axis_next_glyph = "\xe2\x96\xb9" (* ▹ *)
let axis_now_header = axis_now_glyph ^ " now"

(* The grid of the views (RFC-0515 §2.4). The row marks are the marks the
   list already draws for the same readings. *)
let grid_gutter_glyph = "\xe2\x96\x8c" (* ▌ *)
let grid_now_line = "│"
let grid_dot_mark = pulse_quiet_mark
let grid_wake_mark = "▁"
let grid_unknown_range_mark = "─"
let grid_failing_mark = Status.glyph Status.Failed
let grid_paused_mark = paused_glyph
(* Recovered: sound now after a failure in the window, so worth a look. *)
let grid_recovered_mark = Status.glyph Status.Caution
let grid_ok_mark = filled_dot
let grid_late_word = "late"
let grid_held_word = "held"
let grid_keeper_header = "keeper"
let grid_due_header = "due"
let grid_lag_header = "lag"
let grid_pulse_header ~window = axis_before_glyph ^ " " ^ window
let grid_next_header ~window = "next " ^ axis_next_glyph ^ " " ^ window

(* The views' pulse draws one mark per half hour (RFC-0515 §2.4.3): the
   lowest bar for ok turns, a full one for failed turns ([grid_full_mark])
   and a half one for a half hour that holds both. *)
let grid_pulse_ok_mark = "\xe2\x96\x81" (* ▁ *)
let grid_pulse_failed_and_ok_mark = "\xe2\x96\x84" (* ▄ *)

(* The memory and age views, the failure line and the group titles. *)
let grid_wait_glyph = "\xe2\x97\x8c" (* ◌ *)
let grid_full_mark = "\xe2\x96\x88" (* █ *)
let grid_chain_link = "\xe2\x94\x81" (* ━ *)
let grid_more_mark = "\xe2\x80\xa6" (* … *)
let grid_open_mark = "▾"
let grid_folded_mark = "▸"
let grid_saved_mark = "+"
let grid_stale_mark = "\xc3\x97" (* × *)
let grid_since_word = "since"
let grid_ago_word = "ago"
let grid_wait_word = "wait"
let grid_no_data_word = "no data"
let grid_no_snapshot_word = "no snapshot"
let grid_turns_word = "turns"
let grid_librarian_header = "librarian"
let grid_lag_bar_short_header = "lag " ^ axis_next_glyph
let grid_lag_bar_header = "lag \xc2\xb7 unread turns " ^ axis_next_glyph (* · *)
let grid_digest_header = "digest"
let grid_gap_header = "gap"
let grid_facts_by_age_header = "facts by age \xe2\x96\xb8" (* ▸ *)
let grid_saved_header = "saved"
let grid_stale_header = "stale"
let grid_facts_header = "facts"

let column_legend =
  let letters letter values = String.concat "/" (List.map letter values) in
  let words word values = String.concat " / " (List.map word values) in
  let pulse_marks =
    [ pulse_ok_mark, "ok"
    ; pulse_rested_mark, "rested"
    ; pulse_failed_mark, "failed"
    ; pulse_quiet_mark, "no turn"
    ; unknown_mark, "unknown"
    ]
  in
  let half_hour_marks =
    [ grid_dot_mark, "no turn"
    ; grid_pulse_ok_mark, "ok"
    ; grid_pulse_failed_and_ok_mark, "failed and ok"
    ; grid_full_mark, "failed"
    ; unknown_mark, "unknown"
    ]
  in
  let marked marks = String.concat " / " (List.map (fun (mark, word) -> mark ^ " " ^ word) marks) in
  [ now_header, "what the keeper is doing at this moment"
  ; ( age_header
    , "time since it last moved: the open turn's latest update (its start before it \
       reports one), else the later of its last turn and the start of its wait" )
  ; "LIFECYCLE", "the keeper process"
  ; ( String.concat " "
        [ axis_before_glyph; grid_now_line; axis_now_header; grid_now_line
        ; "next " ^ axis_next_glyph; grid_due_header; grid_lag_header ]
    , Printf.sprintf
        "every view but the list draws a keeper on the same columns, fixed from the right \
         edge so the %s lines stand in one column: the row mark (%s failing, %s paused, %s \
         recovered in the cause view, %s the rest), the name, the turn pulse, the NOW cell, \
         the state view's known wake count and any partial observation, or the other \
         views' half hours ahead (%s a scheduled wake, blank none, %s an unknown range; \
         entirely unknown or empty windows have one label), the next \
         scheduled run (its time within a day, %s, %s, %s%s from an earlier reading, %s \
         unknown) and the librarian's unread turns with a level against the keeper \
         furthest behind. The memory and age views pick their own \
         columns. With two lines a failing keeper of the state and cause views adds a line: \
         %s since when it fails, the attempts of the failed turn (%s%s%s) and the failure \
         word, and the runtime of the next dispatch (%s, or %s %s while the path rests)"
        grid_now_line grid_failing_mark grid_paused_mark grid_recovered_mark grid_ok_mark
        grid_wake_mark grid_unknown_range_mark grid_late_word grid_held_word grid_held_word
        unknown_mark unknown_mark axis_before_glyph
        attempt_glyph grid_chain_link attempt_glyph axis_next_glyph grid_wait_glyph grid_wait_word )
  ; ( String.concat " "
        [ axis_before_glyph ^ " " ^ grid_turns_word; grid_now_line; grid_librarian_header
        ; grid_now_line; grid_lag_bar_short_header; grid_digest_header; grid_gap_header ]
    , Printf.sprintf
        "the memory view: the turn pulse, how the librarian's last pass ended (%s without a \
         memory row), the unread turns as a bar against the listed keeper furthest behind, \
         the time since the last digest (%s before the first) and the atoms requests skip; %s \
         is a value the server did not measure, a pass this server has not seen yet too"
        grid_no_data_word Masc_tui_theme.Glyph.no_value Masc_tui_keeper_age_ladder.unmeasured_mark )
  ; ( String.concat " "
        [ grid_facts_by_age_header; grid_now_line; grid_saved_header; grid_now_line
        ; grid_lag_bar_short_header; grid_stale_header; grid_facts_header ]
    , Printf.sprintf
        "the age view: the keeper's facts in %s, and a group title adds up its keepers; %s \
         the time since its memory snapshot was saved (%s %s without one), the unread-turn \
         bar, %sN invalidated sources and the fact count with a level against the keeper with \
         the most facts; %s is a value the server did not measure"
        (Masc_tui_keeper_age_ladder.column_legend ~empty:grid_dot_mark)
        grid_saved_mark Masc_tui_theme.Glyph.no_value grid_no_snapshot_word grid_stale_mark
        Masc_tui_keeper_age_ladder.unmeasured_mark )
  ; ( String.concat " " (List.map fst half_hour_marks)
    , Printf.sprintf
        "the views' turn pulse: autonomous turn results of the last half hours, one mark \
         per half hour, newest on the right: %s; a rested turn counts as failed, chat turns \
         are not counted, and a half hour from before the server's record of the keeper \
         reads %s. The header names how long the marks span"
        (marked half_hour_marks) unknown_mark )
  ; ( failing_glyph
    , "a failing keeper's last failure: how long ago · cause · the runtime that ended it \
       · candidates tried. The list draws it in place of its runtime or first in DETAIL" )
  ; ( failing_since_word
    , Printf.sprintf
        "how long the keeper has been in the failing phase; %s when the server recorded \
         no start, or the start is ahead of this screen's clock (Detailed second row)"
        unknown_mark )
  ; ( String.concat " " (List.map fst pulse_marks)
    , Printf.sprintf
        "autonomous turn results of the last %d clock hours, one mark per hour, newest \
         on the right: %s; chat turns are not counted, and an hour from before the \
         server's record of the keeper reads %s (Detailed second row)"
        pulse_hours (marked pulse_marks) unknown_mark )
  ; "Mode " ^ letters activation_letter activations, words activation_word activations
  ; "S " ^ letters sandbox_letter sandboxes, "sandbox: " ^ words sandbox_word sandboxes
  ; ( "쉬는 중"
    , Printf.sprintf
        "resting path: relative duration (제공자 stated / 상한 bounded); in DETAIL %s prefixes next candidate after turn failure"
        axis_next_glyph )
  ; ( badge_glyph Badge_schedule
    , Printf.sprintf "next scheduled run or hold status (Detailed second row; %s in the views)"
        grid_due_header )
  ; ( "mem · lag · stale"
    , Printf.sprintf
        "keeper memory health: unread gap/lag, update clock, invalidated sources (Detailed second \
         row; its lag under %s in the views, and the memory and age views draw their own cells). \
         mem %s is memory health not read yet, or a refused row that may be this keeper's; mem \
         ! is this keeper's row, refused; %s is a keeper with no memory snapshot"
        grid_lag_header Masc_tui_keeper_age_ladder.unmeasured_mark
        Masc_tui_theme.Glyph.no_value )
  ; ( Masc_tui_keeper_age_ladder.cell_label
    , Printf.sprintf "%s (Detailed second row; the age view draws the bins under %s, %s for an \
                       empty one)"
        Masc_tui_keeper_age_ladder.legend grid_facts_by_age_header grid_dot_mark )
  ; "사람 몫 / 효과 확인 / 분류 안 됨", "requires human operator action, effect review, or unmapped fault (NOW column)"
  ]
