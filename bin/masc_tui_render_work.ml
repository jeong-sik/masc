(** Work / Tasks, Planning (Goals) and Schedules screens. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim

module Frame_presenter = Masc_tui_frame_presenter
module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Render_schedule = Masc_tui_render_schedule
module Task_selection = Masc_tui_task_selection
module Overview_tasks = Masc_tui_overview_tasks
module Planning_detail = Masc_tui_planning_detail
module Planning_due = Masc_tui_planning_due
module Link = Masc_tui_link
module Press = Masc_tui_press
module Doc = Masc_tui_doc
module Card = Masc_tui_card
module Text_block = Masc_tui_text_block

let wrap_style style text =
  if String.equal style "" || String.equal style Ansi.reset || String.equal text ""
  then text
  else style ^ text ^ Ansi.reset

let task_status_mark (status : Masc_domain.task_status) =
  Masc_tui_value.Mark.glyph
    (match status with
     | Masc_domain.Todo -> Masc_tui_value.Mark.Waiting
     | Masc_domain.Claimed _ | Masc_domain.InProgress _ ->
         Masc_tui_value.Mark.Under_way
     | Masc_domain.AwaitingVerification _ -> Masc_tui_value.Mark.Caution
     | Masc_domain.Done _ -> Masc_tui_value.Mark.Settled
     | Masc_domain.Cancelled _ -> Masc_tui_value.Mark.Paused)

(* A moment the wire spells out as ISO-8601 text, drawn the way every other
   moment on these screens is: in the operator's zone, with only as much of
   the date as its distance from now needs. *)
let wire_moment (ts : string) =
  Terminal_text.single_line
    (Planning_detail.moment_text ~now:(Unix.gettimeofday ()) ts)

(* Board lives under Work. Both links use the existing destinations; the
   palette spelling also gives keyboard users a path without claiming [b],
   which already opens the Goal summary. This is one physical header row. *)
let work_hub_navigation (state : state) ~cols =
  let requests = ui_text state ~ko:"p:요청" ~en:"p:Requests" in
  let board = ui_text state ~ko:":게시판" ~en:":Board" in
  let links =
    if Message_layout.display_width ("  " ^ requests ^ "  " ^ board)
       <= framed_inner_width cols
    then
      Press.pressable (Press.Press_surface Approvals) requests ^ "  "
      ^ Press.pressable (Press.Press_surface Board) board
    else Press.pressable (Press.Press_surface Board) board
  in
  "  " ^ Theme.recede () ^ links ^ Ansi.reset

let goal_receipt_authority_current (state : state) (receipt : goal_action_receipt) =
  match receipt.gar_authority with
  | None -> true
  | Some authority ->
      let current_confirmation = match state.goal_confirmation with
        | Planning_detail.Inspecting read ->
          (match Planning_detail.confirmation_view_for read ~goal_id:receipt.gar_goal_id with
           | Ready confirmation -> Some confirmation
           | Absent | Loading | Stale _ | Failed _ -> None)
        | Planning_detail.Submitting _ -> None in
      let credential_current = state.workspace_identity = Workspace_identity_match
        && Masc_tui_http.credential_owner_is_current authority.ra_credential_owner in
      let current_instance = Option.bind state.server_identity (fun identity -> identity.sid_runtime_instance_id) in
      Planning_detail.receipt_authority_current ~credential_current ~current_instance
        ~current_confirmation ~receipt:authority

(* What a receipt says about its request. A request the workspace guard kept
   back never left, so its kept-back notice is drawn alone; any other outcome
   is the server's answer, qualified by whether the receipt's authority is
   still current. *)
let goal_receipt_answer (state : state) (receipt : goal_action_receipt) =
  let ko = state.ui_language = Lang_ko in
  let answer result =
    `Answer (Planning_detail.receipt_outcome_text ~ko
      ~current:(goal_receipt_authority_current state receipt) result) in
  match receipt.gar_result with
  | Error (Request_withdrawn refusal) ->
    `Kept_back (workspace_refusal_text ~ko ~request:Kept_request.Goal_transition refusal)
  | Error (Request_failed detail) -> answer (Error detail)
  | Ok message -> answer (Ok message)

let task_status_word state (status : Masc_domain.task_status) =
  Masc_tui_task_document.status_label ~ko:(state.ui_language = Lang_ko) status

type work_panels =
  { list_width : int
  ; preview_width : int
  ; list_rows : int
  ; preview_rows : int
  ; arrangement : [ `Beside | `Plain ]
  }

(* Narrow screens reserve a short preview and spend the remaining rows on
   list entries. Paging and drawing use this same geometry. *)
let work_panels ~inner ~rows =
  let inner = max 1 inner and rows = max 0 rows in
  let list_floor = 44 and preview_floor = 36 and gap = 2 in
  if inner >= list_floor + preview_floor + gap && rows >= 4 then
    let list_width = min (inner - gap - preview_floor)
        (max list_floor ((inner - gap) * 3 / 5)) in
    { list_width = list_width - 4
    ; preview_width = inner - gap - list_width - 4
    ; list_rows = rows - 2; preview_rows = rows - 2; arrangement = `Beside }
  else
    let preview_rows = min 5 (rows / 3) in
    let separator_rows = if preview_rows > 0 then 1 else 0 in
    { list_width = inner; preview_width = inner
    ; list_rows = rows - preview_rows - separator_rows
    ; preview_rows; arrangement = `Plain }

let work_panel_lines geometry ~list_title ~list_lines ~preview_title ~preview_lines =
  let fill height lines =
    let shown = List.take height lines in
    shown @ List.init (max 0 (height - List.length shown)) (fun _ -> "") in
  let left = fill geometry.list_rows list_lines
  and right = fill geometry.preview_rows preview_lines in
  match geometry.arrangement with
  | `Plain -> if geometry.preview_rows = 0 then left else left @ ("" :: right)
  | `Beside ->
      let left = studio_panel ~width:(geometry.list_width + 4) ~title:list_title ~lines:left
      and right = studio_panel ~width:(geometry.preview_width + 4) ~title:preview_title ~lines:right in
      List.map2 (fun a b -> a ^ "  " ^ b) left right

type work_list_window =
  { entry_height : int
  ; capacity : int
  ; first : int
  }

(* Cursors and page keys count entries; the list budget counts physical rows.
   Where the cursor stands is on the title row, so no row is kept for it. *)
let work_list_window ~rows ~count ~selected =
  let rows = max 0 rows in
  let entry_height = if rows >= 2 then 2 else 1 in
  let capacity = min count (rows / entry_height) in
  let first = match selected with
    | None -> 0
    | Some index -> if capacity = 0 then 0 else max 0 (index - capacity + 1) in
  { entry_height; capacity; first }

let work_entry_lines ~cells ~height ~selected ~title ~summary ~compact =
  let lead = if selected then "› " else "  " in
  let lines =
    if height = 1 then [lead ^ compact ^ " · " ^ Terminal_text.single_line title]
    else [lead ^ Terminal_text.single_line title; "  " ^ summary] in
  List.map (fun line ->
    if selected then selection_row_styled ~cells line
    else Message_layout.fit_width line cells) lines

let work_preview_field ~cells label value =
  let value = Terminal_text.single_line value in
  Message_layout.truncate_middle (max 1 cells) (label ^ value)

let work_preview_body ~cells ~rows text =
  if rows <= 0 then [] else
  let lines = Masc_tui_text_block.rows ~max_cells:(max 1 cells) text in
  let shown = List.take rows lines in
  if List.length lines <= rows then shown
  else List.mapi (fun index line ->
    if index = rows - 1 then Message_layout.truncate_end cells line
    else line) shown

(* The rows on screen are the last reading that arrived. A read still in
   flight does not make them older: they stay as they are until its answer
   lands, and the slow-read note says a read is under way (RFC
   tui-one-screen-grammar, section 8). *)
let work_task_rows_current (state : state) =
  state.workspace_identity = Workspace_identity_match
  && match state.local_workspace, state.task_reading with
     | Local_workspace_read, Overview_tasks.Rows_read _ -> true
     | (Local_workspace_unread | Local_workspace_failed _), _
     | Local_workspace_read, (Rows_unread | Rows_unavailable _) -> false

(* A recent read can still be recovered or have incomplete coverage. The
   note is not parsed: without a complete reading, absence is not a fact. *)
let work_task_rows_complete state =
  work_task_rows_current state && Option.is_none state.tasks_error

let work_task_scope (state : state) =
  let ko = state.ui_language = Lang_ko in
  let text ko en = ui_text state ~ko ~en in
  let current = work_task_rows_current state in
  let partial = Option.is_some state.tasks_error in
  let scope = match state.task_reading with
    | Overview_tasks.Rows_read _ when current ->
        if partial then text "현재 작업 관측 · 조회 범위 일부" "Current Task reading · partial coverage"
        else text "현재 작업 관측" "Current Task reading"
    | Rows_read _ ->
        (* Rows that are read but not current: the local workspace was not
           read or its read failed, or else the workspace is unconfirmed. *)
        let reason = match state.local_workspace with
          | Local_workspace_failed detail ->
              text "새 조회 실패: " "Refresh failed: " ^ Terminal_text.single_line detail
          | Local_workspace_unread -> text "로컬 워크스페이스 " "Local workspace " ^ field_unread ~ko
          | Local_workspace_read -> String.capitalize_ascii (workspace_identity_unconfirmed ~ko) in
        text "이전 작업 관측 · " "Previous Task reading · " ^ reason
    | Rows_unread -> text "작업 미조회 · 남은 줄은 이전 관측" "Tasks not read · the rows shown are a previous reading"
    | Rows_unavailable detail ->
        text "작업 조회 실패 · 남은 줄은 이전 관측: " "Task reading failed · the rows shown are a previous reading: "
        ^ Terminal_text.single_line detail in
  scope, (not current || partial)

let work_tasks_context_lines (state : state) ~cols =
  let text ko en = ui_text state ~ko ~en in
  let scope, warning = work_task_scope state in
  let reasons =
    [ Terminal_text.optional_single_line state.tasks_error
    ; (match state.goal_task_links with
       | Goal_links_read_failed reason -> Terminal_text.optional_single_line (Some reason)
       | Goal_links_not_read | Goal_links_read _ -> None) ]
    |> List.filter_map Fun.id in
  [work_hub_navigation state ~cols]
  @ (if warning then [" " ^ Theme.warn () ^ scope ^ Ansi.reset] else [])
  @ Option.to_list (local_source_pending_note state Local_work)
  @ (if reasons = [] then [] else
       [" " ^ Theme.warn () ^ text "조회 범위: " "Coverage: " ^ String.concat " · " reasons ^ Ansi.reset])

let work_tasks_projection (state : state) ~cols ~budget =
  let context_budget = max 0 (budget - 1) in
  let context = work_tasks_context_lines state ~cols in
  let context =
    match context with
    | navigation :: scope :: rest when List.length context > context_budget ->
        scope :: navigation :: rest
    | _ -> context in
  let context = List.take context_budget context in
  let geometry = work_panels ~inner:(framed_inner_width cols) ~rows:(budget - List.length context) in
  let count = List.length (Overview_tasks.work_rows state.tasks) in
  let selected = Overview_tasks.work_selected_index state.tasks
      ~selected:(Overview_tasks.selection state.task_focus) in
  let window = work_list_window ~rows:geometry.list_rows ~count ~selected in
  context, geometry, window

let task_preview_lines (state : state) ~cells ~rows (task : Tui_decode.task) =
  if rows <= 0 then [] else
  let text ko en = ui_text state ~ko ~en in
  let field = work_preview_field ~cells in
  let original =
    List.find_opt (fun (full : Masc_domain.task) -> String.equal full.id task.id)
      (task_domain_values state) in
  let request = match original with
    | None -> text "요청 내용 미조회" "Request not read"
    | Some full ->
        if String.trim full.description = "" then full.title
        else full.description in
  let owner = match Masc_domain.task_assignee_of_status task.status with
    | Some owner -> owner
    | None -> text "미배정" "Unassigned" in
  let header =
    if rows >= 3 then
      [Theme.recede () ^ field "" (owner ^ " · " ^ task_status_word state task.status) ^ Ansi.reset]
      @ (if rows >= 4 then [""] else [])
    else [] in
  let hint =
    if rows >= 2 then [Theme.recede () ^ text "Enter:상세" "Enter:details" ^ Ansi.reset]
    else [] in
  let room = max 0 (rows - List.length header - List.length hint) in
  let body_budget = if hint <> [] && room >= 3 then room - 1 else room in
  let body = work_preview_body ~cells ~rows:body_budget request in
  let hint_gap = if hint <> [] && body <> [] && List.length body < room then [""] else [] in
  header @ body @ hint_gap @ hint


(* One task's event history, appended after the detail body so it rides the
   same scroll. Loaded lazily on detail entry; the id check drops an answer
   for a task the operator already left. Rows are raw event-stream lines, so
   only the fields present are drawn. *)
let task_detail_lines (state : state) ~cols (task : Masc_domain.task) =
  let text ko en = ui_text state ~ko ~en in
  let width=max 1 (framed_inner_width cols - 2) in
  let history=Masc_tui_fetched.view_for ~equal:String.equal state.task_history ~key:task.id in
  let stalled_note =
    match state.operator_stalled with
    | Masc_tui_agenda.Read rows ->
        Option.to_list
          (Option.map
             (fun (row : Masc_tui_agenda.stalled) ->
               (text " 운영자 목록 · " " Operator list · ")
               ^ Terminal_text.single_line
                   (Masc.Operator_task_attention.summary
                      ~ko:(state.ui_language = Lang_ko) row))
             (List.find_opt
                (fun (row : Masc_tui_agenda.stalled) ->
                  String.equal (Masc.Operator_task_attention.task_id row) task.id)
                rows))
    | Masc_tui_agenda.Not_read | Masc_tui_agenda.Read_failed _ -> []
  in
  let failures=stalled_note
    @ Option.to_list (Option.map (fun detail -> (text " 작업 조회 실패 · 이전 관측: " " Task read failed · last observation: ") ^ detail) state.tasks_error)
    @ (match task_goal_reading state ~task_id:task.id with
      | Masc_tui_agenda.Read_failed detail -> [(text " 목표 연결 조회 실패: " " Goal links unavailable: ") ^ detail]
      | Not_read | Read _ -> []) in
  let failure_rows =
    failures
    |> List.concat_map (Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols)))
  in
  let body_rows = task_document_lines state ~cols Masc_tui_task_document.Body in
  let pre_history =
    match failure_rows, body_rows with
    | [], [] -> []
    | [], _ :: _ -> body_rows
    | _ :: _, [] -> failure_rows
    | _ :: _, _ :: _ -> failure_rows @ ("" :: body_rows)
  in
  let history_heading =
    Masc_tui_task_document.history_heading_rows ~ko:(state.ui_language = Lang_ko) ~width
  in
  (if pre_history = [] then history_heading else pre_history @ ("" :: history_heading))
  @ (Masc_tui_task_document.history_status_lines ~ko:(state.ui_language = Lang_ko) ~width
      ~view:(observation_failure_said (history_failure_said ~ko:(state.ui_language = Lang_ko)
        ~request:Kept_request.Task_history_read) history)
      ~in_flight:(Masc_tui_fetched.in_flight state.task_history)
      ~continuing:(Option.exists (fun request -> Option.is_some request.thr_page.hr_cursor)
        state.task_history_request)
     |> List.concat_map
          (Masc_tui_text_block.preformatted_rows
             ~max_cells:(max 1 (framed_inner_width cols))))
  @ task_document_lines state ~cols Masc_tui_task_document.History

let task_detail_chrome_rows = max 0 (framed_chrome_rows - 2)

let task_detail_height ~rows ~count =
  Masc_tui_scroll.content_height ~rows ~chrome:task_detail_chrome_rows ~count
    ~preview_keep:None

let task_detail_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let pane_cols = task_document_columns state ~terminal_cols:cols in
  let count = match Task_selection.detail_row ~detail_id:state.task_detail_id ~tasks:(Masc_tui_types.task_domain_values state) with
    | None -> 0
    | Some task -> List.length (task_detail_lines state ~cols:pane_cols task)
  in
  count, task_detail_height ~rows ~count

let task_detail_pane (state : state) ~rows ~cols (task : Masc_domain.task) buf =
  let header = screen_title (ui_text state ~ko:" 작업" ~en:" Task")
    ^ quiet_connection_tail state in
  let lines = task_detail_lines state ~cols task in
  let count = List.length lines in
  let height = task_detail_height ~rows ~count in
  let scroll = Masc_tui_scroll.normalize ~count ~height (task_detail_render_scroll state) in
  box_line buf cols
    (titled_row ~cols state ~title:header
       ~position:(Masc_tui_value.Position.window ~first:scroll ~shown:height ~total:count));
  box_divider buf cols;
  let window = Rows.of_list ~first:scroll ~height lines in
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some line -> box_line buf cols line
  done;
  scroll, count, height
;;

(* The task list stays beside the task. Overview's rows are the queue
   this task sits in, and reading one used to cost the reader their
   place in it. Below the split width the detail keeps the screen. *)
let render_task_detail (state : state) (task : Masc_domain.task) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let offset, count, height =
    if cols < keeper_split_threshold_cols then
      task_detail_pane state ~rows ~cols task buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      (* The highlight names the task this detail shows, not the cursor: a
         done or cancelled task opened from the palette or a link has no row
         here, and the row the cursor last rested on would be a different
         task. *)
      (* The id follows each title because the shared sidebar fold keeps the
         tail, so titles with the same opening and ending still differ. *)
      write_list_sidebar_selection ~framed:false left_buf ~rows ~cols:left_cols
        ~title:(ui_text state ~ko:"작업" ~en:"Tasks") ~focused:false
        (* [Overview_tasks.work_rows] drops what is done or cancelled.
           A filter is not a page: what it left out is a different kind of
           row, not more of these, so there is no second number to draw. *)
        ~holding:None
        ~labels:
          (List.map
             (fun (row : Tui_decode.task) ->
               Render_schedule.sidebar_row_label ~about:row.title
                 ~apart:(Some row.id))
             (Overview_tasks.work_rows state.tasks))
        ~selection:(Overview_tasks.work_selected_index state.tasks
                      ~selected:(Some task.id));
      let answer =
        task_detail_pane state ~rows ~cols:(cols - left_cols) task right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~status:[]
       ~hints:(ui_text state ~ko:"j/k:스크롤  PgUp/PgDn:페이지  Home/End:처음/끝  x:취소  ←/Esc:뒤로  r:새로고침"
         ~en:"j/k:scroll  PgUp/PgDn:page  Home/End:top/end  x:cancel  Left / Esc:back  r:refresh"));

  let offset =
    if task_documents_pending state && not (task_detail_following_end state)
    then state.task_detail_scroll else offset in
  finish_surface state ~clamped:(Task_detail (offset, Some (count, height)))
    ~surface_key:"task-detail" ~rows:terminal_rows ~cols buf

