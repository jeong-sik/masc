(** Work / Tasks, Planning (Goals) and Schedules screens. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim

module Frame_presenter = Masc_tui_frame_presenter
module Magnitude = Masc_tui_magnitude
module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Render_schedule = Masc_tui_render_schedule
module Task_selection = Masc_tui_task_selection
module Overview_tasks = Masc_tui_overview_tasks
module Planning_detail = Masc_tui_planning_detail
module Link = Masc_tui_link
module Chart = Masc_tui_chart

module Task_id_set = Set.Make (String)

let task_line ~cols ~ordinal ~task_ids ~use_ordinals (task : task) =
  let status = Masc_domain.task_status_to_string task.status in
  (* The icon and the status word share one color so the row's state reads at
     a glance: in-flight rows in cyan, waiting rows dimmed. Terminal states
     never reach this list ([active_tasks_of_domain] filters them); they keep
     the default so a future caller showing one is visible rather than wrong. *)
  let status_color =
    match task.status with
    | Masc_domain.Claimed _ | Masc_domain.InProgress _ -> (Theme.info ())
    | Masc_domain.AwaitingVerification _ -> Theme.warn ()
    | Masc_domain.Todo -> Ansi.dim
    | Masc_domain.Done _ | Masc_domain.Cancelled _ -> ""
  in
  let assignee =
    match Masc_domain.task_assignee_of_status task.status with
    | Some name -> Printf.sprintf " @%s" (Terminal_text.single_line name)
    | None -> ""
  in
  let goal_tag =
    match task.goal_ids with
    | [] -> ""
    | goal :: _ ->
        Printf.sprintf " %s%s%s" (Theme.recede ())
          (Terminal_text.single_line goal)
          Ansi.reset
  in
  let prefix id =
    Printf.sprintf "%s%s%s %s[%s]%s " status_color
      (task_status_icon task.status) Ansi.reset Ansi.dim id Ansi.reset
  in
  let suffix status owner =
    Printf.sprintf " %s(%s%s)%s %s" status_color status owner Ansi.reset
      (priority_indicator task.priority)
  in
  (* Preserve the Task number before spending cells on its owner and title.
     The canonical prefix may yield on narrow screens, but its digits do not
     share a truncation budget with unrelated fields. *)
  let available = max 0 (framed_inner_width cols - 2) in
  let id = Terminal_text.single_line task.id in
  let short_id =
    if String.starts_with ~prefix:"task-" id then
      let digits = String.sub id 5 (String.length id - 5) in
      if digits <> "" && String.for_all (fun c -> c >= '0' && c <= '9') digits then digits else id
    else id in
  let status =
    let required = Message_layout.display_width (prefix "")
      + Message_layout.display_width (suffix status "")
      + Message_layout.display_width id + Message_layout.display_width "Task" in
    if required <= available then status
    else match task.status with
      | Masc_domain.Todo -> "todo"
      | Masc_domain.Claimed _ -> "claimed"
      | Masc_domain.InProgress _ -> "active"
      | Masc_domain.AwaitingVerification _ -> "verify"
      | Masc_domain.Done _ -> "done"
      | Masc_domain.Cancelled _ -> "cancelled"
  in
  let fixed_chrome = Message_layout.display_width (prefix "")
    + Message_layout.display_width (suffix status "") in
  let fields = max 0 (available - fixed_chrome) in
  let id = if Message_layout.display_width id + Message_layout.display_width "Task" <= fields
    then id else short_id in
  (* A row coordinate stays distinct when an opaque ID cannot fit. The
     original identifier remains the selection key and is readable in detail. *)
  let id =
    if use_ordinals || Message_layout.display_width id > fields
       || (not (String.equal id task.id)
           && Task_id_set.mem id task_ids)
    then Printf.sprintf "row %d" ordinal else id
  in
  let remainder = max 0 (fields - Message_layout.display_width id) in
  let title = Terminal_text.single_line task.title in
  (* A short title needs only its measured cells. Its spare allocation can
     show the owner instead of padding beside a shortened identity. *)
  let title_cells = min (remainder / 2) (Message_layout.display_width title) in
  let assignee =
    fit_width assignee
      (min (remainder - title_cells) (Message_layout.display_width assignee))
  in
  let prefix = prefix id in
  let suffix = suffix status assignee in
  let fixed = Message_layout.display_width prefix + Message_layout.display_width suffix in
  let goal_tag =
    if fixed + Message_layout.display_width title
       + Message_layout.display_width goal_tag <= available
    then goal_tag else ""
  in
  prefix ^ fit_width title
    (max 0 (available - fixed - Message_layout.display_width goal_tag))
  ^ suffix ^ goal_tag


(* One task's event history, appended after the detail body so it rides the
   same scroll. Loaded lazily on detail entry; the id check drops an answer
   for a task the operator already left. Rows are raw event-stream lines, so
   only the fields present are drawn. *)
let task_detail_lines (state : state) ~cols (task : Masc_domain.task) =
  let width=max 1 (framed_inner_width cols - 2) in
  let history=Masc_tui_fetched.view_for ~equal:String.equal state.task_history ~key:task.id in
  let stalled_note =
    match state.operator_stalled with
    | Masc_tui_agenda.Read rows ->
        Option.to_list
          (Option.map
             (fun (row : Masc_tui_agenda.stalled) ->
               " Needs your decision · "
               ^ Terminal_text.single_line row.what
               ^ " · press x to cancel")
             (List.find_opt
                (fun (row : Masc_tui_agenda.stalled) ->
                  String.equal row.task_id task.id)
                rows))
    | Masc_tui_agenda.Not_read | Masc_tui_agenda.Read_failed _ -> []
  in
  let failures=stalled_note
    @ Option.to_list (Option.map (fun detail -> " Task read failed · last observation: " ^ detail) state.tasks_error)
    @ (match task_goal_reading state ~task_id:task.id with
      | Masc_tui_agenda.Read_failed detail -> [" Goal links unavailable: " ^ detail]
      | Not_read | Read _ -> []) in
  (failures |> List.concat_map (Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols))))
  @ task_document_lines state ~cols Masc_tui_task_document.Body
  @ (Masc_tui_task_document.history_status_lines ~width ~view:history
      ~in_flight:(Masc_tui_fetched.in_flight state.task_history)
     |> List.concat_map (fun line -> if line="" then [""] else
       Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols)) line))
  @ task_document_lines state ~cols Masc_tui_task_document.History

let task_detail_height ~rows ~count =
  Masc_tui_scroll.content_height ~rows ~chrome:framed_chrome_rows ~count
    ~preview_keep:None ~overflow_takes_row:true

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
  let header = Printf.sprintf "%s  %s%s%s  %s"
    (screen_title " MASC Task") Ansi.dim
    (bracketed ~max_cells:20 (Terminal_text.single_line task.id)) Ansi.reset
    (connection_badge state) in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let lines = task_detail_lines state ~cols task in
  let count = List.length lines in
  let height = task_detail_height ~rows ~count in
  let scroll = Masc_tui_scroll.normalize ~count ~height state.task_detail_scroll in
  let window = Rows.of_list ~first:scroll ~height lines in
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some line -> box_line_styled buf cols ~style:Ansi.dim line
  done;
  Option.iter (box_line_styled buf cols ~style:(Theme.recede ()))
    (Masc_tui_scroll.position_row ~scroll ~height count);
  box_bottom buf cols;
  scroll
;;

(* The task list stays beside the task. Overview's rows are the queue
   this task sits in, and reading one used to cost the reader their
   place in it. Below the split width the detail keeps the screen. *)
let render_task_detail (state : state) (task : Masc_domain.task) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let offset =
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
      write_list_sidebar_selection left_buf ~rows ~cols:left_cols
        ~title:"Tasks" ~focused:false
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
       ~status:[ Masc_tui_footer.Refresh_interval state.refresh_interval ]
       ~hints:"j/k:scroll  PgUp/PgDn:page  Home/End  x:cancel  Left / Esc:back  r:refresh");

  let offset=if task_documents_pending state then state.task_detail_scroll else offset in
  finish_surface state ~clamped:(Task_detail offset) ~surface_key:"task-detail" ~rows:terminal_rows ~cols buf

