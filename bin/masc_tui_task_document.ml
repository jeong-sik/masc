open Masc_tui_ansi
module Tui_decode = Masc.Tui_decode
module Message_layout = Masc_tui_message_layout
module Planning_detail = Masc_tui_planning_detail

let status_tag_label ~ko (tag : Masc_domain.Task_status_tag.t) =
  let text korean english = if ko then korean else english in
  match tag with
  | Todo -> text "할 일" "Todo"
  | Claimed -> text "담당됨" "Claimed"
  | In_progress -> text "진행 중" "In progress"
  | Awaiting_verification -> text "검증 대기" "Awaiting verification"
  | Done -> text "완료" "Done"
  | Cancelled -> text "취소" "Cancelled"

let status_label ~ko status = status_tag_label ~ko (Masc_domain.task_status_tag status)

(* A Task opened from its Goal reads like the Goal: the same section title
   style (info colour, bold) and the same receded rows for where a fact came
   from ([Masc_tui_render_work.planning_detail_tone]). A style goes on a row
   after the row is wrapped. The wrapper neutralises every escape sequence in
   what it is given, so a style put on first would be spelled out on screen. *)
let heading_style () = Theme.info () ^ Ansi.bold
let provenance_style = Ansi.dim

let paint style row =
  if String.equal style "" then row else style ^ row ^ Ansi.reset

let section_rows ~width title =
  Masc_tui_text_block.rows ~max_cells:width ("[ " ^ title ^ " ]")
  |> List.map (fun line -> "  " ^ paint (heading_style ()) line)

let history_heading_rows ~ko ~width = section_rows ~width (if ko then "상태 기록" else "History")

