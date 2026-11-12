(** Home decisions, continuation and selection over the terminal state. *)

open Masc_tui_types
open Masc_tui_approvals_model

let open_approvals state ~navigate =
  let origin = state.view in
  navigate Approvals;
  state.followed_from <- Some (origin, None)

let home_request_of_approval = function
  | Keeper_tool_row held ->
      Home_held_call { keeper = held.Tui_decode.kta_keeper; call_id = held.kta_tool_call_id }
  | Gate_row pending -> Home_gate_request pending.Tui_decode.gp_id
  | Operator_row item -> Home_operator_request item.ap_token

module Action_table = Hashtbl.Make (struct
  type t = home_action

  (* Keep the structural key comparison used by [List.assoc_opt]. *)
  let equal left right = Stdlib.compare left right = 0
  let hash = Hashtbl.hash
end)

let ordered_decision_rows rows =
  (* The index belongs to this projection. The reversed list, never table
     iteration, owns the first-seen order; only the shared Agenda destination
     combines labels from more than one source. *)
  let labels = Action_table.create (List.length rows) in
  let reversed =
    List.fold_left (fun reversed (action, label) ->
      match Action_table.find_opt labels action with
      | None ->
          let held = ref label in
          Action_table.add labels action held;
          (action, held) :: reversed
      | Some held ->
          (match action with
           | Home_agenda -> held := !held ^ "; " ^ label
           | Home_approvals | Home_request _ | Home_resume _ | Home_read_last _
           | Home_choose_keeper | Home_create_keeper | Home_operator_action _ -> ());
          reversed) [] rows
  in
  List.rev_map (fun (action, label) -> action, !label) reversed

(* Current successes survive another source's failure. Stale snapshots are
   reachable through their source reading, never offered as current requests. *)
let decision_rows_of_state (state : state) =
  let reading = approvals_reading state in
  let text ko en = ui_text state ~ko ~en in
  let clean = Masc_tui_ansi.Terminal_text.single_line in
  let approval_rows =
    approval_items state
    |> List.filter_map (fun row ->
      let current, who, why, kind = match row with
        | Keeper_tool_row held ->
            list_is_read reading.held_calls, held.kta_keeper, held.kta_question, text "도구 승인" "Held call"
        | Gate_row pending ->
            list_is_read reading.gate_queue, pending.gp_keeper, pending.gp_display_tool, text "실행 승인" "Gate approval"
        | Operator_row item ->
            list_is_read reading.confirm_queue, item.ap_actor, item.ap_summary, text "확인" "Confirm"
      in
      if current && approval_item_needs_person row then
        Some (Home_request (home_request_of_approval row),
              Printf.sprintf "%s · %s · %s" kind (clean who) (clean why))
      else None)
  in
  let questions =
    if list_is_read reading.questions then
      Option.value ~default:[] (approvals_open_questions state)
      |> List.map (fun (row : Masc.Tui_decode_asks.ask_row) ->
          let why = match row.ar_questions, row.ar_context with
            | question :: _, _ -> question.aq_prompt
            | [], Some reason -> reason
            | [], None -> text "답변 대기" "open question"
          in
          Home_request (Home_question (Masc.Tui_decode_asks.ask_key row)),
          Printf.sprintf "%s · %s · %s" (text "질문" "Question")
            (clean (Masc.Tui_decode_asks.ask_asker_label row.ar_asker)) (clean why))
    else []
  in
  let source_notes =
    approval_row_lists reading @ ["questions", reading.questions]
    |> List.filter_map (fun (name, status) -> match status with
        | List_read -> None
        | List_not_read _ -> Some name)
  in
  let approvals =
    (* Rows a match read stay while the identity is unconfirmed; deciding on
       them waits for a read that matches again. *)
    let identity = match state.workspace_identity with
      | Workspace_identity_match_unconfirmed _ ->
          [text "워크스페이스 식별 미확인 · 응답 보류" "workspace identity unconfirmed · decisions wait"]
      | Workspace_identity_unread | Workspace_identity_match
      | Workspace_identity_mismatch _ -> []
    in
    let unread = identity @ match source_notes with
      | [] -> []
      | names -> [text "일부 조회 미완료 · " "not fully read · " ^ String.concat ", " names]
    in
    let notes =
      match state.approval_snapshot with
      | Some snapshot when snapshot.aps_hidden_count > 0 ->
          unread @ [Printf.sprintf (if state.ui_language = Lang_ko then
              "현재 필터 밖 요청 %d건" else "%d requests outside current filter") snapshot.aps_hidden_count]
      | Some _ | None -> unread
    in
    match notes with
    | [] ->
        let count =
          List.map fst (approval_rows @ questions) |> List.sort_uniq compare |> List.length
        in
        if count = 0 then []
        else [Home_approvals, Printf.sprintf (if state.ui_language = Lang_ko then
            "승인·질문 %d건 · 전체 보기"
          else "Approvals and questions: %d need you · all requests") count]
    | _ :: _ -> [Home_approvals, text "승인·질문: " "Approvals and questions: " ^ String.concat "; " notes]
  in
  let goals = match state.goals_to_confirm with
    | Masc_tui_agenda.Read rows ->
        List.map (fun (row : Masc_tui_agenda.goal_to_confirm) ->
          Home_request (Home_goal_confirmation row.goal_id),
          Printf.sprintf "%s · %s" (text "목표 완료 확인" "Confirm Goal") (clean row.title)) rows
    | Not_read -> [Home_agenda, text "목표 완료 확인 미조회 · 상세 보기" "Goal confirmations not read · inspect sources"]
    | Read_failed _ -> [Home_agenda, text "목표 완료 확인 조회 불가 · 상세 보기" "Goal confirmations unavailable · inspect sources"]
  in
  (* Equality is kind plus authoritative request ID, never a Keeper/task
     grouping key. Distinct calls belonging to one Keeper remain distinct. *)
  ordered_decision_rows (approval_rows @ questions @ goals @ approvals)

