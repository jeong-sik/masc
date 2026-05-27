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

(** Tool_task - Core task CRUD operations

    Handles: add_task, batch_add_tasks, cancel_task, claim, claim_next,
    done, release, task_history, tasks, transition, update_priority, archive_view
*)

open Yojson.Safe.Util

type context = {
  config: Coord.config;
  agent_name: string;
  sw: Eio.Switch.t option;
}

open Tool_args

(* RFC-0189: [Masc_domain] backend Error variants (Task_error /
   Agent_error / etc.) currently surface as caller-actionable
   workflow violations ("task not found", "invalid transition",
   "agent not in room") rather than transient/runtime failures.
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

let json_string_opt = function
  | None -> `Null
  | Some value -> `String value

let json_float_opt = function
  | None -> `Null
  | Some value -> `Float value

let claim_next_transient_error_data err =
  match err with
  | Masc_domain.System
      (Masc_domain.System_error.LockContention
         { key; attempts; owner; acquired_at; expires_at }) ->
    `Assoc
      [ "error_kind", `String "distributed_lock_contention"
      ; "retryable", `Bool true
      ; "retry_after_ms", `Int 1000
      ; "lock_key", `String key
      ; "attempts", `Int attempts
      ; "holder_owner", json_string_opt owner
      ; "holder_acquired_at_unix", json_float_opt acquired_at
      ; "holder_expires_at_unix", json_float_opt expires_at
      ]
  | _ ->
    `Assoc
      [ "error_kind", `String "transient_claim_next_error"
      ; "retryable", `Bool true
      ; "retry_after_ms", `Int 1000
      ]

let claim_next_transient_error_response ~tool_name ~start_time err =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Transient_error
    ~start_time
    ~data:(claim_next_transient_error_data err)
    (Printf.sprintf "Error: %s" (Masc_domain.masc_error_to_string err))

let log_task_transition_failed ~agent_name err =
  let message = Masc_domain.masc_error_to_string err in
  match err with
  | Masc_domain.Task (Masc_domain.Task_error.InvalidState _) ->
      Log.Task.warn ~keeper_name:agent_name "task transition failed: %s" message
  | _ -> Log.Task.error ~keeper_name:agent_name "task transition failed: %s" message

(** Client-side FSM gate: reject impossible transitions before server dispatch.
    Uses [Coord_task_classify.valid_next_actions_for_status] as SSOT. *)
let client_side_transition_gate_error ~task_opt ~action ~action_s =
  match task_opt with
  | None -> None
  | Some (task : Masc_domain.task) ->
    let valid_actions = Coord_task_classify.valid_next_actions_for_status task.task_status in
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

let is_registered_keeper_agent_alias_name config agent_name =
  let agent_name = String.trim agent_name in
  let keeper_name_variants keeper_name =
    let map_sep ~from_ch ~to_ch value =
      String.map (fun c -> if Char.equal c from_ch then to_ch else c) value
    in
    let separator_variants value =
      Json_util.dedupe_keep_order
        [
          value;
          map_sep ~from_ch:('_') ~to_ch:('-') value;
          map_sep ~from_ch:('-') ~to_ch:('_') value;
        ]
    in
    let generated_type_variants value =
      if Nickname.is_dictionary_generated_nickname value then
        match Nickname.extract_agent_type value with
        | Some agent_type when Keeper_config.validate_name agent_type ->
            separator_variants agent_type
        | _ -> []
      else []
    in
    let base_variants = separator_variants keeper_name in
    Json_util.dedupe_keep_order
      (base_variants @ List.concat_map generated_type_variants base_variants)
  in
  let registered_keeper_name keeper_name =
    keeper_name_variants keeper_name
    |> List.exists (fun name ->
           Option.is_some
             (Keeper_registry.get ~base_path:config.Coord.base_path name))
  in
  match Keeper_identity.canonical_keeper_name_from_agent_name agent_name with
  | Some keeper_name ->
      Keeper_identity.is_keeper_agent_alias agent_name
      && registered_keeper_name keeper_name
  | None -> false

