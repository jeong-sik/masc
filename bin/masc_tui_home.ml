(** Home decisions, continuation and selection over the terminal state. *)

open Masc_tui_types
open Masc_tui_approvals_model

let home_request_of_approval = function
  | Keeper_tool_row held ->
      Home_held_call { keeper = held.Tui_decode.kta_keeper; call_id = held.kta_tool_call_id }
  | Gate_row pending -> Home_gate_request pending.Tui_decode.gp_id
  | Operator_row item -> Home_operator_request item.ap_token

(* Current successes survive another source's failure. Stale snapshots are
   reachable through their source reading, never offered as current requests. *)
let home_decision_rows (state : state) =
  let reading = approvals_reading state in
  let clean = Masc_tui_ansi.Terminal_text.single_line in
  let approval_rows =
    approval_items state
    |> List.filter_map (fun row ->
      let current, who, why, kind, request_id = match row with
        | Keeper_tool_row held ->
            list_is_read reading.held_calls, held.kta_keeper, held.kta_question, "Held call", held.kta_tool_call_id
        | Gate_row pending ->
            list_is_read reading.gate_queue, pending.gp_keeper, pending.gp_display_tool, "Approval", pending.gp_id
        | Operator_row item ->
            list_is_read reading.confirm_queue, item.ap_actor, item.ap_summary, "Approval", item.ap_token
      in
      if current && approval_item_needs_person row then
        Some (Home_request (home_request_of_approval row),
              Printf.sprintf "%s · %s [%s] · %s" kind (clean who)
                (String.trim (Masc_tui_message_layout.fit_middle 12 (clean request_id))) (clean why))
      else None)
  in
  let questions =
    if list_is_read reading.questions then
      Option.value ~default:[] (approvals_open_questions state)
      |> List.map (fun (row : Masc.Tui_decode_asks.ask_row) ->
          let why = match row.ar_context, row.ar_questions with
            | Some reason, _ -> reason
            | None, question :: _ -> question.aq_prompt
            | None, [] -> "open question"
          in
          Home_request (Home_question row.ar_id),
          Printf.sprintf "Question · %s [%s] · %s" (clean row.ar_keeper)
            (String.trim (Masc_tui_message_layout.fit_middle 12 (clean row.ar_id))) (clean why))
    else []
  in
  let source_notes =
    approval_row_lists reading @ ["questions", reading.questions]
    |> List.filter_map (fun (name, status) -> match status with
        | List_read -> None
        | List_not_read _ -> Some (name ^ " not fully read"))
  in
  let approvals =
    let notes =
      match state.approval_snapshot with
      | Some snapshot when snapshot.aps_hidden_count > 0 ->
          source_notes @ [Printf.sprintf "%d requests outside current filter" snapshot.aps_hidden_count]
      | Some _ | None -> source_notes
    in
    match notes with
    | [] ->
        let count =
          List.map fst (approval_rows @ questions) |> List.sort_uniq compare |> List.length
        in
        if count = 0 then []
        else [Home_approvals, Printf.sprintf "Approvals and questions: %d need you · all requests" count]
    | _ :: _ -> [Home_approvals, "Approvals and questions: " ^ String.concat "; " notes]
  in
  let goals = match state.goals_to_confirm with
    | Masc_tui_agenda.Read rows ->
        List.map (fun (row : Masc_tui_agenda.goal_to_confirm) ->
          Home_request (Home_goal_confirmation row.goal_id),
          Printf.sprintf "Confirm Goal · %s · %s" (clean row.goal_id) (clean row.title)) rows
    | Not_read -> [Home_agenda, "Goal confirmations not read · inspect sources"]
    | Read_failed _ -> [Home_agenda, "Goal confirmations unavailable · inspect sources"]
  in
  let tasks = match state.tasks_error, state.operator_stalled with
    | Some _, _ -> [Home_agenda, "Operator tasks unavailable · inspect sources"]
    | None, None -> [Home_agenda, "Operator tasks not read · inspect sources"]
    | None, Some rows ->
        List.map (fun (row : Masc_tui_agenda.stalled) ->
          Home_request (Home_operator_task row.task_id),
          Printf.sprintf "Operator task · %s · %s" (clean row.task_id) (clean row.what)) rows
  in
  (* Equality is kind plus authoritative request ID, never a Keeper/task
     grouping key. Distinct calls belonging to one Keeper remain distinct. *)
  List.fold_left (fun rows ((action, label) as row) ->
    match List.assoc_opt action rows with
    | None -> rows @ [row]
    | Some previous when action = Home_agenda ->
        List.map (fun (key, text) ->
          if key = action then key, previous ^ "; " ^ label else key, text) rows
    | Some _ -> rows) [] (approval_rows @ questions @ goals @ tasks @ approvals)

let clear_ask_answering state =
  state.ask_answer_mode <- Ask_browsing;
  state.ask_draft <- None;
  state.ask_text_entry <- None;
  state.pending_ask_submit <- None