let clear_ask_answering state =
  state.ask_answer_mode <- Ask_browsing;
  state.ask_origin <- None;
  state.ask_draft <- None;
  state.ask_text_entry <- None;
  Masc_tui_types.disarm_ask_submit state

let reconcile_home_request_detail state =
  match state.home_opened_request with
  | None -> ()
  | Some request ->
      let expected_surface = match request with
        | Home_held_call _ | Home_gate_request _ | Home_operator_request _ | Home_question _ -> Approvals
        | Home_goal_confirmation _ -> Planning
      in
      if state.view <> expected_surface then begin
        state.home_opened_request <- None;
        (match state.followed_from with
         | Some (Overview, _) -> state.followed_from <- None
         | Some
             ( ( Acting | Metrics | Keepers _ | Memory | Lanes | Clients | Board
               | Approvals | Planning | Schedules | Verification | Harness
               | Fusion | Repositories | Code | Changes | Connectors | Runtime
               | Config | Resources | Tools | System_logs )
             , _ )
         | None -> ())
      end else if
        (match request with
         | Home_question _ ->
             state.workspace_identity <> Workspace_identity_match
             || (match approvals_questions_reading state with
                 | List_not_read _ -> true
                 | List_read -> false)
         | Home_held_call _ | Home_gate_request _ | Home_operator_request _
         | Home_goal_confirmation _ -> false)
      then ()
      else if not (List.exists (fun (action, _) -> equal_home_action action (Home_request request))
                     (decision_rows_of_state state)) then begin
        (match request with
          | Home_question _ -> clear_ask_answering state
          | Home_held_call _ | Home_gate_request _ | Home_operator_request _
          | Home_goal_confirmation _ -> ());
        state.home_opened_request <- None;
        state.approval_detail_open <- false;
        state.approval_value_reading <- None;
        state.pending_approval_action <- None;
        state.followed_from <- None;
        state.view <- Overview
      end else
        match request with
        | Home_held_call _ | Home_gate_request _ | Home_operator_request _ ->
            Option.iter (fun index -> state.approval_cursor <- index)
              (List.find_index (fun row -> equal_home_request (home_request_of_approval row) request)
                 (approval_items state))
        | Home_question ask ->
            Option.iter (fun index -> state.ask_cursor <- Masc_tui_ask_projection.On index)
              (List.find_index (fun row -> Masc.Tui_decode_asks.(equal_ask_key ask (ask_key row)))
                 (Option.value ~default:[] (approvals_open_questions state)))
        | Home_goal_confirmation goal_id ->
            state.planning_mode <- Planning_detail goal_id;
            (match state.planning with
             | None -> ()
             | Some planning ->
                 Option.iter (fun index -> state.planning_cursor <- index)
                   (List.find_index
                      (fun (goal : planning_goal) -> String.equal goal.pg_id goal_id)
                      (planning_visible_goals ~filter:state.planning_filter
                         ~sort:state.planning_sort planning.pl_goals)))