let render_work_tasks (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Overview_tasks.work_rows state.tasks in
  let task_ids =
    Task_id_set.of_list
      (List.map (fun (task : Tui_decode.task) -> Terminal_text.single_line task.id) rows)
  in
  let ordinal_labels =
    Task_id_set.of_list (List.mapi (fun index _ -> Printf.sprintf "row %d" (index + 1)) rows)
  in
  (* A canonical ID may itself occupy the row-coordinate namespace. In
     that population every row uses its unique coordinate, so no fallback
     can impersonate a different Task. Detail and selection retain IDs. *)
  let use_ordinals = not (Task_id_set.disjoint task_ids ordinal_labels) in
  let selected =
    Overview_tasks.work_selected_index state.tasks
      ~selected:(Overview_tasks.selection state.task_focus)
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols
    ~surface_key:"work-tasks"
    ~title:(screen_title " MASC Work / Tasks")
    ~hints:Masc_tui_keys.footer_hints_work_tasks
    ~body:(fun ~budget c ->
      let pending_note = local_source_pending_note state Local_work in
      Option.iter c.push pending_note;
      (match state.local_workspace, state.task_flow with
       | Local_workspace_unread, _ ->
           c.push "  Active tasks · not observed"
       | Local_workspace_failed detail, _ ->
           c.push ("  Active tasks · unavailable: " ^ Terminal_text.single_line detail)
       | Local_workspace_read, None ->
           c.push "  Active tasks · unavailable"
       | Local_workspace_read, Some _ ->
           c.push (Printf.sprintf
             "  Open tasks · %d in progress, awaiting verification, claimed, or todo"
             (List.length rows)));
      (match state.task_flow with
       | None -> c.push "  Task history · not observed"
       | Some flow ->
           let completed =
             List.map (fun (day : Masc_tui_task_flow.day) ->
               day.d_completed) flow.daily in
           c.push (Printf.sprintf "  Currently done by UTC day (%d days): %s"
                     (List.length flow.daily) (Chart.sparkline ~min:0 completed)));
      let link_error = match state.goal_task_links with
        | Goal_links_read_failed reason -> Some reason
        | Goal_links_not_read | Goal_links_read _ -> None in
      let reasons =
        [ Terminal_text.optional_single_line state.tasks_error
        ; Terminal_text.optional_single_line link_error
        ]
        |> List.filter_map Fun.id in
      (match reasons with
       | [] -> ()
       | reasons -> c.push ("  Coverage: " ^ String.concat " · " reasons));
      c.push_divider ();
      let header_rows =
        3 + (if Option.is_some pending_note then 1 else 0)
        + (if reasons = [] then 0 else 1)
      in
      let count = List.length rows in
      let room = work_tasks_room ~budget ~header_rows ~count in
      if budget > header_rows && rows = [] && Option.is_some state.task_flow then
        c.push "  No open tasks";
      let first =
        match selected with
        | None -> 0
        | Some index ->
            if room <= 0 then 0
            else max 0 (index - room + 1)
      in
      (* [task_line] is the one row a task draws: its status icon and word in
         one colour, id, title, assignee, priority and Goal, each through the
         terminal sanitiser. *)
      List.iteri
        (fun index (task : Tui_decode.task) ->
           if index >= first && index < first + room then
             let line = "  " ^ task_line ~cols ~ordinal:(index + 1) ~task_ids ~use_ordinals task in
             if Some index = selected then
               c.push_selected (Masc_tui_theme.strip_sgr line)
             else c.push line)
        rows;
      if budget - header_rows > 1 && count > room then
        c.push_styled ~style:(Theme.recede ())
          (Printf.sprintf "  [tasks %s]"
             (Masc_tui_scroll.window_text ~scroll:first ~height:room count)))

(* The lifecycle as a rail, not a single word. The phase says where the goal
   is; it never said what the stages are or which way they run, so "what does
   [c] do here" was a question the screen could not answer. The occupied stop
   is bracketed and keeps its colour, the rest stay dim.

   [Dropped] is not a stop on this line -- it leaves the line -- so a dropped
   goal draws what it is and how to come back instead of highlighting a stop
   on a rail it is no longer on. *)
let planning_stage_rail (phase : Goal_phase.t) =
  let stop stage =
    let label = planning_phase_label stage in
    if stage = phase then
      planning_phase_color stage ^ Ansi.bold ^ "[" ^ label ^ "]" ^ Ansi.reset
    else Ansi.dim ^ " " ^ label ^ " " ^ Ansi.reset
  in
  let arrow = Ansi.dim ^ "\xe2\x94\x80\xe2\x96\xb6" ^ Ansi.reset in
  match phase with
  | (Goal_phase.Paused _ | Goal_phase.Blocked _) as suspended ->
    planning_phase_color suspended ^ "[" ^ planning_phase_label suspended ^ "]" ^ Ansi.reset
    ^ (match Goal_phase.resume_phase suspended with
       | None -> "" | Some target -> "  resumes " ^ planning_phase_label target)
  | Goal_phase.Dropped ->
    planning_phase_color Goal_phase.Dropped
    ^ Ansi.bold ^ "[dropped]" ^ Ansi.reset
    ^ Ansi.dim ^ "  (off the line; [o] puts it back on executing)" ^ Ansi.reset
  | Goal_phase.Executing | Goal_phase.Verifying | Goal_phase.Awaiting_confirmation | Goal_phase.Completed ->
    String.concat arrow
      [ stop Goal_phase.Executing
      ; stop Goal_phase.Verifying
      ; stop Goal_phase.Awaiting_confirmation
      ; stop Goal_phase.Completed
      ]
;;

let planning_detail_tone (tone : Planning_detail.tone) =
  match tone with
  | Planning_detail.Proven -> (Theme.ok ())
  | Planning_detail.Refused -> (Theme.bad ())
  | Planning_detail.Waiting | Planning_detail.Unreadable -> (Theme.warn ())
  | Planning_detail.Note | Planning_detail.Quiet -> Ansi.dim
  | Planning_detail.Plain -> Ansi.default_fg

(* What moves this goal next, in one sentence, from the pair the operator can
   see separately but had to combine themselves: the phase and the judge's
   last word. [executing] with a refusal on the ledger is a different
   instruction from [executing] with nothing on it, and both drew the same
   word. Only the goal phase decides here -- the linked tasks have their own
   surface and their own verdicts. *)
let planning_next_step (goal : planning_goal) =
  match goal.pg_phase, goal.pg_proof with
  | Goal_phase.Executing, Tui_decode.Proof_refuted _ ->
    ( (Theme.bad ())
    , "refused - fix what the verdict names below, then [c] to resubmit" )
  | (Goal_phase.Executing, Proof_idle) | (Goal_phase.Executing, Proof_pending)
  | (Goal_phase.Executing, Proof_proven _) | (Goal_phase.Executing, Proof_stale _)
  | (Goal_phase.Executing, Proof_unreadable _) ->
    ( Ansi.dim
    , "work the linked tasks, then [c] to submit it for verification" )
  | (Goal_phase.Verifying, Proof_idle) | (Goal_phase.Verifying, Proof_pending)
  | (Goal_phase.Verifying, Proof_proven _) | (Goal_phase.Verifying, Proof_refuted _)
  | (Goal_phase.Verifying, Proof_stale _) | (Goal_phase.Verifying, Proof_unreadable _) ->
    let tone, text = Planning_detail.verifying_next_step goal.pg_verifier_unreconciled in
    (planning_detail_tone tone, text)
  | (Goal_phase.Awaiting_confirmation, Proof_idle)
  | (Goal_phase.Awaiting_confirmation, Proof_pending)
  | (Goal_phase.Awaiting_confirmation, Proof_proven _)
  | (Goal_phase.Awaiting_confirmation, Proof_refuted _)
  | (Goal_phase.Awaiting_confirmation, Proof_stale _)
  | (Goal_phase.Awaiting_confirmation, Proof_unreadable _) ->
    (Theme.warn (), "proof passed - [a] reads the proof for your final confirmation")
  | (Goal_phase.Completed, Proof_idle) | (Goal_phase.Completed, Proof_pending)
  | (Goal_phase.Completed, Proof_proven _) | (Goal_phase.Completed, Proof_refuted _)
  | (Goal_phase.Completed, Proof_stale _) | (Goal_phase.Completed, Proof_unreadable _) -> (Ansi.dim, "reached its target - [o] reopens it")
  | (Goal_phase.Dropped, Proof_idle) | (Goal_phase.Dropped, Proof_pending)
  | (Goal_phase.Dropped, Proof_proven _) | (Goal_phase.Dropped, Proof_refuted _)
  | (Goal_phase.Dropped, Proof_stale _) | (Goal_phase.Dropped, Proof_unreadable _) -> (Ansi.dim, "abandoned - [o] reopens it")
  | (Goal_phase.Paused _, Proof_idle) | (Goal_phase.Paused _, Proof_pending)
  | (Goal_phase.Paused _, Proof_proven _) | (Goal_phase.Paused _, Proof_refuted _)
  | (Goal_phase.Paused _, Proof_stale _) | (Goal_phase.Paused _, Proof_unreadable _) -> (Theme.warn (), "paused - [r] restores the prior state; linked Tasks continue independently")
  | (Goal_phase.Blocked _, Proof_idle) | (Goal_phase.Blocked _, Proof_pending)
  | (Goal_phase.Blocked _, Proof_proven _) | (Goal_phase.Blocked _, Proof_refuted _)
  | (Goal_phase.Blocked _, Proof_stale _) | (Goal_phase.Blocked _, Proof_unreadable _) -> (Theme.bad (), "blocked - [u] restores the prior state; linked Tasks continue independently")
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
           | Goal_reconcile_step.Rearm_proof -> "검증기가 요청을 다시 준비하지 못함"
           | Goal_reconcile_step.Read_original -> "검증기가 보존된 요청을 읽지 못함"
           else Planning_detail.unreconciled_heading blocked.vu_step)
          (Terminal_text.single_line blocked.vu_detail) )
  | None ->
  match goal.pg_proof with
  | Tui_decode.Proof_proven None -> Some ((Theme.ok ()), text "검증 통과" "proven")
  | Tui_decode.Proof_proven (Some evidence) ->
      Some ((Theme.ok ()), text "검증 통과: " "proven: " ^ Terminal_text.single_line evidence)
  | Tui_decode.Proof_refuted None -> Some ((Theme.bad ()), text "검증 거절" "refused")
  | Tui_decode.Proof_refuted (Some reason) ->
      Some ((Theme.bad ()), text "검증 거절: " "refused: " ^ Terminal_text.single_line reason)
  | Tui_decode.Proof_pending -> Some ((Theme.warn ()), text "완료 판정 대기" "waiting for the completion judge")
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
        (fun note -> (Ansi.dim, text "메모: " "note: " ^ note))
        (Terminal_text.optional_single_line goal.pg_last_review_note)
;;

let planning_selected_detail ~ko (goal : planning_goal) =
  let metric =
    match
      Terminal_text.optional_single_line goal.pg_metric,
      Terminal_text.optional_single_line goal.pg_target_value
    with
    | Some name, Some target ->
        Printf.sprintf (if ko then "지표: %s → %s" else "metric: %s → %s") name target
    | Some name, None -> (if ko then "지표: " else "metric: ") ^ name
    | None, Some target -> (if ko then "목표값: " else "target: ") ^ target
    | None, None -> if ko then "지표: —" else "metric: —"
  in
  match planning_proof_detail ~ko goal with
  | None -> Ansi.dim, Printf.sprintf "%s \xc2\xb7 %s" goal.pg_id metric
  | Some (colour, proof) ->
      colour,
      Printf.sprintf "%s \xc2\xb7 %s \xc2\xb7 %s" proof goal.pg_id metric
;;

(* Freshness in one short word: the exact timestamps live in the detail
   pane; the row only needs to separate "touched today" from "quiet for
   weeks". A timestamp that does not parse renders nothing here -- the raw
   string is still shown unmodified in the detail pane. *)
let planning_updated_age ~now (goal : planning_goal) =
  match goal.pg_updated_at with
  | None -> None
  | Some iso ->
      Option.map
        (fun then_ ->
           let delta = max 0. (now -. then_) in
           if delta < 60. then "now"
           else if delta < 3600. then
             Printf.sprintf "%dm" (int_of_float (delta /. 60.))
           else if delta < 86400. then
             Printf.sprintf "%dh" (int_of_float (delta /. 3600.))
           else Printf.sprintf "%dd" (int_of_float (delta /. 86400.)))
        (Masc_domain.parse_iso8601_opt iso)

(** Render the Planning surface (list view). *)


(* This is snapshot provenance, not fresh Goal/proof authority. Keep the
   warning outside the scrollable proof body so proof presentation indices
   still refer to the same body rows. Header and viewport use the same rows. *)
let planning_stale_notice_rows (state : state) ~cols =
  let ko = state.ui_language = Lang_ko in
  let notice = match state.workspace_identity, state.planning_error with
    | Workspace_identity_match_unconfirmed detail, _ -> Some ((if ko then "워크스페이스 미확인" else "Workspace unconfirmed"), detail)
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
        ^ Terminal_text.single_line snapshot.pl_generated_at)
      @ (match Terminal_text.optional_single_line (Some error) with
         | None -> []
         (* Keep verbose diagnostics on the existing error row; a long
            transport reason must not consume the Goal/proof viewport. *)
         | Some detail -> [data_unreliable_row ~cols detail])
  | None, (None | Some _) | Some _, None -> []

