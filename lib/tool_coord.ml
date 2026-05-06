module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_coord - Coord management operations
    Handles: status, reset, init, workflow_guide, check
    Note: join, leave, set_room, who require state/registry and remain in mcp_server_eio.ml
*)

open Coord_types

open Tool_args

type tool_result = Coord_types.tool_result

type context = Coord_types.context = {
  config : Coord.config;
  agent_name : string;
}

type assertion_kind = Coord_assertions.assertion_kind =
  | Room_set
  | Joined
  | Task_claimed
  | Current_task_set
  | Worktree_active

let assertion_kind_to_string = Coord_assertions.assertion_kind_to_string
let all_assertion_kinds = Coord_assertions.all_assertion_kinds
let valid_assertion_strings = Coord_assertions.valid_assertion_strings
let assertion_kind_of_string_lenient =
  Coord_assertions.assertion_kind_of_string_lenient

let take_items limit items =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> loop (remaining - 1) (x :: acc) xs
  in
  loop limit [] items

type text_cache = {
  mutable key : string option;
  mutable value : string option;
  mutable expires_at : float;
}

let make_text_cache () = { key = None; value = None; expires_at = 0.0 }

let _status_cache = make_text_cache ()

let cache_ttl_seconds env_var ~default =
  match Sys.getenv_opt env_var with
  | Some raw -> (
      match Float.of_string_opt (String.trim raw) with
      | Some value when Stdlib.Float.compare value 0.0 >= 0 -> value
      | _ -> default)
  | None -> default

let status_cache_ttl_s () = 2.0

let invalidate_status_cache () =
  _status_cache.key <- None;
  _status_cache.value <- None;
  _status_cache.expires_at <- 0.0

let cached_text_by_key cache ~key ~ttl_s compute =
  let now = Time_compat.now () in
  match cache.key, cache.value with
  | Some cached_key, Some value
    when String.equal cached_key key && Stdlib.Float.compare now cache.expires_at < 0 ->
      value
  | _ ->
      let value = compute () in
      cache.key <- Some key;
      cache.value <- Some value;
      cache.expires_at <- now +. ttl_s;
      value

let effective_cluster_name (config : Coord.config) =
  match String.trim config.backend_config.Backend_types.cluster_name with
  | "" -> Env_config_core.cluster_name ()
  | name -> name

(* Handlers *)

let lifecycle_tools =
  [
    "masc_claim_next";
    "masc_transition";
  ]

let is_lifecycle_tool tool =
  List.exists (String.equal tool) lifecycle_tools

let unique_strings items =
  List.fold_left
    (fun acc item ->
      let item = String.trim item in
      if String.equal item "" || List.exists (String.equal item) acc then acc
      else item :: acc)
    [] items
  |> List.rev

let credential_state (ctx : context) ~actual_name =
  let auth_cfg = Auth.load_auth_config ctx.config.base_path in
  let credential_required = auth_cfg.enabled && auth_cfg.require_token in
  let credential_candidates = unique_strings [ ctx.agent_name; actual_name ] in
  let internal_keeper_credential_available name =
    match
      ( Keeper_identity.keeper_name_from_agent_name name,
        Sys.getenv_opt Auth.internal_keeper_token_env_key )
    with
    | Some _, Some raw ->
        let token = String.trim raw in
        not (String.equal token "")
        && Auth.verify_internal_keeper_token ctx.config.base_path ~token
    | _ -> false
  in
  let is_initial_admin name =
    match Auth.read_initial_admin ctx.config.base_path with
    | Some admin -> String.equal name admin
    | None -> false
  in
  let credential_available =
    (not credential_required)
    || List.exists
         (fun name ->
           is_initial_admin name
           || internal_keeper_credential_available name
           (* PR-3b1: ask Auth for the canonical [keeper-<n>-agent]
              form so a configured keeper's credential is never
              resolved through the bare-name redirect stub. Non-keeper
              names pass through unchanged. Spec: AuthIdentityFSM I1. *)
           || Option.is_some
                (Auth.load_credential ctx.config.base_path
                   (Keeper_runtime.canonicalize_if_keeper ctx.config name)))
         credential_candidates
  in
  { credential_required; credential_available; credential_candidates }