let continue_rows_of_state (state : state) =
  let text ko en = ui_text state ~ko ~en in
  let last =
    match state.home_last_chat, state.opening_mode with
    | Recorded_chat name, _ -> Some (Keeper_id.Keeper_name.to_string name, "")
    | Saving_chat name, _ ->
        Some (Keeper_id.Keeper_name.to_string name, text " · 저장 중" " · save pending")
    | Unobserved_chat { keeper; _ }, _ ->
        Some (Keeper_id.Keeper_name.to_string keeper, text " · 저장 결과 미확인" " · save outcome unknown")
    | Session_chat { keeper; _ }, _ ->
        Some (Keeper_id.Keeper_name.to_string keeper, text " · 이번 세션에서만" " · this session only")
    | Unconfirmed_chat { keeper; _ }, _ ->
        Some (Keeper_id.Keeper_name.to_string keeper, text " · 저장 유지 여부 미확인" " · save durability unconfirmed")
    | No_chat_receipt, Masc_tui_config.Last (Some name) ->
        Some (Keeper_id.Keeper_name.to_string name, "")
    | Unreadable_chat_receipt _, _
    | No_chat_receipt, (Masc_tui_config.Last None | Masc_tui_config.Overview
                       | Masc_tui_config.Keeper _) -> None
  in
  let resume =
    match last with
    | Some (name, save_notice) when state.workspace_identity = Workspace_identity_match
                   && keeper_available_for_new_message state name ->
        [ Home_resume name,
          text "이어가기 · " "Continue with " ^ Masc_tui_ansi.Terminal_text.single_line name
          ^ save_notice ]
    | Some (name, save_notice) when state.workspace_identity = Workspace_identity_match
                         && Option.is_some state.keepers_error ->
        [ Home_read_last name,
          text "최근 대화 · " "Last conversation with " ^ Masc_tui_ansi.Terminal_text.single_line name
          ^ save_notice
          ^ text " · 키퍼 목록 조회 불가, 이력 보기" " · roster unavailable; read history" ]
    | Some _ | None -> []
  in
  let choose =
    match state.workspace_identity, state.local_keepers, state.keepers_error, state.keepers with
    | Workspace_identity_match, Local_workspace_read, None, [] ->
        [ Home_create_keeper,
          (match state.home_last_chat, last with
           | Unreadable_chat_receipt _, _ ->
               text "키퍼 만들기 · 대화 이력 조회 불가" "Create a Keeper · conversation history unavailable"
           | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _
              | Saving_chat _ | Unobserved_chat _), Some (name, _) ->
               text "키퍼 만들기 · 최근 대화 " "Create a Keeper · last conversation "
               ^ Masc_tui_ansi.Terminal_text.single_line name ^ text " 이용 불가" " unavailable"
           | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _
              | Saving_chat _ | Unobserved_chat _), None ->
               text "키퍼 만들기 · 대화 시작" "Create a Keeper · start a conversation") ]
    | (Workspace_identity_match, Local_workspace_read, None, _::_)
    | (Workspace_identity_match, Local_workspace_read, Some _, _)
    | (Workspace_identity_match, (Local_workspace_unread | Local_workspace_failed _), _, _)
    | ((Workspace_identity_unread | (Workspace_identity_match_unconfirmed _ | Workspace_identity_mismatch _)), _, _, _) -> [ Home_choose_keeper,
          (match resume with
           | [] ->
               (match state.home_last_chat, last with
                | Unreadable_chat_receipt _, _ ->
                    text "대화 이력 조회 불가 · 키퍼 선택" "Conversation history unavailable · choose a Keeper"
                | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _
                   | Saving_chat _ | Unobserved_chat _), Some (name, _) ->
                    text "최근 대화 " "Last conversation " ^ Masc_tui_ansi.Terminal_text.single_line name
                    ^ (match state.workspace_identity with
                       | Workspace_identity_unread ->
                           text " 이용 불가 · 워크스페이스 식별 미조회 · 키퍼 선택"
                             " unavailable · workspace identity not read · choose a Keeper"
                       | Workspace_identity_match_unconfirmed _ ->
                           text " 이용 불가 · 워크스페이스 식별 미확인 · 키퍼 선택"
                             " unavailable · workspace identity unconfirmed · choose a Keeper"
                       | Workspace_identity_match | Workspace_identity_mismatch _ ->
                           text " 이용 불가 · 키퍼 선택" " unavailable · choose a Keeper")
                | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _
                   | Saving_chat _ | Unobserved_chat _), None ->
                    text "키퍼 선택 · 대화 시작" "Choose a Keeper · start a conversation")
           | _ :: _ -> text "다른 키퍼와 대화" "Talk to another Keeper") ]
  in
  resume @ choose

