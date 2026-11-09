module Reading = Masc.Tui_decode

(* Operator pause outranks the health reading: it is a person's decision about
   a keeper that may well be healthy, and a reader looking for why a keeper is
   quiet wants that answer first. *)
let paused_glyph = "\xe2\x97\x8b" (* ○ hollow: stopped on purpose *)
let unread_glyph = "-"

(* Opens every line about a failing keeper's past: the FAILING group heading,
   its count in the summary, and the sentence of its last failure. *)
let failing_glyph = "\xe2\x97\x82" (* ◂ *)

(* The filled dot: a healthy keeper that has turned, a turn under way, and the
   now cell of the views' header. *)
let filled_dot = "\xe2\x97\x8f" (* ● *)

let health_glyph : Reading.keeper_health_reading -> string = function
  | Reading.Health_running -> filled_dot (* keepalive running, has turned *)
  | Reading.Health_idle -> "\xc2\xb7" (* · small: keepalive running, no turn yet *)
  | Reading.Health_failing -> "!" (* keepalive running, its turns failing *)
  | Reading.Health_offline -> "\xc3\x97" (* × gone *)

let glyph ~paused reading =
  match reading with
  | None -> unread_glyph
  | Some _ when paused -> paused_glyph
  | Some value -> health_glyph value

let activity_glyph : Masc_tui_keeper_list_model.activity -> string = function
  | Held_call -> "!"
  | Attempt_failed -> "\xe2\x9c\x97" (* ✗: an attempt of the open turn failed *)
  | Question -> "?"
  | Confirmation | Verifying -> "\xe2\x97\x87" (* ◇ *)
  | Preparing | Running -> filled_dot (* the list substitutes its animated mark *)
  | Streaming -> ">"
  | Async_working _ -> "&"
  | Deferred -> "\xe2\x97\x8c" (* ◌ *)
  | Tool_waiting -> "\xe2\x96\xa0" (* ■ *)
  | Model_waiting -> "\xe2\x97\x94" (* ◔ *)
  | External_waiting -> "\xe2\x97\x8c" (* ◌ *)
  | Delegate_result -> "\xe2\x86\xa9" (* ↩ *)
  | Idle -> "\xe2\x97\x8b" (* ○ *)
  | Paused -> "\xe2\x85\xa1" (* Ⅱ *)
  | Offline -> "\xc3\x97" (* × *)
  | Unknown -> unread_glyph

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
  ; paused_glyph, "paused"
  ; health_glyph Reading.Health_offline, "offline"
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
let pulse_quiet_mark = health_glyph Reading.Health_idle

(* The header of the views' axis row (RFC-0515 §2.4): before, now and next.
   Before takes the mark of the failure sentence, which also looks back. *)
let axis_before_glyph = failing_glyph
let axis_now_glyph = filled_dot
let axis_next_glyph = "\xe2\x96\xb9" (* ▹ *)
let pulse_header = Printf.sprintf "%s %dh" axis_before_glyph pulse_hours
let axis_now_header = axis_now_glyph ^ " now"
let axis_next_header = axis_next_glyph ^ " next"

(* The memory and age views put values of their own in the same three cells. *)
let header_words words = String.concat " \xc2\xb7 " words (* · *)
let fact_age_header = axis_before_glyph ^ " fact age"
let librarian_header = axis_now_glyph ^ " librarian"
let updated_header = axis_now_glyph ^ " saved"
let lag_digest_gap_header = axis_next_glyph ^ " " ^ header_words [ "lag"; "digest"; "gap" ]

let lag_stale_facts_header =
  axis_next_glyph ^ " " ^ header_words [ "lag"; "stale"; Masc_tui_keeper_age_ladder.cell_label ]

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
  [ now_header, "what the keeper is doing at this moment"
  ; ( age_header
    , "time since it last moved: the open turn's latest update (its start before it \
       reports one), else the later of its last turn and the start of its wait" )
  ; "LIFECYCLE", "the keeper process"
  ; ( String.concat " " [ pulse_header; axis_now_header; axis_next_header ]
    , "every view but the list draws a keeper on one axis row. The memory and age views \
       pick their own cells; the others draw its turn pulse, its NOW cell, then what \
       comes next -- what it waits on a person for, the next scheduled run, the next \
       dispatch path and the librarian lag. With two lines only a failing keeper adds a \
       second line" )
  ; ( String.concat " " [ pulse_header; librarian_header; lag_digest_gap_header ]
    , Printf.sprintf
        "the memory view: the turn pulse, how the librarian's last pass ended, then the \
         unread turns as a bar against the listed keeper furthest behind, the time since its \
         last digest and the atoms requests skip; %s is a value the server did not measure"
        Masc_tui_keeper_age_ladder.unmeasured_mark )
  ; ( String.concat " " [ fact_age_header; updated_header; lag_stale_facts_header ]
    , Printf.sprintf
        "the age view: the keeper's facts by age as the %s strip draws them, the time since \
         its memory last changed, then the unread-turn bar, invalidated sources and the fact \
         count; %s is a value the server did not measure"
        Masc_tui_keeper_age_ladder.cell_label Masc_tui_keeper_age_ladder.unmeasured_mark )
  ; ( failing_glyph
    , "a failing keeper's last failure: how long ago · cause · the runtime that ended it \
       · candidates tried. The list draws it in place of its runtime or first in DETAIL, \
       the views on a failing keeper's second line" )
  ; ( failing_since_word
    , Printf.sprintf
        "how long the keeper has been in the failing phase; %s when the server recorded \
         no start, or the start is ahead of this screen's clock (Detailed second row)"
        unknown_mark )
  ; ( String.concat " " (List.map fst pulse_marks)
    , Printf.sprintf
        "autonomous turn results of the last %d clock hours, one mark per hour, newest \
         on the right: %s; chat turns are not counted, and an hour from before the \
         server's record of the keeper reads %s (Detailed second row, and %s in the views)"
        pulse_hours
        (String.concat " / " (List.map (fun (mark, word) -> mark ^ " " ^ word) pulse_marks))
        unknown_mark pulse_header )
  ; "Mode " ^ letters activation_letter activations, words activation_word activations
  ; "S " ^ letters sandbox_letter sandboxes, "sandbox: " ^ words sandbox_word sandboxes
  ; ( "쉬는 중"
    , Printf.sprintf
        "resting path: relative duration (제공자 stated / 상한 bounded); in DETAIL %s prefixes next candidate after turn failure"
        axis_next_glyph )
  ; ( badge_glyph Badge_schedule
    , Printf.sprintf "next scheduled run or hold status (Detailed second row, and %s in the views)"
        axis_next_header )
  ; ( "mem · lag · stale"
    , Printf.sprintf
        "keeper memory health: unread gap/lag, update clock, invalidated sources (Detailed second \
         row; its lag in %s in the views, and the memory and age views draw their own cells). \
         mem %s is memory health not read yet, or a refused row that may be this keeper's; mem \
         ! is this keeper's row, refused; %s is a keeper with no memory snapshot"
        axis_next_header Masc_tui_keeper_age_ladder.unmeasured_mark
        Masc_tui_theme.Glyph.no_value )
  ; ( Masc_tui_keeper_age_ladder.cell_label
    , Printf.sprintf "%s (Detailed second row, and %s in the age view)"
        Masc_tui_keeper_age_ladder.legend fact_age_header )
  ; "사람 몫 / 효과 확인 / 분류 안 됨", "requires human operator action, effect review, or unmapped fault (NOW column)"
  ]
