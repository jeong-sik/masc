(** Workflow Guidance — encodes Golden Path sequences.

    Three canonical paths are encoded:
    1. Room/Task Hygiene (prerequisite for all work)
    2. CPv2 Direct (benchmark / swarm)
    3. Team Session / Supervisor

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

(* ── Golden Path 1: Room/Task Hygiene ────────────────────────────── *)

let after_set_room ~success =
  if success then
    { next_steps =
        [ s "masc_join" "Register your agent identity in the room";
          s "masc_status" "Verify room state before proceeding" ];
      preconditions = [];
      common_mistakes =
        [ "Starting work without masc_join — other agents cannot see you" ] }
  else
    { next_steps =
        [ s "masc_init" "Initialize MASC if not yet set up";
          s "masc_rooms_list" "Check available rooms" ];
      preconditions = [];
      common_mistakes = [] }

let after_join ~success =
  if success then
    { next_steps =
        [ s "masc_status" "Check current room state and available tasks";
          s "masc_transition" "Claim an existing task if available (action=claim)";
          s "masc_add_task" "Create a new task if none exist" ];
      preconditions = [ "room_set" ];
      common_mistakes =
        [ "Skipping masc_status — you may duplicate work another agent claimed" ] }
  else
    { next_steps =
        [ s "masc_set_room" "Set the room first";
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
        [ s "masc_set_room" "Ensure room is configured";
          s "masc_join" "Join the room first" ];
      preconditions = [];
      common_mistakes = [] }

let after_claim ~success =
  if success then
    { next_steps =
        [ s "masc_plan_set_task" "Bind claimed task as your current_task — required before work";
          s "masc_worktree_create" "Create an isolated worktree for this task" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes =
        [ "Starting work without masc_plan_set_task — current_task will be unset";
          "Forgetting masc_worktree_create — working on main branch directly" ] }
  else
    { next_steps =
        [ s "masc_status" "Check which tasks are available";
          s "masc_add_task" "Create a task if none exist" ];
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
        [ s "masc_status" "Check room state for errors" ];
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
          s "masc_leave" "Leave room if all work is complete" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_status" "Check task state — it may already be completed" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

(* ── Golden Path 2: CPv2 Direct ──────────────────────────────────── *)

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
          s "masc_status" "Check room prerequisites" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

let after_dispatch_tick ~success =
  if success then
    { next_steps =
        [ s "masc_detachment_list" "Check materialized detachments";
          s "masc_observe_operations" "Monitor operation progress";
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
        [ s "masc_join" "Ensure you have joined the room";
          s "masc_status" "Check room state" ];
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
        [ s "masc_join" "Ensure you are in the room" ];
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
          s "masc_status" "Check room configuration" ];
      preconditions = [ "room_set"; "joined"; "task_claimed" ];
      common_mistakes = [] }

let after_init ~success =
  if success then
    { next_steps =
        [ s "masc_set_room" "Set the room to your project root";
          s "masc_join" "Join the room" ];
      preconditions = [];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_status" "Check if MASC is already initialized" ];
      preconditions = [];
      common_mistakes = [] }

let after_switch_mode ~success =
  if success then
    { next_steps =
        [ s "masc_status" "Verify the new mode is active" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }
  else
    { next_steps =
        [ s "masc_tool_help" "Check available modes" ];
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
          s "masc_status" "Check basic room state" ];
      preconditions = [ "room_set"; "joined" ];
      common_mistakes = [] }

(* ── Main dispatch ───────────────────────────────────────────────── *)

let next_steps ~tool_name ~success =
  match tool_name with
  (* Golden Path 1: Room/Task Hygiene *)
  | "masc_set_room" -> after_set_room ~success
  | "masc_join" -> after_join ~success
  | "masc_status" -> after_status ~success
  | "masc_claim" | "masc_claim_next" | "masc_claim_task" -> after_claim ~success
  | "masc_add_task" | "masc_batch_add_tasks" -> after_add_task ~success
  | "masc_plan_set_task" | "masc_set_current_task" -> after_plan_set_task ~success
  | "masc_heartbeat" -> after_heartbeat ~success
  | "masc_done" | "masc_complete_task" -> after_done ~success
  (* Golden Path 2: CPv2 *)
  | "masc_operation_start" -> after_operation_start ~success
  | "masc_dispatch_tick" -> after_dispatch_tick ~success
  (* Golden Path 3: Team Session *)
  | "masc_team_session_start" -> after_team_session_start ~success
  | "masc_team_session_step" -> after_team_session_step ~success
  | "masc_team_session_prove" -> after_team_session_prove ~success
  (* Common *)
  | "masc_broadcast" -> after_broadcast ~success
  | "masc_worktree_create" -> after_worktree_create ~success
  | "masc_init" -> after_init ~success
  | "masc_switch_mode" -> after_switch_mode ~success
  | "masc_operator_digest" -> after_operator_digest ~success
  (* No guidance registered *)
  | _ -> empty

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
  let before = match tool_name with
    | "masc_join" -> [ "masc_set_room" ]
    | "masc_status" -> [ "masc_set_room"; "masc_join" ]
    | "masc_claim" | "masc_claim_next" | "masc_claim_task" ->
        [ "masc_join"; "masc_status" ]
    | "masc_plan_set_task" | "masc_set_current_task" ->
        [ "masc_claim" ]
    | "masc_worktree_create" ->
        [ "masc_plan_set_task" ]
    | "masc_heartbeat" ->
        [ "masc_join" ]
    | "masc_done" | "masc_complete_task" ->
        [ "masc_plan_set_task" ]
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
        [ s "masc_set_room" "Set the room to your project root (repo root)";
          s "masc_init" "Initialize MASC if this is a fresh setup" ];
      preconditions = [];
      common_mistakes =
        [ "Calling any MASC tool without setting a room first" ] }
  else if not joined then
    { next_steps =
        [ s "masc_join" "Register your agent identity in the room" ];
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
        [ "masc_claim alone does not set current_task — you must call masc_plan_set_task" ] }
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
