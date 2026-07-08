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

module Workspace = Workspace_core

(** Tool_task - Core task CRUD operations

    Handles: add_task, batch_add_tasks, cancel_task, claim, claim_next,
    done, release, task_history, tasks, transition, update_priority, archive_view
*)

(* Yojson.Safe.Util removed — use Json_util SSOT helpers instead *)

let record_verdict_fn
  : (task_id:string -> req:Anti_rationalization.review_request -> result:Anti_rationalization.review_result -> unit -> unit) Atomic.t
  = Atomic.make (fun ~task_id:_ ~req:_ ~result:_ () -> ())

let sse_broadcast_fn
  : (Yojson.Safe.t -> unit) Atomic.t
  = Atomic.make (fun _ -> ())

let get_few_shot_block_fn
  : (unit -> string) Atomic.t
  = Atomic.make (fun () -> "")

let push_event_to_sessions_fn
  : (Yojson.Safe.t -> unit) Atomic.t
  = Atomic.make (fun _ -> ())





type context = {
  config: Workspace.config;
  agent_name: string;
  sw: Eio.Switch.t option;
}

type task_owner_hooks =
  { is_registered_agent_alias : Workspace.config -> string -> bool
  ; sync_current_task_binding : Workspace.config -> agent_name:string -> unit
  ; transition_action_denylist : Workspace.config -> agent_name:string -> string list
  ; active_goal_phases_for_agent : Workspace.config -> agent_name:string -> string list
  }

let default_task_owner_hooks =
  { is_registered_agent_alias = (fun _ _ -> false)
  ; sync_current_task_binding = (fun _ ~agent_name:_ -> ())
  ; transition_action_denylist = (fun _ ~agent_name:_ -> [])
  ; active_goal_phases_for_agent = (fun _ ~agent_name:_ -> [])
  }
;;

let task_owner_hooks = Atomic.make default_task_owner_hooks
let set_task_owner_hooks hooks = Atomic.set task_owner_hooks hooks
let current_task_owner_hooks () = Atomic.get task_owner_hooks

open Tool_args

let task_log_warn ~task_id fmt =
  Stdlib.Format.ksprintf
    (fun message -> Log.Task.warn "task_id=%s %s" task_id message)
    fmt

let task_log_error ~task_id fmt =
  Stdlib.Format.ksprintf
    (fun message -> Log.Task.error "task_id=%s %s" task_id message)
    fmt

let task_agent_log_warn ~agent_name fmt =
  Stdlib.Format.ksprintf
    (fun message -> Log.Task.warn "agent_name=%s %s" agent_name message)
    fmt

let task_agent_log_error ~agent_name fmt =
  Stdlib.Format.ksprintf
    (fun message -> Log.Task.error "agent_name=%s %s" agent_name message)
    fmt

(* RFC-0189: [Masc_domain] backend Error variants (Task_error /
   Agent_error / etc.) currently surface as caller-actionable
   workflow violations ("task not found", "invalid transition",
   "agent not in workspace") rather than transient/runtime failures.
   Tag [Workflow_rejection] uniformly at the helper boundary —
   when [Masc_domain] grows typed per-variant failure_class
   assignment, this tag becomes per-call-site. *)
let result_to_response ~tool_name ~start_time = function
  | Ok msg -> Tool_result.ok ~tool_name ~start_time msg
  | Error e ->
      Tool_result.error
        ~failure_class:(Some Tool_result.Workflow_rejection)
        ~tool_name ~start_time
        (Masc_domain.masc_error_to_string e)

let log_task_transition_failed ~agent_name err =
  let message = Masc_domain.masc_error_to_string err in
  match err with
  | Masc_domain.Task (Masc_domain.Task_error.InvalidState _) ->
      task_agent_log_warn ~agent_name "task transition failed: %s" message
  | _ -> task_agent_log_error ~agent_name "task transition failed: %s" message

(** Client-side FSM gate: reject impossible transitions before server dispatch.
    Uses [Workspace_task_classify.valid_next_actions_for_status] as SSOT. *)
let client_side_transition_gate_error ~task_opt ~action ~action_s =
  match task_opt with
  | None -> None
  | Some (task : Masc_domain.task) ->
    let valid_actions = Workspace_task_classify.valid_next_actions_for_status task.task_status in
    if List.mem action valid_actions
    then None
    else
      Some
        (Masc_domain.Task_error.InvalidState
           (Printf.sprintf
              "Transition '%s' from status '%s' is not allowed. Valid actions: %s"
              action_s
              (Masc_domain.task_status_to_string task.task_status)
              (String.concat ", " (List.map Masc_domain.task_action_to_string valid_actions))))