let planning_phase_korean = function
  | Goal_phase.Kind.Executing -> "진행"
  | Goal_phase.Kind.Verifying -> "검증 중"
  | Goal_phase.Kind.Awaiting_confirmation -> "확인 대기"
  | Goal_phase.Kind.Completed -> "완료"
  | Goal_phase.Kind.Dropped -> "포기"
  | Goal_phase.Kind.Paused -> "일시정지"
  | Goal_phase.Kind.Blocked -> "막힘"

let planning_summary_reading ~cols (state : state) =
  let ko = state.ui_language = Lang_ko in
  let text korean english = if ko then korean else english in
  let section heading rows : Masc_tui_detail_reading.section =
    { heading; body = String.concat "\n" (List.map Masc_tui_theme.strip_sgr rows) }
  in
  let warning =
    (match state.workspace_identity with
     | Workspace_identity_match_unconfirmed detail ->
         [text "워크스페이스 미확인: " "Workspace unconfirmed: " ^ Terminal_text.single_line detail]
     | Workspace_identity_match | Workspace_identity_unread | Workspace_identity_mismatch _ -> [])
    @ Option.to_list (Option.map (fun detail ->
        text "조회 실패: " "Read failed: " ^ Terminal_text.single_line detail) state.planning_error)
  in
  let sections = match state.planning with
    | None -> [section (text "관측 상태" "Observation")
        (warning @ [text "목표 관측 없음" "No Goal observation"])]
    | Some p ->
        let stamps =
          [ text "표시 중인 서버 스냅샷: " "Displayed server snapshot: " ^ Terminal_text.single_line p.pl_generated_at ]
          @ (match state.planning_baseline with
             | None -> [text "기준 스냅샷 없음" "No baseline snapshot"]
             | Some first -> [text "기준 서버 스냅샷: " "Baseline server snapshot: " ^ Terminal_text.single_line first.pl_generated_at])
        in
        let history = match p.pl_goal_history with
          | [] -> [text "목록 밖 이력 없음" "No unlisted Goal history"]
          | history ->
              let ended = List.length (List.filter (fun row -> Option.is_some row.pgh_closed_at) history) in
              (if ko then Printf.sprintf "목록 밖 %d개 · 종결 결과 미기록 %d개" (List.length history) (List.length history - ended)
               else planning_goal_history_summary ~unlisted:(List.length history) ~ended)
              :: List.map (fun row ->
                   let name = Option.value row.pgh_title ~default:row.pgh_goal_id |> Terminal_text.single_line in
                   let phase = match row.pgh_final_phase with
                     | None -> text "단계 미기록" "phase not recorded"
                     | Some phase ->
                         let shown = if ko then
                             Option.fold ~none:(Terminal_text.single_line phase)
                               ~some:planning_phase_korean (Goal_phase.Kind.parse phase)
                           else Terminal_text.single_line phase in
                         text "마지막 단계 " "last phase " ^ shown in
                   let outcome = if Option.is_some row.pgh_closed_at
                     then text "종결 시각 기록됨" "close time recorded"
                     else text "종결 결과 미기록" "terminal outcome not recorded" in
                   let lifetime = match row.pgh_lifetime_hours with
                     | None -> ""
                     | Some hours ->
                         if hours >= 48. then Printf.sprintf " · %.1fd" (hours /. 24.)
                         else Printf.sprintf " · %.1fh" hours in
                   name ^ " · " ^ phase ^ " · " ^ outcome ^ lifetime) history
        in
        let rollup = p.pl_rollup in
        let backlog = p.pl_backlog in
        let total_goals = rollup.pr_active + rollup.pr_verifying + rollup.pr_awaiting_confirmation
          + rollup.pr_done + rollup.pr_paused + rollup.pr_blocked + rollup.pr_dropped in
        let goal_rows = if not ko then planning_rollup_rows ~cols rollup else
          [ Printf.sprintf "전체 %d · 진행 %d · 검증 %d · 확인 대기 %d" total_goals rollup.pr_active rollup.pr_verifying rollup.pr_awaiting_confirmation
          ; Printf.sprintf "완료 단계 %d · 일시정지 %d · 막힘 %d · 포기 %d" rollup.pr_done rollup.pr_paused rollup.pr_blocked rollup.pr_dropped ] in
        let backlog_rows = if not ko then pack_planning_summary_rows ~cols (planning_backlog_clauses backlog) else
          [ Printf.sprintf "할 일 %d · 담당 %d · 진행 %d" backlog.pb_todo backlog.pb_claimed backlog.pb_running
          ; Printf.sprintf "검증 대기 %d · 완료 %d · 취소 %d" backlog.pb_awaiting_verification backlog.pb_done backlog.pb_cancelled ] in
        let change_rows = pack_planning_summary_rows ~cols
            (planning_change_clauses ~ko ~baseline:state.planning_baseline p) in
        [section (text "관측과 기준" "Observation and baseline") (warning @ stamps);
         section (text "목표 상태" "Goal states") goal_rows;
         section (text "전체 Task 현황" "Global Task backlog") backlog_rows;
         section (text "기준 대비 변화" "Change from baseline") change_rows;
         section (text "목록 밖 목표 이력" "Unlisted Goal history") history]
  in
  Masc_tui_detail_reading.create ~ko ~title:(text "작업 요약" "Work summary") sections

(* The list owns the first row of the summary; its complete counts and the
   two server timestamps stay in the captured reading at [b]. *)
let planning_compact_summary ~cols (state : state) (p : planning_snapshot) =
  let ko = state.ui_language = Lang_ko in
  let r = p.pl_rollup in
  let total = r.pr_active + r.pr_verifying + r.pr_awaiting_confirmation
    + r.pr_done + r.pr_dropped + r.pr_paused + r.pr_blocked in
  let clauses =
    [ if ko then "b:요약" else "b:summary"
    ]
    @ (if r.pr_awaiting_confirmation = 0 then [] else
         [Printf.sprintf (if ko then "확인 대기 %d" else "confirm %d") r.pr_awaiting_confirmation])
    @ (if r.pr_blocked = 0 then [] else
         [Printf.sprintf (if ko then "막힘 %d" else "%d blocked") r.pr_blocked])
    @ (if r.pr_verifying = 0 then [] else
         [Printf.sprintf (if ko then "검증 중 %d" else "%d verifying") r.pr_verifying])
    @ [Printf.sprintf (if ko then "목표 %d" else "%d goals") total]
    @ [Printf.sprintf (if ko then "완료 단계 %d" else "%d in completed phase") r.pr_done]
    @ (if p.pl_goal_history = [] then [] else
         [Printf.sprintf (if ko then "목록 밖 %d" else "%d no longer listed") (List.length p.pl_goal_history)])
  in
  let fits line = Message_layout.display_width line <= framed_inner_width cols in
  let omitted line =
    let with_mark = if line = "" then "  b…" else line ^ " · …" in
    if fits with_mark then with_mark else "  b…"
  in
  let rec pack line = function
    | [] -> line
    | clause :: rest ->
        let next = if line = "" then "  " ^ clause else line ^ " · " ^ clause in
        if fits next && (rest = [] || fits (next ^ " · …")) then pack next rest
        else omitted line
  in
  pack "" clauses

