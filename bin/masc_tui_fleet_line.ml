module F = Masc.Fleet_stream
module Keeper_fleet_blocker = Masc.Keeper_fleet_blocker
module Keeper_fleet_grade = Masc.Keeper_fleet_grade
module Terminal_text = Masc_tui_ansi.Terminal_text

let say ko korean english = if ko then korean else english

let blocker_phrase ~ko = function
  | Keeper_fleet_blocker.Keeper_bootstrap_disabled ->
      say ko "Keeper 자동 기동 꺼짐" "keeper bootstrap off"
  | No_executable_keeper_fibers ->
      say ko "턴을 돌 수 있는 Keeper 없음" "no keeper can take a turn"
  | Turn_configuration_error -> say ko "설정 오류로 막힌 Keeper" "config-blocked keepers"
  | Official_client_recovery_required -> say ko "세션 복구 필요" "session recovery required"
  | Reaction_capacity_below_target ->
      say ko "턴 여력이 목표보다 적음" "turn capacity below target"
  | Active_task_owner_without_executable_fiber ->
      say ko "턴 못 도는 작업 담당" "task owner without fiber"
  | Durable_paused_autoboot_enabled ->
      say ko "자동 기동 Keeper 일시정지" "autoboot keepers paused"

(* The English word is the grade's wire name, so a log line and this row agree. *)
let status_text ~ko grade =
  if not ko then Keeper_fleet_grade.wire_name grade
  else
    match grade with
    | Keeper_fleet_grade.Fleet_ok -> "정상"
    | Keeper_fleet_grade.Fleet_degraded -> "저하"
    | Keeper_fleet_grade.Fleet_blocked -> "막힘"

let status_is_ok = function
  | Keeper_fleet_grade.Fleet_ok -> true
  | Keeper_fleet_grade.(Fleet_degraded | Fleet_blocked) -> false

let blocker_text ~ko (fleet : F.fleet) = Option.map (blocker_phrase ~ko) fleet.fs_blocker

let seconds_per_hour = 3600
let seconds_per_minute = 60

(* A setting, not a measurement, so the words must give back the exact value:
   the largest unit that divides it, else the two-unit span. Rounding to the
   nearest minute would show 90 seconds as a setting of 2m. *)
let interval_text interval =
  let seconds = F.Proactive_interval.to_seconds interval in
  if seconds mod seconds_per_hour = 0 then Printf.sprintf "%dh" (seconds / seconds_per_hour)
  else if seconds mod seconds_per_minute = 0 then
    Printf.sprintf "%dm" (seconds / seconds_per_minute)
  else Masc_tui_message_layout.span_text (Float.of_int seconds)

let proactive_text ~ko (fleet : F.fleet) =
  let interval = interval_text fleet.fs_proactive_interval in
  if ko then "자율 턴 " ^ interval ^ "마다" else "proactive every " ^ interval

(* The phase snapshot partitions failing Keepers into retrying, configuration
   errors and official-client session recovery, so the classes drawn sum to
   the failing count. The latter two need more than the same turn again. *)
let failing_text ~ko (fleet : F.fleet) =
  if fleet.fs_failing_count = 0 then None
  else
    let classes =
      List.filter
        (fun (_, count) -> count > 0)
        [ (say ko "재시도 중" "retrying", fleet.fs_recovering_count)
        ; (say ko "설정 오류" "config-blocked", fleet.fs_turn_configuration_error_count)
        ; ( say ko "세션 복구 필요" "session-recovery-required"
          , fleet.fs_official_client_recovery_required_count )
        ]
    in
    let failing =
      Printf.sprintf "%s %d" (say ko "실패" "failing") fleet.fs_failing_count
    in
    match classes with
    | [] -> Some failing
    | _ ->
        Some
          (Printf.sprintf "%s (%s)" failing
             (String.concat " \xc2\xb7 "
                (List.map
                   (fun (label, count) -> Printf.sprintf "%s %d" label count)
                   classes)))

(* The detail after the colon is the server's own words and stays as sent. *)
let failure_text ~ko = function
  | Masc_tui_fleet_stream.Refused { status; detail } ->
      Printf.sprintf
        (if ko then "fleet 스트림이 %d 로 거절함: %s"
         else "fleet stream refused with %d: %s")
        status (Terminal_text.single_line detail)
  | Invalid_response detail ->
      say ko "fleet 스트림 응답을 읽지 못함: " "fleet stream response rejected: "
      ^ Terminal_text.single_line detail
  | Schema_mismatch { expected; received } ->
      Printf.sprintf
        (if ko then "fleet 스트림은 schema %d, 이 빌드는 %d 를 읽음"
         else "fleet stream is schema %d, this build reads %d")
        received expected
  | Frame_rejected detail ->
      say ko "fleet 스트림이 이 빌드가 못 읽는 frame 을 보냄: "
        "fleet stream sent a frame this build cannot read: "
      ^ Terminal_text.single_line detail

let outage_reason_text ~ko = function
  | F.Scan_timed_out -> say ko "갱신 시간 초과" "refresh timed out"
  | F.Scan_failed -> say ko "갱신 실패" "refresh failed"

let stream_lost_text ~ko ~now ~since =
  match Masc_tui_message_layout.age_text ~now ~since with
  | Some age -> if ko then "스트림 끊김 " ^ age ^ " 전" else "stream lost " ^ age ^ " ago"
  | None -> say ko "스트림 끊김" "stream lost"

let not_observed ko = say ko "미관측" "not observed"

let unavailable_text ~ko ~now ~(degradation : F.degradation) ~disconnected_since =
  let reason = outage_reason_text ~ko degradation.reason in
  let scan =
    match Masc_tui_message_layout.age_text ~now ~since:degradation.since with
    | Some age ->
        if ko then Printf.sprintf "%s · %s %s째" (not_observed ko) reason age
        else Printf.sprintf "%s · %s for %s" (not_observed ko) reason age
    | None -> not_observed ko ^ " · " ^ reason
  in
  match disconnected_since with
  | None -> scan
  | Some since -> scan ^ " · " ^ stream_lost_text ~ko ~now ~since

(* No reading was ever told and the stream is down, so nothing was observed
   and the screen says the stream is the reason, not a scan. *)
let unreachable_text ~ko ~now ~since =
  not_observed ko ^ " \xc2\xb7 " ^ stream_lost_text ~ko ~now ~since

(* While the scans fail or the stream is down, the counts beside this are the
   last reading (#38499). The age is taken from [now] at draw time, so it keeps
   growing between events instead of freezing at the age the event had. A
   clock ahead of this one has no age to give, and the tag still says the
   reading is stale. *)
let trouble_text ~ko ~now trouble =
  let stale = say ko "이전 관측" "stale" in
  match trouble with
  | Masc_tui_fleet_stream.Scans_failing { F.since; reason } ->
      let reason = outage_reason_text ~ko reason in
      (match Masc_tui_message_layout.age_text ~now ~since with
       | Some age ->
           if ko then Printf.sprintf "%s \xc2\xb7 스캔 실패 %s째 (%s)" stale age reason
           else Printf.sprintf "%s \xc2\xb7 scans failing for %s (%s)" stale age reason
       | None -> Printf.sprintf "%s (%s)" stale reason)
  | Disconnected { since } ->
      (match Masc_tui_message_layout.age_text ~now ~since with
       | Some _ -> stale ^ " \xc2\xb7 " ^ stream_lost_text ~ko ~now ~since
       | None -> Printf.sprintf "%s (%s)" stale (stream_lost_text ~ko ~now ~since))

(* The task owners the fleet has no fiber for, and how much of that reading is
   missing. A Keeper whose profile does not load is a scan error: its tasks are
   left out of the count, and only a backlog failure moves the fleet status off
   "ok", so an unread Keeper left the row saying nothing at all. The count is
   drawn beside its own shortfall rather than alone.

   [None] where there is neither: a zero over a complete reading is a row spent
   saying nothing happened. *)
let owner_scan_text ~ko (fleet : F.fleet) =
  let owners = fleet.fs_active_task_owner_without_fiber_count in
  let unread = fleet.fs_active_task_owner_scan_error_count in
  if owners = 0 && unread = 0 then None
  else if unread = 0 then
    Some
      (Printf.sprintf "%s %d" (say ko "턴 못 도는 작업 담당" "task owner without fiber") owners)
  else
    (* [+] because the number is a lower bound, not a total: the unread
       sources held whatever they held. The Changes pane spells an open
       record's call count the same way for the same reason. Without it a
       scan that read nothing said "0", which reads as "there are none"
       while the row's own parenthesis says nobody looked. *)
    Some
      (if ko then Printf.sprintf "턴 못 도는 작업 담당 %d+ (출처 %d곳 못 읽음)" owners unread
       else
         Printf.sprintf "task owner without fiber %d+ (%s unread)" owners
           (Masc_tui_message_layout.count_noun unread "source"))