(* Frame preparation pins only an authoritative initial reading; transient
   boot destinations must remain free to settle. Drawing shares these pure
   projections but does not store either selection or viewport state. *)
let operator_action_label state (item : Masc.Operator_action_reason.t) =
  let text ko en = ui_text state ~ko ~en in
  let clean = Masc_tui_ansi.Terminal_text.single_line in
  match item.cause with
  | Masc.Operator_action_reason.Memory_attention {keeper;durable;admission;_} ->
      let ko = state.ui_language=Lang_ko in
      let durable = Option.to_list durable
          |> List.filter Masc.Keeper_librarian_pending.needs_attention
          |> List.map (fun pending -> memory_pass_text ~ko
              (Masc.Tui_decode_memory_health.Pass_pending pending)) in
      let admission = Option.to_list admission
          |> List.filter (fun admission -> Masc.Keeper_librarian_pending.needs_attention
              (Masc.Keeper_librarian_pending.admission_pending admission))
          |> List.map (memory_admission_text ~ko) in
      let causes = durable @ admission in
      "Memory · " ^ clean keeper ^ " · " ^ String.concat " · " causes
      ^ text " · Enter:상세" " · Enter:details"
  | Shutdown_fenced_backlog {count; keepers=Some [(keeper,_)]; complete=true} ->
      text "대기 목록 · " "Queue · " ^ clean keeper
      ^ Printf.sprintf (if state.ui_language=Lang_ko then " · 종료 보류 %d건" else " · %d shutdown-fenced events") count
  | Shutdown_fenced_backlog {count;complete;_} ->
      text "진단 · " "Reading · "
      ^ Printf.sprintf (if state.ui_language=Lang_ko then "종료 보류 %d건" else "%d shutdown-fenced events") count
      ^ (if complete then text " · 대상 확인" " · inspect owners"
         else text " · 전체 미확인" " · coverage unknown")
  | Other_reported ->
      let component = match item.component with
        | "keeper_memory_execution" -> text "기억 처리" "Memory execution"
        | "skill_catalog" -> text "스킬 목록" "Skill catalog"
        | "keeper_config_schema" -> text "키퍼 설정" "Keeper configuration"
        | component -> clean (String.escaped component) in
      component ^ text " · 진단 확인" " · inspect diagnostics"

let operator_rows_of_state state =
  Option.value (Option.map (List.mapi (fun index item ->
    Home_operator_action (state.workspace_authority,index,item), operator_action_label state item))
    (operator_actions state)) ~default:[]

let initial_reading_ready state selected =
  match selected with
  | Some (Home_request _ | Home_resume _ | Home_read_last _ | Home_operator_action _) -> true
  | Some Home_approvals -> approvals_reading_current state
  | Some (Home_choose_keeper | Home_create_keeper) ->
      approvals_reading_current state
      && (match state.goals_to_confirm with
        | Masc_tui_agenda.Read _ -> true
        | Masc_tui_agenda.Not_read | Read_failed _ -> false)
  | Some Home_agenda | None -> false