let render_planning_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let list_page_rows = ref 1 in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let tail = Buffer.create 256 in
  box_bottom tail cols;
  Buffer.add_string tail
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints ~detail_open:false state.view));
  let tail_rows = count_frame_lines tail in

  let now_unix = Unix.gettimeofday () in
  let modes = if ko then
      let sort = match state.planning_sort with
        | Planning_sort_phase_priority -> "단계/우선순위"
        | Planning_sort_updated -> "최근 갱신"
        | Planning_sort_due -> "기한" in
      let filter = match state.planning_filter with
        | Planning_filter_all -> "전체" | Planning_filter_active -> "미종결"
        | Planning_filter_completed -> "완료" | Planning_filter_dropped -> "포기" in
      Printf.sprintf "정렬:%s  필터:%s" sort filter
    else Printf.sprintf "sort:%s  filter:%s"
      (planning_sort_label state.planning_sort)
      (planning_filter_label state.planning_filter) in
  (* Connection identity keeps its place. Modes share the title only when
     every navigation tab retains the width it has without them. *)
  let chrome = "  " ^ connection_badge state in
  let riding = "  " ^ modes ^ chrome in
  let title_alone =
    planning_workspace_title state ~cols ~tab:Planning_goals ~window:""
      ~after:chrome
  in
  let title_with_modes =
    planning_workspace_title state ~cols ~tab:Planning_goals ~window:""
      ~after:riding
  in
  (* The modes ride when they cost nothing: the strip drawn beside them is the
     same strip, and the row still fits. Measuring only the width let the strip
     pay instead -- it cuts rather than overflowing, so any row "fits" once the
     tabs are allowed to disappear, and at a hundred columns Planning answered
     yes by hiding "Task Review" and "Task Verdicts". The modes have a row of
     their own; the two other tabs and the badge have nowhere else to go. *)
  let modes_fit_header =
    String.equal title_alone title_with_modes
    && Message_layout.display_width (title_with_modes ^ riding)
       <= framed_inner_width cols
  in
  let header =
    if modes_fit_header then title_with_modes ^ riding else title_alone ^ chrome
  in

  box_top buf cols;
  box_line buf cols header;
  (* Show the modes once, but do not hide them behind a clipped title. *)
  if not modes_fit_header then
    box_line_styled buf cols ~style:(Theme.recede ()) ("  " ^ modes);
  List.iter (box_line buf cols) (planning_stale_notice_rows state ~cols);
  box_divider buf cols;

  let goals =
    match state.planning with
    | None -> []
    | Some p ->
        planning_visible_goals ~filter:state.planning_filter
          ~sort:state.planning_sort p.pl_goals
  in
  let count = List.length goals in
  let planning_error =
    Terminal_text.optional_single_line state.planning_error
  in

  (match state.planning with
   | None ->
       (match planning_error with
        | Some err ->
            box_line buf cols (data_unreliable_row ~cols err)
        | None ->
            box_line buf cols (Ansi.dim ^ page_unread_note ^ Ansi.reset));
       for _ = 1 to rows - count_frame_lines buf - tail_rows do
         box_empty buf cols
       done
   | Some p ->
       (* Keep the selected Goal, its detail and the footer before spending
          a row on the summary. The complete reading is available at [b]. *)
       let phase_width = planning_phase_column + 2 in
       let goal_layout =
         Render_schedule.planning_layout
           ~inner_width:(max 1 (framed_inner_width cols - 2))
           ~phase_width
       in
       let list_header = Buffer.create 256 in
       box_line_styled list_header cols ~style:(Theme.recede ())
         ("  "
         ^ (if ko then Render_schedule.planning_header_row_korean ~phase_width ~layout:goal_layout
            else Render_schedule.planning_header_row ~phase_width ~layout:goal_layout));
       let divider = Buffer.create 128 in
       box_divider divider cols;
       let selection_rows = if count = 0 then 0 else 1 in
       let reserved_rows =
         count_frame_lines list_header + (2 * count_frame_lines divider)
         + 1 + selection_rows + tail_rows
       in
       if count_frame_lines buf + 1 + reserved_rows <= rows then
         box_line buf cols (planning_compact_summary ~cols state p);
       Buffer.add_buffer buf divider;
       (* The list drew rows and never said what they were. *)
       Buffer.add_buffer buf list_header;
       (* What the JUDGE column's marks mean, once, under the header that
          names it. The glyphs are the only part of a row an operator cannot
          read straight off, and every one of them changes what to do next --
          which is why the legend says the marks this list draws and only those.
          Wrap complete explanations within the frame's cell width: a clipped
          legend would lose a verdict and add a truncation mark identical to
          the stale-proof glyph. A list narrow enough to give up the JUDGE
          column draws no marks, so it draws no legend either. *)
       (* Reserve the divider, a goal (or empty note), and the selected
          verdict before spending rows on the legend. At the minimum
          height the headers and summary stay in place and a goal remains
          visible; taller frames get the legend back. *)
       let list_floor = if count = 0 then 1
         else min 5 count + (if count > 5 then 1 else 0) in
       let rows_after_legend = 1 + list_floor + selection_rows + tail_rows in
       let judge_legend =
         if
           List.mem Render_schedule.Planning_proof
             goal_layout.Masc_tui_table.shown
         then
           Masc_tui_planning_proof_mark.legend_rows
             ~ko
             ~max_cells:(framed_inner_width cols)
             ~max_rows:(rows - count_frame_lines buf - rows_after_legend)
             (List.map (fun (g : planning_goal) -> g.pg_proof) goals)
         else []
       in
       List.iter (box_line_styled buf cols ~style:Ansi.dim) judge_legend;
       box_divider buf cols;

       if count = 0 then begin
         (* An empty filter and an empty store are different facts: the first
            says how to see the rest, the second has nothing to show. *)
         let empty_note =
           match p.pl_goals with
           | [] -> "  (no goals)"
           | _ -> "  no goals in this filter (f to change)"
         in
         box_line buf cols (Ansi.dim ^ empty_note ^ Ansi.reset);
         for _ = 1 to rows - count_frame_lines buf - tail_rows do
           box_empty buf cols
         done
       end else begin
         (* One row is reserved below the list for the selected goal's verdict. *)
         let content_height =
           rows - count_frame_lines buf - selection_rows - tail_rows
         in
         (* Where the list stands, when it does not hold every goal. At
            sixty columns and twenty-four rows the active filter held eight
            and the frame drew seven, and nothing on the screen said an
            eighth existed -- the rollup above counts every goal in the
            store, not the ones this filter and this frame leave off. The
            reading costs one of the rows it describes, which is the rule
            [Masc_tui_scroll.content_height ~overflow_takes_row:true] already
            holds for the roster and the reading panes. The chrome is zero
            here because [content_height] above has already taken it. *)
         let list_rows =
           (* A short frame may leave no list row at all. When it leaves
              one, that row is the selected goal: the cursor row is what
              [j/k] and Enter act on, and the count needs a second row. *)
           if content_height <= 0 then 0
           else if content_height = 1 then 1
           else
             Masc_tui_scroll.content_height ~rows:content_height ~chrome:0
               ~count ~preview_keep:None ~overflow_takes_row:true
         in
         list_page_rows := max 1 list_rows;
         let overflowing = content_height > 1 && count > list_rows in
         let scroll_offset =
           if list_rows = 0 then 0
           else if state.planning_cursor >= list_rows then
             state.planning_cursor - list_rows + 1
           else 0
         in
         let goals_window = Rows.of_list ~first:scroll_offset ~height:list_rows goals in
         for i = 0 to list_rows - 1 do
           let idx = i + scroll_offset in
           match Rows.at goals_window idx with
           | None -> box_empty buf cols
           | Some g -> begin
             let is_selected = idx = state.planning_cursor in
             let status_color = planning_phase_color g.pg_phase in
             let status_label = if ko then planning_phase_korean (Goal_phase.kind g.pg_phase)
               else planning_phase_label g.pg_phase in
            (* The gap belonged to the reading before; the columns space
               themselves now, and an absent date leaves its cell empty rather
               than moving the one beside it. *)
            let due =
              match Terminal_text.optional_single_line g.pg_due_date with
              | Some d -> d
              | None -> ""
            in
             let age =
               match planning_updated_age ~now:now_unix g with
               | Some a -> a
               | None -> ""
             in
             (* What is being done about this goal, on the row itself. The
                detail panel below already resolves the same links, but only
                for the goal under the cursor: reading which of seventeen
                goals had work stuck in verification took seventeen moves.

                [state.tasks] drops terminal rows and the goal links ride
                only on it ([task_of_domain] takes goal_ids as an argument;
                the domain record does not carry them), so this counts open
                work, not progress. A "5 of 12 done" would need the server to
                carry the link on finished rows too.

                One signal, not three: verification is the one that means
                something is not moving, so it wins the cell when both are
                present. *)
             let open_note, open_style =
                let linked =
                  List.filter
                    (fun (t : Tui_decode.task) -> List.mem g.pg_id t.goal_ids)
                    state.tasks
                in
                match linked with
                | [] -> "", ""
                | _ ->
                    let tally predicate =
                      List.length (List.filter predicate linked)
                    in
                    let awaiting =
                      tally (fun (t : Tui_decode.task) ->
                          match t.status with
                          | Masc_domain.AwaitingVerification _ -> true
                          | Types_core.Todo | Types_core.Claimed _ | Types_core.InProgress _
                          | Types_core.Done _ | Types_core.Cancelled _ -> false)
                    in
                    let running =
                      tally (fun (t : Tui_decode.task) ->
                          match t.status with
                          | Masc_domain.InProgress _ -> true
                          | Types_core.Todo | Types_core.Claimed _
                          | Types_core.AwaitingVerification _ | Types_core.Done _
                          | Types_core.Cancelled _ -> false)
                    in
                    let total = List.length linked in
                    let with_activity activity ~ko_word ~en_word =
                      let full =
                        if ko then Printf.sprintf "%d열림 %d%s" total activity ko_word
                        else Printf.sprintf "%d open %d %s" total activity en_word in
                      if Message_layout.display_width full <= Render_schedule.planning_open_width then full
                      else
                        let short = if ko then Printf.sprintf "%s %d" ko_word activity
                          else Printf.sprintf "%s %d" en_word activity in
                        if Message_layout.display_width short <= Render_schedule.planning_open_width then short
                        else if ko then ko_word ^ " 있음" else en_word ^ " present" in
                    if awaiting > 0 then
                      with_activity awaiting ~ko_word:"검증" ~en_word:"ver", (Theme.warn ())
                    else if running > 0 then
                      with_activity running ~ko_word:"진행" ~en_word:"run", (Theme.info ())
                    else
                      let open_only = Printf.sprintf (if ko then "%d열림" else "%d open") total in
                      (if Message_layout.display_width open_only <= Render_schedule.planning_open_width then open_only
                       else if ko then "열린 작업 있음" else "open tasks"), Ansi.dim
             in
             let priority_style =
               match g.pg_priority with
               | 1 -> (Theme.bad ()) ^ Ansi.bold
               | 2 -> (Theme.warn ())
               | 3 -> Ansi.reset
               | _ -> Ansi.dim
             in
             let lead = if is_selected then "> " else "  " in
             let line =
               lead
               ^ Render_schedule.planning_row ~phase_style:status_color
                   ~priority_style ~open_style ~phase_width ~layout:goal_layout
                   { Render_schedule.prow_phase = "[" ^ status_label ^ "]"
                   ; prow_proof = planning_proof_mark g.pg_proof
                   ; prow_priority = Printf.sprintf "P%d" g.pg_priority
                   ; prow_open = open_note
                   ; prow_title = Terminal_text.single_line g.pg_title
                   ; prow_age = age
                   ; prow_due = due
                   }
             in
             if is_selected then
               box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
             else
               box_line buf cols line
           end
         done;
         if overflowing then
           box_line_styled buf cols ~style:(Theme.recede ())
             (Printf.sprintf (if ko then "  [목표 %s]" else "  [goals %s]")
                (Masc_tui_scroll.window_text ~scroll:scroll_offset
                   ~height:list_rows count));
         match List.nth_opt goals state.planning_cursor with
         | None -> box_empty buf cols
         | Some selected ->
             let colour, text = planning_selected_detail ~ko selected in
             box_line buf cols
               (colour ^ "  " ^ Terminal_text.single_line text ^ Ansi.reset)
       end);

  Buffer.add_buffer buf tail;

  finish_surface state ~clamped:(Planning_list_page_rows !list_page_rows)
      ~surface_key:"planning-list" ~rows:terminal_rows
      ~cols buf

let planning_measurement_lines (state : state) (goal : planning_goal) =
  let line tone text = { Planning_detail.tone; text } in
  let unavailable reason =
    [ line Planning_detail.Unreadable
        ("Actual measurement unavailable: " ^ Terminal_text.single_line reason) ]
  in
  if Option.is_none goal.pg_criterion_revision then []
  else match state.overview_goals with
  | Goals_unread -> [ line Planning_detail.Waiting "Actual measurement not observed" ]
  | Goals_failed reason -> unavailable reason
  | Goals_read goals ->
      (match List.find_opt
               (fun (row : Tui_decode.overview_goal) ->
                 String.equal row.og_id goal.pg_id) goals with
       | None -> unavailable "Goal missing from the current measurement tree"
       | Some row ->
           if not (Option.equal String.equal goal.pg_criterion_revision
                        row.og_criterion_revision)
              || not (Option.equal String.equal goal.pg_metric row.og_metric)
              || not (Option.equal String.equal goal.pg_target_value
                        row.og_target_value)
           then unavailable "criterion revision or target differs between Work and the Goal tree"
           else
             let tasks =
               line Planning_detail.Quiet
                 (Printf.sprintf "Linked Tasks: %d/%d done (separate from the measurement)"
                    row.og_task_done_count row.og_task_count)
             in
             (match row.og_measurement with
              | Goal_measurement_unread ->
                  [ line Planning_detail.Waiting "Actual measurement not observed"; tasks ]
              | Goal_measurement_not_recorded ->
                  [ line Planning_detail.Quiet "Actual measurement not recorded"; tasks ]
              | Goal_measurement_unavailable reason -> unavailable reason @ [ tasks ]
              | Goal_measurement_reported { value; evidence; actor; recorded_at } ->
                  (* "Measured:", not "Evidence:": this row is the goal tree's
                     measurement provenance, and on a confirmation screen the
                     same label already names the proof's evidence. *)
                  [ line Planning_detail.Proven
                      ("Actual: " ^ Terminal_text.single_line value ^ " (reported)")
                  ; line Planning_detail.Note
                      ("Measured: " ^ Terminal_text.single_line evidence
                       ^ " · " ^ Terminal_text.single_line actor
                       ^ " · " ^ Terminal_text.single_line recorded_at)
                  ; tasks ]))

let planning_confirmation_view (state : state) ~goal_id =
  match state.goal_confirmation with
  | Planning_detail.Inspecting read ->
      `Inspect (Masc_tui_fetched.view_for ~equal:String.equal read ~key:goal_id)
  | Planning_detail.Submitting (submitted_goal, _) when String.equal submitted_goal goal_id -> `Submitting
  | Planning_detail.Submitting _ -> `Inspect Absent

let planning_detail_action_rows ~cols ~armed ~drop_reason (goal : planning_goal) =
  let item action =
    let key = planning_action_key action and label = planning_action_label action in
    let text = Printf.sprintf "[%s] %s" key label in
    if Goal_phase.moves_goal ~phase:goal.pg_phase
         ~action:(Goal_phase.Public_action.to_action action)
    then text else Ansi.dim ^ text ^ Ansi.reset
  in
  let actions = List.map item Goal_phase.Public_action.all
    @ (if Goal_phase.moves_goal ~phase:goal.pg_phase ~action:Goal_phase.Confirm_completion
       then ["[a] Confirm proof"] else []) in
  (* These are commands, so every action stays visible while its evidence is
     read. Their physical rows are subtracted before the reader is allocated. *)
  Message_layout.wrap_styled_words ~max_cells:(max 1 (framed_inner_width cols - 2))
    ("Actions: " ^ String.concat "   " actions)
  |> List.map (fun line -> "  " ^ line)
  |> fun rows -> rows @ (match armed with
       | None -> []
       | Some action ->
           Message_layout.wrap_words ~max_cells:(max 1 (framed_inner_width cols - 2))
             (Printf.sprintf "ARMED: %s [%s] -- press again to submit; other keys cancel"
                (planning_action_label action) (planning_action_key action))
           |> List.map (fun line -> "  " ^ Theme.warn () ^ line ^ Ansi.reset))
  |> fun rows -> rows @ (match drop_reason with
       | None -> []
       | Some reason ->
           Message_layout.wrap_words ~max_cells:(max 1 (framed_inner_width cols - 2))
             (Printf.sprintf "DROP REASON: %s_ -- Enter drops the Goal and cancels its unclaimed Tasks"
                (Terminal_text.single_line reason))
           |> List.map (fun line -> "  " ^ Theme.warn () ^ line ^ Ansi.reset))

let planning_proof_rows ~width lines =
  List.concat_map (fun (line : Planning_detail.line) ->
    match Masc_tui_text_block.rows ~max_cells:width line.text with
    | [] -> [{line with text=""}]
    | rows -> List.map (fun text -> {line with text="  " ^ text}) rows) lines

let planning_detail_lines (state : state) ~confirmation ~cols (goal : planning_goal) =
  let width = max 1 (framed_inner_width cols - 2) in
  let field ?(tone = Planning_detail.Note) label text =
    let prefix = "  " ^ label ^ ": " in
    let cells = Message_layout.display_width prefix in
    let project text = { Planning_detail.tone; text } in
    if cells < framed_inner_width cols then
      (match Masc_tui_text_block.rows ~max_cells:(framed_inner_width cols - cells) text with
       | [] -> [project prefix]
       | lines -> List.mapi (fun index line ->
           project ((if index = 0 then prefix else String.make cells ' ') ^ line)) lines)
    else
      (Message_layout.wrap_words ~max_cells:width label |> List.map (fun line -> project ("  " ^ line)))
      @ (Masc_tui_text_block.rows ~max_cells:width text |> List.map (fun line -> project ("  " ^ line)))
  in
  let optional = function Some value -> value | None -> Masc_tui_theme.Glyph.no_value in
  let _, next_text = planning_next_step goal in
  let section title =
    Masc_tui_text_block.rows ~max_cells:width ("[ " ^ title ^ " ]")
    |> List.map (fun line -> { Planning_detail.tone = Note; text = "  " ^ line })
  in
  let gap = [ { Planning_detail.tone = Quiet; text = "" } ] in
  let metadata =
    section
      (ui_text state ~ko:"1. 목표 개요 · 단계 및 지표"
         ~en:"1. Goal Stage & Target")
    @ field "Title" goal.pg_title @ field "Goal" goal.pg_id
    @ field "Stage" (Masc_tui_theme.strip_sgr (planning_stage_rail goal.pg_phase ^ "  " ^ planning_proof_mark goal.pg_proof))
    @ field "Next" next_text
    @ field "Metric" (optional goal.pg_metric)
    @ field "Target" (optional goal.pg_target_value)
    @ field "Due" (optional goal.pg_due_date)
    @ field "Priority" (Printf.sprintf "P%d" goal.pg_priority)
    @ (List.concat_map (fun (label, value) -> match value with
         | None -> [] | Some value -> field ~tone:Planning_detail.Quiet label value)
         ["Created", goal.pg_created_at; "Updated", goal.pg_updated_at; "Reviewed", goal.pg_last_review_at])
    @ field ~tone:Planning_detail.Quiet "Link" (Link.reference Goal goal.pg_id)
    @ (match state.goal_action_error with None -> [] | Some error -> field ~tone:Planning_detail.Refused "Error" error)
  in
  let linked_tasks = List.filter (fun (row : Tui_decode.task) -> List.mem goal.pg_id row.goal_ids) state.tasks in
  let linked =
    gap
    @ section
        (ui_text state ~ko:"2. 연결된 작업"
           ~en:"2. Linked Tasks")
    @ match linked_tasks with
    | [] ->
        let note = match state.task_reading with
          | Masc_tui_overview_tasks.Rows_unavailable _ -> page_failed_note
          | Rows_unread -> page_unread_note
          | Rows_read _ ->
              (match state.goal_task_links with
               | Goal_links_not_read -> "(links not read)"
               | Goal_links_read_failed _ -> "(links unavailable)"
               | Goal_links_read _ -> "(none)") in
        field ~tone:Planning_detail.Quiet "Open tasks" note
    | tasks -> field "Open tasks" (string_of_int (List.length tasks))
        @ List.concat_map (fun (task : Tui_decode.task) ->
            field "Task" task.id @ field "Title" task.title
            @ field ~tone:Planning_detail.Quiet "Link" (Link.reference Task task.id)) tasks
  in
  let confirmation_rows =
    (match confirmation with
       | `Submitting -> [{Planning_detail.tone = Waiting; text = "Sending proof confirmation..."}]
       | `Inspect (Masc_tui_fetched.Ready value) ->
           Planning_detail.confirmation_lines ~width
             ~ko:(state.ui_language = Lang_ko) value
       | `Inspect Loading -> [{Planning_detail.tone = Waiting; text = "Reading the proof to confirm..."}]
       | `Inspect (Stale (_, reason) | Failed reason) -> [{Planning_detail.tone = Unreadable; text = reason}]
       | `Inspect Masc_tui_fetched.Absent ->
           (match goal.pg_verifier_unreconciled with Some blocked -> Planning_detail.unreconciled_lines ~width blocked | None -> [])
           @ Planning_detail.body ~width goal.pg_proof goal.pg_last_review_note)
  in
  let measurement = planning_measurement_lines state goal in
  let timeline = Planning_detail.timeline ~width ~goal_id:goal.pg_id state.goal_timeline in
  (* While a proof waits for confirmation, the decision block leads and the
     timeline -- context, not decision input -- moves behind the goal's own
     summary, so the promise and the metadata read adjacently instead of a
     long event list wedging itself between them. *)
  let proof =
    (match confirmation with
     | `Inspect Masc_tui_fetched.Absent -> measurement @ confirmation_rows @ timeline
     | `Submitting | `Inspect (Masc_tui_fetched.Ready _ | Loading | Stale _ | Failed _) ->
         confirmation_rows @ measurement) in
  let wrapped_proof = planning_proof_rows ~width proof in
  (match confirmation with
   | `Inspect Masc_tui_fetched.Absent ->
       metadata @ linked @ gap
       @ section
           (ui_text state ~ko:"3. 검증 판정 · 측정 및 이력"
              ~en:"3. Verification & Measurement")
       @ wrapped_proof
   | `Submitting | `Inspect (Masc_tui_fetched.Ready _ | Loading | Stale _ | Failed _) ->
       wrapped_proof @ gap @ metadata @ linked @ timeline)

let planning_detail_header_rows (state : state) ~cols (goal : planning_goal) =
  let phase = "  " ^ bracketed ~max_cells:planning_phase_column
      (planning_phase_label goal.pg_phase) in
  let identity = Terminal_text.single_line goal.pg_id in
  let tail = phase ^ " " ^ identity in
  let header = planning_workspace_title state ~cols ~tab:Planning_goals ~window:""
    ~after:tail ^ tail in
  let headers =
    if Message_layout.display_width header <= framed_inner_width cols then [header]
    else
      (planning_workspace_title state ~cols ~tab:Planning_goals ~window:""
         ~after:phase ^ phase)
      :: (Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols - 2))
            ("Goal: " ^ identity)
          |> List.map (fun line -> "  " ^ line))
  in
  headers @ planning_stale_notice_rows state ~cols