include Tool_task_payloads

let is_registered_owner_agent_alias_name config agent_name =
  (current_task_owner_hooks ()).is_registered_agent_alias config agent_name

let sync_planning_current_task_with_owned_task (ctx : context) =
  let actual_name =
    (* Asymmetric silent-failure unification: previously [Sys_error _ |
       Yojson.Json_error _] (the *more common* read-side failure class —
       missing agents file, malformed JSON) returned [ctx.agent_name]
       silently while only the rare [exn] catch-all logged. Operators
       saw the loud path but missed the common one. Single warn arm
       mirrors [Tool_workspace.safe_read_backlog]. *)
    try Workspace.resolve_agent_name ctx.config ctx.agent_name with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Task.warn "resolve_agent_name failed for %s: %s" ctx.agent_name
          (Stdlib.Printexc.to_string exn);
        ctx.agent_name
  in
  if
    is_registered_owner_agent_alias_name ctx.config ctx.agent_name
    || is_registered_owner_agent_alias_name ctx.config actual_name
  then ()
  else
    let matches_you assignee =
      String.equal assignee ctx.agent_name || String.equal assignee actual_name
    in
    let owned_task =
      Workspace.get_tasks_raw ctx.config
      |> List.find_map (fun (task : Masc_domain.task) ->
             match task.task_status with
             | Masc_domain.Claimed { assignee; _ }
             | Masc_domain.InProgress { assignee; _ } ->
                 if matches_you assignee then Some task.id else None
             | Masc_domain.Todo
             | Masc_domain.AwaitingVerification _
             | Masc_domain.Done _
             | Masc_domain.Cancelled _ -> None)
    in
    match owned_task with
    | Some task_id ->
        (match Planning_eio.set_current_task ctx.config ~task_id with
         | Ok () -> ()
         | Error msg ->
             task_log_warn ~task_id
               "failed to sync planning current_task to %s: %s"
               task_id msg)
    | None -> Planning_eio.clear_current_task ctx.config

let sync_owner_current_task_binding (ctx : context) =
  (current_task_owner_hooks ()).sync_current_task_binding
    ctx.config
    ~agent_name:ctx.agent_name

let owner_transition_action_denylist (ctx : context) =
  (current_task_owner_hooks ()).transition_action_denylist
    ctx.config
    ~agent_name:ctx.agent_name

let review_completion_notes
    ~(completion_contract : string list option)
    ~(evaluator_runtime : string option)
    ~(ctx : context)
    ~(task_opt : Masc_domain.task option)
    ~(task_id : string)
    ~(notes : string)
    ~(evidence_refs : string list) : string option =
  match task_opt with
  | None -> None
  | Some task ->
      let ar_req : Anti_rationalization.review_request = {
        task_title = task.title;
        task_description = task.description;
        completion_notes = notes;
        agent_name = ctx.agent_name;
        task_id = task.id;
        evidence_refs = evidence_refs;
      } in
      (* task-1664: the persisted contract's evidence obligations must reach
         the LLM prompt too, not only [completion_contract]. Read them from
         the task's own contract so a task requiring e.g. a PR link is judged
         against that requirement rather than approved on narrative notes. *)
      let required_evidence, verify_gate_evidence =
        match task.contract with
        | Some (c : Masc_domain.task_contract) ->
            c.required_evidence, c.verify_gate_evidence
        | None -> [], []
      in
      let on_verdict result =
        (Atomic.get record_verdict_fn)
          ~task_id ~req:ar_req ~result ();
        (try
           (Atomic.get sse_broadcast_fn)
             (build_verdict_sse_payload
                ~now:(Time_compat.now ())
                ~task_id ~req:ar_req ~result)
         with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Harness.warn
              "[anti-rationalization] verdict sse broadcast failed: %s"
              (Stdlib.Printexc.to_string exn))
      in
      let few_shot_block = (Atomic.get get_few_shot_block_fn) () in
      match (Anti_rationalization.review
         ?sw:ctx.sw
         ?evaluator_runtime
         ?completion_contract
         ~required_evidence
         ~verify_gate_evidence
         ~on_verdict ~few_shot_block ar_req).verdict with
      | Anti_rationalization.Reject reason -> Some reason
      | Anti_rationalization.Approve -> None

