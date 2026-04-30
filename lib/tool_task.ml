(** Tool_task - Core task CRUD operations

    Handles: add_task, batch_add_tasks, cancel_task, claim, claim_next,
    done, release, task_history, tasks, transition, update_priority, archive_view
*)

open Yojson.Safe.Util

type tool_result = bool * string

type context = {
  config: Coord.config;
  agent_name: string;
  sw: Eio.Switch.t option;
}

open Tool_args

let result_to_response = function
  | Ok msg -> (true, msg)
  | Error e -> (false, Types.masc_error_to_string e)

let build_claim_observation_payload ~(now : float) ~(agent_name : string)
    ~(task_id : string) : Yojson.Safe.t =
  `Assoc
    [
      ("event_type", `String "collaboration.todo.claim_observed");
      ("observed_at", `Float now);
      ( "substrate",
        `Assoc
          [
            ("kind", `String "todo_claim");
            ("provider", `String "masc.coord");
            ("workspace_id", `Null);
          ] );
      ( "actor",
        `Assoc
          [
            ("id", `String agent_name);
            ("role", `Null);
            ("display_name", `Null);
          ] );
      ( "todo_claim",
        `Assoc
          [
            ("todo_id", `String task_id);
            ("state", `String "claim_verified");
            ("claimed_by", `String agent_name);
            ("winner_actor_id", `String agent_name);
            ("logical_clock", `Null);
            ("convergence_delay_ms", `Null);
          ] );
    ]

let append_claim_observation message ~now ~agent_name ~task_id =
  let payload = build_claim_observation_payload ~now ~agent_name ~task_id in
  message ^ "\nclaim_observation=" ^ Yojson.Safe.to_string payload

let verdict_to_string (result : Anti_rationalization.review_result) =
  match result.verdict with
  | Anti_rationalization.Approve -> "approve"
  | Anti_rationalization.Reject reason -> "reject:" ^ reason

(** True when both cascades are non-empty AND distinct.

    Must match {!Eval_calibration.calibration_stats} inclusion criteria
    exactly (both [evaluator_cascade <> ""] and [generator_cascade <> ""])
    so that a real-time SSE event and the aggregated cross_model_rate
    agree on which verdicts count as cross-model. *)
let is_cross_model_verdict (result : Anti_rationalization.review_result) : bool =
  match result.generator_cascade with
  | None -> false
  | Some g ->
    g <> ""
    && result.evaluator_cascade <> ""
    && not (String.equal g result.evaluator_cascade)

(** Build the [verdict_recorded] SSE payload for a finished review.

    Pure function: no IO, no broadcast, no logging. Extracted so the
    payload contract can be exercised by unit tests. *)
let build_verdict_sse_payload
    ~(now : float)
    ~(task_id : string)
    ~(req : Anti_rationalization.review_request)
    ~(result : Anti_rationalization.review_result) : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "oas:masc:harness:verdict_recorded");
      ( "payload",
        `Assoc
          [
            ("timestamp", `Float now);
            ("task_id", `String task_id);
            ("task_title", `String req.task_title);
            ("agent_name", `String req.agent_name);
            ("gate", `String (Anti_rationalization.gate_to_string result.gate));
            ("verdict", `String (verdict_to_string result));
            ("evaluator_cascade", `String result.evaluator_cascade);
            ( "generator_cascade",
              match result.generator_cascade with
              | Some c -> `String c
              | None -> `Null );
            ("cross_model", `Bool (is_cross_model_verdict result));
            ( "fallback_reason",
              match result.fallback_reason with
              | Some reason -> `String reason
              | None -> `Null );
          ] );
    ]

(** Validate task_id is non-empty. Prevents phantom operations on empty IDs. *)
let validate_task_id task_id =
  if task_id = "" then Error (Types.TaskNotFound "")
  else Ok task_id

let sync_planning_current_task_with_owned_task (ctx : context) =
  let actual_name =
    try Coord.resolve_agent_name ctx.config ctx.agent_name
    with
    | Sys_error _ | Yojson.Json_error _ -> ctx.agent_name
    | exn ->
        Log.Task.warn "resolve_agent_name failed for %s: %s" ctx.agent_name
          (Printexc.to_string exn);
        ctx.agent_name
  in
  let matches_you assignee =
    String.equal assignee ctx.agent_name || String.equal assignee actual_name
  in
  let owned_task =
    Coord.get_tasks_raw ctx.config
    |> List.find_map (fun (task : Types.task) ->
           match task.task_status with
           | Types.Claimed { assignee; _ }
           | Types.InProgress { assignee; _ } ->
               if matches_you assignee then Some task.id else None
           | Types.Todo
           | Types.AwaitingVerification _
           | Types.Done _
           | Types.Cancelled _ -> None)
  in
  match owned_task with
  | Some task_id -> Planning_eio.set_current_task ctx.config ~task_id
  | None -> Planning_eio.clear_current_task ctx.config

let sync_keeper_current_task_binding (ctx : context) =
  Keeper_current_task_reconcile.sync_current_task_id_for_agent_name
    ~config:ctx.config ~agent_name:ctx.agent_name

let keeper_agent_tool_names (ctx : context) =
  let resolved =
    try Coord.resolve_agent_name ctx.config ctx.agent_name
    with
    | Sys_error _ | Yojson.Json_error _ -> ctx.agent_name
    | exn ->
        Log.Task.warn "resolve_agent_name failed for keeper tool surface %s: %s"
          ctx.agent_name
          (Printexc.to_string exn);
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
    ~(task_opt : Types.task option)
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
              (Printexc.to_string exn))
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

let can_review_completion ~(task_opt : Types.task option) ~(agent_name : string) =
  match task_opt with
  | Some task ->
      (match task.task_status with
       | Types.Claimed { assignee; _ }
       | Types.InProgress { assignee; _ } ->
           String.equal assignee agent_name
       | Types.Todo
       | Types.AwaitingVerification _
       | Types.Done _
       | Types.Cancelled _ -> false)
  | None -> false

let persisted_completion_contract ~(task_opt : Types.task option) =
  match task_opt with
  | Some ({ contract = Some contract; _ } : Types.task)
    when contract.completion_contract <> [] ->
      Some contract.completion_contract
  | _ -> None

(* Concrete example handed to the keeper when the anti-rationalization
   gate rejects a completion. Prior form said only "describe actual
   work"; small-LLM keepers retried the same perfunctory notes
   (37 Tool_task completion rejects observed on 2026-04-17/18 in
   ~/me/.masc/tool_calls). The example shows the expected density:
   what changed, which files, what verification ran. See #8688. *)
let completion_notes_example =
  "Example of accepted notes: 'Added Event_kind.Board variant to \
   lib/coord/event_kind.{ml,mli}, migrated 8 call-sites in \
   coord_task.ml and activity_graph.ml, test_event_kind round-trip \
   green, CI green on PR #NNNN.'"

let completion_rejection_message ?(allow_force = false) reason =
  if allow_force then
    Printf.sprintf
      "Completion rejected by anti-rationalization gate: %s\n\
       Revise your completion notes to describe actual work, then retry.\n\
       %s\n\
       Use force=true to override (operator only)." reason completion_notes_example
  else
    Printf.sprintf
      "Completion rejected by anti-rationalization gate: %s\n\
       Revise your completion notes to describe actual work, then retry.\n\
       %s" reason completion_notes_example

let parse_task_contract args =
  match args |> member "contract" with
  | `Null -> Ok None
  | (`Assoc _ as json) -> (
      match Types.task_contract_of_yojson json with
      | Ok contract -> Ok (Some contract)
      | Error error ->
          Error
            (Printf.sprintf "Invalid contract payload: %s" error))
  | _ -> Error "contract must be an object when provided"

let is_internal_marker key =
  String.length key > 0 && key.[0] = '_'

let unknown_args ~valid_keys args =
  match args with
  | `Assoc kvs ->
      kvs
      |> List.filter (fun (key, _) ->
             (not (is_internal_marker key)) && not (List.mem key valid_keys))
      |> List.map fst
  | _ -> []

(* Synthesize a summary from sibling [notes] / [reason] transition args
   when [handoff_context.summary] is empty. Keeper LLMs frequently send
   a non-empty [reason] or [notes] but forget the nested summary field —
   rejecting the call in that case burned 76/132 masc_transition calls
   on 2026-04-17/18 (see memory/handoff-2026-04-18-masc-tool-failure-
   investigation.md). Prefer [notes] when present (it's the canonical
   done-note) then fall back to [reason] (release blocker note). Truncate
   to keep the synthesized summary single-line. *)
let synthesize_summary_from_siblings args =
  let pick key =
    match args |> member key with
    | `String s ->
        let trimmed = String.trim s in
        if trimmed = "" then None else Some trimmed
    | _ -> None
  in
  let first_line s =
    match String.index_opt s '\n' with
    | Some i -> String.sub s 0 i
    | None -> s
  in
  let truncate ~max_len s =
    if String.length s <= max_len then s
    else String.sub s 0 max_len ^ "…"
  in
  match pick "notes" with
  | Some s -> Some (truncate ~max_len:240 (first_line s))
  | None ->
      match pick "reason" with
      | Some s -> Some (truncate ~max_len:240 (first_line s))
      | None -> None

let parse_handoff_context ~(agent_name : string) args =
  match args |> member "handoff_context" with
  | `Null -> Ok None
  | (`Assoc _ as json) -> (
      match Types.task_handoff_context_of_yojson json with
      | Error error ->
          Error
            (Printf.sprintf "Invalid handoff_context payload: %s" error)
      | Ok handoff_context ->
          let summary = String.trim handoff_context.summary in
          let summary =
            if summary = "" then
              Option.value ~default:"" (synthesize_summary_from_siblings args)
            else summary
          in
          if summary = "" then
            Error
              "handoff_context.summary is required (non-empty string). \
               Example: {\"summary\": \"tests green, PR #123 pending review\", \
               \"next_step\": \"wait for CI\", \"evidence_refs\": [\"PR#123\"]}. \
               Alternatively pass a non-empty top-level 'notes' or 'reason' \
               and it will be synthesized into summary automatically."
          else
            Ok
              (Some
                 {
                   handoff_context with
                   summary;
                   evidence_refs =
                     List.sort_uniq String.compare handoff_context.evidence_refs;
                   updated_at = Some (Types.now_iso ());
                   updated_by = Some agent_name;
                 }))
  | _ -> Error "handoff_context must be an object when provided"

let task_has_persisted_contract = function
  | Some (task : Types.task) -> Option.is_some task.contract
  | None -> false

let strict_release_requires_handoff = function
  | Some ({ contract = Some contract; _ } : Types.task) -> contract.strict
  | _ -> false

let completion_state_error ~(task_id : string) ~(agent_name : string)
    ~(task_opt : Types.task option) =
  match task_opt with
  | None -> Some (Types.TaskNotFound task_id)
  | Some task ->
    match task.task_status with
    | Types.Claimed { assignee; _ } | Types.InProgress { assignee; _ } ->
      if String.equal assignee agent_name then
        None
      else
        Some (Types.TaskAlreadyClaimed { task_id; by = assignee })
    | Types.Todo -> Some (Types.TaskNotClaimed task_id)
    | Types.Done { assignee; _ } ->
      Some
        (Types.TaskInvalidState
           (Printf.sprintf
              "task %s is already done by %s; inspect task history instead of calling masc_transition(action=done) again"
              task_id assignee))
    | Types.Cancelled { cancelled_by; _ } ->
      Some
        (Types.TaskInvalidState
           (Printf.sprintf
              "task %s was cancelled by %s; reopen or create a new task instead of calling masc_transition(action=done)"
              task_id cancelled_by))
    | Types.AwaitingVerification { assignee; _ } ->
      Some
        (Types.TaskInvalidState
           (Printf.sprintf
              "task %s is awaiting verification by %s; approve or reject before marking done"
              task_id assignee))

let persisted_contract_rejection ~(ctx : context)
    ~(task_opt : Types.task option) ~(notes : string) =
  ignore notes;
  match task_opt with
  | None -> None
  | Some task ->
    if not (Env_config_runtime.Cdal.gate_enabled ()) then begin
      Log.Task.info "[cdal-gate] disabled, skipping for task=%s agent=%s"
        task.id ctx.agent_name;
      None
    end else
      match task.contract with
      | None -> None
      | Some contract ->
        (* Always run the verdict lookup so Dashboard_attribution records the
           outcome (pass / policy_failed / missing). strict=false stays
           advisory — we drop the rejection but keep the audit trail so the
           dashboard shows a verification trace instead of nothing.

           Advisory recordings go into the [cdal_verdict_advisory] gate
           bucket so the dashboard can distinguish "strict-enforced"
           from "allowed through under advisory" without guessing. *)
        let gate_label =
          if contract.strict then Cdal_verdict_gate.strict_gate_label
          else Cdal_verdict_gate.advisory_gate_label
        in
        Log.Task.info
          "[cdal-gate] checking verdict for task=%s agent=%s strict=%b gate=%s"
          task.id ctx.agent_name contract.strict gate_label;
        let rejection =
          Cdal_verdict_gate.gate_check ~gate_label ~task_id:task.id ()
        in
        if contract.strict then rejection
        else begin
          (match rejection with
           | Some msg ->
             Log.Task.info
               "[cdal-gate] advisory (strict=false) for task=%s: %s"
               task.id msg
           | None -> ());
          None
        end

(* Handlers *)

let handle_add_task ctx args =
  let valid_keys = [ "title"; "priority"; "description"; "goal_id"; "contract" ] in
  let unknown = unknown_args ~valid_keys args in
  if unknown <> [] then
    ( false
    , Printf.sprintf
        "Unknown argument(s): %s. Valid: %s"
        (String.concat ", " unknown)
        (String.concat ", " valid_keys) )
  else
  let title = get_string args "title" "" in
  let priority = get_int args "priority" 3 in
  let description = get_string args "description" "" in
  let goal_id =
    match Safe_ops.json_string_opt "goal_id" args with
    | Some s when String.trim s <> "" -> Some (String.trim s)
    | _ -> None
  in
  let contract_result = parse_task_contract args in
  (* BUG-009/010: Validate title and priority *)
  let trimmed_title = String.trim title in
  if trimmed_title = "" then
    (false, "Task title cannot be empty or whitespace-only")
  else if priority < 1 || priority > 5 then
    (false, Printf.sprintf "Priority must be between 1 and 5, got %d" priority)
  else if Option.is_some goal_id
          && not
               (Goal_store.list_goals ctx.config ()
                |> List.exists (fun (goal : Goal_store.goal) ->
                       String.equal goal.id (Option.value ~default:"" goal_id)))
  then
    (false, Printf.sprintf "Unknown goal_id '%s'" (Option.value ~default:"" goal_id))
  else
    match contract_result with
    | Error error -> (false, error)
    | Ok contract ->
        ( true,
          Coord.add_task ?contract ?goal_id
            ~created_by:ctx.agent_name ctx.config ~title:trimmed_title
            ~priority ~description )

let handle_batch_add_tasks ctx args =
  let tasks_json = match args |> member "tasks" with
    | `List l -> l
    | _ -> []
  in
  if tasks_json = [] then
    (false, "tasks array is empty or missing")
  else
  let validated = List.mapi (fun idx t ->
    let title = String.trim (t |> member "title" |> to_string) in
    let priority = t |> member "priority" |> to_int_option |> Option.value ~default:3 in
    let description = t |> member "description" |> to_string_option |> Option.value ~default:"" in
    let goal_id =
      match t |> member "goal_id" |> to_string_option with
      | Some s when String.trim s <> "" -> Some (String.trim s)
      | _ -> None
    in
    let contract =
      match t |> member "contract" with
      | `Null -> Ok None
      | (`Assoc _ as json) -> (
          match Types.task_contract_of_yojson json with
          | Ok contract -> Ok (Some contract)
          | Error error ->
              Error
                (Printf.sprintf "item[%d]: invalid contract payload: %s" idx
                   error))
      | _ -> Error (Printf.sprintf "item[%d]: contract must be an object" idx)
    in
    if title = "" then
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
  if errors <> [] then
    (false, Printf.sprintf "Validation failed:\n%s" (String.concat "\n" errors))
  else
    let tasks =
      List.filter_map (function Ok t -> Some t | Error _ -> None) validated
    in
    (true, Coord.batch_add_tasks_with_contracts
      ~created_by:ctx.agent_name ctx.config tasks)

let handle_claim ?agent_tool_names ctx args =
  if not (try Coord.is_agent_joined ctx.config ~agent_name:ctx.agent_name with Sys_error _ | Not_found -> false) then
    result_to_response (Error (Types.AgentNotJoined ctx.agent_name))
  else if args |> member "agent_role" <> `Null then
    (false, "agent_role is no longer supported")
  else
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response (Error e)
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
   | Error e -> Log.Task.warn "task claim failed for %s: %s" task_id (Types.masc_error_to_string e));
  result_to_response result

let handle_claim_next ?agent_tool_names ctx _args =
  if not (try Coord.is_agent_joined ctx.config ~agent_name:ctx.agent_name with Sys_error _ | Not_found -> false) then
    (false, Printf.sprintf "Agent '%s' is not a member of this room" ctx.agent_name)
  else
  let agent_tool_names =
    match agent_tool_names with
    | Some _ -> agent_tool_names
    | None -> keeper_agent_tool_names ctx
  in
  let result =
    Coord.claim_next_r ctx.config ~agent_name:ctx.agent_name ?agent_tool_names ()
  in
  let message = match result with
    | Coord.Claim_next_claimed { message; task_id; _ } ->
        sync_keeper_current_task_binding ctx;
        sync_planning_current_task_with_owned_task ctx;
        append_claim_observation message ~now:(Time_compat.now ())
          ~agent_name:ctx.agent_name ~task_id
    | Coord.Claim_next_no_unclaimed -> "📋 No unclaimed tasks available"
    | Coord.Claim_next_no_eligible { excluded_count; _ } ->
        Printf.sprintf "📋 No eligible tasks available (blocked/excluded: %d)" excluded_count
    | Coord.Claim_next_error e -> Printf.sprintf "❌ Error: %s" e
  in
  (true, message)

let handle_release ctx args =
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response (Error e)
  | Ok task_id ->
  let expected_version = get_int_opt args "expected_version" in
  let tasks = Coord.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Types.task) -> t.id = task_id) tasks in
  let handoff_context = parse_handoff_context ~agent_name:ctx.agent_name args in
  (match handoff_context with
   | Error error -> (false, error)
   | Ok handoff_context ->
       if strict_release_requires_handoff task_opt && Option.is_none handoff_context
       then
         (false, "Strict task release requires handoff_context.summary")
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
         result_to_response result)

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

let rec handle_done ctx args =
  let notes = get_string args "notes" "" in
  handle_transition ctx
    (`Assoc
       [
         ("task_id", args |> member "task_id");
         ("action", `String "done");
         ("notes", `String notes);
       ])

and handle_cancel_task ctx args =
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response (Error e)
  | Ok task_id ->
  let reason = get_string args "reason" "" in
  let tasks = Coord.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Types.task) -> t.id = task_id) tasks in
  let started_at_actual = match task_opt with
    | Some t -> (match t.task_status with
        | Types.InProgress { started_at; _ } ->
            Types.parse_iso8601 ~default_time:(Time_compat.now () -. 60.0) started_at
        | Types.Claimed { claimed_at; _ } ->
            Types.parse_iso8601 ~default_time:(Time_compat.now () -. 60.0) claimed_at
        | _ -> Time_compat.now () -. 60.0)
    | None -> Time_compat.now () -. 60.0
  in
  let result = Coord.cancel_task_r ctx.config ~agent_name:ctx.agent_name ~task_id ~reason in
  (* Record failed metric on cancellation *)
  (match result with
   | Ok _ ->
       sync_keeper_current_task_binding ctx;
       sync_planning_current_task_with_owned_task ctx;
       let metric : Metrics_store_eio.task_metric = {
         id = Printf.sprintf "metric-%s-%d" task_id (int_of_float (Time_compat.now () *. 1000.));
         agent_id = ctx.agent_name;
         task_id;
         started_at = started_at_actual;
         completed_at = Some (Time_compat.now ());
         success = false;
         error_message = Some (if reason = "" then "Cancelled" else reason);
         collaborators = [];
         handoff_from = None;
         handoff_to = None;
       } in
       (try let _ = Metrics_store_eio.record ctx.config metric in ()
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Task.error "Metrics_store_eio.record(cancel) failed: %s" (Printexc.to_string exn));
       (* Feed failure into Thompson Sampling quality signal *)
       Thompson_sampling.record_vote ~agent_name:ctx.agent_name ~direction:`Down;
       (* Prometheus: record task failure *)
       Prometheus.record_task_failed ();
       (* Notification harness: push cancel event to all active sessions *)
       Subscriptions.push_event_to_sessions (`Assoc [
         ("type", `String "masc/task_cancelled");
         ("task_id", `String task_id);
         ("agent_name", `String ctx.agent_name);
         ("reason", `String reason);
         ("timestamp", `Float (Time_compat.now ()));
       ])
   | Error err ->
       Log.Task.error "metrics record failed: %s" (Types.masc_error_to_string err));
  result_to_response result

and handle_transition ?agent_tool_names ctx args =
  (* Underscore-prefixed keys (e.g. "_agent_name") are internal protocol markers
     injected by the HTTP transport and dashboard client for identity
     propagation. They are consumed upstream in Agent_identity and must not
     trigger the strict-schema "Unknown argument(s)" rejection here. *)
  let is_internal_marker k =
    String.length k > 0 && k.[0] = '_'
  in
  (* Issue #8312: small LLM keepers and operator UIs frequently send
     - target-state aliases via [to] instead of canonical [action]
     - singular [note] instead of [notes]
     Normalize before strict-schema validation so callers do not have
     to memorize canonical vocabulary. The Variant ([Types.task_action])
     remains the SSOT — only the transport-level keys get rewritten.
     Existing canonical keys are never overridden. *)
  let normalize_args = function
    | `Assoc kvs ->
      let has k = List.exists (fun (k', _) -> String.equal k k') kvs in
      let kvs =
        if has "note" && not (has "notes") then
          List.map (fun (k, v) -> if String.equal k "note" then ("notes", v) else (k, v)) kvs
        else
          List.filter (fun (k, _) -> not (String.equal k "note") || not (has "notes")) kvs
      in
      let kvs =
        if has "to" && not (has "action") then
          List.map (fun (k, v) -> if String.equal k "to" then ("action", v) else (k, v)) kvs
        else
          List.filter (fun (k, _) -> not (String.equal k "to") || not (has "action")) kvs
      in
      let kvs =
        match List.find_opt (fun (k, _) -> String.equal k "pr_url") kvs with
        | Some (_, `String pr_url) when pr_url <> "" ->
            let kvs = List.filter (fun (k, _) -> not (String.equal k "pr_url")) kvs in
            let kvs =
              match List.find_opt (fun (k, _) -> String.equal k "notes") kvs with
              | Some (_, `String notes) ->
                  List.map
                    (fun (k, v) ->
                      if String.equal k "notes"
                      then ("notes", `String (notes ^ "\nPR: " ^ pr_url))
                      else (k, v))
                    kvs
              | _ -> kvs @ [ ("notes", `String ("PR: " ^ pr_url)) ]
            in
            kvs
        | Some _ -> List.filter (fun (k, _) -> not (String.equal k "pr_url")) kvs
        | None -> kvs
      in
      `Assoc kvs
    | other -> other
  in
  let args = normalize_args args in
  let unknown = match args with
    | `Assoc kvs ->
      List.filter
        (fun (k, _) ->
          (not (is_internal_marker k))
          && not (List.mem k transition_known_args))
        kvs
    | _ -> []
  in
  if unknown <> [] then
    let names = String.concat ", " (List.map fst unknown) in
    (false, Printf.sprintf "Unknown argument(s): %s. Valid: %s"
      names (String.concat ", " transition_known_args))
  else
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response (Error e)
  | Ok task_id ->
  let action_raw = get_string args "action" "" in
  if action_raw = "" then
    (false, Printf.sprintf "action is required (%s)" (String.concat ", " Types.valid_task_action_strings))
  else
  match Types.task_action_of_string_lenient action_raw with
  | Error msg -> (false, msg)
  | Ok action ->
  let action_s = Types.task_action_to_string action in
  let notes = get_string args "notes" "" in
  let reason = get_string args "reason" "" in
  let completion_contract =
    match get_string_list args "completion_contract" with
    | [] -> None
    | items -> Some items
  in
  let evaluator_cascade = get_string_opt args "evaluator_cascade" in
  let handoff_context = parse_handoff_context ~agent_name:ctx.agent_name args in
  let expected_version = get_int_opt args "expected_version" in
  let force_raw = get_bool args "force" false in
  (* force=true requires admin privilege: initial_admin or Admin role *)
  let force =
    if force_raw then
      match Auth.read_initial_admin ctx.config.base_path with
      | Some admin when String.equal ctx.agent_name admin -> true
      | _ ->
        Log.Task.warn "[anti-rationalization] force=true rejected: agent=%s lacks admin privilege"
          ctx.agent_name;
        false
    else false
  in
  let tasks = Coord.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Types.task) -> t.id = task_id) tasks in
  match handoff_context with
  | Error error -> (false, error)
  | Ok handoff_context ->
  if action = Types.Release && strict_release_requires_handoff task_opt
     && Option.is_none handoff_context
  then
    (false, "Strict task release requires handoff_context.summary")
  else
  let completion_state_error =
    if action = Types.Done_action && not force then
      completion_state_error ~task_id ~agent_name:ctx.agent_name ~task_opt
    else
      None
  in
  match completion_state_error with
  | Some err ->
    Log.Task.error "task transition failed: %s" (Types.masc_error_to_string err);
    result_to_response (Error err)
  | None ->
  let completion_owned_by_caller =
    force || can_review_completion ~task_opt ~agent_name:ctx.agent_name
  in
  let persisted_gate_rejection =
    if action = Types.Done_action && not force then
      if not completion_owned_by_caller then
        None
      else if task_has_persisted_contract task_opt then
        persisted_contract_rejection ~ctx ~task_opt ~notes
      else
        None
    else
      None
  in
  match persisted_gate_rejection with
  | Some reason ->
    (false, reason)
  | None ->
  let review_gate_rejection =
    if action = Types.Done_action && not force then
      if not completion_owned_by_caller then
        None
      else if can_review_completion ~task_opt ~agent_name:ctx.agent_name then
        review_completion_notes
          ~completion_contract:
            (match persisted_completion_contract ~task_opt with
             | Some persisted -> Some persisted
             | None -> completion_contract)
          ~evaluator_cascade
          ~ctx
          ~task_opt
          ~task_id
          ~notes
      else
        None
    else
      None
  in
  match review_gate_rejection with
  | Some reason ->
    (false, completion_rejection_message ~allow_force:true reason)
  | None ->
  (* Verifier gate: if the task has a completion_contract and the
     verification FSM is enabled, redirect Done → Submit_for_verification
     so a cross-agent verifier keeper can independently validate the
     quantitative criteria. Gates 1-3 (length, excuse, LLM) still run
     above; this replaces Gate 2.5 (substring match) with real
     measurement by the verifier. See issue #7598. *)
  let action =
    if action = Types.Done_action
       && Env_config_runtime.Verification.fsm_enabled ()
       && completion_owned_by_caller
    then
      match task_opt with
      | Some task ->
        (match task.contract with
         | Some contract
           when contract.completion_contract <> [] || contract.required_evidence <> [] ->
           Log.Task.info
             "[verifier-gate] redirecting Done→Submit_for_verification task=%s agent=%s contract_items=%d"
             task_id ctx.agent_name
             (List.length contract.completion_contract + List.length contract.required_evidence);
           Types.Submit_for_verification
         | _ -> action)
      | None -> action
    else action
  in
  let default_time = Time_compat.now () -. 60.0 in
  let (started_at_actual, collaborators_from_task) = match task_opt with
    | Some t -> (match t.task_status with
        | Types.InProgress { started_at; assignee } ->
            let ts = Types.parse_iso8601 ~default_time started_at in
            let collabs = if assignee <> "" && assignee <> ctx.agent_name then [assignee] else [] in
            (ts, collabs)
        | Types.Claimed { claimed_at; assignee } ->
            let ts = Types.parse_iso8601 ~default_time claimed_at in
            let collabs = if assignee <> "" && assignee <> ctx.agent_name then [assignee] else [] in
            (ts, collabs)
        | _ -> (default_time, []))
    | None -> (default_time, [])
  in
  let max_cas_retries = 3 in
  let cas_retry_delay_s = 0.05 in
  let is_version_mismatch = function
    | Error (Types.TaskInvalidState msg) ->
        let prefix = "Version mismatch" in
        String.length msg >= String.length prefix
        && String.sub msg 0 (String.length prefix) = prefix
    | _ -> false
  in
  let prepare_verification_request =
    match action with
    | Types.Submit_for_verification ->
      Some
        (fun ~task ~assignee ~verification_id ~evidence_refs ->
           Verification_protocol.create_submit_request
             ~config:ctx.config
             ~task
             ~assignee
             ~verification_id
             ~evidence_refs)
    | Types.Claim
    | Types.Start
    | Types.Done_action
    | Types.Cancel
    | Types.Release
    | Types.Approve_verification
    | Types.Reject_verification ->
      None
  in
  let prepare_verification_verdict =
    match action with
    | Types.Approve_verification
    | Types.Reject_verification ->
      Some
        (fun ~(task : Types.task) ~verifier ~verification_id ~decision ->
           match decision with
           | `Approve notes ->
             Verification_protocol.record_approve_verification
               ~config:ctx.config
               ~task_id:task.id
               ~verifier
               ~verification_id
               ~notes
           | `Reject reason ->
             Verification_protocol.record_reject_verification
               ~config:ctx.config
               ~task_id:task.id
               ~verifier
               ~verification_id
               ~reason)
    | Types.Claim
    | Types.Start
    | Types.Done_action
    | Types.Cancel
    | Types.Release
    | Types.Submit_for_verification ->
      None
  in
  let rec try_transition attempt =
    let ev = if attempt = 0 then expected_version else None in
    let agent_tool_names =
      match agent_tool_names with
      | Some _ -> agent_tool_names
      | None -> keeper_agent_tool_names ctx
    in
    let r = Coord.transition_task_r ctx.config ~agent_name:ctx.agent_name
              ~task_id ~action ?expected_version:ev ~notes ~reason
              ?handoff_context ?agent_tool_names ?prepare_verification_request
              ?prepare_verification_verdict () in
    if is_version_mismatch r && attempt < max_cas_retries then begin
      Log.Task.info "CAS version mismatch on %s (attempt %d/%d), retrying in %.0fms"
        task_id (attempt + 1) max_cas_retries (cas_retry_delay_s *. 1000.0);
      Time_compat.sleep cas_retry_delay_s;
      try_transition (attempt + 1)
    end else
      r
  in
  (* Capture verification_id from AwaitingVerification state BEFORE transition.
     approve/reject transitions change state, destroying the verification_id.
     Issue #7543. *)
  let verification_id_before =
    match task_opt with
    | Some t -> (match t.task_status with
        | Types.AwaitingVerification { verification_id; _ } -> Some verification_id
        | _ -> None)
    | None -> None
  in
  let result = try_transition 0 in
  (match result with
   | Ok _ ->
     sync_keeper_current_task_binding ctx;
     sync_planning_current_task_with_owned_task ctx
   | Error _ -> ());
  (* Notify A2A subscribers on successful transition *)
  (match result with
   | Ok _ ->
       A2a_tools.notify_event
         ~event_type:A2a_tools.TaskUpdate
         ~agent:ctx.agent_name
         ~data:(`Assoc [
           ("task_id", `String task_id);
           ("action", `String action_s);
           ("notes", `String notes);
         ]);
       (* Notification harness: push task transition to all active sessions *)
       Subscriptions.push_event_to_sessions (`Assoc [
         ("type", `String "masc/task_transition");
         ("task_id", `String task_id);
         ("action", `String action_s);
         ("agent_name", `String ctx.agent_name);
         ("timestamp", `Float (Time_compat.now ()));
       ]);
       (match action with
        | Types.Submit_for_verification ->
          let tasks = Coord.get_tasks_raw ctx.config in
          (match List.find_opt (fun (t : Types.task) -> t.id = task_id) tasks with
           | Some task ->
             let evidence_refs = match task.contract with
               | Some c -> c.verify_gate_evidence
               | None -> [] in
             (match task.task_status with
              | Types.AwaitingVerification { verification_id; assignee; _ } ->
                Verification_protocol.notify_submit_for_verification
                  ~config:ctx.config ~task ~assignee ~verification_id ~evidence_refs
              | Types.Todo | Types.Claimed _ | Types.InProgress _
              | Types.Done _ | Types.Cancelled _ -> ())
           | None -> ())
        | Types.Approve_verification ->
          let verification_id = Option.value ~default:"" verification_id_before in
          Verification_protocol.notify_approve_verification
            ~task_id ~verifier:ctx.agent_name ~verification_id ~notes;
          (* Record a CDAL verdict attribution on the approval leg so the
             dashboard gets a complete audit line.  With the verification
             FSM enabled, tasks reach Done via approve_verification rather
             than Done_action, so the gate_check call on the Done_action
             path (persisted_contract_rejection) never fires and the CDAL
             gate shows zero entries in Dashboard_attribution even when
             contracts are present.  The rejection string is intentionally
             dropped — the verifier keeper has already judged the task,
             we only want the [Dashboard_attribution] side effect that
             [gate_check] performs internally. *)
          if Env_config_runtime.Cdal.gate_enabled () then
            ignore (Cdal_verdict_gate.gate_check ~task_id ())
        | Types.Reject_verification ->
          let reason = if notes <> "" then notes else reason in
          let verification_id = Option.value ~default:"" verification_id_before in
          Verification_protocol.notify_reject_verification
            ~task_id ~verifier:ctx.agent_name ~verification_id ~reason;
          if Env_config_runtime.Cdal.gate_enabled () then
            ignore (Cdal_verdict_gate.gate_check ~task_id ())
        | Types.Claim | Types.Start | Types.Done_action | Types.Cancel | Types.Release -> ())
   | Error err ->
       Log.Task.error "task transition failed: %s" (Types.masc_error_to_string err));
  (* Record metrics *)
  (match result, action with
   | Ok _, Types.Done_action ->
       let metric : Metrics_store_eio.task_metric = {
         id = Printf.sprintf "metric-%s-%d" task_id (int_of_float (Time_compat.now () *. 1000.));
         agent_id = ctx.agent_name;
         task_id;
         started_at = started_at_actual;
         completed_at = Some (Time_compat.now ());
         success = true;
         error_message = None;
         collaborators = collaborators_from_task;
         handoff_from = None;
         handoff_to = None;
       } in
       (try let _ = Metrics_store_eio.record ctx.config metric in ()
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Task.error "Metrics_store_eio.record(transition-done) failed: %s" (Printexc.to_string exn));
       Thompson_sampling.record_vote ~agent_name:ctx.agent_name ~direction:`Up;
       Prometheus.record_task_completed ()
   | Ok _, Types.Cancel ->
       let metric : Metrics_store_eio.task_metric = {
         id = Printf.sprintf "metric-%s-%d" task_id (int_of_float (Time_compat.now () *. 1000.));
         agent_id = ctx.agent_name;
         task_id;
         started_at = started_at_actual;
         completed_at = Some (Time_compat.now ());
         success = false;
         error_message = Some (if reason = "" then "Cancelled" else reason);
         collaborators = collaborators_from_task;
         handoff_from = None;
         handoff_to = None;
       } in
       (try let _ = Metrics_store_eio.record ctx.config metric in ()
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Task.error "Metrics_store_eio.record(transition-cancel) failed: %s" (Printexc.to_string exn));
       Thompson_sampling.record_vote ~agent_name:ctx.agent_name ~direction:`Down;
       Prometheus.record_task_failed ()
   | Ok _, (Types.Claim | Types.Start | Types.Submit_for_verification
            | Types.Approve_verification | Types.Reject_verification | Types.Release)
   | Error _, _ -> ());
  result_to_response result

let handle_update_priority ctx args =
  let task_id = get_string args "task_id" "" in
  let priority = get_int args "priority" 3 in
  (true, Coord.update_priority ctx.config ~task_id ~priority)

let handle_tasks ctx args =
  let include_done = get_bool args "include_done" false in
  let include_cancelled = get_bool args "include_cancelled" false in
  let status =
    match args |> member "status" with
    | `String s when s <> "" -> Some s
    | _ -> None
  in
  (true, Coord.list_tasks ctx.config ~include_done ~include_cancelled ?status)

let task_history_events_json (config : Coord.config) ~task_id ~limit =
  let scan_limit = min 500 (limit * 5) in
  let lines = Mcp_server.read_event_lines config ~limit:scan_limit in
  let (parsed, _malformed) =
    Fs_compat.parse_jsonl_lines ~source:"task_events" lines
  in
  let matches_task json =
    let task = json |> member "task" |> to_string_option in
    let task_id_field = json |> member "task_id" |> to_string_option in
    match task, task_id_field with
    | Some t, _ when t = task_id -> true
    | _, Some t when t = task_id -> true
    | _ -> false
  in
  let rec take n xs =
    match xs with
    | [] -> []
    | _ when n <= 0 -> []
    | x :: rest -> x :: take (n - 1) rest
  in
  let events = parsed |> List.filter matches_task |> take limit in
  `List events

let handle_task_history ctx args =
  let task_id = get_string args "task_id" "" in
  let limit = get_int args "limit" 50 in
  (true, Yojson.Safe.to_string (task_history_events_json ctx.config ~task_id ~limit))

include Tool_task_schemas
(* Dispatch function *)
let dispatch ?agent_tool_names ctx ~name ~args : tool_result option =
  match name with
  | "masc_add_task" -> Some (handle_add_task ctx args)
  | "masc_batch_add_tasks" -> Some (handle_batch_add_tasks ctx args)
  | "masc_claim_task" -> Some (handle_claim ?agent_tool_names ctx args)
  | "masc_claim_next" -> Some (handle_claim_next ?agent_tool_names ctx args)
  | "masc_transition" -> Some (handle_transition ?agent_tool_names ctx args)
  | "masc_update_priority" -> Some (handle_update_priority ctx args)
  | "masc_tasks" -> Some (handle_tasks ctx args)
  | "masc_task_history" -> Some (handle_task_history ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only = [ "masc_task_history"; "masc_tasks" ]
let _tool_spec_requires_join = [ "masc_claim_next"; "masc_transition" ]

let tool_required_permission = function
  | "masc_tasks" | "masc_task_history" ->
      Some Types.CanReadState
  | "masc_add_task" | "masc_batch_add_tasks" ->
      Some Types.CanAddTask
  | "masc_claim_next" ->
      Some Types.CanClaimTask
  | "masc_transition" | "masc_update_priority" ->
      Some Types.CanCompleteTask
  | _ -> None

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_task
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ~requires_join:(List.mem s.name _tool_spec_requires_join)
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
