type t =
  { admitted_scheduled_input : string
  ; goal_context : string option
  ; task_context : string option
  ; remaining_context : string option
  ; workspace_memory : Workspace_memory_ledger.observation
  ; wiki_contents : Keeper_wiki_contents.t
  }

let nonempty fragments =
  List.filter (fun text -> String.trim text <> "") fragments

let prepare_common fragments =
  match nonempty fragments with
  | [] -> None
  | fragments -> Some (String.concat "\n\n" fragments)

let direct_turn_task_context
      ~(current_task : Keeper_world_observation_inputs.current_task_observation)
      ~(held_task_skills : Keeper_world_observation_inputs.held_task_skills list)
      ~(task_skill_surfaces : (string * Keeper_skill_catalog.exact_surface list) list)
  : string
  =
  let current =
    let skill_surfaces =
      match current_task with
      | Keeper_world_observation_inputs.Current_task task
      | Recovered_current_task { task; _ } -> List.assoc_opt task.id task_skill_surfaces
      | No_current_task | Current_task_missing _ | Current_task_unavailable _ -> None
    in
    match Keeper_unified_prompt.format_current_task_observation ?skill_surfaces current_task with
    | Some rendered -> rendered
    | None -> ""
  in
  let held =
    match Keeper_unified_prompt.format_held_task_skills ~skill_surfaces_by_task:task_skill_surfaces held_task_skills with
    | Some rendered -> rendered
    | None -> ""
  in
  current ^ held

let prepare ~turn_ref ~active_goal_summaries ~current_task ~held_task_skills ~task_skill_surfaces
    ~workspace_memory ~wiki_contents ~lane_updates ~approval_authority_text
    ~recent_direct_conversation_text ~worktree_text ~telemetry_feedback_text
    ~turn_instructions_text () =
  let goal_context = Keeper_unified_prompt.format_active_goal_summaries active_goal_summaries in
  let task_context = prepare_common
      [direct_turn_task_context ~current_task ~held_task_skills ~task_skill_surfaces] in
  let remaining_context = prepare_common
      (Option.to_list (Lane_addon_subscription.render lane_updates)
       @ [approval_authority_text; recent_direct_conversation_text; worktree_text;
          telemetry_feedback_text; turn_instructions_text]) in
  let admitted_scheduled_input = Keeper_unified_prompt_event_fields.format_scheduled_admission
      ~turn_ref ~admission:Unknown in
  { admitted_scheduled_input; goal_context; task_context; remaining_context; workspace_memory; wiki_contents }

let project_partition prepared ~workspace_memory_access =
  let dynamic =
    Option.to_list (Keeper_unified_prompt.format_workspace_memory_observation
      ?access:workspace_memory_access prepared.workspace_memory)
    @ Option.to_list (Keeper_unified_prompt.format_wiki_observation
      ?access:workspace_memory_access prepared.wiki_contents)
    |> nonempty in
  (* Common fragments have already been filtered and coalesced. Do not scan
     their text again for each request; concatenation retains the original
     Goal / Task / memory / wiki / Lane-and-conversation order and exact separators. *)
  let remaining = String.concat "\n\n"
      (Option.to_list prepared.task_context @ dynamic @ Option.to_list prepared.remaining_context) in
  let observations = Keeper_context_layers.assemble ~content_of:(function
    | Active_goals -> prepared.goal_context
    | Admitted_scheduled_input -> Some prepared.admitted_scheduled_input
    | Current_task | Approval_authority | Connected_surfaces | Namespace_state
    | Workspace_memory | Wiki | Lane_updates | Repository_freshness | Autonomous_trigger
    | Scheduled_automation | Completion_authority | Task_cancellations | Pending_mentions
    | Scope_messages | Own_board_posts | Board_activity | Own_recent_actions | Recent_work
    | Fleet_messages -> None) in
  Keeper_context_layers.append_unattributed observations Direct_turn
    (if remaining = "" then "" else "\n\n" ^ remaining)

let project prepared ~workspace_memory_access =
  project_partition prepared ~workspace_memory_access |> Keeper_context_layers.text