let reconcile_home_request_detail state =
  match state.home_opened_request with
  | None -> ()
  | Some request ->
      let expected_surface = match request with
        | Home_held_call _ | Home_gate_request _ | Home_operator_request _ | Home_question _ -> Approvals
        | Home_goal_confirmation _ | Home_operator_task _ -> Planning
      in
      if state.view <> expected_surface then begin
        state.home_opened_request <- None;
        (match state.followed_from with
         | Some (Overview, _) -> state.followed_from <- None
         | Some _ | None -> ())
      end else if not (List.mem_assoc (Home_request request) (home_decision_rows state)) then begin
        (match request with Home_question _ -> clear_ask_answering state | _ -> ());
        state.home_opened_request <- None;
        state.approval_detail_open <- false;
        state.pending_approval_action <- None;
        state.followed_from <- None;
        state.view <- Overview
      end else
        match request with
        | Home_held_call _ | Home_gate_request _ | Home_operator_request _ ->
            Option.iter (fun index -> state.approval_cursor <- index)
              (List.find_index (fun row -> home_request_of_approval row = request)
                 (approval_items state))
        | Home_question ask_id ->
            Option.iter (fun index -> state.ask_cursor <- index)
              (List.find_index (fun (row : Masc.Tui_decode_asks.ask_row) -> row.ar_id = ask_id)
                 (Option.value ~default:[] (approvals_open_questions state)))
        | Home_goal_confirmation goal_id -> state.planning_mode <- Planning_detail goal_id
        | Home_operator_task task_id -> state.task_detail_id <- Some task_id

let home_continue_rows (state : state) =
  let last =
    match state.home_last_chat, state.opening_mode with
    | Recorded_chat name, _ -> Some (Keeper_id.Keeper_name.to_string name, "")
    | Session_chat { keeper; _ }, _ ->
        Some (Keeper_id.Keeper_name.to_string keeper, " · this session only")
    | Unconfirmed_chat { keeper; _ }, _ ->
        Some (Keeper_id.Keeper_name.to_string keeper, " · save durability unconfirmed")
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
          "Continue with " ^ Masc_tui_ansi.Terminal_text.single_line name
          ^ save_notice ]
    | Some (name, save_notice) when state.workspace_identity = Workspace_identity_match
                         && Option.is_some state.keepers_error ->
        [ Home_read_last name,
          "Last conversation with " ^ Masc_tui_ansi.Terminal_text.single_line name
          ^ save_notice
          ^ " · roster unavailable; read history" ]
    | Some _ | None -> []
  in
  let choose =
    match state.workspace_identity, state.local_workspace, state.keepers_error, state.keepers with
    | Workspace_identity_match, Local_workspace_read, None, [] ->
        [ Home_create_keeper,
          (match state.home_last_chat, last with
           | Unreadable_chat_receipt _, _ ->
               "Create a Keeper · conversation history unavailable"
           | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _), Some (name, _) ->
               "Create a Keeper · last conversation "
               ^ Masc_tui_ansi.Terminal_text.single_line name ^ " unavailable"
           | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _), None ->
               "Create a Keeper  · choose who will take the work") ]
    | _ ->
        [ Home_choose_keeper,
          (match resume with
           | [] ->
               (match state.home_last_chat, last with
                | Unreadable_chat_receipt _, _ ->
                    "Conversation history unavailable · choose a Keeper"
                | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _), Some (name, _) ->
                    "Last conversation " ^ Masc_tui_ansi.Terminal_text.single_line name
                    ^ " unavailable · choose a Keeper"
                | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _), None ->
                    "Choose a Keeper  · start a conversation")
           | _ :: _ -> "New work  · choose a Keeper") ]
  in
  resume @ choose

let home_actions state =
  List.map fst (home_decision_rows state @ home_continue_rows state)

let home_selected_action state =
  let actions = home_actions state in
  match state.home_selected with
  | None -> List.nth_opt actions 0
  | Some action ->
      if List.mem action actions then Some action else None

(* Frame preparation pins only an authoritative initial reading; transient
   boot destinations must remain free to settle. Drawing shares these pure
   projections but does not store either selection or viewport state. *)
let home_initial_reading_ready state selected =
  match selected with
  | Some (Home_request _ | Home_resume _ | Home_read_last _) -> true
  | Some Home_approvals -> approvals_reading_current state
  | Some (Home_choose_keeper | Home_create_keeper) ->
      approvals_reading_current state && Option.is_some state.operator_stalled
      && (match state.goals_to_confirm with Masc_tui_agenda.Read _ -> true | _ -> false)
  | Some Home_agenda | None -> false

let home_decision_window state ~budget =
  let decisions = home_decision_rows state in
  let continuation = home_continue_rows state in
  let selected = home_selected_action state in
  let warning_rows =
    if Option.is_some state.home_selected && Option.is_none selected then 1 else 0
  in
  let capacity = max 0 (budget - List.length continuation - 2 - warning_rows) in
  let first = max 0 (min state.home_decision_scroll (List.length decisions - capacity)) in
  let first = match List.find_index (fun (action, _) -> Some action = selected) decisions with
    | Some index when index < first -> index
    | Some index when index >= first + capacity -> max 0 (index - capacity + 1)
    | Some _ | None -> first
  in
  first, capacity

let home_step state ~backwards =
  let actions = home_actions state in
  let current = home_selected_action state in
  let index =
    match List.find_index (fun action -> Some action = current) actions with
    | None -> 0
    | Some index ->
        if backwards then max 0 (index - 1)
        else min (List.length actions - 1) (index + 1)
  in
  state.home_selected <- List.nth_opt actions index
