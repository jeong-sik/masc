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

(** Tool_workspace - Workspace management operations
    Handles: status, reset, init, check
    Note: stateful workspace helpers remain in server dispatch modules
*)

module Planning_eio = Task.Planning_eio

open Workspace_types
open Tool_args

(* [type tool_result = Workspace_types.tool_result] DELETED in RFC-0062 Phase 4d-2.
   All handlers now return Tool_result.result directly. *)

type context = Workspace_types.context =
  { config : Workspace.config
  ; agent_name : string
  }

type assertion_kind = Workspace_assertions.assertion_kind =
  | Task_claimed
  | Current_task_set

let assertion_kind_to_string = Workspace_assertions.assertion_kind_to_string
let all_assertion_kinds = Workspace_assertions.all_assertion_kinds
let valid_assertion_strings = Workspace_assertions.valid_assertion_strings
let assertion_kind_of_string_lenient = Workspace_assertions.assertion_kind_of_string_lenient

let take_items limit items =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> loop (remaining - 1) (x :: acc) xs
  in
  loop limit [] items
;;

type text_cache =
  { mutable key : string option
  ; mutable value : string option
  ; mutable expires_at : float
  }

let make_text_cache () = { key = None; value = None; expires_at = 0.0 }
let status_cache = make_text_cache ()

let cache_ttl_seconds env_var ~default =
  match Sys.getenv_opt env_var with
  | Some raw ->
    (match Float.of_string_opt (String.trim raw) with
     | Some value when Stdlib.Float.compare value 0.0 >= 0 -> value
     | _ -> default)
  | None -> default
;;

let status_cache_ttl_s () = 2.0

let invalidatestatus_cache () =
  status_cache.key <- None;
  status_cache.value <- None;
  status_cache.expires_at <- 0.0
;;

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
;;

let effective_cluster_name (config : Workspace.config) =
  match String.trim config.backend_config.Backend_types.cluster_name with
  | "" -> Env_config_core.cluster_name ()
  | name -> name
;;

(* Handlers *)

let lifecycle_tools = [ "keeper_task_claim"; "masc_transition" ]
let is_lifecycle_tool tool = List.exists (String.equal tool) lifecycle_tools

let unique_strings items =
  List.fold_left
    (fun acc item ->
       let item = String.trim item in
       if String.equal item "" || List.exists (String.equal item) acc
       then acc
       else item :: acc)
    []
    items
  |> List.rev
;;

let credential_state (ctx : context) ~actual_name =
  let auth_cfg = Auth.load_auth_config ctx.config.base_path in
  let credential_required = auth_cfg.enabled && auth_cfg.require_token in
  let credential_candidates = unique_strings [ ctx.agent_name; actual_name ] in
  let internal_keeper_credential_available name =
    match
      ( Workspace_identity_backend.keeper_name_for_agent_name name
      , Sys.getenv_opt Auth.internal_keeper_token_env_key )
    with
    | Some _, Some raw ->
      let token = String.trim raw in
      (not (String.equal token ""))
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
                 (Auth.load_credential
                    ctx.config.base_path
                    (Workspace_identity_backend.canonicalize_if_keeper ctx.config name)))
         credential_candidates
  in
  { credential_required; credential_available; credential_candidates }
;;

(* Asymmetric silent-failure unification: previously [Sys_error _ |
   Yojson.Json_error _] (the *more common* read-side failure class —
   missing file, malformed JSON) returned the default silently while
   only the rare [exn] catch-all logged. Operators saw the loud path
   but missed the common one. The five [safe_*] wrappers below now
   share the single-warn-arm shape; [Eio.Cancel.Cancelled] is re-raised
   explicitly so cancellation propagation is preserved across all of
   them. *)
let safe_resolve_agent_name (ctx : context) ~session_bound =
  if not session_bound
  then ctx.agent_name
  else (
    try Workspace.resolve_agent_name ctx.config ctx.agent_name with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Workspace.warn
        "resolve_agent_name failed for %s: %s"
        ctx.agent_name
        (Stdlib.Printexc.to_string exn);
      ctx.agent_name)
;;