(* The colours the chat gives a served JSON document, out of the reader's own
   theme. A note's colours are chosen when its rows are prepared, like the
   Body's headings. *)
let document_palette () : Masc_tui_tool_detail.palette =
  { Masc_tui_tool_detail.plain with
    key = Theme.Syntax.json_key ()
  ; string_ = Theme.Syntax.string ()
  ; number = Theme.Syntax.json_number ()
  ; literal = Theme.Syntax.json_literal ()
  ; punctuation = Theme.Syntax.json_punctuation
  ; reset = Ansi.reset
  }

(* A note that is a JSON object or array is drawn as the chat draws one, with
   its keys, strings, numbers and literals in their own colours. Any other
   note is prose and keeps the one colour. A block is lines drawn together, so
   a blank line inside a note stays between its neighbours and only the blank
   lines at the block's edges go. [Document_block] already carries its colour
   and is safe to draw; [Plain_block] is neither. *)
type history_block =
  | Plain_block of string
  | Document_block of string

(* The indent of a note under the event that owns it. Every line of the note
   takes it, not only the first. *)
let note_indent = "      "

let indented block =
  String.split_on_char '\n' block
  |> List.map (fun line -> note_indent ^ line)
  |> String.concat "\n"

let history_blocks ~ko =
  let text korean english = if ko then korean else english in function
        | [] -> [ Plain_block (text "    (조회한 범위에 기록 없음)" "    (no events in the observed prefix)") ]
        | events ->
            let palette = document_palette () in
            List.concat_map
              (fun (event : Tui_decode.task_history_event) ->
                let transition =
                  match event.Tui_decode.th_from_status, event.th_to_status with
                  | Some from_status, Some to_status ->
                      Printf.sprintf "  %s -> %s" from_status to_status
                  | Some from_status, None -> (text "  이전 " "  from ") ^ from_status
                  | None, Some to_status -> "  -> " ^ to_status
                  | None, None -> ""
                in
                let actor =
                  match event.th_actor with
                  | Some actor -> (text "  주체 " "  by ") ^ actor
                  | None -> ""
                in
                let provenance=match event.th_origin with
                  | None -> ""
                  | Some origin -> Printf.sprintf " [%s · %s:%d]"
                    (match origin.tho_source with Tui_decode.Task_activity -> "lifecycle" | Tui_decode.Task_audit -> "audit")
                    origin.tho_file origin.tho_offset in
                Plain_block
                  (Printf.sprintf "    %s  %s%s%s%s"
                     (Planning_detail.short_ts event.th_ts)
                     event.th_label transition actor provenance)
                :: (match event.th_note with
                    | Some note ->
                        (match Masc_tui_tool_detail.document ~palette note with
                         | Some document -> [ Document_block (indented document) ]
                         | None -> [ Plain_block (indented note) ])
                    | None -> []))
              events

let history_status_lines ~ko ~width ~(view : Masc.Tui_decode_task_inspection.history Masc_tui_fetched.view) ~in_flight ~continuing =
  let text korean english = if ko then korean else english in
  let rows =
    match view with
    | Masc_tui_fetched.Ready _ -> []
    | Masc_tui_fetched.Stale (_, detail) ->
        Masc_tui_text_block.rows ~max_cells:width
          ((text "    기록 조회 실패 · 이전 관측: " "    history read failed; previous observation: ") ^ Terminal_text.single_line detail)
    | Masc_tui_fetched.Failed detail -> Masc_tui_text_block.rows ~max_cells:width
        ((text "    조회 실패: " "    load failed: ") ^ Terminal_text.single_line detail)
    | Masc_tui_fetched.Absent -> [ (text "    기록 미조회" "    history not requested") ]
    | Masc_tui_fetched.Loading -> [ (text "    조회 중" "    loading...") ]
  in
  let pending =
    if not in_flight then []
    else match view with
      | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _ ->
          [ if continuing then (text "    이전 기록 조회 중 · 조회한 범위 표시" "    reading earlier history; showing observed prefix")
            else (text "    기록 조회 중 · 이전 관측" "    reading history; previous observation") ]
      | Masc_tui_fetched.Failed _ -> [ (text "    재조회 중 · 이전 실패 유지" "    retrying; previous failure remains") ]
      | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading -> [] in
  let boundary=match Masc_tui_fetched.value view with
    | None -> []
    | Some history -> [match history.history_next_cursor with
        | Some _ when in_flight && continuing -> (text "    r:최신 기록 조회" "    r:start a fresh prefix")
        | Some _ -> (text "    H:이전 기록 조회 · r:최신 기록 조회" "    H:read earlier stored history · r:start a fresh prefix")
        | None -> (text "    조회 범위 끝 · r:최신 기록 조회" "    observed stored prefix exhausted · r:read latest history")] in
  let sources=match Masc_tui_fetched.value view with
    | None -> []
    | Some history -> List.map (fun (source,state) ->
      "    " ^ (match source with Tui_decode.Task_activity -> (text "상태 전환" "Lifecycle") | Tui_decode.Task_audit -> (text "감사 기록" "Audit"))
      ^ (match state with Masc.Tui_decode_task_inspection.Source_observed -> (text ": 조회한 저장 범위" ": observed stored prefix")
        | Masc.Tui_decode_task_inspection.Source_not_created -> (text ": 저장소 미생성 · 관측 없음" ": store not yet created; no observations available"))) history.history_sources in
  pending @ rows @ sources @ boundary

let body_lines ~ko ~cols ~goal_lines (task : Masc_domain.task) =
  let text korean english = if ko then korean else english in
  let width = max 1 (framed_inner_width cols - 2) in
  let field ?(style = "") korean english value =
    let label = text korean english in
    let prefix = "  " ^ label ^ ": " in
    let cells = Message_layout.display_width prefix in
    (if cells < framed_inner_width cols then
       Masc_tui_text_block.rows ~max_cells:(framed_inner_width cols - cells) value
       |> List.mapi (fun index line ->
         (if index = 0 then prefix else String.make cells ' ') ^ line)
     else (Message_layout.wrap_words ~max_cells:width label |> List.map ((^) "  "))
       @ (Masc_tui_text_block.rows ~max_cells:width value |> List.map ((^) "  ")))
    |> List.map (paint style) in
  let optional ?style ko en = function None -> [] | Some value -> field ?style ko en value in
  let many ko en values = List.concat_map (field ko en) values in
  let quiet ko en value = field ~style:provenance_style ko en value in
  let heading ko en = section_rows ~width (text ko en) in
  let status value = field ~style:(task_state_style task.task_status) "상태" "Status" value in
  let label = status_label ~ko task.task_status in
  let state, times = match task.task_status with
    | Masc_domain.Todo -> status (label ^ text " · 미배정" " · unassigned"), []
    | Claimed {assignee; claimed_at} ->
      status label @ field "담당" "Owner" assignee,
      quiet "담당 시각" "Claimed" claimed_at
    | InProgress {assignee; started_at} ->
      status label @ field "담당" "Owner" assignee,
      quiet "시작" "Started" started_at
    | AwaitingVerification {assignee; started_at; submitted_at; verification_id} ->
      status label @ field "담당" "Owner" assignee
      @ field "검증 요청" "Verification" verification_id,
      quiet "시작" "Started" started_at @ quiet "제출" "Submitted" submitted_at
    | Done {assignee; completed_at; notes} ->
      status label @ field "담당" "Owner" assignee @ optional "메모" "Notes" notes,
      quiet "완료 시각" "Completed" completed_at
    | Cancelled {cancelled_by; cancelled_at; reason} ->
      status label @ field "취소한 주체" "Cancelled by" cancelled_by
      @ optional "사유" "Reason" reason,
      quiet "취소 시각" "Cancelled" cancelled_at in
  let request = heading "요청과 상태" "Request and status"
    @ field "제목" "Title" task.title @ state
    @ (if String.equal task.description "" then [] else field "요청" "Request" task.description)
    @ many "대상 파일" "File" task.files in
  let evidence = (match task.handoff_context with
    | None -> []
    | Some handoff -> optional "사유" "Reason" handoff.reason
      @ (if String.equal handoff.summary "" then [] else field "인수인계" "Handoff" handoff.summary)
      @ optional "다음 행동" "Next" handoff.next_step
      @ optional "실패" "Failure" handoff.failure_mode
      @ many "근거" "Evidence" handoff.evidence_refs)
    @ (match task.contract with
      | None -> []
      | Some contract -> many "완료 조건" "Done when" contract.completion_contract
        @ many "필요한 근거" "Required evidence" contract.required_evidence
        @ many "점검 근거" "Inspection evidence" contract.inspect_gate_evidence
        @ many "검증 근거" "Verification evidence" contract.verify_gate_evidence) in
  let metadata = quiet "작업 ID" "Task ID" task.id @ times
    @ quiet "생성" "Created" task.created_at
    @ quiet "생성한 주체" "Creator" (Option.value task.created_by ~default:Masc_tui_theme.Glyph.no_value)
    @ quiet "우선순위" "Priority" (string_of_int task.priority)
    @ quiet "작업 회차" "Cycles" (string_of_int task.cycle_count)
    @ optional ~style:provenance_style "이전 작업" "Predecessor" task.predecessor_task_id
    @ optional ~style:provenance_style "실행 ID" "Operation" task.execution_links.operation_id
    @ optional ~style:provenance_style "세션 ID" "Session" task.execution_links.session_id
    @ (List.concat_map (fun skill -> quiet "스킬" "Skill"
        (Yojson.Safe.to_string (Skill_reference.to_yojson skill))) task.skills)
    @ (match task.handoff_context with None -> [] | Some handoff ->
        optional ~style:provenance_style "인수인계 갱신" "Handoff updated" handoff.updated_at
        @ optional ~style:provenance_style "갱신한 주체" "Handoff updater" handoff.updated_by) in
  request
  @ (if evidence = [] then [] else [""] @ heading "완료 조건과 근거" "Completion and evidence" @ evidence)
  @ [""] @ heading "연결 목표" "Linked Goals" @ goal_lines
  @ [""] @ heading "상세 정보" "Details" @ metadata


type goals = Unread | Unavailable of string | Membership of string list | Canonical of string option
type part = Body | History
type input = Body_input of bool * int * goals * Masc_domain.task | History_input of bool * int * Tui_decode.task_history_event list
let body ~ko ~cols ~goals task = Body_input (ko,cols,goals,task)
let history ~ko ~cols events = History_input (ko,cols,events)
let part = function Body_input _ -> Body | History_input _ -> History
let columns = function Body_input (_,cols,_,_) | History_input (_,cols,_) -> cols
let is_korean = function Body_input (ko,_,_,_) | History_input (ko,_,_) -> ko
let equal_input a b = match a,b with
  | Body_input (ko,cols,goals,task),Body_input (other_ko,other_cols,other_goals,other_task) ->
      ko=other_ko && cols=other_cols && goals=other_goals && task==other_task
  | History_input (ko,cols,events),History_input (other_ko,other_cols,other_events) -> ko=other_ko && cols=other_cols && events==other_events
  | Body_input _,History_input _ | History_input _,Body_input _ -> false
let prepare_input = function
  | History_input (ko,cols,events) ->
      let max_cells = max 1 (framed_inner_width cols) in
      history_blocks ~ko events |> List.concat_map (function
        | Plain_block block -> Masc_tui_text_block.preformatted_rows ~max_cells block
        | Document_block block ->
            Masc_tui_text_block.preformatted_styled_rows ~max_cells block)
  | Body_input (ko,cols,goals,task) ->
      let text korean english = if ko then korean else english in
      let field ?(style = "") label text =
        let prefix="  " ^ label ^ ": " in
        let inner=max 1 (framed_inner_width cols) in
        let lead=Message_layout.display_width prefix in
        (if lead < inner then
          Masc_tui_text_block.rows ~max_cells:(inner-lead) text
          |> List.mapi (fun index line -> (if index=0 then prefix else String.make lead ' ') ^ line)
        else Masc_tui_text_block.rows ~max_cells:inner (prefix ^ text))
        |> List.map (paint style) in
      let goal_lines=match goals with
        | Unread -> field (text "목표" "Goal") (text "연결 미조회" "Links not read")
        | Unavailable detail -> field (text "목표" "Goal") (text "연결 조회 실패: " "Links unavailable: " ^ detail)
        | Membership [] -> field (text "목표" "Goal") (text "연결 없음" "No link")
        | Membership ids -> List.concat_map (fun id -> field (text "목표" "Goal") id
            @ field ~style:provenance_style (text "링크" "Link") (Masc_tui_link.reference Masc_tui_link.Goal id)) ids
        | Canonical goal -> field (text "기록된 목표" "Recorded Goal") (Option.fold ~none:(text "없음" "None") ~some:Fun.id goal) in
      body_lines ~ko ~cols ~goal_lines task

let prepare input = Message_layout.with_isolated_pieces_cache (fun () -> prepare_input input)