let status_worktree_active (ctx : context) =
  let wt_dir = Filename.concat ctx.config.base_path ".worktrees" in
  try
    Sys.file_exists wt_dir && Sys.is_directory wt_dir
    && Array.length (Sys.readdir wt_dir) > 0
  with
  | Sys_error _ -> false
  | exn ->
      Log.Coord.warn "worktree_active check failed: %s" (Stdlib.Printexc.to_string exn);
      false

let safe_resolve_agent_name (ctx : context) ~joined =
  if not joined then
    ctx.agent_name
  else
    try Coord.resolve_agent_name ctx.config ctx.agent_name
    with
    | Sys_error _ | Yojson.Json_error _ -> ctx.agent_name
    | exn ->
        Log.Coord.warn "resolve_agent_name failed for %s: %s" ctx.agent_name
          (Stdlib.Printexc.to_string exn);
        ctx.agent_name

let safe_current_task (ctx : context) ~joined =
  if not joined then
    None
  else
    try Planning_eio.get_current_task ctx.config
    with
    | Sys_error _ | Yojson.Json_error _ -> None
    | exn ->
        Log.Coord.warn "get_current_task failed for %s: %s" ctx.agent_name
        (Stdlib.Printexc.to_string exn);
        None

let safe_get_agents (ctx : context) =
  try Coord.get_agents_raw ctx.config
  with
  | Sys_error _ | Yojson.Json_error _ -> []
  | exn ->
      Log.Coord.warn "get_agents_raw failed: %s" (Stdlib.Printexc.to_string exn);
      []

let safe_read_backlog (ctx : context) =
  try
    Coord.read_backlog ctx.config
  with
  | exn ->
      Log.Coord.warn "read_backlog failed: %s"
        (Stdlib.Printexc.to_string exn);
      {
        Masc_domain.tasks = [];
        last_updated = Masc_domain.now_iso ();
        version = 1;
      }

let safe_is_zombie_agent ~agent_name last_seen =
  try Coord.is_zombie_agent ~agent_name last_seen
  with
  | Sys_error _ | Yojson.Json_error _ -> false
  | exn ->
      Log.Coord.warn "is_zombie_agent failed for %s: %s" agent_name
        (Stdlib.Printexc.to_string exn);
      false

