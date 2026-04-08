(** Workflow Guidance — encodes front-door and auxiliary sequences.

    1. Namespace/Task Hygiene (default front door)
    2. Managed Operations (experimental/compatibility lane)
    3. Team Session / Supervisor (delivery lane)

    @since 2.89.0 *)

type step = {
  tool : string;
  reason : string;
}

type guidance = {
  next_steps : step list;
  preconditions : string list;
  common_mistakes : string list;
}

let empty = { next_steps = []; preconditions = []; common_mistakes = [] }

(* ── helpers ─────────────────────────────────────────────────────── *)

let s tool reason = { tool; reason }

let transition_action args =
  let open Yojson.Safe.Util in
  match args |> member "action" |> to_string_option with
  | Some action -> Some (String.lowercase_ascii (String.trim action))
  | None -> None

let guidance_tool_name name =
  match name with
  | "masc_set_current_task"
  | "masc_room_status"
  | "masc_list_tasks" -> Tool_catalog.canonical_tool_name name
  | _ -> name

(* ── Golden Path 1: Namespace/Task Hygiene ──────────────────────── *)

let after_start ~success =
  if success then
    { next_steps =
        [ s "masc_worktree_create" "Create an isolated worktree for this task";
          s "masc_heartbeat" "Signal liveness before starting work" ];
      preconditions = [];
      common_mistakes =
        [ "Forgetting masc_worktree_create — working on main branch directly" ] }
  else
    { next_steps =
        [ s "masc_start" "Retry masc_start with the correct path if the path was wrong";
          s "masc_init" "Initialize MASC if not yet set up" ];
      preconditions = [];
      common_mistakes = [] }

let after_set_room ~success =
  if success then
    { next_steps =
        [ s "masc_join" "Compatibility path: register your agent identity in the project namespace";
          s "masc_status" "Verify namespace state before proceeding";
          s "masc_start" "Prefer masc_start for future one-step namespace onboarding" ];
      preconditions = [];
      common_mistakes =
        [ "Treating masc_set_room like full onboarding — it only selects the project coordination root";
          "Starting work without masc_join — other agents cannot see you" ] }
  else
    { next_steps =
        [ s "masc_start" "Retry with the repo root path if you want the truthful one-shot onboarding flow";
          s "masc_init" "Initialize MASC if not yet set up" ];
      preconditions = [];
      common_mistakes = [] }

let after_join ~success =
  if success then
    { next_steps =
        [ s "masc_status" "Check current namespace state and available tasks";
          s "masc_transition" "Claim an existing task if available (action=claim)";
          s "masc_add_task" "Create a new task if none exist" ];
      preconditions = [ "room_set" ];
      common_mistakes =
        [ "Skipping masc_status — you may duplicate work another agent claimed" ] }
  else
    { next_steps =
        [ s "masc_start" "Set the namespace first";
          s "masc_init" "Initialize MASC if not set up" ];
      preconditions = [];
      common_mistakes = [] }

let after_status ~success =
  if success then
    { next_steps =
        [ s "masc_transition" "Claim a task from the available list (action=claim)";
          s "masc_add_task" "Add a new task if the list is empty";
          s "masc_workflow_guide" "Get personalized guidance for your current state" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_start" "Ensure namespace is configured";
          s "masc_join" "Join the namespace first" ];
      preconditions = [];
      common_mistakes = [] }