let planning_detail_height ~rows ~header_rows ~action_rows ~count =
  Masc_tui_scroll.content_height ~rows ~chrome:(framed_chrome_rows + max 0 (header_rows - 1) + action_rows)
    ~count ~preview_keep:None ~overflow_takes_row:true

let planning_detail_fits ~rows ~header_rows ~action_rows ~count =
  let height = planning_detail_height ~rows ~header_rows ~action_rows ~count in
  framed_chrome_rows + max 0 (header_rows - 1) + action_rows + height
    + (if count > height then 1 else 0) <= rows

let planning_detail_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let cols = if cols < keeper_split_threshold_cols then cols else cols - keeper_roster_pane_cols in
  match state.planning_mode, state.planning with
  | Planning_detail goal_id, Some snapshot ->
      (match List.find_opt (fun (goal : planning_goal) -> String.equal goal.pg_id goal_id) snapshot.pl_goals with
       | None -> 0, max 1 (rows - framed_chrome_rows)
       | Some goal ->
           let action_rows = List.length (planning_detail_action_rows ~cols ~armed:(goal_action_armed_for state goal_id)
             ~drop_reason:(goal_drop_reason_for state goal_id) goal) in
           let count = List.length (planning_detail_lines state ~cols goal
             ~confirmation:(planning_confirmation_view state ~goal_id)) in
           let header_rows = List.length (planning_detail_header_rows state ~cols goal) in
           if planning_detail_fits ~rows ~header_rows ~action_rows ~count
           then count, planning_detail_height ~rows ~header_rows ~action_rows ~count
           else 0, 1)
  | Planning_list, _ | Planning_detail _, None -> 0, max 1 (rows - framed_chrome_rows)

