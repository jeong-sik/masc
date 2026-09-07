(** Tool_workspace - Workspace management operations
    Handles: status, init, check
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

let valid_assertion_strings = Workspace_assertions.valid_assertion_strings
let effective_cluster_name (config : Workspace.config) =
  match String.trim config.backend_config.Backend_types.cluster_name with
  | "" -> Env_config_core.cluster_name ()
  | name -> name
;;

(* Handlers *)

(* Trims before comparing, so [" a"] and ["a"] are one value, and drops
   what is blank after trimming. [Json_util.dedupe_keep_order] does
   neither; naming this one [unique_strings] hid that difference. *)
let unique_trimmed_nonblank items =
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
  let credential_candidates =
    unique_trimmed_nonblank [ ctx.agent_name; actual_name ]
  in
  let internal_keeper_credential_available name =
    (* Typed in-process read (RFC-0371 B11): this used to getenv the token
       the process itself had putenv'd at boot — its own environment as an
       in-memory channel, re-read per tool call. RFC-0393: whether [name]
       is a keeper is a registry lookup, not a name-shape parse. *)
    match
      ( (Atomic.get Workspace_hooks.keeper_registered_fn)
          ~base_path:ctx.config.base_path
          ~agent_name:name
      , Auth.internal_keeper_token () )
    with
    | true, Some raw ->
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
            || Option.is_some (Auth.load_credential ctx.config.base_path name))
         credential_candidates
  in
  { credential_required; credential_available; credential_candidates }
;;