let notice_lines_of_state state =
  let text ko en = ui_text state ~ko ~en in
  let clean = Masc_tui_ansi.Terminal_text.single_line in
  (match Masc_tui_credential_preparation.status state.credential_preparation with
   | Not_requested | Settled -> []
   | Preparing _ -> [text " 워크스페이스 접근 준비 중…" " Preparing workspace access…"]
   | Awaiting_ui _ -> [text " 워크스페이스 접근 준비 결과 반영 대기…" " Workspace access result awaiting application…"])
  @ (match state.opening_notice with
   | None -> []
   | Some notice -> [" " ^ clean notice])
  @ (match operator_actions state with
     | None -> [text " 조치 원인 미관측 · v:진단" " Action reasons unobserved · v:reading"]
     | Some _ -> [])
  @ (match state.home_decision_receipt with
     | None -> []
     | Some (_, receipt) -> [text " 최근 응답 · " " Last decision receipt · " ^ clean receipt])

type prepared = {
  decisions : (home_action * string) list;
  continuation : (home_action * string) list;
  operator_rows : (home_action * string) list;
  selected : home_action option;
  selection_changed : bool;
  notices : string list;
  help_hint_shown : bool;
  initial_ready : bool;
}

let prepare (state : state) =
  let decisions = decision_rows_of_state state in
  let continuation = continue_rows_of_state state in
  let operator_rows = operator_rows_of_state state in
  let first = function [] -> None | (action, _) :: _ -> Some action in
  let selected = match state.home_selected with
    | None ->
        (match first decisions with
         | Some _ as action -> action
         | None -> (match first operator_rows with Some _ as action -> action | None -> first continuation))
    | Some action ->
        let find rows = Option.map fst
          (List.find_opt (fun (current, _) -> equal_home_action action current) rows) in
        (match find decisions with
         | Some _ as action -> action
         | None -> (match find operator_rows with Some _ as action -> action | None -> find continuation))
  in
  { decisions; continuation; operator_rows; selected;
    selection_changed = Option.is_some state.home_selected && Option.is_none selected;
    notices = notice_lines_of_state state;
    help_hint_shown = state.help_hint_shown;
    initial_ready = initial_reading_ready state selected }

let home_decision_rows prepared = prepared.decisions
let home_continue_rows prepared = prepared.continuation
let home_operator_rows prepared = prepared.operator_rows
let home_selected_action prepared = prepared.selected
let home_initial_reading_ready prepared = prepared.initial_ready
let home_notice_lines prepared = prepared.notices

type body = {
  hb_help : bool; hb_shortcuts : bool; hb_notices : string list;
  hb_selection_changed : bool; hb_rows : (home_action * string) list;
  hb_first : int; hb_total : int; hb_spare : int;
}
let home_body prepared ~scroll ~budget =
  let destinations = prepared.decisions @ prepared.operator_rows @ prepared.continuation in
  let budget = max 0 budget in
  let reserve = if destinations = [] then 0 else min 1 budget in
  let extra = max 0 (budget - reserve) in
  let hb_selection_changed = prepared.selection_changed && extra > 0 in
  let extra = extra - if hb_selection_changed then 1 else 0 in
  let hb_notices = List.take extra prepared.notices in
  let extra = extra - List.length hb_notices in
  let hb_help = not prepared.help_hint_shown && extra > 0 in
  let extra = extra - if hb_help then 1 else 0 in
  let hb_shortcuts = extra > 0 in
  let room = budget - (if hb_help then 1 else 0) - (if hb_shortcuts then 1 else 0)
      - (if hb_selection_changed then 1 else 0) - List.length hb_notices in
  let hb_total = List.length destinations in
  let height = min hb_total room in
  let first = max 0 (min scroll (hb_total - height)) in
  let first = match List.find_index (fun (action,_) ->
      Option.equal equal_home_action (Some action) prepared.selected) destinations with
    | Some index when height > 0 && index < first -> index
    | Some index when height > 0 && index >= first + height -> index - height + 1
    | Some _ | None -> first in
  {hb_help;hb_shortcuts;hb_notices;hb_selection_changed;
   hb_rows=List.drop first destinations |> List.take height;
   hb_first=first;hb_total;hb_spare=room-height}

let home_step state ~backwards =
  let prepared = prepare state in
  let actions = List.map fst (prepared.decisions @ prepared.operator_rows @ prepared.continuation) in
  let current = prepared.selected in
  let index =
    match List.find_index (fun action -> Option.equal equal_home_action (Some action) current) actions with
    | None -> 0
    | Some index ->
        if backwards then max 0 (index - 1)
        else min (List.length actions - 1) (index + 1)
  in
  state.home_selected <- List.nth_opt actions index