let sync_planning_current_task_with_owned_task (ctx : context) =
  let actual_name =
    (* Asymmetric silent-failure unification: previously [Sys_error _ |
       Yojson.Json_error _] (the *more common* read-side failure class —
       missing agents file, malformed JSON) returned [ctx.agent_name]
       silently while only the rare [exn] catch-all logged. Operators
       saw the loud path but missed the common one. Single warn arm
       mirrors [Tool_coord.safe_read_backlog]. *)
    try Coord.resolve_agent_name ctx.config ctx.agent_name with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Task.warn "resolve_agent_name failed for %s: %s" ctx.agent_name
          (Stdlib.Printexc.to_string exn);
        ctx.agent_name
  in
  if
    is_registered_keeper_agent_alias_name ctx.config ctx.agent_name
    || is_registered_keeper_agent_alias_name ctx.config actual_name
  then ()
  else
    let matches_you assignee =
      String.equal assignee ctx.agent_name || String.equal assignee actual_name
    in
    let owned_task =
      Coord.get_tasks_raw ctx.config
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
             Log.Task.warn ~keeper_name:task_id
               "failed to sync planning current_task to %s: %s"
               task_id msg)
    | None -> Planning_eio.clear_current_task ctx.config

let sync_keeper_current_task_binding (ctx : context) =
  Keeper_current_task_reconcile.sync_current_task_id_for_agent_name
    ~config:ctx.config ~agent_name:ctx.agent_name

let keeper_agent_tool_names (ctx : context) =
  let resolved =
    try Coord.resolve_agent_name ctx.config ctx.agent_name with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Task.warn "resolve_agent_name failed for keeper tool surface %s: %s"
          ctx.agent_name
          (Stdlib.Printexc.to_string exn);
        ctx.agent_name
  in
  [ ctx.agent_name; resolved ]
  |> List.filter_map Keeper_identity.canonical_keeper_name
  |> List.sort_uniq String.compare
  |> List.find_map (fun keeper_name ->
       match Keeper_registry.get ~base_path:ctx.config.base_path keeper_name with
       | Some entry -> Some (Keeper_tool_policy.keeper_allowed_tool_names entry.meta)
       | None -> None)