include Tool_task_completion_review

include Tool_task_args

include Tool_task_contract_gate

(* [persisted_contract_rejection] takes [~agent_name] as a plain label so
   that {!Tool_task_contract_gate} stays free of the {!Tool_task} context
   record. The facade re-exports a context-bound shim so existing
   downstream code shape ([~ctx]) is preserved. *)
let persisted_contract_rejection ~(ctx : context)
    ~(task_opt : Masc_domain.task option) ~(notes : string) =
  Tool_task_contract_gate.persisted_contract_rejection
    ~agent_name:ctx.agent_name ~task_opt ~notes

(* Handlers *)

let handle_add_task ~tool_name ~start_time ctx args =
  let valid_keys =
    [ "title"; "priority"; "description"; "goal_id"; "contract"; "predecessor_task_id" ]
  in
  let unknown = unknown_args ~valid_keys args in
  if Stdlib.List.length unknown > 0 then
    (* RFC-0189: schema rejection — operator passed unknown
       argument names. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      (Printf.sprintf
        "Unknown argument(s): %s. Valid: %s"
        (String.concat ", " unknown)
        (String.concat ", " valid_keys))
  else
  let title = get_string args "title" "" in
  let priority = get_int args "priority" 3 in
  let description = get_string args "description" "" in
  let goal_id =
    match Safe_ops.json_string_opt "goal_id" args with
    | Some s when not (String.equal (String.trim s) "") -> Some (String.trim s)
    | _ -> None
  in
  (* RFC-0323 W2: existence + terminal validation happens in
     [Workspace.add_task_with_result] inside the backlog lock (typed
     [Unknown_predecessor] / [Predecessor_not_terminal] errors). *)
  let predecessor_task_id =
    match Safe_ops.json_string_opt "predecessor_task_id" args with
    | Some s when not (String.equal (String.trim s) "") -> Some (String.trim s)
    | _ -> None
  in
  let contract_result = parse_task_contract args in
  (* BUG-009/010: Validate title and priority *)
  let trimmed_title = String.trim title in
  (* RFC-0189: title/priority/goal_id/contract validation — all
     caller-input violations. [Workflow_rejection]. *)
  if String.equal trimmed_title "" then
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      "Task title cannot be empty or whitespace-only"
  else if priority < 1 || priority > 5 then
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      (Printf.sprintf "Priority must be between 1 and 5, got %d" priority)
  else if Option.is_some goal_id
          && not
               (* DET-OK: [Option.value ~default:""] is guarded by
                  the [Option.is_some goal_id] guard above; the
                  empty default is unreachable.  Refactoring to a
                  match would split the boolean chain awkwardly. *)
               (Goal_store.list_goals ctx.config ()
                |> List.exists (fun (goal : Goal_store.goal) ->
                       String.equal goal.id (Option.value ~default:"" goal_id)))
  then
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      (* DET-OK: same guarded branch — goal_id is [Some _]. *)
      (Printf.sprintf "Unknown goal_id '%s'" (Option.value ~default:"" goal_id))
  else
    match contract_result with
    | Error error ->
        Tool_result.error
          ~failure_class:(Some Tool_result.Workflow_rejection)
          ~tool_name ~start_time error
    | Ok contract ->
        let add_result =
          Workspace.add_task_with_result ?contract
            ?goal_id
            ?predecessor_task_id
            ~reject_if:
              (Workspace_task_capacity.rejection_for_add_task_for_config
                 ctx.config
                 ?goal_id)
            ~created_by:ctx.agent_name ctx.config ~title:trimmed_title
            ~priority ~description
        in
        (match add_result with
         | Ok created ->
           Tool_result.make_ok
             ~tool_name
             ~start_time
             ~data:
               (`Assoc
                  [ "ok", `Bool true
                  ; "task_id", `String created.task_id
                  ; "summary", `String created.summary
                  ; "title", `String trimmed_title
                  ; "priority", `Int priority
                  ; "description", `String description
                  ; "goal_id", Json_util.string_opt_to_json goal_id
                  ; ( "predecessor_task_id"
                    , Json_util.string_opt_to_json predecessor_task_id )
                  ])
             ()
         | Error err ->
           Tool_result.error
             ~failure_class:(Some Tool_result.Workflow_rejection)
             ~tool_name
             ~start_time
             (Workspace.add_task_error_to_string err))

(* RFC-0267 Phase 2: assign an existing goalless task to a goal. Thin adapter
   over [Task_goal_assignment.set_task_goal] — the single validated backend
   shared with the dashboard HTTP route, so neither surface re-implements the
   precondition checks. All caller-input violations are [Workflow_rejection]. *)
let handle_set_goal ~tool_name ~start_time ctx args =
  let valid_keys = [ "task_id"; "goal_id" ] in
  let unknown = unknown_args ~valid_keys args in
  if Stdlib.List.length unknown > 0 then
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      (Printf.sprintf "Unknown argument(s): %s. Valid: %s"
        (String.concat ", " unknown)
        (String.concat ", " valid_keys))
  else
    let task_id = String.trim (get_string args "task_id" "") in
    let goal_id = String.trim (get_string args "goal_id" "") in
    if String.equal task_id "" then
      Tool_result.error
        ~failure_class:(Some Tool_result.Workflow_rejection)
        ~tool_name ~start_time
        "task_id is required and cannot be empty"
    else if String.equal goal_id "" then
      Tool_result.error
        ~failure_class:(Some Tool_result.Workflow_rejection)
        ~tool_name ~start_time
        "goal_id is required and cannot be empty"
    else (
      match Task_goal_assignment.set_task_goal ctx.config ~task_id ~goal_id with
      | Ok () ->
        Tool_result.ok ~tool_name ~start_time
          (Yojson.Safe.to_string
            (`Assoc
              [ ("ok", `Bool true)
              ; ("task_id", `String task_id)
              ; ("goal_id", `String goal_id)
              ]))
      | Error err ->
        Tool_result.error
          ~failure_class:(Some Tool_result.Workflow_rejection)
          ~tool_name ~start_time
          (Task_goal_assignment.set_task_goal_error_to_string err))

let handle_batch_add_tasks ~tool_name ~start_time ctx args =
  let valid_item_keys = [ "title"; "priority"; "description"; "goal_id"; "contract" ] in
  let tasks_json = match Json_util.assoc_member_opt "tasks" args with
    | Some (`List l) -> l
    | _ -> []
  in
  if Stdlib.List.length tasks_json = 0 then
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      "tasks array is empty or missing"
  else
  let validated = List.mapi (fun idx t ->
    let title = String.trim (Json_util.get_string t "title" |> Option.value ~default:"") in
    let priority = Json_util.get_int t "priority" |> Option.value ~default:3 in
    let description = Json_util.get_string t "description" |> Option.value ~default:"" in
    let goal_id =
      match Json_util.get_string t "goal_id" with
      | Some s when not (String.equal (String.trim s) "") -> Some (String.trim s)
      | _ -> None
    in
    let contract =
      match Json_util.assoc_member_opt "contract" t with
      | None | Some `Null -> Ok None
      | Some (`Assoc _ as json) -> (
          match Masc_domain.task_contract_of_yojson json with
          | Ok contract -> Ok (Some contract)
          | Error error ->
              Error
                (Printf.sprintf "item[%d]: invalid contract payload: %s" idx
                   error))
      | Some _ -> Error (Printf.sprintf "item[%d]: contract must be an object" idx)
    in
    if String.equal title "" then
      Error (Printf.sprintf "item[%d]: title cannot be empty" idx)
    else if priority < 1 || priority > 5 then
      Error (Printf.sprintf "item[%d]: priority must be 1-5, got %d" idx priority)
    else
      match contract with
      | Ok contract ->
          let has_removed_field name =
            match Json_util.assoc_member_opt name t with
            | None | Some `Null -> false
            | Some _ -> true
          in
          let unknown = unknown_args ~valid_keys:valid_item_keys t in
          if has_removed_field "required_role" then
            Error (Printf.sprintf "item[%d]: required_role is no longer supported" idx)
          else if has_removed_field "required_verifier_role" then
            Error
              (Printf.sprintf "item[%d]: required_verifier_role is no longer supported" idx)
          else if Stdlib.List.length unknown > 0 then
            Error
              (Printf.sprintf "item[%d]: Unknown argument(s): %s. Valid: %s" idx
                 (String.concat ", " unknown)
                 (String.concat ", " valid_item_keys))
          else
            Ok (title, priority, description, contract, goal_id)
      | Error error -> Error error
  ) tasks_json in
  let errors = List.filter_map (function Error e -> Some e | Ok _ -> None) validated in
  if Stdlib.List.length errors > 0 then
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      (Printf.sprintf "Validation failed:\n%s" (String.concat "\n" errors))
  else
    let tasks =
      List.filter_map (function Ok t -> Some t | Error _ -> None) validated
    in
    let batch_result =
      Workspace.batch_add_tasks_with_contracts_result
        ~created_by:ctx.agent_name ctx.config tasks
    in
    (match batch_result with
     | Ok created ->
       Tool_result.make_ok
         ~tool_name
         ~start_time
         ~data:
           (`Assoc
              [ "ok", `Bool true
              ; "task_ids", `List (List.map (fun task_id -> `String task_id) created.task_ids)
              ; "summary", `String created.summary
              ; "count", `Int created.count
              ])
         ()
     | Error err ->
       Tool_result.error
         ~failure_class:(Some Tool_result.Workflow_rejection)
         ~tool_name
         ~start_time
         (Workspace.batch_add_tasks_error_to_string err))

let handle_claim ~tool_name ~start_time ctx args =
  (* #18965 — removed [is_agent_session_bound] hard gate.  Agent-internal tag
     dispatch path bypasses MCP entry session binding, so this gate produced
     false-negative rejects for every agent turn (fleet evidence:
     <base-path>/.masc/agents/ empty while agents run normally; only
     masc_claim/keeper_task_claim failed).  Workspace.claim_task_r works on
     agent_name alone; gate added no real authorization. *)
  if Option.is_some (Json_util.assoc_member_opt "agent_role" args) then
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      "agent_role is no longer supported"
  else
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response ~tool_name ~start_time (Error e)
  | Ok task_id ->
  let result =
    Workspace.claim_task_r ctx.config ~agent_name:ctx.agent_name ~task_id ()
  in
  (match result with
   | Ok outcome ->
       sync_owner_current_task_binding ctx;
       sync_planning_current_task_with_owned_task ctx;
       (* Issue #18839: surface auto-released task IDs to subscribers so an
          MCP operator (or agent consuming the event stream) can react
          to an implicit hot-potato instead of substring-parsing
          ["… (auto-released X, Y)"] out of the response message. Empty
          list when the claim did not displace any prior holding. *)
       let auto_released_json =
         `List (List.map (fun id -> `String id) outcome.Workspace.auto_released_task_ids)
       in
        (Atomic.get push_event_to_sessions_fn) (`Assoc [
          ("type", `String "masc/task_claimed");
          ("task_id", `String task_id);
          ("agent_name", `String ctx.agent_name);
          ("auto_released_task_ids", auto_released_json);
          ("timestamp", `Float (Time_compat.now ()));
        ])
   | Error e -> task_log_warn ~task_id "task claim failed for %s: %s" task_id (Masc_domain.masc_error_to_string e));
  let response_result =
    Result.map (fun (o : Workspace.claim_outcome) -> o.message) result
  in
  result_to_response ~tool_name ~start_time response_result

(* Look up the current Goal_store phase for each goal id in the agent's
   active_goal_ids. Returns a list of "<goal_id>=<phase>" strings, e.g.
   ["goal-1777967605002-004b=executing"; "goal-other=completed"].

   This is consumed only by [format_no_eligible] below, to give the LLM
   the *current* goal phase instead of letting it infer "completed goal"
   from the bare excluded_count. See PR body for the velvet-hammer
   misdiagnosis that motivated this surface. *)
let active_goal_phases_for_agent ctx =
  (current_task_owner_hooks ()).active_goal_phases_for_agent
    ctx.config
    ~agent_name:ctx.agent_name

let no_eligible_diagnostics_json =
  Tool_task_no_eligible.no_eligible_diagnostics_json
let no_eligible_blocker_summary =
  Tool_task_no_eligible.no_eligible_blocker_summary

let format_no_eligible
      ctx
      ~excluded_count
      ~blocked_count
      ~verification_blocked_count
      ~scope_excluded_count
  =
  let diagnostics =
    no_eligible_blocker_summary
      ~blocked_count
      ~verification_blocked_count
      ~scope_excluded_count
  in
  match active_goal_phases_for_agent ctx with
  | [] ->
      Printf.sprintf
        "No eligible tasks available (blocked/excluded: %d). This agent has no \
         active_goal_ids — every open task is out of scope. Operator should \
         configure active_goal_ids via the owner runtime. %s"
        excluded_count
        diagnostics
  | phases ->
      Printf.sprintf
        "No eligible tasks available (blocked/excluded: %d). active goal \
         phases: [%s]. NOTE: excluded ≠ completed. If every phase above is \
         'executing', the cause is goal-scope mismatch — open tasks are \
         scoped to a goal not in this agent's active_goal_ids — not goal \
         completion. %s"
        excluded_count
        (String.concat ", " phases)
        diagnostics

let handle_claim_next ~tool_name ~start_time ctx _args =
  (* #18965 — removed [is_agent_session_bound] hard gate (same rationale as
     [handle_claim] above).  Workspace.claim_next_r operates on
     [~agent_name] alone; backlog read does not require an entry under
     agents_dir. *)
  let result = Workspace.claim_next_r ctx.config ~agent_name:ctx.agent_name () in
  match result with
  | Workspace.Claim_next_claimed { message; task_id; scope_widened } ->
    sync_owner_current_task_binding ctx;
    sync_planning_current_task_with_owned_task ctx;
    append_claim_observation message ~now:(Time_compat.now ())
      ~agent_name:ctx.agent_name ~task_id ~scope_widened
    |> Tool_result.ok ~tool_name ~start_time
  | Workspace.Claim_next_no_unclaimed ->
    Tool_result.ok ~tool_name ~start_time "No unclaimed tasks available"
  | Workspace.Claim_next_no_eligible
      { excluded_count
      ; blocked_count
      ; verification_blocked_count
      ; scope_excluded_count
      ; explicit_excluded_count
      ; claim_pool_candidate_count
      } ->
    let message =
      format_no_eligible
        ctx
        ~excluded_count
        ~blocked_count
        ~verification_blocked_count
        ~scope_excluded_count
    in
    let diagnostics =
      no_eligible_diagnostics_json
        ~excluded_count
        ~blocked_count
        ~verification_blocked_count
        ~scope_excluded_count
        ~explicit_excluded_count
        ~claim_pool_candidate_count
    in
    (* #18954: build the structured payload directly via [make_ok ~data]
       so the message and diagnostics live in the JSON [data] field.
       The previous form [Tool_result.ok (message ^ "\n" ^ payload)]
       routed through [structured_payload_of_message], which parsed the
       trailing JSON object out and discarded the prefix line — leaving
       [Tool_result.message] able to round-trip only the JSON, not the
       human-readable lead.  LLM/JSON consumers still see the message
       inside the JSON [.message] field; we keep the same Assoc shape
       that callers already inspect. *)
    let data =
      `Assoc [ "message", `String message; "diagnostics", diagnostics ]
    in
    Tool_result.make_ok ~tool_name ~start_time ~data ()
  | Workspace.Claim_next_error e ->
    (* RFC-0189: Claim_next_error wraps workspace-side reasons like
       "no claimable task", "agent not allowed", "permission denied"
       — all caller-actionable. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      (Printf.sprintf "Error: %s" e)

let handle_release ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response ~tool_name ~start_time (Error e)
  | Ok task_id ->
  let expected_version = get_int_opt args "expected_version" in
  let tasks = Workspace.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks in
  let handoff_context =
    parse_handoff_context ~agent_name:ctx.agent_name
      ~action:Masc_domain.Release args
  in
  (match handoff_context with
   | Error error ->
       (* RFC-0189: handoff_context parse error from caller payload. *)
       Tool_result.error
         ~failure_class:(Some Tool_result.Workflow_rejection)
         ~tool_name ~start_time error
   | Ok handoff_context ->
       if strict_release_requires_handoff task_opt && Option.is_none handoff_context
       then
         Tool_result.error
           ~failure_class:(Some Tool_result.Workflow_rejection)
           ~tool_name ~start_time
           "Strict task release requires handoff_context.summary"
       else
         let result =
           Workspace.release_task_r ctx.config ~agent_name:ctx.agent_name ~task_id
             ?expected_version ?handoff_context ()
         in
         (match result with
          | Ok _ ->
            sync_owner_current_task_binding ctx;
            sync_planning_current_task_with_owned_task ctx
          | Error _ -> ());
         result_to_response ~tool_name ~start_time result)

let transition_known_args =
  [
    "task_id";
    "action";
    "notes";
    "reason";
    "expected_version";
    "agent_name";
    "force";
    "completion_contract";
    "evaluator_runtime";
    "handoff_context";
    "evidence_refs";
  ]
