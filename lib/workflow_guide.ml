(** Workflow Guidance — encodes front-door and auxiliary sequences.

    1. Namespace/Task Hygiene (default front door)
    2. Managed Operations (experimental/compatibility lane)
    3. Supervised Execution / Supervisor (delivery lane)

    @since 2.89.0 *)

type step =
  { tool : string
  ; reason : string
  }

type guidance =
  { next_steps : step list
  ; preconditions : string list
  ; common_mistakes : string list
  }

let empty = { next_steps = []; preconditions = []; common_mistakes = [] }

(* ── helpers ─────────────────────────────────────────────────────── *)

let s tool reason = { tool; reason }
let project_ready = "project_ready"

let transition_action args =
  let open Yojson.Safe.Util in
  match args |> member "action" |> to_string_option with
  | Some action -> Some (String.lowercase_ascii (String.trim action))
  | None -> None
;;

let guidance_tool_name name =
  match name with
  | "masc_set_current_task" | "masc_room_status" | "masc_list_tasks" ->
    Tool_catalog.canonical_tool_name name
  | _ -> name
;;

(* ── Golden Path 1: Namespace/Task Hygiene ──────────────────────── *)

let after_start ~success =
  if success
  then
    { next_steps =
        [ s "masc_worktree_create" "Create an isolated worktree for this task"
        ; s "masc_heartbeat" "Signal liveness before starting work"
        ]
    ; preconditions = []
    ; common_mistakes =
        [ "Forgetting masc_worktree_create — working on main branch directly" ]
    }
  else
    { next_steps =
        [ s "masc_start" "Retry masc_start with the correct path if the path was wrong" ]
    ; preconditions = []
    ; common_mistakes = []
    }
;;

let after_join ~success =
  if success
  then
    { next_steps =
        [ s "masc_status" "Check current namespace state and available tasks"
        ; s "masc_transition" "Claim an existing task if available (action=claim)"
        ; s "masc_add_task" "Create a new task if none exist"
        ]
    ; preconditions = [ project_ready ]
    ; common_mistakes =
        [ "Skipping masc_status — you may duplicate work another agent claimed" ]
    }
  else
    { next_steps = [ s "masc_start" "Set the namespace first" ]
    ; preconditions = []
    ; common_mistakes = []
    }
;;

