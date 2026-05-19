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

let result_to_response ~tool_name ~start_time = function
  | Ok msg -> Tool_result.ok ~tool_name ~start_time msg
  | Error e -> Tool_result.error ~tool_name ~start_time (Masc_domain.masc_error_to_string e)

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
    try Coord.resolve_agent_name ctx.config ctx.agent_name
    with
    | Sys_error _ | Yojson.Json_error _ -> ctx.agent_name
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
             Log.Task.warn "failed to sync planning current_task to %s: %s"
               task_id msg)
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
    Tool_result.error ~tool_name ~start_time
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
  if String.equal trimmed_title "" then
    Tool_result.error ~tool_name ~start_time "Task title cannot be empty or whitespace-only"
  else if priority < 1 || priority > 5 then
    Tool_result.error ~tool_name ~start_time (Printf.sprintf "Priority must be between 1 and 5, got %d" priority)
  else if Option.is_some goal_id
          && not
               (Goal_store.list_goals ctx.config ()
                |> List.exists (fun (goal : Goal_store.goal) ->
                       String.equal goal.id (Option.value ~default:"" goal_id)))
  then
    Tool_result.error ~tool_name ~start_time (Printf.sprintf "Unknown goal_id '%s'" (Option.value ~default:"" goal_id))
  else
    match contract_result with
    | Error error -> Tool_result.error ~tool_name ~start_time error
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
    Tool_result.error ~tool_name ~start_time "tasks array is empty or missing"
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
    Tool_result.error ~tool_name ~start_time (Printf.sprintf "Validation failed:\n%s" (String.concat "\n" errors))
  else
    let tasks =
      List.filter_map (function Ok t -> Some t | Error _ -> None) validated
    in
    Tool_result.ok ~tool_name ~start_time (Coord.batch_add_tasks_with_contracts
      ~created_by:ctx.agent_name ctx.config tasks)

let handle_claim ?agent_tool_names ~tool_name ~start_time ctx args =
  if not (try Coord.is_agent_joined ctx.config ~agent_name:ctx.agent_name with Sys_error _ | Stdlib.Not_found -> false) then
    result_to_response ~tool_name ~start_time (Error (Masc_domain.Agent (Masc_domain.Agent_error.NotJoined ctx.agent_name)))
  else if not ((=) (args |> member "agent_role") `Null) then
    Tool_result.error ~tool_name ~start_time "agent_role is no longer supported"
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
   | Error e -> Log.Task.warn "task claim failed for %s: %s" task_id (Masc_domain.masc_error_to_string e));
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

let format_no_eligible ctx excluded_count =
  match active_goal_phases_for_agent ctx with
  | [] ->
      Printf.sprintf
        "No eligible tasks available (blocked/excluded: %d). This agent has no \
         active_goal_ids — every open task is out of scope. Operator should \
         set active_goal_ids via masc_keeper_up."
        excluded_count
  | phases ->
      Printf.sprintf
        "No eligible tasks available (blocked/excluded: %d). active goal \
         phases: [%s]. NOTE: excluded ≠ completed. If every phase above is \
         'executing', the cause is goal-scope mismatch — open tasks are \
         scoped to a goal not in this agent's active_goal_ids — not goal \
         completion."
        excluded_count
        (String.concat ", " phases)

let handle_claim_next ?agent_tool_names ~tool_name ~start_time ctx _args =
  if not (try Coord.is_agent_joined ctx.config ~agent_name:ctx.agent_name with Sys_error _ | Stdlib.Not_found -> false) then
    Tool_result.error ~tool_name ~start_time (Printf.sprintf "Agent '%s' is not a member of this room" ctx.agent_name)
  else
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
  | Coord.Claim_next_no_eligible { excluded_count; _ } ->
    Tool_result.ok ~tool_name ~start_time (format_no_eligible ctx excluded_count)
  | Coord.Claim_next_error e ->
    Tool_result.error ~tool_name ~start_time (Printf.sprintf "Error: %s" e)

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
   | Error error -> Tool_result.error ~tool_name ~start_time error
   | Ok handoff_context ->
       if strict_release_requires_handoff task_opt && Option.is_none handoff_context
       then
         Tool_result.error ~tool_name ~start_time "Strict task release requires handoff_context.summary"
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

let rec handle_done ~tool_name ~start_time ctx args =
  let notes = get_string args "notes" "" in
  handle_transition ~tool_name ~start_time ctx
    (`Assoc
       [
         ("task_id", args |> member "task_id");
         ("action", `String "done");
         ("notes", `String notes);
       ])

