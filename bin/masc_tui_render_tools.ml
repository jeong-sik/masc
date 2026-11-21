(** The Tools surface: what the selected Keeper's turn called, and what the
    process has registered. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi

(* The Skills list's name column is as wide as its longest name, between
   these two. The floor is the width the column always had. The cap keeps a
   row on an 80-column screen: 32 name cells and an instruction Skill's
   other fields (mark, execution, sizes) come to about 74 cells. A longer
   name is cut in the middle, so two names that share a head still differ
   on screen. *)
let skill_name_min_cells = 22
let skill_name_max_cells = 32

module Tool_tree = Masc_tui_tool_tree
module Tool_table = Masc_tui_tool_table

(* Every word this screen writes is a Masc_tui_say.t (RFC
   tui-one-screen-grammar section 7.1, layer 9), so a literal written in one
   language does not compile here. The language is chosen once, where the
   rows are cut to the frame's width ({!tools_display_lines}). *)
module Say = Masc_tui_say

let ( ++ ) = Say.( ++ )
let say_dot = Say.code " \xc2\xb7 "

(* Right-pads to [cells] display cells without truncating; Korean words are
   measured in cells, not bytes. Use [pad_cells_fit] for fixed-width data
   columns that must truncate cleanly with "…" when wider. *)
let pad_cells cells text =
  text
  ^ String.make
      (max 0 (cells - Masc_tui_message_layout.display_width text))
      ' '

let pad_cells_fit cells text =
  Masc_tui_message_layout.fit_width text cells

let format_unix_ts ~now value =
  if not (Float.is_finite value) then Printf.sprintf "%.3f" value
  else
    try Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_second ~now value
    with Unix.Unix_error _ | Invalid_argument _ -> Printf.sprintf "%.3f" value

let say_language (state : state) =
  match state.ui_language with
  | Lang_ko -> Say.Ko
  | Lang_en -> Say.En

let refusal_text ~request refusal =
  Say.of_ko_flag (fun ~ko -> workspace_refusal_text ~ko ~request refusal)

(* What a section of this screen hands the frame. A [Row] holds its words in
   both languages. A [Cursor] is a row of the entry the list keys act on --
   the Skill's own row and the rows that say why it was loaded: it draws as a
   [Row] in its own style, and {!tools_display} says which physical rows the
   entry takes, so the key handler brings it into view by those numbers
   rather than by looking for its colour. A [Timed] row draws as a [Row]
   whose time text reads differently from the instant it carries. It was
   built without noting that instant ({!Masc_tui_value.Redraw.deferred}):
   {!tools_display} hands it back with each physical row the text lands on,
   and the frame notes it only for a row it draws, so a row scrolled out of
   the window asks for no redraw. A [Laid_out] block is rows fitted to
   a width by a step that has to see the words first -- a boxed card wraps
   its rows, a table keeps its columns only if its header fits, a chart sizes
   its bars beside its names -- so how many rows it takes depends on the
   language, and it gets the language when the frame draws ({!draw}). A
   [Measurement_card] is laid out the same way, and {!tools_display} says
   which rows the selected Skill's measurement card takes. A [Cursor] handed
   to a [Laid_out] block is drawn but not counted, and a [Timed] row there
   is drawn without its instant; the Skill list and the Async request list
   are in none. A [List_entry] is the pieces of one entry of the list the
   move keys walk -- a Skill with its group heading and the rows that say
   why it was loaded, or one async request -- drawn as those pieces are:
   {!tools_display} counts the rows each entry takes, so the frame can page
   by the entries its window holds whole. *)
type piece =
  | Row of string * Say.t
  | Cursor of string * Say.t
  | Timed of string * Say.t * float
  | Laid_out of (Say.language -> (string * string) list)
  | Measurement_card of (Say.language -> (string * string) list)
  | List_entry of piece list

(* Which of {!tools_display}'s runs a drawn row belongs to: none, the
   [Cursor]'s entry, the measurement card, or a [Timed] text with when it
   reads differently. *)
type mark =
  | Unmarked
  | Entry
  | Card
  | Changes_at of float

let rows lines = List.map (fun (style, text) -> Row (style, text)) lines

(* Rows another module wrote in the screen's language: the task document
   reads [state.ui_language] itself. It moves to Masc_tui_say in its own
   layer; until then the frame takes its rows as they are. *)
let written_elsewhere lines = Laid_out (fun _ -> lines)

(* Each drawn row, paired with the run it belongs to. *)
let rec draw_marked language pieces =
  List.concat_map
    (function
      | Row (style, text) -> [ (style, Say.render language text), Unmarked ]
      | Cursor (style, text) -> [ (style, Say.render language text), Entry ]
      | Timed (style, text, at) -> [ (style, Say.render language text), Changes_at at ]
      | Laid_out lay -> List.map (fun row -> row, Unmarked) (lay language)
      | Measurement_card lay -> List.map (fun row -> row, Card) (lay language)
      | List_entry pieces -> draw_marked language pieces)
    pieces

let draw language pieces = List.map fst (draw_marked language pieces)

let tool_domain_rule_cells = 21

let tool_domain_rule =
  String.concat "" (List.init tool_domain_rule_cells (fun _ -> Ansi.box_h))

(* A request row reads its age, and the list scrolls: the age is built
   deferred, so only a row the window draws asks for the redraw on which its
   age reads differently ([Timed]). *)
let async_request_inventory_lines (state : state) =
  let errors = Option.to_list (Option.map (function
    | Request_failed detail -> Theme.bad (),
        Say.both ~ko:" Async broker · 재확인 실패 · 이전 목록 유지: "
          ~en:" Async broker · recheck failed · previous list kept: "
        ++ Say.as_received (Terminal_text.single_line detail)
    | Request_withdrawn refusal -> Theme.bad (),
        Say.code " " ++ refusal_text ~request:Kept_request.Async_requests_read refusal)
    state.tools_async_observation_error) in
  rows errors @ (match state.tools_async_observation with
  | None ->
    if errors=[] then rows [ Theme.warn (), Say.both ~ko:" Async broker · 미조회" ~en:" Async broker · not loaded" ]
    else []
  | Some (Async_unavailable { kind; reason }) ->
    rows [ Theme.bad (),
      Say.both ~ko:" Async broker · 영속 목록 조회 불가: " ~en:" Async broker · durable inventory unavailable: "
      ++ Say.as_received (Terminal_text.single_line kind)
      ++ Option.fold ~none:Say.empty
           ~some:(fun value -> Say.code ": " ++ Say.as_received (Terminal_text.single_line value)) reason ]
  | Some (Async_ready { summary; requests; recovery }) ->
    let summary_lines =
      [ Ansi.bold,
        Say.per_language (function
          | Say.Ko -> Printf.sprintf
              " Async broker · 진행 %d · runtime 소유 %d · 소유 확인 안 됨 %d · 기록 오류 %d"
              summary.ars_active summary.ars_runtime_owned
              summary.ars_ownership_unknown summary.ars_record_errors
          | Say.En -> Printf.sprintf
              " Async broker · active=%d · runtime-owned=%d · ownership-unconfirmed=%d · record-errors=%d"
              summary.ars_active summary.ars_runtime_owned
              summary.ars_ownership_unknown summary.ars_record_errors) ]
    in
    let now = Unix.gettimeofday () in
    let request_lines = List.map (fun request ->
      let tone, ownership = match request.ar_ownership with
        | Async_runtime_owned -> Theme.ok (), Say.both ~ko:"runtime 소유" ~en:"runtime owned"
        | Async_ownership_unknown ->
          Theme.warn (), Say.both ~ko:"디스크에만 있음 · 소유 확인 안 됨" ~en:"on disk only · ownership unconfirmed"
      in
      let status = match request.ar_phase with
        | Async_queued -> Say.both ~ko:"대기열" ~en:"queued"
        | Async_running -> Say.both ~ko:"실행 중" ~en:"running"
        | Async_cancelling -> Say.both ~ko:"취소 중" ~en:"cancelling"
      in
      let elapsed, changes_at =
        Masc_tui_value.Redraw.deferred (fun () ->
          match
            Masc_tui_message_layout.age_text ~now ~since:request.ar_submitted_at
          with
          | Some text -> Say.as_received text
          | None -> Say.code Masc_tui_theme.Glyph.no_value)
      in
      let selected = Option.exists (fun (target : Masc.Tui_decode_async_request.target) ->
        target.request_id=request.ar_request_id && target.submitted_by=request.ar_submitted_by
        && target.keeper_name=request.ar_keeper_name) state.tools_async_selection in
      let text =
        Say.code (if selected then " › " else "   ")
        ++ Say.concat ~sep:say_dot
             [ Say.as_received (Terminal_text.single_line request.ar_request_id);
               Say.as_received (Terminal_text.single_line request.ar_keeper_name);
               status; elapsed; ownership ]
      in
      let row_style = if selected then Theme.selection_style () else tone in
      List_entry
        [ (match changes_at with
           | Some at -> Timed (row_style, text, at)
           | None -> Row (row_style, text)) ]) requests
    in
    let recovery_lines = match recovery with
      | None ->
        [ (Theme.recede ()), Say.both ~ko:"   시작 복구: 이 process 에 보고 없음"
                      ~en:"   startup recovery: not reported to this process" ]
      | Some report ->
        [ (Theme.recede ()),
          Say.both ~ko:"   시작 복구: " ~en:"   startup recovery: "
          ++ Say.code (Printf.sprintf
            "lost=%d finalized=%d cleaned=%d unreadable=%d failed=%d staging=%d/%d/%d"
            report.arr_lost report.arr_finalized report.arr_cleaned
            report.arr_unreadable report.arr_failed report.arr_staging_inspected
            report.arr_staging_deleted report.arr_staging_preserved) ]
    in
    rows summary_lines @ request_lines @ rows recovery_lines)

let async_logical_lines ~now value =
  let module Detail = Masc.Tui_decode_async_request in
  let safe value = Say.as_received (Terminal_text.single_line value) in
  match value with
  | Detail.Not_composition ->
    [Theme.recede (), Say.both ~ko:" 논리: Composition 원본 없음" ~en:" Logical: no original Composition"]
  | Original_run run ->
    [Theme.series_tint Masc_tui_theme.Calls 0.8, Say.both ~ko:" 원본 run: " ~en:" Original run: " ++ safe run.run_id;
     Theme.recede (), Say.both ~ko:" 원본 Task: " ~en:" Original Task: "
       ++ Option.fold ~none:(Say.both ~ko:"없음(기록)" ~en:"none (recorded)") ~some:safe run.source_task_id;
     Theme.recede (), Say.both ~ko:" 현재 run owner: " ~en:" Current run owner: " ++ safe run.owner.request_id
       ++ say_dot ++ Say.per_language (function
            | Say.Ko -> Printf.sprintf "세대 %d" run.owner.generation
            | Say.En -> Printf.sprintf "generation %d" run.owner.generation);
     Theme.recede (), Say.both ~ko:" 논리 관측 시각: " ~en:" Logical observed at: "
       ++ Say.code (format_unix_ts ~now run.observed_at)
       ++ say_dot ++ Say.both ~ko:"저널 " ~en:"journal " ++ safe run.journal_version]
    @ (match run.resolution with
      | None ->
        [Theme.warn (), Say.both ~ko:" 논리: 명시적 종결 없음 · 실행 허가는 별도"
                          ~en:" Logical: no explicit resolution · permission to run is separate"]
      | Some resolution ->
        [Theme.warn (), Say.both ~ko:" 논리: 재개 종결 · " ~en:" Logical: resumption resolved · "
           ++ (match resolution.decision with
               | Detail.Rejected -> Say.both ~ko:"거절" ~en:"rejected"
               | Cancelled_continuation -> Say.both ~ko:"취소" ~en:"cancelled");
         Theme.recede (), Say.both ~ko:" 결정: " ~en:" Decided by: " ++ safe resolution.requested_by
           ++ say_dot ++ Say.code (format_unix_ts ~now resolution.resolved_at);
         Theme.series_tint Masc_tui_theme.Calls 0.8, Say.both ~ko:" 사유: " ~en:" Reason: " ++ safe resolution.reason])

let async_request_detail_lines ~cols state target =
  let module Detail = Masc.Tui_decode_async_request in
  let now = Unix.gettimeofday () in
  let view = Masc_tui_fetched.view_for ~equal:Detail.equal_target state.tools_async_detail ~key:target in
  let pending = Masc_tui_fetched.in_flight state.tools_async_detail in
  let safe value = Say.as_received (Terminal_text.single_line value) in
  let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way ^ " " in
  let reading = match pending,view with
    | true,(Masc_tui_fetched.Absent | Loading | Failed _) ->
      [Theme.info (), Say.code (" " ^ under_way) ++ Say.both ~ko:"원본 요청 조회 중" ~en:"Reading the original request"]
    | true,(Ready _ | Stale _) | false,_ -> [] in
  let failures = match view with
    | Masc_tui_fetched.Absent -> [Theme.recede (), Say.both ~ko:" 미조회" ~en:" Not read"]
    | Loading -> []
    | Failed (Request_failed detail) ->
      [Theme.bad (), Say.both ~ko:" 조회 실패: " ~en:" Read failed: " ++ safe detail]
    | Failed (Request_withdrawn refusal) ->
      [Theme.bad (), Say.code " " ++ refusal_text ~request:Kept_request.Async_request_read refusal]
    | Stale (_,Request_failed detail) ->
      [Theme.warn (), Say.both ~ko:" 마지막 관측 · 재확인 실패: " ~en:" Last observation · recheck failed: "
         ++ safe detail]
    | Stale (_,Request_withdrawn refusal) ->
      [Theme.warn (), Say.both ~ko:" 마지막 관측 · " ~en:" Last observation · "
         ++ refusal_text ~request:Kept_request.Async_request_read refusal]
    | Ready _ -> [] in
  let snapshot = match Masc_tui_fetched.value view with
    | None -> []
    | Some Detail.Absent ->
      [Theme.warn (), Say.both ~ko:" 원본 요청 기록이 없습니다 · 재실행 허가가 아닙니다"
                        ~en:" No record of the original request · this is not permission to run again"]
    | Some (Observed snapshot) ->
      let phase = match snapshot.phase with
        | Detail.Queued -> Say.both ~ko:"대기열" ~en:"queued"
        | Running -> Say.both ~ko:"실행 중" ~en:"running"
        | Cancelling -> Say.both ~ko:"취소 중" ~en:"cancelling"
        | Waiting -> Say.both ~ko:"의존 대기 · worker 해제됨" ~en:"waiting for dependencies · worker released"
        | Lost -> Say.both ~ko:"잃음" ~en:"lost"
        | Cancelled -> Say.both ~ko:"취소됨" ~en:"cancelled"
        | Persistence_failed -> Say.both ~ko:"저장 실패" ~en:"persistence failed"
        | Done true -> Say.both ~ko:"끝남 (물리 성공)" ~en:"done (physical success)"
        | Done false -> Say.both ~ko:"오류 (물리 실패)" ~en:"error (physical failure)" in
      let physical = [Theme.series_tint Masc_tui_theme.Calls 0.8, Say.both ~ko:" 물리 상태: " ~en:" Physical state: " ++ phase;
        Theme.recede (), Say.both ~ko:" 접수: " ~en:" Submitted: " ++ Say.code (format_unix_ts ~now snapshot.submitted_at)
          ++ say_dot ++ Say.both ~ko:"종료: " ~en:"Ended: "
          ++ Option.fold ~none:(Say.both ~ko:"미종료" ~en:"not ended")
               ~some:(fun at -> Say.code (format_unix_ts ~now at)) snapshot.completed_at] in
      let dependencies = List.map (fun dependency ->
        Theme.recede (), Say.both ~ko:" 의존: " ~en:" Depends on: "
          ++ Say.as_received (Terminal_text.single_line
               (Yojson.Safe.to_string (Masc.Keeper_composition_dependency.to_json dependency))))
        snapshot.dependencies in
      let logical = match snapshot.logical with
        | Detail.Confirmed value -> async_logical_lines ~now value
        | Unavailable detail ->
          [Theme.bad (), Say.both ~ko:" 논리 상태 조회 불가: " ~en:" Logical state unavailable: " ++ safe detail]
          @ (match state.tools_async_last_logical with
            | Some (source,value) when Detail.equal_source source snapshot.source ->
              [Theme.warn (), Say.both ~ko:" 아래 논리는 마지막 관측이며 최신 확인이 아닙니다"
                                ~en:" The logical state below is the last observation, not a current check"]
              @ async_logical_lines ~now value
            | Some _ | None ->
              [Theme.recede (), Say.both ~ko:" 확인된 이전 논리 관측 없음" ~en:" No earlier confirmed logical observation"]) in
      physical @ Option.to_list (Option.map (fun notice -> Theme.warn (),
        Say.both ~ko:" 물리 사유: " ~en:" Physical reason: " ++ safe notice) snapshot.notice)
      @ dependencies @ logical in
  [Ansi.bold, Say.both ~ko:" 원본 비동기 요청  t:원본 Task  o:원본 ID 조회  r:재조회  Esc:목록"
                ~en:" Original async request  t:original Task  o:read original ID  r:read again  Esc:list"]
  @ reading @ failures @ snapshot

let async_source_task_lines ~cols state source =
  let width=max 1 (Masc_tui_frame.inner_width ~cols) in
  let now = Unix.gettimeofday () in
  let ko = state.ui_language = Lang_ko in
  let body=Masc_tui_fetched.view_for ~equal:equal_tools_async_task_source state.tools_async_task_body ~key:source in
  let history=Masc_tui_fetched.view_for ~equal:equal_tools_async_task_source state.tools_async_task_history ~key:source in
  let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
  let pending = if Masc_tui_fetched.in_flight state.tools_async_task_body then
      [Theme.info (), Say.both ~ko:(" " ^ under_way ^ " Task 본문 조회 중 · 기존 관측·실패 유지")
                   ~en:(" " ^ under_way ^ " Reading the Task body · earlier observation and failure kept")] else [] in
  let errors=match body with
    | Masc_tui_fetched.Absent -> [Theme.recede (), Say.both ~ko:" Task 본문 미조회" ~en:" Task body not read"]
    | Loading | Ready _ -> []
    | Failed (Request_failed detail) ->
      [Theme.bad (), Say.both ~ko:" Task 본문 조회 실패: " ~en:" Task body read failed: " ++ Say.as_received detail]
    | Failed (Request_withdrawn refusal) ->
      [Theme.bad (), Say.code " " ++ refusal_text ~request:Kept_request.Original_task_read refusal]
    | Stale (_,Request_failed detail) ->
      [Theme.warn (), Say.both ~ko:" Task 본문 재확인 실패 · 마지막 관측: "
                        ~en:" Task body recheck failed · last observation: " ++ Say.as_received detail]
    | Stale (_,Request_withdrawn refusal) ->
      [Theme.warn (), Say.code " " ++ refusal_text ~request:Kept_request.Original_task_read refusal
         ++ say_dot ++ Say.both ~ko:"마지막 관측" ~en:"last observation"] in
  let content=match Masc_tui_fetched.value body with
    | None -> []
    | Some (detail : Masc.Tui_decode_task_inspection.detail) ->
      let warnings=match detail.task.handoff_context with
        | None | Some (Masc_domain.Handoff_decoded _) -> []
        | Some (Handoff_unreadable {reason;raw=_}) ->
          [Theme.warn (), Say.both ~ko:" Task handoff 조회 불가: " ~en:" Task handoff unreadable: "
             ++ Say.as_received reason] in
      rows warnings
      @ [ written_elsewhere (task_document_lines state ~cols Masc_tui_task_document.Body
            |> List.map (fun line -> "",line)) ] in
  rows
  [Ansi.bold, Say.both ~ko:" 원본 Task · " ~en:" Original Task · " ++ Say.as_received source.ats_task_id
     ++ Say.both ~ko:"  r:재조회  Esc:원본 요청" ~en:"  r:reread  Esc:original request";
   Theme.recede (), Say.both ~ko:" 출처 run: " ~en:" Source run: " ++ Say.as_received source.ats_run_id
     ++ Say.both ~ko:" · 논리 관측 " ~en:" · logical observation "
     ++ Say.code (format_unix_ts ~now source.ats_observed_at)
     ++ (if source.ats_retained
         then Say.both ~ko:" · 이전 확인 관측에서 열림" ~en:" · opened from an earlier confirmed observation"
         else Say.empty)]
  @ rows (pending @ errors) @ content
  @ [ Row ("", Say.empty) ]
  @ [ written_elsewhere (Masc_tui_task_document.history_heading_rows ~ko ~width:(max 1 (width - 2))
     |> List.map (fun row -> "", row)) ]
  @ [ written_elsewhere (Masc_tui_task_document.history_status_lines ~ko ~width
       ~view:(observation_failure_said (history_failure_said ~ko
         ~request:Kept_request.Task_history_read) history)
       ~in_flight:(Masc_tui_fetched.in_flight state.tools_async_task_history)
       ~continuing:(Option.exists (fun request -> Option.is_some request.thr_page.hr_cursor)
         state.tools_async_task_history_request)
      |> List.concat_map (fun line ->
           Masc_tui_text_block.preformatted_rows ~max_cells:width line
           |> List.map (fun row -> "", row))) ]
  @ [ written_elsewhere (task_document_lines state ~cols Masc_tui_task_document.History
     |> List.map (fun line -> "",line)) ]

let async_request_observation_lines ~cols state =
  match state.tools_async_detail_open,state.tools_async_selection,state.tools_async_task_source with
  | true,Some _,Some source -> async_source_task_lines ~cols state source
  | true,Some target,None -> rows (async_request_detail_lines ~cols state target)
  | true,None,_ | false,_,_ -> async_request_inventory_lines state

(* The Tools sections, named where the reader is standing. Same shape as
   {!config_pane_strip}: a reader who has seen one has seen the other. *)
(* Revisions remain complete: the physical document wraps them at the
   viewport width, so operators can compare the actual identities. *)
(* The Skill discovery roots, in the order the catalog consults them.

   The pane named skills and never named where they were looked for, so
   "my Skill is not loaded" had no first question to ask. A root that is
   missing, refused, or read-only contributes nothing and only shows here:
   the editor's own sources endpoint filters to the read-write roots that
   resolved, because it is choosing somewhere to write. *)
let skill_access_short = function
  | "read-write" -> "rw"
  | "read-only" -> "ro"
  | other -> other
;;

(* The status marks of RFC tui-one-screen-grammar 7.2 in their 7.3 tones. A
   source that holds skills is settled. One that holds none, or is not there,
   is a value read as none (6.4). A path that is not a directory asks for a
   look, and a source that could not be read or whose path the config refused
   failed; the words say which. [!] and [✓] are not status marks. *)
let skill_source_status status = (Theme.status_tone status, Masc_tui_value.Mark.glyph status)

let skill_source_reading (observation : Masc.Tui_decode_tools.skill_source_observation) =
  match observation with
  | Masc.Tui_decode_tools.Skill_source_ready count ->
    let tone, mark =
      if count = 0 then (Theme.recede (), Masc_tui_theme.Glyph.no_value)
      else skill_source_status Masc_tui_value.Mark.Settled
    in
    ( tone
    , mark
    , Say.per_language (function
        | Say.Ko -> Printf.sprintf "Skill 디렉터리 %d개" count
        | Say.En -> Printf.sprintf "%d skill director%s" count (if count = 1 then "y" else "ies")) )
  | Masc.Tui_decode_tools.Skill_source_missing ->
    (Theme.recede (), Masc_tui_theme.Glyph.no_value, Say.both ~ko:"없음" ~en:"missing")
  | Masc.Tui_decode_tools.Skill_source_not_directory kind ->
    let tone, mark = skill_source_status Masc_tui_value.Mark.Caution in
    ( tone, mark
    , Say.both ~ko:"디렉터리가 아님 (" ~en:"not a directory (" ++ Say.as_received kind ++ Say.code ")" )
  | Masc.Tui_decode_tools.Skill_source_unavailable operation ->
    let tone, mark = skill_source_status Masc_tui_value.Mark.Failed in
    ( tone, mark
    , Say.both ~ko:"읽을 수 없음: " ~en:"unreadable at " ++ Say.as_received operation )
  | Masc.Tui_decode_tools.Skill_source_unresolved ->
    let tone, mark = skill_source_status Masc_tui_value.Mark.Failed in
    (tone, mark, Say.both ~ko:"설정이 경로를 거부함" ~en:"path refused by config")
;;

let skill_config_line (config : Masc.Tui_decode_tools.skill_catalog_config option) =
  match config with
  | None -> []
  | Some (Masc.Tui_decode_tools.Skill_config_configured { revision; resource_read_max_bytes })
    ->
    let cap =
      match resource_read_max_bytes with
      | None -> Say.both ~ko:"resource 읽기 한도 없음" ~en:"no resource read cap"
      | Some bytes ->
        Say.per_language (function
          | Say.Ko -> Printf.sprintf "resource 읽기 \xe2\x89\xa4 %s바이트" (Masc_tui_value.Count.grouped bytes)
          | Say.En -> Printf.sprintf "resource read \xe2\x89\xa4 %s bytes" (Masc_tui_value.Count.grouped bytes))
    in
    [ ( (Theme.recede ())
      , Say.both ~ko:"   설정 " ~en:"   config "
        ++ Say.as_received (Terminal_text.single_line revision) ++ say_dot ++ cap )
    ]
  | Some (Masc.Tui_decode_tools.Skill_config_rejected { source_revision; diagnostics }) ->
    (* The catalog still stands on the defaults, so nothing else on the
       screen changes when the operator's section stops parsing. *)
    ( Theme.warn ()
    , Say.per_language (function
        | Say.Ko -> Printf.sprintf "   runtime.toml Skill 설정 거부됨 (rev %s) · 기본값 사용"
            (Terminal_text.single_line source_revision)
        | Say.En -> Printf.sprintf "   runtime.toml Skill config rejected (rev %s) · defaults in use"
            (Terminal_text.single_line source_revision)) )
    :: List.map
         (fun diagnostic ->
            (Theme.warn (), Say.code "     " ++ Say.as_received (Terminal_text.single_line diagnostic)))
         diagnostics
  | Some Masc.Tui_decode_tools.Skill_config_unreadable ->
    [ ( Theme.warn ()
      , Say.both ~ko:"   runtime.toml Skill 설정을 읽을 수 없음 · 기본값 사용"
          ~en:"   runtime.toml Skill config unreadable · defaults in use" )
    ]
;;

(* A composition skill's execution plan, as the batches it runs in.

   The flow arrives decoded in full -- every node, the tool it calls, the
   batch it sits in and how that batch runs -- and no renderer read any of
   it, so the pane could say a composition had been invoked twelve times
   without ever saying what it invokes.

   The batches are the ordering the server recorded. The usage card follows
   this summary with the complete node, batch and dependency records.

   Same arrow as the Goal stage rail and the Fusion topology row, so three
   surfaces spell a pipeline one way. *)
let skill_flow_line (flow : Masc.Tui_decode_tools.skill_flow) =
  let tool_of id =
    List.find_map
      (fun (node : Masc.Tui_decode_tools.skill_flow_node) ->
         if String.equal node.sfn_id id then Some node.sfn_tool_name else None)
      flow.sf_nodes
  in
  let batch (b : Masc.Tui_decode_tools.skill_flow_batch) =
    match List.filter_map tool_of b.sfb_node_ids with
    | [] -> None
    | tools ->
      Some
        (Printf.sprintf "%s %s"
           (Terminal_text.single_line b.sfb_execution_mode)
           (String.concat " \xc2\xb7 "
              (List.map Terminal_text.single_line tools)))
  in
  (* Execution modes and tool names as the server declared them. *)
  match List.filter_map batch flow.sf_batches with
  | [] -> None
  | parts -> Some (Say.as_received (String.concat "  \xe2\x94\x80\xe2\x96\xb6  " parts))
;;

(* Complete composition metadata, including nodes outside the recorded
   batches. The final physical-row projection keeps each value reachable. *)
let skill_flow_detail_lines (flow : Masc.Tui_decode_tools.skill_flow) =
  let safe value = Say.as_received (Terminal_text.single_line value) in
  let batches = List.map
    (fun (batch : Masc.Tui_decode_tools.skill_flow_batch) ->
      (Theme.recede ()),
      Say.per_language (function
        | Say.Ko -> Printf.sprintf "배치 %d · " batch.sfb_index
        | Say.En -> Printf.sprintf "Batch %d · " batch.sfb_index)
      ++ safe batch.sfb_execution_mode
      ++ Say.both ~ko:" · 노드: " ~en:" · nodes: "
      ++ safe (String.concat ", " batch.sfb_node_ids))
    flow.sf_batches in
  let nodes = List.concat_map
    (fun (node : Masc.Tui_decode_tools.skill_flow_node) ->
      ((Theme.recede ()),
       Say.both ~ko:"노드 " ~en:"Node " ++ safe node.sfn_id
       ++ Say.both ~ko:" · 도구: " ~en:" · tool: " ++ safe node.sfn_tool_name
       ++ Say.per_language (function
            | Say.Ko -> Printf.sprintf " · 배치: %d · 방식: " node.sfn_batch_index
            | Say.En -> Printf.sprintf " · batch: %d · mode: " node.sfn_batch_index)
       ++ safe node.sfn_execution_mode)
      :: (match node.sfn_dependencies with
          | [] -> [(Theme.recede ()), Say.both ~ko:"  의존: 없음" ~en:"  Dependencies: none"]
          | dependencies -> List.map
              (fun (dependency : Masc.Tui_decode_tools.skill_flow_dependency) ->
                (Theme.recede ()),
                Say.both ~ko:"  의존 " ~en:"  Dependency " ++ safe dependency.sfd_node_id
                ++ Say.both ~ko:" · 종류: " ~en:" · kind: " ++ safe dependency.sfd_kind) dependencies))
    flow.sf_nodes in
  batches @ nodes
;;

let skill_source_lines ~cols ~config ~(sources : Masc.Tui_decode_tools.skill_catalog_source list) =
  let ready =
    List.length
      (List.filter
         (fun (source : Masc.Tui_decode_tools.skill_catalog_source) ->
            match source.scso_observation with
            | Masc.Tui_decode_tools.Skill_source_ready count -> count > 0
            | Masc.Tui_decode_tools.Skill_source_missing
            | Masc.Tui_decode_tools.Skill_source_unresolved
            | Masc.Tui_decode_tools.Skill_source_not_directory _
            | Masc.Tui_decode_tools.Skill_source_unavailable _ -> false)
         sources)
  in
  let total = List.length sources in
  let heading =
    ( Ansi.bold ^ Theme.section_heading ()
    , Say.per_language (function
        | Say.Ko -> Printf.sprintf " Skill 출처 · 루트 %d개 중 %d개에 Skill 있음" total ready
        | Say.En -> Printf.sprintf " Skill Sources · %d of %d root%s carrying skills"
            ready total (if total = 1 then "" else "s")) )
  in
  let meter_row =
    let inner = Masc_tui_frame.inner_width ~cols in
    if total <= 0 || inner < 24 then []
    else
      let meter_width = min 44 (max 16 (inner - 6)) in
      [ ( ""
        , Say.per_language (fun lang ->
              let label = match lang with Say.Ko -> "활성 루트" | Say.En -> "Active roots" in
              "   "
              ^ Masc_tui_chart.dot_meter ~width:meter_width ~value:ready ~max_value:(max 1 total)
                  ~label ~label_style:(Theme.recede ())
                  ~suffix:(Printf.sprintf "%d/%d" ready total)
                  ~scale:(Masc_tui_chart.Series { paint = Theme.paint (); series = Masc_tui_theme.Capacity })
                  ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()) )
      ]
  in
  let source_rows =
    List.map
      (fun (source : Masc.Tui_decode_tools.skill_catalog_source) ->
         let tone, mark, reading = skill_source_reading source.scso_observation in
         let path =
           match source.scso_path with
           | Some path -> Say.as_received (pad_cells_fit 26 (Terminal_text.single_line path))
           | None ->
             Say.map (pad_cells 26)
               (Say.both ~ko:"(절대 경로라 공개 안 함)" ~en:"(absolute; path not published)")
         in
         ( tone
         , Say.code (Printf.sprintf "   %s " mark)
           ++ Say.as_received
                (pad_cells_fit 16 (Terminal_text.single_line source.scso_id) ^ " "
                 ^ pad_cells_fit 10 (Terminal_text.single_line source.scso_anchor) ^ " ")
           ++ path
           ++ Say.code (" " ^ pad_cells 2 (skill_access_short source.scso_access) ^ "  ")
           ++ reading ))
      sources
  in
  match sources with
  | [] -> []
  | _ -> (heading :: meter_row @ source_rows) @ skill_config_line config @ [ (Theme.recede (), Say.empty) ]
;;

(* The catalog's volume child shows what the next press sends, the server's
   last periodic inventory report, and the last operator-request answer. *)
let volume_tone = function
  | Masc_tui_volume_gc.Plain -> ""
  | Masc_tui_volume_gc.Dim -> Theme.recede ()
  | Masc_tui_volume_gc.Ok -> Theme.ok ()
  | Masc_tui_volume_gc.Warn -> Theme.warn ()
  | Masc_tui_volume_gc.Info -> Theme.info ()
  | Masc_tui_volume_gc.Bad -> Theme.bad ()

let volume_gc_lines (state : state) =
  let now = Unix.gettimeofday () in
  let gc_sig =
    match state.volume_gc.phase with
    | Masc_tui_volume_gc.Reporting -> Some "reporting"
    | Masc_tui_volume_gc.Reclaiming -> Some "reclaiming"
    | Masc_tui_volume_gc.Idle | Masc_tui_volume_gc.Armed _ -> None
  in
  let started_at =
    Masc_tui_types.progress_clock_option state ~slot:"tools-volume-gc" ~now gc_sig
  in
  let server_report =
    Option.map
      (fun (snapshot : Masc.Tui_decode_tools.tool_snapshot) ->
         Masc_tui_volume_gc.server_report_line
           ~timestamp:Terminal_text.short_timestamp_of_unix
           snapshot.Masc.Tui_decode_tools.ts_volume_gc_report)
      state.tools_inventory
  in
  List.map
    (fun (tone, text) ->
      let text =
        match tone, started_at with
        | Masc_tui_volume_gc.Info, Some at ->
            let duration = Masc_tui_value.Ongoing.since ~now at in
            text ++ Say.both ~ko:(" · " ^ duration ^ " 경과") ~en:(" · " ^ duration)
        | (Masc_tui_volume_gc.Plain | Dim | Ok | Warn | Info | Bad), (Some _ | None) -> text
      in
      Row (volume_tone tone, Say.code " " ++ text))
    (Masc_tui_volume_gc.lines ~server_report state.volume_gc)
;;

(* The storage pane: the host disk and the server's cleanup results from the
   inventory's envelope, then the server's periodic report on retired
   Keepers' volumes, which the catalog's volume child acts on. Before the
   first inventory reading there is nothing to draw but the frame's own
   "reading" line. *)
let storage_lines (state : state) =
  match state.tools_inventory with
  | None -> []
  | Some (snapshot : Masc.Tui_decode_tools.tool_snapshot) ->
    let timestamp = Terminal_text.short_timestamp_of_unix in
    let uptime =
      Option.bind state.server_identity (fun (identity : Masc.Tui_decode.server_identity) ->
        identity.sid_uptime)
    in
    let reading =
      List.map
        (fun (tone, text) ->
           let color =
             match tone with
             | Masc_tui_storage.Heading -> Ansi.bold
             | Masc_tui_storage.Plain -> ""
             | Masc_tui_storage.Dim -> Theme.recede ()
             | Masc_tui_storage.Warn -> Theme.warn ()
             | Masc_tui_storage.Bad -> Theme.bad ()
           in
           color, Say.code " " ++ text)
        (Masc_tui_storage.lines ~timestamp ~uptime snapshot.ts_storage)
    in
    let tone, report =
      Masc_tui_volume_gc.server_report_line ~timestamp snapshot.ts_volume_gc_report
    in
    rows
      (reading
       @ [ Ansi.bold, Say.both ~ko:" 은퇴한 Keeper 의 볼륨" ~en:" Retired Keepers' volumes"
         ; volume_tone tone, Say.code "   " ++ report
         ; (Theme.recede ()),
           Say.both ~ko:"   회수: 전체 도구 탭  " ~en:"   Reclaim on All tools tab  "
           ++ Say.code Masc_tui_volume_gc.key
           ++ Say.both ~ko:":정리" ~en:":reclaim" ])
;;

(* Through [tab_strip], the one drawing every in-screen strip shares. This one
   was left out when the others moved: a bar between names, a space before the
   unmarked ones and the mark without the information colour, so the Tools
   row read "▸호출 범위 | 비동기 작업" under strips spelled two cells apart. *)
let tools_pane_strip ~cols (state : state) =
  let active_pane = match state.tools_pane with
    | Tools_catalog (Tools_catalog_volumes _) -> Tools_catalog Tools_catalog_list
    | (Tools_surface | Tools_async | Tools_usage | Tools_storage
      | Tools_catalog Tools_catalog_list) as pane -> pane in
  let language = say_language state in
  tab_strip ~numbered:true
    ~width:(tab_strip_width ~cols ~before:" " ~after:"")
    ~press:(fun pane text -> Masc_tui_press.(pressable (Press_tools_pane pane) text))
    (List.map
       (fun pane ->
         let label =
           Say.both ~ko:(tools_pane_label ~ko:true pane) ~en:(tools_pane_label ~ko:false pane)
         in
         (Say.render language label, active_pane = pane, pane))
       tools_panes)
;;

let skill_usage_box ~cols rows =
  let width = Masc_tui_frame.inner_width ~cols in
  let content_width = max 1 (width - 4) in
  let border_style = Theme.border_muted () in
  let border left right = border_style, left ^ draw_hline (max 0 (width - 2)) ^ right in
  let vbar = Ansi.wrap_style border_style Ansi.box_v in
  let body =
    List.concat_map (fun (style, text) ->
      (if Masc_tui_message_layout.display_width text <= content_width then [text]
       else Masc_tui_message_layout.wrap_styled_words ~max_cells:content_width text)
      |> List.map (fun line ->
        "",
        vbar ^ " " ^ Ansi.wrap_style style (fit_width line content_width) ^ " " ^ vbar)) rows
  in
  if width < 5 then
    List.concat_map (fun (style, text) ->
      Masc_tui_message_layout.wrap_styled_words ~max_cells:(max 1 width) text
      |> List.map (fun line -> style, line)) rows
  else
    border Ansi.box_tl Ansi.box_tr :: body
    @ [border Ansi.box_bl Ansi.box_br; Theme.recede (), ""]
;;

let skill_json_lines ~cols ~indent json =
  let width = max 1 (Masc_tui_frame.inner_width ~cols) in
  let lines = Yojson.Safe.pretty_to_string json
    |> String.split_on_char '\n'
    |> List.map Terminal_text.single_line in
  let widest = List.fold_left (fun widest line ->
    max widest (Masc_tui_message_layout.widest_grapheme_cells line)) 0 lines in
  let gutter = Masc_tui_message_layout.display_width
    (Masc_tui_markdown_theme.palette ~closing:Ansi.reset).code_gutter in
  let indent =
    if width < gutter + widest then 0
    else min indent (width - gutter - widest) in
  let indent = String.make indent ' ' in
  let body_width = max 1 (width - String.length indent) in
  let source = String.concat "\n" lines in
  Masc_tui_markdown_theme.code ~language:"json" ~width:body_width source
  |> List.map (fun line -> Ansi.reset, indent ^ line)

type 'row skill_json_projection =
  { json_source : Yojson.Safe.t
  ; json_cols : int
  ; json_palette_generation : int
  ; json_lines : 'row list
  }

let skill_schema_projection = ref None

let cached_skill_json projection ~cols ~render json =
  let generation = Masc_tui_terminal_palette.(snapshot_generation (snapshot ())) in
  match !projection with
  | Some cached when cached.json_source == json && cached.json_cols = cols
                     && cached.json_palette_generation = generation -> cached.json_lines
  | Some _ | None ->
      let lines = render json in
      projection := Some {json_source=json; json_cols=cols;
        json_palette_generation=generation; json_lines=lines};
      lines

(* A boxed card: the box wraps each row to its inside width. *)
let card ~cols pieces =
  Laid_out (fun language -> skill_usage_box ~cols (draw language pieces))

(* JSON as the ledger recorded it, laid out as a code block. *)
let json_rows lines = List.map (fun (style, text) -> style, Say.as_received text) lines

let skill_io_lines ~cols = function
  | Masc.Tui_decode_tools.Model_orchestrated ->
      [ (Theme.recede ()), Say.both ~ko:"     입력: 정확한 Skill 참조 / 고를 수 있는 resource 경로"
                    ~en:"     Input: exact Skill reference / optional resource path";
        (Theme.recede ()), Say.both ~ko:"     출력: 지침 본문이나 resource · 그다음 도구는 모델이 고름"
                    ~en:"     Output: instruction body or resource; subsequent tools are model-orchestrated";
        (Theme.recede ()), Say.both ~ko:"     평균 실행 시간: 지침 텍스트에는 없음"
                    ~en:"     Average execution: not applicable to instruction text" ]
  | Composition_io { input_schema; exports } ->
      (Ansi.bold, Say.both ~ko:"     선언한 입력 schema (필수 인자, 타입, enum)"
                    ~en:"     Declared input schema (required parameters, types and enums)")
      :: json_rows (cached_skill_json skill_schema_projection ~cols
           ~render:(skill_json_lines ~cols ~indent:7) input_schema)
      @ (match exports with
         | [] -> [(Theme.recede ()), Say.both ~ko:"     선언한 출력: 실행 결과 전체 (고른 export 없음)"
                              ~en:"     Declared output: complete execution result (no selected exports)"]
         | routes ->
           (Ansi.bold, Say.both ~ko:"     선언한 출력 경로" ~en:"     Declared output routes")
           :: List.map (fun route ->
             (Theme.recede ()),
             Say.code "       " ++ Say.as_received (Terminal_text.single_line route.Masc.Tui_decode_tools.sor_name)
             ++ Say.both ~ko:" ← 노드 " ~en:" ← node " ++ Say.as_received (Terminal_text.single_line route.sor_node_id)
             ++ Say.code " · JSON pointer "
             ++ (if route.sor_pointer = "" then Say.both ~ko:"(루트)" ~en:"(root)"
                 else Say.as_received (Terminal_text.single_line route.sor_pointer))) routes)
;;

let request_selection_prefix = Say.both ~ko:"요청: " ~en:"Request: "

let skill_selection_prefix ~index ~count =
  Say.code (Printf.sprintf "Skill %d/%d: " (index + 1) count)

(* The selection row of the frame, drawn by the frame in the screen's
   language. *)
let tools_selection_line ~cols state =
  let language = say_language state in
  let text = match state.tools_skill_source_picker with
    | Some picker ->
      Say.both ~ko:"새 " ~en:"New "
      ++ Say.code (if picker.ssp_composition then "Composition" else "Instruction")
      ++ Say.both ~ko:" · 저장할 곳 고르기" ~en:" · choose a save location"
    | None when Option.is_some (tools_volume_gc_parent_scroll state.tools_pane) ->
      Say.both ~ko:"은퇴한 Keeper의 볼륨" ~en:"Retired Keeper volumes"
    | None when state.tools_pane = Tools_storage ->
      Say.both ~ko:"호스트 디스크와 Keeper 저장 공간 정리" ~en:"Host disk and Keeper storage cleanup"
    | None when state.tools_pane = Tools_async ->
      (match state.tools_async_selection with
       | None -> Say.both ~ko:"비동기 요청: 없음" ~en:"Async request: none"
       | Some target ->
         Say.map (Masc_tui_message_layout.fit_middle (Masc_tui_frame.inner_width ~cols))
           (request_selection_prefix ++ Say.as_received (Terminal_text.single_line target.request_id)))
    | None ->
      let profiles = tools_skill_profiles state in
      let count = List.length profiles in
      let cursor = clamped_tools_skill_cursor ~count state.tools_skill_cursor in
      (match List.nth_opt profiles cursor with
       | None -> Say.both ~ko:"Skill: 없음" ~en:"Skill: none"
       | Some profile ->
         let prefix = skill_selection_prefix ~index:cursor ~count in
         prefix ++ Say.as_received (Masc_tui_message_layout.fit_middle
           (max 1 (Masc_tui_frame.inner_width ~cols
                   - Masc_tui_message_layout.display_width (Say.render language prefix)))
           (Terminal_text.single_line profile.esp_name)))
  in
  Say.render language text

(* The selection row above the document cuts the middle of a name that does
   not fit the row. The document names the selection again only then, so a
   name that fits is on screen once and a cut name can still be read whole.
   Whether it fits depends on the words, so it is decided when the language
   is chosen. *)
let named_again ~cols ~selection_row ~title =
  Laid_out (fun language ->
    if Masc_tui_message_layout.display_width (Say.render language selection_row)
       > Masc_tui_frame.inner_width ~cols
    then draw language [ title ] else [])

let request_selection_document ~cols (target : Masc.Tui_decode_async_request.target) =
  let request_id = Say.as_received (Terminal_text.single_line target.request_id) in
  [ named_again ~cols ~selection_row:(request_selection_prefix ++ request_id)
      ~title:(Row (Ansi.bold, Say.code " " ++ request_selection_prefix ++ request_id))
  ; Row ((Theme.recede ()),
         Say.both ~ko:" 원래 요청자: " ~en:" Requested by: "
         ++ Say.as_received (Terminal_text.single_line target.submitted_by)
         ++ Say.both ~ko:" · 대상 Keeper: " ~en:" · Keeper: "
         ++ Say.as_received (Terminal_text.single_line target.keeper_name)) ]

(* The Skill at [index] of [count]: its selection row counts its place, so
   whether the row fits depends on the place as well as on the name. *)
let skill_selection_document ~cols ~count index
    (profile : Masc.Tui_decode_tools.effective_skill_profile) =
  let reference = profile.esp_reference in
  let name = Say.as_received (Terminal_text.single_line profile.esp_name) in
  (* Where the Skill comes from is one fact in three parts, so it takes
     one row: the list below gets the two rows the parts used to take
     each. A row too long for the frame wraps rather than cutting an
     identity. *)
  let field label value = label ++ Say.code " " ++ Say.as_received value in
  [ named_again ~cols ~selection_row:(skill_selection_prefix ~index ~count ++ name)
      ~title:(Row (Ansi.bold, Say.both ~ko:"동작 대상 Skill: " ~en:"Action Skill: " ++ name))
  ; Row ((Theme.recede ()),
         Say.concat ~sep:say_dot
           [ field (Say.both ~ko:"출처" ~en:"Source") (Terminal_text.single_line
               (Skill_reference.identity_source_id_to_string reference.identity));
             field (Say.both ~ko:"패키지" ~en:"Package") (Terminal_text.single_line
               (Skill_reference.identity_package_id_to_string reference.identity));
             field (Say.both ~ko:"리비전" ~en:"Revision") (Masc_tui_value.Hash.short (Terminal_text.single_line
               (Skill_reference.content_revision_to_string reference.content_revision))) ]) ]

let tools_selection_document ~cols state =
  if state.tools_pane = Tools_async then
    Option.fold ~none:[] ~some:(request_selection_document ~cols) state.tools_async_selection
  else
    let profiles = tools_skill_profiles state in
    let count = List.length profiles in
    let cursor = clamped_tools_skill_cursor ~count state.tools_skill_cursor in
    match List.nth_opt profiles cursor with
    | None -> []
    | Some profile ->
        skill_selection_document ~cols ~count cursor profile

(* The loaded list the move keys walk on this pane, as it was read: the
   Skills of the Effective Keeper Surface, or the async requests while no
   request is open. A new read is a new list. *)
type selections =
  | Skill_selections of Masc.Tui_decode_tools.effective_skill_profile list
  | Request_selections of Tui_decode.async_request_row list

let selections (state : state) =
  match state.tools_pane with
  | Tools_surface -> (
      match state.tools_inventory with
      | Some
          { Masc.Tui_decode_tools.ts_effective =
              Some (Masc.Tui_decode_tools.Effective_surface_available { ets_skill_profiles; _ })
          ; _ } ->
          Some (Skill_selections ets_skill_profiles)
      | Some
          { Masc.Tui_decode_tools.ts_effective =
              None | Some (Masc.Tui_decode_tools.Effective_surface_unavailable _)
          ; _ }
      | None -> None)
  | Tools_async when not state.tools_async_detail_open -> (
      match state.tools_async_observation with
      | Some (Tui_decode.Async_ready { requests; _ }) -> Some (Request_selections requests)
      | Some (Tui_decode.Async_unavailable _) | None -> None)
  | Tools_async | Tools_usage | Tools_storage | Tools_catalog _ -> None

let same_selections seen loaded =
  match seen, loaded with
  | Skill_selections seen, Skill_selections loaded -> seen == loaded
  | Request_selections seen, Request_selections loaded -> seen == loaded
  | Skill_selections _, Request_selections _ | Request_selections _, Skill_selections _ -> false

(* The document of every selection the list can land on, in the order the
   list draws them, from the state the list was read from. *)
let selection_documents ~cols state = function
  | Skill_selections _ ->
      let profiles = tools_skill_profiles state in
      List.mapi (skill_selection_document ~cols ~count:(List.length profiles)) profiles
  | Request_selections _ -> List.map (request_selection_document ~cols) (tools_async_targets state)

(* The rows the tallest of those documents takes, counted once for as long
   as the same list is loaded at the same width in the same language, as the
   Memory screen counts its tallest fact: wrapping every entry's document on
   each frame made a Skill key on 54 Skills about two fifths slower, and the
   cost grows with the list. *)
let tallest_selection_memo : (selections * int * Say.language * int) option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let tallest_selection_rows ~cols ~language ~rows_of state loaded =
  match Domain.DLS.get tallest_selection_memo with
  | Some (seen, seen_cols, seen_language, tallest)
    when same_selections seen loaded && seen_cols = cols && seen_language = language -> tallest
  | Some _ | None ->
      let tallest =
        List.fold_left
          (fun tallest document -> max tallest (rows_of document))
          0 (selection_documents ~cols state loaded)
      in
      Domain.DLS.set tallest_selection_memo (Some (loaded, cols, language, tallest));
      tallest

(* The Effective Keeper Surface's diagnostics: what the runtime says about
   itself, the two digests and the byte budgets. [hash] draws a digest: its
   head on screen (RFC tui-one-screen-grammar, section 5.2), the whole value
   in a copy. An unavailable surface has none. *)
let effective_surface_diagnostics ~hash = function
  | Masc.Tui_decode_tools.Effective_surface_unavailable _ -> []
  | Masc.Tui_decode_tools.Effective_surface_available
      { ets_runtime_id; ets_official_client_kind; ets_native_posture;
        ets_skill_snapshot_revision; ets_skill_resource_read_max_bytes;
        ets_tool_surface_bytes; ets_skill_tool_surface_bytes;
        ets_skill_discovery_bytes; ets_skill_body_bytes; ets_tool_surface_sha256; _ } ->
      let byte_count = function
        | Some bytes -> Printf.sprintf "%dB" bytes
        | None -> "?"
      in
      [ Say.code (Printf.sprintf "runtime=%s  client=%s  native=%s"
          (Terminal_text.single_line ets_runtime_id)
          (Terminal_text.single_line ets_official_client_kind)
          (Option.value
             ~default:(Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported)
             ets_native_posture))
      ; Say.code "skill snapshot=" ++ Say.as_received (hash (Terminal_text.single_line ets_skill_snapshot_revision))
      ; (match ets_skill_resource_read_max_bytes with
         | Some max_bytes ->
           Say.per_language (function
             | Say.Ko -> Printf.sprintf "미룬 resource 한도 %s바이트" (Masc_tui_value.Count.grouped max_bytes)
             | Say.En -> Printf.sprintf "deferred resource bound=%s bytes" (Masc_tui_value.Count.grouped max_bytes))
         | None -> Say.both ~ko:"미룬 resource 한도 없음" ~en:"deferred resource bound=not configured")
      ; Say.per_language (function
          | Say.Ko -> Printf.sprintf
              "Skill 맥락: profile 탐색 %dB · 미룬 본문 %s · skill 도구 schema %s / 전체 도구 %s"
              ets_skill_discovery_bytes (byte_count ets_skill_body_bytes)
              (byte_count ets_skill_tool_surface_bytes) (byte_count ets_tool_surface_bytes)
          | Say.En -> Printf.sprintf
              "Skill context: profile discovery=%dB · deferred bodies=%s · skill tool schema=%s/%s all tools"
              ets_skill_discovery_bytes (byte_count ets_skill_body_bytes)
              (byte_count ets_skill_tool_surface_bytes) (byte_count ets_tool_surface_bytes))
      ; Say.code "digest="
        ++ (match ets_tool_surface_sha256 with
            | None -> Say.both ~ko:"없음 (턴은 Agent Core 가 가짐)" ~en:"none (Agent Core owns the turn)"
            | Some value -> Say.as_received (hash (Terminal_text.single_line value))) ]

(* What Y copies, in the screen's language. *)
let tools_diagnostics_copy_text (state : state) =
  match state.tools_inventory with
  | None | Some { Masc.Tui_decode_tools.ts_effective = None; _ } -> None
  | Some { Masc.Tui_decode_tools.ts_effective = Some surface; _ } ->
      (match surface with
       | Masc.Tui_decode_tools.Effective_surface_unavailable _ -> None
       | Masc.Tui_decode_tools.Effective_surface_available { ets_keeper_name; _ } ->
           let field label value = label ++ Say.code ": " ++ Say.as_received (Terminal_text.single_line value) in
           let profiles = tools_skill_profiles state in
           let skill_cursor =
             clamped_tools_skill_cursor ~count:(List.length profiles) state.tools_skill_cursor
           in
           let skill =
             match List.nth_opt profiles skill_cursor with
             | None -> []
             | Some profile ->
                 let reference = profile.esp_reference in
                 [ field (Say.code "Skill") profile.esp_name
                 ; field (Say.both ~ko:"출처" ~en:"Source")
                     (Skill_reference.identity_source_id_to_string reference.identity)
                 ; field (Say.both ~ko:"패키지" ~en:"Package")
                     (Skill_reference.identity_package_id_to_string reference.identity)
                 ; field (Say.both ~ko:"리비전" ~en:"Revision")
                     (Skill_reference.content_revision_to_string reference.content_revision) ]
           in
           Some
             (Say.render (say_language state)
                (Say.concat ~sep:(Say.code "\n")
                   (field (Say.code "Keeper") ets_keeper_name
                    :: effective_surface_diagnostics ~hash:Fun.id surface
                    @ skill))))

let skill_source_picker_prefix summary =
  [ Ansi.bold, Say.both ~ko:" 패키지 저장 출처 선택 (쓰기 가능)"
                 ~en:" Choose the writable source for this package"
  ; (Theme.recede ()), Say.both ~ko:" j/k·화살표:선택  Enter:편집  /:필터  Esc:취소"
                ~en:" j/k/arrows:select  Enter:edit  /:filter  Esc:cancel"
  ; (Theme.recede ()), Say.code " " ++ summary ]

let skill_source_picker_page state ~terminal_rows =
  max 1 (tools_content_rows state ~terminal_rows ~count:0
    - List.length (skill_source_picker_prefix Say.empty))

let surface_title = Say.both ~ko:" Keeper 호출 범위" ~en:" Effective Keeper Surface"

type cursor_rows = { first_row : int; last_row : int }

type display =
  { lines : (string * string) list
  ; cursor : cursor_rows option
  ; card : cursor_rows option
  ; row_changes : (int * float) list
  ; entries : (paged_list * cursor_rows list) option
  }

let tools_display ?(cols = 80) ?terminal_rows (state : state) : display =
  let language = say_language state in
  match state.tools_skill_source_picker with
  | Some picker ->
    let terminal_rows = match terminal_rows with Some rows -> rows | None -> fst (get_terminal_size ()) in
    let view = Masc_tui_pick_list.view ~page:(skill_source_picker_page state ~terminal_rows)
      ~window:Masc_tui_pick_list.Opens_at_cursor ~label:Fun.id picker.ssp_sources picker.ssp_list in
    (* The picker pages its own window to its cursor, so no Skill row is
       reported for the frame to scroll to, and it draws no time text. *)
    { lines =
        draw language (rows
          (skill_source_picker_prefix (Say.of_ko_flag (fun ~ko -> Masc_tui_pick_list.summary ~ko view))
           @ (if view.rows = [] then [Theme.warn (), Say.both ~ko:" 맞는 출처 없음" ~en:" No matching source"] else
               List.mapi (fun index source ->
                 let selected = view.selected_row = Some index in
                 (if selected then Theme.selection_style () else ""),
                 Say.code (if selected then " › " else "   ")
                 ++ Say.as_received (Terminal_text.single_line source)) view.rows)))
    ; cursor = None
    ; card = None
    ; row_changes = []
    ; entries = None }
  | None ->
  let registered_tools =
    match state.tools_inventory with
    | None -> []
    | Some s -> s.Masc.Tui_decode_tools.ts_tools
  in
  let effective_lines =
    lazy begin
    match state.tools_inventory with
    (* Unread and failed are two answers. "not loaded" under the red
       "tool inventory load failed" row sent the reader to [r] for a read
       that had already been made and refused. *)
    | None ->
        rows
          [ ( (if Option.is_some (selected_tools_error state) then Theme.bad () else Theme.warn ())
            , surface_title ++ Say.code " "
              ++ Say.of_ko_flag (fun ~ko -> title_missing_reading ~ko ~error:(selected_tools_error state)) )
          ]
    | Some { Masc.Tui_decode_tools.ts_effective = None; _ } ->
        rows [ (Theme.warn ()), surface_title ++ Say.both ~ko:" · 고른 Keeper 없음" ~en:" · no Keeper selected" ]
    | Some
        { Masc.Tui_decode_tools.ts_effective =
            Some
              (Masc.Tui_decode_tools.Effective_surface_unavailable
                 { ets_keeper_name; ets_reason; ets_detail });
          _ } ->
        rows
          [ (Theme.bad ()),
            surface_title ++ Say.code " · " ++ Say.as_received (Terminal_text.single_line ets_keeper_name)
            ++ Say.both ~ko:" · 조회 불가 (" ~en:" · unavailable ("
            ++ Say.as_received (Terminal_text.single_line ets_reason) ++ Say.code ")";
            (Theme.bad ()), Say.code "   " ++ Say.as_received (Terminal_text.single_line ets_detail) ]
    | Some
        { Masc.Tui_decode_tools.ts_effective =
            Some
              (Masc.Tui_decode_tools.Effective_surface_available
                 { ets_keeper_name;
                   (* The fields bound to [_] are drawn under the diagnostics
                      heading, by [effective_surface_diagnostics]. *)
                   ets_runtime_id = _;
                   ets_official_client_kind = _;
                   ets_tool_delivery;
                   ets_native_posture = _;
                   ets_skill_snapshot_revision = _;
                   ets_skill_resource_read_max_bytes = _;
                   ets_skills_left_out;
                   ets_unavailable_skill_names;
                   ets_skill_profiles;
                   ets_tool_surface_bytes = _;
                   ets_skill_tool_surface_bytes = _;
                   ets_skill_discovery_bytes = _;
                   ets_skill_body_bytes = _;
                   ets_tools;
                   ets_tool_surface_sha256 = _;
                 } as surface);
          _ } ->
        let delivery_tone, delivery =
          match ets_tool_delivery with
          | Masc.Tui_decode_tools.Effective_tools_delivered ->
            (Theme.recede ()), Say.both ~ko:"지원" ~en:"delivered"
          | Masc.Tui_decode_tools.Effective_tools_suppressed_runtime_unsupported ->
            Theme.warn (), Say.both ~ko:"미지원으로 제외" ~en:"left out, the runtime does not support tools"
        in
        (* Folded under one heading by default (RFC tui-one-screen-grammar,
           section 5.1): these rows sat above the Skill list, two of them a
           64-character digest each. *)
        let diagnostics_lines =
          let folded = state.tools_diagnostics_folded in
          ( (Theme.recede ()),
            Say.code (Printf.sprintf "   %s " (if folded then "▸" else "▾"))
            ++ Say.both ~ko:"진단" ~en:"Diagnostics"
            ++ say_dot ++ Say.code (Masc_tui_keys.expand_turn_label ^ " ")
            ++ (if folded then Say.both ~ko:"펴기" ~en:"unfold" else Say.both ~ko:"접기" ~en:"fold")
            ++ say_dot ++ Say.code "Y " ++ Say.both ~ko:"전체 복사" ~en:"copy all" )
          :: (if folded then []
              else
                List.map (fun line -> (Theme.recede ()), Say.code "     " ++ line)
                  (effective_surface_diagnostics ~hash:Masc_tui_value.Hash.short surface))
        in
        let origin_label = function
          | Masc.Tui_decode_tools.Descriptor_origin ->
              Say.both ~ko:"정의" ~en:"descriptor"
          | Masc.Tui_decode_tools.Instruction_skill_origin ->
              Say.both ~ko:"지침 스킬" ~en:"instruction_skill"
          | Masc.Tui_decode_tools.Composition_skill_origin { skill_source_id = Some source_id } ->
              Say.both ~ko:"컴포지션 스킬:" ~en:"composition_skill:"
              ++ Say.as_received (Terminal_text.single_line source_id)
          | Masc.Tui_decode_tools.Composition_skill_origin { skill_source_id = None } ->
              Say.both ~ko:"컴포지션 스킬" ~en:"composition_skill"
          | Masc.Tui_decode_tools.Composition_control_origin ->
              Say.both ~ko:"컴포지션 제어" ~en:"composition_control"
          | Masc.Tui_decode_tools.Unrecognised_origin raw ->
              Say.as_received (Terminal_text.single_line raw)
        in
        let tool_lines =
          List.map
            (fun (tool : Masc.Tui_decode_tools.effective_tool) ->
               (* The source id, not the skill name: the name repeats what
                  the tool is already called (keeper_compose_work-intake ->
                  work-intake), while the id answers the question this
                  column asks -- which configured source this came from. It
                  is also short, so the column does not have to cut it. *)
               "",
               Say.per_language (fun lang ->
                 Say.render lang
                   (Tool_table.effective_tool_line
                      ~name:(Terminal_text.single_line (Masc.Tool_display.list_label tool.et_name))
                      ~origin:(Say.render lang (origin_label tool.et_origin)))))
            ets_tools
        in
        let ets_skill_profiles = tools_skill_profiles state in
        let skill_cursor =
          clamped_tools_skill_cursor ~count:(List.length ets_skill_profiles)
            state.tools_skill_cursor
        in
        let is_normal profile = match profile.Masc.Tui_decode_tools.esp_io with
          | Model_orchestrated -> true | Composition_io _ -> false in
        (* The name column is as wide as the longest name, up to a cap, so a
           long name such as [verify-before-claiming-done] no longer pushes
           its row's execution and sizes past every other row's. *)
        let skill_name_cells =
          List.fold_left
            (fun widest (profile : Masc.Tui_decode_tools.effective_skill_profile) ->
              max widest
                (Masc_tui_message_layout.display_width
                   (Terminal_text.single_line profile.esp_name)))
            skill_name_min_cells ets_skill_profiles
          |> min skill_name_max_cells
        in
        let skill_profile_lines =
          List.mapi
            (fun index (profile : Masc.Tui_decode_tools.effective_skill_profile) ->
               let instruction = is_normal profile in
               let glyph, mode_tone, execution =
                 match profile.esp_surface with
                 | Masc.Keeper_skill_observability.Instruction_skill ->
                   ( "\xe2\x97\x87" (* ◇ *)
                   , Theme.series_tint Masc_tui_theme.Memory 0.8
                   , Say.both ~ko:"필요할 때" ~en:"on-demand" )
               in
               (* An instruction skill is text the model reads; it has no
                  flow, so its node, batch and parallel counts are zero on
                  every row. A composition's are the shape of its plan and
                  are drawn. *)
               let flow =
                 if instruction then ""
                 else
                   Printf.sprintf " nodes=%d batches=%d parallel=%d"
                     profile.esp_node_count
                     profile.esp_batch_count
                     profile.esp_max_parallelism
               in
               (* Why a skill is loaded is worth a row when something chose
                  it. Loaded because the catalog holds it is the default for
                  every skill here, and a row per skill saying so is the same
                  sentence down the pane. *)
               let chosen =
                 profile.esp_load_reasons
                 |> List.filter_map (function
                      | Masc.Tui_decode_tools.Skill_catalog_default -> None
                      | Masc.Tui_decode_tools.Skill_keeper_profile ->
                        Some (Say.both ~ko:"Keeper 프로필" ~en:"Keeper profile")
                      | Masc.Tui_decode_tools.Skill_task task_id ->
                        Some (Say.code "Task " ++ Say.as_received (Terminal_text.single_line task_id)))
               in
               let heading =
                 let first_in_group = index = 0 ||
                   (match List.nth_opt ets_skill_profiles (index - 1) with
                    | None -> true
                    | Some previous -> is_normal previous <> instruction) in
                 if not first_in_group then [] else
                   [ Ansi.bold ^ Theme.series_tint Masc_tui_theme.Calls 0.8,
                     Say.code "   "
                     (* Headings follow the screen language and are not
                        written in capitals only (RFC tui-one-screen-grammar
                        section 5.1); Skill and Composition are product
                        nouns and stay as they are. *)
                     ++ (if instruction
                         then Say.both ~ko:"지침 Skill" ~en:"Normal Skills · instructions"
                         else Say.both ~ko:"Composition Skill · 실행 계획"
                             ~en:"Composition Skills · executable plans")
                     ++ Say.code (Printf.sprintf " (%d)"
                          (List.length (List.filter (fun value -> is_normal value = instruction) ets_skill_profiles)))] in
               let selected = index = skill_cursor in
               let name_fitted =
                 Masc_tui_message_layout.fit_middle skill_name_cells
                   (Terminal_text.single_line profile.esp_name)
               in
               let skill_row_plain =
                 Say.code (Printf.sprintf " %s " Masc_tui_theme.Glyph.current_entry)
                 ++ Say.as_received name_fitted
                 ++ Say.code (" " ^ glyph ^ " ")
                 ++ Say.map (pad_cells 11) execution
                 ++ Say.code (Printf.sprintf "%s discovery=%dB body=%dB"
                      flow profile.esp_discovery_bytes profile.esp_body_bytes)
               in
               let skill_row_styled =
                 Say.per_language (fun language ->
                   let exec_col = pad_cells 11 (Say.render language execution) in
                   let name_col = Ansi.bold ^ name_fitted ^ Ansi.reset in
                   let badge_col = mode_tone ^ glyph ^ " " ^ exec_col ^ Ansi.reset in
                   let stats_col =
                     Theme.recede ()
                     ^ Printf.sprintf "%s discovery=%dB body=%dB"
                         flow profile.esp_discovery_bytes profile.esp_body_bytes
                     ^ Ansi.reset
                   in
                   "   " ^ name_col ^ " " ^ badge_col ^ stats_col)
               in
               (* The rows that say why the selected Skill was loaded are
                  its rows too, so following the cursor brings them in. *)
               let entry_rows lines =
                 if selected then List.map (fun (style, text) -> Cursor (style, text)) lines
                 else rows lines
               in
               List_entry
                 (rows heading
                  @ [ (if selected then Cursor (Theme.selection_style (), skill_row_plain)
                       else Row ("", skill_row_styled)) ]
                  @ entry_rows (match profile.esp_load_reasons, chosen with
                      | [], _ ->
                          [ ( Theme.warn ()
                            , Say.both ~ko:"     불러온 이유: 알 수 없음" ~en:"     why loaded: unattributed" ) ]
                      | _, [] -> []
                      | _, chosen ->
                          [ ( Theme.recede ()
                            , Say.both ~ko:"     불러온 이유: " ~en:"     why loaded: "
                              ++ Say.concat ~sep:(Say.code " + ") chosen )
                          ])))
            ets_skill_profiles
        in
        let selected_skill_flow_lines =
          match List.nth_opt ets_skill_profiles skill_cursor with
          | None -> []
          | Some { Masc.Tui_decode_tools.esp_flow = None; _ } ->
            [ (Theme.recede ()), Say.both ~ko:"     흐름: 지침 본문 온디맨드 로드 · 도구 모델 자율 선택"
                          ~en:"     Flow: instruction body loads on demand; the model orchestrates tools" ]
          | Some { Masc.Tui_decode_tools.esp_flow = Some flow; _ } ->
            (* Grouped under the batch that runs them, rather than listed
               flat with a batch=N to cross-reference. The batches are the
               order; the nodes are what is in each one. Two readings, and
               the old shape made the reader join them by hand.

               A tree, not a graph: the dependencies are already named on the
               node, and drawing edges between rows buys a picture at the
               price of a screen nobody can scan. *)
            let node_by_id id =
              List.find_opt
                (fun (node : Masc.Tui_decode_tools.skill_flow_node) ->
                   String.equal node.sfn_id id)
                flow.sf_nodes
            in
            let dependency_text (node : Masc.Tui_decode_tools.skill_flow_node) =
              match node.sfn_dependencies with
              | [] -> ""
              | values ->
                "  \xe2\x86\x90 "
                ^ (values
                   |> List.map (fun (dependency : Masc.Tui_decode_tools.skill_flow_dependency) ->
                        dependency.sfd_node_id ^ ":" ^ dependency.sfd_kind)
                   |> String.concat ", ")
            in
            let batch_count = List.length flow.sf_batches in
            let batch_lines =
              flow.sf_batches
              |> List.mapi (fun batch_position (batch : Masc.Tui_decode_tools.skill_flow_batch) ->
                let last_batch = batch_position = batch_count - 1 in
                let node_count = List.length batch.sfb_node_ids in
                batch.sfb_node_ids
                |> List.mapi (fun node_position node_id ->
                  let first_node = node_position = 0 in
                  let stem =
                    if first_node then
                      if last_batch then "\xe2\x94\x94" else "\xe2\x94\x9c"
                    else if last_batch then " "
                    else "\xe2\x94\x82"
                  in
                  let label =
                    if first_node then
                      Printf.sprintf "%d %s" batch.sfb_index
                        (Terminal_text.single_line batch.sfb_execution_mode)
                    else ""
                  in
                  let tool, dependencies =
                    match node_by_id node_id with
                    | None -> Say.both ~ko:"(노드에 없음)" ~en:"(not in nodes)", ""
                    | Some node ->
                      ( Say.as_received (Terminal_text.single_line node.sfn_tool_name)
                      , dependency_text node )
                  in
                  ( (Theme.recede ())
                  , Say.code (Printf.sprintf "     %s " stem)
                    ++ Say.as_received
                         (pad_cells 12 label ^ " "
                          ^ pad_cells 18 (Terminal_text.single_line node_id)
                          ^ " ")
                    ++ tool ++ Say.as_received dependencies ))
                |> fun lines ->
                if node_count = 0 then
                  [ ( (Theme.recede ())
                    , Say.code (Printf.sprintf "     %s %d "
                        (if last_batch then "\xe2\x94\x94" else "\xe2\x94\x9c")
                        batch.sfb_index)
                      ++ Say.as_received (Terminal_text.single_line batch.sfb_execution_mode)
                      ++ Say.both ~ko:" (노드 없음)" ~en:" (no nodes)" )
                  ]
                else lines)
              |> List.concat
            in
            ( Ansi.bold
            , Say.per_language (function
                | Say.Ko -> Printf.sprintf "     선언한 그래프 · Ctrl-O:Pele · 배치 %d개 · 노드 %d개"
                    batch_count (List.length flow.sf_nodes)
                | Say.En -> Printf.sprintf "     Declared graph · Ctrl-O:Pele · %d batches · %d nodes"
                    batch_count (List.length flow.sf_nodes)) )
            :: batch_lines
        in
        let selected_skill_statistics_lines, selected_skill_evidence_lines = [], [] in
        let performance_card =
          match List.nth_opt ets_skill_profiles skill_cursor with
          | None -> []
          | Some profile ->
            let card_body = match profile.esp_io with
              | Masc.Tui_decode_tools.Model_orchestrated ->
                  rows
                    (* f and the keys that walk the list are in section 5
                       of the frame, so the card names no key of its own. *)
                    [ (Theme.recede ()), Say.both ~ko:"지침 Skill · executor 실행 시간 없음"
                        ~en:"Normal Skill · instructions have no executor run time" ]
              | Composition_io _ -> selected_skill_statistics_lines in
            let pending = match state.tools_evidence_reference, state.tools_evidence_request with
              | Some reference, Some _ when Skill_reference.equal reference profile.esp_reference ->
                  let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
                  [ Theme.info (), Say.both ~ko:(under_way ^ " 실측 조회 중 · 이전 관측 유지")
                                     ~en:(under_way ^ " Reading measurements · earlier observation retained") ]
              | Some _, Some _ | Some _, None | None, Some _ | None, None -> [] in
            let card_pieces =
              rows
                ((Ansi.bold, Say.both ~ko:"Skill 실측 · " ~en:"Skill performance · "
                             ++ Say.as_received (Terminal_text.single_line profile.esp_name))
                 :: pending)
              @ card_body
            in
            [ Measurement_card (fun language -> skill_usage_box ~cols (draw language card_pieces)) ]
        in
        let selected_profile = List.nth_opt ets_skill_profiles skill_cursor in
        rows
          [ Ansi.bold,
            surface_title ++ Say.code " · " ++ Say.as_received (Terminal_text.single_line ets_keeper_name)
            ++ Say.code " ("
            ++ Say.per_language (function
                 | Say.Ko -> Printf.sprintf "도구 %d개" (List.length ets_tools)
                 | Say.En -> Masc_tui_message_layout.count_noun (List.length ets_tools) "tool")
            ++ Say.code ")" ]
        @ rows
            ([ delivery_tone, Say.both ~ko:"   Runtime 도구 전달: " ~en:"   Runtime tool delivery: " ++ delivery ]
             @ diagnostics_lines)
        (* The keys that move through this list are in section 5 of the
           frame, so the list carries no hint row of its own. *)
        @ skill_profile_lines
        (* The selected Skill's card stands under the list, with the rest of
           its detail. Above the list it took one row for an instruction
           Skill and about twelve for a Composition with loaded measurements,
           so each j moved every Skill row under it (RFC
           tui-one-screen-grammar section 8). *)
        @ performance_card
        @ rows
          ((match selected_profile with
             | None -> [] | Some profile -> skill_io_lines ~cols profile.esp_io)
          @ selected_skill_flow_lines
          @ (match state.tools_evidence_reference, state.tools_evidence_request, selected_profile with
             | Some reference, Some _, Some profile when Skill_reference.equal reference profile.esp_reference ->
                 let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
                 [Theme.info (),
                  Say.both ~ko:("     " ^ under_way ^ " 요청한 실행 불러오는 중: ")
                    ~en:("     " ^ under_way ^ " Loading requested run ")
                  ++ Option.fold ~none:(Say.both ~ko:"최신" ~en:"latest")
                       ~some:(fun run_id -> Say.as_received (Masc.Keeper_tool_plan.Composition_run_id.to_string run_id))
                       state.tools_evidence_run_id
                  ++ Say.both ~ko:" · 이전 관측 유지" ~en:" · previous observation retained"]
             | _ -> [])
          @ selected_skill_evidence_lines
          (* Said on this surface because this is the one that answers "what can
             this Keeper call". A document the catalog could not read is absent
             from that answer, and absence with nothing beside it reads as a
             skill nobody wrote rather than one that did not load. Drawn only
             when there is one, so a healthy workspace gains no row. *)
          @ (match ets_skills_left_out with
             | [] -> []
             | left_out ->
               let count = List.length left_out in
               ( (Theme.warn ()),
                 Say.per_language (function
                   | Say.Ko -> Printf.sprintf "   카탈로그에서 빠진 스킬 %d개" count
                   | Say.En ->
                       Printf.sprintf "   %d %s left out of the catalog"
                         count (if count = 1 then "skill" else "skills")) )
               :: List.map
                    (fun entry ->
                      (Theme.warn ()),
                      Say.code "     " ++ Say.as_received (Terminal_text.single_line entry))
                    left_out)
          (* A configured name the turn catalog does not hold is a different
             fact from a document that failed to read: the operator selected a
             Skill that is not there. The dashboard says it under "Unavailable
             Skills"; without these rows this screen answered "what can this
             Keeper call" while staying silent about a selection that did
             nothing. Drawn only when there is one. *)
          @ (match ets_unavailable_skill_names with
             | [] -> []
             | unavailable ->
               let count = List.length unavailable in
               ( (Theme.warn ()),
                 Say.per_language (function
                   | Say.Ko -> Printf.sprintf "   턴 카탈로그에 없는 설정 스킬 이름 %d개" count
                   | Say.En ->
                       Printf.sprintf "   %d configured skill %s not in the turn catalog"
                         count (if count = 1 then "name" else "names")) )
               :: List.map
                    (fun { Masc.Tui_decode_tools.csn_name; csn_reason } ->
                      (Theme.warn ()),
                      Say.code "     "
                      ++ Say.as_received (Terminal_text.single_line csn_name)
                      ++ say_dot
                      ++ Say.as_received (Terminal_text.single_line csn_reason))
                    unavailable)
          @ [ Ansi.bold, Tool_table.effective_tool_header ]
          @ tool_lines)
    end
  in
  let catalog_lines =
    lazy begin
    match state.tools_inventory with
    | None ->
        rows
          [ Theme.warn (),
            Say.both ~ko:" 전체 등록 도구 · 조회 자료 없음" ~en:" All registered tools · no inventory reading" ]
    | Some { Masc.Tui_decode_tools.ts_usage; _ } ->
    let registered_rows = Tool_tree.rows registered_tools in
    let surfaces_text (tool : Masc.Tui_decode_tools.tool_entry) =
      match tool.tl_surfaces with
      | [] -> Say.code Masc_tui_theme.Glyph.no_value
      | names -> Say.as_received (Terminal_text.single_line (String.concat ", " names))
    in
    (* The SURFACES column is as wide as its widest reading, so the layout is
       decided once the language is chosen. *)
    let catalog_rows language =
      let layout =
        Tool_table.catalog_layout ~language ~width:(Masc_tui_frame.inner_width ~cols)
          ~surfaces_cells:
            (List.fold_left
               (fun widest tool ->
                 max widest
                   (Masc_tui_message_layout.display_width (Say.render language (surfaces_text tool))))
               0 registered_tools)
      in
      (* A tool the server has no row for was not called; with no per-tool
         counts at all, nothing is known about any tool. *)
      let usage_of name =
        match ts_usage with
        | None -> Tool_table.Usage_unread
        | Some rows -> (
            match Masc.Tui_decode_tools.tool_usage_for rows ~name with
            | None -> Tool_table.Never_called
            | Some { Masc.Tui_decode_tools.tu_calls; tu_failures; tu_p95_ms; _ } ->
                Tool_table.Called
                  { calls = tu_calls; failures = tu_failures; p95_ms = tu_p95_ms })
      in
      let localized_domain name =
        match name with
        | "board" -> Say.both ~ko:"보드" ~en:"board"
        | "work" -> Say.both ~ko:"작업" ~en:"work"
        | "run" -> Say.both ~ko:"실행" ~en:"run"
        | "keeper ops" -> Say.both ~ko:"키퍼 운영" ~en:"keeper ops"
        | "keeper self" -> Say.both ~ko:"키퍼 자체" ~en:"keeper self"
        | "system" -> Say.both ~ko:"시스템" ~en:"system"
        | "unsorted" -> Say.both ~ko:"미분류" ~en:"unsorted"
        | other -> Say.as_received (Terminal_text.single_line other)
      in
      let count = List.length registered_tools in
      [ Row (Ansi.bold,
             Say.per_language (function
               | Say.Ko -> Printf.sprintf " 전체 등록 도구 · %d개" count
               | Say.En -> Printf.sprintf " All registered tools · %s"
                   (Masc_tui_message_layout.count_noun count "tool")));
        Row (Theme.recede (), Tool_table.catalog_tool_header layout) ]
      @ List.map
          (function
            | Tool_tree.Domain { name; count } ->
                Row ( Ansi.bold,
                  Say.code " " ++ localized_domain name
                  ++ Say.code (Printf.sprintf " (%d) %s" count tool_domain_rule) )
            | Tool_tree.Family { name; count } ->
                Row (Ansi.bold,
                  Say.code "    " ++ Say.as_received (Terminal_text.single_line name)
                  ++ Say.code (Printf.sprintf " (%d)" count))
            | Tool_tree.Tool tool ->
                (* The name is what an operator scans a hundred rows for, so it
                   keeps the terminal's own weight and the two columns that
                   answer about it are dimmed behind it. Dimming the whole row --
                   as this did -- left the headings above in bold and every tool
                   name on the screen as the faintest thing on it.

                   A tool on no surface is unreachable, and [Surfaces] is the
                   column that says so, so the warning starts there instead of
                   recolouring the name, which is not itself the problem. *)
                let metadata =
                  if tool.tl_surfaces = [] then (Theme.warn ()) else (Theme.recede ())
                in
                Row ( "",
                  Tool_table.catalog_tool_line layout ~metadata
                    ~name:(Terminal_text.single_line (Masc.Tool_display.list_label tool.tl_name))
                    ~direct:(if tool.tl_direct_call
                             then Say.both ~ko:"예" ~en:"yes" else Say.both ~ko:"아니오" ~en:"no")
                    ~usage:(usage_of tool.tl_name)
                    ~surfaces:(surfaces_text tool) ))
          registered_rows
    in
    [ Laid_out (fun language -> draw language (catalog_rows language)) ]
    end
  in
  let usage_matrix_lines =
    lazy begin
    let usage_title = Say.both ~ko:" Skill 사용 집계" ~en:" Skill Usage" in
    let error_lines =
      match state.skills_catalog_error with
      | None -> []
      | Some error ->
          [ Theme.bad (), Say.code " "
              ++ Say.of_ko_flag (fun ~ko -> Terminal_text.single_line
                   (request_failure_text ~ko ~request:Kept_request.Skill_catalog_read error)) ]
          @ (match state.skills_catalog with
             | None -> []
             | Some _ -> [ Theme.warn (), Say.both ~ko:" 이전 catalog 조회 결과 유지" ~en:" Previous catalog reading retained" ])
    in
    let reading_lines =
    match state.skills_catalog with
    | None ->
        rows
          [ (Theme.recede ()),
            usage_title
            ++ (match state.skills_catalog_error with
                | None -> Say.both ~ko:" · 작업 공간 catalog 조회 없음" ~en:" · no workspace catalog reading"
                | Some _ -> Say.both ~ko:" · 조회 불가 (catalog 조회 없음)" ~en:" · unavailable (no catalog reading)") ]
    | Some { Masc.Tui_decode_tools.sc_state; _ }
      when sc_state <> Masc.Tui_decode_tools.Skills_ready ->
        let state_label =
          match sc_state with
          | Masc.Tui_decode_tools.Skills_ready -> Say.both ~ko:"준비됨" ~en:"ready"
          | Masc.Tui_decode_tools.Skills_not_registered ->
              Say.both ~ko:"미등록" ~en:"not registered"
          | Masc.Tui_decode_tools.Skills_uninitialized ->
              Say.both ~ko:"초기화 전" ~en:"uninitialized"
          | Masc.Tui_decode_tools.Skills_invalid_workspace ->
              Say.both ~ko:"잘못된 작업 공간" ~en:"invalid workspace"
        in
        rows
          [ Theme.recede (),
            usage_title ++ Say.both ~ko:" · 카탈로그 " ~en:" · catalog " ++ state_label ]
    | Some
        { Masc.Tui_decode_tools.sc_surfaces
        ; sc_rejections
        ; sc_shadows
        ; sc_sources
        ; sc_config
        ; _
        }
      ->
        let surface_name (surface : Masc.Tui_decode_tools.skills_catalog_surface) =
          Skill_reference.(surface.scs_reference.identity.name)
        in
        let total_surfaces = List.length sc_surfaces in
        let heading = card ~cols (rows
          [ Ansi.bold ^ Theme.section_heading (),
            Say.per_language (function
              | Say.Ko -> Printf.sprintf "Skill 카탈로그 · %d개 등록" total_surfaces
              | Say.En -> Printf.sprintf "Skills Catalog · %d registered" total_surfaces)
          ])
        in
        let surface_kind_label kind =
          match String.lowercase_ascii kind with
          | "instruction" -> Say.both ~ko:"지침" ~en:"instruction"
          | "composition" -> Say.both ~ko:"컴포지션" ~en:"composition"
          | _ -> Say.as_received (Terminal_text.single_line kind)
        in
        let surface_cards = List.map
          (fun (surface : Masc.Tui_decode_tools.skills_catalog_surface) ->
            let flow_rows = match surface.scs_flow with
              | None -> []
              | Some flow ->
                  (match skill_flow_line flow with
                   | None -> [] | Some line -> [Theme.recede (), line])
                  @ skill_flow_detail_lines flow in
            card ~cols
              (rows
                 ([ Ansi.bold, Say.as_received (Terminal_text.single_line (surface_name surface))
                      ++ Say.code "  " ++ surface_kind_label surface.scs_kind
                  ]
                  @ flow_rows))) sc_surfaces
        in
        let rejection_rows =
          match sc_rejections with
          | [] -> []
          | rejections ->
            ( Ansi.bold,
              Say.per_language (function
                | Say.Ko -> Printf.sprintf " 거부된 Skill 출처 · %d" (List.length rejections)
                | Say.En -> Printf.sprintf " Rejected Skill Sources · %d" (List.length rejections)) )
            :: List.concat_map
                 (fun (rejection : Masc.Tui_decode_tools.skill_catalog_rejection) ->
                    let source =
                      Say.as_received (Terminal_text.single_line (rejection.scr_source_id ^ "/"))
                      ++ (match rejection.scr_package_id with
                          | Some package -> Say.as_received (Terminal_text.single_line package)
                          | None -> Say.both ~ko:"(잘못된 package)" ~en:"(invalid package)")
                    in
                    let revision =
                      match rejection.scr_content_revision with
                      | Some revision -> Say.as_received (Terminal_text.single_line revision)
                      (* The field is required and nullable: null is the
                         catalog saying the rejection has no revision. *)
                      | None -> Say.code Masc_tui_theme.Glyph.no_value
                    in
                    (* The catalog's own diagnostic codes, which the reader
                       matches against the catalog's log. *)
                    let diagnostics =
                      match rejection.scr_reason with
                      | Masc.Tui_decode_tools.Skill_document_rejected diagnostics ->
                        List.map
                          (fun (diagnostic : Masc.Tui_decode_tools.skill_rejection_diagnostic) ->
                             ( Theme.warn (),
                               Say.code (Printf.sprintf "     %s: "
                                 (Masc.Tui_decode_tools.skill_diagnostic_code_to_string
                                    diagnostic.srd_diagnostic))
                               ++ Say.as_received (Terminal_text.single_line diagnostic.srd_message) ))
                          diagnostics
                      | Masc.Tui_decode_tools.Skill_document_unreadable ->
                        [ Theme.warn (), Say.code "     document_unreadable" ]
                      | Masc.Tui_decode_tools.Skill_exact_identity_duplicate ->
                        [ Theme.warn (), Say.code "     exact_identity_duplicate" ]
                      | Masc.Tui_decode_tools.Skill_invalid_package_id ->
                        [ Theme.warn (), Say.code "     invalid_package_id" ]
                    in
                    ( Theme.warn (), Say.code "   " ++ source ++ say_dot ++ revision )
                    :: diagnostics)
                 rejections
        in
        (* A Skill name two catalog entries declare. The first in catalog order
           wins (Skill_catalog_snapshot.effective_projection); the other is
           published but listed to no Keeper turn by that name, and this list
           is where an operator sees it. The name leads, the shadowed package
           follows it, and the winner stands on its own line so a narrow pane
           cuts neither package. *)
        let shadow_rows =
          let identity_text identity =
            Skill_reference.identity_source_id_to_string identity
            ^ "/"
            ^ Skill_reference.identity_package_id_to_string identity
          in
          match sc_shadows with
          | [] -> []
          | shadows ->
            ( Ansi.bold,
              Say.per_language (function
                | Say.Ko -> Printf.sprintf " 가려진 Skill · %d" (List.length shadows)
                | Say.En -> Printf.sprintf " Shadowed Skills · %d" (List.length shadows)) )
            :: List.concat_map
                 (fun (shadow : Masc.Tui_decode_tools.skill_catalog_shadow) ->
                    [ ( Theme.warn (),
                        Say.code "   "
                        ++ Say.as_received (Terminal_text.single_line shadow.scsh_shadowed.Skill_reference.name)
                        ++ say_dot
                        ++ Say.as_received (Terminal_text.single_line (identity_text shadow.scsh_shadowed)) )
                    ; ( (Theme.recede ()),
                        Say.both ~ko:"     가린 것: " ~en:"     shadowed by "
                        ++ Say.as_received (Terminal_text.single_line (identity_text shadow.scsh_winner)) )
                    ])
                 shadows
        in
        heading :: surface_cards
        @ rows (skill_source_lines ~cols ~config:sc_config ~sources:sc_sources
                @ rejection_rows @ shadow_rows)
    in
    rows error_lines @ reading_lines
    end
  in
  (* One section at a time. These used to be concatenated, and the first of
     them is one row per tool -- ninety-five of them on this workspace -- so
     the other four started past row 120 of a list a terminal shows twenty of.
     They were not missing; they were behind a section that never ends, with
     nothing saying so. *)
  let pane_lines =
    match state.tools_pane with
    | Masc_tui_types.Tools_surface -> Lazy.force effective_lines
    | Masc_tui_types.Tools_async -> async_request_observation_lines ~cols state
    | Masc_tui_types.Tools_usage -> Lazy.force usage_matrix_lines
    | Masc_tui_types.Tools_catalog Tools_catalog_list -> Lazy.force catalog_lines
    | Masc_tui_types.Tools_catalog (Tools_catalog_volumes _) -> volume_gc_lines state
    | Masc_tui_types.Tools_storage -> storage_lines state
  in
  (* Each pane follows its own independent read. Retained rows are still
     useful during refresh; neither unread nor failed means a successful zero. *)
  let part, source, observed, error = match state.tools_pane with
    | Tools_surface | Tools_storage
    | Tools_catalog (Tools_catalog_list | Tools_catalog_volumes _) ->
        Tools_inventory_read, Say.both ~ko:"도구 목록" ~en:"tool inventory",
        Option.is_some state.tools_inventory, (selected_tools_error state)
    | Tools_usage ->
        Tools_catalog_read, Say.both ~ko:"Skill catalog" ~en:"Skills catalog",
        Option.is_some state.skills_catalog, state.skills_catalog_error
    | Tools_async ->
        Tools_async_read, Say.both ~ko:"async broker" ~en:"async broker",
        Option.is_some state.tools_async_observation, state.tools_async_observation_error
  in
  let reads_this_pane pending = pending = part in
  let pending =
    if state.tools_pane = Tools_async then state.tools_async_observation_inflight
    else
      List.exists reads_this_pane state.tools_skill_pending
      || (match state.tools_read_inflight with
          | Some request
            when request.tri_generation = state.tools_request_generation
                 && Option.equal String.equal request.tri_keeper
                      (Option.map (fun (row : keeper) -> row.k_name) (selected_keeper state)) ->
              List.exists reads_this_pane request.tri_pending
          | Some _ | None -> false)
  in
  let now = Unix.gettimeofday () in
  let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way ^ " " in
  let hide_reading = state.tools_pane = Tools_async && state.tools_async_detail_open in
  let pane_tag =
    match state.tools_pane with
    | Tools_surface -> "surface"
    | Tools_async -> "async"
    | Tools_usage -> "usage"
    | Tools_catalog (Tools_catalog_list | Tools_catalog_volumes _) -> "catalog"
    | Tools_storage -> "storage"
  in
  let reading_started =
    Masc_tui_types.progress_clock_option state ~slot:"tools-reading" ~now
      (if pending && not hide_reading then
         Some (pane_tag ^ ":" ^ string_of_int state.tools_request_generation)
       else None)
  in
  let elapsed_suffix =
    if hide_reading then Say.empty
    else
      match reading_started with
      | None -> Say.empty
      | Some at ->
          let d = Masc_tui_value.Ongoing.since ~now at in
          Say.both ~ko:(" · " ^ d ^ " 경과") ~en:(" · " ^ d)
  in
  (* Only a first read has a line of its own. A read over a held reading says
     nothing here, and a retry over a failure keeps the line the failure has:
     the reading slot says the read (RFC tui-one-screen-grammar section 8). *)
  let reading_lines = if hide_reading then [] else match pending, observed, error with
    | true, false, None ->
        [ Theme.info (), Say.code (" " ^ under_way) ++ source
                         ++ Say.both ~ko:" 읽는 중" ~en:" · reading"
                         ++ elapsed_suffix ]
    | (true | false), true, Some _ ->
        [ Theme.warn (), Say.code " " ++ source
                         ++ Say.both ~ko:" 마지막 조회 유지 · r:새로 읽기" ~en:" · last reading retained · r:refresh" ]
    | false, false, None ->
        [ (Theme.recede ()), Say.code " " ++ source ++ Say.both ~ko:" 안 읽음 · r:새로 읽기" ~en:" not read · r:refresh" ]
    | (true | false), true, None | (true | false), false, Some _ -> []
  in
  let error_lines = match (selected_tools_error state) with
    | None -> []
    | Some (Request_failed detail) ->
      [Theme.bad (), Say.both ~ko:"도구 조회 실패: " ~en:"Tools read failed: "
                     ++ Say.as_received (Terminal_text.single_line detail)]
    | Some (Request_withdrawn refusal) ->
        [Theme.bad (), refusal_text ~request:Kept_request.Tool_inventory_read refusal]
  in
  let width = max 1 (Masc_tui_frame.inner_width ~cols) in
  (* The one place this screen's rows take a language. *)
  let wrap pieces = List.concat_map (fun ((style, text), mark) ->
       (* Fitted tables and usage cards already own their alignment. Only
          overlong rows need physical wrapping; never render metadata as
          Markdown or shorten its identities to fit the frame. Every row a
          wrapped marked row becomes keeps the mark, so its run is whole, and
          every row keeps the instant its time text changes at. *)
       if Masc_tui_message_layout.display_width text <= width then [ (style, text), mark ]
       else
         let splitter =
           if String.equal style "" then Masc_tui_message_layout.wrap_styled_words
           else Masc_tui_message_layout.wrap_words
         in
         splitter ~max_cells:width text
         |> List.map (fun line -> (style, line), mark))
       (draw_marked language pieces) in
  let drafts = List.map (fun draft ->
      Theme.warn (),
      Say.both ~ko:" 게시 안 한 " ~en:" Unpublished "
      ++ Say.code (if draft.scd_composition then "Composition" else "Instruction")
      ++ Say.both ~ko:" 초안 보관 중: " ~en:" draft retained for "
      ++ Say.as_received (Terminal_text.single_line draft.scd_source_id)
      ++ say_dot ++ Say.code (if draft.scd_composition then "C" else "c")
      ++ Say.both ~ko:": 편집기에서 이어 쓰기" ~en:":resume in editor")
    (skill_create_drafts_for_current_workspace state) in
  let notices = rows (drafts @ reading_lines @ error_lines) in
  (* The selection's document stands above the list, so on a pane whose list
     the move keys walk it takes as many rows for every selection: as many as
     the tallest document among the loaded entries, a shorter one ending in
     blank rows (RFC tui-one-screen-grammar §8). Sized by the selected
     entry alone, the list moved a row with j and k wherever the next
     entry's source or requester wrapped differently, and a page counted in
     one frame was a row off in the frame the key landed in, so PgDn and
     PgUp pushed the entry read last off the window (§3.1). The document is
     an identity and is never cut, so no cap applies: it is as tall as it
     wraps. *)
  let selection_rows =
    let shown = wrap (tools_selection_document ~cols state) in
    match selections state with
    | None -> shown
    | Some loaded ->
        let tallest =
          max (List.length shown)
            (tallest_selection_rows ~cols ~language
               ~rows_of:(fun document -> List.length (wrap document)) state loaded)
        in
        shown @ List.init (tallest - List.length shown) (fun _ -> ("", ""), Unmarked)
  in
  (* Where each entry of the pane's list is in the page, in order, from the
     page wrapped one piece at a time, so no row is wrapped twice. *)
  let entry_spans ~above wrapped =
    List.fold_left
      (fun (row, spans) (piece, rows) ->
         let next = row + List.length rows in
         match piece with
         | List_entry _ -> next, { first_row = row; last_row = next - 1 } :: spans
         | Row _ | Cursor _ | Timed _ | Laid_out _ | Measurement_card _ -> next, spans)
      (above, []) wrapped
    |> snd |> List.rev
  in
  let marked, entry_rows =
    if Option.is_some (tools_volume_gc_parent_scroll state.tools_pane) then
      wrap (pane_lines @ rows (reading_lines @ error_lines)), []
    else if state.tools_pane = Tools_storage then
      (* No Skill is selected here, so the Skill heading stays out. *)
      wrap (rows (reading_lines @ error_lines) @ pane_lines), []
    else if state.tools_pane=Tools_async && state.tools_async_detail_open && Option.is_some state.tools_async_task_source then
      selection_rows @ wrap notices @ draw_marked language pane_lines, []
    else
      (* A row wraps by its own width alone, so a piece takes as many rows
         wrapped by itself as among the rows around it. *)
      let wrapped = List.map (fun piece -> piece, wrap [ piece ]) (notices @ pane_lines) in
      ( selection_rows @ List.concat_map snd wrapped
      , entry_spans ~above:(List.length selection_rows) wrapped )
  in
  let entries =
    let listed list = match entry_rows with [] -> None | spans -> Some (list, spans) in
    match state.tools_pane with
    | Tools_surface -> listed Skill_entries
    | Tools_async -> listed Async_request_entries
    | Tools_usage | Tools_storage | Tools_catalog _ -> None
  in
  (* The first and the last row [in_run] picks. The [Cursor] pieces are the
     adjacent rows of one Skill and the card is one piece, so each run is
     whole. *)
  let span in_run =
    List.fold_left
      (fun (index, span) (_, mark) ->
         let span =
           match in_run mark, span with
           | false, _ -> span
           | true, None -> Some { first_row = index; last_row = index }
           | true, Some rows -> Some { rows with last_row = index }
         in
         index + 1, span)
      (0, None) marked
    |> snd
  in
  { lines = List.map fst marked
  ; cursor = span (function Entry -> true | Unmarked | Card | Changes_at _ -> false)
  ; card = span (function Card -> true | Unmarked | Entry | Changes_at _ -> false)
  ; row_changes =
      List.concat
        (List.mapi
           (fun index (_, mark) ->
             match mark with
             | Changes_at at -> [ (index, at) ]
             | Unmarked | Entry | Card -> [])
           marked)
  ; entries
  }
;;

let drawn_change display window =
  List.fold_left
    (fun earliest (index, at) ->
      match Masc_tui_rows.at window index, earliest with
      | None, _ -> earliest
      | Some _, None -> Some at
      | Some _, Some sooner -> Some (Float.min sooner at))
    None display.row_changes

let tools_display_lines ?cols ?terminal_rows state = (tools_display ?cols ?terminal_rows state).lines

(* A Skill or a request can wrap, so a page counts the entries the window
   holds whole wherever it stands, as the cursor counts entries. The first
   entry takes every row of the page above it too, since the window brings
   the top of the page in with it (Home); a page counted without them let
   PgUp onto the first entry push the entry read first off the window. *)
let drawn_page display ~rows =
  let heights = function
    | [] -> []
    | first :: rest ->
        (first.last_row + 1) :: List.map (fun entry -> entry.last_row - entry.first_row + 1) rest
  in
  Option.map
    (fun (list, spans) -> list, Masc_tui_scroll.items_always_shown ~heights:(heights spans) ~rows)
    display.entries

type landing = { entry : cursor_rows; lead : int }

(* Where the selected Skill is drawn on the Available pane: the rows its
   entry takes there, every row of it when it wraps ([cursor]), and the
   lines above it that belong with it. The group heading above it is not
   part of the entry, so the lead brings it in.

   The first Skill brings everything above it, so Home shows the top of the
   page. A Skill that opens its group brings the group heading, which the
   renderer draws above the first Skill of each kind. *)
let skill_landing (state : state) display =
  Option.map (fun entry ->
      let instruction (profile : Masc.Tui_decode_tools.effective_skill_profile) =
        match profile.esp_io with
        | Model_orchestrated -> true
        | Composition_io _ -> false
      in
      let profiles = tools_skill_profiles state in
      let cursor =
        clamped_tools_skill_cursor ~count:(List.length profiles) state.tools_skill_cursor
      in
      let lead =
        if cursor <= 0 then entry.first_row
        else
          match List.nth_opt profiles (cursor - 1), List.nth_opt profiles cursor with
          | Some previous, Some selected
            when not (Bool.equal (instruction previous) (instruction selected)) -> 1
          | Some _, Some _ | Some _, None | None, Some _ | None, None -> 0
      in
      { entry; lead })
    display.cursor

(* Where the selected async request is drawn: the rows its entry takes in
   the page. The first request brings everything above it, as the first
   Skill does. *)
let request_landing (state : state) display =
  match display.entries, state.tools_async_selection with
  | Some (_, spans), Some selected ->
      Option.bind
        (List.find_index (Masc.Tui_decode_async_request.equal_target selected)
           (tools_async_targets state))
        (fun index ->
          Option.map
            (fun entry -> { entry; lead = (if index = 0 then entry.first_row else 0) })
            (List.nth_opt spans index))
  | Some _, None | None, (Some _ | None) -> None

(* The window over a landing, the way [row_list]'s [follow] works for a row
   cursor: the last line first, then the first with its lead, so a Skill or
   a request that wraps is on screen whole when it fits. *)
let follow landing ~height scroll =
  Masc_tui_scroll.ensure_visible_with_lead ~cursor:landing.entry.first_row ~lead:landing.lead
    ~height (Masc_tui_scroll.ensure_visible ~cursor:landing.entry.last_row ~height scroll)

let selected_skill_bottom_sheet ~cols ~height (state : state) =
  let width = Masc_tui_frame.inner_width ~cols in
  if state.tools_pane <> Tools_surface
     || Option.is_some state.tools_skill_source_picker
     || height < Masc_tui_card.min_height
     || width < Masc_tui_card.min_width
  then []
  else
    match selected_tools_skill_profile state with
    | None -> []
    | Some profile ->
        let ko = state.ui_language = Lang_ko in
        let say korean english = if ko then korean else english in
        let glyph, mode_word, mode_tone =
          match profile.esp_surface with
          | Masc.Keeper_skill_observability.Instruction_skill ->
              ( "\xe2\x97\x87" (* ◇ *)
              , say "지침 · 필요할 때" "instruction · on-demand"
              , Theme.series_tint Masc_tui_theme.Memory 0.8 )
        in
        let reference = profile.esp_reference in
        let src_id =
          Terminal_text.single_line
            (Skill_reference.identity_source_id_to_string reference.identity)
        in
        let pkg_id =
          Terminal_text.single_line
            (Skill_reference.identity_package_id_to_string reference.identity)
        in
        let rev =
          Masc_tui_value.Hash.short
            (Terminal_text.single_line
               (Skill_reference.content_revision_to_string reference.content_revision))
        in
        let load_reasons =
          match profile.esp_load_reasons with
          | [] -> say "직접 지정 없음" "unattributed"
          | reasons ->
              reasons
              |> List.map (function
                   | Masc.Tui_decode_tools.Skill_catalog_default ->
                       say "기본 카탈로그" "catalog default"
                   | Masc.Tui_decode_tools.Skill_keeper_profile ->
                       say "Keeper 프로필" "Keeper profile"
                   | Masc.Tui_decode_tools.Skill_task task_id ->
                       "Task " ^ Terminal_text.single_line task_id)
              |> String.concat " · "
        in
        let plan_summary =
          match profile.esp_surface with
          | Masc.Keeper_skill_observability.Instruction_skill ->
              Printf.sprintf "discovery=%dB · body=%dB"
                profile.esp_discovery_bytes profile.esp_body_bytes
        in
        let io_summary =
          match profile.esp_io with
          | Masc.Tui_decode_tools.Model_orchestrated ->
              say "모델 자율 선택 (지침 본문 온디맨드)" "model-orchestrated (on-demand body)"
          | Masc.Tui_decode_tools.Composition_io { exports; _ } ->
              Printf.sprintf
                (if ko then "고정 실행 그래프 · exports %d개"
                 else "fixed composition graph · %d export(s)")
                (List.length exports)
        in
        let fields =
          [ Masc_tui_doc.kv ~tone:mode_tone
              (say "실행 방식" "Execution") (glyph ^ " " ^ mode_word)
          ; Masc_tui_doc.kv (say "호출 구조" "Shape") io_summary
          ; Masc_tui_doc.kv (say "규모 · 맥락" "Plan / Bytes") plan_summary
          ; Masc_tui_doc.kv (say "출처 · 패키지" "Source / Pkg")
              (Printf.sprintf "%s / %s @ %s" src_id pkg_id rev)
          ; Masc_tui_doc.kv (say "불러온 이유" "Load reason") load_reasons
          ]
        in
        let preview_indent = 1 in
        let preview_cells = max 1 (width - preview_indent) in
        Masc_tui_doc.docked_preview ~width ~height ~indent:preview_indent
          ~eyebrow:(say "선택한 Skill" "Selected Skill")
          ~title:(Terminal_text.single_line profile.esp_name)
          ~meta:(glyph ^ " " ^ mode_word)
          ~footer_hints:
            [ { Masc_tui_card.key = "Enter"; label = say "실측" "evidence" }
            ; { key = "f"; label = say "조합" "comp" }
            ; { key = "1-6"; label = say "탭" "tabs" }
            ]
          (Masc_tui_doc.kv_rows ~width:preview_cells fields)
;;
