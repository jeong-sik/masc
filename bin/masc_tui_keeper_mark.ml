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

(* The mark of a state-view group. The operator's turn, failed, under way and
   waiting are the groups' own; the inactive group holds rest as well as
   pauses, so it wears the waiting mark. [None] is the group of activities
   that were not read. *)
let attention_mark : Masc_tui_keeper_list_model.attention -> Status.t option = function
  | Masc_tui_keeper_list_model.Attention -> Some Status.Yours
  | Masc_tui_keeper_list_model.Failing -> Some Status.Failed
  | Masc_tui_keeper_list_model.Active -> Some Status.Under_way
  | Masc_tui_keeper_list_model.Waiting | Masc_tui_keeper_list_model.Inactive -> Some Status.Waiting
  | Masc_tui_keeper_list_model.Unobserved -> None

(* What the Keeper is doing now wears the mark of its activity's group in the
   state view ([Masc_tui_keeper_list_model.group_of_activity]). A pause and
   offline are paused instead; rest is waiting. [None] is an activity that
   was not read. *)
let activity_mark (activity : Masc_tui_keeper_list_model.activity) =
  match activity with
  | Masc_tui_keeper_list_model.Paused | Masc_tui_keeper_list_model.Offline -> Some Status.Paused
  | Held_call | Question | Confirmation | Attempt_failed | Preparing | Streaming | Running
  | Async_working _ | Deferred | Tool_waiting | Model_waiting | Delegate_result | Verifying
  | External_waiting | Idle | Unknown ->
      attention_mark (Masc_tui_keeper_list_model.group_of_activity activity)

(* A Keeper that starts on its own and is not paused should be running, so
   when it is offline it asks for a look; a Keeper started by hand or on
   demand is offline as expected. *)
let starts_on_its_own (row : Masc_tui_keeper_list_model.row) =
  match Masc_tui_keeper_list_model.runtime_of_row row with
  | Some runtime -> (
      (not runtime.Reading.kr_paused)
      &&
      match runtime.kr_activation_mode with
      | Reading.Activation_autonomous -> true
      | Reading.Activation_manual | Reading.Activation_on_demand -> false)
  | None -> false

let offline_unexpectedly row =
  match Masc_tui_keeper_list_model.primary_activity_of_row row with
  | Masc_tui_keeper_list_model.Offline -> starts_on_its_own row
  | Paused | Held_call | Question | Confirmation | Attempt_failed | Preparing | Streaming
  | Running | Async_working _ | Deferred | Tool_waiting | Model_waiting | Delegate_result
  | Verifying | External_waiting | Idle | Unknown -> false

let row_activity_mark row =
  let activity = Masc_tui_keeper_list_model.primary_activity_of_row row in
  match activity with
  | Masc_tui_keeper_list_model.Offline when offline_unexpectedly row -> Some Status.Caution
  | Offline | Paused | Held_call | Question | Confirmation | Attempt_failed | Preparing
  | Streaming | Running | Async_working _ | Deferred | Tool_waiting | Model_waiting
  | Delegate_result | Verifying | External_waiting | Idle | Unknown ->
      activity_mark activity

let row_activity_glyph row =
  match row_activity_mark row with
  | Some mark -> Status.glyph mark
  | None -> unread_glyph

let activity_glyph activity =
  match activity_mark activity with
  | Some mark -> Status.glyph mark
  | None -> unread_glyph

(* A failed attempt is a failure, so it wears the failed status mark (RFC
   tui-one-screen-grammar 7.2: one mark, one meaning). *)
let attempt_glyph = Status.glyph Status.Failed

(* A badge says in a word what else goes on beside the activity, behind the
   status mark of its kind (§7.2). A list the screen could not read wears the
   read-failed mark of a missing value (§6.4); a background run is under way;
   a queued run, a delegate's result, a verification and a scheduled wake are
   waits; a run being cancelled is paused; a spent quota asks for a look. *)
let badge_glyph : Masc_tui_keeper_list_model.badge -> string = function
  | Badge_read_error | Badge_waiting_unavailable ->
      Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Read_failed
  | Badge_async _ -> Status.glyph Status.Under_way
  | Badge_async_queued _ | Badge_delegate | Badge_verification | Badge_schedule ->
      Status.glyph Status.Waiting
  | Badge_async_cancelling _ -> Status.glyph Status.Paused
  | Badge_quota_spent -> Status.glyph Status.Caution