and handle_cancel_task ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response ~tool_name ~start_time (Error e)
  | Ok task_id ->
  let reason = get_string args "reason" "" in
  let tasks = Coord.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks in
  let started_at_actual = match task_opt with
    | Some t -> (match t.task_status with
        | Masc_domain.InProgress { started_at; _ } ->
            Masc_domain.parse_iso8601 ~default_time:(Time_compat.now () -. 60.0) started_at
        | Masc_domain.Claimed { claimed_at; _ } ->
            Masc_domain.parse_iso8601 ~default_time:(Time_compat.now () -. 60.0) claimed_at
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
         id = Printf.sprintf "metric-%s-%d" task_id (Stdlib.Int.of_float (Time_compat.now () *. 1000.));
         agent_id = ctx.agent_name;
         task_id;
         started_at = started_at_actual;
         completed_at = Some (Time_compat.now ());
         success = false;
         error_message = Some (if String.equal reason "" then "Cancelled" else reason);
         collaborators = [];
         handoff_from = None;
         handoff_to = None;
       } in
       (try let _ = Metrics_store_eio.record ctx.config metric in ()
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Task.error "Metrics_store_eio.record(cancel) failed: %s" (Stdlib.Printexc.to_string exn));
       (* Feed failure into Thompson Sampling quality signal *)
       Thompson_sampling.record_vote ~agent_name:ctx.agent_name ~direction:`Down;
       Thompson_sampling.record_quality_signal
         ~agent_name:ctx.agent_name
         ~verdict:(Post_verifier.Fail "task_cancelled");
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
       Log.Task.error "metrics record failed: %s" (Masc_domain.masc_error_to_string err));
  result_to_response ~tool_name ~start_time result

and handle_transition ?agent_tool_names ~tool_name ~start_time ctx args =
  (* Underscore-prefixed keys (e.g. "_agent_name") are internal protocol markers
     injected by the HTTP transport and dashboard client for identity
     propagation. They are consumed upstream in Agent_identity and must not
     trigger the strict-schema "Unknown argument(s)" rejection here. *)
  let is_internal_marker k =
    String.length k > 0 && Char.equal k.[0] '_'
  in
  (* Issue #8312: small LLM keepers and operator UIs frequently send
     - target-state aliases via [to] instead of canonical [action]
     - singular [note] instead of [notes]
     Normalize before strict-schema validation so callers do not have
     to memorize canonical vocabulary. The Variant ([Masc_domain.task_action])
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
      (* Transport-level alias [pr_url] is hoisted into the typed
         [handoff_context.evidence_refs] list. Previously this aliased
         into a "PR: <url>" string blob inside [notes], which the
         downstream task-handoff schema then had to recover via
         sibling synthesis or substring scanning. There is no
         in-repo reader of that [notes] blob — pr_url consumers
         (keeper_tool_call_log, keeper_hooks_oas, audit_keeper_...)
         already read pr_url as a typed field elsewhere — so the
         legacy blob is dead-on-write.

         Merge semantics: if a [handoff_context] object is already
         present in args, append pr_url to its [evidence_refs]
         (preserving any existing refs). Otherwise inject a new
         minimal handoff_context = { evidence_refs = [pr_url] }. *)
      let kvs =
        match List.find_opt (fun (k, _) -> String.equal k "pr_url") kvs with
        | Some (_, `String pr_url) when not (String.equal pr_url "") ->
            let kvs = List.filter (fun (k, _) -> not (String.equal k "pr_url")) kvs in
            let merge_pr_url_into_handoff (hc : Yojson.Safe.t) : Yojson.Safe.t =
              match hc with
              | `Assoc hc_fields ->
                let existing_refs =
                  match List.assoc_opt "evidence_refs" hc_fields with
                  | Some (`List xs) -> xs
                  | _ -> []
                in
                let new_refs = existing_refs @ [ `String pr_url ] in
                let hc_fields =
                  List.filter
                    (fun (k, _) -> not (String.equal k "evidence_refs"))
                    hc_fields
                  @ [ "evidence_refs", `List new_refs ]
                in
                `Assoc hc_fields
              | _ -> `Assoc [ "evidence_refs", `List [ `String pr_url ] ]
            in
            (match List.find_opt (fun (k, _) -> String.equal k "handoff_context") kvs with
             | Some _ ->
               List.map
                 (fun (k, v) ->
                   if String.equal k "handoff_context"
                   then ("handoff_context", merge_pr_url_into_handoff v)
                   else (k, v))
                 kvs
             | None ->
               kvs @ [ "handoff_context", merge_pr_url_into_handoff `Null ])
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
  if Stdlib.List.length unknown > 0 then
    let names = String.concat ", " (List.map fst unknown) in
    Tool_result.error ~tool_name ~start_time (Printf.sprintf "Unknown argument(s): %s. Valid: %s"
      names (String.concat ", " transition_known_args))
  else
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response ~tool_name ~start_time (Error e)
  | Ok task_id ->
  let action_raw = get_string args "action" "" in
  if String.equal action_raw "" then
    Tool_result.error ~tool_name ~start_time (Printf.sprintf "action is required (%s)" (String.concat ", " Masc_domain.valid_task_action_strings))
  else
  match Masc_domain.task_action_of_string_lenient action_raw with
  | Error msg -> Tool_result.error ~tool_name ~start_time msg
  | Ok action ->
  let requested_action = action in
  let action_s = Masc_domain.task_action_to_string action in
  if is_verifier_agent_name ctx.agent_name
     && not (verifier_transition_action_allowed action)
  then
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name
      ~start_time
      (verifier_transition_rejection ~agent_name:ctx.agent_name ~action:action_s)
  else
  let notes = get_string args "notes" "" in
  let reason = get_string args "reason" "" in
  let completion_contract =
    match get_string_list args "completion_contract" with
    | [] -> None
    | items -> Some items
  in
  let evaluator_cascade = get_string_opt args "evaluator_cascade" in
  let handoff_context =
    parse_handoff_context ~agent_name:ctx.agent_name ~action args
  in
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
  let task_opt = List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks in
  let verifier_terminal_verdict_noop =
    if is_verifier_agent_name ctx.agent_name
       && verifier_transition_action_allowed action
    then
      match task_opt with
      | Some task when Masc_domain.task_status_is_terminal task.task_status ->
        Some
          (verifier_terminal_verdict_noop_message
             ~task_id
             ~action:action_s
             ~status:(Masc_domain.task_status_to_string task.task_status))
      | _ -> None
    else
      None
  in
  match verifier_terminal_verdict_noop with
  | Some message -> Tool_result.ok ~tool_name ~start_time message
  | None ->
  match handoff_context with
  | Error error -> Tool_result.error ~tool_name ~start_time error
  | Ok handoff_context ->
  if (=) action Masc_domain.Release && strict_release_requires_handoff task_opt
     && Option.is_none handoff_context
  then
    Tool_result.error ~tool_name ~start_time "Strict task release requires handoff_context.summary"
  else
  let completion_state_error =
    if (=) action Masc_domain.Done_action && not force then
      completion_state_error ~task_id ~agent_name:ctx.agent_name ~task_opt
    else
      None
  in
  match completion_state_error with
  | Some err ->
    Log.Task.error "task transition failed: %s" (Masc_domain.masc_error_to_string err);
    result_to_response ~tool_name ~start_time (Error err)
  | None ->
  let completion_owned_by_caller =
    force || can_review_completion ~task_opt ~agent_name:ctx.agent_name
  in
  let done_redirects_to_verification =
    (=) action Masc_domain.Done_action
    && Env_config_runtime.Verification.fsm_enabled ()
    && completion_owned_by_caller
    && task_requires_verification task_opt
  in
  let persisted_gate_rejection =
    if (=) action Masc_domain.Done_action
       && not force
       && not done_redirects_to_verification
    then
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
    Tool_result.error ~tool_name ~start_time reason
  | None ->
  let review_gate_rejection =
    if (=) action Masc_domain.Done_action && not force then
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
    Tool_result.error ~tool_name ~start_time (completion_rejection_message ~allow_force:true reason)
  | None ->
  (* Verifier gate: if the task has a completion_contract and the
     verification FSM is enabled, redirect Done → Submit_for_verification
     so a cross-agent verifier keeper can independently validate the
     quantitative criteria. Gates 1-3 (length, excuse, LLM) still run
     above; this replaces Gate 2.5 (substring match) with real
     measurement by the verifier. See issue #7598. *)
  let action =
    if done_redirects_to_verification then
      match task_opt with
      | Some task ->
        (match task.contract with
         | Some contract when contract_requires_verification contract ->
           Log.Task.info
             "[verifier-gate] redirecting Done→Submit_for_verification task=%s agent=%s contract_items=%d"
             task_id ctx.agent_name
             (List.length contract.completion_contract
              + List.length contract.required_evidence
              + List.length contract.verify_gate_evidence);
           Masc_domain.Submit_for_verification
         | _ -> action)
      | None -> action
    else action
  in
  let submit_evidence_error =
    match requested_action with
    | Masc_domain.Submit_for_verification | Masc_domain.Submit_pr_evidence ->
      verification_submission_evidence_error ~notes ~handoff_context
    | Masc_domain.Done_action when done_redirects_to_verification ->
      verification_submission_evidence_error ~notes ~handoff_context
    | Masc_domain.Claim
    | Masc_domain.Start
    | Masc_domain.Done_action
    | Masc_domain.Cancel
    | Masc_domain.Release
    | Masc_domain.Approve_verification
    | Masc_domain.Reject_verification ->
      None
  in
  let action =
    match requested_action, task_opt, submit_evidence_error with
    | ( Masc_domain.Submit_for_verification
      , Some ({ task_status = Masc_domain.Todo; _ } : Masc_domain.task)
      , None ) ->
      Log.Task.info
        "[verification-alias] treating todo submit_for_verification with evidence as submit_pr_evidence task=%s agent=%s"
        task_id
        ctx.agent_name;
      Masc_domain.Submit_pr_evidence
    | _ -> action
  in
  let action_s = Masc_domain.task_action_to_string action in
  let default_time = Time_compat.now () -. 60.0 in
  let (started_at_actual, collaborators_from_task) = match task_opt with
    | Some t -> (match t.task_status with
        | Masc_domain.InProgress { started_at; assignee } ->
            let ts = Masc_domain.parse_iso8601 ~default_time started_at in
            let collabs = if not (String.equal assignee "") && not (String.equal assignee ctx.agent_name) then [assignee] else [] in
            (ts, collabs)
        | Masc_domain.Claimed { claimed_at; assignee } ->
            let ts = Masc_domain.parse_iso8601 ~default_time claimed_at in
            let collabs = if not (String.equal assignee "") && not (String.equal assignee ctx.agent_name) then [assignee] else [] in
            (ts, collabs)
        | _ -> (default_time, []))
    | None -> (default_time, [])
  in
  let max_cas_retries = 3 in
  let cas_retry_delay_s = 0.05 in
  let is_version_mismatch = function
    | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState msg)) ->
        let prefix = "Version mismatch" in
        String.length msg >= String.length prefix
        && String.equal (Stdlib.String.sub msg 0 (String.length prefix)) prefix
    | _ -> false
  in
  let prepare_verification_request =
    match action with
    | Masc_domain.Submit_for_verification | Masc_domain.Submit_pr_evidence ->
      Some
        (fun ~task ~assignee ~verification_id ~evidence_refs ->
           Verification_protocol.create_submit_request
             ~config:ctx.config
             ~task
             ~assignee
             ~verification_id
             ~evidence_refs)
    | Masc_domain.Claim
    | Masc_domain.Start
    | Masc_domain.Done_action
    | Masc_domain.Cancel
    | Masc_domain.Release
    | Masc_domain.Approve_verification
    | Masc_domain.Reject_verification ->
      None
  in
  let prepare_verification_verdict =
    match action with
    | Masc_domain.Approve_verification
    | Masc_domain.Reject_verification ->
      Some
        (fun ~(task : Masc_domain.task) ~verifier ~verification_id ~decision ->
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
    | Masc_domain.Claim
    | Masc_domain.Start
    | Masc_domain.Done_action
    | Masc_domain.Cancel
    | Masc_domain.Release
    | Masc_domain.Submit_for_verification
    | Masc_domain.Submit_pr_evidence ->
      None
  in
  let verifier_approve_gate_rejection =
    if (=) action Masc_domain.Approve_verification
       && task_has_strict_persisted_contract task_opt
    then
      persisted_contract_rejection ~ctx ~task_opt ~notes
    else
      None
  in
  match verifier_approve_gate_rejection with
  | Some reason ->
    Tool_result.error ~tool_name ~start_time reason
  | None ->
  let rec try_transition attempt =
    match submit_evidence_error with
    | Some reason ->
      Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState reason))
    | None ->
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
        | Masc_domain.AwaitingVerification { verification_id; _ } -> Some verification_id
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
       (* Notification harness: push task transition to all active sessions *)
       Subscriptions.push_event_to_sessions (`Assoc [
         ("type", `String "masc/task_transition");
         ("task_id", `String task_id);
         ("action", `String action_s);
         ("agent_name", `String ctx.agent_name);
         ("timestamp", `Float (Time_compat.now ()));
       ]);
       (match action with
        | Masc_domain.Submit_for_verification | Masc_domain.Submit_pr_evidence ->
          let tasks = Coord.get_tasks_raw ctx.config in
          (match List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks with
           | Some task ->
             let evidence_refs = verification_evidence_refs_for_task task in
             (match task.task_status with
              | Masc_domain.AwaitingVerification { verification_id; assignee; _ } ->
                Verification_protocol.notify_submit_for_verification
                  ~config:ctx.config ~task ~assignee ~verification_id ~evidence_refs
              | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
              | Masc_domain.Done _ | Masc_domain.Cancelled _ -> ())
           | None -> ());
          (* Record CDAL verdict attribution on submit_pr_evidence so the
             dashboard gets a complete audit line.  When tasks bypass
             Done_action and go directly to submit_pr_evidence, the
             gate_check call on the Done_action path never fires and
             the CDAL gate shows zero entries in Dashboard_attribution
             even when contracts are present. *)
          if Env_config_runtime.Cdal.gate_enabled () then
            ignore
              (Cdal_verdict_gate.gate_check
                 ~gate_label:(cdal_gate_label_for_task task_opt)
                 ~warn_on_missing:false
                 ~task_id ())
        | Masc_domain.Approve_verification ->
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
            ignore
              (Cdal_verdict_gate.gate_check
                 ~gate_label:(cdal_gate_label_for_task task_opt)
                 ~warn_on_missing:false
                 ~task_id ())
        | Masc_domain.Reject_verification ->
          let reason = if not (String.equal notes "") then notes else reason in
          let verification_id = Option.value ~default:"" verification_id_before in
          Verification_protocol.notify_reject_verification
            ~task_id ~verifier:ctx.agent_name ~verification_id ~reason;
          if Env_config_runtime.Cdal.gate_enabled () then
            ignore
              (Cdal_verdict_gate.gate_check
                 ~gate_label:(cdal_gate_label_for_task task_opt)
                 ~warn_on_missing:false
                 ~task_id ())
        | Masc_domain.Claim | Masc_domain.Start | Masc_domain.Done_action | Masc_domain.Cancel | Masc_domain.Release -> ())
   | Error err ->
       Log.Task.error "task transition failed: %s" (Masc_domain.masc_error_to_string err));
  (* Record metrics *)
  (match result, action with
   | Ok _, Masc_domain.Done_action ->
       let metric : Metrics_store_eio.task_metric = {
         id = Printf.sprintf "metric-%s-%d" task_id (Stdlib.Int.of_float (Time_compat.now () *. 1000.));
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
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Task.error "Metrics_store_eio.record(transition-done) failed: %s" (Stdlib.Printexc.to_string exn));
       Thompson_sampling.record_vote ~agent_name:ctx.agent_name ~direction:`Up;
       Thompson_sampling.record_quality_signal
         ~agent_name:ctx.agent_name
         ~verdict:Post_verifier.Pass;
       Prometheus.record_task_completed ()
   | Ok _, Masc_domain.Cancel ->
       let metric : Metrics_store_eio.task_metric = {
         id = Printf.sprintf "metric-%s-%d" task_id (Stdlib.Int.of_float (Time_compat.now () *. 1000.));
         agent_id = ctx.agent_name;
         task_id;
         started_at = started_at_actual;
         completed_at = Some (Time_compat.now ());
         success = false;
         error_message = Some (if String.equal reason "" then "Cancelled" else reason);
         collaborators = collaborators_from_task;
         handoff_from = None;
         handoff_to = None;
       } in
       (try let _ = Metrics_store_eio.record ctx.config metric in ()
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Task.error "Metrics_store_eio.record(transition-cancel) failed: %s" (Stdlib.Printexc.to_string exn));
       Thompson_sampling.record_vote ~agent_name:ctx.agent_name ~direction:`Down;
       Thompson_sampling.record_quality_signal
         ~agent_name:ctx.agent_name
         ~verdict:(Post_verifier.Fail "task_cancelled");
       Prometheus.record_task_failed ()
   | Ok _, (Masc_domain.Claim | Masc_domain.Start | Masc_domain.Submit_for_verification
            | Masc_domain.Submit_pr_evidence
            | Masc_domain.Approve_verification | Masc_domain.Reject_verification | Masc_domain.Release)
   | Error _, _ -> ());
  result_to_response ~tool_name ~start_time result

let handle_update_priority ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  let priority = get_int args "priority" 3 in
  Tool_result.ok ~tool_name ~start_time (Coord.update_priority ctx.config ~task_id ~priority)

let handle_tasks ~tool_name ~start_time ctx args =
  let include_done = get_bool args "include_done" false in
  let include_cancelled = get_bool args "include_cancelled" false in
  let status =
    match args |> member "status" with
    | `String s when not (String.equal s "") -> Some s
    | _ -> None
  in
  Tool_result.ok ~tool_name ~start_time (Coord.list_tasks ctx.config ~include_done ~include_cancelled ?status)

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
    | Some t, _ when String.equal t task_id -> true
    | _, Some t when String.equal t task_id -> true
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

let handle_task_history ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  let limit = get_int args "limit" 50 in
  Tool_result.ok ~tool_name ~start_time (Yojson.Safe.to_string (task_history_events_json ctx.config ~task_id ~limit))

include Tool_task_schemas
(* Dispatch function *)
let dispatch ?agent_tool_names ctx ~name ~args : Tool_result.t option =
  let start = Time_compat.now () in
  match name with
  | "masc_add_task" -> Some (handle_add_task ~tool_name:name ~start_time:start ctx args)
  | "masc_batch_add_tasks" -> Some (handle_batch_add_tasks ~tool_name:name ~start_time:start ctx args)
  | "masc_claim_task" -> Some (handle_claim ?agent_tool_names ~tool_name:name ~start_time:start ctx args)
  | "masc_claim_next" -> Some (handle_claim_next ?agent_tool_names ~tool_name:name ~start_time:start ctx args)
  | "masc_transition" -> Some (handle_transition ?agent_tool_names ~tool_name:name ~start_time:start ctx args)
  | "masc_update_priority" -> Some (handle_update_priority ~tool_name:name ~start_time:start ctx args)
  | "masc_tasks" -> Some (handle_tasks ~tool_name:name ~start_time:start ctx args)
  | "masc_task_history" -> Some (handle_task_history ~tool_name:name ~start_time:start ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let tool_spec_read_only = [ "masc_task_history"; "masc_tasks" ]
let tool_spec_requires_join = [ "masc_claim_next"; "masc_transition" ]

let tool_required_permission = function
  | "masc_tasks" | "masc_task_history" ->
      Some Masc_domain.CanReadState
  | "masc_add_task" | "masc_batch_add_tasks" ->
      Some Masc_domain.CanAddTask
  | "masc_claim_next" ->
      Some Masc_domain.CanClaimTask
  | "masc_transition" | "masc_update_priority" ->
      Some Masc_domain.CanCompleteTask
  | _ -> None

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_task
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name tool_spec_read_only)
           ~is_idempotent:(List.mem s.name tool_spec_read_only)
           ~requires_join:(List.mem s.name tool_spec_requires_join)
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
