(** Tool-surface gating, selection constants, and backlog task reconciliation. *)


(** Tool surface types, serialization, constants, and search index
    extracted to [Keeper_agent_tool_surface_types].
    Tool selection logic below. *)

include Keeper_agent_tool_surface_types

let satisfying_tools_for_turn ~(turn_affordances : string list) ~(allowed_tool_names : string list)
  : string list
  =
  let canonicalize = Keeper_tool_resolution.canonical_tool_name in
  let allowed_set =
    List.fold_left
      (fun s n -> String_set.add (canonicalize n) s)
      String_set.empty
      allowed_tool_names
  in
  turn_affordances
  |> List.concat_map (fun aff ->
    match turn_affordance_of_string aff with
    | Some affordance ->
      tools_for_gated_affordance affordance
      |> List.filter (fun n -> String_set.mem (canonicalize n) allowed_set)
    | None -> [])
  |> Keeper_types.dedupe_keep_order

let preferred_tool_names_for_turn_affordances turn_affordances =
  turn_affordances
  |> List.filter_map turn_affordance_of_string
  |> List.concat_map (function
       | Board_curation ->
         [ "keeper_board_curation_submit" ]
       | Board_post_or_comment ->
         [ "keeper_board_comment"; "keeper_board_post" ]
       | Message_sweep ->
         [ "masc_keeper_msg"; "masc_broadcast" ]
       | Reply_in_room ->
         [ "keeper_board_comment"; "keeper_board_post";
           "masc_keeper_msg"; "masc_broadcast" ]
       | Task_claim ->
         [ "keeper_task_claim"; "masc_claim_next" ]
       | Task_audit ->
         [ "keeper_tasks_audit" ]
       | Task_verify ->
         [ "keeper_task_submit_for_verification"; "keeper_task_done";
           "masc_transition" ]
       | Work_discovery ->
         Keeper_tool_capability_axis.preferred_work_discovery_tool_names
       | Inspect_worktree_delta ->
         Keeper_tool_capability_axis.preferred_inspect_worktree_delta_tool_names)
  |> Keeper_types.dedupe_keep_order

(* Filtered variant of [turn_affordances_require_tool_gate]:  a gated
   affordance only counts when the keeper actually has a tool that can
   satisfy it.  Without this filter, presets such as [social] (which
   excludes claim/execution tools) get [Require_tool_use] forced on
   them whenever the board lists unclaimed tasks, leading to repeated
   [Failure_run_error] turns the keeper cannot resolve. *)
let turn_affordances_require_tool_gate_with_allowed
    ?(record_suppression_metric = false)
    ~(allowed_tool_names : string list) turn_affordances : bool =
  let has_matching_tool affordance =
    List.exists
      (fun tool ->
         List.mem tool allowed_tool_names
         && Keeper_tool_progress.tool_name_can_satisfy_required_contract tool)
      (tools_for_gated_affordance affordance)
  in
  let gated_affordances =
    turn_affordances
    |> List.filter_map turn_affordance_of_string
    |> List.filter should_tool_gate_affordance
  in
  let gate_requested = List.exists has_matching_tool gated_affordances in
  if record_suppression_metric && not gate_requested then
    List.iter
      (fun affordance ->
         if not (has_matching_tool affordance) then
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_required_tool_gate_suppressed_total
             ~labels:[ ("affordance", turn_affordance_to_string affordance) ]
             ())
      gated_affordances;
  gate_requested

let tool_names_for_required_gate_surface
    ~(tool_gate_requested : bool)
    ~(required_tool_names : string list)
    (tool_names : string list) : string list =
  let is_stay_silent name =
    match Tool_name.of_string name with
    | Some (Tool_name.Keeper Tool_name.Keeper.Stay_silent) -> true
    | _ -> false
  in
  let canonical_required_tool_names =
    required_tool_names
    |> List.map Keeper_tool_resolution.canonical_tool_name
    |> Keeper_types.dedupe_keep_order
  in
  let is_explicit_required_tool_name name =
    List.mem
      (Keeper_tool_resolution.canonical_tool_name name)
      canonical_required_tool_names
  in
  if not tool_gate_requested then tool_names
  else
    let actionable =
      tool_names
      |> List.filter (fun name ->
        is_explicit_required_tool_name name
        || (Keeper_tool_progress.tool_name_can_satisfy_required_contract name
            && (not (is_stay_silent name))))
      |> Keeper_types.dedupe_keep_order
    in
    match actionable with
    | [] -> tool_names
    | _ :: _ -> actionable

let should_require_tools_for_initial_turn ~(max_turns : int)
    ~(turn_affordances : string list) =
  let initial_per_call_turn = 1 in
  let initial_turn_is_last = initial_per_call_turn >= max_turns in
  max_turns > 1
  && not initial_turn_is_last
  && turn_affordances_require_tool_gate turn_affordances

let has_turn_affordance expected turn_affordances =
  List.exists
    (fun affordance ->
       match turn_affordance_of_string affordance with
       | Some affordance -> affordance = expected
       | None -> false)
    turn_affordances

let has_task_claim_affordance = has_turn_affordance Task_claim