(* Asymmetric silent-failure unification: previously [Sys_error _ |
   Yojson.Json_error _] (the *more common* read-side failure class —
   missing file, malformed JSON) returned the default silently while
   only the rare [exn] catch-all logged. Operators saw the loud path
   but missed the common one. The three [safe_*] wrappers below now
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

(* The roster and what went wrong while reading it. Two layers can fail here:
   one source inside the merge, reported through the returned list, and the
   whole read, caught below. Both used to end at a log line and an empty list,
   which reaches an operator as a roster that is simply short. *)
let safe_get_agents_observed (ctx : context) =
  try Workspace.get_active_agents_observed ctx.config with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let detail = Stdlib.Printexc.to_string exn in
    Log.Workspace.warn "get_active_agents failed: %s" detail;
    [], [ "active agent roster: " ^ detail ]
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


let status_summary_string (ctx : context) =
  Workspace.ensure_initialized ctx.config;
  let state = Workspace.read_state ctx.config in
  match Workspace.read_backlog_observation_with_source_r ctx.config with
  | Error error ->
    Error (Printf.sprintf "status snapshot unavailable: backlog read failed: %s" error)
  | Ok { Workspace.observed_backlog = backlog; recovered_from } ->
  (* Read the goal-task registry through the Result reader so a damaged
     registry surfaces here instead of rendering as "no task has a goal". The
     renderer takes the built index as an argument — its contract says every
     line is a deliberate operator surface, which a store read inside it
     would quietly break. *)
  match Workspace_goal_index.read_goal_task_links_r ctx.config with
  | Error error ->
    Error
      (Printf.sprintf "status snapshot unavailable: goal link read failed: %s" error)
  | Ok goal_task_links ->
  let task_goal_index =
    Workspace_goal_index.build_task_goal_index ~goal_task_links ()
  in
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
  let roster, observation_failures = safe_get_agents_observed ctx in
  let agents =
    roster
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
  let matches_you assignee =
    String.equal assignee ctx.agent_name || String.equal assignee actual_name
  in
  let assigned_task_ids =
    Workspace_status_rendering.assigned_task_ids ~matches_you active_tasks
  in
  let binding =
    resolve_current_binding ~assigned_task_ids ~planning_current:current_task
  in
  let attention_items =
    let items = [] in
    let items =
      if not session_bound
      then items @ [ "Your agent session is not bound." ]
      else items
    in
    let items =
      if credential_blocked
      then
        items
        @ [ Printf.sprintf
              "Lifecycle actions are credential-blocked for %s."
              (String.concat "/" credential_state.credential_candidates)
          ]
      else items
    in
    let items =
      if Option.is_some binding.primary_owned && not binding.current_task_set
      then
        items
        @ [ "You own a task but planning current_task is unset or drifted." ]
      else items
    in
    let items =
      match binding.drift_reason with
      | Some "secondary_assignment" ->
        items
        @ [ "Multiple assigned tasks detected. Current focus is also assigned." ]
      | Some "stale_focus" ->
        items
        @ [ "Owned/current drift detected. Planning current_task is not assigned to you." ]
      | Some "no_owned" ->
        items
        @ [ "Planning current_task is set but no active task is assigned to you." ]
      | Some _ | None -> items
    in
    if todo_count > 0 && Stdlib.List.length binding.assigned_task_ids = 0
    then
      items
      @ [ Printf.sprintf "%d unclaimed task(s) are available right now." todo_count
        ]
    else items
  in
  let snapshot =
    Workspace_status_rendering.status_summary_string
       ~ctx
       ~bound:session_bound
       ~actual_name
       ~credential_state
       ~credential_blocked
       ~current_task
       ~effective_cluster_name
       ~agents
       ~active_tasks
       ~todo_count
       ~claimed_count
       ~in_progress_count
       ~done_count
       ~cancelled_count
       ~binding
       ~task_goal_index
       ~attention_items
       ~state
       ~backlog
  in
  let snapshot =
    match recovered_from with
    | None -> snapshot
    | Some _ ->
      "⚠ Backlog observation is recovery-backed and non-authoritative. Recheck the primary backlog before mutation.\n"
      ^ snapshot
  in
  (* The backlog already says when it is recovery-backed. An observation
     outside the backlog said nothing: it logged and answered with an empty
     list, so the roster below simply came back short. Name it in the screen a
     person reads, next to the line that reports the backlog. *)
  let snapshot =
    match observation_failures with
    | [] -> snapshot
    | failures ->
      Printf.sprintf
        "⚠ Observation incomplete — %s. The roster below is missing whatever \
         that read would have carried.\n%s"
        (String.concat "; " failures)
        snapshot
  in
  Ok (snapshot, recovered_from, observation_failures)
;;

let handle_status ~task_list_projection ~tool_name ~start_time ctx args =
  match Snapshot_protocol.if_revision args with
  | Error message ->
    error_result_typed
      ~tool_name
      ~start_time
      ~failure_class:Tool_result.Policy_rejection
      ~code:Validation_error
      message
  | Ok if_revision ->
  let task_list_name =
    Tool_capability_projection.task_list_name task_list_projection
  in
  (match status_summary_string ctx with
   | Error message ->
     error_result_typed
       ~tool_name
       ~start_time
       ~code:Internal_error
       message
   | Ok (snapshot, recovered_from, observation_failures) ->
     let revision =
       Snapshot_protocol.revision_of_json
         ~namespace:"status"
         (`Assoc
           [ "task_list_name", `String task_list_name
           ; ( "backlog_authority"
             , `String
                 (if Option.is_none recovered_from
                  then "primary"
                  else "recovery_non_authoritative") )
           ; ( "observation_failures"
             , `List (List.map (fun failure -> `String failure) observation_failures) )
           ; "snapshot", `String snapshot
           ])
     in
     let response =
       match recovered_from with
       | None -> Snapshot_protocol.respond ~revision ~if_revision (`String snapshot)
       | Some _ -> Snapshot_protocol.Snapshot { revision; value = `String snapshot }
     in
     let data =
       match Snapshot_protocol.to_yojson response with
       | `Assoc fields ->
         `Assoc
           (( "backlog_authority"
            , `String
                (if Option.is_none recovered_from
                 then "primary"
                 else "recovery_non_authoritative") )
            :: ( "observation_failures"
               , `List (List.map (fun failure -> `String failure) observation_failures) )
            :: ( "degraded"
               , `Bool (Option.is_some recovered_from || observation_failures <> []) )
            :: fields)
       | payload -> payload
     in
     Tool_result.make_ok
       ~tool_name
       ~start_time
       ~data
       ())
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

(* ── State check (assertion-based verification) ────────────────── *)

(** Issue #8636: SSOT for [masc_check] assertion vocabulary. Schema
    enum, handler match, and default fallback used to disagree on
    which strings were valid. The Variant + helpers below give a
    single witness that compile-fails when a constructor is added but
    [assertion_kind_to_string] / [assertion_kind_of_string_lenient]
    aren't updated. Same shape as #8546 / #8601 / #8592. *)
let handle_heartbeat ~tool_name ~start_time ctx _args =
  let outcome = Workspace.heartbeat ctx.config ~agent_name:ctx.agent_name in
  let message = Workspace.heartbeat_message outcome in
  match outcome with
  | Workspace.Heartbeat_updated _ -> Tool_result.ok ~tool_name ~start_time message
  | Workspace.Agent_not_found _ | Workspace.Agent_file_invalid _ ->
    (* RFC-0189: heartbeat failure stems from agent-state issues
       ("agent not found", "invalid file") that the caller can
       resolve (bind the session, refresh credentials).
       [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
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

(* Goal tools route on their closed type. [dispatchable_names] and the routing
   below both read Tool_name.Goal_name, so a constructor added there is a
   compile error in [goal_handler] rather than a tool that gets advertised and
   then answers "unknown". The two entries left in [dispatch_bindings] own no
   closed type yet. *)
let goal_handler : Tool_name.Goal_name.t -> dispatch_handler = function
  | Tool_name.Goal_name.Goal_list -> Workspace_goals.handle_goal_list
  | Tool_name.Goal_name.Goal_upsert -> Workspace_goals.handle_goal_upsert
  | Tool_name.Goal_name.Goal_transition -> Workspace_goals.handle_goal_transition
;;

let dispatchable_names =
  List.map Tool_schemas_workspace_core.tool_name Tool_schemas_workspace_core.operations
  @ List.map Tool_name.Goal_name.to_string Tool_name.Goal_name.all

(* Both families route on their closed type. [Status] takes the task-list
   projection the other two do not, which is why it kept a separate arm rather
   than a shared handler table. *)
let dispatch_with_task_list_projection task_list_projection ctx ~name ~args =
  let start_time = Time_compat.now () in
  match Tool_schemas_workspace_core.operation_of_tool_name name with
  | Some Tool_schemas_workspace_core.Status ->
    Some (handle_status ~task_list_projection ~tool_name:name ~start_time ctx args)
  | Some Tool_schemas_workspace_core.Check ->
    Some (handle_check ~tool_name:name ~start_time ctx args)
  | Some Tool_schemas_workspace_core.Heartbeat ->
    Some (handle_heartbeat ~tool_name:name ~start_time ctx args)
  | None ->
    (match Tool_name.Goal_name.of_string name with
     | Some goal -> Some (goal_handler goal ~tool_name:name ~start_time ctx args)
     | None -> None)
;;

let dispatch ctx ~name ~args =
  dispatch_with_task_list_projection
    Tool_capability_projection.External_masc_tasks
    ctx
    ~name
    ~args
;;

let dispatch_for_keeper ctx ~name ~args =
  dispatch_with_task_list_projection
    Tool_capability_projection.Keeper_tasks_list
    ctx
    ~name
    ~args
;;

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let core_is_read_only = function
  | Tool_schemas_workspace_core.Status | Tool_schemas_workspace_core.Check -> true
  | Tool_schemas_workspace_core.Heartbeat -> false
;;

let goal_is_read_only = function
  | Tool_name.Goal_name.Goal_list -> true
  | Tool_name.Goal_name.Goal_transition | Tool_name.Goal_name.Goal_upsert -> false
;;

let goal_schema goal =
  let name = Tool_name.Goal_name.to_string goal in
  match
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
      Tool_schemas_workspace_extra.schemas
  with
  | Some schema -> schema
  | None -> invalid_arg ("missing workspace goal schema: " ^ name)
;;

(* Registration walks the same two closed types [dispatch] matches, so the
   advertised set and the routed set are the same set by construction --
   [test_tool_registry_consistency] compared them at test time, and PR CI does
   not run tests. read_only used to come from a membership list over three name
   strings; it is a match on each type now. *)
let () =
  let register ~name ~(schema : Masc_domain.tool_schema) ~is_read_only =
    Tool_spec.register
      (Tool_spec.create
         ~name
         ~description:schema.description
         ~module_tag:Tool_dispatch.Mod_state
         ~input_schema:schema.input_schema
         ~handler_binding:Tag_dispatch
         ~is_read_only
         ())
  in
  List.iter
    (fun operation ->
       register
         ~name:(Tool_schemas_workspace_core.tool_name operation)
         ~schema:(Tool_schemas_workspace_core.schema operation)
         ~is_read_only:(core_is_read_only operation))
    Tool_schemas_workspace_core.operations;
  List.iter
    (fun goal ->
       register
         ~name:(Tool_name.Goal_name.to_string goal)
         ~schema:(goal_schema goal)
         ~is_read_only:(goal_is_read_only goal))
    Tool_name.Goal_name.all
;;
