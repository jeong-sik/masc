(** Home decisions, continuation and selection over the terminal state. *)

open Masc_tui_types
open Masc_tui_approvals_model

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
           | Home_choose_keeper | Home_create_keeper -> ());
          reversed) [] rows
  in
  List.rev_map (fun (action, label) -> action, !label) reversed

(* Current successes survive another source's failure. Stale snapshots are
   reachable through their source reading, never offered as current requests. *)
let decision_rows_of_state (state : state) =
  let reading = approvals_reading state in
  let clean = Masc_tui_ansi.Terminal_text.single_line in
  let approval_rows =
    approval_items state
    |> List.filter_map (fun row ->
      let current, who, why, kind, request_id = match row with
        | Keeper_tool_row held ->
            list_is_read reading.held_calls, held.kta_keeper, held.kta_question, "Held call", held.kta_tool_call_id
        | Gate_row pending ->
            list_is_read reading.gate_queue, pending.gp_keeper, pending.gp_display_tool, "Gate approval", pending.gp_id
        | Operator_row item ->
            list_is_read reading.confirm_queue, item.ap_actor, item.ap_summary, "Confirm", item.ap_token
      in
      if current && approval_item_needs_person row then
        Some (Home_request (home_request_of_approval row),
              Printf.sprintf "%s · %s [%s] · %s" kind (clean who)
                (Masc_tui_message_layout.truncate_middle 12 (clean request_id)) (clean why))
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
          Home_request (Home_question (Masc.Tui_decode_asks.ask_key row)),
          Printf.sprintf "Question · %s [%s] · %s" (clean (Masc.Tui_decode_asks.ask_asker_label row.ar_asker))
            (Masc_tui_message_layout.truncate_middle 12 (clean row.ar_id)) (clean why))
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
          ["workspace identity unconfirmed · decisions wait"]
      | Workspace_identity_unread | Workspace_identity_match
      | Workspace_identity_mismatch _ -> []
    in
    let unread = identity @ match source_notes with
      | [] -> []
      | names -> ["not fully read · " ^ String.concat ", " names]
    in
    let notes =
      match state.approval_snapshot with
      | Some snapshot when snapshot.aps_hidden_count > 0 ->
          unread @ [Printf.sprintf "%d requests outside current filter" snapshot.aps_hidden_count]
      | Some _ | None -> unread
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
  let tasks = match state.operator_stalled with
    | Masc_tui_agenda.Read_failed _ -> [Home_agenda, "Operator tasks unavailable · inspect sources"]
    | Not_read -> [Home_agenda, "Operator tasks not read · inspect sources"]
    | Read rows ->
        List.map (fun (row : Masc_tui_agenda.stalled) ->
          let id = clean row.task_id in
          let what = clean row.what in
          let detail =
            if String.starts_with ~prefix:(id ^ ":") what
               || String.starts_with ~prefix:(id ^ " · ") what
            then what
            else Printf.sprintf "%s · %s" id what
          in
          Home_request (Home_operator_task row.task_id),
          Printf.sprintf "Operator task · %s" detail) rows
  in
  (* Equality is kind plus authoritative request ID, never a Keeper/task
     grouping key. Distinct calls belonging to one Keeper remain distinct. *)
  ordered_decision_rows (approval_rows @ questions @ goals @ tasks @ approvals)

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
        | Home_goal_confirmation _ | Home_operator_task _ -> Planning
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
         | Home_goal_confirmation _ | Home_operator_task _ -> false)
      then ()
      else if not (List.exists (fun (action, _) -> equal_home_action action (Home_request request))
                     (decision_rows_of_state state)) then begin
        (match request with
          | Home_question _ -> clear_ask_answering state
          | Home_held_call _ | Home_gate_request _ | Home_operator_request _
          | Home_goal_confirmation _ | Home_operator_task _ -> ());
        state.home_opened_request <- None;
        state.approval_detail_open <- false;
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
        | Home_operator_task task_id -> state.task_detail_id <- Some task_id

let continue_rows_of_state (state : state) =
  let last =
    match state.home_last_chat, state.opening_mode with
    | Recorded_chat name, _ -> Some (Keeper_id.Keeper_name.to_string name, "")
    | Saving_chat name, _ ->
        Some (Keeper_id.Keeper_name.to_string name, " · save pending")
    | Unobserved_chat { keeper; _ }, _ ->
        Some (Keeper_id.Keeper_name.to_string keeper, " · save outcome unknown")
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
    match state.workspace_identity, state.local_keepers, state.keepers_error, state.keepers with
    | Workspace_identity_match, Local_workspace_read, None, [] ->
        [ Home_create_keeper,
          (match state.home_last_chat, last with
           | Unreadable_chat_receipt _, _ ->
               "Create a Keeper · conversation history unavailable"
           | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _
              | Saving_chat _ | Unobserved_chat _), Some (name, _) ->
               "Create a Keeper · last conversation "
               ^ Masc_tui_ansi.Terminal_text.single_line name ^ " unavailable"
           | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _
              | Saving_chat _ | Unobserved_chat _), None ->
               "Create a Keeper  · choose who will take the work") ]
    | (Workspace_identity_match, Local_workspace_read, None, _::_)
    | (Workspace_identity_match, Local_workspace_read, Some _, _)
    | (Workspace_identity_match, (Local_workspace_unread | Local_workspace_failed _), _, _)
    | ((Workspace_identity_unread | (Workspace_identity_match_unconfirmed _ | Workspace_identity_mismatch _)), _, _, _) -> [ Home_choose_keeper,
          (match resume with
           | [] ->
               (match state.home_last_chat, last with
                | Unreadable_chat_receipt _, _ ->
                    "Conversation history unavailable · choose a Keeper"
                | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _
                   | Saving_chat _ | Unobserved_chat _), Some (name, _) ->
                    "Last conversation " ^ Masc_tui_ansi.Terminal_text.single_line name
                    ^ (match state.workspace_identity with
                       | Workspace_identity_unread ->
                           " unavailable · workspace identity not read · choose a Keeper"
                       | Workspace_identity_match_unconfirmed _ ->
                           " unavailable · workspace identity unconfirmed · choose a Keeper"
                       | Workspace_identity_match | Workspace_identity_mismatch _ ->
                           " unavailable · choose a Keeper")
                | (No_chat_receipt | Recorded_chat _ | Session_chat _ | Unconfirmed_chat _
                   | Saving_chat _ | Unobserved_chat _), None ->
                    "Choose a Keeper  · start a conversation")
           | _ :: _ -> "New work  · choose a Keeper") ]
  in
  resume @ choose