let planning_detail_pane (state : state) ~armed ~confirmation ~rows ~cols (goal : planning_goal) buf =
  let headers = planning_detail_header_rows state ~cols goal in
  box_top buf cols;
  List.iter (box_line buf cols) headers;
  box_divider buf cols;
  let actions = planning_detail_action_rows ~cols ~armed
      ~drop_reason:(goal_drop_reason_for state goal.pg_id) goal in
  List.iter (box_line buf cols) actions;
  let lines = planning_detail_lines state ~confirmation ~cols goal in
  let count = List.length lines in
  let height = planning_detail_height ~rows ~header_rows:(List.length headers)
    ~action_rows:(List.length actions) ~count in
  let scroll = Masc_tui_scroll.normalize ~count ~height state.planning_scroll in
  let window = Rows.of_list ~first:scroll ~height lines in
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some line -> box_line_styled buf cols ~style:(planning_detail_tone line.Planning_detail.tone) line.text
  done;
  Option.iter (box_line_styled buf cols ~style:(Theme.recede ()))
    (Masc_tui_scroll.position_row ~scroll ~height count);
  box_bottom buf cols;
  let seen = match confirmation with
    | `Inspect (Masc_tui_fetched.Ready proof) ->
        let width = max 1 (framed_inner_width cols - 2) in
        let last = List.length (planning_proof_rows ~width
          (Planning_detail.confirmation_lines ~width
             ~ko:(state.ui_language = Lang_ko) proof)) - 1 in
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
  let detail_cols = if cols < keeper_split_threshold_cols then cols else cols - keeper_roster_pane_cols in
  let action_rows = List.length (planning_detail_action_rows ~cols:detail_cols ~armed
      ~drop_reason:(goal_drop_reason_for state goal.pg_id) goal) in
  let count = List.length (planning_detail_lines state ~confirmation ~cols:detail_cols goal) in
  let header_rows = List.length (planning_detail_header_rows state ~cols:detail_cols goal) in
  if not (planning_detail_fits ~rows ~header_rows ~action_rows ~count) then begin
    let buf = Buffer.create 96 in
    Buffer.add_string buf (fit_width "Goal detail needs more room; resize to read and act" cols);
    Buffer.add_char buf '\n';
    finish_terminal_too_small_frame ~cursor:Frame_presenter.Hidden ~rows:terminal_rows ~cols buf
  end else begin
  let buf = Buffer.create 4096 in
  let scroll, seen =
    if cols < keeper_split_threshold_cols then
      planning_detail_pane state ~armed ~confirmation ~rows ~cols goal buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let goals =
        match state.planning with
        | None -> []
        | Some p ->
            planning_visible_goals ~filter:state.planning_filter
              ~sort:state.planning_sort p.pl_goals
      in
      let selected =
        let rec find i = function
          | [] -> 0
          | (row : planning_goal) :: rest ->
            if String.equal row.pg_id goal.pg_id then i else find (i + 1) rest
        in
        find 0 goals
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      let format_sidebar_goal (row : planning_goal) =
        let phase_badge =
          match row.pg_phase with
          | Goal_phase.Executing -> "[exec]"
          | Goal_phase.Verifying -> "[ver ]"
          | Goal_phase.Awaiting_confirmation -> "[human]"
          | Goal_phase.Completed -> "[done]"
          | Goal_phase.Dropped -> "[drop]"
          | Goal_phase.Paused _ -> "[pause]"
          | Goal_phase.Blocked _ -> "[block]"
        in
        Printf.sprintf "%s P%d %s" phase_badge row.pg_priority
          (Terminal_text.single_line row.pg_title)
      in
      (* The goal filter narrows to a phase; the goals it leaves out are on
         the other side of a filter, not behind a page boundary. *)
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Work"
        ~holding:None
        ~focused:false
        ~labels:(List.map format_sidebar_goal goals)
        ~selected;
      let scroll, seen =
        planning_detail_pane state ~armed ~confirmation ~rows ~cols:(cols - left_cols) goal
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      scroll, seen
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (match goal_drop_reason_for state goal.pg_id with
          | Some _ -> Masc_tui_keys.footer_hints_goal_drop_reason
          | None -> Masc_tui_keys.footer_hints ~detail_open:true state.view));
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

let schedule_status_color status =
  semantic_status_color status

(* The wake's status is the contract's own word, so the list column is as
   wide as the widest word the contract can send and no wider: the value
   was a string, and the column a literal 10 that happened to fit
   "succeeded". Measured once from the contract's list, the column and
   the vocabulary cannot drift apart. *)
let schedule_wake_word = Schedule_contract_values.wake_status_to_string

let schedule_wake_word_cells =
  List.fold_left
    (fun widest word -> max widest (Message_layout.display_width word))
    0 Schedule_contract_values.wake_status_strings

(* The same rule for the schedule's own status. [sch_status] arrives as a
   string rather than the contract's variant, so the cell is cut to this
   width as well: a word the contract does not name cannot push the columns
   beside it out of line. *)
let schedule_status_word_cells =
  List.fold_left
    (fun widest word -> max widest (Message_layout.display_width word))
    0 Schedule_contract_values.schedule_status_strings


(* The width of the request clock column, read off the format rather than
   typed. [short_timestamp] answers a parsed stamp in this shape, but an
   unparsed one comes back as the source text and an absent one as "(never)",
   and either of those pulls the three columns after it out of line -- the
   same shape as the printf padding this row gave up. *)
let schedule_requested_clock_cells =
  Message_layout.display_width (Terminal_text.short_timestamp_of_unix 0.)

(* What became of the wake, for a list row that has one line to say it in.

   The word is the server's own [projection_status], not a reading of it.
   That status is written at a dozen places in
   [server_dashboard_schedule_projection.ml] as bare strings, and the live
   store holds values this file has never heard of; a table of meanings
   here would be a second classifier over that same open axis, drifting
   from the ledger's the first time the server learns a word. Showing the
   word the server wrote cannot drift.

   The [matched_] prefix comes off. It sits on most of the values and
   separates none of them, which is the reason the subject drops
   [keeper:] a few lines below.

   [None] is the ledger saying nothing, and the row then shows an em dash
   rather than a delivery it does not know. That is not the same as a wake
   that failed, which [wake:] beside it already names. *)
let schedule_delivery_word (row : schedule_row) =
  let matched = "matched_" in
  let cut status =
    let n = String.length matched in
    if String.length status > n && String.equal (String.sub status 0 n) matched then
      String.sub status n (String.length status - n)
    else status
  in
  match row.sch_reaction_projection_status with
  | None -> Masc_tui_theme.Glyph.no_value
  | Some status -> cut status

(* What the last occurrence came to, for a row that has one line to say it.

   A wake that did not succeed is the outcome. A succeeded wake hands the
   column to the furthest step the ledger recorded -- the reading that
   separates a wake merely taken from one that finished a turn. No wake at
   all is no outcome: the reaction evidence beside it belongs to the
   occurrence before (a held occurrence has no wake of its own, and a
   projection between occurrences still carries the last one's reading), so
   drawing it would pair a dash in the trigger column with a word about a
   different occurrence in this one. The word is the server's own, cut of
   its [matched_] prefix, and the caller sanitises it the way it sanitises
   every other reading from this projection. *)
let schedule_outcome_word (row : schedule_row) =
  match row.sch_last_wake_status with
  | Some Schedule_contract_values.Wake_succeeded ->
      schedule_delivery_word row
  | Some
      (( Schedule_contract_values.Wake_running
       | Schedule_contract_values.Wake_failed ) as other) ->
      schedule_wake_word other
  | None -> Masc_tui_theme.Glyph.no_value

(* Whether a status word names a schedule that can still act. The word is
   the projection's own; a word this build does not name stays with the live
   rows rather than being buried under the closed rule -- the same promise
   the word itself makes by rendering as itself. *)
let schedule_status_is_terminal word =
  match Schedule_domain.schedule_status_of_string word with
  | Ok status -> Schedule_domain.is_terminal status
  | Error _ -> false

let schedule_delivery_summary ~freshness ~runner (row : schedule_row) =
  let queue =
    match row.sch_queue_projection_status, row.sch_queue_pending_count with
    | None, None -> "queue:\xe2\x80\x94"
    | Some status, None -> "queue:" ^ status
    | None, Some count -> Printf.sprintf "queue:pending=%d" count
    | Some status, Some count ->
        Printf.sprintf "queue:%s/%d pending" status count
  in
  let reaction =
    match row.sch_reaction_projection_status with
    | None -> "reaction:\xe2\x80\x94"
    | Some status -> "reaction:" ^ status
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
               Render_schedule.schedule_hold_tag
                 ~due:(Terminal_text.short_timestamp hold.Tui_decode.srh_due_at_iso)
           | Tui_decode.Hold_as_of checked ->
               Render_schedule.schedule_hold_as_of_tag
                 ~checked:(Terminal_text.short_timestamp_of_unix checked))
  in
  ( Printf.sprintf "%s \xc2\xb7 status:%s%s" row.sch_schedule_id
      row.sch_status hold
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
         | Some _ -> "이전 조회 유지 · " ^ err)

(* The list on screen is the newest answer only while its last load
   succeeded. A failed reload keeps the previous list on screen, and a hold on
   it is then an earlier reading whatever the runner said at the time. *)
let schedule_list_freshness (state : state) =
  match state.schedules_error with
  | None -> Tui_decode.List_latest
  | Some _ -> Tui_decode.List_kept

(* A refused create or modify form, wrapped to the frame, for as long as the
   last-action window lasts; the action line alone is lost under a workspace
   warning. *)
let schedule_form_refusal_rows (state : state) ~cols =
  match state.schedule_form_refusal with
  | Some { sfr_action; sfr_detail; sfr_at; sfr_workspace = _ }
    when Unix.gettimeofday () -. sfr_at <= Masc_tui_types.last_action_window_s ->
      Message_layout.wrap_words ~max_cells:(max 1 (framed_inner_width cols))
        (Terminal_text.single_line (sfr_action ^ ": " ^ sfr_detail))
  | Some _ | None -> []

(* Rows the Schedules page spends around its list, counted once so the
   refusal budget and the list height read the same numbers: the request
   count, next due and its divider; the column names and their rule; the two
   delivery rows. *)
let schedule_summary_rows = 3
let schedule_column_header_rows = 2
let schedule_delivery_rows = 2

let schedule_rows_around_list =
  schedule_summary_rows + schedule_column_header_rows + schedule_delivery_rows

(** Render the Schedules surface: the scheduled-automation list, with an
    armed cancel. The server sorts active rows first by due time and caps the
    list at its own limit; [scs_truncated] and [scs_request_count] say what
    of the whole store this page is. *)
let render_schedule_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let refusal_rows = schedule_form_refusal_rows state ~cols in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s  %s"
    (screen_title " MASC Keepers / Schedules")
    timestamp
    (connection_badge state) in

  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"schedules" ~title:header
    ~hints:(Masc_tui_keys.footer_hints ~detail_open:false Schedules)
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
        let selected = Option.is_some (List.nth_opt snapshot.scs_rows state.schedule_cursor) in
        selected, warning + cancel +
          (if snapshot.scs_rows = [] then schedule_summary_rows
           else schedule_rows_around_list + 1)
    | Some _ | None -> false, 1
  in
  let room = max 0 (budget - reserved_rows) in
  let refusal_rows =
    if List.length refusal_rows <= room then refusal_rows
    else if room = 0 then []
    else
      let cue = if selected_row_exists then "… Enter: full refusal diagnostic"
        else "… refusal diagnostic truncated" in
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
            c.push (Ansi.dim ^ page_unread_note ^ Ansi.reset))
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
                ((Theme.bad ()) ^ "  (schedule store unreadable)" ^ Ansi.reset))
       end else begin
         let count_text =
           match snapshot.scs_request_count, snapshot.scs_paging with
           | Some total, Schedule_paging_unavailable when snapshot.scs_truncated ->
               Printf.sprintf "  Requests: %d  (first %d; server paging unavailable)" total
                 (List.length snapshot.scs_rows)
           | Some total, Schedule_paging _
             when snapshot.scs_truncated || Option.is_some state.schedules_page.sp_cursor ->
               Printf.sprintf "  Requests: %d  · page %d (%d shown; pages may change)"
                 total (List.length state.schedules_page.sp_previous + 1)
                 (List.length snapshot.scs_rows)
           | Some total, (Schedule_paging_unavailable | Schedule_paging _) ->
               Printf.sprintf "  Requests: %d" total
           | None, (Schedule_paging_unavailable | Schedule_paging _) ->
               "  Requests: " ^ Masc_tui_theme.Glyph.no_value
         in
         (* One row, not two. The count and the next wake are a phrase each,
            and with nothing due the second row was drawn blank -- a row of
            the list given up to say nothing. *)
         let next_due_text =
           match snapshot.scs_next_due_iso with
           | Some iso ->
               Printf.sprintf "%s  \xc2\xb7  Next due: %s%s" Ansi.dim
                 (Terminal_text.short_timestamp iso) Ansi.reset
           | None -> ""
         in
         let page_read_text = match state.schedules_navigation with
           | Some (ticket, page, _) when Snapshot_read.is_current state.schedules_read ticket ->
               Printf.sprintf "  · loading page %d" (List.length page.sp_previous + 1)
           | Some _ | None -> "" in
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
                 "  (no schedules on this page; < returns to the previous page)"
             | Some total, [] when total > 0 ->
                 "  (no schedules on this page; refresh to read again)"
             | (Some _ | None), (_ :: _ | []) ->
                 "  (no scheduled automation \xe2\x80\x94 press n to create one)"
           in
           c.push (Ansi.dim ^ empty ^ Ansi.reset)
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
           let wake_width = schedule_wake_word_cells in
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
                    Terminal_text.single_line (schedule_delivery_word row))
                  snapshot.scs_rows)
           in
           let layout =
             Render_schedule.schedule_layout
               ~inner_width:(max 1 (framed_inner_width cols - 2))
               ~target_width:subject_width ~wake_width ~delivery_width
           in
           c.push_styled ~style:(Theme.recede ())
             ("  " ^ Render_schedule.schedule_header_row ~layout);
           c.push_divider ();
           (* The column names and the rule under them, the two rows every
              other list on this screen already spends to say what it draws. *)
           (* The body outside the list: the source warning, the request count,
              next due and its divider, the column names and their rule, the
              two delivery rows, and the cancel rows. *)
           let content_height =
             max 1 (budget - List.length refusal_rows - warning_rows - schedule_rows_around_list - cancel_rows)
           in
           let scroll_offset =
             if state.schedule_cursor >= content_height then
               state.schedule_cursor - content_height + 1
             else 0
           in
           let scs_rows_window = Rows.of_list ~first:scroll_offset ~height:content_height snapshot.scs_rows in
           for i = 0 to content_height - 1 do
             let idx = i + scroll_offset in
             match Rows.at scs_rows_window idx with
             | None -> c.push_empty ()
             | Some row -> begin
               let is_selected = idx = state.schedule_cursor in
               let due =
                 match row.sch_due_at_iso with
                 | Some iso -> Terminal_text.short_timestamp iso
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
               let status_color = schedule_status_color row.sch_status in
               let last_wake =
                 Option.fold ~none:Masc_tui_theme.Glyph.no_value ~some:schedule_wake_word
                   row.sch_last_wake_status
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
                 Render_schedule.schedule_row ~status_style:status_color
                   ~wake_style:(schedule_status_color last_wake)
                   ~recurrence_style:Ansi.dim ~layout
                   { Render_schedule.srow_status =
                       bracketed ~max_cells:10 row.sch_status
                   ; srow_due = due
                   ; srow_target = Terminal_text.single_line subject
                   ; srow_wake = last_wake
                   ; srow_delivery =
                       Terminal_text.single_line (schedule_delivery_word row)
                   ; srow_recurrence =
                       Terminal_text.single_line row.sch_recurrence_summary
                   }
               in
               let content =
                 if is_selected then
                   Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
                 else
                   "  " ^ line
               in
               c.push content
             end
           done;
           (match List.nth_opt snapshot.scs_rows state.schedule_cursor with
            | None ->
                c.push_empty ();
                c.push_empty ()
            | Some selected ->
                let identity, delivery =
                  schedule_delivery_summary
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
                ((Theme.warn ())
                ^ Printf.sprintf
                    "  armed: cancel %s -- same key again to send"
                    (Terminal_text.single_line schedule_id)
                ^ Ansi.reset)
          | None -> ());
         (match state.schedule_cancel_error with
          | Some (schedule_id, err) ->
              c.push
                ((Theme.bad ()) ^ "  "
                ^ fit_width (Terminal_text.single_line (schedule_id ^ ": " ^ err)) (framed_inner_width cols - 4)
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
let schedule_turn_rows
      ~(field : ?style:string -> string -> string -> string * string)
      (row : schedule_row) =
  let step_observed =
    [ row.sch_wake_seen
    ; row.sch_turn_started
    ; row.sch_turn_finished
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
              " \xc2\xb7 " ^ timestamp
            | _, _ -> ""
          in
          field ~style:tone label ((if value then "yes" else "no") ^ at)
    in
    let identity_rows =
      [ Option.map
          (fun keeper ->
             field "Keeper evidence"
               (Link.reference Keeper (Terminal_text.single_line keeper)))
          row.sch_reaction_keeper_name
      ; Option.map
          (fun stimulus -> field "Stimulus" stimulus)
          row.sch_reaction_stimulus_id
      ; Option.map
          (fun occurrence -> field "Occurrence" occurrence)
          row.sch_reaction_post_id
      ]
      |> List.filter_map Fun.id
    in
    [ Ansi.dim, ""
    ; Ansi.bold, "  TURN"
    ]
    @ identity_rows
    @ [ step "Wake seen" row.sch_wake_seen row.sch_stimulus_recorded_at_iso
      ; step "Turn started" row.sch_turn_started
          row.sch_turn_started_recorded_at_iso
      ; step "Turn finished" row.sch_turn_finished
          row.sch_turn_finished_recorded_at_iso
      ; step "Queue ack" row.sch_queue_ack_seen row.sch_queue_ack_recorded_at_iso
      ; step ~bad_when_true:true "Cancelled" row.sch_wake_cancelled
          row.sch_wake_cancelled_recorded_at_iso
      ; field "Reaction kind"
          (Option.value ~default:Masc_tui_theme.Glyph.no_value row.sch_reaction_kind)
      ; field
          ~style:(if Option.is_some row.sch_reaction_reason then Theme.warn () else Ansi.dim)
          "Reason" (Option.value ~default:Masc_tui_theme.Glyph.no_value row.sch_reaction_reason)
    ; field
        ~style:
          (match row.sch_reaction_quarantined with
           | Some count when count > 0 -> Theme.warn ()
           | Some _ | None -> Ansi.dim)
        "Quarantined"
        (match row.sch_reaction_quarantined with
         | None -> Masc_tui_theme.Glyph.no_value
         | Some count -> string_of_int count)
      ]

(* The wake block. The row carries the newest attempt and the exact lookup
   carries the retained list, so this pane reports whichever it has and says
   which: one attempt out of up to 32 read as a schedule's whole past for as
   long as the list was the only thing not projected. The three unloaded
   readings stay three sentences. *)
let schedule_wake_lines
      ~(field : ?style:string -> string -> string -> string * string)
      ~(timestamp : string option -> string) ~(row : schedule_row)
      ~(history : schedule_wake_history option)
      ~(history_error : (string * string) option) =
  let last_wake_fields =
    [ (let word =
         Option.fold ~none:Masc_tui_theme.Glyph.no_value ~some:schedule_wake_word
           row.sch_last_wake_status
       in
       field
         ~style:
           (if Option.is_some row.sch_last_wake_status then
              schedule_status_color word
            else Ansi.dim)
         "Status" word)
    ; field "Started" (timestamp row.sch_last_wake_started_at_iso)
    ; field
        ~style:(if Option.is_some row.sch_last_wake_error then Theme.bad () else Ansi.dim)
        "Error" (Option.value ~default:Masc_tui_theme.Glyph.no_value row.sch_last_wake_error)
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
      (Ansi.bold, "  LAST WAKE")
      :: last_wake_fields
      @ [ (Theme.bad (), "  Wake history: " ^ Terminal_text.single_line err) ]
  | Render_schedule.Wake_last_only ->
      (Ansi.bold, "  LAST WAKE")
      :: last_wake_fields
      @ [ (Ansi.dim, "  (loading the rest of this schedule's wakes\xe2\x80\xa6)") ]
  | Render_schedule.Wake_never ->
      [ Ansi.bold, "  WAKES"; (Ansi.dim, "  (this schedule has not woken)") ]
  | Render_schedule.Wake_history { count; retention } ->
      let wakes =
        match history with Some h -> h.swh_wakes | None -> []
      in
        (Ansi.bold
        , Printf.sprintf "  WAKES (%d retained, ceiling %d per schedule)"
            count retention )
        :: List.concat_map
             (fun (wake : schedule_wake) ->
                let started = timestamp wake.swk_started_at_iso in
                let finished = timestamp wake.swk_finished_at_iso in
                (* The status is the row's label, drawn through [field] so
                   the times start in the column every other value on the
                   page starts in. A literal 12 here put them two cells to
                   the left of the Reaction time below. *)
                let word = schedule_wake_word wake.swk_status in
                let head =
                  field ~style:(schedule_status_color word) word
                    (Printf.sprintf "%s \xe2\x86\x92 %s" started finished)
                in
                match wake.swk_error with
                | None -> [ head ]
                | Some err -> [ head; field ~style:(Theme.bad ()) "" err ])
             wakes

let schedule_detail_lines ~width ~freshness ~runner (row : schedule_row)
      ~(wake_history : schedule_wake_history option)
      ~(wake_history_error : (string * string) option) =
  let field ?(style = Ansi.reset) label value =
    let prefix = Printf.sprintf "  %-14s " label in
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
  let timestamp value =
    match value with
    | None -> Masc_tui_theme.Glyph.no_value
    | Some iso -> iso
  in
  let queue =
    match row.sch_queue_projection_status, row.sch_queue_pending_count with
    | None, None -> Masc_tui_theme.Glyph.no_value
    | Some status, None -> status
    | None, Some count -> Printf.sprintf "pending=%d" count
    | Some status, Some count -> Printf.sprintf "%s  pending=%d" status count
  in
  let reaction =
    match row.sch_reaction_projection_status, row.sch_reaction_latest_at_iso with
    | None, None -> Masc_tui_theme.Glyph.no_value
    | Some status, None -> status
    | None, Some at -> at
    | Some status, Some at ->
        Printf.sprintf "%s  %s" status at
  in
  let summary =
    Option.value ~default:"(no payload summary)" row.sch_payload_summary
  in
  let keeper_wake =
    match row.sch_payload_kind with
    | Some ("keeper_wake" | "masc.keeper_wake") -> true
    | Some _ | None -> false
  in
  let target_link =
    match keeper_wake, row.sch_payload_target with
    | true, Some keeper ->
        [ field "Keeper link"
            (Link.reference Keeper (Terminal_text.single_line keeper))
        ]
    | _, _ -> []
  in
  let hold_rows =
    match row.sch_runner_hold with
    | None -> []
    | Some hold ->
        [ field ~style:(Theme.warn ()) "Held"
            (match Tui_decode.schedule_hold_reading ~freshness ~runner hold with
             | Tui_decode.Hold_current ->
                 let due = Terminal_text.short_timestamp hold.Tui_decode.srh_due_at_iso in
                 (match hold.Tui_decode.srh_reason with
                  | Tui_decode.Hold_previous_wake_untaken ->
                      Render_schedule.schedule_hold_reading ~due
                  | Tui_decode.Hold_target_shutdown_fenced { target; fence_owner } ->
                      Render_schedule.schedule_fence_hold_reading
                        ~due ~target ~fence_owner)
             | Tui_decode.Hold_as_of checked ->
                 let checked = Terminal_text.short_timestamp_of_unix checked in
                 (match hold.Tui_decode.srh_reason with
                  | Tui_decode.Hold_previous_wake_untaken ->
                      Render_schedule.schedule_hold_as_of_reading ~checked
                  | Tui_decode.Hold_target_shutdown_fenced { target; fence_owner } ->
                      Render_schedule.schedule_fence_hold_as_of_reading
                        ~checked ~target ~fence_owner))
        ; field "Held id" hold.Tui_decode.srh_occurrence_id
        ; field "Held due" hold.Tui_decode.srh_due_at_iso
        ]
  in
  detail_section_heading ~first:true
    "1. 현재 상태 · 다음 실행 · 보류 진단 (Status & Delivery)"
  @ [ field ~style:(schedule_status_color row.sch_status) "Status" row.sch_status
    ; field "Due" (timestamp row.sch_due_at_iso)
    ; field "Next due" (timestamp row.sch_next_due_at_iso)
    ; field "Recurrence" row.sch_recurrence_summary
    ; field "Expires" (timestamp row.sch_expires_at_iso)
    ]
  @ hold_rows
  @ [ field
        ~style:
          (Option.fold ~none:Ansi.dim ~some:schedule_status_color
             row.sch_queue_projection_status)
        "Queue" queue
    ; field
        ~style:
          (Option.fold ~none:Ansi.dim ~some:schedule_status_color
             row.sch_reaction_projection_status)
        "Reaction" reaction
    ]
  @ schedule_turn_rows ~field row
  @ detail_section_heading "2. 최근 실행 이력 (Wake History)"
  @ schedule_wake_lines ~field ~timestamp ~row ~history:wake_history
      ~history_error:wake_history_error
  @ (if keeper_wake then
       [ Ansi.dim, ""
       ; Ansi.bold, "  WORK RESULT"
       ; field "Attribution"
           "the turn this wake opened, bounded by its start and finish rows"
       ; field "Inspect"
           "Keeper Calls or Activity between the two recorded times"
       ]
     else [])
  @ detail_section_heading "3. 작업 요약 · 스케줄 식별자 (Summary & Identity)"
  @ [ Ansi.bold, "  SUMMARY" ]
  @ (Message_layout.wrap_body ~markdown:document_markdown
       ~max_cells:(max 1 (width - 4)) ~sanitize:Terminal_text.single_line summary
    |> List.map (fun line -> Ansi.reset, "    " ^ line))
  @ [ field "Target" (optional row.sch_payload_target) ]
  @ target_link
  @ [ field "Kind" (optional row.sch_payload_kind)
    ; field "Dispatch tool" (optional row.sch_payload_dispatch_tool)
    ; field "Support" row.sch_payload_support
    ; field "Schedule" row.sch_schedule_id
    ; field "Instance" row.sch_schedule_instance_id
    ; field "Link"
        (Link.reference Schedule
           (Terminal_text.single_line row.sch_schedule_id))
    ; field "Source" row.sch_source
    ; field "Requested by" row.sch_requested_by
    ; field "Scheduled by" row.sch_scheduled_by
    ; field "Requested" row.sch_requested_at_iso
    ]
  @ detail_section_heading "4. 페이로드 원문 (Payload JSON & Digest)"
  @ [ field "Digest" row.sch_payload_digest
    ; Ansi.bold, "  PAYLOAD JSON"
    ]
  @ (document_markdown ~width:(max 1 (width - 4))
       ("```json\n" ^ Yojson.Safe.pretty_to_string row.sch_payload ^ "\n```")
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
         [Theme.bad (), "Cancel error: " ^ wire error]
     | Some _ | None -> [])
    @ (match schedule_source_warning state with
       | None -> [] | Some error -> [Theme.bad (), "Source: " ^ wire error])
    @ (match state.schedule_cancel_armed with
       | None -> [] | Some id -> [Theme.warn (), "Armed: cancel " ^ wire id ^ " -- press x again to submit"]) in
  let fields = schedule_detail_lines ~width
      ~freshness:(schedule_list_freshness state) ~runner row
      ~wake_history:state.schedule_wake_history
      ~wake_history_error:state.schedule_wake_history_error in
  List.concat_map (fun (style, text) ->
      String.split_on_char '\n' text |> List.concat_map (fun line ->
        if Message_layout.display_width line <= width then [style, line]
        else match Message_layout.wrap_words ~max_cells:width line with
        | [] -> [style, ""]
        | lines -> List.map (fun text -> style, text) lines))
    (warnings @ fields)

let schedule_detail_height ~rows ~warning_rows ~count =
  Masc_tui_scroll.content_height ~rows ~chrome:(framed_chrome_rows + warning_rows) ~count
    ~preview_keep:None ~overflow_takes_row:true

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
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s[%s]%s"
       (screen_title " MASC Keepers / Schedules ▸ details")
       (schedule_status_color row.sch_status)
       (Terminal_text.single_line row.sch_status) Ansi.reset);
  box_divider buf cols;
  (* Source freshness governs every evidence row, so it stays visible while
     the reader moves. The complete warning also remains in the reader for
     narrow viewports or a refusal longer than the fixed status summary. *)
  let warning_rows = match schedule_source_warning state with
    | None -> 0
    | Some error -> box_line buf cols (data_unreliable_row ~cols error); 1 in
  let lines = schedule_detail_content state ~cols ~runner row in
  let count = List.length lines in
  let height = schedule_detail_height ~rows ~warning_rows ~count in
  let scroll = Masc_tui_scroll.normalize ~count ~height state.schedule_scroll in
  let lines_window = Rows.of_list ~first:scroll ~height lines in
  for index = 0 to height - 1 do
    match Rows.at lines_window (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  Option.iter (box_line_styled buf cols ~style:(Theme.recede ()))
    (Masc_tui_scroll.position_row ~scroll ~height count);
  box_bottom buf cols;
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
          List.map (fun (row : schedule_row) -> row.sch_schedule_id)
            snapshot.scs_rows
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Schedules"
        ~focused:false
        ~holding:
          (Option.bind state.schedules (fun snapshot ->
               snapshot.scs_request_count))
        ~labels ~selected:state.schedule_cursor;
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
       ~hints:(Masc_tui_keys.footer_hints ~detail_open:true Schedules));
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
          let confirmation = planning_confirmation_view state ~goal_id in
          render_planning_detail state
            ~armed:(goal_action_armed_for state goal_id) ~confirmation goal
      | None ->
          (match state.home_opened_request with
           | Some (Home_goal_confirmation selected) when selected = goal_id ->
               let terminal_rows, cols = get_terminal_size () in
               surface_chrome ~overflow:Fits state ~terminal_rows ~cols
                 ~surface_key:"planning_detail"
                 ~title:("Goal · " ^ Terminal_text.single_line goal_id)
                 ~status:[] ~hints:"Esc:Dashboard  r:refresh"
                 ~body:(fun ~budget:_ c ->
                   c.push (match state.planning_error with
                     | Some error -> " Goal detail unavailable · " ^ Terminal_text.single_line error
                     | None -> " Goal detail not read · waiting for its source"))
           | Some
               ( Home_held_call _ | Home_gate_request _
               | Home_operator_request _ | Home_question _
               | Home_goal_confirmation _ | Home_operator_task _ )
           | None -> render_planning_list state)