let safe_current_task (ctx : context) ~session_bound =
  if not session_bound
  then None
  else (
    try Planning_eio.get_current_task ctx.config with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Workspace.warn
        "get_current_task failed for %s: %s"
        ctx.agent_name
        (Stdlib.Printexc.to_string exn);
      None)
;;

let safe_get_agents (ctx : context) =
  try Workspace.get_active_agents ctx.config with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Workspace.warn "get_active_agents failed: %s" (Stdlib.Printexc.to_string exn);
    []
;;

let safe_read_backlog (ctx : context) =
  try Workspace.read_backlog ctx.config with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Workspace.warn "read_backlog failed: %s" (Stdlib.Printexc.to_string exn);
    { Masc_domain.tasks = []; last_updated = Masc_domain.now_iso (); version = 1 }
;;

let safe_is_zombie_agent ?agent_type ?agent_meta ~agent_name last_seen =
  try Workspace.is_zombie_agent ?agent_type ?agent_meta ~agent_name last_seen with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Workspace.warn
      "is_zombie_agent failed for %s: %s"
      agent_name
      (Stdlib.Printexc.to_string exn);
    false
;;

let todo_task_has_completed_deliverable_conflict (ctx : context) (task : Masc_domain.task)
  =
  match task.task_status with
  | Masc_domain.Todo ->
    (match Planning_eio.load ctx.config ~task_id:task.id with
     | Ok plan_ctx ->
       Task_completion_claim.deliverable_claims_completion
         ~task_id:task.id
         plan_ctx.deliverable
     | Error _ -> false)
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.AwaitingVerification _
  | Masc_domain.Done _
  | Masc_domain.Cancelled _ -> false
;;

let todo_completed_deliverable_conflicts (ctx : context) tasks =
  List.filter_map
    (fun (task : Masc_domain.task) ->
       Workspace_query.safe_yield ();
       if todo_task_has_completed_deliverable_conflict ctx task
       then Some task.id
       else None)
    tasks
;;

let resolve_current_binding ~assigned_task_ids ~planning_current =
  let primary_owned =
    match assigned_task_ids with
    | id :: _ -> Some id
    | [] -> None
  in
  let current_is_assigned =
    match planning_current with
    | Some current ->
      List.exists (fun task_id -> String.equal task_id current) assigned_task_ids
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
  { assigned_task_ids
  ; primary_owned
  ; planning_current
  ; current_is_assigned
  ; effective_current
  ; drift_reason
  ; current_task_set
  ; claim_first_suppressed = Stdlib.List.length assigned_task_ids > 0
  }
;;

let planning_context_state
      (ctx : context)
      (binding : current_binding)
      (active_tasks : Masc_domain.task list)
  =
  match binding.primary_owned with
  | None -> { planning_missing_task = None; deliverable_conflict_task = None }
  | Some task_id ->
    (match Planning_eio.load ctx.config ~task_id with
     | Error _ ->
       { planning_missing_task = Some task_id; deliverable_conflict_task = None }
     | Ok plan_ctx ->
       let deliverable_conflict_task =
         match
           List.find_opt
             (fun (task : Masc_domain.task) -> String.equal task.id task_id)
             active_tasks
         with
         | Some { task_status = Masc_domain.Claimed _ | Masc_domain.InProgress _; _ }
           when Task_completion_claim.deliverable_claims_completion
                  ~task_id
                  plan_ctx.deliverable -> Some task_id
         | Some _ | None -> None
       in
       { planning_missing_task = None; deliverable_conflict_task })
;;