let todo_task_has_completed_deliverable_conflict (ctx : context)
    (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Todo -> (
      match Planning_eio.load ctx.config ~task_id:task.id with
      | Ok plan_ctx ->
          Coord_status_rendering.deliverable_claims_completion
            ~task_id:task.id plan_ctx.deliverable
      | Error _ -> false)
  | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
  | Masc_domain.Done _ | Masc_domain.Cancelled _ -> false

let todo_completed_deliverable_conflicts (ctx : context) tasks =
  List.filter_map
    (fun ((task : Masc_domain.task)) ->
      Coord_query.safe_yield ();
      if todo_task_has_completed_deliverable_conflict ctx task then Some task.id
      else None)
    tasks

let resolve_current_binding ~assigned_task_ids ~planning_current =
  let primary_owned =
    match assigned_task_ids with
    | id :: _ -> Some id
    | [] -> None
  in
  let current_is_assigned =
    match planning_current with
    | Some current ->
        List.exists (fun task_id -> String.equal task_id current)
          assigned_task_ids
    | None -> false
  in
  let drift_reason =
    match primary_owned, planning_current with
    | None, None -> None
    | Some _, None -> None
    | None, Some _ -> Some "no_owned"
    | Some owned, Some current when String.equal owned current -> None
    | Some _, Some _ when current_is_assigned -> Some "secondary_assignment"
    | Some _, Some _ -> Some "stale_focus"
  in
  let effective_current =
    match primary_owned, planning_current with
    | Some owned, Some current when String.equal owned current -> Some current
    | Some _, Some current when current_is_assigned -> Some current
    | Some owned, Some _ -> Some owned
    | Some owned, None -> Some owned
    | None, Some _ | None, None -> None
  in
  let current_task_set =
    match primary_owned, planning_current with
    | Some owned, Some current when String.equal owned current -> true
    | _ -> false
  in
  {
    assigned_task_ids;
    primary_owned;
    planning_current;
    current_is_assigned;
    effective_current;
    drift_reason;
    current_task_set;
    claim_first_suppressed = Stdlib.List.length assigned_task_ids > 0;
  }

let planning_context_state (ctx : context) (binding : current_binding)
    (active_tasks : Masc_domain.task list) =
  match binding.primary_owned with
  | None ->
      { planning_missing_task = None; deliverable_conflict_task = None }
  | Some task_id -> (
      match Planning_eio.load ctx.config ~task_id with
      | Error _ ->
          { planning_missing_task = Some task_id; deliverable_conflict_task = None }
      | Ok plan_ctx ->
          let deliverable_conflict_task =
            match
              List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
                active_tasks
            with
              | Some
                  {
                    task_status = (Masc_domain.Claimed _ | Masc_domain.InProgress _);
                    _;
                  }
              when
                Coord_status_rendering.deliverable_claims_completion ~task_id
                  plan_ctx.deliverable ->
                Some task_id
            | Some _ | None -> None
          in
          { planning_missing_task = None; deliverable_conflict_task })

let coordination_fsm_attention_items ctx =
  try
    let snapshot = Coordination_product_snapshot.build ctx.config in
    let counts = Coordination_product_snapshot.severity_counts snapshot in
    if counts.error = 0 && counts.warn = 0 then
      []
    else
      [
        Printf.sprintf
          "Coordination FSM advisory has %d error(s), %d warning(s). Call masc_coordination_fsm_snapshot before changing goal/task/board/reward state."
          counts.error counts.warn;
      ]
  with
  | exn ->
      Log.Coord.warn "coordination FSM status advisory failed: %s"
        (Stdlib.Printexc.to_string exn);
      []

let status_summary_string (ctx : context) =
  Coord.ensure_initialized ctx.config;
  let state = Coord.read_state ctx.config in
  let backlog = safe_read_backlog ctx in
  let joined =
    try Coord.is_agent_joined ctx.config ~agent_name:ctx.agent_name
    with Sys_error _ | Yojson.Json_error _ -> false
  in
  let actual_name = safe_resolve_agent_name ctx ~joined in
  let credential_state = credential_state ctx ~actual_name in
  let credential_blocked =
    credential_state.credential_required
    && not credential_state.credential_available
  in
  let current_task = safe_current_task ctx ~joined in
  let worktree_active = status_worktree_active ctx in
  let effective_cluster_name = effective_cluster_name ctx.config in
  let active_task_assignees =
    Coord.active_task_assignees_by_task_id backlog
  in
  let agents =
    safe_get_agents ctx
    |> List.map (fun (agent : Masc_domain.agent) ->
           match agent.current_task with
           | Some task_id
             when not
                    (Coord.agent_current_task_matches_assignments
                       active_task_assignees
                       ~agent_name:agent.name task_id) ->
               let status =
                 match agent.status with
                 | Masc_domain.Inactive -> Masc_domain.Inactive
                 | Masc_domain.Active | Masc_domain.Busy | Masc_domain.Listening ->
                     Masc_domain.Active
               in
               { agent with status; current_task = None }
           | Some _ | None -> agent)
    |> List.sort (fun (a : Masc_domain.agent) (b : Masc_domain.agent) ->
           String.compare a.name b.name)
  in
  let agents_with_state =
    List.map
      (fun (agent : Masc_domain.agent) ->
        Coord_query.safe_yield ();
        let is_zombie =
          safe_is_zombie_agent ~agent_name:agent.name agent.last_seen
        in
        (agent, is_zombie))
      agents
  in
  let zombie_count =
    List.fold_left
      (fun acc (_, is_zombie) -> if is_zombie then acc + 1 else acc)
      0 agents_with_state
  in
  let active_tasks, todo_count, claimed_count, in_progress_count, done_count,
      cancelled_count =
    List.fold_left
      (fun
         (active, todo_cnt, claimed_cnt, in_progress_cnt, done_cnt, cancelled_cnt)
         (task : Masc_domain.task) ->
        Coord_query.safe_yield ();
        match task.task_status with
        | Masc_domain.Todo ->
            (task :: active, todo_cnt + 1, claimed_cnt, in_progress_cnt,
             done_cnt, cancelled_cnt)
        | Masc_domain.Claimed _ ->
            (task :: active, todo_cnt, claimed_cnt + 1, in_progress_cnt,
             done_cnt, cancelled_cnt)
        | Masc_domain.InProgress _ ->
            (task :: active, todo_cnt, claimed_cnt, in_progress_cnt + 1,
             done_cnt, cancelled_cnt)
        | Masc_domain.Done _ ->
            (active, todo_cnt, claimed_cnt, in_progress_cnt, done_cnt + 1,
             cancelled_cnt)
        | Masc_domain.AwaitingVerification _ ->
            (task :: active, todo_cnt, claimed_cnt, in_progress_cnt + 1,
             done_cnt, cancelled_cnt)
        | Masc_domain.Cancelled _ ->
            (active, todo_cnt, claimed_cnt, in_progress_cnt, done_cnt,
             cancelled_cnt + 1))
      ([], 0, 0, 0, 0, 0)
      backlog.tasks
  in
  let active_tasks = List.rev active_tasks in
  let todo_conflict_task_ids = todo_completed_deliverable_conflicts ctx active_tasks in
  let todo_conflict_count = List.length todo_conflict_task_ids in
  let fresh_todo_count = max 0 (todo_count - todo_conflict_count) in
  let matches_you assignee =
    String.equal assignee ctx.agent_name || String.equal assignee actual_name
  in
  let assigned_task_ids =
    List.filter_map
      (fun (task : Masc_domain.task) ->
        match Coord_status_rendering.active_task_assignee task.task_status with
        | Some assignee when matches_you assignee -> Some task.id
        | Some _ | None -> None)
      active_tasks
  in
  let binding =
    resolve_current_binding ~assigned_task_ids ~planning_current:current_task
  in
  let planning_state = planning_context_state ctx binding active_tasks in
  let guidance =
    Workflow_guide.current_state_guidance
      ~room_set:true
      ~joined
      ~task_claimed:(Stdlib.List.length binding.assigned_task_ids > 0)
      ~current_task_set:binding.current_task_set
      ~worktree_active ~session_active:false
  in
  let suggested_next =
    if Option.is_some planning_state.planning_missing_task then
      []
    else if Option.is_some planning_state.deliverable_conflict_task then
      [ "masc_deliver"; "masc_status" ]
    else
      guidance.next_steps
      |> List.map (fun (step : Workflow_guide.step) -> step.tool)
      |> fun tools ->
      if credential_blocked then
        List.filter (fun tool -> not (is_lifecycle_tool tool)) tools
      else
        match binding.drift_reason with
        | Some "no_owned" ->
            let tools =
              List.filter (fun tool -> not (String.equal tool "masc_transition"))
                tools
            in
            let tools =
              if fresh_todo_count > 0 then
                "masc_claim_next" :: tools
              else
                tools
            in
            unique_strings tools
        | Some _ | None -> tools
      |> take_items 2
  in
  let attention_items =
    let items = [] in
    let items =
      if not joined then
        items @ [ "You are not joined in the project namespace. Call masc_join." ]
      else
        items
    in
    let items =
      if credential_blocked then
        items
        @ [
            Printf.sprintf
              "Lifecycle actions are credential-blocked for %s. Mount a valid credential before claiming or transitioning tasks."
              (String.concat "/" credential_state.credential_candidates);
          ]
      else
        items
    in
    let items =
      match planning_state.planning_missing_task with
      | Some task_id ->
          items
          @ [
              Printf.sprintf
                "Owned task %s has no planning context. Do not retry generic masc_plan_init from a drifted surface; use handoff/worktree/test logs as the temporary SSOT until a credentialed owner repair receipt exists."
                task_id;
            ]
      | None -> items
    in
    let items =
      match planning_state.deliverable_conflict_task with
      | Some task_id ->
          items
          @ [
              Printf.sprintf
                "Owned task %s already has a completed-looking deliverable while the task is still active. Treat this as conflict triage until board, planning, and control-plane state converge."
                task_id;
            ]
      | None -> items
    in
    let items =
      if Option.is_some binding.primary_owned && not binding.current_task_set then
        items
        @ [
            "You own a task but planning current_task is unset or drifted. \
             Treat owned as canonical and call masc_plan_set_task.";
          ]
      else
        items
    in
    let items =
      match binding.drift_reason with
      | Some "secondary_assignment" ->
          items
          @ [
              "Multiple assigned tasks detected. Current focus is also assigned; choose or reconcile the active lane before claiming new work.";
            ]
      | Some "stale_focus" ->
          items
          @ [
              "Owned/current drift detected. Planning current_task is not assigned to you; treat primary_owned as the safe task lane.";
            ]
      | Some "no_owned" ->
          items
          @ [
              "Planning current_task is set but no active task is assigned to you; clear or rebind current_task before following it.";
            ]
      | Some _ | None -> items
    in
    let items =
      if todo_conflict_count > 0 then
        items
        @ [
            Printf.sprintf
              "%d todo task(s) have completed-looking planning deliverables; treat them as control-plane conflicts, not fresh claimable work."
              todo_conflict_count;
          ]
      else
        items
    in
    let items = items @ coordination_fsm_attention_items ctx in
    let items =
      if zombie_count > 0 then
        items
        @ [
            Printf.sprintf
              "%d stale agent(s) are still visible in the namespace." zombie_count;
          ]
      else
        items
    in
    if fresh_todo_count > 0 && Stdlib.List.length binding.assigned_task_ids = 0 then
      items
      @ [ Printf.sprintf "%d unclaimed task(s) are available right now."
            fresh_todo_count ]
    else
      items
  in
  Coord_status_rendering.status_summary_string
    ~ctx ~joined ~actual_name ~credential_state ~credential_blocked
    ~current_task ~worktree_active ~effective_cluster_name
    ~agents_with_state ~active_tasks ~todo_count ~claimed_count
    ~in_progress_count ~done_count ~cancelled_count
    ~todo_conflict_task_ids ~binding ~planning_state
    ~suggested_next ~attention_items ~state ~backlog

let handle_status ctx _args =
  let cache_key = Printf.sprintf "%s::%s" ctx.config.base_path ctx.agent_name in
  { success = true;
    message = cached_text_by_key _status_cache ~key:cache_key
       ~ttl_s:(status_cache_ttl_s ()) (fun () ->
       status_summary_string ctx) }

let handle_reset ctx args =
  let confirm = get_bool args "confirm" false in
  if not confirm then
    { success = false;
      message = "This will DELETE the entire .masc/ folder!\nCall with confirm=true to proceed." }
  else begin
    invalidate_status_cache ();
    { success = true; message = Coord.reset ctx.config }
  end

(* ── State inspection (shared by workflow_guide and check) ──────── *)

type agent_state = {
  room_set : bool;
  joined : bool;
  task_claimed : bool;
  current_task_set : bool;
  worktree_active : bool;
}

let inspect_state ctx =
  let room_set = Coord.is_initialized ctx.config in
  let joined =
    if room_set then
      (try Coord.is_agent_joined ctx.config ~agent_name:ctx.agent_name
       with Sys_error _ | Yojson.Json_error _ -> false)
    else false
  in
  let binding =
    if joined then
      let actual_name = safe_resolve_agent_name ctx ~joined in
      let matches_you assignee =
        String.equal assignee ctx.agent_name || String.equal assignee actual_name
      in
      let assigned_task_ids =
        Coord.get_tasks_raw ctx.config
        |> Coord_status_rendering.assigned_task_ids ~matches_you
      in
      resolve_current_binding ~assigned_task_ids
        ~planning_current:(safe_current_task ctx ~joined)
    else
      resolve_current_binding ~assigned_task_ids:[] ~planning_current:None
  in
  let task_claimed = Stdlib.List.length binding.assigned_task_ids > 0 in
  let current_task_set = binding.current_task_set in
  let worktree_active =
    if room_set then
      status_worktree_active ctx
    else false
  in
  { room_set; joined; task_claimed; current_task_set; worktree_active }
let state_to_json st =
  `Assoc [
    ("project_ready", `Bool st.room_set);
    ("namespace_ready", `Bool st.room_set);
    ("room_set", `Bool st.room_set);
    ("joined", `Bool st.joined);
    ("task_claimed", `Bool st.task_claimed);
    ("current_task_set", `Bool st.current_task_set);
    ("worktree_active", `Bool st.worktree_active);
    ("session_active", `Bool false);
  ]

(* ── Workflow guide ─────────────────────────────────────────────── *)

let handle_workflow_guide ctx _args =
  let st = inspect_state ctx in
  let guidance =
    Workflow_guide.current_state_guidance
      ~room_set:st.room_set ~joined:st.joined
      ~task_claimed:st.task_claimed ~current_task_set:st.current_task_set
      ~worktree_active:st.worktree_active ~session_active:false
  in
  let result =
    `Assoc [
      ("current_state", state_to_json st);
      ("guidance", Workflow_guide.guidance_to_json guidance);
    ]
  in
  { success = true; message = Yojson.Safe.to_string result }

(* ── Coordination product FSM snapshot ─────────────────────────── *)

let handle_coordination_fsm_snapshot ctx _args =
  { success = true;
    message = Yojson.Safe.to_string
      (Coordination_product_snapshot.safe_build_tool_yojson ctx.config) }

(* ── State check (assertion-based verification) ────────────────── *)

(** Issue #8636: SSOT for [masc_check] assertion vocabulary. Schema
    enum, handler match, and default fallback used to disagree on
    which strings were valid. The Variant + helpers below give a
    single witness that compile-fails when a constructor is added but
    [assertion_kind_to_string] / [assertion_kind_of_string_lenient]
    aren't updated. Same shape as #8546 / #8601 / #8592. *)
let handle_heartbeat ctx _args =
  let message = Coord.heartbeat ctx.config ~agent_name:ctx.agent_name in
  (* Coord.heartbeat returns "..." on failure (agent not found, invalid file) *)
  let success = not (String.length message >= 3
    && Char.code message.[0] = 0xe2
    && Char.code message.[1] = 0x9a
    && Char.code message.[2] = 0xa0) in
  { success; message }

let dispatch ctx ~name ~args : tool_result option =
  match name with
  | "masc_status" -> Some (handle_status ctx args)
  | "masc_heartbeat" -> Some (handle_heartbeat ctx args)
  | "masc_goal_list" -> Some (Coord_goals.handle_goal_list ctx args)
  | "masc_goal_upsert" -> Some (Coord_goals.handle_goal_upsert ctx args)
  | "masc_goal_review" -> Some (Coord_goals.handle_goal_review ctx args)
  | "masc_goal_transition" -> Some (Coord_goals.handle_goal_transition ctx args)
  | "masc_goal_verify" -> Some (Coord_goals.handle_goal_verify ctx args)
  | "masc_coordination_fsm_snapshot" ->
      Some (handle_coordination_fsm_snapshot ctx args)
  | "masc_reset" -> Some (handle_reset ctx args)
  | "masc_workflow_guide" -> Some (handle_workflow_guide ctx args)
  | "masc_check" ->
      let inspect ctx =
        let s = inspect_state ctx in
        {
          Coord_assertions.room_set = s.room_set;
          joined = s.joined;
          task_claimed = s.task_claimed;
          current_task_set = s.current_task_set;
          worktree_active = s.worktree_active;
        }
      in
      Some (Coord_assertions.handle_check ~inspect_state:inspect ctx args)
  | _ -> None

let schemas = Tool_schemas_coord.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only =
  [ "masc_status"; "masc_goal_list"; "masc_coordination_fsm_snapshot" ]
let _tool_spec_system_internal = [ "masc_reset" ]

let _tool_spec_requires_join = [ "masc_heartbeat" ]

let tool_required_permission = function
  | "masc_status" | "masc_workflow_guide" | "masc_check"
  | "masc_coordination_fsm_snapshot"
  | "masc_goal_list" ->
      Some Masc_domain.CanReadState
  | "masc_goal_upsert" | "masc_goal_review"
  | "masc_goal_transition" | "masc_goal_verify" ->
      Some Masc_domain.CanBroadcast
  | "masc_heartbeat" ->
      Some Masc_domain.CanBroadcast
  | "masc_reset" ->
      Some Masc_domain.CanReset
  | _ -> None

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      let is_system = List.mem s.name _tool_spec_system_internal in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_room
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~requires_join:(List.mem s.name _tool_spec_requires_join)
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ~visibility:(if is_system then Tool_catalog.Hidden else Tool_catalog.Default)
           ~allow_direct_call_when_hidden:is_system
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