let generic_required_actionable_tool_names ~(has_current_task : bool)
    ~(turn_affordances : string list) ~(allowed_tool_names : string list) =
  let is_stay_silent name =
    String.equal
      (Keeper_tool_resolution.canonical_tool_name name)
      "keeper_stay_silent"
  in
  let can_recommend_tool name =
    List.mem name allowed_tool_names
    && Keeper_tool_progress.tool_name_can_satisfy_required_contract name
    && not (is_stay_silent name)
    && ((not has_current_task)
        || not (Keeper_tool_progress.is_claim_context_tool_name name))
  in
  let preferred =
    preferred_tool_names_for_turn_affordances turn_affordances
    |> List.filter can_recommend_tool
    |> Keeper_types.dedupe_keep_order
  in
  match preferred with
  | _ :: _ -> preferred
  | [] ->
    allowed_tool_names
    |> List.filter can_recommend_tool
    |> Keeper_types.dedupe_keep_order

let preferred_tool_choice_for_required_turn ~(has_current_task : bool)
    ~(turn_affordances : string list) ~(allowed_tool_names : string list) =
  let is_stay_silent name =
    String.equal
      (Keeper_tool_resolution.canonical_tool_name name)
      "keeper_stay_silent"
  in
  let progress_tool_available name =
    List.mem name allowed_tool_names
    && Keeper_tool_progress.tool_name_can_satisfy_required_contract name
  in
  let executable_progress_tool_available =
    List.exists
      (fun name ->
         progress_tool_available name
         && (not (is_stay_silent name))
         && ((not has_current_task)
             || not (Keeper_tool_progress.is_claim_context_tool_name name)))
      allowed_tool_names
  in
  let actionable_tool_names =
    generic_required_actionable_tool_names ~has_current_task ~turn_affordances
      ~allowed_tool_names
  in
  let exact_tool_choice_if_public = function
    | [ name ] ->
      (match Keeper_tool_alias.route name with
       | Some _ -> Some (Agent_sdk.Types.Tool name)
       | None -> None)
    | [] | _ :: _ :: _ -> None
  in
  if has_turn_affordance Board_curation turn_affordances
     && List.exists
          progress_tool_available
          [ "keeper_board_curation_submit"; "keeper_board_cleanup" ]
  then
    (* Keep the curation submit tool visible, but do not force exact
       tool_choice. Several keeper cascades can use runtime MCP tools while
       lacking inline exact-tool-choice support; exact forcing turns those
       productive lanes into spurious pause-human failures. *)
    Agent_sdk.Types.Any
  else if (not has_current_task)
     && has_task_claim_affordance turn_affordances
     && progress_tool_available "keeper_task_claim"
  then
    (* Runtime MCP transports may report the correct call as
       [mcp__masc__keeper_task_claim]. OAS exact-tool contracts compare
       raw provider names before MASC canonicalizes them, so exact
       [Tool "keeper_task_claim"] can reject a valid claim. Keep the
       turn tool-required and let MASC validate the canonical observed
       tool names after execution. *)
    Agent_sdk.Types.Any
  else if has_turn_affordance Board_post_or_comment turn_affordances
          && List.exists
               progress_tool_available
               [ "keeper_board_comment"; "keeper_board_post"; "masc_broadcast" ]
  then Agent_sdk.Types.Any
  else if has_turn_affordance Reply_in_room turn_affordances
          && List.exists
               progress_tool_available
               [ "keeper_board_comment"; "keeper_board_post"; "masc_keeper_msg";
                 "masc_broadcast" ]
  then Agent_sdk.Types.Any
  else if has_turn_affordance Task_audit turn_affordances
          && progress_tool_available "keeper_tasks_audit"
  then Agent_sdk.Types.Tool "keeper_tasks_audit"
  else if has_turn_affordance Task_verify turn_affordances
          && progress_tool_available "masc_transition"
  then Agent_sdk.Types.Any
  else if has_current_task
          && has_turn_affordance Task_verify turn_affordances
          && progress_tool_available "keeper_task_submit_for_verification"
  then Agent_sdk.Types.Any
  else if has_current_task
          && has_turn_affordance Task_verify turn_affordances
          && progress_tool_available "keeper_task_done"
  then Agent_sdk.Types.Any
  else if not has_current_task then
    (* #10008: no active task and no applicable specific claim tool
       to force.  Fall back to [Auto] instead of [Any] so the model
       can respond with an honest refusal ("no eligible task to
       claim", "no matching affordance to exercise") without
       triggering the [Require_tool_use] contract violation.  The
       caller ([Keeper_agent_run]) reads [tool_choice = Auto] as
       "MASC dropped the specific-tool demand" and relaxes the
       completion contract to [Allow_text_or_tool].  Otherwise the
       affordance-driven gate would self-contradict — force a tool
       call when no applicable tool exists. *)
    Agent_sdk.Types.Auto
  else if not executable_progress_tool_available then
    (* Active-task gates are intentionally strict only when at least one
       executable progress tool is actually visible.  Claim/stay_silent
       tools cannot advance an already-owned task, so forcing [Any] here
       creates an impossible contract and burns a retry. *)
    Agent_sdk.Types.Auto
  else (
    match exact_tool_choice_if_public actionable_tool_names with
    | Some tool_choice -> tool_choice
    | None ->
      (* Active task in progress: keep the strict gate.  The keeper is
         expected to make progress via some tool call (board update,
         task_update, task_done, etc.). *)
      Agent_sdk.Types.Any)

let generic_required_tool_candidate_names ~(has_current_task : bool)
    ~(turn_affordances : string list) ~(allowed_tool_names : string list) =
  let actionable_tools =
    generic_required_actionable_tool_names ~has_current_task ~turn_affordances
      ~allowed_tool_names
  in
  actionable_tools
;;

let generic_required_tool_gate_guidance ~(has_current_task : bool)
    ~(turn_affordances : string list) ~(allowed_tool_names : string list) =
  let actionable_tools =
    generic_required_tool_candidate_names
      ~has_current_task
      ~turn_affordances
      ~allowed_tool_names
  in
  let preview =
    actionable_tools
    |> List.filteri (fun i _ -> i < 6)
    |> String.concat ", "
  in
  let omitted = List.length actionable_tools - min 6 (List.length actionable_tools) in
  let suffix = if omitted > 0 then Printf.sprintf " (+%d more)" omitted else "" in
  let claim_context_note =
    if has_current_task
    then " You already hold an active task; claim/context tools alone do not count as execution progress."
    else ""
  in
  if String.equal preview ""
  then
    Printf.sprintf
      "[TOOL BLOCKED] This turn has an actionable runtime signal, but no \
       currently visible keeper tool can advance it. Do not call passive \
       reads/status, claim/context tools, or keeper_stay_silent merely to \
       satisfy the contract.%s Emit a concise [STATE] blocker instead."
      claim_context_note
  else
    Printf.sprintf
      "[TOOL REQUIRED] This turn has an actionable runtime signal. Before \
       answering in natural language, call one of the currently visible keeper \
       runtime tools. Preferred tools for this signal: %s%s. Passive \
       reads/status alone do not satisfy this turn.%s"
      preview
      suffix
      claim_context_note

let required_tool_names_for_turn ~(current_task_required_tool_names : string list)
    ~(per_call_required_tool_names : string list) =
  match per_call_required_tool_names with
  | [] -> current_task_required_tool_names
  | _ :: _ -> per_call_required_tool_names

let outstanding_required_tool_names ~(required_tool_names : string list)
    ~(satisfied_tool_names : string list) =
  let satisfied =
    satisfied_tool_names
    |> List.map Keeper_tool_resolution.canonical_tool_name
    |> Keeper_types.dedupe_keep_order
  in
  required_tool_names
  |> List.filter (fun name ->
    let canonical = Keeper_tool_resolution.canonical_tool_name name in
    not (List.mem canonical satisfied))
  |> Keeper_types.dedupe_keep_order

let satisfied_required_tool_names_of_outcomes
    (calls : (string * string) list) =
  calls
  |> List.filter_map (fun (tool_name, outcome) ->
    if String.equal outcome "ok" then Some tool_name else None)
  |> Keeper_types.dedupe_keep_order

let preferred_tool_choice_for_required_tool_names
    ~(required_tool_names : string list) ~(allowed_tool_names : string list) =
  let add_visible_required acc canonical visible_name via_public_alias =
    if List.exists
         (fun (_, existing_name, _) -> String.equal existing_name visible_name)
         acc
    then acc
    else acc @ [ canonical, visible_name, via_public_alias ]
  in
  let visible_required =
    required_tool_names
    |> List.fold_left
         (fun acc name ->
            let canonical = Keeper_tool_resolution.canonical_tool_name name in
            if List.mem canonical allowed_tool_names
            then add_visible_required acc canonical canonical false
            else if List.mem name allowed_tool_names
            then add_visible_required acc canonical name false
            else (
              match Keeper_tool_name_projection.public_alias_for_internal canonical with
              | Some public when List.mem public allowed_tool_names ->
                add_visible_required acc canonical public true
              | _ -> acc))
         []
  in
  match visible_required with
  | [ canonical, name, false ]
    when not
           (Keeper_tool_progress.tool_name_can_satisfy_required_contract
              canonical
            || Keeper_tool_progress.tool_name_can_satisfy_required_contract name)
    ->
    (* Passive/read-only tools do not suffer the mutating-tool raw-name
       satisfaction ambiguity described below. When an operator explicitly
       requires one passive tool, exact tool_choice keeps the model from
       satisfying the turn with an unrelated write. *)
    Agent_sdk.Types.Tool name
  | _ :: _ ->
    (* Use the provider-level "some tool is required" contract here, even
       for a single explicit required tool. Runtime MCP transports may return
       names such as [mcp__masc__keeper_shell]; OAS exact-tool contracts
       compare raw names before MASC can canonicalize them, so exact Tool(name)
       can reject a correct call. MASC still validates the specific required
       names after execution via [outstanding_required_tool_names]. *)
    Agent_sdk.Types.Any
  | [] -> Agent_sdk.Types.Auto