let status_summary_string (ctx : context) =
  Workspace.ensure_initialized ctx.config;
  let state = Workspace.read_state ctx.config in
  let backlog = safe_read_backlog ctx in
  let session_bound =
    (* status_summary_string is read-only on the workspace file; a missing
       or malformed file is treated as "session not bound" because that's the
       most useful default for status rendering. But the silent path
       hid an operationally meaningful failure (file missing after session bind,
       config corrupted) — surface it via warn while keeping the
       [false] default. *)
    try Workspace.is_agent_session_bound ctx.config ~agent_name:ctx.agent_name with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Workspace.warn
        "is_agent_session_bound failed for %s: %s"
        ctx.agent_name
        (Stdlib.Printexc.to_string exn);
      false
  in
  let actual_name = safe_resolve_agent_name ctx ~session_bound in
  let credential_state = credential_state ctx ~actual_name in
  let credential_blocked =
    credential_state.credential_required && not credential_state.credential_available
  in
  let current_task = safe_current_task ctx ~session_bound in
  let effective_cluster_name = effective_cluster_name ctx.config in
  let active_task_assignees = Workspace.active_task_assignees_by_task_id backlog in
  let agents =
    safe_get_agents ctx
    |> List.map (fun (agent : Masc_domain.agent) ->
      match agent.current_task with
      | Some task_id
        when not
               (Workspace.agent_current_task_matches_assignments
                  active_task_assignees
                  ~agent_name:agent.name
                  task_id) ->
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
         Workspace_query.safe_yield ();
         let is_zombie =
             safe_is_zombie_agent
               ~agent_type:agent.agent_type
               ?agent_meta:agent.meta
               ~agent_name:agent.name
               agent.last_seen
         in
         agent, is_zombie)
      agents
  in
  let zombie_count =
    List.fold_left
      (fun acc (_, is_zombie) -> if is_zombie then acc + 1 else acc)
      0
      agents_with_state
  in
  let ( active_tasks
      , todo_count
      , claimed_count
      , in_progress_count
      , done_count
      , cancelled_count )
    =
    List.fold_left
      (fun (active, todo_cnt, claimed_cnt, in_progress_cnt, done_cnt, cancelled_cnt)
        (task : Masc_domain.task) ->
         Workspace_query.safe_yield ();
         match task.task_status with
         | Masc_domain.Todo ->
           ( task :: active
           , todo_cnt + 1
           , claimed_cnt
           , in_progress_cnt
           , done_cnt
           , cancelled_cnt )
         | Masc_domain.Claimed _ ->
           ( task :: active
           , todo_cnt
           , claimed_cnt + 1
           , in_progress_cnt
           , done_cnt
           , cancelled_cnt )
         | Masc_domain.InProgress _ ->
           ( task :: active
           , todo_cnt
           , claimed_cnt
           , in_progress_cnt + 1
           , done_cnt
           , cancelled_cnt )
         | Masc_domain.Done _ ->
           active, todo_cnt, claimed_cnt, in_progress_cnt, done_cnt + 1, cancelled_cnt
         | Masc_domain.AwaitingVerification _ ->
           ( task :: active
           , todo_cnt
           , claimed_cnt
           , in_progress_cnt + 1
           , done_cnt
           , cancelled_cnt )
         | Masc_domain.Cancelled _ ->
           active, todo_cnt, claimed_cnt, in_progress_cnt, done_cnt, cancelled_cnt + 1)
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
    Workspace_status_rendering.assigned_task_ids ~matches_you active_tasks
  in
  let binding =
    resolve_current_binding ~assigned_task_ids ~planning_current:current_task
  in
  let planning_state = planning_context_state ctx binding active_tasks in
  let suggested_next =
    (* All branches must end with [take_items 2] so masc_status response
       size stays bounded.  Prior pipeline had a trailing [|> take_items 2]
       that applied uniformly; restoring that invariant explicitly per
       branch (Copilot review #14662 thread tool_workspace.ml:492). *)
    if Option.is_some planning_state.planning_missing_task
    then []
    else if Option.is_some planning_state.deliverable_conflict_task
    then [ "masc_deliver"; "masc_status" ]
    else (
      let tools =
        if Stdlib.List.length binding.assigned_task_ids > 0
        then [ "masc_heartbeat"; "masc_transition" ]
        else if fresh_todo_count > 0
        then [ "keeper_task_claim"; "masc_status" ]
        else [ "masc_status"; "masc_add_task" ]
      in
      let tools =
        if credential_blocked
        then List.filter (fun tool -> not (is_lifecycle_tool tool)) tools
        else (
          match binding.drift_reason with
          | Some "no_owned" ->
            let tools =
              List.filter (fun tool -> not (String.equal tool "masc_transition")) tools
            in
            let tools =
              if fresh_todo_count > 0 then "keeper_task_claim" :: tools else tools
            in
            unique_strings tools
          | Some _ | None -> tools)
      in
      take_items 2 tools)
  in
  let attention_items =
    let items = [] in
    let items =
      if not session_bound
      then items @ [ "Your agent session is not bound. Call masc_start." ]
      else items
    in
    let items =
      if credential_blocked
      then
        items
        @ [ Printf.sprintf
              "Lifecycle actions are credential-blocked for %s. Mount a valid credential \
               before claiming or transitioning tasks."
              (String.concat "/" credential_state.credential_candidates)
          ]
      else items
    in
    let items =
      match planning_state.planning_missing_task with
      | Some task_id ->
        items
        @ [ Printf.sprintf
              "Owned task %s has no planning context. Do not retry generic \
               masc_plan_init from a drifted surface; use handoff/worktree/test logs as \
               the temporary SSOT until a credentialed owner repair receipt exists."
              task_id
          ]
      | None -> items
    in
    let items =
      match planning_state.deliverable_conflict_task with
      | Some task_id ->
        items
        @ [ Printf.sprintf
              "Owned task %s already has a completed-looking deliverable while the task \
               is still active. Treat this as conflict triage until board, planning, and \
               control-plane state converge."
              task_id
          ]
      | None -> items
    in
    let items =
      if Option.is_some binding.primary_owned && not binding.current_task_set
      then
        items
        @ [ "You own a task but planning current_task is unset or drifted. Treat owned \
             as canonical and call masc_plan_set_task."
          ]
      else items
    in
    let items =
      match binding.drift_reason with
      | Some "secondary_assignment" ->
        items
        @ [ "Multiple assigned tasks detected. Current focus is also assigned; choose or \
             reconcile the active lane before claiming new work."
          ]
      | Some "stale_focus" ->
        items
        @ [ "Owned/current drift detected. Planning current_task is not assigned to you; \
             treat primary_owned as the safe task lane."
          ]
      | Some "no_owned" ->
        items
        @ [ "Planning current_task is set but no active task is assigned to you; clear \
             or rebind current_task before following it."
          ]
      | Some _ | None -> items
    in
    let items =
      if todo_conflict_count > 0
      then
        items
        @ [ Printf.sprintf
              "%d todo task(s) have completed-looking planning deliverables; treat them \
               as control-plane conflicts, not fresh claimable work."
              todo_conflict_count
          ]
      else items
    in
    let items =
      if zombie_count > 0
      then
        items
        @ [ Printf.sprintf
              "%d stale agent(s) are still visible in the namespace."
              zombie_count
          ]
      else items
    in
    if fresh_todo_count > 0 && Stdlib.List.length binding.assigned_task_ids = 0
    then
      items
      @ [ Printf.sprintf "%d unclaimed task(s) are available right now." fresh_todo_count
        ]
    else items
  in
  Workspace_status_rendering.status_summary_string
    ~ctx
    ~bound:session_bound
    ~actual_name
    ~credential_state
    ~credential_blocked
    ~current_task
    ~effective_cluster_name
    ~agents_with_state
    ~active_tasks
    ~todo_count
    ~claimed_count
    ~in_progress_count
    ~done_count
    ~cancelled_count
    ~todo_conflict_task_ids
    ~binding
    ~planning_state
    ~suggested_next
    ~attention_items
    ~state
    ~backlog
;;

let handle_status ~tool_name ~start_time ctx _args =
  let cache_key = Printf.sprintf "%s::%s" ctx.config.base_path ctx.agent_name in
  Tool_result.ok
    ~tool_name
    ~start_time
    (cached_text_by_key
       status_cache
       ~key:cache_key
       ~ttl_s:(status_cache_ttl_s ())
       (fun () -> status_summary_string ctx))
;;

let handle_reset ~tool_name ~start_time ctx args =
  let confirm = get_bool args "confirm" false in
  if not confirm
  then
    (* RFC-0189: missing required [confirm=true] safety gate.
       [Workflow_rejection] — operator can address by passing the
       expected argument. *)
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name
      ~start_time
      "This will DELETE the entire .masc/ folder!\nCall with confirm=true to proceed."
  else (
    invalidatestatus_cache ();
    Tool_result.ok ~tool_name ~start_time (Workspace.reset ctx.config))
;;

(* ── State inspection (shared by status and check) ──────── *)

type agent_state =
  { task_claimed : bool
  ; current_task_set : bool
  }

let inspect_state ctx =
  let binding =
    let actual_name = safe_resolve_agent_name ctx ~session_bound:true in
    let matches_you assignee =
      String.equal assignee ctx.agent_name || String.equal assignee actual_name
    in
    let assigned_task_ids =
      Workspace.get_tasks_raw ctx.config
      |> Workspace_status_rendering.assigned_task_ids ~matches_you
    in
    resolve_current_binding
      ~assigned_task_ids
      ~planning_current:(safe_current_task ctx ~session_bound:true)
  in
  let task_claimed = Stdlib.List.length binding.assigned_task_ids > 0 in
  let current_task_set = binding.current_task_set in
  { task_claimed; current_task_set }
;;

let state_to_json st =
  `Assoc
    [ "task_claimed", `Bool st.task_claimed
    ; "current_task_set", `Bool st.current_task_set
    ; "session_active", `Bool false
    ]
;;

(* ── State check (assertion-based verification) ────────────────── *)

(** Issue #8636: SSOT for [masc_check] assertion vocabulary. Schema
    enum, handler match, and default fallback used to disagree on
    which strings were valid. The Variant + helpers below give a
    single witness that compile-fails when a constructor is added but
    [assertion_kind_to_string] / [assertion_kind_of_string_lenient]
    aren't updated. Same shape as #8546 / #8601 / #8592. *)
let handle_heartbeat ~tool_name ~start_time ctx _args =
  let message = Workspace.heartbeat ctx.config ~agent_name:ctx.agent_name in
  (* Workspace.heartbeat returns "..." on failure (agent not found, invalid file) *)
  let success =
    not
      (String.length message >= 3
       && Char.code message.[0] = 0xe2
       && Char.code message.[1] = 0x9a
       && Char.code message.[2] = 0xa0)
  in
  if success
  then Tool_result.ok ~tool_name ~start_time message
  else
    (* RFC-0189: heartbeat failure stems from agent-state issues
       ("agent not found", "invalid file") that the caller can
       resolve (bind the session, refresh credentials).
       [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time message
;;

type dispatch_handler =
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result

let handle_check ~tool_name ~start_time ctx args =
  let inspect ctx =
    let s = inspect_state ctx in
    { Workspace_assertions.task_claimed = s.task_claimed
    ; current_task_set = s.current_task_set
    }
  in
  Workspace_assertions.handle_check ~inspect_state:inspect ~tool_name ~start_time ctx args
;;

let dispatch_bindings : (string * dispatch_handler) list =
  [ "masc_status", handle_status
  ; "masc_heartbeat", handle_heartbeat
  ; "masc_goal_list", Workspace_goals.handle_goal_list
  ; "masc_goal_upsert", Workspace_goals.handle_goal_upsert
  ; "masc_goal_hygiene_review", Workspace_goals.handle_goal_hygiene_review
  ; "masc_goal_transition", Workspace_goals.handle_goal_transition
  ; "masc_goal_verify", Workspace_goals.handle_goal_verify
  ; "masc_reset", handle_reset
  ; "masc_check", handle_check
  ]
;;

let dispatchable_names = List.map fst dispatch_bindings

let dispatch ctx ~name ~args : Tool_result.result option =
  let start_time = Time_compat.now () in
  match List.assoc_opt name dispatch_bindings with
  | Some handle -> Some (handle ~tool_name:name ~start_time ctx args)
  | None -> None
;;

let schemas = Tool_schemas_workspace.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let tool_spec_read_only = [ "masc_status"; "masc_check"; "masc_goal_list" ];;

let tool_spec_system_internal = [ "masc_reset" ]

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
       let is_system = List.mem s.name tool_spec_system_internal in
       Tool_spec.register
         (Tool_spec.create
            ~name:s.name
            ~description:s.description
            ~module_tag:Tool_dispatch.Mod_state
            ~input_schema:s.input_schema
            ~handler_binding:Tag_dispatch
            ~is_read_only:(List.mem s.name tool_spec_read_only)
            ~is_idempotent:(List.mem s.name tool_spec_read_only)
            ~visibility:(if is_system then Tool_catalog.Hidden else Tool_catalog.Default)
            ~allow_direct_call_when_hidden:is_system
            ()))
    schemas
;;
