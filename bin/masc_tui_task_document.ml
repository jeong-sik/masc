open Masc_tui_ansi
module Tui_decode = Masc.Tui_decode
module Message_layout = Masc_tui_message_layout
module Planning_detail = Masc_tui_planning_detail

let history_lines ~width ~view ~in_flight =
  let header = "  HISTORY" in
  let observed = function
        | [] -> [ "    (no events recorded)" ]
        | events ->
            List.concat_map
              (fun (event : Tui_decode.task_history_event) ->
                let transition =
                  match event.Tui_decode.th_from_status, event.th_to_status with
                  | Some from_status, Some to_status ->
                      Printf.sprintf "  %s -> %s" from_status to_status
                  | Some from_status, None -> "  from " ^ from_status
                  | None, Some to_status -> "  -> " ^ to_status
                  | None, None -> ""
                in
                let actor =
                  match event.th_actor with
                  | Some actor -> "  by " ^ actor
                  | None -> ""
                in
                Printf.sprintf "    %s  %s%s%s"
                  (Planning_detail.short_ts event.th_ts)
                  event.th_label transition actor
                :: (match event.th_note with
                    | Some note -> [ "      " ^ note ]
                    | None -> []))
              events
  in
  let rows =
    match view with
    | Masc_tui_fetched.Ready events -> observed events
    | Masc_tui_fetched.Stale (events, detail) ->
        Masc_tui_text_block.rows ~max_cells:width
          ("    refresh failed; previous history: " ^ Terminal_text.single_line detail)
        @ observed events
    | Masc_tui_fetched.Failed detail -> Masc_tui_text_block.rows ~max_cells:width
        ("    load failed: " ^ Terminal_text.single_line detail)
    | Masc_tui_fetched.Absent -> [ "    history not requested" ]
    | Masc_tui_fetched.Loading -> [ "    loading..." ]
  in
  let pending =
    if not in_flight then []
    else match view with
      | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _ -> [ "    refreshing; previous history" ]
      | Masc_tui_fetched.Failed _ -> [ "    retrying; previous failure remains" ]
      | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading -> [] in
  ("" :: header :: (pending @ rows))

let body_lines ~cols ~goal_lines (task : Masc_domain.task) =
  let width = max 1 (framed_inner_width cols - 2) in
  let labeled_lines label text =
    let prefix = "  " ^ label ^ ": " in
    let prefix_width = Message_layout.display_width prefix in
    if prefix_width < framed_inner_width cols then
      Masc_tui_text_block.rows ~max_cells:(framed_inner_width cols - prefix_width) text
      |> List.mapi (fun index line ->
           (if index = 0 then prefix else String.make prefix_width ' ') ^ line)
    else
      (Message_layout.wrap_words ~max_cells:width label
       |> List.map (fun line -> "  " ^ line))
      @ (Masc_tui_text_block.rows ~max_cells:width text
         |> List.map (fun line -> "  " ^ line))
  in
  let some_lines label = function None -> [] | Some text -> labeled_lines label text in
  let list_lines label items = List.concat_map (labeled_lines label) items in
  (* Status, actor and every transition's evidence are real rows in the same
     reading as the description. No metadata field is a one-line preview. *)
  let status_lines =
    match task.task_status with
    | Masc_domain.Todo -> labeled_lines "status" "todo — unclaimed"
    | Masc_domain.Claimed { assignee; claimed_at } ->
        labeled_lines "status" "claimed" @ labeled_lines "actor" assignee
        @ labeled_lines "claimed" claimed_at
    | Masc_domain.InProgress { assignee; started_at } ->
        labeled_lines "status" "in progress" @ labeled_lines "actor" assignee
        @ labeled_lines "started" started_at
    | Masc_domain.AwaitingVerification { assignee; started_at; submitted_at; verification_id } ->
        labeled_lines "status" "awaiting verification" @ labeled_lines "actor" assignee
        @ labeled_lines "started" started_at @ labeled_lines "submitted" submitted_at
        @ labeled_lines "verification" verification_id
    | Masc_domain.Done { assignee; completed_at; notes } ->
        labeled_lines "status" "done" @ labeled_lines "actor" assignee
        @ labeled_lines "completed" completed_at @ some_lines "notes" notes
    | Masc_domain.Cancelled { cancelled_by; cancelled_at; reason } ->
        labeled_lines "status" "cancelled" @ labeled_lines "actor" cancelled_by
        @ labeled_lines "cancelled" cancelled_at @ some_lines "reason" reason
  in
  labeled_lines "title" task.title @ labeled_lines "id" task.id @ goal_lines
  @ status_lines
  @ labeled_lines "created" task.created_at
  @ labeled_lines "creator" (match task.created_by with Some by -> by | None -> Masc_tui_theme.Glyph.no_value)
  @ labeled_lines "priority" (string_of_int task.priority)
  @ labeled_lines "cycles" (string_of_int task.cycle_count)
  @ some_lines "predecessor" task.predecessor_task_id
  @ some_lines "operation" task.execution_links.operation_id
  @ some_lines "session" task.execution_links.session_id
  @ some_lines "reclaim policy"
      (Option.map Masc_domain.task_reclaim_policy_to_string task.reclaim_policy)
  @ some_lines "do not reclaim" task.do_not_reclaim_reason
  @ List.concat_map (fun skill ->
      labeled_lines "skill" (Yojson.Safe.to_string (Skill_reference.to_yojson skill))) task.skills
  @ (if String.equal task.description "" then [] else labeled_lines "what" task.description)
  @ (match task.handoff_context with
     | None -> []
     | Some handoff ->
         some_lines "why" handoff.Masc_domain.reason
         @ (if String.equal handoff.Masc_domain.summary "" then [] else labeled_lines "handoff" handoff.Masc_domain.summary)
         @ some_lines "next" handoff.Masc_domain.next_step
         @ some_lines "failure" handoff.Masc_domain.failure_mode
         @ some_lines "handoff reclaim policy"
             (Option.map Masc_domain.task_reclaim_policy_to_string
                handoff.Masc_domain.reclaim_policy)
         @ some_lines "handoff updated" handoff.Masc_domain.updated_at
         @ some_lines "handoff updater" handoff.Masc_domain.updated_by
         @ list_lines "evidence" handoff.Masc_domain.evidence_refs)
  @ (match task.contract with
     | None -> []
     | Some contract ->
         (if contract.Masc_domain.strict then ["  contract strict"] else [])
         @ list_lines "done-when" contract.Masc_domain.completion_contract
         @ list_lines "evidence" contract.Masc_domain.required_evidence
         @ list_lines "inspection evidence" contract.Masc_domain.inspect_gate_evidence
         @ list_lines "verification evidence" contract.Masc_domain.verify_gate_evidence)
  @ list_lines "file" task.files