let render_work_tasks (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let text ko en = ui_text state ~ko ~en in
  let rows = Overview_tasks.work_rows state.tasks in
  let selected = Overview_tasks.work_selected_index state.tasks
      ~selected:(Overview_tasks.selection state.task_focus) in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols
    ~surface_key:"work-tasks"
    ~title:(here_row ~cols state ~path:[ text "태스크" "Tasks" ] ~readings:[] ~position:None)
    ~hints:(Masc_tui_keys.footer_hints_work_tasks ~lang:state.ui_language)
    ~body:(fun ~budget c ->
      let context, geometry, window = work_tasks_projection state ~cols ~budget in
      report_drawn_list Task_entries ~height:window.capacity;
      List.iter c.push context;
      let count = List.length rows in
      let list_lines =
        (if count = 0 then
           [match state.task_reading with
            | Overview_tasks.Rows_read _ ->
                if work_task_rows_complete state then text "표시할 열린 작업 없음" "No open Tasks in this reading"
                else if work_task_rows_current state then
                  text "이 관측에 열린 작업 없음 · 일부 관측" "No open Tasks in this reading · partial reading"
                else text "이전 관측에 열린 작업 없음" "No open Tasks in the earlier reading"
            | Rows_unread | Rows_unavailable _ -> text "열린 작업 목록 미조회" "Open Task list not read"]
         else
           (* A row holds values only. A previous reading draws them faint
              and the scope line above says why (RFC tui-one-screen-grammar
              6.4); a list read in part says so on that line too. *)
           let previous = not (work_task_rows_current state) in
           rows |> List.mapi (fun index task -> index, task)
           |> List.drop window.first |> List.take window.capacity
           |> List.concat_map (fun (index, (task : Tui_decode.task)) ->
             let status_word = task_status_mark task.status ^ " " ^ task_status_word state task.status in
             let owner = match Masc_domain.task_assignee_of_status task.status with
               | Some name -> Terminal_text.single_line name
               | None -> text "미배정" "unassigned" in
             let status_style = if previous then Theme.recede () else task_state_style task.status in
             let summary = wrap_style status_style status_word
               ^ wrap_style (Theme.recede ()) (" · " ^ owner) in
             work_entry_lines ~cells:geometry.list_width ~height:window.entry_height
               ~selected:(Some index = selected) ~title:task.title ~summary
               ~compact:status_word)) in
      if count > 0 then
        c.position (Masc_tui_value.Position.row ~selected ~total:count);
      let selected_task = Overview_tasks.work_selected_task state.tasks
          ~selected:(Overview_tasks.selection state.task_focus) in
      let preview_title, preview_lines = match selected_task with
        | Some task ->
            text "요청" "Request",
            task_preview_lines state ~cells:geometry.preview_width ~rows:geometry.preview_rows task
        | None ->
            text "요청" "Request",
            [text "선택된 작업 없음" "No task selected"] in
      List.iter c.push (work_panel_lines geometry
        ~list_title:(text "작업" "Tasks")
        ~list_lines ~preview_title ~preview_lines))

let planning_detail_tone (tone : Planning_detail.tone) =
  match tone with
  | Planning_detail.Proven -> (Theme.ok ())
  | Planning_detail.Refused -> (Theme.bad ())
  | Planning_detail.Waiting | Planning_detail.Unreadable -> (Theme.warn ())
  | Planning_detail.Active -> (Theme.info ())
  | Planning_detail.Note | Planning_detail.Quiet -> Theme.recede ()
  | Planning_detail.Plain -> Ansi.default_fg
  | Planning_detail.Heading -> Masc_tui_ansi.Section.style
  | Planning_detail.Prestyled -> ""

let planning_phase_mark = function
  | Goal_phase.Executing -> Masc_tui_value.Mark.Under_way
  | Goal_phase.Verifying -> Masc_tui_value.Mark.Under_way
  | Goal_phase.Awaiting_confirmation -> Masc_tui_value.Mark.Yours
  | Goal_phase.Completed -> Masc_tui_value.Mark.Settled
  | Goal_phase.Paused _ -> Masc_tui_value.Mark.Paused
  | Goal_phase.Blocked _ -> Masc_tui_value.Mark.Failed
  | Goal_phase.Dropped -> Masc_tui_value.Mark.Paused

let planning_progress_sheet ~now ?goal_id (state : state) =
  let matching_inflight =
    match goal_id with
    | Some id ->
        if List.mem_assoc id state.goal_action_inflight then Some id else None
    | None -> (
        match state.goal_action_inflight with
        | (id, _) :: _ -> Some id
        | [] -> None)
  in
  let submitting_goal =
    match state.goal_confirmation with
    | Masc_tui_planning_detail.Submitting (id, _) -> (
        match goal_id with
        | Some target when not (String.equal target id) -> None
        | Some _ | None -> Some id)
    | Inspecting _ -> None
  in
  let spec =
    match submitting_goal, matching_inflight with
    | Some id, _ ->
        Some
          ( "confirm:" ^ id
          , ui_text state ~ko:"목표 근거 최종 확인 전송 중" ~en:"Submitting goal proof confirmation"
          , Some (Terminal_text.single_line id)
          , true )
    | None, Some id ->
        Some
          ( "transition:" ^ id
          , ui_text state ~ko:"목표 상태 변경 처리 중" ~en:"Updating goal state"
          , Some (Terminal_text.single_line id)
          , true )
    | None, None -> None
  in
  let started_at =
    Masc_tui_types.progress_clock_option state ~slot:"planning-op" ~now
      (Option.map (fun (sig_key, _, _, _) -> sig_key) spec)
  in
  Option.map
    (fun (_, ps_title, ps_detail, ps_blocking) ->
      { ps_title
      ; ps_detail
      ; ps_started_at = started_at
      ; ps_meter = None
      ; ps_action_hint = None
      ; ps_blocking
      })
    spec
;;

(* What moves this goal next, in one sentence, from the pair the operator can
   see separately but had to combine themselves: the phase and the judge's
   last word. [executing] with a refusal on the ledger is a different
   instruction from [executing] with nothing on it, and both drew the same
   word. Only the goal phase decides here -- the linked tasks have their own
   surface and their own verdicts. *)
let planning_next_step ~ko (goal : planning_goal) =
  let text korean english = if ko then korean else english in
  if not (planning_goal_has_valid_id goal) then
    (Theme.warn (), (text "목표 ID 오류 (빈 값·앞뒤 공백) · 저장된 ID 확인 필요" "Goal ID is blank or has disallowed surrounding whitespace; inspect stored ID"))
  else match goal.pg_phase, goal.pg_proof with
  | Goal_phase.Executing, Tui_decode.Proof_unreadable _ when Option.is_none goal.pg_retry_binding ->
    (Theme.warn (), (text "검증 결속 보고 안 됨 · 근거·저장소·런타임 확인 후 r:재조회" "verification binding not reported · inspect proof, storage, runtime  r:refresh"))
  | Goal_phase.Executing, _ when Option.is_none goal.pg_retry_binding ->
    (Theme.warn (), (text "검증 결속 보고 안 됨 · 목표·근거 확인 후 r:재조회" "verification binding not reported · inspect Goal and proof  r:refresh"))
  | Goal_phase.Executing, Tui_decode.Proof_refuted _ ->
    ( (Theme.bad ())
    , (text "검증 거절 · 판정 사유 반영 후 c:재제출" "refused · address verdict below  c:resubmit") )
  | (Goal_phase.Executing, Proof_idle) | (Goal_phase.Executing, Proof_pending)
  | (Goal_phase.Executing, Proof_proven _) | (Goal_phase.Executing, Proof_stale _)
  | (Goal_phase.Executing, Proof_unreadable _) ->
    ( Theme.recede ()
    , (text "성공 조건 충족 후 c:검증 요청" "meet success criterion  c:request verification") )
  | (Goal_phase.Verifying, Proof_idle) | (Goal_phase.Verifying, Proof_pending)
  | (Goal_phase.Verifying, Proof_proven _) | (Goal_phase.Verifying, Proof_refuted _)
  | (Goal_phase.Verifying, Proof_stale _) | (Goal_phase.Verifying, Proof_unreadable _) ->
    let tone, text = Planning_detail.verifying_next_step ~ko
        ~can_retry:(Option.is_some goal.pg_retry_binding) goal.pg_verifier_unreconciled in
    (planning_detail_tone tone, text)
  | (Goal_phase.Awaiting_confirmation, Proof_idle)
  | (Goal_phase.Awaiting_confirmation, Proof_pending)
  | (Goal_phase.Awaiting_confirmation, Proof_proven _)
  | (Goal_phase.Awaiting_confirmation, Proof_refuted _)
  | (Goal_phase.Awaiting_confirmation, Proof_stale _)
  | (Goal_phase.Awaiting_confirmation, Proof_unreadable _) ->
    (Theme.warn (), (text "최종 확인 대기 · a:근거 조회 및 증거 확인" "awaiting confirmation · a:review proof and confirm"))
  | (Goal_phase.Completed, Proof_idle) | (Goal_phase.Completed, Proof_pending)
  | (Goal_phase.Completed, Proof_proven _) | (Goal_phase.Completed, Proof_refuted _)
  | (Goal_phase.Completed, Proof_stale _) | (Goal_phase.Completed, Proof_unreadable _) -> (Theme.recede (), (text "완료  o:다시 열기" "completed  o:reopen"))
  | (Goal_phase.Dropped, Proof_idle) | (Goal_phase.Dropped, Proof_pending)
  | (Goal_phase.Dropped, Proof_proven _) | (Goal_phase.Dropped, Proof_refuted _)
  | (Goal_phase.Dropped, Proof_stale _) | (Goal_phase.Dropped, Proof_unreadable _) -> (Theme.recede (), (text "중단  o:다시 열기" "abandoned  o:reopen"))
  | (Goal_phase.Paused _, Proof_idle) | (Goal_phase.Paused _, Proof_pending)
  | (Goal_phase.Paused _, Proof_proven _) | (Goal_phase.Paused _, Proof_refuted _)
  | (Goal_phase.Paused _, Proof_stale _) | (Goal_phase.Paused _, Proof_unreadable _) -> (Theme.warn (), (text "일시정지  r:재개 · 연결 작업은 별도 진행" "paused  r:resume · linked Tasks continue independently"))
  | (Goal_phase.Blocked _, Proof_idle) | (Goal_phase.Blocked _, Proof_pending)
  | (Goal_phase.Blocked _, Proof_proven _) | (Goal_phase.Blocked _, Proof_refuted _)
  | (Goal_phase.Blocked _, Proof_stale _) | (Goal_phase.Blocked _, Proof_unreadable _) -> (Theme.bad (), (text "막힘  u:재개 · 연결 작업은 별도 진행" "blocked  u:resume · linked Tasks continue independently"))
;;

(* The line under the list, for the goal the cursor is on. A verdict without its
   reason is a colour and nothing else; the reason is what the judge produced
   and the only thing that says what to do next. *)
let planning_proof_detail ~ko (goal : planning_goal) =
  let text korean english = if ko then korean else english in
  match goal.pg_verifier_unreconciled with
  | Some blocked ->
    (* The judge's last word is not what holds this goal: the latest verifier
       scan could not settle it, and only this line says why. *)
    Some
      ( Theme.bad ()
      , Printf.sprintf "%s: %s"
          (if ko then match blocked.vu_step with
           | Goal_reconcile_step.Reconcile_proof -> "검증기가 확정 증거를 적용하지 못함"
           | Goal_reconcile_step.Rearm_proof -> "검증기가 증명 요청을 확인하지 못함"
           | Goal_reconcile_step.Read_original -> "검증기가 보존된 요청을 읽지 못함"
           else Planning_detail.unreconciled_heading ~ko blocked.vu_step)
          (Terminal_text.single_line blocked.vu_detail) )
  | None ->
  (* A verdict is a past event of the Goal, not its state: the phase beside
     it is the state, and a refused Goal is back at work. "지난" keeps the
     two from reading as one Goal in two states at once. *)
  match goal.pg_proof with
  | Tui_decode.Proof_proven None -> Some ((Theme.ok ()), text "지난 검증 통과" "last verification passed")
  | Tui_decode.Proof_proven (Some evidence) ->
      Some ((Theme.ok ()), text "지난 검증 통과: " "last verification passed: " ^ Terminal_text.single_line evidence)
  | Tui_decode.Proof_refuted None -> Some ((Theme.bad ()), text "지난 검증 거절" "last verification refused")
  | Tui_decode.Proof_refuted (Some reason) ->
      Some ((Theme.bad ()), text "지난 검증 거절: " "last verification refused: " ^ Terminal_text.single_line reason)
  | Tui_decode.Proof_pending -> Some ((Theme.warn ()), text "완료 판정 대기" "verification result pending")
  | Tui_decode.Proof_stale _ ->
      Some ((Theme.warn ()), text "기준 변경 · 이전 증거는 이력" "criterion changed; previous proof is historical")
  | Tui_decode.Proof_unreadable None ->
      Some ((Theme.warn ()), text "검증 기록 읽기 실패" "verification ledger unreadable")
  | Tui_decode.Proof_unreadable (Some detail) ->
      Some ((Theme.warn ()), text "검증 기록 읽기 실패: " "verification ledger unreadable: " ^ Terminal_text.single_line detail)
  | Tui_decode.Proof_idle ->
      (* Nothing from the judge. A keeper's own note is the next best thing the
         row has to say, and it is what the operator wrote there to be read. *)
      Option.map
        (fun note -> (Theme.recede (), text "메모: " "note: " ^ note))
        (Terminal_text.optional_single_line goal.pg_last_review_note)
;;

(** Render the Planning surface (list view). *)


(* This is snapshot provenance, not fresh Goal/proof authority. Keep the
   warning outside the scrollable proof body so proof presentation indices
   still refer to the same body rows. Header and viewport use the same rows. *)
let planning_stale_notice_rows (state : state) ~cols =
  let ko = state.ui_language = Lang_ko in
  let notice = match state.workspace_identity, state.planning_error with
    | Workspace_identity_match_unconfirmed detail, _ ->
        Some (String.capitalize_ascii (workspace_identity_unconfirmed ~ko), detail)
    | (Workspace_identity_match | Workspace_identity_unread | Workspace_identity_mismatch _), Some error ->
        Some ((if ko then "새로고침 실패" else "Refresh failed"), error)
    | (Workspace_identity_match | Workspace_identity_unread | Workspace_identity_mismatch _), None -> None
  in
  match state.planning, notice with
  | Some snapshot, Some (status, error) ->
      let width = max 1 (framed_inner_width cols - 2) in
      let rows text = Message_layout.wrap_words ~max_cells:width text
        |> List.map (fun line -> Theme.warn () ^ "  " ^ line ^ Ansi.reset) in
      rows (status ^ (if ko then " · 표시 중인 스냅샷 " else " · showing snapshot ")
        ^ wire_moment snapshot.pl_generated_at)
      @ (match Terminal_text.optional_single_line (Some error) with
         | None -> []
         (* Keep verbose diagnostics on the existing error row; a long
            transport reason must not consume the Goal/proof viewport. *)
         | Some detail -> [data_unreliable_row ~cols detail])
  | None, (None | Some _) | Some _, None -> []

let planning_phase_korean = function
  | Goal_phase.Kind.Executing -> "진행"
  | Goal_phase.Kind.Verifying -> "검증 중"
  | Goal_phase.Kind.Awaiting_confirmation -> "최종 확인 대기"
  | Goal_phase.Kind.Completed -> "완료"
  | Goal_phase.Kind.Dropped -> "중단"
  | Goal_phase.Kind.Paused -> "일시정지"
  | Goal_phase.Kind.Blocked -> "막힘"

let seconds_per_hour = 3600.

let planning_summary_reading ~cols (state : state) =
  let ko = state.ui_language = Lang_ko in
  let text korean english = if ko then korean else english in
  let section heading rows : Masc_tui_detail_reading.section =
    { heading; body = String.concat "\n" (List.map Masc_tui_theme.strip_sgr rows) }
  in
  let warning =
    (match state.workspace_identity with
     | Workspace_identity_match_unconfirmed detail ->
         [String.capitalize_ascii (workspace_identity_unconfirmed ~ko) ^ ": "
          ^ Terminal_text.single_line detail]
     | Workspace_identity_match | Workspace_identity_unread | Workspace_identity_mismatch _ -> [])
    @ Option.to_list (Option.map (fun detail ->
        text "조회 실패: " "Read failed: " ^ Terminal_text.single_line detail) state.planning_error)
  in
  let sections = match state.planning with
    | None -> [section (text "관측 상태" "Observation")
        (warning @ [text "목표 관측 없음" "No Goal observation"])]
    | Some p ->
        let stamps =
          [ text "표시 중인 서버 스냅샷: " "Displayed server snapshot: " ^ wire_moment p.pl_generated_at ]
          @ (match state.planning_baseline with
             | None -> [text "기준 스냅샷 없음" "No baseline snapshot"]
             | Some first -> [text "기준 서버 스냅샷: " "Baseline server snapshot: " ^ wire_moment first.pl_generated_at])
        in
        let history = match p.pl_goal_history with
          | [] -> [text "목록 밖 이력 없음" "No unlisted Goal history"]
          | history ->
              let ended = List.length (List.filter (fun row -> Option.is_some row.pgh_closed_at) history) in
              (if ko then Printf.sprintf "목록 밖 %d개 · 종결 결과 보고 안 됨 %d개" (List.length history) (List.length history - ended)
               else planning_goal_history_summary ~unlisted:(List.length history) ~ended)
              :: List.map (fun row ->
                   let name = Option.value row.pgh_title ~default:row.pgh_goal_id |> Terminal_text.single_line in
                   let phase = match row.pgh_final_phase with
                     | None -> text "단계 보고 안 됨" "phase not reported"
                     | Some phase ->
                         let shown = if ko then
                             Option.fold ~none:(Terminal_text.single_line phase)
                               ~some:planning_phase_korean (Goal_phase.Kind.parse phase)
                           else Terminal_text.single_line phase in
                         text "마지막 단계 " "last phase " ^ shown in
                   let outcome = if Option.is_some row.pgh_closed_at
                     then text "종결 시각 기록됨" "close time recorded"
                     else text "종결 결과 보고 안 됨" "terminal outcome not reported" in
                   (* The server reports a lifetime only for a Goal that
                      closed, so it is a finished length (RFC
                      tui-one-screen-grammar 6.2): 1d12h, not 36.0h. A
                      lifetime the ladder refuses (negative, not a number)
                      draws the read-failed mark rather than vanishing. *)
                   let lifetime = match row.pgh_lifetime_hours with
                     | None -> ""
                     | Some hours ->
                         " · " ^ Option.value
                           (Message_layout.elapsed_text (hours *. seconds_per_hour))
                           ~default:(Masc_tui_value.Unknown.glyph
                                       Masc_tui_value.Unknown.Read_failed) in
                   name ^ " · " ^ phase ^ " · " ^ outcome ^ lifetime) history
        in
        let rollup = p.pl_rollup in
        let backlog = p.pl_backlog in
        let total_goals = rollup.pr_active + rollup.pr_verifying + rollup.pr_awaiting_confirmation
          + rollup.pr_done + rollup.pr_paused + rollup.pr_blocked + rollup.pr_dropped in
        let goal_rows = if not ko then planning_rollup_rows ~cols rollup else
          [ Printf.sprintf "전체 %d · 진행 %d · 검증 %d · 확인 대기 %d" total_goals rollup.pr_active rollup.pr_verifying rollup.pr_awaiting_confirmation
          ; Printf.sprintf "완료 단계 %d · 일시정지 %d · 막힘 %d · 중단 %d" rollup.pr_done rollup.pr_paused rollup.pr_blocked rollup.pr_dropped ] in
        let backlog_rows = if not ko then pack_planning_summary_rows ~cols (planning_backlog_clauses backlog) else
          [ Printf.sprintf "할 일 %d · 담당 %d · 진행 %d" backlog.pb_todo backlog.pb_claimed backlog.pb_running
          ; Printf.sprintf "검증 대기 %d · 완료 %d · 취소 %d" backlog.pb_awaiting_verification backlog.pb_done backlog.pb_cancelled ] in
        let change_rows = pack_planning_summary_rows ~cols
            (planning_change_clauses ~ko ~baseline:state.planning_baseline p) in
        [section (text "관측과 기준" "Observation and baseline") (warning @ stamps);
         section (text "목표 상태" "Goal states") goal_rows;
         section (text "전체 작업 현황" "Global Task backlog") backlog_rows;
         section (text "기준 대비 변화" "Change from baseline") change_rows;
         section (text "목록 밖 목표 이력" "Unlisted Goal history") history]
  in
  let retired = List.rev state.goal_action_receipts |> List.map (fun receipt ->
    let names = Printf.sprintf "%s · %s · %s" (Terminal_text.single_line receipt.gar_goal_id)
      (Terminal_text.single_line receipt.gar_workspace) (Terminal_text.single_line receipt.gar_ticket) in
    match goal_receipt_answer state receipt with
    | `Kept_back notice -> notice ^ " · " ^ names
    | `Answer answer -> names ^ " · " ^ answer) in
  let sections = sections @ (match retired with
    | [] -> []
    | _ -> [section (text "목표 요청 결과" "Goal request results") retired]) in
  Masc_tui_detail_reading.create ~ko ~title:(text "작업 요약" "Work summary") sections

(* The linked-Task clause of a Goal row. It names what it counts, in the
   words of the Task list, so it never reads as a second state of the Goal:
   [작업 2개 검증 대기], not [검증 2]. It is a value (RFC
   tui-one-screen-grammar 6.3, 6.4): a list read in part is a lower bound,
   a reading that is missing is a mark (◌ not read yet, ✕ the read failed,
   ? read in part with none of this Goal's among what arrived), and a
   previous reading is faint. Why a value is missing or old is the scope
   line above the list. Linked Tasks have a separate read contract from the
   Goal snapshot: an unread registry or backlog is never a claim that a Goal
   has no work. *)
let planning_open_note (state : state) (goal : planning_goal) =
  let ko = state.ui_language = Lang_ko in
  let missing mark = (if ko then "작업 " else "tasks ") ^ mark in
  match state.goal_task_links, state.task_reading with
  (* A failed reading on either side is a failure whatever the other side
     holds: a backlog that cannot be read leaves the links not read too
     (Masc_tui_loader). *)
  | Goal_links_read_failed _, (Overview_tasks.Rows_unread | Rows_read _ | Rows_unavailable _)
  | (Goal_links_not_read | Goal_links_read _), Rows_unavailable _ ->
      missing "✕", Theme.warn ()
  | Goal_links_not_read, (Rows_unread | Rows_read _) | Goal_links_read _, Rows_unread ->
      missing "◌", Theme.recede ()
  | Goal_links_read _, Rows_read _ ->
      let tasks = List.filter (fun (task : Tui_decode.task) -> List.mem goal.pg_id task.goal_ids) state.tasks in
      let partial = Option.is_some state.tasks_error in
      let faint style = if work_task_rows_current state then style else Theme.recede () in
      let count noun value =
        (if partial then Masc_tui_value.Count.at_least else Masc_tui_value.Count.reading)
          ~ko noun value in
      let awaiting = List.length (List.filter (fun (task : Tui_decode.task) ->
        match task.status with
        | Masc_domain.AwaitingVerification _ -> true
        | Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ -> false) tasks) in
      let running = List.length (List.filter (fun (task : Tui_decode.task) ->
        match task.status with
        | Masc_domain.InProgress _ -> true
        | Todo | Claimed _ | AwaitingVerification _ | Done _ | Cancelled _ -> false) tasks) in
      if tasks = [] then (if partial then missing "?", faint (Theme.warn ()) else "", Theme.recede ())
      else if awaiting > 0 then
        count Masc_tui_value.Count.Task awaiting ^ (if ko then " 검증 대기" else " awaiting verification"),
        faint (Theme.warn ())
      else if running > 0 then
        count Masc_tui_value.Count.Task running ^ (if ko then " 진행 중" else " in progress"),
        faint (if partial then Theme.warn () else Theme.info ())
      else count Masc_tui_value.Count.Open_task (List.length tasks),
        faint (if partial then Theme.warn () else Theme.recede ())

(* The words a Goal at work carries when its due date has passed or cannot be
   read (#39571). The row, the preview and the detail print the same words for
   the same standing; a Goal due later, without a due date or not at work
   carries none. *)
let planning_due_clause ~ko (standing : Planning_due.standing) =
  let text korean english = if ko then korean else english in
  match standing with
  | Planning_due.Due_passed -> Some (text "기한 지남" "past due")
  | Planning_due.Unreadable_due _ -> Some (text "기한 읽기 실패" "unreadable due date")
  | Planning_due.Due_ahead | Planning_due.Not_in_progress | Planning_due.No_due -> None

let planning_preview_lines (state : state) ~now ~cells ~rows (goal : planning_goal) =
  if rows <= 0 || cells <= 0 then []
  else
    let ko = state.ui_language = Lang_ko in
    let text korean english = if ko then korean else english in
    let next_tone, next_sentence = planning_next_step ~ko goal in
    let next_rows =
      Text_block.rows ~max_cells:cells (Terminal_text.single_line next_sentence)
      |> (function
          | first :: _ ->
              [ (if String.equal next_tone "" then first
                 else next_tone ^ first ^ Ansi.reset) ]
          | [] -> [])
    in
    let notice =
      if not (planning_goal_has_valid_id goal) then
        Some (Theme.warn (), text "목표 ID 확인 필요" "Goal identifier needs inspection")
      else if Option.is_some goal.pg_verifier_unreconciled then
        planning_proof_detail ~ko goal
      else
        match goal.pg_proof with
        | Proof_refuted _ | Proof_stale _ | Proof_unreadable _ ->
            planning_proof_detail ~ko goal
        | Proof_idle | Proof_pending | Proof_proven _ -> (
            match goal.pg_phase with
            | (Goal_phase.Executing | Verifying)
              when Option.is_none goal.pg_retry_binding ->
                Some
                  ( Theme.warn ()
                  , text "검증 요청 정보 보고 안 됨"
                      "Verification request binding not reported" )
            | Executing | Verifying | Awaiting_confirmation | Completed | Dropped
            | Paused _ | Blocked _ -> None)
    in
    let open_note, open_tone = planning_open_note state goal in
    let due_opt = planning_due_clause ~ko (Planning_due.standing ~now goal) in
    let kv_fields =
      [ Doc.kv ~tone:Ansi.bold (text "목표값" "Target")
          (Planning_detail.measure_text goal.pg_measure)
      ]
      @ (if String.equal open_note "" then []
         else [ Doc.kv ~tone:open_tone (text "연결 작업" "Tasks") open_note ])
      @ (match due_opt with
         | None -> []
         | Some words -> [ Doc.kv ~tone:(Theme.warn ()) (text "기한" "Due") words ])
      @ (match notice with
         | None -> []
         | Some (tone, detail) ->
             [ Doc.kv ~tone (text "판정/주의" "Notice")
                 (Terminal_text.single_line detail) ])
    in
    let kv_lines = Doc.kv_rows ~width:cells ~indent:0 ~max_label_cells:12 kv_fields in
    let prose_lines =
      if rows >= 4 && not (String.equal (String.trim goal.pg_procedure) "") then
        [ "" ]
        @ Doc.prose_block ~width:cells ~indent:0 ~break_numbered:true
            goal.pg_procedure
      else []
    in
    next_rows @ kv_lines @ prose_lines

let paint_goal_table_row ~width ~selected ~current row =
  let fitted = fit_width row width in
  if selected then
    match Theme.sidebar_selection_background () with
    | Some bg when not (String.equal bg "") ->
        Masc_tui_theme.paint_row_background ~bg fitted
    | Some _ | None ->
        Theme.selection_style () ^ Masc_tui_theme.strip_sgr fitted ^ Ansi.reset
  else if current then fitted
  else Theme.recede () ^ Masc_tui_theme.strip_sgr fitted ^ Ansi.reset

let render_planning_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* One moment for the whole frame, so every row and the preview judge their
     due dates against the same instant. *)
  let now = Ptime_clock.now () in
  let ko = state.ui_language = Lang_ko in
  let text korean english = if ko then korean else english in
  let goals = match state.planning with
    | None -> []
    | Some snapshot -> planning_visible_goals ~filter:state.planning_filter
        ~sort:state.planning_sort snapshot.pl_goals in
  let count = List.length goals in
  let modes = if ko then
      let sort = match state.planning_sort with
        | Planning_sort_phase_priority -> "단계/우선순위"
        | Planning_sort_updated -> "최근 갱신" | Planning_sort_due -> "기한" in
      let filter = match state.planning_filter with
        | Planning_filter_all -> "전체" | Planning_filter_active -> "미종결"
        | Planning_filter_completed -> "완료" | Planning_filter_dropped -> "중단" in
      Printf.sprintf "정렬:%s  필터:%s" sort filter
    else Printf.sprintf "sort:%s  filter:%s"
      (planning_sort_label state.planning_sort) (planning_filter_label state.planning_filter) in
  let show_modes = state.planning_sort <> Planning_sort_phase_priority
    || state.planning_filter <> Planning_filter_active in
  let badge = quiet_connection_tail state in
  let now_unix = Unix.gettimeofday () in
  let progress_sheet = planning_progress_sheet ~now:now_unix state in
  let title =
    let suffix =
      badge
      ^ (match progress_sheet with
         | None -> ""
         | Some sheet ->
             "  " ^ progress_inline ~ko ~now:now_unix ?started_at:sheet.ps_started_at sheet.ps_title)
    in
    planning_workspace_title state ~cols ~tab:Planning_goals ~window:"" ~after:suffix ^ suffix
  in
  surface_chrome_keys
    ~overflow:Paged_by_cursor
    ?progress_sheet ~now:now_unix
    state ~terminal_rows ~cols ~surface_key:"planning-list" ~title
    ~keys:(Masc_tui_keys.footer_row_planning_goal_list ~lang:state.ui_language ~has_rows:(count > 0))
    ~body:(fun ~budget c ->
      let used = ref 0 in
      let push line = if !used < budget then (c.push line; incr used) in
      let push_context line = if !used < max 0 (budget - 1) then push line in
      let navigation = work_hub_navigation state ~cols in
      let current = state.workspace_identity = Workspace_identity_match
        && Option.is_none state.planning_error in
      (match state.planning with
       | None ->
           push_context navigation;
           let note = match Terminal_text.optional_single_line state.planning_error with
             | Some detail -> text "목표 조회 실패: " "Goal reading unavailable: " ^ detail
             | None -> text "목표 미조회 · r:새로고침" "Goals not read · r:refresh" in
           push (" " ^ Theme.warn () ^ note ^ Ansi.reset)
       | Some snapshot ->
           let scope = " " ^ (if current then Theme.recede () else Theme.warn ())
             ^ text (if current then "현재 목표 관측 · " else "이전 목표 관측 · ")
                    (if current then "Current Goal reading · " else "Previous Goal reading · ")
             ^ wire_moment snapshot.pl_generated_at ^ Ansi.reset in
           (* The linked-Task clause on each row is a value; when it is old,
              read in part or missing, these lines say why. A Task reading
              and a Goal-link reading fail apart, so each has its own. *)
           let task_scope, task_warning = work_task_scope state in
           let link_failure = match state.goal_task_links with
             | Goal_links_read_failed reason ->
                 [" " ^ Theme.warn () ^ text "목표 연결 조회 실패: " "Goal link reading failed: "
                  ^ Terminal_text.single_line reason ^ Ansi.reset]
             | Goal_links_not_read | Goal_links_read _ -> [] in
           List.iter push_context
             ((if current then [navigation] else [scope; navigation])
              @ (if task_warning then [" " ^ Theme.warn () ^ task_scope ^ Ansi.reset] else [])
              @ link_failure);
           let available = max 0 (budget - !used) in
           (* Modes and a read failure can use spare space, but never replace
              the one row Enter would open in a short terminal. *)
           if available >= 8 then begin
             if show_modes then push_context (" " ^ wrap_style (Theme.recede ()) modes);
             Option.iter (fun detail -> push_context (" " ^ wrap_style (Theme.warn ()) (Terminal_text.single_line detail)))
               state.planning_error
           end;
           let inner = max 1 (framed_inner_width cols) in
           let rollup = snapshot.pl_rollup in
           let total_goals =
             rollup.pr_active + rollup.pr_verifying + rollup.pr_awaiting_confirmation
             + rollup.pr_done + rollup.pr_paused + rollup.pr_blocked + rollup.pr_dropped
           in
           if max 0 (budget - !used) >= 10 && total_goals > 0 && inner >= 36 then begin
             let meter_w = min 44 (max 20 (inner - 4)) in
             push_context
               (" "
                ^ completion_meter ~width:meter_w
                    ~label:(text "목표 완료" "Goals done")
                    ~value:rollup.pr_done ~max_value:total_goals
                    ~suffix:(Printf.sprintf "%d/%d" rollup.pr_done total_goals)
                    ())
           end;
           let body_budget = max 0 (budget - !used) in
           let planning_cursor =
             Masc_tui_scroll.cursor_normalized ~count state.planning_cursor
           in
           let selected_goal = List.nth_opt goals planning_cursor in
           let split =
             Masc_tui_types.docked_vertical_split ~total_rows:body_budget
               ~mode:state.planning_preview_mode
               ~has_selection:(count > 0 && Option.is_some selected_goal)
           in
           let list_rows = split.list_rows in
           let table_header_rows =
             (if list_rows >= 3 then 1 else 0) + (if list_rows >= 4 then 1 else 0)
           in
           let entry_rows = max 0 (list_rows - table_header_rows) in
           let capacity = if count = 0 then 0 else min count entry_rows in
           let first =
             if capacity <= 0 || count <= capacity then 0
             else
               max 0 (min (count - capacity) (planning_cursor - (capacity / 2)))
           in
           report_drawn_list Goal_entries ~height:capacity;
           let list_header =
             if list_rows >= 3 then
               [ Doc.section_header ~width:inner ~indent:1
                   ~subtitle:(Printf.sprintf (if ko then "%s건" else "%s goals") (Masc_tui_value.Count.grouped count))
                   (text "목표" "Goals")
               ]
             else []
           in
           let phase_w = min 14 (max 8 (inner / 6)) in
           let tail_w = min 22 (max 10 (inner / 5)) in
           let prefix_w = 8 in
           let title_w = max 10 (inner - prefix_w - phase_w - tail_w - 4) in
           let col_header =
             if list_rows >= 4 then
               let phase_header =
                 match state.planning_sort with
                 | Planning_sort_phase_priority ->
                     text "단계 \xe2\x86\x93" "Phase \xe2\x86\x93"
                 | Planning_sort_updated | Planning_sort_due ->
                     text "단계" "Phase"
               in
               let tail_header =
                 match state.planning_sort with
                 | Planning_sort_due ->
                     if tail_w >= 13 then
                       text "연결 · 기한 \xe2\x86\x91" "Tasks / Due \xe2\x86\x91"
                     else text "기한 \xe2\x86\x91" "Due \xe2\x86\x91"
                 | Planning_sort_phase_priority | Planning_sort_updated ->
                     text "연결 · 기한" "Tasks / Due"
               in
               [ Theme.recede ()
                 ^ fit_width
                     (Printf.sprintf "  %s %s  %s  %s"
                        (fit_width (text "우선" "Prio") 5)
                        (fit_width (text "제목" "Goal") title_w)
                        (fit_width phase_header phase_w)
                        (fit_width tail_header tail_w))
                     inner
                 ^ Ansi.reset
               ]
             else []
           in
           let entry_lines =
             if count = 0 then
               if entry_rows > 0 then
                 [ "  " ^ Theme.recede ()
                   ^ text
                       (if snapshot.pl_goals = [] then "아직 Goal 없음"
                        else "필터에 맞는 Goal 없음 · f:필터")
                       (if snapshot.pl_goals = [] then "No Goals in this reading"
                        else "No Goals match · f:filter")
                   ^ Ansi.reset
                 ]
               else []
             else
               goals
               |> List.mapi (fun index goal -> index, goal)
               |> List.drop first
               |> List.take capacity
               |> List.map (fun (index, (goal : planning_goal)) ->
                    let selected = index = planning_cursor in
                    let pointer = if selected then "\xe2\x80\xba " else "  " in
                    let mark = Masc_tui_value.Mark.glyph (planning_phase_mark goal.pg_phase) in
                    let mark_sgr = planning_phase_color goal.pg_phase in
                    let prio = fit_width (Printf.sprintf "P%d" goal.pg_priority) 3 in
                    let phase = planning_phase_label ~ko goal.pg_phase in
                    let due_opt = planning_due_clause ~ko (Planning_due.standing ~now goal) in
                    let open_note, open_style = planning_open_note state goal in
                    let tail_raw, tail_sgr =
                      match due_opt, open_note with
                      | Some words, "" -> words, Theme.warn ()
                      | Some words, note -> note ^ " · " ^ words, open_style
                      | None, "" -> Masc_tui_theme.Glyph.no_value, Theme.recede ()
                      | None, note -> note, open_style
                    in
                    let title_fit = fit_width (Terminal_text.single_line goal.pg_title) title_w in
                    let phase_fit = fit_width phase phase_w in
                    let tail_fit = fit_width tail_raw tail_w in
                    let styled =
                      Printf.sprintf "%s%s%s%s %s %s%s%s  %s%s%s  %s%s%s"
                        pointer mark_sgr mark Ansi.reset prio
                        Ansi.bold title_fit Ansi.reset
                        mark_sgr phase_fit Ansi.reset
                        tail_sgr tail_fit Ansi.reset
                    in
                    paint_goal_table_row ~width:inner ~selected ~current styled)
           in
           if count > 0 then
             c.position
               (Masc_tui_value.Position.row ~selected:(Some planning_cursor)
                  ~total:count);
           let pad_rows =
             max 0 (list_rows - List.length list_header - List.length col_header - List.length entry_lines)
           in
           let preview_lines =
             if split.preview_rows <= 0 then []
             else
               match selected_goal with
               | None -> []
               | Some goal ->
                   let stage_label =
                     match state.planning_preview_mode with
                     | Preview_compact -> text "미리보기 확장" "expand"
                     | Preview_half -> text "최대" "full"
                     | Preview_full -> text "접기" "compact"
                   in
                   let body =
                     planning_preview_lines state ~now ~cells:(max 1 (inner - 1))
                       ~rows:(max 1 (split.preview_rows - 3)) goal
                   in
                   Doc.docked_preview ~width:inner ~height:split.preview_rows
                     ~indent:1
                     ~eyebrow:(text "선택한 목표" "Selected Goal")
                     ~meta:(Printf.sprintf "P%d · %s" goal.pg_priority (planning_phase_label ~ko goal.pg_phase))
                     ~footer_hints:
                       [ { Card.key = "Space"; label = stage_label }
                       ; { Card.key = "Enter"; label = text "상세" "open" }
                       ; { Card.key = "Esc"; label = text "닫기/뒤로" "back" }
                       ]
                     body
           in
           List.iter push
             (list_header @ col_header @ entry_lines @ List.init pad_rows (fun _ -> "") @ preview_lines)))

let planning_measurement_lines (state : state) ~width (goal : planning_goal) =
  let text ko en = ui_text state ~ko ~en in
  let line tone text = Planning_detail.wrapped ~width tone text in
  let unavailable reason =
    line Planning_detail.Unreadable
      ((text "실제 측정 조회 실패: " "Actual measurement unavailable: ") ^ Terminal_text.single_line reason)
  in
  if Option.is_none goal.pg_criterion_revision then []
  else match state.overview_goals with
  | Goals_unread -> line Planning_detail.Waiting (text "실제 측정 미조회" "Actual measurement not observed")
  | Goals_failed reason -> unavailable reason
  | Goals_read goals ->
      (match List.find_opt
               (fun (row : Tui_decode.overview_goal) ->
                 String.equal row.og_id goal.pg_id) goals with
       | None -> unavailable (text "현재 측정 목록에 목표 없음" "Goal missing from the current measurement tree")
       | Some row ->
           if not (Option.equal String.equal goal.pg_criterion_revision
                        row.og_criterion_revision)
              || not (Goal_measure.equal goal.pg_measure row.og_measure)
              || not (String.equal goal.pg_procedure row.og_procedure)
           then unavailable (text "목표 목록과 측정 목록의 기준 버전 또는 목표값이 다름" "criterion revision or target differs between Work and the Goal tree")
           else
             let tasks =
               line Planning_detail.Quiet
                 (Printf.sprintf (if state.ui_language = Lang_ko then "연결 작업: %d/%d 완료 · 목표 측정과 별개" else "Linked Tasks: %d/%d done (separate from the measurement)")
                    row.og_task_done_count row.og_task_count)
             in
             (match row.og_measurement with
              | Goal_measurement_unread ->
                  line Planning_detail.Waiting (text "실제 측정 미조회" "Actual measurement not read") @ tasks
              | Goal_measurement_not_recorded ->
                  line Planning_detail.Quiet (text "기록된 실제 측정 없음" "No actual measurement recorded") @ tasks
              | Goal_measurement_unavailable reason -> unavailable reason @ tasks
              | Goal_measurement_reported { value; evidence; actor; recorded_at } ->
                  (* "Measured:", not "Evidence:": this row is the goal tree's
                     measurement provenance, and on a confirmation screen the
                     same label already names the proof's evidence. *)
                  line Planning_detail.Proven
                    ((text "실제값: " "Actual: ") ^ Terminal_text.single_line value ^ (text " (보고된 값)" " (reported)"))
                  @ line Planning_detail.Note
                      ((text "측정 근거: " "Measured: ") ^ Terminal_text.single_line evidence)
                  @ line Planning_detail.Quiet
                      ((text "측정 주체: " "Measured by: ") ^ Terminal_text.single_line actor
                       ^ " · " ^ (text "기록 시각: " "recorded: ") ^ wire_moment recorded_at)
                  @ tasks))

let planning_confirmation_view (state : state) ~goal_id =
  let ko = state.ui_language = Lang_ko in
  let text ko en = ui_text state ~ko ~en in
  match state.goal_confirmation with
  | Planning_detail.Inspecting read ->
      let view = Planning_detail.confirmation_view_for read ~goal_id in
      let view = match view with
        | (Ready _ | Stale _ | Failed _) when state.workspace_identity <> Workspace_identity_match ->
            Masc_tui_fetched.Failed
              (String.capitalize_ascii (workspace_identity_unconfirmed ~ko)
               ^ text " · 근거를 다시 조회하세요" " · read the proof again")
        | (Ready confirmation | Stale (confirmation, _))
          when not (Masc_tui_http.credential_owner_is_current confirmation.credential_owner) ->
            Masc_tui_fetched.Failed (text "인증 정보 변경 · 근거를 다시 조회하세요" "Credential changed · read the proof again")
        | (Ready confirmation | Stale (confirmation, _))
          when not (Option.exists (fun identity -> identity.sid_runtime_instance_id = Some confirmation.runtime_instance_id) state.server_identity) ->
            Masc_tui_fetched.Failed (text "서버 변경 · 근거를 다시 조회하세요" "Server changed; read the proof again")
        | Stale (confirmation, error) ->
            Stale (confirmation, Planning_detail.confirmation_read_error_message ~ko:(state.ui_language = Lang_ko)
              ~credential_is_current:Masc_tui_http.credential_owner_is_current error)
        | Failed error ->
            Failed (Planning_detail.confirmation_read_error_message ~ko:(state.ui_language = Lang_ko)
              ~credential_is_current:Masc_tui_http.credential_owner_is_current error)
        | Ready confirmation -> Ready confirmation
        | Loading -> Loading
        | Absent -> Absent in
      `Inspect view
  | Planning_detail.Submitting (submitted_goal, _) when String.equal submitted_goal goal_id -> `Submitting
  | Planning_detail.Submitting _ -> `Inspect Absent

let planning_detail_action_rows ~ko ~cols ~armed ~drop_reason (goal : planning_goal) =
  let text korean english = if ko then korean else english in
  let inner_w = max 1 (framed_inner_width cols - 2) in
  let footer_keys =
    let base =
      Goal_phase.Public_action.all
      |> List.filter (planning_goal_offers_action goal)
      |> List.map (fun action ->
           { Card.key = planning_action_key action
           ; label = planning_action_label ~ko action
           })
    in
    let extra =
      if not (planning_goal_has_valid_id goal) then []
      else if Goal_phase.moves_goal ~phase:goal.pg_phase ~action:Goal_phase.Confirm_completion
      then [ { Card.key = "a"; label = text "근거 최종 확인" "confirm proof" } ]
      else if goal.pg_phase = Goal_phase.Completed
      then [ { Card.key = "a"; label = text "확인 조회" "inspect proof" } ]
      else []
    in
    extra @ base
  in
  let _, next_step = planning_next_step ~ko goal in
  let role =
    match goal.pg_proof with
    | Tui_decode.Proof_refuted _ -> Masc_tui_theme.Panel_attention
    | Tui_decode.
        ( Proof_idle | Proof_pending | Proof_proven _ | Proof_stale _
        | Proof_unreadable _ ) -> (
        match goal.pg_phase with
        | Goal_phase.Awaiting_confirmation | Goal_phase.Blocked _ ->
            Masc_tui_theme.Panel_attention
        | Goal_phase.Executing | Goal_phase.Verifying ->
            Masc_tui_theme.Panel_fleet
        | Goal_phase.Completed | Goal_phase.Dropped | Goal_phase.Paused _ ->
            Masc_tui_theme.Panel_neutral)
  in
  let status =
    { Card.symbol = Card.Mark (planning_phase_mark goal.pg_phase)
    ; word = planning_phase_label ~ko goal.pg_phase
    ; tone = planning_phase_color goal.pg_phase
    }
  in
  let summary_clauses =
    [ text "목표값 " "Target " ^ Planning_detail.measure_text goal.pg_measure
    ; Printf.sprintf "P%d" goal.pg_priority
    ]
  in
  let card_rows =
    Doc.action_callout_card ~ko ~width:inner_w ~role
      ~title:(text "다음 행동" "Next Action")
      ~status ~next_step ~summary_clauses ~footer_keys
    |> List.map (fun row -> "  " ^ row)
  in
  card_rows
  |> fun rows -> rows @ (if planning_goal_has_valid_id goal then [] else
       Message_layout.wrap_words ~max_cells:inner_w
         (text "목표 ID가 비어 있거나 앞뒤 공백이 있습니다 · 상태를 바꿀 수 없습니다." "Goal ID is blank or has disallowed surrounding whitespace; lifecycle actions are unavailable.")
       |> List.map (fun line -> "  " ^ Theme.warn () ^ line ^ Ansi.reset))
  |> fun rows -> rows @ (match armed with
       | None -> []
       | Some action ->
           Message_layout.wrap_words ~max_cells:inner_w
             (Printf.sprintf (if ko then "확인 대기: %s [%s] · 다시 누르면 제출, 다른 키는 취소" else "Armed: %s [%s] · press again to submit; other keys cancel")
                (planning_action_label ~ko action) (planning_action_key action))
           |> List.map (fun line -> "  " ^ wrap_style (Theme.warn () ^ Ansi.bold) line))
  |> fun rows -> rows @ (match drop_reason with
       | None -> []
       | Some reason ->
           Message_layout.wrap_words ~max_cells:inner_w
             (Printf.sprintf (if ko then "중단 사유: %s_ · Enter:중단 요청" else "Drop reason: %s_ · Enter requests drop")
                (Terminal_text.single_line reason))
           |> List.map (fun line -> "  " ^ wrap_style (Theme.warn ()) line))

(* The proof block sits two cells in. Its rows arrive wrapped by
   [Planning_detail] at [planning_proof_width], which leaves room for that
   lead, so nothing here wraps again: a second wrap split rows the first one
   had filled and left one- or two-word rows behind. *)
let planning_proof_lead = "  "

let planning_proof_width ~width =
  max 1 (width - Message_layout.display_width planning_proof_lead)

let planning_proof_rows lines =
  List.map (fun (line : Planning_detail.line) ->
    { line with text = planning_proof_lead ^ line.text }) lines

let planning_measurement_kv (state : state) ~doc_width (goal : planning_goal) =
  let ko = state.ui_language = Lang_ko in
  let text k e = ui_text state ~ko:k ~en:e in
  let prestyled rows =
    List.map (fun s -> { Planning_detail.tone = Prestyled; text = s }) rows
  in
  let kv_rows = Doc.kv_rows ~width:doc_width ~indent:2 ~max_label_cells:16 in
  let unreconciled reason =
    kv_rows [ Doc.kv ~tone:(Theme.warn ()) (text "실제 측정" "Measured") reason ]
    |> prestyled
  in
  if Option.is_none goal.pg_criterion_revision then []
  else match state.overview_goals with
  | Goals_unread ->
      kv_rows [ Doc.kv ~tone:(Theme.warn ()) (text "실제 측정" "Measured") (text "실제 측정 미조회" "Actual measurement not observed") ]
      |> prestyled
  | Goals_failed reason ->
      unreconciled (text "조회 실패: " "Unavailable: " ^ Terminal_text.single_line reason)
  | Goals_read goals ->
      (match List.find_opt (fun (row : Tui_decode.overview_goal) -> String.equal row.og_id goal.pg_id) goals with
       | None -> unreconciled (text "현재 측정 목록에 목표 없음" "Goal missing from measurement tree")
       | Some row ->
           if not (Option.equal String.equal goal.pg_criterion_revision row.og_criterion_revision)
              || not (Goal_measure.equal goal.pg_measure row.og_measure)
              || not (String.equal goal.pg_procedure row.og_procedure)
           then unreconciled (text "목표 목록과 측정 목록의 기준 버전 또는 목표값이 다름" "Criterion revision or target differs from Goal tree")
           else
             let tasks_str =
               Printf.sprintf
                 (if ko then "%d/%d 완료 · 목표 측정과 별개" else "%d/%d done (separate from measurement)")
                 row.og_task_done_count row.og_task_count
             in
             let fields =
               match row.og_measurement with
               | Goal_measurement_unread ->
                   [ Doc.kv ~tone:(Theme.warn ()) (text "실제 측정" "Measured") (text "미조회" "not read")
                   ; Doc.kv ~tone:(Theme.recede ()) (text "연결 작업" "Linked tasks") tasks_str
                   ]
               | Goal_measurement_not_recorded ->
                   [ Doc.kv ~tone:(Theme.recede ()) (text "실제 측정" "Measured") (text "기록된 측정 없음" "no measurement recorded")
                   ; Doc.kv ~tone:(Theme.recede ()) (text "연결 작업" "Linked tasks") tasks_str
                   ]
               | Goal_measurement_unavailable reason ->
                   [ Doc.kv ~tone:(Theme.warn ()) (text "실제 측정" "Measured") (Terminal_text.single_line reason)
                   ; Doc.kv ~tone:(Theme.recede ()) (text "연결 작업" "Linked tasks") tasks_str
                   ]
               | Goal_measurement_reported { value; evidence; actor; recorded_at } ->
                   [ Doc.kv ~tone:(Theme.ok () ^ Ansi.bold) (text "실제값" "Actual")
                       (Terminal_text.single_line value ^ text " (보고된 값)" " (reported)")
                   ; Doc.kv (text "측정 근거" "Evidence") (Terminal_text.single_line evidence)
                   ; Doc.kv ~tone:(Theme.recede ()) (text "측정 주체" "Recorded by")
                       (Terminal_text.single_line actor ^ " · " ^ wire_moment recorded_at)
                   ; Doc.kv ~tone:(Theme.recede ()) (text "연결 작업" "Linked tasks") tasks_str
                   ]
             in
             kv_rows fields |> prestyled)

let planning_detail_content (state : state) ~confirmation ~cols (goal : planning_goal) =
  let ko = state.ui_language = Lang_ko in
  let text korean english = if ko then korean else english in
  let inner_w = max 1 (framed_inner_width cols) in
  let width = max 1 (inner_w - 2) in
  let prestyled rows =
    List.map (fun s -> { Planning_detail.tone = Prestyled; text = s }) rows
  in
  let line_p text = { Planning_detail.tone = Prestyled; text } in
  let section ?badge ?badge_tone title =
    [ line_p (Doc.section_rule ~width:inner_w ~indent:2 ?badge ?badge_tone title) ]
  in
  let kv_block ?label_style ?max_label_cells fields =
    Doc.kv_rows ~width:inner_w ~indent:2 ?label_style ?max_label_cells fields |> prestyled
  in
  let optional = function Some value -> value | None -> Masc_tui_theme.Glyph.no_value in
  let due_standing = Planning_due.standing ~now:(Ptime_clock.now ()) goal in
  let due_tone =
    match due_standing with
    | Planning_due.Due_passed | Planning_due.Unreadable_due _ -> Theme.warn ()
    | Planning_due.Due_ahead | Planning_due.Not_in_progress | Planning_due.No_due -> ""
  in
  let due = optional goal.pg_due_date
    ^ (match planning_due_clause ~ko due_standing with
       | None -> ""
       | Some words -> " · " ^ words) in
  let gap = [ { Planning_detail.tone = Planning_detail.Quiet; text = "" } ] in
  let title_rows =
    Text_block.rows ~max_cells:(max 1 (inner_w - 4)) goal.pg_title
    |> List.map (fun row -> line_p ("  " ^ Ansi.bold ^ row ^ Ansi.reset))
  in
  let overview =
    section (text "목표와 성공 조건" "Goal and criterion")
    @ title_rows
    @ kv_block ~max_label_cells:14
        [ Doc.kv ~tone:(Theme.ok () ^ Ansi.bold) (text "목표값" "Measure") (Planning_detail.measure_text goal.pg_measure)
        ; Doc.kv (text "측정 방법" "Procedure") goal.pg_procedure
        ; Doc.kv ~tone:due_tone (text "기한" "Due") due
        ; Doc.kv ~tone:(if goal.pg_priority <= 1 then Theme.warn () ^ Ansi.bold else "")
            (text "우선순위" "Priority") (Printf.sprintf "P%d" goal.pg_priority)
        ]
  in
  let metadata =
    gap
    @ section (text "상세 정보" "Details")
    @ kv_block ~max_label_cells:16
        ([ Doc.kv ~tone:(Theme.recede ()) (text "목표 ID" "Goal ID") goal.pg_id ]
         @ List.filter_map (fun (label, value) ->
             Option.map (fun v -> Doc.kv ~tone:(Theme.recede ()) label (wire_moment v)) value)
             [ (text "생성" "Created"), goal.pg_created_at
             ; (text "갱신" "Updated"), goal.pg_updated_at
             ; (text "검토" "Reviewed"), goal.pg_last_review_at
             ]
         @ [ Doc.kv ~tone:(Theme.recede ()) (text "링크" "Link") (Link.reference Goal goal.pg_id) ]
         @ (match state.planning with
            | None -> []
            | Some snapshot ->
                [ Doc.kv ~tone:(Theme.recede ()) (text "목록 관측 시각" "List observed")
                    (wire_moment snapshot.pl_generated_at) ]))
  in
  let request_results =
    (match List.assoc_opt goal.pg_id state.goal_action_errors with
     | Some (Request_failed error) ->
         kv_block [ Doc.kv ~tone:(Theme.bad ()) (text "실패" "Error") error ]
     | Some (Request_withdrawn refusal) ->
         Doc.prose_block ~width:inner_w ~indent:2 ~guide_style:(Theme.bad ()) ~tone:(Theme.bad ())
           (workspace_refusal_text ~ko ~request:Kept_request.Goal_transition refusal)
         |> prestyled
     | None -> [])
    @ (state.goal_action_receipts |> List.filter_map (fun receipt ->
         if not (String.equal receipt.gar_goal_id goal.pg_id) then None
         else
           Some
             (kv_block
                [ Doc.kv ~tone:(Theme.warn ()) (text "요청 결과" "Request result")
                    (match goal_receipt_answer state receipt with
                     | `Kept_back notice ->
                         Printf.sprintf "%s · %s · %s" notice receipt.gar_workspace receipt.gar_ticket
                     | `Answer answer ->
                         Printf.sprintf "%s · %s · %s" receipt.gar_workspace receipt.gar_ticket answer)
                ]))
       |> List.concat)
  in
  let linked_tasks = List.filter (fun (row : Tui_decode.task) -> List.mem goal.pg_id row.goal_ids) state.tasks in
  let linked =
    let scope, warning = work_task_scope state in
    let links_complete, link_notices = match state.goal_task_links with
      | Goal_links_read _ -> true, []
      | Goal_links_not_read -> false,
          kv_block [ Doc.kv ~tone:(Theme.warn ()) (text "목표 연결" "Goal links") (ui_text state ~ko:"연결 정보 미조회" ~en:"links not read") ]
      | Goal_links_read_failed reason -> false,
          kv_block [ Doc.kv ~tone:(Theme.warn ()) (text "목표 연결" "Goal links") reason ] in
    let complete = links_complete && work_task_rows_complete state in
    let count = List.length linked_tasks in
    let count_text =
      if complete then Printf.sprintf (if ko then "%s건" else "%s") (Masc_tui_value.Count.grouped count)
      else if count = 0 then ui_text state ~ko:"일부 관측" ~en:"partial"
      else if ko then Printf.sprintf "%s건 (일부)" (Masc_tui_value.Count.grouped count)
      else Printf.sprintf "%s (partial)" (Masc_tui_value.Count.grouped count)
    in
    let task_rows =
      List.concat_map (fun (task : Tui_decode.task) ->
        let icon = task_status_icon task.status in
        let icon_style = task_state_style task.status in
        let status_word = task_status_word state task.status in
        let header =
          Printf.sprintf "  %s%s%s %s%s%s  %s%s%s  "
            icon_style icon Ansi.reset
            (Theme.recede ()) (Masc.Tui_terminal_text.sanitize_terminal_text task.id) Ansi.reset
            icon_style (Masc.Tui_terminal_text.sanitize_terminal_text status_word) Ansi.reset
        in
        let lead_w = Message_layout.display_width (Masc_tui_theme.strip_sgr header) in
        let title_w = max 1 (inner_w - lead_w) in
        let wrapped_title = Text_block.rows ~max_cells:title_w task.title in
        (match wrapped_title with
         | [] -> [ line_p header ]
         | first :: rest ->
             line_p (header ^ first)
             :: List.map (fun r -> line_p (String.make (min lead_w (max 0 (inner_w - 1))) ' ' ^ r)) rest))
        linked_tasks
    in
    gap
    @ section ~badge:count_text (ui_text state ~ko:"연결 작업" ~en:"Linked Tasks")
    @ (if warning then kv_block [ Doc.kv ~tone:(Theme.warn ()) (text "작업 관측" "Task reading") scope ] else [])
    @ (match state.tasks_error with
       | None -> []
       | Some reason -> kv_block [ Doc.kv ~tone:(Theme.warn ()) (text "작업 조회 범위" "Task coverage") reason ])
    @ link_notices
    @ task_rows
  in
  let proof_width = planning_proof_width ~width in
  let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
  let confirmation_rows =
    match confirmation with
    | `Submitting -> [ { Planning_detail.tone = Active; text = under_way ^ " " ^ text "근거 최종 확인 요청 중" "Sending proof confirmation" } ]
    | `Inspect (Masc_tui_fetched.Ready value) ->
        Planning_detail.confirmation_lines ~width:proof_width ~ko value
    | `Inspect Loading -> [ { Planning_detail.tone = Active; text = under_way ^ " " ^ text "확인할 근거 조회 중" "Reading the proof to confirm" } ]
    | `Inspect (Stale (_, reason) | Failed reason) -> Planning_detail.wrapped ~width:proof_width Unreadable reason
    | `Inspect Masc_tui_fetched.Absent ->
        (match goal.pg_verifier_unreconciled with Some blocked -> Planning_detail.unreconciled_lines ~ko ~width:proof_width blocked | None -> [])
        @ Planning_detail.body ~ko ~width:proof_width goal.pg_proof goal.pg_last_review_note
  in
  let proof_badge_word, proof_badge_tone =
    match goal.pg_proof with
    | Tui_decode.Proof_proven _ -> (text "검증 통과" "proven"), Theme.ok ()
    | Tui_decode.Proof_refuted _ -> (text "검증 거절" "refused"), Theme.bad ()
    | Tui_decode.Proof_pending -> (text "판정 대기" "pending"), Theme.warn ()
    | Tui_decode.Proof_stale _ -> (text "기준 변경" "stale"), Theme.recede ()
    | Tui_decode.Proof_unreadable _ -> (text "읽기 실패" "unreadable"), Theme.warn ()
    | Tui_decode.Proof_idle -> (text "판정 없음" "no verdict"), Theme.recede ()
  in
  let doc_proof_and_measurement =
    let unreconciled_doc =
      match goal.pg_verifier_unreconciled with
      | None -> []
      | Some blocked ->
          let headline =
            "  " ^ Theme.bad () ^ Ansi.bold
            ^ Masc.Tui_terminal_text.sanitize_terminal_text (Planning_detail.unreconciled_heading ~ko blocked.vu_step)
            ^ Ansi.reset
          in
          line_p headline
          :: prestyled (Doc.prose_block ~width:inner_w ~indent:2 ~guide_style:(Theme.bad ()) ~break_numbered:true blocked.vu_detail)
    in
    let evidence_prose_block tone reason_opt =
      match reason_opt with
      | None -> []
      | Some reason ->
          let guide_style =
            if String.equal tone "" then Theme.border_muted () else tone
          in
          prestyled (Doc.prose_block ~width:inner_w ~indent:2 ~guide_style ~break_numbered:true reason)
    in
    let note_block =
      match goal.pg_last_review_note with
      | None -> []
      | Some n ->
          gap
          @ [ line_p ("  " ^ Theme.recede () ^ text "검토 메모" "Review note" ^ Ansi.reset) ]
          @ prestyled (Doc.prose_block ~width:inner_w ~indent:2 ~guide_style:(Theme.recede ()) ~tone:(Theme.recede ()) n)
    in
    let proof_prose =
      match goal.pg_proof with
      | Tui_decode.Proof_proven reason ->
          evidence_prose_block (Theme.ok ()) reason
      | Tui_decode.Proof_refuted reason ->
          evidence_prose_block (Theme.bad ()) reason
      | Tui_decode.Proof_pending ->
          [ line_p ("  " ^ Theme.warn () ^ text "완료 판정 대기 중" "Verification result pending" ^ Ansi.reset) ]
      | Tui_decode.Proof_stale evidence ->
          [ line_p ("  " ^ Theme.recede () ^ text "기준 변경 · 이전 근거 보존됨" "Criterion changed; previous proof retained" ^ Ansi.reset) ]
          @ evidence_prose_block (Theme.recede ()) evidence
      | Tui_decode.Proof_unreadable detail ->
          evidence_prose_block (Theme.warn ()) detail
      | Tui_decode.Proof_idle ->
          [ line_p ("  " ^ Theme.recede () ^ text "기록된 판정 없음" "No verdict recorded on the ledger" ^ Ansi.reset) ]
    in
    let criterion_subsection =
      match goal.pg_criterion_review with
      | Tui_decode.Criterion_unchecked -> []
      | Tui_decode.Criterion_unavailable detail ->
          gap
          @ section ~badge:(text "확인 불가" "unavailable") ~badge_tone:(Theme.warn ())
              (text "도달 가능한 성공 기준" "Criterion feasibility")
          @ prestyled (Doc.prose_block ~width:inner_w ~indent:2 ~guide_style:(Theme.warn ()) ~tone:(Theme.recede ()) detail)
      | Tui_decode.Criterion_observed observed ->
          let badge_word, badge_tone, reason =
            match observed.state with
            | Tui_decode.Criterion_pending -> text "대기" "pending", Theme.warn (), observed.detail
            | Criterion_execution_pending -> text "실행 중" "executing", Theme.warn (), observed.detail
            | Criterion_execution_unknown -> text "불확실" "unknown", Theme.warn (), observed.detail
            | Criterion_judgment_pending -> text "반영 대기" "publishing", Theme.warn (), observed.detail
            | Criterion_deferred -> text "보류" "deferred", Theme.warn (), observed.detail
            | Criterion_viable reason -> text "도달 가능" "viable", Theme.ok (), Some reason
            | Criterion_needs_revision reason -> text "수정 필요" "needs revision", Theme.bad (), Some reason
            | Criterion_superseded -> text "대체됨" "superseded", Theme.recede (), observed.detail
          in
          let body =
            match reason with
            | None -> []
            | Some r ->
                prestyled
                  (Doc.prose_block ~width:inner_w ~indent:2
                     ~guide_style:(Theme.recede ()) ~break_numbered:true
                     ~tone:(Theme.recede ()) r)
          in
          let rev_kv =
            kv_block ~max_label_cells:12
              [ Doc.kv ~tone:(Theme.recede ()) (text "기준 버전" "Revision") (Masc_tui_value.Hash.short observed.criterion_revision)
              ; Doc.kv ~tone:(Theme.recede ()) (text "검토 요청" "Request") (Masc_tui_value.Hash.short observed.request_id)
              ]
          in
          gap
          @ section ~badge:badge_word ~badge_tone (text "성공 기준 검토" "Criterion review")
          @ body
          @ rev_kv
    in
    section ~badge:proof_badge_word ~badge_tone:proof_badge_tone (text "판정과 측정" "Proof and measurement")
    @ planning_measurement_kv state ~doc_width:inner_w goal
    @ (if unreconciled_doc = [] && proof_prose = [] then [] else gap)
    @ unreconciled_doc
    @ proof_prose
    @ note_block
    @ criterion_subsection
  in
  let raw_timeline =
    Planning_detail.timeline ~ko ~now:(Unix.gettimeofday ()) ~width
      ~goal_id:goal.pg_id state.goal_timeline
    |> List.map (fun (line : Planning_detail.line) ->
         match line.tone with
         | Heading -> line_p (Doc.section_rule ~width:inner_w ~indent:2 line.text)
         | Proven | Refused | Waiting | Active | Unreadable | Note | Quiet | Plain
         | Prestyled ->
             line)
  in
  let candle =
    let open Candle_goal_observation in
    let kv_opt = kv_block ~max_label_cells:16 in
    let kv_note label text_s = kv_opt [ Doc.kv ~tone:(Theme.recede ()) label text_s ] in
    let kv_warn label text_s = kv_opt [ Doc.kv ~tone:(Theme.warn ()) label text_s ] in
    let coverage =
      prestyled
        (Doc.prose_block ~width:inner_w ~indent:2 ~guide_style:(Theme.recede ())
           ~tone:(Theme.recede ())
           (text "후보 준비는 증명 기록 때 저장한 스냅샷의 작업 연결을 읽습니다. 이 원장만으로 전체 연결 이력이나 누락된 기여를 알 수 없습니다."
              "Candidate preparation reads Snapshot links saved during proof recording; this ledger cannot establish full link history or missing contributions."))
    in
    let describe ({ configuration; ledger } : Candle_goal_observation.t) =
      let config = match configuration with Enabled -> (text "켜짐" "enabled") | Off -> (text "꺼짐" "off") | Disabled -> (text "비활성 또는 읽기 실패" "disabled or unreadable") in
      let identity (id : identity) =
        kv_opt
          [ Doc.kv ~tone:(Theme.recede ()) (text "검증 요청" "Verification req") id.request_id
          ; Doc.kv ~tone:(Theme.recede ()) (text "검증 실행" "Verifier run") id.verification_run_id
          ]
      in
      let snapshot = function
        | Snapshot_matching -> []
        | Snapshot_missing -> kv_warn (text "스냅샷" "Snapshot") (text "확인된 검증 실행의 스냅샷 없음" "missing for this confirmed run")
        | Snapshot_conflicting -> kv_warn (text "스냅샷" "Snapshot") (text "확인된 검증 실행의 스냅샷 기록 충돌" "conflicting records for this confirmed run") in
      let payout = function
        | No_recorded_obligation ->
            kv_opt [ Doc.kv (text "지급" "Payout") (text "이 원장에 지급 의무 기록 없음 · 이전 이력은 미조회" "no obligation recorded in this ledger; prior history not read") ]
        | Inconsistent -> kv_warn (text "지급" "Payout") (text "원장 상태를 해석할 수 없음" "ledger state could not be interpreted")
        | Owed { identity = id; snapshot = pass; stage } ->
            kv_opt
              [ Doc.kv ~tone:(Theme.warn ()) (text "지급" "Payout")
                  (match stage with
                   | Candidates_unrecorded ->
                       (match pass with Snapshot_matching -> (text "지급 대기 · 후보 기록 없음 · 대기 사유 보고 안 됨" "owed; no candidates recorded; waiting reason not reported")
                        | Snapshot_missing | Snapshot_conflicting -> (text "지급 대기 · 스냅샷 확인 전 후보 준비 대기" "owed; candidate preparation waits for the unresolved Snapshot"))
                   | Candidates_consistent -> (text "지급 대기 · 후보 기록됨 · 정산 대기" "owed; candidates recorded; awaiting settlement")
                   | Candidates_inconsistent -> (text "지급 대기 · 기록된 후보 근거 불일치" "owed; recorded candidate evidence is inconsistent")
                   | Candidates_unchecked -> (text "지급 대기 · 기록된 후보 근거 미점검" "owed; recorded candidate evidence is not checked"))
              ]
            @ snapshot pass @ identity id
        | Held { identity = id; snapshot = pass; origin; issues } ->
            kv_opt
              [ Doc.kv ~tone:(Theme.warn ()) (text "지급" "Payout") (text "보류 · 기여 기간이 불확실함" "held: contribution window is uncertain")
              ; Doc.kv ~tone:(Theme.recede ()) (text "보류 근거" "Hold evidence")
                  (match origin with Stored -> (text "원장에 기록됨" "recorded in ledger") | Derived_candidates -> (text "기록된 후보에서 도출됨" "derived from recorded candidates"))
              ]
            @ snapshot pass @ identity id
            @ (match issues with
               | Issues_unavailable -> kv_warn (text "문제" "Issues") (text "보류 상세 보고 안 됨" "hold details not reported")
               | Complete_issues issues -> List.concat_map (fun issue ->
                   kv_warn (text "문제" "Issue") (Candle_payout.window_issue_to_string issue)) issues
               | Snapshot_independent_issues issues ->
                   List.concat_map (fun issue ->
                     kv_warn (text "문제" "Issue") (Candle_payout.window_issue_to_string issue)) issues
                   @ kv_warn (text "시간 경계" "Time boundary") (text "스냅샷이 정해지기 전에는 추가 문제를 볼 수 없음" "additional issues cannot be seen until the Snapshot is resolved"))
            @ (match origin with
               | Stored -> []
               | Derived_candidates -> kv_warn (text "후보 근거" "Candidate evidence")
                   (text "작업 범위와 후보의 일치 여부는 미점검" "Task coverage and candidate consistency have not been checked"))
        | Paid { identity = id; recorded_at; allocations } ->
            kv_opt
              ([ Doc.kv ~tone:(Theme.ok ()) (text "지급" "Payout") ((text "지급 기록 시각: " "recorded paid at ") ^ Candle_time.to_rfc3339 recorded_at) ]
               @ List.map (fun (allocation : allocation) ->
                   Doc.kv (text "기록된 배분" "Allocation")
                     (Printf.sprintf (if ko then "%s: %d.%03d Candle (가중치 %d)" else "%s: %d.%03d Candle (weight %d)")
                        allocation.keeper (allocation.amount_milli / 1000) (allocation.amount_milli mod 1000) allocation.weight)) allocations
               @ [ Doc.kv ~tone:(Theme.recede ()) (text "금액" "Amounts") (text "지급 당시 금액 · 현재 잔액과 다를 수 있음" "at payout; current balances may differ") ])
            @ identity id
        | Unattributed { identity = id; recorded_at; reason } ->
            kv_opt
              [ Doc.kv (text "지급" "Payout")
                  ((match reason with
                    | No_candidates -> (text "지급 대상 후보 없음" "no payable candidates")
                    | All_unrelated -> (text "후보 작업이 무관함" "candidate tasks unrelated")
                    | No_related_keepers -> (text "관련 Keeper 없음" "no related Keepers")
                    | Window_released -> (text "해제된 기여 기간이 모호함" "released window stayed ambiguous"))
                   ^ " (" ^ Candle_time.to_rfc3339 recorded_at ^ ")")
              ]
            @ identity id
        | Payout_failed { identity = id } ->
            kv_opt [ Doc.kv ~tone:(Theme.bad ()) (text "지급" "Payout") (text "지급 기한을 읽지 못한 실패 기록" "failure recorded as unreadable due date") ]
            @ identity id
      in
      kv_opt [ Doc.kv (text "마지막 설정 관측" "Last config") config ]
      @ (match ledger with
         | Missing -> kv_warn (text "원장" "Ledger") (text "원장 파일 없음 · 이전 이력은 읽을 수 없음" "file absent; earlier history cannot be read")
         | Unavailable reason -> kv_warn (text "원장" "Ledger")
             (match reason with Locked -> (text "잠김" "locked") | Unreadable -> (text "읽기 실패" "unreadable") | Invalid_row -> (text "유효하지 않은 행" "invalid row"))
         | Observed result -> payout result)
      @ (match ledger with
         | Observed (Owed _ | Held _ | Paid _ | Unattributed _ | Payout_failed _) -> coverage
         | Missing | Unavailable _ | Observed (No_recorded_obligation | Inconsistent) -> [])
      @ kv_note (text "모델 실행" "Model exec") (text "지급 원장에서 관측하지 않음" "not observed from payout ledger")
    in
    let reading = Masc_tui_fetched.view_for ~equal:String.equal state.goal_candle ~key:goal.pg_id in
    let kv_active label s = kv_opt [ Doc.kv ~tone:(Theme.info ()) label (under_way ^ " " ^ s) ] in
    let rows =
      if not (server_authority_ready state) then
        kv_warn "Candle" (workspace_identity_unconfirmed ~ko)
      else match reading with
      | Masc_tui_fetched.Absent -> kv_note "Candle" (text "미조회" "not read")
      | Loading -> kv_active "Candle" (text "지급 원장 조회 중" "reading payout ledger")
      | Failed (Goal_candle_unread error) ->
          if Masc_tui_fetched.in_flight state.goal_candle then
            kv_active "Candle" (text "조회 중 · 이전 조회 실패: " "reading; previous read failed: " ^ error)
          else kv_warn "Candle" error
      | Failed (Goal_candle_kept_back notice) ->
          if Masc_tui_fetched.in_flight state.goal_candle then
            kv_active "Candle" (text "지급 원장 조회 중" "reading payout ledger")
          else kv_warn "Candle" notice
      | Ready (owner, _, _) | Stale ((owner, _, _), _) when not (Masc_tui_http.credential_owner_is_current owner) ->
          if Masc_tui_fetched.in_flight state.goal_candle then
            kv_active "Candle" (text "조회 중 · 이전 인증 정보의 관측은 표시하지 않음" "reading; previous credential observation hidden")
          else kv_warn "Candle" (text "인증 정보 변경 · 다시 조회하세요" "credential changed; read again")
      | Ready (_, instance, _) | Stale ((_, instance, _), _)
        when not (Option.exists (fun identity -> identity.Tui_decode.sid_runtime_instance_id = Some instance) state.server_identity) ->
          kv_warn "Candle" (text "서버 인스턴스 변경 · 다시 조회하세요" "server instance changed; read again")
      | Ready (_, _, observation) ->
          if Masc_tui_fetched.in_flight state.goal_candle then
            kv_active "Candle" (text "지급 원장 조회 중" "reading payout ledger")
          else describe observation
      | Stale (_, Goal_candle_unread error) ->
          if Masc_tui_fetched.in_flight state.goal_candle then
            kv_active "Candle" (text "조회 중 · 이전 조회 실패: " "reading; previous read failed: " ^ error)
          else kv_warn "Candle" error
      | Stale (_, Goal_candle_kept_back notice) ->
          if Masc_tui_fetched.in_flight state.goal_candle then
            kv_active "Candle" (text "지급 원장 조회 중" "reading payout ledger")
          else kv_warn "Candle" notice
    in
    gap
    @ section ~badge:(Printf.sprintf "[%s:%s]" Masc_tui_keys.goal_candle_refresh_key (text "조회" "read"))
        (text "Candle 지급 기록" "Candle payout record")
    @ rows
  in
  (* Confirmation stays at physical row zero: the presented-row guard below
     measures this exact block. When not inspecting confirmation, the modern
     structured document presents Summary -> Measurement+Proof -> Linked Tasks. *)
  let before_candle =
    match confirmation with
    | `Inspect Masc_tui_fetched.Absent ->
        request_results @ overview @ gap @ doc_proof_and_measurement @ linked
    | `Submitting | `Inspect (Masc_tui_fetched.Ready _ | Loading | Stale _ | Failed _) ->
        let measurement = planning_measurement_lines state ~width:proof_width goal in
        let criterion_review = Planning_detail.criterion_review_lines ~width:proof_width ~ko goal.pg_criterion_review in
        let wrapped_proof = planning_proof_rows (confirmation_rows @ measurement @ criterion_review) in
        wrapped_proof @ request_results @ gap @ overview @ linked
  in
  let after_candle = metadata @ raw_timeline in
  before_candle @ candle @ after_candle,
  List.length before_candle + List.length gap

let planning_detail_lines state ~confirmation ~cols goal =
  fst (planning_detail_content state ~confirmation ~cols goal)

let planning_detail_candle_scroll (state : state) (goal : planning_goal) =
  let _, cols = get_terminal_size () in
  snd (planning_detail_content state ~cols goal
    ~confirmation:(planning_confirmation_view state ~goal_id:goal.pg_id))

let planning_detail_header_rows (state : state) ~cols (goal : planning_goal) =
  let ko = state.ui_language = Lang_ko in
  let phase = "  " ^ bracketed ~max_cells:(planning_phase_column ~ko)
      (planning_phase_label ~ko goal.pg_phase) in
  let header = planning_workspace_title state ~cols ~tab:Planning_goals ~window:""
    ~after:phase ^ phase in
  header :: planning_stale_notice_rows state ~cols

let planning_detail_chrome_rows = max 0 (framed_chrome_rows - 2)

let planning_detail_height ~rows ~header_rows ~action_rows ~count =
  Masc_tui_scroll.content_height ~rows ~chrome:(planning_detail_chrome_rows + max 0 (header_rows - 1) + action_rows)
    ~count ~preview_keep:None

let planning_detail_fits ~rows ~header_rows ~action_rows ~count =
  let height = planning_detail_height ~rows ~header_rows ~action_rows ~count in
  planning_detail_chrome_rows + max 0 (header_rows - 1) + action_rows + height <= rows

let planning_detail_sheet_available ~rows ~header_rows ~base_action_rows =
  max 0 (rows - planning_detail_chrome_rows - max 0 (header_rows - 1) - base_action_rows - 1)
;;

let planning_detail_sheet_rows ~rows ~cols ~header_rows ~base_action_rows ~goal_id (state : state) =
  let has_op =
    List.mem_assoc goal_id state.goal_action_inflight
    || (match state.goal_confirmation with
        | Masc_tui_planning_detail.Submitting (id, _) -> String.equal id goal_id
        | Inspecting _ -> false)
  in
  if not has_op then 0
  else
    progress_sheet_height
      ~available:(planning_detail_sheet_available ~rows ~header_rows ~base_action_rows)
      ~cols:(framed_inner_width cols)
      { ps_title = ""
      ; ps_detail = None
      ; ps_started_at = None
      ; ps_meter = None
      ; ps_action_hint = None
      ; ps_blocking = true
      }
;;

let planning_detail_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  match state.planning_mode, state.planning with
  | Planning_detail goal_id, Some snapshot ->
      (match List.find_opt (fun (goal : planning_goal) -> String.equal goal.pg_id goal_id) snapshot.pl_goals with
       | None -> 0, max 1 (rows - planning_detail_chrome_rows)
       | Some goal ->
           let header_rows = List.length (planning_detail_header_rows state ~cols goal) in
           let base_action_rows =
             List.length (planning_detail_action_rows ~ko:(state.ui_language = Lang_ko) ~cols ~armed:(goal_action_armed_for state goal_id)
               ~drop_reason:(goal_drop_reason_for state goal_id) goal)
           in
           let action_rows =
             base_action_rows
             + planning_detail_sheet_rows ~rows ~cols ~header_rows ~base_action_rows ~goal_id state
           in
           let count = List.length (planning_detail_lines state ~cols goal
             ~confirmation:(planning_confirmation_view state ~goal_id)) in
           if planning_detail_fits ~rows ~header_rows ~action_rows ~count
           then count, planning_detail_height ~rows ~header_rows ~action_rows ~count
           else 0, 1)
  | Planning_list, _ | Planning_detail _, None -> 0, max 1 (rows - planning_detail_chrome_rows)

let planning_detail_pane (state : state) ~armed ~confirmation ~rows ~cols (goal : planning_goal) buf =
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let headers = planning_detail_header_rows state ~cols goal in
  let actions = planning_detail_action_rows ~ko ~cols ~armed
      ~drop_reason:(goal_drop_reason_for state goal.pg_id) goal in
  let progress_sheet = planning_progress_sheet ~now ~goal_id:goal.pg_id state in
  let sheet_avail =
    planning_detail_sheet_available ~rows ~header_rows:(List.length headers)
      ~base_action_rows:(List.length actions)
  in
  let sheet_lines =
    match progress_sheet with
    | None -> []
    | Some sheet ->
        render_progress_sheet ~ko ~now
          ~available:sheet_avail
          ~width:(framed_inner_width cols) sheet
  in
  let lines, candle_scroll = planning_detail_content state ~confirmation ~cols goal in
  let count = List.length lines in
  let height = planning_detail_height ~rows ~header_rows:(List.length headers)
    ~action_rows:(List.length actions + List.length sheet_lines) ~count in
  let requested_scroll = match state.planning_scroll with
    | Planning_scroll_offset value -> value
    | Planning_scroll_candle _ -> candle_scroll in
  let scroll = Masc_tui_scroll.normalize ~count ~height requested_scroll in
  (match headers with
   | [] -> ()
   | title :: rest ->
       let title =
         match progress_sheet with
         | None -> title
         | Some sheet ->
             title ^ "  " ^ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title
       in
       box_line buf cols
         (titled_row ~cols state ~title
            ~position:(Masc_tui_value.Position.window ~first:scroll ~shown:height ~total:count));
       List.iter (box_line buf cols) rest);
  box_divider buf cols;
  List.iter (box_line buf cols) actions;
  let window = Rows.of_list ~first:scroll ~height lines in
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some { Planning_detail.tone = Prestyled; text } -> box_line buf cols text
    | Some
        { Planning_detail.tone =
            ( Proven | Refused | Waiting | Active | Unreadable | Note | Quiet
            | Plain | Heading ) as tone
        ; text
        } ->
        box_line_styled buf cols ~style:(planning_detail_tone tone) text
  done;
  List.iter (box_line buf cols) sheet_lines;
  let seen = match confirmation with
    | `Inspect (Masc_tui_fetched.Ready proof) ->
        let width = max 1 (framed_inner_width cols - 2) in
        let last = List.length (planning_proof_rows
          (Planning_detail.confirmation_lines ~width:(planning_proof_width ~width)
             ~ko proof)) - 1 in
        if last >= scroll && last < scroll + height then Some proof else None
    | `Submitting | `Inspect (Masc_tui_fetched.Absent | Loading | Stale _ | Failed _) -> None in
  scroll, seen
;;

(* The goal list stays beside its detail. Opening one used to replace the
   other, so reading a row cost the reader their place in the list. Below the
   split width there is no room for both and the detail keeps the screen,
   which is the rule the Board read pane already follows. *)
let render_planning_detail (state : state)
    ~(armed : Goal_phase.Public_action.t option) ~confirmation (goal : planning_goal) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let header_rows = List.length (planning_detail_header_rows state ~cols goal) in
  let base_action_rows =
    List.length (planning_detail_action_rows ~ko:(state.ui_language = Lang_ko) ~cols ~armed
      ~drop_reason:(goal_drop_reason_for state goal.pg_id) goal)
  in
  let action_rows =
    base_action_rows
    + planning_detail_sheet_rows ~rows ~cols ~header_rows ~base_action_rows ~goal_id:goal.pg_id state
  in
  let count = List.length (planning_detail_lines state ~confirmation ~cols goal) in
  if not (planning_detail_fits ~rows ~header_rows ~action_rows ~count) then begin
    let buf = Buffer.create 96 in
    Buffer.add_string buf (fit_width (ui_text state ~ko:"목표 상세를 읽으려면 창을 늘려 주세요" ~en:"Goal detail needs more room; resize to read and act") cols);
    Buffer.add_char buf '\n';
    finish_terminal_too_small_frame ~cursor:Frame_presenter.Hidden ~rows:terminal_rows ~cols buf
  end else begin
  let buf = Buffer.create 4096 in
  let scroll, seen =
    planning_detail_pane state ~armed ~confirmation ~rows ~cols goal buf
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (match goal_drop_reason_for state goal.pg_id with
          | Some _ -> Masc_tui_keys.footer_hints_goal_drop_reason ~lang:state.ui_language
          | None -> Masc_tui_keys.footer_hints_planning_goal_detail ~lang:state.ui_language));
  finish_surface state ~clamped:(Planning_confirmation_scroll (scroll, seen))
      ~surface_key:"planning-detail" ~rows:terminal_rows ~cols buf
  end

(* The store's status vocabulary, as colours. An unknown word keeps its own
   text and no colour: the row is still a fact about the store, just one this
   build does not rank. *)
(* Who the wake reaches. The server's keeper name takes precedence over the
   encoded target. An older server has only the target, which stays unchanged
   rather than being parsed as a name. Rows without either fall back to the
   summary, then the source, so every row names something.

   Lifted out of the row loop because the column measures itself from the
   rows now: the width and the cell have to be reading the same string. *)
let schedule_row_subject (row : Masc_tui_types.schedule_row) =
  match Masc_tui_types.schedule_row_who row with
  | Some who -> who
  | None -> (
    match row.sch_payload_summary with
    | Some summary -> summary
    | None -> row.sch_source)
;;

(* The screen's words for the schedule contract's two status variants, in
   the screen's language. Each value has its own arm, so a status the
   contract learns has to be given a word, a tone and a mark before this
   builds -- the shape [planning_phase_label] has. The tone and the mark
   follow the variant, not the drawn word, so a Korean word keeps the colour
   the English one had (RFC tui-one-screen-grammar §7.2). *)
let schedule_status_label ~ko = function
  | Schedule_contract_values.Scheduled -> if ko then "예정" else "scheduled"
  | Schedule_contract_values.Due -> if ko then "실행 대기" else "due"
  | Schedule_contract_values.Running -> if ko then "실행 중" else "running"
  | Schedule_contract_values.Succeeded -> if ko then "성공" else "succeeded"
  | Schedule_contract_values.Failed -> if ko then "실패" else "failed"
  | Schedule_contract_values.Cancelled -> if ko then "취소됨" else "cancelled"
  | Schedule_contract_values.Expired -> if ko then "만료" else "expired"

let schedule_status_tone = function
  | Schedule_contract_values.Running -> Theme.info ()
  | Schedule_contract_values.Scheduled | Schedule_contract_values.Due -> Theme.warn ()
  | Schedule_contract_values.Succeeded -> Theme.ok ()
  | Schedule_contract_values.Failed -> Theme.bad ()
  | Schedule_contract_values.Cancelled | Schedule_contract_values.Expired -> Theme.recede ()

let schedule_status_mark status =
  Masc_tui_value.Mark.glyph
    (match status with
     | Schedule_contract_values.Scheduled -> Masc_tui_value.Mark.Waiting
     | Schedule_contract_values.Due | Schedule_contract_values.Running ->
         Masc_tui_value.Mark.Under_way
     | Schedule_contract_values.Succeeded -> Masc_tui_value.Mark.Settled
     | Schedule_contract_values.Failed -> Masc_tui_value.Mark.Failed
     | Schedule_contract_values.Cancelled | Schedule_contract_values.Expired ->
         Masc_tui_value.Mark.Paused)

(* [sch_status] arrives as a string. A word the contract names is drawn as
   the screen's word in its tone; a word this build does not name is drawn
   as received, with no tone and the plain dot, so it still reads as a fact
   about the store. *)
type schedule_status_reading = { word : string; tone : string; mark : string }

let schedule_status_reading ~ko text =
  match Schedule_domain.schedule_status_of_string text with
  | Ok status ->
      { word = schedule_status_label ~ko status
      ; tone = schedule_status_tone status
      ; mark = schedule_status_mark status }
  | Error _ ->
      { word = Terminal_text.single_line text; tone = Ansi.reset; mark = "\xc2\xb7" }

(* The list column is as wide as the widest word this screen draws for a
   wake in its language, and no wider: the value was a string, and the
   column a literal 10 that happened to fit "succeeded". Measured from the
   contract's list of statuses, the column and the vocabulary cannot drift
   apart. *)
let schedule_wake_word ~ko = function
  | Schedule_contract_values.Wake_running -> if ko then "실행 중" else "running"
  | Schedule_contract_values.Wake_succeeded -> if ko then "성공" else "succeeded"
  | Schedule_contract_values.Wake_failed -> if ko then "실패" else "failed"

let schedule_wake_tone = function
  | Schedule_contract_values.Wake_running -> Theme.info ()
  | Schedule_contract_values.Wake_succeeded -> Theme.ok ()
  | Schedule_contract_values.Wake_failed -> Theme.bad ()

let schedule_wake_word_cells ~ko =
  List.fold_left
    (fun widest status ->
      max widest (Message_layout.display_width (schedule_wake_word ~ko status)))
    0 Schedule_contract_values.wake_statuses

(* The same rule for the schedule's own status. [sch_status] arrives as a
   string rather than the contract's variant, so the cell is cut to this
   width as well: a word the contract does not name cannot push the columns
   beside it out of line. *)
let schedule_status_word_cells ~ko =
  List.fold_left
    (fun widest status ->
      max widest (Message_layout.display_width (schedule_status_label ~ko status)))
    0 Schedule_contract_values.schedule_statuses


(* The width of the request clock column: the widest column moment
   ([Terminal_text.column_timestamp]), not a measured row. An unparsed stamp
   comes back as the source text and an absent one as "(never)", and either
   of those pulls the three columns after it out of line -- the same shape
   as the printf padding this row gave up. *)
let schedule_requested_clock_cells = Terminal_text.column_timestamp_cells

(* The screen's words for the two projection axes. Both arrive as the
   schedule contract's closed variants, so each value has its own arm here and
   a value the server learns has to be given a word before this builds
   (#36009). The words name what the reader sees, not the wire spelling:
   [matched_consumed_ack] is "acknowledged", [matched_pending] is "queued". *)
let schedule_queue_word ~ko = function
  | Schedule_contract_values.Queue_matched_pending -> if ko then "대기 중" else "queued"
  | Schedule_contract_values.Queue_retained_terminal_wake -> if ko then "남겨 둠" else "retained"
  | Schedule_contract_values.Queue_withdrawn_at_cancel -> if ko then "취소로 뺌" else "withdrawn"
  | Schedule_contract_values.Queue_not_found -> if ko then "대기열에 없음" else "not in queue"
  | Schedule_contract_values.Queue_matched_terminal_completed -> if ko then "끝남" else "completed"
  | Schedule_contract_values.Queue_matched_terminal_cancelled -> if ko then "취소됨" else "cancelled"
  | Schedule_contract_values.Queue_terminal_projection_pending -> if ko then "정리 중" else "settling"
  | Schedule_contract_values.Queue_transfer_projection_pending -> if ko then "옮기는 중" else "transferring"
  | Schedule_contract_values.Queue_evidence_invalid -> if ko then "기록 어긋남" else "mismatched"
  | Schedule_contract_values.Queue_read_error -> if ko then "읽기 실패" else "unreadable"
  | Schedule_contract_values.Queue_unrecognized_receipt -> if ko then "모르는 기록" else "unknown receipt"

let schedule_reaction_word ~ko = function
  | Schedule_contract_values.Reaction_conflicting_terminal_evidence -> if ko then "기록 충돌" else "conflicting"
  | Schedule_contract_values.Reaction_matched_terminal_cancelled -> if ko then "취소됨" else "cancelled"
  | Schedule_contract_values.Reaction_matched_consumed_ack -> if ko then "받음 확인" else "acknowledged"
  | Schedule_contract_values.Reaction_matched_turn_finished -> if ko then "턴 끝남" else "turn finished"
  | Schedule_contract_values.Reaction_matched_turn_started -> if ko then "턴 시작" else "turn started"
  | Schedule_contract_values.Reaction_matched_stimulus -> if ko then "받음" else "received"
  | Schedule_contract_values.Reaction_not_found -> if ko then "기록 없음" else "not found"
  | Schedule_contract_values.Reaction_quarantined -> if ko then "격리됨" else "quarantined"
  | Schedule_contract_values.Reaction_read_error -> if ko then "읽기 실패" else "unreadable"
  | Schedule_contract_values.Reaction_missing_stimulus_id -> if ko then "자극 id 없음" else "no stimulus id"
  | Schedule_contract_values.Reaction_invalid_stimulus_id -> if ko then "잘못된 자극 id" else "bad stimulus id"
  | Schedule_contract_values.Reaction_unrecognized_receipt -> if ko then "모르는 기록" else "unknown receipt"

(* The last reaction the woken Keeper's ledger recorded, in the words the
   Reaction row above already uses for the same steps. *)
let schedule_reaction_kind_word ~ko = function
  | Masc.Keeper_reaction_ledger_wire.Turn_started -> if ko then "턴 시작" else "turn started"
  | Masc.Keeper_reaction_ledger_wire.Turn_finished -> if ko then "턴 끝남" else "turn finished"
  | Masc.Keeper_reaction_ledger_wire.Event_queue_ack -> if ko then "받음 확인" else "acknowledged"
  | Masc.Keeper_reaction_ledger_wire.Event_queue_cancelled -> if ko then "취소됨" else "cancelled"

(* How the woken turn ended: the word and the colour of its status mark (RFC
   tui-one-screen-grammar §7.2). A turn that ended asking the operator for
   input is the operator's turn; a rest and a skip are waits; a cancel is a
   stop. *)
type schedule_turn_outcome_reading = { outcome_word : string; outcome_tone : string }

let schedule_turn_outcome_reading ~ko disposition =
  let reading korean english tone =
    { outcome_word = (if ko then korean else english); outcome_tone = tone } in
  match disposition with
  | Masc.Keeper_reaction_ledger.Turn_disposition.Completed -> reading "완료" "completed" (Theme.ok ())
  | Masc.Keeper_reaction_ledger.Turn_disposition.Checkpointed ->
      reading "중간 저장" "checkpointed" (Theme.ok ())
  | Masc.Keeper_reaction_ledger.Turn_disposition.Input_required ->
      reading "입력 필요" "input required" (Theme.warn ())
  | Masc.Keeper_reaction_ledger.Turn_disposition.Cancelled ->
      reading "취소됨" "cancelled" (Theme.recede ())
  | Masc.Keeper_reaction_ledger.Turn_disposition.Skipped ->
      reading "건너뜀" "skipped" (Theme.recede ())
  | Masc.Keeper_reaction_ledger.Turn_disposition.Failed -> reading "실패" "failed" (Theme.bad ())
  | Masc.Keeper_reaction_ledger.Turn_disposition.Rested -> reading "쉼" "rested" (Theme.recede ())

let schedule_queue_color = function
  | Schedule_contract_values.Queue_matched_pending
  | Schedule_contract_values.Queue_terminal_projection_pending
  | Schedule_contract_values.Queue_transfer_projection_pending -> Theme.warn ()
  | Schedule_contract_values.Queue_matched_terminal_completed -> Theme.ok ()
  | Schedule_contract_values.Queue_retained_terminal_wake
  | Schedule_contract_values.Queue_withdrawn_at_cancel
  | Schedule_contract_values.Queue_matched_terminal_cancelled -> Theme.recede ()
  | Schedule_contract_values.Queue_not_found
  | Schedule_contract_values.Queue_evidence_invalid
  | Schedule_contract_values.Queue_read_error
  | Schedule_contract_values.Queue_unrecognized_receipt -> Theme.bad ()

let schedule_reaction_color = function
  | Schedule_contract_values.Reaction_matched_consumed_ack
  | Schedule_contract_values.Reaction_matched_turn_finished -> Theme.ok ()
  | Schedule_contract_values.Reaction_matched_turn_started
  | Schedule_contract_values.Reaction_matched_stimulus -> Theme.info ()
  | Schedule_contract_values.Reaction_matched_terminal_cancelled -> Theme.recede ()
  | Schedule_contract_values.Reaction_conflicting_terminal_evidence
  | Schedule_contract_values.Reaction_not_found
  | Schedule_contract_values.Reaction_quarantined
  | Schedule_contract_values.Reaction_read_error
  | Schedule_contract_values.Reaction_missing_stimulus_id
  | Schedule_contract_values.Reaction_invalid_stimulus_id
  | Schedule_contract_values.Reaction_unrecognized_receipt -> Theme.bad ()

(* What became of the wake, for a list row that has one line to say it in.
   [None] is the ledger saying nothing, and the row then shows an em dash
   rather than a delivery it does not know. That is not the same as a wake
   that failed, which [wake:] beside it already names. *)
let schedule_delivery_word ~ko (row : schedule_row) =
  match row.sch_reaction_projection_status with
  | None -> Masc_tui_theme.Glyph.no_value
  | Some status -> schedule_reaction_word ~ko status

(* What the last occurrence came to, for a row that has one line to say it.

   A wake that did not succeed is the outcome. A succeeded wake hands the
   column to the furthest step the ledger recorded -- the reading that
   separates a wake merely taken from one that finished a turn. No wake at
   all is no outcome: the reaction evidence beside it belongs to the
   occurrence before (a held occurrence has no wake of its own, and a
   projection between occurrences still carries the last one's reading), so
   drawing it would pair a dash in the trigger column with a word about a
   different occurrence in this one. The word and its tone come with it, the
   reaction's or the wake's, so a caller does not read the colour back out
   of a word drawn in either language. [None] is no outcome. *)
let schedule_outcome ~ko (row : schedule_row) =
  match row.sch_last_wake_status with
  | Some Schedule_contract_values.Wake_succeeded ->
      Option.map
        (fun status -> schedule_reaction_word ~ko status, schedule_reaction_color status)
        row.sch_reaction_projection_status
  | Some
      (( Schedule_contract_values.Wake_running
       | Schedule_contract_values.Wake_failed ) as other) ->
      Some (schedule_wake_word ~ko other, schedule_wake_tone other)
  | None -> None

(* Whether a status word names a schedule that can still act. The word is
   the projection's own; a word this build does not name stays with the live
   rows rather than being buried under the closed rule -- the same promise
   the word itself makes by rendering as itself. *)
let schedule_status_is_terminal word =
  match Schedule_domain.schedule_status_of_string word with
  | Ok status -> Schedule_domain.is_terminal status
  | Error _ -> false

(* The delivery summary names each reading before its value: [status:],
   [queue:] and [reaction:] on an English screen, 상태, 대기열 and 반응 on a
   Korean one. The hold tag follows the same language. *)
(* The length of the owner's whole queue, beside the wake's queue word. *)
let schedule_queue_depth ~ko count =
  let count = Masc_tui_value.Count.grouped count in
  if ko then "쌓인 " ^ count ^ "건" else "depth=" ^ count

let schedule_delivery_summary ~ko ~freshness ~runner (row : schedule_row) =
  let label korean english = if ko then korean ^ " " else english ^ ":" in
  let depth = schedule_queue_depth ~ko in
  let queue =
    (* [pending_count] is the length of the owner's whole queue, not a fact
       about this wake, so it is spelled as the depth beside the wake's
       word rather than as a second "pending". *)
    label "대기열" "queue"
    ^ (match row.sch_queue_projection_status, row.sch_queue_pending_count with
       | None, None -> Masc_tui_theme.Glyph.no_value
       | Some status, None -> schedule_queue_word ~ko status
       | None, Some count -> depth count
       | Some status, Some count ->
           schedule_queue_word ~ko status ^ (if ko then " \xc2\xb7 " else " ") ^ depth count)
  in
  let reaction =
    label "반응" "reaction"
    ^ (match row.sch_reaction_projection_status with
       | None -> Masc_tui_theme.Glyph.no_value
       | Some status -> schedule_reaction_word ~ko status)
  in
  (* A held occurrence has no wake of its own, so the queue and reaction
     readings on the next line still describe the previous one. The hold says
     so on the identity line, next to the status it would otherwise leave
     reading as a late [due]. The short tag, because the line is already
     most of a narrow screen; the detail pane carries the full sentence.
     Unless the list is the latest answer and the runner is [ok], the hold
     is drawn at the time the runner read it: the tag names that time instead
     of the due -- the same width, and the due column above still has the
     due (#38411). *)
  let hold =
    match row.sch_runner_hold with
    | None -> ""
    | Some hold ->
        " \xc2\xb7 "
        ^ (match Tui_decode.schedule_hold_reading ~freshness ~runner hold with
           | Tui_decode.Hold_current ->
               Render_schedule.schedule_hold_tag ~ko
                 ~due:(Terminal_text.short_timestamp hold.Tui_decode.srh_due_at_iso)
           | Tui_decode.Hold_as_of checked ->
               Render_schedule.schedule_hold_as_of_tag ~ko
                 ~checked:(Terminal_text.short_timestamp_of_unix checked))
  in
  let subject =
    match row.sch_payload_summary with
    | Some summary when not (String.equal (String.trim summary) "") ->
        Terminal_text.single_line summary
    | Some _ | None -> row.sch_schedule_id
  in
  ( Printf.sprintf "%s \xc2\xb7 %s%s%s" subject (label "상태" "status")
      (schedule_status_reading ~ko row.sch_status).word hold
  , Printf.sprintf "%s \xc2\xb7 %s" queue reaction )

(* Both readers draw this through [data_unreliable_row], which already opens
   "(data unreliable: ". So each branch says only what that frame cannot:
   nothing, when there is no snapshot and the error is the whole story; and
   that the rows on screen are the previous read, when there is one. *)
let schedule_source_warning (state : state) =
  Terminal_text.optional_single_line state.schedules_error
  |> Option.map (fun err ->
         match state.schedules with
         | None -> err
         | Some _ ->
             ui_text state ~ko:"이전 조회 유지 · " ~en:"Keeping prior read · " ^ err)

(* The list on screen is the newest answer only while its last load
   succeeded. A failed reload keeps the previous list on screen, and a hold on
   it is then an earlier reading whatever the runner said at the time. *)
let schedule_list_freshness (state : state) =
  match state.schedules_error with
  | None -> Tui_decode.List_latest
  | Some _ -> Tui_decode.List_kept

(* A refused create or modify form, wrapped to the frame, for as long as the
   last-action window lasts; the action line alone is lost under a workspace
   warning. The rows leave when the window ends, with no new data, so a frame
   that draws them notes that instant (RFC tui-one-screen-grammar §8). *)
let schedule_form_refusal_rows (state : state) ~cols =
  match state.schedule_form_refusal with
  | Some ({ sfr_at; _ } as refusal)
    when Masc_tui_value.Redraw.holds ~now:(Unix.gettimeofday ())
           ~until:(sfr_at +. Masc_tui_types.last_action_window_s) ->
      Message_layout.wrap_words ~max_cells:(max 1 (framed_inner_width cols))
        (Terminal_text.single_line
           (schedule_form_refusal_text ~ko:(state.ui_language = Lang_ko) refusal))
  | Some _ | None -> []

(* Rows the Schedules page spends around its list, counted once so the
   refusal budget and the list height read the same numbers: the summary line
   (request count and next due combined) and its divider; the column names and
   their rule; the two delivery rows. *)
let schedule_summary_rows = 2
let schedule_column_header_rows = 2
let schedule_delivery_rows = 2

let schedule_rows_around_list =
  schedule_summary_rows + schedule_column_header_rows + schedule_delivery_rows

(* Whether the list holds a row for [j/k], [Right / Enter], [e], [x] and [Y]
   to act on. Read by the footer; the dispatcher reads the same rows. *)
let schedule_list_has_rows (state : state) =
  match state.schedules with
  | Some snapshot -> snapshot.scs_rows <> []
  | None -> false

(** Render the Schedules surface: the scheduled-automation list, with an
    armed cancel. The server sorts active rows first by due time and caps the
    list at its own limit; [scs_truncated] and [scs_request_count] say what
    of the whole store this page is. *)
let render_schedule_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let refusal_rows = schedule_form_refusal_rows state ~cols in

  (* The title carried the current time to the second, so the row was
     redrawn every second with nothing on the screen having changed. The top
     row holds the clock. *)
  let header =
    here_row ~cols state
      ~path:[ ui_text state ~ko:"일정" ~en:"schedules" ]
      ~readings:[] ~position:None
  in

  let drawn_list_scroll = ref 0 in
  surface_chrome_keys
    ~overflow:
      (Self_scrolled
         (fun () -> List_window_scroll (Schedule_list, !drawn_list_scroll)))
    state ~terminal_rows ~cols ~surface_key:"schedules"
    ~title:header
    ~keys:
      (Masc_tui_keys.footer_row_of_surface ~lang:state.ui_language ~detail_open:false
         ~has_rows:(schedule_list_has_rows state) Schedules)
    ~body:(fun ~budget c ->
  (* The refusal rows go first and take what the list's fixed rows leave;
     past that, the last row says where the rest is. The fixed rows are the
     ones [content_height] subtracts below (next due and its divider, the
     column names and their rule, the two delivery rows) plus one list row. *)
  let selected_row_exists, reserved_rows =
    match state.schedules with
    | Some snapshot when String.equal snapshot.scs_status "ok" ->
        let warning = if Option.is_some (schedule_source_warning state) then 1 else 0 in
        let cancel = (if Option.is_some state.schedule_cancel_armed then 1 else 0)
          + (if Option.is_some state.schedule_cancel_error then 1 else 0) in
        let selected =
          snapshot.scs_rows <> []
          && Option.is_some
               (List.nth_opt snapshot.scs_rows
                  (Masc_tui_scroll.cursor_normalized
                     ~count:(List.length snapshot.scs_rows) state.schedule_cursor))
        in
        selected, warning + cancel +
          (if snapshot.scs_rows = [] then schedule_summary_rows + 1
           else schedule_rows_around_list + 1)
    | Some _ | None -> false, 1
  in
  let room = max 0 (budget - reserved_rows) in
  let refusal_rows =
    if List.length refusal_rows <= room then refusal_rows
    else if room = 0 then []
    else
      let cue =
        if selected_row_exists then
          ui_text state ~ko:"… Enter:거절 진단 전체"
            ~en:"… Enter:full refusal diagnostic"
        else
          ui_text state ~ko:"… 거절 진단이 잘림"
            ~en:"… refusal diagnostic truncated"
      in
      List.filteri (fun index _ -> index < room - 1) refusal_rows
      @ [Message_layout.fit_width cue (max 1 (framed_inner_width cols))]
  in
  List.iter (c.push_styled ~style:(Theme.bad ())) refusal_rows;
  (match state.schedules with
   | None ->
       (match schedule_source_warning state with
        | Some err ->
            c.push (data_unreliable_row ~cols err)
        | None ->
            let reading = Snapshot_read.in_flight state.schedules_read in
            c.push (wrap_style (if reading then Theme.info () else Theme.recede ()) (page_unread_note_while ~ko:(state.ui_language = Lang_ko) ~reading)))
   | Some snapshot ->
       let warning_rows =
         match schedule_source_warning state with
         | None -> 0
         | Some err ->
             c.push (data_unreliable_row ~cols err);
             1
       in
       (* The arm and the server's last refusal take a row each under the
          list while they stand. *)
       let cancel_rows =
         (if Option.is_some state.schedule_cancel_armed then 1 else 0)
         + (if Option.is_some state.schedule_cancel_error then 1 else 0)
       in
       if not (String.equal snapshot.scs_status "ok") then begin
         (* The server's "unknown" is a failed store read, not an empty list;
            the row says which, so a dead ledger cannot read as "nothing is
            scheduled". *)
         (match snapshot.scs_read_error with
          | Some err ->
              c.push (data_unreliable_row ~cols err)
          | None ->
              c.push
                ((Theme.bad ())
                 ^ ui_text state ~ko:"  (일정 저장소를 읽지 못함)"
                     ~en:"  (schedule store unreadable)"
                 ^ Ansi.reset))
       end else begin
         let ko = state.ui_language = Lang_ko in
         let count_text =
           match snapshot.scs_request_count, snapshot.scs_paging with
           | Some total, Schedule_paging_unavailable when snapshot.scs_truncated ->
               Printf.sprintf
                 (if ko then "  일정 요청: %s건  (앞 %s건 · 서버가 페이지를 주지 않음)"
                  else "  Requests: %s  (first %s; server paging unavailable)")
                 (Masc_tui_value.Count.grouped total) (Masc_tui_value.Count.grouped (List.length snapshot.scs_rows))
           | Some total, Schedule_paging _
             when snapshot.scs_truncated || Option.is_some state.schedules_page.sp_cursor ->
               Printf.sprintf
                 (if ko then "  일정 요청: %s건  · %d쪽 (%s건 표시 · 쪽 구성은 바뀔 수 있음)"
                  else "  Requests: %s  · page %d (%s shown; pages may change)")
                 (Masc_tui_value.Count.grouped total) (List.length state.schedules_page.sp_previous + 1)
                 (Masc_tui_value.Count.grouped (List.length snapshot.scs_rows))
           | Some total, (Schedule_paging_unavailable | Schedule_paging _) ->
               Printf.sprintf (if ko then "  일정 요청: %s건" else "  Requests: %s") (Masc_tui_value.Count.grouped total)
           | None, (Schedule_paging_unavailable | Schedule_paging _) ->
               (if ko then "  일정 요청: " else "  Requests: ")
               ^ Masc_tui_theme.Glyph.no_value
         in
         (* One row, not two. The count and the next wake are a phrase each,
            and with nothing due the second row was drawn blank -- a row of
            the list given up to say nothing. *)
         let next_due_text =
           match snapshot.scs_next_due_iso with
           | Some iso ->
               wrap_style (Theme.recede ())
                 (Printf.sprintf
                    (if ko then "  \xc2\xb7  다음 기한: %s"
                     else "  \xc2\xb7  Next due: %s")
                    (Terminal_text.short_timestamp iso))
           | None -> ""
         in
         let page_read_text = match state.schedules_navigation with
           | Some (ticket, page, _) when Snapshot_read.is_current state.schedules_read ticket ->
               let now = Unix.gettimeofday () in
               let page_num = List.length page.sp_previous + 1 in
               let started_at =
                 Masc_tui_types.progress_clock_for state ~slot:"schedules-page" ~now
                   ~signature:(string_of_int page_num)
               in
               "  · "
               ^ progress_inline ~ko ~now ~started_at
                   (Printf.sprintf (if ko then "%d쪽 조회 중" else "loading page %d") page_num)
           | Some _ | None ->
               Masc_tui_types.clear_progress_clock state ~slot:"schedules-page";
               "" in
         c.push (Ansi.bold ^ count_text ^ Ansi.reset ^ next_due_text ^ page_read_text);
         c.push_divider ();

         let count = List.length snapshot.scs_rows in
         if count = 0 then begin
           (* The key that fills this list, on the row that says it is empty.
              [n] is an Act key on a surface whose Navigate keys take the
              footer first -- j/k, PgUp/PgDn, [ / ] -- so at a hundred and ten
              columns the footer drops every action this screen has, [n] with
              them. An operator looking at an empty Schedules screen then has
              nowhere on it saying a schedule can be made at all. Same move
              [page_unread_note] made for [r]. *)
           let empty = match snapshot.scs_request_count, state.schedules_page.sp_previous with
             | Some total, _ :: _ when total > 0 ->
                 ui_text state
                   ~ko:"  (이 페이지에 일정 없음 · < 로 이전 페이지)"
                   ~en:"  (no schedules on this page; < returns to the previous page)"
             | Some total, [] when total > 0 ->
                 ui_text state
                   ~ko:"  (이 페이지에 일정 없음 · 새로고침으로 다시 읽기)"
                   ~en:"  (no schedules on this page; refresh to read again)"
             | (Some _ | None), (_ :: _ | []) ->
                 ui_text state
                   ~ko:"  (자동 일정 없음 · n 으로 만들기)"
                   ~en:"  (no scheduled automation · press n to create one)"
           in
           c.push (wrap_style (Theme.recede ()) empty)
         end else begin
           (* Keep two factual rows below the list for delivery state. Without
              it the list says when a wake is due but not whether the dispatch,
              queue, and reaction projections agree. Two rows keep all three
              projections readable at the 100-column regression viewport. *)
           let subject_width =
             List.fold_left
               (fun widest row ->
                 max widest
                   (Message_layout.display_width
                      (Terminal_text.single_line (schedule_row_subject row))))
               Render_schedule.schedule_minimum_target_width snapshot.scs_rows
             |> min Render_schedule.schedule_maximum_target_width
           in
           let wake_width = schedule_wake_word_cells ~ko in
           (* Measured, like the target beside it. The column was a literal
              12, and the words the projection sends run past it: live,
              [turn_finished] drew as [tur...finished], and
              [terminal_cancelled] and [conflicting_terminal_evidence] are
              longer still. The wake column next to it takes its width from
              the contract's own list; this one has no such list to read
              (#38350), so it is measured from the rows on the page. *)
           let delivery_width =
             Render_schedule.schedule_delivery_width
               (List.map
                  (fun row ->
                    Terminal_text.single_line (schedule_delivery_word ~ko row))
                  snapshot.scs_rows)
           in
           let layout =
             Render_schedule.schedule_layout
               ~ko:(state.ui_language = Lang_ko)
               ~inner_width:(max 1 (framed_inner_width cols - 2))
               ~target_width:subject_width ~wake_width ~delivery_width
           in
           c.push_styled ~style:(Theme.recede ())
             ("  "
              ^ Render_schedule.schedule_header_row
                  ~ko:(state.ui_language = Lang_ko) ~layout);
           c.push_divider ();
           (* The column names and the rule under them, the two rows every
              other list on this screen already spends to say what it draws. *)
           (* The body outside the list: the source warning, the request count,
              next due and its divider, the column names and their rule, the
              two delivery rows, and the cancel rows. *)
           let content_height =
             max 1 (budget - List.length refusal_rows - warning_rows - schedule_rows_around_list - cancel_rows)
           in
           let schedule_cursor =
             Masc_tui_scroll.cursor_normalized ~count state.schedule_cursor
           in
           let scroll_offset =
             Masc_tui_scroll.normalize ~count ~height:content_height
               state.schedule_list_scroll
             |> Masc_tui_scroll.ensure_visible ~cursor:schedule_cursor
                  ~height:content_height
           in
           drawn_list_scroll := scroll_offset;
           let scs_rows_window = Rows.of_list ~first:scroll_offset ~height:content_height snapshot.scs_rows in
           report_drawn_list Schedule_rows ~height:content_height;
           c.position (Masc_tui_value.Position.row ~selected:(Some schedule_cursor) ~total:count);
           for i = 0 to content_height - 1 do
             let idx = i + scroll_offset in
             match Rows.at scs_rows_window idx with
             | None -> c.push_empty ()
             | Some row -> begin
               let is_selected = idx = schedule_cursor in
               let due =
                 match row.sch_due_at_iso with
                 | Some iso -> Terminal_text.column_timestamp iso
                 | None -> Masc_tui_theme.Glyph.no_value
               in
               (* The payload target names who the wake reaches (a keeper for
                  keeper wakes); rows without one fall back to the summary,
                  then the source, so every row names something.

                  The kind prefix comes off first. It is "keeper:" on every
                  row this list can draw, so it separates nothing and takes
                  seven cells out of the name -- which left two schedules for
                  two different keepers both reading "keeper:~". The agenda
                  strip has stripped it since it was written; this list is
                  the surface that did not. *)
               let subject = schedule_row_subject row in
               let status = schedule_status_reading ~ko row.sch_status in
               let last_wake =
                 Option.fold ~none:Masc_tui_theme.Glyph.no_value ~some:(schedule_wake_word ~ko)
                   row.sch_last_wake_status
               in
               let last_wake_tone =
                 Option.fold ~none:Ansi.reset ~some:schedule_wake_tone row.sch_last_wake_status
               in
               (* The enqueue result and what became of the wake are two
                  facts, and the list carried only the first: a wake the queue
                  cancelled forty seconds later still read [wake:succeeded].
                  Both are here, each under its own name.

                  The target is measured from the rows rather than given the
                  rest of the line. The subject is a keeper name on every row
                  that has a payload target, so [cols - 76] spent ninety cells
                  on [edgar.a.poe] and the recurrence past it -- which is where
                  the timezone lives -- read [daily 08:00:00 A~]. The fallback
                  summary can be long, so it is capped rather than trusted. *)
               let line =
                 Render_schedule.schedule_row ~status_style:status.tone
                   ~wake_style:last_wake_tone
                   ~recurrence_style:(Theme.recede ()) ~layout
                   { Render_schedule.srow_status =
                       status.mark ^ " " ^ status.word
                   ; srow_due = due
                   ; srow_target = Terminal_text.single_line subject
                   ; srow_wake = last_wake
                   ; srow_delivery =
                       Terminal_text.single_line (schedule_delivery_word ~ko row)
                   ; srow_recurrence =
                       Terminal_text.single_line
                         (Masc_tui_schedule_recurrence.text ~ko ~now:(Unix.gettimeofday ())
                            ~summary:row.sch_recurrence_summary row.sch_recurrence)
                   }
               in
               if is_selected then
                 c.push_selected_styled ("\xe2\x80\xba " ^ line)
               else
                 c.push ("  " ^ line)
             end
           done;
           (match List.nth_opt snapshot.scs_rows schedule_cursor with
            | None ->
                c.push_empty ();
                c.push_empty ()
            | Some selected ->
                let identity, delivery =
                  schedule_delivery_summary ~ko
                    ~freshness:(schedule_list_freshness state)
                    ~runner:snapshot.scs_runner_status selected
                in
                c.push_styled ~style:(Theme.recede ())
                  ("  " ^ identity);
                c.push_styled ~style:(Theme.recede ())
                  ("  " ^ delivery))
         end;
         (* The arm and the server's last refusal sit under the list, the
            same rows the goal detail carries them on. *)
         (match state.schedule_cancel_armed with
          | Some schedule_id ->
              c.push
                ((Theme.warn ()) ^ "  "
                ^ schedule_cancel_armed_text ~ko:(state.ui_language = Lang_ko)
                    (resolve_schedule_title_in ~rows:snapshot.scs_rows schedule_id)
                ^ Ansi.reset)
          | None -> ());
         (match state.schedule_cancel_error with
          | Some (schedule_id, err) ->
              c.push
                ((Theme.bad ()) ^ "  "
                ^ fit_width
                    (Terminal_text.single_line
                       (resolve_schedule_title_in ~rows:snapshot.scs_rows schedule_id
                        ^ ": "
                        ^ request_failure_text ~ko:(state.ui_language = Lang_ko)
                            ~request:Kept_request.Schedule_cancel err))
                    (framed_inner_width cols - 4)
                ^ Ansi.reset)
          | None -> ())
       end))

(* What became of the wake. The pane could say a schedule fired and stop
   there: [LAST WAKE] reports the dispatch and [DELIVERY EVIDENCE] reports one
   word of verdict, and neither answers "did the Keeper do anything". The
   reaction ledger records four steps and the projection folds all four into
   that one word, so a wake delivered to a Keeper that never took a turn reads
   the same as one that did.

   Drawn only when the ledger said something. A schedule that has not fired
   has no trail, and four rows of "--" under it would be four rows saying the
   same nothing the empty [LAST WAKE] block already says. *)
let schedule_turn_rows ~ko
      ~(field : ?style:string -> string -> string -> string * string)
      (row : schedule_row) =
  let t korean english = if ko then korean else english in
  let turn_finished_seen =
    Option.map
      (function
        | Schedule_turn_open -> false
        | Schedule_turn_finished _ -> true)
      row.sch_turn_finished
  in
  let step_observed =
    [ row.sch_wake_seen
    ; row.sch_turn_started
    ; turn_finished_seen
    ; row.sch_queue_ack_seen
    ; row.sch_wake_cancelled
    ]
    |> List.exists Option.is_some
  in
  let metadata_observed =
    [ row.sch_reaction_keeper_name
    ; row.sch_reaction_stimulus_id
    ; row.sch_reaction_post_id
    ; row.sch_reaction_reason
    ; row.sch_stimulus_recorded_at_iso
    ; row.sch_turn_started_recorded_at_iso
    ; row.sch_turn_finished_recorded_at_iso
    ; row.sch_queue_ack_recorded_at_iso
    ; row.sch_wake_cancelled_recorded_at_iso
    ]
    |> List.exists Option.is_some
  in
  if not (step_observed || metadata_observed || Option.is_some row.sch_reaction_quarantined)
  then []
  else
    (* [None] is not [false]. A step the ledger never spoke about draws the
       same dash every unknown draws on this pane, in the dim every unknown
       takes -- claiming "no" for it would report a failure nobody observed. *)
    let step ?(bad_when_true = false) label observed recorded_at =
      match observed with
      | None -> field label Masc_tui_theme.Glyph.no_value
      | Some value ->
          let tone =
            if value = bad_when_true then Theme.bad () else Theme.ok ()
          in
          let at =
            match value, recorded_at with
            | true, Some timestamp ->
              " \xc2\xb7 " ^ Terminal_text.short_timestamp timestamp
            | _, _ -> ""
          in
          field ~style:tone label ((if value then t "예" "yes" else t "아니오" "no") ^ at)
    in
    let identity_rows =
      [ Option.map
          (fun keeper ->
             field (t "Keeper 근거" "Keeper evidence")
               (Link.reference Keeper (Terminal_text.single_line keeper)))
          row.sch_reaction_keeper_name
      ; Option.map
          (fun stimulus -> field (t "자극" "Stimulus") stimulus)
          row.sch_reaction_stimulus_id
      ; Option.map
          (fun occurrence -> field (t "회차" "Occurrence") occurrence)
          row.sch_reaction_post_id
      ]
      |> List.filter_map Fun.id
    in
    [ Theme.recede (), ""
    ; Ansi.bold, t "  턴" "  Turn"
    ]
    @ identity_rows
    @ [ step (t "실행 확인" "Wake seen") row.sch_wake_seen row.sch_stimulus_recorded_at_iso
      ; step (t "턴 시작" "Turn started") row.sch_turn_started
          row.sch_turn_started_recorded_at_iso
      ; step (t "턴 종료" "Turn finished") turn_finished_seen
          row.sch_turn_finished_recorded_at_iso
      ; (match row.sch_turn_finished with
         | Some (Schedule_turn_finished disposition) ->
             let outcome = schedule_turn_outcome_reading ~ko disposition in
             field ~style:outcome.outcome_tone (t "턴 결과" "Turn outcome") outcome.outcome_word
         | Some Schedule_turn_open | None ->
             field (t "턴 결과" "Turn outcome") Masc_tui_theme.Glyph.no_value)
      ; step (t "큐 확인" "Queue ack") row.sch_queue_ack_seen row.sch_queue_ack_recorded_at_iso
      ; step ~bad_when_true:true (t "취소" "Cancelled") row.sch_wake_cancelled
          row.sch_wake_cancelled_recorded_at_iso
      ; field (t "반응 종류" "Reaction kind")
          (match row.sch_reaction_kind with
           | Some (Ok kind) -> schedule_reaction_kind_word ~ko kind
           (* A kind this build cannot read: the ledger's own token. *)
           | Some (Error raw) -> Terminal_text.single_line raw
           | None -> Masc_tui_theme.Glyph.no_value)
      ; field
          ~style:(if Option.is_some row.sch_reaction_reason then Theme.warn () else Theme.recede ())
          (t "사유" "Reason") (Option.value ~default:Masc_tui_theme.Glyph.no_value row.sch_reaction_reason)
    ; field
        ~style:
          (match row.sch_reaction_quarantined with
           | Some count when count > 0 -> Theme.warn ()
           | Some _ | None -> Theme.recede ())
        (t "격리" "Quarantined")
        (match row.sch_reaction_quarantined with
         | None -> Masc_tui_theme.Glyph.no_value
         | Some count -> string_of_int count)
      ]

(* The wake block. The row carries the newest attempt and the exact lookup
   carries the retained list, so this pane reports whichever it has and says
   which: one attempt out of up to 32 read as a schedule's whole past for as
   long as the list was the only thing not projected. The three unloaded
   readings stay three sentences. *)
let schedule_wake_lines ~ko
      ~(field : ?style:string -> string -> string -> string * string)
      ~(timestamp : string option -> string) ~(row : schedule_row)
      ~(history : schedule_wake_history option)
      ~(history_error : (string * string) option) =
  let t korean english = if ko then korean else english in
  let last_wake = Ansi.bold, t "  마지막 실행" "  Last wake" in
  let last_wake_fields =
    [ (let word =
         Option.fold ~none:Masc_tui_theme.Glyph.no_value ~some:(schedule_wake_word ~ko)
           row.sch_last_wake_status
       in
       field
         ~style:(Option.fold ~none:(Theme.recede ()) ~some:schedule_wake_tone row.sch_last_wake_status)
         (t "상태" "Status") word)
    ; field (t "시작" "Started") (timestamp row.sch_last_wake_started_at_iso)
    ; field
        ~style:(if Option.is_some row.sch_last_wake_error then Theme.bad () else Theme.recede ())
        (t "오류" "Error") (Option.value ~default:Masc_tui_theme.Glyph.no_value row.sch_last_wake_error)
    ]
  in
  match
    Render_schedule.classify_wake_reading
      ~history_error:(Option.map snd history_error)
      ~history:
        (Option.map
           (fun h -> (List.length h.swh_wakes, h.swh_retention_per_schedule))
           history)
  with
  | Render_schedule.Wake_history_failed err ->
      last_wake
      :: last_wake_fields
      @ [ (Theme.bad (), t "  실행 이력: " "  Wake history: " ^ Terminal_text.single_line err) ]
  | Render_schedule.Wake_last_only ->
      let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
      last_wake
      :: last_wake_fields
      @ [ (Theme.info (), t ("  " ^ under_way ^ " 이 일정의 나머지 실행을 읽는 중") ("  " ^ under_way ^ " loading the rest of this schedule's wakes")) ]
  | Render_schedule.Wake_never ->
      [ Ansi.bold, t "  실행" "  Wakes"
      ; (Theme.recede (), t "  (이 일정은 아직 실행된 적 없음)" "  (this schedule has not woken)") ]
  | Render_schedule.Wake_history { count; retention } ->
      let wakes =
        match history with Some h -> h.swh_wakes | None -> []
      in
        (Ansi.bold
        , Printf.sprintf
            (if ko then "  실행 (%s건 보관, 일정당 최대 %s건)"
             else "  Wakes (%s retained, ceiling %s per schedule)")
            (Masc_tui_value.Count.grouped count) (Masc_tui_value.Count.grouped retention) )
        :: List.concat_map
             (fun (wake : schedule_wake) ->
                let started = timestamp wake.swk_started_at_iso in
                let finished = timestamp wake.swk_finished_at_iso in
                (* The status is the row's label, drawn through [field] so
                   the times start in the column every other value on the
                   page starts in. A literal 12 here put them two cells to
                   the left of the Reaction time below. *)
                let word = schedule_wake_word ~ko wake.swk_status in
                let head =
                  field ~style:(schedule_wake_tone wake.swk_status) word
                    (Printf.sprintf "%s \xe2\x86\x92 %s" started finished)
                in
                match wake.swk_error with
                | None -> [ head ]
                | Some err -> [ head; field ~style:(Theme.bad ()) "" err ])
             wakes

let schedule_detail_lines ~ko ~width ~freshness ~runner (row : schedule_row)
      ~(wake_history : schedule_wake_history option)
      ~(wake_history_error : (string * string) option) =
  let field ?(style = Ansi.reset) label value =
    (* Padded by display width: "%-14s" counts bytes, which a Korean label
       has three of for every two cells. *)
    let pad = String.make (max 0 (14 - Message_layout.display_width label)) ' ' in
    let prefix = "  " ^ label ^ pad ^ " " in
    let prefix_cells = Message_layout.display_width prefix in
    let rows =
      if width - prefix_cells >= width / 2 then
        let values = Masc_tui_text_block.rows ~max_cells:(max 1 (width - prefix_cells)) value in
        (match values with
         | [] -> [prefix]
         | values -> List.mapi (fun index line ->
             (if index = 0 then prefix else String.make prefix_cells ' ') ^ line) values)
      else
        (if String.equal label "" then [] else ["  " ^ label])
        @ Masc_tui_text_block.rows ~max_cells:width value in
    style, String.concat "\n" rows
  in
  let optional value = Option.value ~default:Masc_tui_theme.Glyph.no_value value in
  let t korean english = if ko then korean else english in
  (* A moment reads on the operator's clock (RFC tui-one-screen-grammar §6.1);
     the wire text stays in section 4's raw payload. *)
  let timestamp value =
    match value with
    | None -> Masc_tui_theme.Glyph.no_value
    | Some iso -> Terminal_text.short_timestamp iso
  in
  let queue =
    match row.sch_queue_projection_status, row.sch_queue_pending_count with
    | None, None -> Masc_tui_theme.Glyph.no_value
    | Some status, None -> schedule_queue_word ~ko status
    | None, Some count -> schedule_queue_depth ~ko count
    | Some status, Some count ->
        Printf.sprintf "%s  %s" (schedule_queue_word ~ko status) (schedule_queue_depth ~ko count)
  in
  let reaction =
    match row.sch_reaction_projection_status, row.sch_reaction_latest_at_iso with
    | None, None -> Masc_tui_theme.Glyph.no_value
    | Some status, None -> schedule_reaction_word ~ko status
    | None, Some at -> Terminal_text.short_timestamp at
    | Some status, Some at ->
        Printf.sprintf "%s  %s" (schedule_reaction_word ~ko status)
          (Terminal_text.short_timestamp at)
  in
  let summary =
    Option.value ~default:(t "(페이로드 요약 없음)" "(no payload summary)") row.sch_payload_summary
  in
  let keeper_wake =
    match Option.bind row.sch_payload_kind Masc.Schedule_payload_projection.classify_kind with
    | Some Masc.Schedule_payload_projection.Keeper_wake -> true
    | Some Masc.Schedule_payload_projection.Lane_act | None -> false
  in
  (* The link names the Keeper by its own field. [sch_payload_target] is
     "keeper:<name>", which no Keeper is called (#53077). *)
  let target_link =
    match keeper_wake, row.sch_payload_keeper_name with
    | true, Some keeper ->
        [ field (t "Keeper 링크" "Keeper link")
            (Link.reference Keeper (Terminal_text.single_line keeper))
        ]
    | _, _ -> []
  in
  let hold_rows =
    match row.sch_runner_hold with
    | None -> []
    | Some hold ->
        [ field ~style:(Theme.warn ()) (t "보류" "Held")
            (match Tui_decode.schedule_hold_reading ~freshness ~runner hold with
             | Tui_decode.Hold_current ->
                 let due = Terminal_text.short_timestamp hold.Tui_decode.srh_due_at_iso in
                 (match hold.Tui_decode.srh_reason with
                  | Tui_decode.Hold_previous_wake_untaken ->
                      Render_schedule.schedule_hold_reading ~ko ~due
                  | Tui_decode.Hold_target_shutdown_fenced { target; fence_owner } ->
                      Render_schedule.schedule_fence_hold_reading
                        ~ko ~due ~target ~fence_owner)
             | Tui_decode.Hold_as_of checked ->
                 let checked = Terminal_text.short_timestamp_of_unix checked in
                 (match hold.Tui_decode.srh_reason with
                  | Tui_decode.Hold_previous_wake_untaken ->
                      Render_schedule.schedule_hold_as_of_reading ~ko ~checked
                  | Tui_decode.Hold_target_shutdown_fenced { target; fence_owner } ->
                      Render_schedule.schedule_fence_hold_as_of_reading
                        ~ko ~checked ~target ~fence_owner))
        ; field (t "보류 id" "Held id") hold.Tui_decode.srh_occurrence_id
        ; field (t "보류 예정" "Held due")
            (Terminal_text.short_timestamp hold.Tui_decode.srh_due_at_iso)
        ]
  in
  detail_section_heading ~first:true ~width
    (t "1. 현재 상태 · 다음 실행 · 보류 진단" "1. Status & Delivery")
  @ [ (let status = schedule_status_reading ~ko row.sch_status in
       field ~style:status.tone (t "상태" "Status") (status.mark ^ " " ^ status.word))
    ; field (t "예정" "Due") (timestamp row.sch_due_at_iso)
    ; field (t "다음 예정" "Next due") (timestamp row.sch_next_due_at_iso)
    ; field (t "반복" "Recurrence")
        (Masc_tui_schedule_recurrence.text ~ko ~now:(Unix.gettimeofday ())
           ~summary:row.sch_recurrence_summary row.sch_recurrence)
    ; field (t "만료" "Expires") (timestamp row.sch_expires_at_iso)
    ]
  @ hold_rows
  @ [ field
        ~style:
          (Option.fold ~none:(Theme.recede ()) ~some:schedule_queue_color
             row.sch_queue_projection_status)
        (t "대기열" "Queue") queue
    ; field
        ~style:
          (Option.fold ~none:(Theme.recede ()) ~some:schedule_reaction_color
             row.sch_reaction_projection_status)
        (t "반응" "Reaction") reaction
    ]
  @ schedule_turn_rows ~ko ~field row
  @ detail_section_heading ~width (t "2. 최근 실행 이력" "2. Wake History")
  @ schedule_wake_lines ~ko ~field ~timestamp ~row ~history:wake_history
      ~history_error:wake_history_error
  @ (if keeper_wake then
       [ Theme.recede (), ""
       ; Ansi.bold, t "  작업 결과" "  Work result"
       ; field (t "해당 턴" "Attribution")
           (t "이 실행이 연 턴 · 시작 줄과 종료 줄 사이"
              "the turn this wake opened, bounded by its start and finish rows")
       ; field (t "확인 방법" "Inspect")
           (t "기록된 두 시각 사이의 Keeper 호출이나 활동"
              "Keeper Calls or Activity between the two recorded times")
       ]
     else [])
  @ detail_section_heading ~width (t "3. 작업 요약 · 일정 식별자" "3. Summary & Identity")
  @ [ Ansi.bold, t "  요약" "  Summary" ]
  @ (Message_layout.wrap_body ~markdown:document_markdown
       ~max_cells:(max 1 (width - 4)) ~sanitize:Terminal_text.single_line summary
    |> List.map (fun line -> Ansi.reset, "    " ^ line))
  @ [ Theme.recede (), ""
    ; field (t "대상" "Target") (optional row.sch_payload_target)
    ]
  @ target_link
  @ [ field (t "종류" "Kind") (optional row.sch_payload_kind)
    ; field (t "실행 도구" "Dispatch tool") (optional row.sch_payload_dispatch_tool)
    ; field (t "지원" "Support") row.sch_payload_support
    ; field (t "일정" "Schedule") row.sch_schedule_id
    ; field (t "인스턴스" "Instance") row.sch_schedule_instance_id
    ; field (t "링크" "Link")
        (Link.reference Schedule
           (Terminal_text.single_line row.sch_schedule_id))
    ; field (t "출처" "Source") row.sch_source
    ; field (t "요청자" "Requested by") row.sch_requested_by
    ; field (t "등록자" "Scheduled by") row.sch_scheduled_by
    ; field (t "요청 시각" "Requested") (Terminal_text.short_timestamp row.sch_requested_at_iso)
    ]
  @ detail_section_heading ~width (t "4. 페이로드 원문" "4. Payload JSON & Digest")
  @ [ field (t "다이제스트" "Digest") row.sch_payload_digest
    ; Theme.recede (), ""
    ; Ansi.bold, t "  페이로드 JSON" "  Payload JSON"
    ]
  @ (document_json ~width:(max 1 (width - 4))
       (Yojson.Safe.pretty_to_string row.sch_payload)
    |> List.map (fun line -> Ansi.reset, "    " ^ line))

let schedule_detail_content (state : state) ~cols ~runner (row : schedule_row) =
  let width = max 1 (framed_inner_width cols) in
  let wire text = String.concat "\n"
      (List.map Terminal_text.single_line (String.split_on_char '\n' text)) in
  let warnings =
    (* A refused form's full diagnostic, which the list may have cut. *)
    List.map (fun line -> Theme.bad (), line) (schedule_form_refusal_rows state ~cols)
    @
    (* The latest action refusal is the row the result handler reveals.
       Source freshness still has its fixed summary outside this document. *)
    (match state.schedule_cancel_error with
     | Some (schedule_id, error) when String.equal schedule_id row.sch_schedule_id ->
         [ Theme.bad ()
         , (match error with
            | Request_failed detail ->
                ui_text state ~ko:"취소 오류: " ~en:"Cancel error: " ^ wire detail
            (* A cancel the workspace guard stopped was not sent, so it is said
               as kept back, alone, and not as an error of the cancel (RFC §2). *)
            | Request_withdrawn refusal ->
                wire (workspace_refusal_text ~ko:(state.ui_language = Lang_ko)
                        ~request:Kept_request.Schedule_cancel refusal)) ]
     | Some _ | None -> [])
    @ (match schedule_source_warning state with
       | None -> []
       | Some error -> [Theme.bad (), ui_text state ~ko:"출처: " ~en:"Source: " ^ wire error])
    @ (match state.schedule_cancel_armed with
       | None -> []
       | Some id ->
           let label =
             if String.equal id row.sch_schedule_id then schedule_row_label row
             else
               let rows =
                 Option.fold ~none:[] ~some:(fun (s : schedule_snapshot) -> s.scs_rows) state.schedules
               in
               resolve_schedule_title_in ~rows id
           in
           [ Theme.warn ()
           , schedule_cancel_armed_text ~ko:(state.ui_language = Lang_ko) label ]) in
  let fields = schedule_detail_lines ~ko:(state.ui_language = Lang_ko) ~width
      ~freshness:(schedule_list_freshness state) ~runner row
      ~wake_history:state.schedule_wake_history
      ~wake_history_error:state.schedule_wake_history_error in
  List.concat_map (fun (style, text) ->
      String.split_on_char '\n' text |> List.concat_map (fun line ->
        if Message_layout.display_width line <= width then [style, line]
        else match Message_layout.wrap_words ~max_cells:width line with
        | [] -> [style, ""]
        | lines -> List.map (fun text -> style, text) lines))
    (if warnings = [] then fields else warnings @ ((Theme.recede (), "") :: fields))

let schedule_detail_chrome_rows = max 0 (framed_chrome_rows - 2)

let schedule_detail_height ~rows ~warning_rows ~count =
  Masc_tui_scroll.content_height ~rows
    ~chrome:(schedule_detail_chrome_rows + warning_rows) ~count
    ~preview_keep:None

let schedule_detail_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let cols = if cols < keeper_split_threshold_cols then cols else cols - keeper_roster_pane_cols in
  let count = match state.schedule_detail_id, state.schedules with
    | Some id, Some snapshot ->
        (match List.find_opt (fun row -> String.equal row.sch_schedule_id id) snapshot.scs_rows with
         | None -> 0
         | Some row -> List.length (schedule_detail_content state ~cols ~runner:snapshot.scs_runner_status row))
    | Some _, None | None, _ -> 0 in
  let warning_rows = if Option.is_some (schedule_source_warning state) then 1 else 0 in
  count, schedule_detail_height ~rows ~warning_rows ~count

let schedule_detail_pane (state : state) ~rows ~cols ~runner (row : schedule_row) buf =
  (* Source freshness governs every evidence row, so it stays visible while
     the reader moves. The complete warning also remains in the reader for
     narrow viewports or a refusal longer than the fixed status summary. *)
  let warning = schedule_source_warning state in
  let warning_rows = match warning with None -> 0 | Some _ -> 1 in
  let lines = schedule_detail_content state ~cols ~runner row in
  let count = List.length lines in
  let height = schedule_detail_height ~rows ~warning_rows ~count in
  let scroll = Masc_tui_scroll.normalize ~count ~height state.schedule_scroll in
  box_line buf cols
    (here_row ~cols state
       ~path:
         [ ui_text state ~ko:"일정" ~en:"schedules"
         ; ui_text state ~ko:"상세" ~en:"details" ]
       ~readings:
         [ (let status =
              schedule_status_reading ~ko:(state.ui_language = Lang_ko) row.sch_status in
            wrap_style status.tone (status.mark ^ " " ^ status.word)) ]
       ~position:(Masc_tui_value.Position.window ~first:scroll ~shown:height ~total:count));
  box_divider buf cols;
  Option.iter (fun error -> box_line buf cols (data_unreliable_row ~cols error)) warning;
  let lines_window = Rows.of_list ~first:scroll ~height lines in
  for index = 0 to height - 1 do
    match Rows.at lines_window (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  scroll, Masc_tui_scroll.maximum ~count ~height
;;

(* The schedule list stays beside the schedule. Opening one used to hide the others, and the others
   are what say whether this is the one to act on. Below the split
   width there is no room for both and the detail keeps the screen. *)
let render_schedule_detail (state : state) ~runner (row : schedule_row) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll, _max_scroll =
    if cols < keeper_split_threshold_cols then
      schedule_detail_pane state ~rows ~cols ~runner row buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let labels =
        match state.schedules with
        | None -> []
        | Some snapshot ->
          List.map
            (fun (row : schedule_row) ->
              match row.sch_payload_summary with
              | Some summary when not (String.equal (String.trim summary) "") ->
                  Terminal_text.single_line summary
              | Some _ | None -> row.sch_schedule_id)
            snapshot.scs_rows
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      write_list_sidebar ~framed:false left_buf ~rows ~cols:left_cols
        ~title:(ui_text state ~ko:"일정" ~en:"Schedules")
        ~focused:false
        ~holding:
          (Option.bind state.schedules (fun snapshot ->
               snapshot.scs_request_count))
        ~labels
        ~selected:
          (Masc_tui_scroll.cursor_normalized ~count:(List.length labels)
             state.schedule_cursor);
      let answer =
        schedule_detail_pane state ~rows ~cols:(cols - left_cols) row
          ~runner right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language ~detail_open:true Schedules));
  finish_surface state ~clamped:(Schedule_detail_scroll scroll)
    ~surface_key:"schedule-detail" ~rows:terminal_rows ~cols buf

let render_schedules (state : state) =
  match state.schedule_detail_id, state.schedules with
  | Some schedule_id, Some snapshot ->
      (match
         List.find_opt
           (fun row -> String.equal row.sch_schedule_id schedule_id)
           snapshot.scs_rows
       with
       | Some row ->
           render_schedule_detail state ~runner:snapshot.scs_runner_status row
       | None -> render_schedule_list state)
  | Some _, None | None, _ -> render_schedule_list state


let planning_missing_goal_notice (state : state) ~goal_id =
  match state.home_opened_request with
  | Some (Home_goal_confirmation selected) -> String.equal selected goal_id
  | Some (Home_held_call _ | Home_gate_request _ | Home_operator_request _ | Home_question _)
  | None -> false

let render_planning (state : state) =
  match state.task_detail_id, state.task_focus, state.planning_mode with
  | Some _, Overview_tasks.Task_focus _, Planning_list ->
      (match Task_selection.detail_row
               ~detail_id:state.task_detail_id ~tasks:(Masc_tui_types.task_domain_values state) with
       | Some task -> render_task_detail state task
       | None -> render_work_tasks state)
  | None, Overview_tasks.Task_focus _, Planning_list -> render_work_tasks state
  | _, _, Planning_list -> render_planning_list state
  | (_, Overview_tasks.No_task_focus, Planning_detail goal_id)
  | (_, Overview_tasks.Task_focus _, Planning_detail goal_id) ->
      let goals = match state.planning with None -> [] | Some p -> p.pl_goals in
      match List.find_opt (fun g -> g.pg_id = goal_id) goals with
      | Some goal ->
          ignore (Masc_tui_types.progress_clock_option state ~slot:"planning-missing" ~now:(Unix.gettimeofday ()) None);
          let confirmation = planning_confirmation_view state ~goal_id in
          render_planning_detail state
            ~armed:(goal_action_armed_for state goal_id) ~confirmation goal
      | None when planning_missing_goal_notice state ~goal_id ->
               let terminal_rows, cols = get_terminal_size () in
               let now = Unix.gettimeofday () in
               let ko = state.ui_language = Lang_ko in
               let started_at =
                 Masc_tui_types.progress_clock_option state
                   ~slot:"planning-missing" ~now
                   (if Option.is_none state.planning_error then Some goal_id else None)
               in
               let progress_sheet =
                 match state.planning_error with
                 | Some _ -> None
                 | None ->
                     Some
                       { ps_title = ui_text state ~ko:"목표 상세 불러오는 중" ~en:"Loading goal detail"
                       ; ps_detail = Some (ui_text state
                           ~ko:"목표 목록에서 상세 정보를 기다리고 있습니다"
                           ~en:"Waiting for goal detail from the planning source")
                       ; ps_started_at = started_at
                       ; ps_meter = None
                       ; ps_action_hint = Some (ui_text state ~ko:"r:새로고침  Esc:대시보드" ~en:"r:refresh  Esc:Dashboard")
                       ; ps_blocking = false
                       }
               in
               surface_chrome ~overflow:Fits ?progress_sheet ~now state ~terminal_rows ~cols
                 ~surface_key:"planning_detail"
                 ~title:
                   (here_row ~cols state
                      ~path:[ ui_text state ~ko:"목표" ~en:"goal" ]
                      ~readings:
                        (match state.planning_error with
                         | Some _ -> []
                         | None ->
                             [ progress_inline ~ko ~now ?started_at
                                 (ui_text state ~ko:"목표 상세 읽는 중" ~en:"reading goal detail") ])
                      ~position:None)
                 ~status:[] ~hints:(ui_text state ~ko:"Esc:대시보드  r:새로고침" ~en:"Esc:Dashboard  r:refresh")
                 ~body:(fun ~budget:_ c ->
                   match state.planning_error with
                   | Some error ->
                       c.push_styled ~style:(Theme.bad ())
                         ((ui_text state ~ko:" 목표 상세 조회 실패 · " ~en:" Goal detail unavailable · ")
                          ^ Terminal_text.single_line error)
                   | None ->
                       c.push
                         (" " ^ progress_inline ~ko ~now ?started_at
                            (ui_text state ~ko:"목표 상세 읽는 중 · 조회 대기"
                               ~en:"Reading goal detail · waiting for its source")))
      | None -> render_planning_list state
