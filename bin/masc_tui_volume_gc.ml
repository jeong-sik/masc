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
  | Kept_back of request * string

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
let kept_back request notice = { phase = Idle; shown = Kept_back (request, notice) }

let disarm t =
  match t.phase with
  | Armed _ -> { t with phase = Idle }
  | Idle | Reporting | Reclaiming -> t
;;

type tone =
  | Plain
  | Dim
  | Info
  | Bad

module Say = Masc_tui_say

let ( ++ ) = Say.( ++ )
let received text = Say.as_received (single_line text)
let names_text names = String.concat ", " (List.map single_line names)

let summary_line report =
  let s = Answer.summary report in
  Say.per_language (function
    | Say.Ko -> Printf.sprintf "유지 %d · 회수 후보 %d · 회수함 %d · 회수 실패 %d"
        s.Answer.kept s.reclaim_candidates s.reclaimed s.reclaim_failed
    | Say.En -> Printf.sprintf "kept %d · to reclaim %d · reclaimed %d · reclaim failed %d"
        s.Answer.kept s.reclaim_candidates s.reclaimed s.reclaim_failed)
;;

let volume_label = function
  | None -> "-"
  | Some name -> single_line name
;;

(* The verdict in the tool's own words and the two volumes by name. *)
let keeper_line (verdict : Answer.verdict) =
  let tone =
    match verdict.kind with
    | Answer.Kept -> Dim
    | Answer.Reclaim_candidate | Answer.Reclaimed -> Plain
    | Answer.Reclaim_failed -> Bad
  in
  ( tone
  , Say.code "  " ++ received verdict.keeper_name ++ Say.code ": " ++ received verdict.outcome
    ++ Say.per_language (function
         | Say.Ko -> Printf.sprintf " (작업 %s, build %s)"
             (volume_label verdict.work_volume) (volume_label verdict.build_volume)
         | Say.En -> Printf.sprintf " (work %s, build %s)"
             (volume_label verdict.work_volume) (volume_label verdict.build_volume)) )
;;

let report_lines (report : Answer.t) =
  let state =
    if report.executed
    then Say.both ~ko:"회수를 요청한 답입니다. 보낸 이름 가운데 지금도 후보인 Keeper 만 지웠습니다."
        ~en:"This answers a reclaim request. Only the Keepers sent that were still candidates were removed."
    else if report.image_given
    then Say.both ~ko:"보고만 받았습니다. 지운 볼륨은 없습니다."
        ~en:"A report only. No volume was removed."
    else Say.both ~ko:"보고만 받았습니다. claims 이미지가 없어 주인을 확인하지 못한 Keeper 는 그대로 둡니다."
        ~en:"A report only. With no claims image, Keepers whose owner could not be checked are left alone."
  in
  let keepers =
    match report.keepers with
    | [] -> [ Dim, Say.both ~ko:"  은퇴한 Keeper 의 볼륨이 없습니다." ~en:"  No retired Keeper has a volume." ]
    | verdicts -> List.map keeper_line verdicts
  in
  let unlisted =
    match report.unlisted_keepers with
    | [] -> []
    | names ->
      [ Dim, Say.both ~ko:"  볼륨 목록에 없어 지우지 않은 이름: " ~en:"  Not in the volume list, so not removed: "
             ++ Say.as_received (names_text names) ]
  in
  let foreign =
    match report.foreign_volumes with
    | [] -> []
    | names ->
      [ Dim, Say.both ~ko:"  Keeper 볼륨이 아닌 것: " ~en:"  Not Keeper volumes: "
             ++ Say.as_received (names_text names) ]
  in
  [ Plain, state; Plain, summary_line report ] @ keepers @ unlisted @ foreign
;;

let shown_lines = function
  | Nothing_asked -> []
  | Answered (Report report) -> report_lines report
  | Answered (Refused detail) ->
    [ Bad, Say.both ~ko:"서버가 거절했습니다: " ~en:"The server refused: " ++ received detail ]
  | Answered (Unreadable detail) ->
    [ Bad, Say.both ~ko:"답을 읽지 못했습니다: " ~en:"The answer could not be read: " ++ received detail ]
  | Unanswered (Report_request, detail) ->
    [ Bad, Say.both ~ko:"보고를 받지 못했습니다: " ~en:"No report came back: " ++ received detail ]
  | Unanswered (Reclaim_request _, detail) ->
    [ Bad, Say.both ~ko:"회수 답을 받지 못했습니다: " ~en:"No answer to the reclaim came back: " ++ received detail
    ; Bad, Say.both ~ko:"지워졌는지 알 수 없습니다. " ~en:"Whether anything was removed is unknown. Press "
           ++ Say.code key
           ++ Say.both ~ko:" 로 지금 상태를 다시 보세요." ~en:" to see the state now."
    ]
  (* The workspace guard's notice, written in the screen's language when the
     answer came. *)
  | Kept_back (_, notice) -> [ Bad, Say.as_received notice ]
;;

let phase_line =
  let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way ^ " " in
  function
  | Idle ->
    Dim, Say.code key ++ Say.both ~ko:": 은퇴한 Keeper 의 볼륨 보고 (지우지 않음)"
                          ~en:": report retired Keepers' volumes (removes nothing)"
  | Reporting ->
    Info, Say.code under_way ++ Say.both ~ko:"보고를 받는 중입니다." ~en:"Waiting for the report."
  | Armed names ->
    ( Bad
    , Say.per_language (function
        | Say.Ko -> Printf.sprintf
            "%s 를 한 번 더 누르면 %s 의 build 볼륨을 회수합니다. 다른 키는 취소입니다."
            key (names_text names)
        | Say.En -> Printf.sprintf
            "Press %s again to reclaim the build volumes of %s. Any other key cancels."
            key (names_text names)) )
  | Reclaiming ->
    Info, Say.code under_way
          ++ Say.both ~ko:"회수를 요청했습니다. 보낸 이름 가운데 지금도 후보인 Keeper 만 지웁니다."
               ~en:"Reclaim requested. Only the Keepers sent that are still candidates are removed."
;;

let server_report_line ~timestamp = function
  | None -> Dim, Say.both ~ko:"서버 주기 보고: 아직 없습니다." ~en:"Server's periodic report: none yet."
  | Some { Masc.Keeper_volume_gc_periodic.observed_at; outcome } ->
    let head =
      Say.both ~ko:"서버 주기 보고 " ~en:"Server's periodic report "
      ++ Say.as_received (timestamp observed_at) ++ Say.code " · "
    in
    (match outcome with
     | Masc.Keeper_volume_gc_periodic.Reported report ->
       (match Answer.reclaim_candidates report with
        | [] -> Dim, head ++ Say.both ~ko:"회수 후보 없음" ~en:"nothing to reclaim"
        | names ->
          ( Plain
          , head
            ++ Say.per_language (function
                 | Say.Ko -> Printf.sprintf "회수 후보 %d" (List.length names)
                 | Say.En -> Printf.sprintf "%d to reclaim" (List.length names))
            ++ Say.code " (" ++ Say.as_received (names_text names) ++ Say.code ")" ))
     | Masc.Keeper_volume_gc_periodic.Skipped reason ->
       Dim, head ++ Say.both ~ko:"건너뜀 · " ~en:"skipped · " ++ received reason
     | Masc.Keeper_volume_gc_periodic.Failed reason ->
       Bad, head ++ Say.both ~ko:"실패 · " ~en:"failed · " ++ received reason)
;;

let lines ~server_report t =
  ((Plain, Say.both ~ko:"은퇴 키퍼 볼륨 (" ~en:"Retired Keepers' volumes (" ++ Say.code tool ++ Say.code ")")
   :: phase_line t.phase :: Option.to_list server_report)
  @ shown_lines t.shown
;;

(* Section 4's notice, which moves to two-language values with section 4 in
   the last layer of RFC tui-one-screen-grammar section 7.1. Until then it
   reads as it did, with the summary in Korean. *)
let status_line ?(ko = true) t =
  let lang = if ko then Say.Ko else Say.En in
  let summary_line report = Say.render lang (summary_line report) in
  match t.shown with
  | Nothing_asked ->
      if ko then "볼륨 정리: 조회 전" else "volume GC: not asked"
  | Answered (Report report) ->
    (match t.phase with
     | Armed names ->
       if ko then
         Printf.sprintf "볼륨 정리: %s · %s 를 한 번 더 누르면 %s 회수"
           (summary_line report) key (names_text names)
       else
         Printf.sprintf "volume GC: %s · press %s again to reclaim %s"
           (summary_line report) key (names_text names)
     | Idle | Reporting | Reclaiming ->
       (if ko then "볼륨 정리: " else "volume GC: ") ^ summary_line report)
  | Answered (Refused detail) ->
      (if ko then "볼륨 정리 거절: " else "volume GC refused: ") ^ single_line detail
  | Answered (Unreadable detail) ->
      (if ko then "볼륨 정리 응답 읽기 불가: " else "volume GC answer unreadable: ") ^ single_line detail
  | Unanswered (_, detail) ->
      (if ko then "볼륨 정리: 응답 없음: " else "volume GC: no answer: ") ^ single_line detail
  | Kept_back (_, notice) -> notice
;;