(* The due groups of the time view: a run that should have started asks for
   a look, a held one is paused, a coming one waits. No schedule is a value
   read as none, and an unknown next time one the answer did not carry. *)
let due_glyph : Masc_tui_keeper_list_model.due -> string = function
  | Due_late -> Status.glyph Status.Caution
  | Due_held -> Status.glyph Status.Paused
  | Due_within_hour | Due_within_half_day | Due_later -> Status.glyph Status.Waiting
  | Due_none -> Masc_tui_theme.Glyph.no_value
  | Due_unknown -> Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported

let legend_for ~ko =
  let say korean english = if ko then korean else english in
  [ health_glyph Reading.Health_running, say "정상" "healthy"
  ; health_glyph Reading.Health_failing, say "실패 중" "failing"
  ; health_glyph Reading.Health_idle, say "대기 중" "idle"
  ; paused_glyph, say "일시정지 또는 오프라인" "paused, or offline"
  ; unread_glyph, say "미조회" "unread"
  ]

(* The roster's Mode S cell: a letter for how the keeper is started and a
   letter for the sandbox its row declares. The letters and the words the
   sheet prints for them are declared together, so the cell and its
   explanation cannot drift apart. *)
let activation_letter : Reading.keeper_activation_mode -> string = function
  | Reading.Activation_manual -> "M"
  | Reading.Activation_on_demand -> "D"
  | Reading.Activation_autonomous -> "A"

let activation_word ~ko : Reading.keeper_activation_mode -> string = function
  | Reading.Activation_manual -> if ko then "수동" else "manual"
  | Reading.Activation_on_demand -> if ko then "요청 시" else "on demand"
  | Reading.Activation_autonomous -> if ko then "자율" else "autonomous"

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

let operator_disposition_word ~ko : Masc.Keeper_execution_receipt.operator_disposition_kind -> string = function
  | Disp_operator_action_required -> if ko then "사람 몫" else "human"
  | Disp_effect_review_required -> if ko then "효과 확인" else "review"
  | Disp_unknown -> if ko then "분류 안 됨" else "unclassed"
  | Disp_pass -> if ko then "통과" else "pass"
  | Disp_fail_open_next_runtime -> if ko then "다음 런타임" else "fail open"
  | Disp_retry_later -> if ko then "나중에 재시도" else "retry later"
  | Disp_pass_next_model -> if ko then "다음 모델" else "next model"
  | Disp_user_cancelled -> if ko then "취소됨" else "cancelled"
  | Disp_skipped -> if ko then "건너뜀" else "skipped"
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
(* An hour's worst turn in the status marks (7.2): finished, rested, failed. *)
let pulse_ok_mark = Status.glyph Status.Settled
let pulse_rested_mark = Status.glyph Status.Waiting
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
(* A resting path waits: the waiting mark (RFC tui-one-screen-grammar 7.2).
   [◌] is a value not read yet (6.4). *)
let grid_wait_glyph = Status.glyph Status.Waiting
let grid_full_mark = "\xe2\x96\x86" (* ▆ *)
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

(* The column headers the views draw, in the screen's language (RFC
   tui-one-screen-grammar 7.1). The legend is English prose, so it names the
   English words above. The Korean words are the ones the Keeper story and the
   memory screen already use for the same readings: 현재 and 다음 in the story
   window, 사실 and 무효화 on the memory screen, and 기억 처리 for the Librarian
   pass column. *)
let grid_column_word ~ko column =
  let say korean english = if ko then korean else english in
  match column with
  | Keeper_column -> say "키퍼" grid_keeper_header
  | Now_column -> say (axis_now_glyph ^ " 현재") axis_now_header
  | Due_column -> say "예정" grid_due_header
  | Lag_column -> say "지연" grid_lag_header
  | Turns_column -> say "턴" grid_turns_word
  | Librarian_column -> say "기억 처리" grid_librarian_header
  | Lag_bar_column -> say ("지연 \xc2\xb7 안 읽은 턴 " ^ axis_next_glyph) grid_lag_bar_header
  | Lag_bar_short_column -> say ("지연 " ^ axis_next_glyph) grid_lag_bar_short_header
  | Digest_column -> say "요약" grid_digest_header
  | Gap_column -> say "빠짐" grid_gap_header
  | Facts_by_age_column -> say "나이별 사실 \xe2\x96\xb8" grid_facts_by_age_header
  | Saved_column -> say "저장" grid_saved_header
  | Stale_column -> say "무효화" grid_stale_header
  | Facts_column -> say "사실" grid_facts_header