let after_status ~success =
  if success
  then
    { next_steps =
        [ s "masc_transition" "Claim a task from the available list (action=claim)"
        ; s "masc_add_task" "Add a new task if the list is empty"
        ; s "masc_workflow_guide" "Get personalized guidance for your current state"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
  else
    { next_steps =
        [ s "masc_start" "Ensure namespace is configured"
        ; s "masc_join" "Join the namespace first"
        ]
    ; preconditions = []
    ; common_mistakes = []
    }
;;

let after_claim_auto_bound ~success =
  if success
  then
    { next_steps =
        [ s "masc_worktree_create" "Create an isolated worktree for this task"
        ; s "masc_heartbeat" "Signal liveness before starting long work"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes =
        [ "Forgetting masc_worktree_create — working on main branch directly" ]
    }
  else
    { next_steps =
        [ s "masc_status" "Check which tasks are available"
        ; s "masc_add_task" "Create a task if none exist"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
;;

let after_transition_claim ~success =
  if success
  then
    { next_steps =
        [ s "masc_worktree_create" "Create an isolated worktree for this task"
        ; s "masc_heartbeat" "Signal liveness before starting long work"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes =
        [ "Forgetting masc_worktree_create — working on main branch directly" ]
    }
  else
    { next_steps =
        [ s "masc_status" "Check which tasks are available"
        ; s "masc_add_task" "Create a task if none exist"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
;;

let after_transition_start ~success =
  if success
  then
    { next_steps =
        [ s "masc_heartbeat" "Signal liveness before and during longer work"
        ; s "masc_broadcast" "Share that you started active implementation"
        ; s
            "masc_transition"
            "Mark the task complete when implementation is finished (action=done)"
        ]
    ; preconditions = [ project_ready; "joined"; "task_claimed"; "current_task_set" ]
    ; common_mistakes = []
    }
  else
    { next_steps =
        [ s "masc_status" "Check the task state before retrying the transition"
        ; s "masc_workflow_guide" "Inspect your current namespace/task readiness"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
;;

let after_transition_release_or_cancel ~success =
  if success
  then
    { next_steps =
        [ s
            "masc_status"
            "Check the remaining backlog after releasing or cancelling the task"
        ; s "masc_transition" "Claim another task if work should continue (action=claim)"
        ; s
            "masc_add_task"
            "Create a replacement task only if the cancelled work still needs tracking"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
  else
    { next_steps =
        [ s "masc_status" "Check task state and ownership before retrying"
        ; s "masc_workflow_guide" "Inspect your current namespace/task readiness"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
;;

let after_transition_generic ~success =
  if success
  then
    { next_steps =
        [ s "masc_status" "Refresh namespace state after the transition"
        ; s
            "masc_workflow_guide"
            "Inspect the next recommended step for your current state"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes =
        [ "masc_transition follow-up depends on action. claim should auto-bind \
           current_task, while done/release/cancel may clear it."
        ]
    }
  else
    { next_steps =
        [ s "masc_status" "Check task state before retrying the transition"
        ; s "masc_workflow_guide" "Inspect your current namespace/task readiness"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
;;

let after_add_task ~success =
  if success
  then
    { next_steps =
        [ s "masc_transition" "Claim the task you just created (action=claim)"
        ; s "masc_status" "Verify the task appears in the list"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes =
        [ "Creating a task without claiming it — another agent may take it" ]
    }
  else
    { next_steps = [ s "masc_status" "Check namespace state for errors" ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
;;

let after_plan_set_task ~success =
  if success
  then
    { next_steps =
        [ s "masc_worktree_create" "Create worktree for isolated work"
        ; s "masc_heartbeat" "Signal liveness before starting long work"
        ]
    ; preconditions = [ project_ready; "joined"; "task_claimed" ]
    ; common_mistakes = []
    }
  else
    { next_steps =
        [ s "masc_transition" "Claim a task first (action=claim)"
        ; s "masc_status" "Verify your claimed task exists"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = [ "Calling plan_set_task without a claimed task" ]
    }
;;

let after_heartbeat ~success =
  if success
  then
    { next_steps =
        [ s "masc_broadcast" "Share progress with other agents"
        ; s "masc_transition" "Mark task complete when finished (action=done)"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
  else
    { next_steps = [ s "masc_join" "Rejoin if session expired" ]
    ; preconditions = []
    ; common_mistakes = []
    }
;;

let after_done ~success =
  if success
  then
    { next_steps =
        [ s "masc_status" "Check for remaining tasks"
        ; s "masc_transition" "Pick up the next task (action=claim)"
        ; s "masc_leave" "Leave the namespace if all work is complete"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
  else
    { next_steps = [ s "masc_status" "Check task state — it may already be completed" ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
;;

(* ── Common tools ────────────────────────────────────────────────── *)

let after_broadcast ~success =
  if success
  then
    { next_steps = [ s "masc_heartbeat" "Keep your presence alive" ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes = []
    }
  else
    { next_steps = [ s "masc_join" "Ensure you are in the namespace" ]
    ; preconditions = [ project_ready ]
    ; common_mistakes = []
    }
;;

let after_worktree_create ~success =
  if success
  then
    { next_steps =
        [ s "masc_heartbeat" "Signal liveness before starting work"
        ; s "masc_broadcast" "Let other agents know you started work"
        ]
    ; preconditions = [ project_ready; "joined"; "task_claimed" ]
    ; common_mistakes = []
    }
  else
    { next_steps =
        [ s "masc_plan_set_task" "Ensure current_task is set"
        ; s "masc_status" "Check namespace configuration"
        ]
    ; preconditions = [ project_ready; "joined"; "task_claimed" ]
    ; common_mistakes = []
    }
;;

(* ── Main dispatch ───────────────────────────────────────────────── *)

let next_steps ~tool_name ~success =
  let tool_name = guidance_tool_name tool_name in
  match tool_name with
  (* Front Door: Namespace/Task Hygiene *)
  | "masc_start" -> after_start ~success
  | "masc_join" -> after_join ~success
  | "masc_status" -> after_status ~success
  | "masc_claim_next" -> after_claim_auto_bound ~success
  | "masc_add_task" | "masc_batch_add_tasks" -> after_add_task ~success
  | "masc_plan_set_task" -> after_plan_set_task ~success
  | "masc_heartbeat" -> after_heartbeat ~success
  | "masc_transition" -> after_transition_generic ~success
  (* Common *)
  | "masc_broadcast" -> after_broadcast ~success
  | "masc_worktree_create" -> after_worktree_create ~success
  (* No guidance registered *)
  | _ -> empty
;;

let next_steps_for_call ~tool_name ~args ~success =
  match guidance_tool_name tool_name with
  | "masc_transition" ->
    (match transition_action args with
     | Some "claim" -> after_transition_claim ~success
     | Some "start" -> after_transition_start ~success
     | Some "done" -> after_done ~success
     | Some ("release" | "cancel") -> after_transition_release_or_cancel ~success
     | _ -> after_transition_generic ~success)
  | _ -> next_steps ~tool_name ~success
;;

(* ── JSON serialisation ──────────────────────────────────────────── *)

let step_to_json { tool; reason } =
  `Assoc [ "tool", `String tool; "reason", `String reason ]
;;

let guidance_to_json g =
  match g.next_steps with
  | [] -> `Null
  | steps ->
    let fields = [ "next_steps", `List (List.map step_to_json steps) ] in
    let fields =
      match g.preconditions with
      | [] -> fields
      | ps -> fields @ [ "preconditions", `List (List.map (fun p -> `String p) ps) ]
    in
    let fields =
      match g.common_mistakes with
      | [] -> fields
      | ms -> fields @ [ "common_mistakes", `List (List.map (fun m -> `String m) ms) ]
    in
    `Assoc fields
;;

(* ── Workflow context for tool help ──────────────────────────────── *)

(** Returns (before_tools, after_tools, common_mistakes) for a given tool.
    Used by tool_help_registry to enrich help responses. *)
let workflow_context ~tool_name =
  let tool_name = guidance_tool_name tool_name in
  let before =
    match tool_name with
    | "masc_join" -> [ "masc_start" ]
    | "masc_status" -> [ "masc_start"; "masc_join" ]
    | "masc_claim_next" -> [ "masc_join"; "masc_status" ]
    | "masc_plan_set_task" -> [ "masc_transition" ]
    | "masc_worktree_create" -> [ "masc_plan_set_task" ]
    | "masc_heartbeat" -> [ "masc_join" ]
    | "masc_transition" -> [ "masc_join"; "masc_status" ]
    | _ -> []
  in
  let after_g = next_steps ~tool_name ~success:true in
  let after = List.map (fun s -> s.tool) after_g.next_steps in
  let mistakes = after_g.common_mistakes in
  match before, after, mistakes with
  | [], [], [] -> None
  | _ -> Some (before, after, mistakes)
;;

(* ── State-based guidance (for masc_workflow_guide tool) ──────────── *)

let current_state_guidance
      ~room_set
      ~joined
      ~task_claimed
      ~current_task_set
      ~worktree_active
      ~session_active
  =
  if not room_set
  then
    { next_steps =
        [ s
            "masc_start"
            "Set the project coordination root and join the default namespace"
        ]
    ; preconditions = []
    ; common_mistakes =
        [ "Calling coordination tools before project scope is initialized" ]
    }
  else if not joined
  then
    { next_steps =
        [ s "masc_join" "Register your agent identity in the project namespace" ]
    ; preconditions = [ project_ready ]
    ; common_mistakes =
        [ "Operating without joining — other agents cannot see or coordinate with you" ]
    }
  else if not task_claimed
  then
    { next_steps =
        [ s "masc_status" "Check available tasks"
        ; s "masc_transition" "Claim an existing task (action=claim)"
        ; s "masc_add_task" "Create a new task if none exist"
        ]
    ; preconditions = [ project_ready; "joined" ]
    ; common_mistakes =
        [ "Modifying code without a claimed task — changes are untracked" ]
    }
  else if not current_task_set
  then
    { next_steps = [ s "masc_plan_set_task" "Bind your claimed task as current_task" ]
    ; preconditions = [ project_ready; "joined"; "task_claimed" ]
    ; common_mistakes =
        [ "Legacy or out-of-band claim paths can leave planning current_task stale. Call \
           masc_plan_set_task to realign."
        ]
    }
  else if not worktree_active
  then
    { next_steps =
        [ s "masc_worktree_create" "Create an isolated git worktree for this task"
        ; s "masc_heartbeat" "Signal liveness if worktree is not needed"
        ]
    ; preconditions = [ project_ready; "joined"; "task_claimed"; "current_task_set" ]
    ; common_mistakes = [ "Working directly on main branch without a worktree" ]
    }
  else if session_active
  then
    { next_steps =
        [ s "masc_status" "Refresh repo coordination state"
        ; s "masc_heartbeat" "Keep your presence alive during work"
        ; s "masc_transition" "Mark the task complete when work is done (action=done)"
        ]
    ; preconditions =
        [ project_ready
        ; "joined"
        ; "task_claimed"
        ; "current_task_set"
        ; "worktree_active"
        ; "session_active"
        ]
    ; common_mistakes = []
    }
  else
    { next_steps =
        [ s "masc_heartbeat" "Signal liveness while working"
        ; s "masc_broadcast" "Share progress with teammates"
        ; s "masc_transition" "Mark task complete when finished (action=done)"
        ]
    ; preconditions =
        [ project_ready; "joined"; "task_claimed"; "current_task_set"; "worktree_active" ]
    ; common_mistakes = []
    }
;;