let after_claim_auto_bound ~success =
  if success then
    { next_steps =
        [ s "masc_worktree_create" "Create an isolated worktree for this task";
          s "masc_heartbeat" "Signal liveness before starting long work" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes =
        [ "Forgetting masc_worktree_create — working on main branch directly" ] }
  else
    { next_steps =
        [ s "masc_status" "Check which tasks are available";
          s "masc_add_task" "Create a task if none exist" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

let after_transition_claim ~success =
  if success then
    { next_steps =
        [ s "masc_plan_set_task" "Bind claimed task as your planning current_task";
          s "masc_worktree_create" "Create an isolated worktree for this task" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes =
        [ "masc_transition(action=claim) only claims backlog ownership — it does not bind planning current_task";
          "Forgetting masc_worktree_create — working on main branch directly" ] }
  else
    { next_steps =
        [ s "masc_status" "Check which tasks are available";
          s "masc_add_task" "Create a task if none exist" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

let after_transition_start ~success =
  if success then
    { next_steps =
        [ s "masc_heartbeat" "Signal liveness before and during longer work";
          s "masc_broadcast" "Share that you started active implementation";
          s "masc_transition" "Mark the task complete when implementation is finished (action=done)" ];
      preconditions = [ "room_set"; "joined"; "task_claimed"; "current_task_set" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_status" "Check the task state before retrying the transition";
          s "masc_workflow_guide" "Inspect your current namespace/task readiness" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

let after_transition_release_or_cancel ~success =
  if success then
    { next_steps =
        [ s "masc_status" "Check the remaining backlog after releasing or cancelling the task";
          s "masc_transition" "Claim another task if work should continue (action=claim)";
          s "masc_add_task" "Create a replacement task only if the cancelled work still needs tracking" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_status" "Check task state and ownership before retrying";
          s "masc_workflow_guide" "Inspect your current namespace/task readiness" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

let after_transition_generic ~success =
  if success then
    { next_steps =
        [ s "masc_status" "Refresh namespace state after the transition";
          s "masc_workflow_guide" "Inspect the next recommended step for your current state" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes =
        [ "masc_transition follow-up depends on action. claim may require masc_plan_set_task, while done/release/cancel do not." ] }
  else
    { next_steps =
        [ s "masc_status" "Check task state before retrying the transition";
          s "masc_workflow_guide" "Inspect your current namespace/task readiness" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

let after_add_task ~success =
  if success then
    { next_steps =
        [ s "masc_transition" "Claim the task you just created (action=claim)";
          s "masc_status" "Verify the task appears in the list" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes =
        [ "Creating a task without claiming it — another agent may take it" ] }
  else
    { next_steps =
        [ s "masc_status" "Check namespace state for errors" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

let after_plan_set_task ~success =
  if success then
    { next_steps =
        [ s "masc_worktree_create" "Create worktree for isolated work";
          s "masc_heartbeat" "Signal liveness before starting long work" ];
      preconditions = [ "room_set"; "joined"; "task_claimed" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_transition" "Claim a task first (action=claim)";
          s "masc_status" "Verify your claimed task exists" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes =
        [ "Calling plan_set_task without a claimed task" ] }

let after_heartbeat ~success =
  if success then
    { next_steps =
        [ s "masc_broadcast" "Share progress with other agents";
          s "masc_transition" "Mark task complete when finished (action=done)" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_join" "Rejoin if session expired" ];
      preconditions = [];
      common_mistakes = [] }

let after_done ~success =
  if success then
    { next_steps =
        [ s "masc_status" "Check for remaining tasks";
          s "masc_transition" "Pick up the next task (action=claim)";
          s "masc_leave" "Leave the namespace if all work is complete" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_status" "Check task state — it may already be completed" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

(* ── Auxiliary Lane: Managed Operations ──────────────────────────── *)

let after_operation_start ~success =
  if success then
    { next_steps =
        [ s "masc_dispatch_tick" "Trigger the scheduler to advance the operation";
          s "masc_observe_topology" "View the operation topology" ];
      preconditions = [ "room_set"; "joined"; "unit_defined" ];
      common_mistakes =
        [ "Forgetting masc_dispatch_tick — the operation will not advance" ] }
  else
    { next_steps =
        [ s "masc_unit_define" "Define organizational unit first";
          s "masc_status" "Check namespace prerequisites" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

let after_dispatch_tick ~success =
  if success then
    { next_steps =
        [ s "masc_observe_operations" "Monitor operation progress";
          s "masc_policy_status" "Review pending policy approvals" ];
      preconditions = [ "room_set"; "joined"; "operation_active" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_operation_start" "Ensure an operation is active" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

(* ── Golden Path 3: Team Session / Supervisor ────────────────────── *)

let after_team_session_start ~success =
  if success then
    { next_steps =
        [ s "masc_team_session_step" "Record the first session turn";
          s "masc_team_session_status" "View session state" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes =
        [ "Not recording turns — the session has no audit trail" ] }
  else
    { next_steps =
        [ s "masc_join" "Ensure you have joined the namespace";
          s "masc_status" "Check namespace state" ];
      preconditions = [ "room_set" ];
      common_mistakes = [] }

let after_team_session_step ~success =
  if success then
    { next_steps =
        [ s "masc_team_session_step" "Record the next turn or spawn workers";
          s "masc_team_session_status" "Review session progress";
          s "masc_team_session_prove" "Generate collaboration evidence when ready" ];
      preconditions = [ "room_set"; "joined"; "session_active" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_team_session_status" "Check session state for errors" ];
      preconditions = [ "room_set"; "joined"; "session_active" ];
      common_mistakes = [] }

let after_team_session_prove ~success =
  if success then
    { next_steps =
        [ s "masc_team_session_stop" "End the session after evidence is collected";
          s "masc_transition" "Mark the underlying task as complete (action=done)" ];
      preconditions = [ "room_set"; "joined"; "session_active" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_team_session_step" "Record more evidence before proving";
          s "masc_team_session_status" "Check what evidence is missing" ];
      preconditions = [ "room_set"; "joined"; "session_active" ];
      common_mistakes = [] }

(* ── Common tools ────────────────────────────────────────────────── *)

let after_broadcast ~success =
  if success then
    { next_steps =
        [ s "masc_heartbeat" "Keep your presence alive" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_join" "Ensure you are in the namespace" ];
      preconditions = [ "room_set" ];
      common_mistakes = [] }

let after_worktree_create ~success =
  if success then
    { next_steps =
        [ s "masc_heartbeat" "Signal liveness before starting work";
          s "masc_broadcast" "Let other agents know you started work" ];
      preconditions = [ "room_set"; "joined"; "task_claimed" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_plan_set_task" "Ensure current_task is set";
          s "masc_status" "Check namespace configuration" ];
      preconditions = [ "room_set"; "joined"; "task_claimed" ];
      common_mistakes = [] }

let after_init ~success =
  if success then
    { next_steps =
        [ s "masc_start" "Set the namespace to your project root and join it" ];
      preconditions = [];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_status" "Check if MASC is already initialized" ];
      preconditions = [];
      common_mistakes = [] }

let after_operator_digest ~success =
  if success then
    { next_steps =
        [ s "masc_operator_action" "Execute a suggested action from the digest";
          s "masc_team_session_status" "Drill into a specific session" ];
      preconditions = [ "room_set"; "joined"; "session_active" ];
      common_mistakes =
        [ "Reading the digest without acting on critical items" ] }
  else
    { next_steps =
        [ s "masc_operator_snapshot" "Get raw state instead";
          s "masc_status" "Check basic namespace state" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

(* ── Main dispatch ───────────────────────────────────────────────── *)

let next_steps ~tool_name ~success =
  let tool_name = guidance_tool_name tool_name in
  match tool_name with
  (* Front Door: Namespace/Task Hygiene *)
  | "masc_start" -> after_start ~success
  | "masc_set_room" -> after_set_room ~success
  | "masc_join" -> after_join ~success
  | "masc_status" -> after_status ~success
  | "masc_claim_next" -> after_claim_auto_bound ~success
  | "masc_add_task" | "masc_batch_add_tasks" -> after_add_task ~success
  | "masc_plan_set_task" -> after_plan_set_task ~success
  | "masc_heartbeat" -> after_heartbeat ~success
  | "masc_done" -> after_done ~success
  | "masc_transition" -> after_transition_generic ~success
  (* Auxiliary Lane: Managed Operations *)
  | "masc_operation_start" -> after_operation_start ~success
  | "masc_dispatch_tick" -> after_dispatch_tick ~success
  (* Delivery Lane: Team Session *)
  | "masc_team_session_start" -> after_team_session_start ~success
  | "masc_team_session_step" -> after_team_session_step ~success
  | "masc_team_session_prove" -> after_team_session_prove ~success
  (* Common *)
  | "masc_broadcast" -> after_broadcast ~success
  | "masc_worktree_create" -> after_worktree_create ~success
  | "masc_init" -> after_init ~success
  | "masc_operator_digest" -> after_operator_digest ~success
  (* No guidance registered *)
  | _ -> empty

let next_steps_for_call ~tool_name ~args ~success =
  match guidance_tool_name tool_name with
  | "masc_transition" -> (
      match transition_action args with
      | Some "claim" -> after_transition_claim ~success
      | Some "start" -> after_transition_start ~success
      | Some "done" -> after_done ~success
      | Some ("release" | "cancel") -> after_transition_release_or_cancel ~success
      | _ -> after_transition_generic ~success)
  | _ -> next_steps ~tool_name ~success

(* ── JSON serialisation ──────────────────────────────────────────── *)

let step_to_json { tool; reason } =
  `Assoc [ ("tool", `String tool); ("reason", `String reason) ]

let guidance_to_json g =
  match g.next_steps with
  | [] -> `Null
  | steps ->
      let fields =
        [ ("next_steps", `List (List.map step_to_json steps)) ]
      in
      let fields =
        match g.preconditions with
        | [] -> fields
        | ps -> fields @ [ ("preconditions", `List (List.map (fun p -> `String p) ps)) ]
      in
      let fields =
        match g.common_mistakes with
        | [] -> fields
        | ms -> fields @ [ ("common_mistakes", `List (List.map (fun m -> `String m) ms)) ]
      in
      `Assoc fields

(* ── Workflow context for tool help ──────────────────────────────── *)

(** Returns (before_tools, after_tools, common_mistakes) for a given tool.
    Used by tool_help_registry to enrich help responses. *)
let workflow_context ~tool_name =
  let tool_name = guidance_tool_name tool_name in
  let before = match tool_name with
    | "masc_join" -> [ "masc_start" ]
    | "masc_status" -> [ "masc_start"; "masc_join" ]
    | "masc_claim_next" ->
        [ "masc_join"; "masc_status" ]
    | "masc_plan_set_task" ->
        [ "masc_transition" ]
    | "masc_worktree_create" ->
        [ "masc_plan_set_task" ]
    | "masc_heartbeat" ->
        [ "masc_join" ]
    | "masc_done" ->
        [ "masc_plan_set_task" ]
    | "masc_transition" ->
        [ "masc_join"; "masc_status" ]
    | "masc_operation_start" ->
        [ "masc_unit_define" ]
    | "masc_dispatch_tick" ->
        [ "masc_operation_start" ]
    | "masc_team_session_start" ->
        [ "masc_join" ]
    | "masc_team_session_step" ->
        [ "masc_team_session_start" ]
    | "masc_team_session_prove" ->
        [ "masc_team_session_step" ]
    | "masc_team_session_stop" ->
        [ "masc_team_session_prove" ]
    | "masc_operator_digest" ->
        [ "masc_team_session_start" ]
    | _ -> []
  in
  let after_g = next_steps ~tool_name ~success:true in
  let after = List.map (fun s -> s.tool) after_g.next_steps in
  let mistakes = after_g.common_mistakes in
  match before, after, mistakes with
  | [], [], [] -> None
  | _ -> Some (before, after, mistakes)

(* ── State-based guidance (for masc_workflow_guide tool) ──────────── *)

let current_state_guidance ~room_set ~joined ~task_claimed
    ~current_task_set ~worktree_active ~session_active =
  if not room_set then
    { next_steps =
        [ s "masc_start" "Set the project coordination root and join the default namespace";
          s "masc_init" "Initialize MASC if this is a fresh setup" ];
      preconditions = [];
      common_mistakes =
        [ "Calling coordination tools before project scope is initialized" ] }
  else if not joined then
    { next_steps =
        [ s "masc_join" "Register your agent identity in the project namespace" ];
      preconditions = [ "room_set" ];
      common_mistakes =
        [ "Operating without joining — other agents cannot see or coordinate with you" ] }
  else if not task_claimed then
    { next_steps =
        [ s "masc_status" "Check available tasks";
          s "masc_transition" "Claim an existing task (action=claim)";
          s "masc_add_task" "Create a new task if none exist" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes =
        [ "Modifying code without a claimed task — changes are untracked" ] }
  else if not current_task_set then
    { next_steps =
        [ s "masc_plan_set_task" "Bind your claimed task as current_task" ];
      preconditions = [ "room_set"; "joined"; "task_claimed" ];
      common_mistakes =
        [ "Some claim paths leave planning current_task unset. This commonly happens after masc_transition(action=claim)." ] }
  else if not worktree_active then
    { next_steps =
        [ s "masc_worktree_create" "Create an isolated git worktree for this task";
          s "masc_heartbeat" "Signal liveness if worktree is not needed" ];
      preconditions = [ "room_set"; "joined"; "task_claimed"; "current_task_set" ];
      common_mistakes =
        [ "Working directly on main branch without a worktree" ] }
  else if session_active then
    { next_steps =
        [ s "masc_team_session_step" "Record the next turn in your session";
          s "masc_team_session_status" "Check session progress";
          s "masc_heartbeat" "Keep your presence alive during work" ];
      preconditions = [ "room_set"; "joined"; "task_claimed"; "current_task_set"; "worktree_active"; "session_active" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_heartbeat" "Signal liveness while working";
          s "masc_broadcast" "Share progress with teammates";
          s "masc_transition" "Mark task complete when finished (action=done)" ];
      preconditions = [ "room_set"; "joined"; "task_claimed"; "current_task_set"; "worktree_active" ];
      common_mistakes = [] }
