module Answer = Masc.Keeper_volume_gc_answer

let single_line = Masc.Tui_terminal_text.sanitize_terminal_text
let tool = "masc_sandbox_volume_gc"
let key = "V"
let claims_image = Masc.Keeper_volume_gc_host.claims_image
let timeout_sec = 60.0

type answer =
  | Report of Answer.t
  | Refused of string
  | Unreadable of string

let answer_of_text ~is_error text =
  if is_error
  then Refused text
  else (
    match Yojson.Safe.from_string text with
    | exception Yojson.Json_error detail -> Unreadable ("the answer is not JSON: " ^ detail)
    | json ->
      (match Answer.of_json json with
       | Ok report -> Report report
       | Error detail -> Unreadable detail))
;;

type request =
  | Report_request
  | Reclaim_request of string list

let execute = function
  | Report_request -> false
  | Reclaim_request _ -> true
;;

let arguments = function
  | Report_request -> [ "image", `String claims_image; "execute", `Bool false ]
  | Reclaim_request names ->
    [ "image", `String claims_image
    ; "execute", `Bool true
    ; "keepers", `List (List.map (fun name -> `String name) names)
    ]
;;

type phase =
  | Idle
  | Reporting
  | Armed of string list
  | Reclaiming

type shown =
  | Nothing_asked
  | Answered of answer
  | Unanswered of request * string

type t = { phase : phase; shown : shown }

let initial = { phase = Idle; shown = Nothing_asked }

type press =
  | Send of request
  | Still_running

let press t =
  match t.phase with
  | Idle -> Send Report_request
  | Armed names -> Send (Reclaim_request names)
  | Reporting | Reclaiming -> Still_running
;;

let sending t request =
  match request with
  | Report_request -> { t with phase = Reporting }
  | Reclaim_request _ -> { t with phase = Reclaiming }
;;

let phase_after = function
  | Report report when not report.Answer.executed ->
    (match Answer.reclaim_candidates report with
     | [] -> Idle
     | names -> Armed names)
  | Report _ | Refused _ | Unreadable _ -> Idle
;;

let answered answer = { phase = phase_after answer; shown = Answered answer }
let unanswered request detail = { phase = Idle; shown = Unanswered (request, detail) }

let disarm t =
  match t.phase with
  | Armed _ -> { t with phase = Idle }
  | Idle | Reporting | Reclaiming -> t
;;

type tone =
  | Plain
  | Dim
  | Bad

let names_text names = String.concat ", " (List.map single_line names)

let summary_line report =
  let s = Answer.summary report in
  Printf.sprintf
    "유지 %d · 회수 후보 %d · 회수함 %d · 회수 실패 %d"
    s.Answer.kept
    s.reclaim_candidates
    s.reclaimed
    s.reclaim_failed
;;

let volume_label = function
  | None -> "-"
  | Some name -> single_line name
;;

let keeper_line (verdict : Answer.verdict) =
  let tone =
    match verdict.kind with
    | Answer.Kept -> Dim
    | Answer.Reclaim_candidate | Answer.Reclaimed -> Plain
    | Answer.Reclaim_failed -> Bad
  in
  ( tone
  , Printf.sprintf
      "  %s: %s (work %s, build %s)"
      (single_line verdict.keeper_name)
      (single_line verdict.outcome)
      (volume_label verdict.work_volume)
      (volume_label verdict.build_volume) )
;;

let report_lines (report : Answer.t) =
  let state =
    if report.executed
    then "회수를 요청한 답입니다. 보낸 이름 가운데 지금도 후보인 Keeper 만 지웠습니다."
    else if report.image_given
    then "보고만 받았습니다. 지운 볼륨은 없습니다."
    else "보고만 받았습니다. claims 이미지가 없어 주인을 확인하지 못한 Keeper 는 그대로 둡니다."
  in
  let keepers =
    match report.keepers with
    | [] -> [ Dim, "  은퇴한 Keeper 의 볼륨이 없습니다." ]
    | verdicts -> List.map keeper_line verdicts
  in
  let unlisted =
    match report.unlisted_keepers with
    | [] -> []
    | names -> [ Dim, "  볼륨 목록에 없어 지우지 않은 이름: " ^ names_text names ]
  in
  let foreign =
    match report.foreign_volumes with
    | [] -> []
    | names -> [ Dim, "  Keeper 볼륨이 아닌 것: " ^ names_text names ]
  in
  [ Plain, state; Plain, summary_line report ] @ keepers @ unlisted @ foreign
;;

let shown_lines = function
  | Nothing_asked -> []
  | Answered (Report report) -> report_lines report
  | Answered (Refused detail) -> [ Bad, "서버가 거절했습니다: " ^ single_line detail ]
  | Answered (Unreadable detail) -> [ Bad, "답을 읽지 못했습니다: " ^ single_line detail ]
  | Unanswered (Report_request, detail) ->
    [ Bad, "보고를 받지 못했습니다: " ^ single_line detail ]
  | Unanswered (Reclaim_request _, detail) ->
    [ Bad, "회수 답을 받지 못했습니다: " ^ single_line detail
    ; Bad, "지워졌는지 알 수 없습니다. " ^ key ^ " 로 지금 상태를 다시 보세요."
    ]
;;

let phase_line = function
  | Idle -> Dim, key ^ ": 은퇴한 Keeper 의 볼륨 보고 (지우지 않음)"
  | Reporting -> Dim, "보고를 받는 중입니다."
  | Armed names ->
    ( Bad
    , Printf.sprintf
        "%s 를 한 번 더 누르면 %s 의 build 볼륨을 회수합니다. 다른 키는 취소입니다."
        key
        (names_text names) )
  | Reclaiming -> Dim, "회수를 요청했습니다. 보낸 이름 가운데 지금도 후보인 Keeper 만 지웁니다."
;;

let server_report_line ~timestamp = function
  | None -> Dim, "서버 주기 보고: 아직 없습니다."
  | Some { Masc.Keeper_volume_gc_periodic.observed_at; outcome } ->
    let head = "서버 주기 보고 " ^ timestamp observed_at ^ " · " in
    (match outcome with
     | Masc.Keeper_volume_gc_periodic.Reported report ->
       (match Answer.reclaim_candidates report with
        | [] -> Dim, head ^ "회수 후보 없음"
        | names ->
          Plain, Printf.sprintf "%s회수 후보 %d (%s)" head (List.length names) (names_text names))
     | Masc.Keeper_volume_gc_periodic.Skipped reason -> Dim, head ^ "건너뜀 · " ^ single_line reason
     | Masc.Keeper_volume_gc_periodic.Failed reason -> Bad, head ^ "실패 · " ^ single_line reason)
;;

let lines ~server_report t =
  ((Plain, "은퇴 Keeper 볼륨 (" ^ tool ^ ")") :: phase_line t.phase :: Option.to_list server_report)
  @ shown_lines t.shown
;;

let status_line t =
  match t.shown with
  | Nothing_asked -> "volume GC: not asked"
  | Answered (Report report) ->
    (match t.phase with
     | Armed names ->
       Printf.sprintf
         "volume GC: %s · %s 를 한 번 더 누르면 %s 회수"
         (summary_line report)
         key
         (names_text names)
     | Idle | Reporting | Reclaiming -> "volume GC: " ^ summary_line report)
  | Answered (Refused detail) -> "volume GC refused: " ^ single_line detail
  | Answered (Unreadable detail) -> "volume GC answer unreadable: " ^ single_line detail
  | Unanswered (_, detail) -> "volume GC: no answer: " ^ single_line detail
;;