let review_completion_notes
    ~(completion_contract : string list option)
    ~(evaluator_cascade : string option)
    ~(ctx : context)
    ~(task_opt : Masc_domain.task option)
    ~(task_id : string)
    ~(notes : string) : string option =
  match task_opt with
  | None -> None
  | Some task ->
      let ar_req : Anti_rationalization.review_request = {
        task_title = task.title;
        task_description = task.description;
        completion_notes = notes;
        agent_name = ctx.agent_name;
      } in
      let on_verdict result =
        Eval_calibration.record_verdict
          ~task_id ~req:ar_req ~result ();
        (try
           Sse.broadcast
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
      let few_shot_block =
        Eval_calibration.format_few_shot_block
          (Eval_calibration.select_examples ~max_examples:3)
      in
      match (Anti_rationalization.review
         ?sw:ctx.sw
         ?evaluator_cascade
         ?completion_contract
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
  let valid_keys = [ "title"; "priority"; "description"; "goal_id"; "contract" ] in
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
        Tool_result.ok ~tool_name ~start_time
          (Coord.add_task ?contract ?goal_id
            ~reject_if:(Coord_task_capacity.rejection_for_add_task ?goal_id)
            ~created_by:ctx.agent_name ctx.config ~title:trimmed_title
            ~priority ~description)

let handle_batch_add_tasks ~tool_name ~start_time ctx args =
  let tasks_json = match args |> member "tasks" with
    | `List l -> l
    | _ -> []
  in
  if Stdlib.List.length tasks_json = 0 then
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      "tasks array is empty or missing"
  else
  let validated = List.mapi (fun idx t ->
    let title = String.trim (t |> member "title" |> to_string) in
    let priority = t |> member "priority" |> to_int_option |> Option.value ~default:3 in
    let description = t |> member "description" |> to_string_option |> Option.value ~default:"" in
    let goal_id =
      match t |> member "goal_id" |> to_string_option with
      | Some s when not (String.equal (String.trim s) "") -> Some (String.trim s)
      | _ -> None
    in
    let contract =
      match t |> member "contract" with
      | `Null -> Ok None
      | (`Assoc _ as json) -> (
          match Masc_domain.task_contract_of_yojson json with
          | Ok contract -> Ok (Some contract)
          | Error error ->
              Error
                (Printf.sprintf "item[%d]: invalid contract payload: %s" idx
                   error))
      | _ -> Error (Printf.sprintf "item[%d]: contract must be an object" idx)
    in
    if String.equal title "" then
      Error (Printf.sprintf "item[%d]: title cannot be empty" idx)
    else if priority < 1 || priority > 5 then
      Error (Printf.sprintf "item[%d]: priority must be 1-5, got %d" idx priority)
    else
      match contract with
      | Ok contract ->
          let has_removed_field name =
            match t |> member name with
            | `Null -> false
            | _ -> true
          in
          if has_removed_field "required_preset" then
            Error (Printf.sprintf "item[%d]: required_preset is no longer supported" idx)
          else if has_removed_field "required_role" then
            Error (Printf.sprintf "item[%d]: required_role is no longer supported" idx)
          else if has_removed_field "required_verifier_role" then
            Error
              (Printf.sprintf "item[%d]: required_verifier_role is no longer supported" idx)
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
    Tool_result.ok ~tool_name ~start_time (Coord.batch_add_tasks_with_contracts
      ~created_by:ctx.agent_name ctx.config tasks)

let handle_claim ?agent_tool_names ~tool_name ~start_time ctx args =
  (* #18965 — removed [is_agent_joined] hard gate.  Keeper-internal tag
     dispatch path bypasses MCP entry auto-join, so this gate produced
     false-negative rejects for every keeper turn (fleet evidence:
     ~/.masc/agents/ empty while keepers run normally; only
     masc_claim/masc_claim_next failed).  Coord.claim_task_r works on
     agent_name alone; gate added no real authorization. *)
  if not ((=) (args |> member "agent_role") `Null) then
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      "agent_role is no longer supported"
  else
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response ~tool_name ~start_time (Error e)
  | Ok task_id ->
  let agent_tool_names =
    match agent_tool_names with
    | Some _ -> agent_tool_names
    | None -> keeper_agent_tool_names ctx
  in
  let result =
    Coord.claim_task_r ctx.config ~agent_name:ctx.agent_name ~task_id
      ?agent_tool_names ()
  in
  (match result with
   | Ok _ ->
       sync_keeper_current_task_binding ctx;
       sync_planning_current_task_with_owned_task ctx;
       Subscriptions.push_event_to_sessions (`Assoc [
         ("type", `String "masc/task_claimed");
         ("task_id", `String task_id);
         ("agent_name", `String ctx.agent_name);
         ("timestamp", `Float (Time_compat.now ()));
       ])
   | Error e -> Log.Task.warn ~keeper_name:task_id "task claim failed for %s: %s" task_id (Masc_domain.masc_error_to_string e));
  result_to_response ~tool_name ~start_time result

(* Look up the current Goal_store phase for each goal id in the agent's
   active_goal_ids. Returns a list of "<goal_id>=<phase>" strings, e.g.
   ["goal-1777967605002-004b=executing"; "goal-other=completed"].

   This is consumed only by [format_no_eligible] below, to give the LLM
   the *current* goal phase instead of letting it infer "completed goal"
   from the bare excluded_count. See PR body for the velvet-hammer
   misdiagnosis that motivated this surface. *)
let active_goal_phases_for_agent ctx =
  match Keeper_types.read_meta_resolved ctx.config ctx.agent_name with
  | Ok (Some (_, meta)) ->
      List.map
        (fun goal_id ->
           match Goal_store.get_goal ctx.config ~goal_id with
           | Some goal ->
               Printf.sprintf "%s=%s" goal_id (Goal_phase.to_string goal.phase)
           | None -> Printf.sprintf "%s=missing" goal_id)
        meta.active_goal_ids
  | Ok None | Error _ -> []

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
      ~required_tool_excluded_count
  =
  let diagnostics =
    no_eligible_blocker_summary
      ~blocked_count
      ~verification_blocked_count
      ~scope_excluded_count
      ~required_tool_excluded_count
  in
  match active_goal_phases_for_agent ctx with
  | [] ->
      Printf.sprintf
        "No eligible tasks available (blocked/excluded: %d). This agent has no \
         active_goal_ids — every open task is out of scope. Operator should \
         set active_goal_ids via masc_keeper_up. %s"
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

let handle_claim_next ?agent_tool_names ~tool_name ~start_time ctx _args =
  (* #18965 — removed [is_agent_joined] hard gate (same rationale as
     [handle_claim] above).  Coord.claim_next_r operates on
     [~agent_name] alone; backlog read does not require an entry under
     agents_dir. *)
  let agent_tool_names =
    match agent_tool_names with
    | Some _ -> agent_tool_names
    | None -> keeper_agent_tool_names ctx
  in
  let result =
    Coord.claim_next_r ctx.config ~agent_name:ctx.agent_name ?agent_tool_names ()
  in
  match result with
  | Coord.Claim_next_claimed { message; task_id; _ } ->
    sync_keeper_current_task_binding ctx;
    sync_planning_current_task_with_owned_task ctx;
    append_claim_observation message ~now:(Time_compat.now ())
      ~agent_name:ctx.agent_name ~task_id
    |> Tool_result.ok ~tool_name ~start_time
  | Coord.Claim_next_no_unclaimed ->
    Tool_result.ok ~tool_name ~start_time "No unclaimed tasks available"
  | Coord.Claim_next_no_eligible
      { excluded_count
      ; blocked_count
      ; verification_blocked_count
      ; scope_excluded_count
      ; required_tool_excluded_count
      ; explicit_excluded_count
      ; claim_pool_candidate_count
      ; receipt_required_tool_blocked
      ; agent_tool_names_known
      } ->
    let message =
      format_no_eligible
        ctx
        ~excluded_count
        ~blocked_count
        ~verification_blocked_count
        ~scope_excluded_count
        ~required_tool_excluded_count
    in
    let diagnostics =
      no_eligible_diagnostics_json
        ~excluded_count
        ~blocked_count
        ~verification_blocked_count
        ~scope_excluded_count
        ~required_tool_excluded_count
        ~explicit_excluded_count
        ~claim_pool_candidate_count
        ~receipt_required_tool_blocked
        ~agent_tool_names_known
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
  | Coord.Claim_next_error e ->
    (* RFC-0189: Claim_next_error wraps coord-side reasons like
       "no claimable task", "agent not allowed", "permission denied"
       — all caller-actionable. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      (Printf.sprintf "Error: %s" e)
  | Coord.Claim_next_transient_error err ->
    claim_next_transient_error_response ~tool_name ~start_time err

let handle_release ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response ~tool_name ~start_time (Error e)
  | Ok task_id ->
  let expected_version = get_int_opt args "expected_version" in
  let tasks = Coord.get_tasks_raw ctx.config in
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
           Coord.release_task_r ctx.config ~agent_name:ctx.agent_name ~task_id
             ?expected_version ?handoff_context ()
         in
         (match result with
          | Ok _ ->
            sync_keeper_current_task_binding ctx;
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
    "evaluator_cascade";
    "handoff_context";
  ]