type grid_word = Late_word | Held_word | Wait_word | No_data_word | No_snapshot_word

(* The words inside the views' cells, in the screen's language (RFC
   tui-one-screen-grammar 7.1). Each Korean word fits the cell its English one
   takes: the due column is five cells. *)
let grid_word ~ko word =
  let say korean english = if ko then korean else english in
  match word with
  | Late_word -> say "늦음" grid_late_word
  | Held_word -> say "보류" grid_held_word
  | Wait_word -> say "쉼" grid_wait_word
  | No_data_word -> say "기록 없음" grid_no_data_word
  | No_snapshot_word -> say "저장 없음" grid_no_snapshot_word

(* [since 15:43] / [15:43부터] and [5m ago] / [5m 전]: the word sits where
   each language puts it. *)
let grid_since_text ~ko clock = if ko then clock ^ "부터" else grid_since_word ^ " " ^ clock
let grid_ago_text ~ko span = span ^ " " ^ (if ko then "전" else grid_ago_word)

let grid_next_column_word ~ko ~window =
  if ko then "다음 " ^ axis_next_glyph ^ " " ^ window else grid_next_header ~window

let column_legend_for ~ko =
  let say korean english = if ko then korean else english in
  let col column = grid_column_word ~ko column in
  let word cell_word = grid_word ~ko cell_word in
  let letters letter values = String.concat "/" (List.map letter values) in
  let words to_word values = String.concat " / " (List.map to_word values) in
  let pulse_marks =
    [ pulse_ok_mark, say "정상" "ok"
    ; pulse_rested_mark, say "휴식" "rested"
    ; pulse_failed_mark, say "실패" "failed"
    ; pulse_quiet_mark, say "턴 없음" "no turn"
    ; unknown_mark, say "모름" "unknown"
    ]
  in
  let half_hour_marks =
    [ grid_dot_mark, say "턴 없음" "no turn"
    ; grid_pulse_ok_mark, say "정상" "ok"
    ; grid_pulse_failed_and_ok_mark, say "실패·정상 혼재" "failed and ok"
    ; grid_full_mark, say "실패" "failed"
    ; unknown_mark, say "모름" "unknown"
    ]
  in
  let marked marks =
    String.concat " / " (List.map (fun (mark, label) -> mark ^ " " ^ label) marks)
  in
  [ ( say "현재" now_header
    , say "키퍼가 지금 하고 있는 일" "what the keeper is doing at this moment" )
  ; ( say "경과" age_header
    , say
        "마지막 움직임 이후 시간: 진행 중 턴의 최근 갱신(보고 전이면 시작), 없으면 마지막 턴과 대기 시작 중 최근 시각"
        "time since it last moved: the open turn's latest update (its start before it \
         reports one), else the later of its last turn and the start of its wait" )
  ; ( say "단계 / 런타임" "LIFECYCLE"
    , say "키퍼 프로세스 단계와 실행 런타임" "the keeper process" )
  ; ( String.concat " "
        [ axis_before_glyph; grid_now_line; col Now_column; grid_now_line
        ; say "다음 " "next " ^ axis_next_glyph; col Due_column; col Lag_column ]
    , if ko then
        Printf.sprintf
          "목록 외 모든 뷰는 오른쪽 끝 기준으로 같은 열에 맞춰 %s 선이 일렬로 섭니다: 줄 기호(%s 실패, %s 일시정지, \
           원인 뷰의 %s 복구됨, %s 그 외), 이름, 턴 흐름, 현재 칸, 예정 시각(%s 예약 깨움, 빈칸 없음, %s 알 수 없는 구간), \
           다음 예약 실행(하루 내 시각, %s, %s, %s%s 이전 조회, %s 모름), 그리고 가장 뒤처진 키퍼 대비 미처리 턴 막대. \
           2줄 보기에서는 실패 키퍼 아래에 실패 시작(%s), 시도(%s%s%s)와 원인, 다음 런타임(%s, 휴식 중이면 %s %s)이 붙습니다"
          grid_now_line grid_failing_mark grid_paused_mark grid_recovered_mark grid_ok_mark
          grid_wake_mark grid_unknown_range_mark (word Late_word) (word Held_word)
          (word Held_word) unknown_mark unknown_mark axis_before_glyph attempt_glyph
          grid_chain_link attempt_glyph axis_next_glyph grid_wait_glyph (word Wait_word)
      else
        Printf.sprintf
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
          grid_wake_mark grid_unknown_range_mark (word Late_word) (word Held_word)
          (word Held_word) unknown_mark unknown_mark axis_before_glyph attempt_glyph
          grid_chain_link attempt_glyph axis_next_glyph grid_wait_glyph (word Wait_word) )
  ; ( String.concat " "
        [ axis_before_glyph ^ " " ^ col Turns_column; grid_now_line; col Librarian_column
        ; grid_now_line; col Lag_bar_short_column; col Digest_column; col Gap_column ]
    , if ko then
        Printf.sprintf
          "기억 뷰: 턴 흐름, Librarian 마지막 처리 결과(기억 행이 없으면 %s), 목록 중 가장 뒤처진 키퍼 대비 안 읽은 턴 막대, \
           마지막 요약 이후 경과(최초 요약 전은 %s), 요청이 건너뛴 아톰 수 · %s는 서버 미측정 값"
          (word No_data_word) Masc_tui_theme.Glyph.no_value
          Masc_tui_keeper_age_ladder.unmeasured_mark
      else
        Printf.sprintf
          "the memory view: the turn pulse, how the librarian's last pass ended (%s without a \
           memory row), the unread turns as a bar against the listed keeper furthest behind, \
           the time since the last digest (%s before the first) and the atoms requests skip; %s \
           is a value the server did not measure, a pass this server has not seen yet too"
          (word No_data_word) Masc_tui_theme.Glyph.no_value
          Masc_tui_keeper_age_ladder.unmeasured_mark )
  ; ( String.concat " "
        [ col Facts_by_age_column; grid_now_line; col Saved_column; grid_now_line
        ; col Lag_bar_short_column; col Stale_column; col Facts_column ]
    , if ko then
        Printf.sprintf
          "나이 뷰: %s(그룹 제목은 소속 키퍼 합계), %s 스냅샷 저장 경과(스냅샷 없으면 %s %s), 안 읽은 턴 막대, \
           %sN 무효화된 출처 수, 최다 사실 키퍼 대비 사실 수 막대 · %s는 서버 미측정 값"
          (Masc_tui_keeper_age_ladder.column_legend_for ~ko ~empty:grid_dot_mark)
          grid_saved_mark Masc_tui_theme.Glyph.no_value (word No_snapshot_word) grid_stale_mark
          Masc_tui_keeper_age_ladder.unmeasured_mark
      else
        Printf.sprintf
          "the age view: the keeper's facts in %s, and a group title adds up its keepers; %s \
           the time since its memory snapshot was saved (%s %s without one), the unread-turn \
           bar, %sN invalidated sources and the fact count with a level against the keeper with \
           the most facts; %s is a value the server did not measure"
          (Masc_tui_keeper_age_ladder.column_legend_for ~ko ~empty:grid_dot_mark)
          grid_saved_mark Masc_tui_theme.Glyph.no_value (word No_snapshot_word) grid_stale_mark
          Masc_tui_keeper_age_ladder.unmeasured_mark )
  ; ( String.concat " " (List.map fst half_hour_marks)
    , if ko then
        Printf.sprintf
          "턴 흐름(30분 단위): 최근 자율 턴 결과를 30분당 한 기호로 오른쪽이 최신이 되게 표시(%s) · \
           휴식 턴은 실패로 집계, 채팅 턴은 제외, 키퍼 기록 이전 구간은 %s"
          (marked half_hour_marks) unknown_mark
      else
        Printf.sprintf
          "the views' turn pulse: autonomous turn results of the last half hours, one mark \
           per half hour, newest on the right: %s; a rested turn counts as failed, chat turns \
           are not counted, and a half hour from before the server's record of the keeper \
           reads %s. The header names how long the marks span"
          (marked half_hour_marks) unknown_mark )
  ; ( failing_glyph
    , say
        "실패 중인 키퍼의 마지막 실패: 경과 · 원인 · 종료 런타임 · 시도한 후보"
        "a failing keeper's last failure: how long ago · cause · the runtime that ended it \
         · candidates tried. The list draws it in place of its runtime or first in DETAIL" )
  ; ( say "실패 경과" failing_since_word
    , if ko then
        Printf.sprintf
          "실패 상태가 이어진 시간 · 시작 시각 미기록 또는 시계 앞섬이면 %s (상세 2줄)"
          unknown_mark
      else
        Printf.sprintf
          "how long the keeper has been in the failing phase; %s when the server recorded \
           no start, or the start is ahead of this screen's clock (Detailed second row)"
          unknown_mark )
  ; ( String.concat " " (List.map fst pulse_marks)
    , if ko then
        Printf.sprintf
          "최근 %d시간 자율 턴 결과(시간당 한 기호, 오른쪽이 최신): %s · 채팅 턴 제외, 기록 이전 구간은 %s (상세 2줄)"
          pulse_hours (marked pulse_marks) unknown_mark
      else
        Printf.sprintf
          "autonomous turn results of the last %d clock hours, one mark per hour, newest \
           on the right: %s; chat turns are not counted, and an hour from before the \
           server's record of the keeper reads %s (Detailed second row)"
          pulse_hours (marked pulse_marks) unknown_mark )
  ; ( say "모드 " "Mode " ^ letters activation_letter activations
    , words (activation_word ~ko) activations )
  ; (* Both KO ("모드 S") and EN ("Mode S") roster headers use "S" for the sandbox column. *)
    ( "S " ^ letters sandbox_letter sandboxes
    , say "샌드박스: " "sandbox: " ^ words sandbox_word sandboxes )
  ; ( say "쉬는 중" "resting"
    , if ko then
        Printf.sprintf
          "휴식 중인 경로: 남은 휴식 시간(제공자 안내 / 상한 제한) · 상세에서는 턴 실패 뒤 다음 후보 앞에 %s 표시"
          axis_next_glyph
      else
        Printf.sprintf
          "resting path: relative duration (provider stated / bounded); in DETAIL %s prefixes next candidate after turn failure"
          axis_next_glyph )
  ; ( col Due_column
    , say
        "다음 예약 실행 시각 또는 보류 상태 · 상세 일정 배지와 같은 정보"
        "the views' next scheduled run or hold status; DETAIL's schedule badge says the same" )
  ; ( say "mem · 지연 · 무효화" "mem · lag · stale"
    , if ko then
        Printf.sprintf
          "키퍼 기억 상태: 안 읽은 턴 지연, 갱신 시각, 무효화된 출처 · mem %s는 미조회 또는 거부된 행, \
           mem !은 이 키퍼 행 조회 거부, %s는 기억 스냅샷 없음"
          Masc_tui_keeper_age_ladder.unmeasured_mark Masc_tui_theme.Glyph.no_value
      else
        Printf.sprintf
          "keeper memory health: unread gap/lag, update clock, invalidated sources (Detailed second \
           row; its lag under %s in the views, and the memory and age views draw their own cells). \
           mem %s is memory health not read yet, or a refused row that may be this keeper's; mem \
           ! is this keeper's row, refused; %s is a keeper with no memory snapshot"
          grid_lag_header Masc_tui_keeper_age_ladder.unmeasured_mark
          Masc_tui_theme.Glyph.no_value )
  ; ( Masc_tui_keeper_age_ladder.cell_label
    , if ko then
        Printf.sprintf "%s (상세 2줄 · 나이 뷰는 %s 아래 구간 표시, 빈 구간은 %s)"
          (Masc_tui_keeper_age_ladder.legend_for ~ko) (col Facts_by_age_column) grid_dot_mark
      else
        Printf.sprintf
          "%s (Detailed second row; the age view draws the bins under %s, %s for an empty one)"
          (Masc_tui_keeper_age_ladder.legend_for ~ko) (col Facts_by_age_column) grid_dot_mark )
  ; ( String.concat " / "
        (List.map (operator_disposition_word ~ko)
           [ Masc.Keeper_execution_receipt.Disp_operator_action_required
           ; Masc.Keeper_execution_receipt.Disp_effect_review_required
           ; Masc.Keeper_execution_receipt.Disp_unknown
           ])
    , say
        "사람 조치 필요, 효과 확인 필요, 또는 미분류 오류(현재 열)"
        "requires human operator action, effect review, or unmapped fault (NOW column)" )
  ]