(* Frame preparation pins only an authoritative initial reading; transient
   boot destinations must remain free to settle. Drawing shares these pure
   projections but does not store either selection or viewport state. *)
let initial_reading_ready state selected =
  match selected with
  | Some (Home_request _ | Home_resume _ | Home_read_last _) -> true
  | Some Home_approvals -> approvals_reading_current state
  | Some (Home_choose_keeper | Home_create_keeper) ->
      approvals_reading_current state
      && (match state.operator_stalled with Masc_tui_agenda.Read _ -> true | Not_read | Read_failed _ -> false)
      && (match state.goals_to_confirm with
        | Masc_tui_agenda.Read _ -> true
        | Masc_tui_agenda.Not_read | Read_failed _ -> false)
  | Some Home_agenda | None -> false

let notice_lines_of_state state =
  let clean = Masc_tui_ansi.Terminal_text.single_line in
  (match Masc_tui_credential_preparation.status state.credential_preparation with
   | Not_requested | Settled -> []
   | Preparing _ -> [" Preparing workspace access…"]
   | Awaiting_ui _ -> [" Workspace access result awaiting application…"])
  @ (match state.opening_notice with
   | None -> []
   | Some notice -> [" " ^ clean notice])
  @ (match state.home_decision_receipt with
     | None -> []
     | Some (_, receipt) -> [" Last decision receipt · " ^ clean receipt])

type prepared = {
  decisions : (home_action * string) list;
  continuation : (home_action * string) list;
  selected : home_action option;
  selection_changed : bool;
  notices : string list;
  help_hint_shown : bool;
  initial_ready : bool;
}

let prepare (state : state) =
  let decisions = decision_rows_of_state state in
  let continuation = continue_rows_of_state state in
  let first = function [] -> None | (action, _) :: _ -> Some action in
  let selected = match state.home_selected with
    | None ->
        (match first decisions with
         | Some _ as action -> action
         | None -> first continuation)
    | Some action ->
        let find rows = Option.map fst
          (List.find_opt (fun (current, _) -> equal_home_action action current) rows) in
        (match find decisions with
         | Some _ as action -> action
         | None -> find continuation)
  in
  { decisions; continuation; selected;
    selection_changed = Option.is_some state.home_selected && Option.is_none selected;
    notices = notice_lines_of_state state;
    help_hint_shown = state.help_hint_shown;
    initial_ready = initial_reading_ready state selected }

let home_decision_rows prepared = prepared.decisions
let home_continue_rows prepared = prepared.continuation
let home_selected_action prepared = prepared.selected
let home_selection_changed prepared = prepared.selection_changed
let home_initial_reading_ready prepared = prepared.initial_ready
let home_notice_lines prepared = prepared.notices

(* The rows Home gives its decision window: the body budget less the one-time
   help line while it is shown and the requests link that always takes the
   first body row. The drawing and the key loop that stores the window's first
   row both read this, so they cannot disagree by the help line. *)
let home_requests_budget prepared ~chrome_budget =
  let help_line = if prepared.help_hint_shown then 0 else 1 in
  max 0 (chrome_budget - help_line - 1)

let home_decision_window prepared ~scroll ~budget =
  let decisions = prepared.decisions in
  let selected = prepared.selected in
  let warning_rows = if prepared.selection_changed then 1 else 0 in
  let capacity = max 0 (budget - List.length prepared.notices
      - List.length prepared.continuation - 2 - warning_rows) in
  let first = max 0 (min scroll (List.length decisions - capacity)) in
  let first = match List.find_index (fun (action, _) -> Option.equal equal_home_action (Some action) selected) decisions with
    | Some index when index < first -> index
    | Some index when index >= first + capacity -> max 0 (index - capacity + 1)
    | Some _ | None -> first
  in
  first, capacity

let home_step state ~backwards =
  let prepared = prepare state in
  let actions = List.map fst (prepared.decisions @ prepared.continuation) in
  let current = prepared.selected in
  let index =
    match List.find_index (fun action -> Option.equal equal_home_action (Some action) current) actions with
    | None -> 0
    | Some index ->
        if backwards then max 0 (index - 1)
        else min (List.length actions - 1) (index + 1)
  in
  state.home_selected <- List.nth_opt actions index
