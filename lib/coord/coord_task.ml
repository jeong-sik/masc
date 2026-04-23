(** Coord_task — Task lifecycle: add, claim, transition, complete, cancel, claim_next. *)

open Types
include Coord_utils
include Coord_state
include Coord_broadcast

(* activity_room_id removed — namespace retired (#unify-namespace). *)

let task_actor_kind agent_name =
  let normalized = String.lowercase_ascii (String.trim agent_name) in
  if normalized = "" || normalized = "system"
  then "system"
  else if Resilience.Zombie.is_keeper_name normalized
  then "keeper"
  else "agent"
;;

let trim_opt = function
  | Some value ->
    let trimmed = String.trim value in
    if trimmed = "" then None else Some trimmed
  | None -> None
;;

(* Agents who currently hold a Claimed or InProgress task.
    Used by the Hebbian hook to strengthen only against agents who are
    actively working, not everyone who happens to be joined.
    Falls back to active_agents if the backlog cannot be read. *)
let working_agents config =
  match read_backlog_r config with
  | Error _ -> (Coord_state.read_state config).active_agents
  | Ok backlog ->
    List.filter_map
      (fun (t : task) ->
         match t.task_status with
         | Claimed { assignee; _ } | InProgress { assignee; _ } -> Some assignee
         | Todo | Done _ | Cancelled _ | AwaitingVerification _ -> None)
      backlog.tasks
    |> List.sort_uniq String.compare
;;

(** Update the on-disk agent state record under its own file lock.

    Task transitions ([claim], [complete], [cancel], …) need to
    reflect the new task assignment on the agent record at
    [<agents_dir>/<name>.json].  Every pre-existing call site in this
    module did the read→modify→write inline without holding any lock
    on that file — the enclosing [with_file_lock config backlog_path]
    only serializes backlog writers, not agent-state writers.  Sibling
    writers in [Coord_agent.update_agent_r] correctly take
    [with_file_lock_r config agent_file], so concurrent
    [update_agent_r] or concurrent room_task transitions can race and
    lose each other's updates.

    This helper centralises the pattern, takes [with_file_lock] on the
    agent file, and silently skips the write when the file is missing
    (matching the pre-existing [if Sys.file_exists agent_file]
    guards).  It never blocks the caller on a missing/corrupt agent
    record — the backlog transition is the source of truth and the
    agent mirror is best-effort telemetry.  On JSON parse failure the
    error is logged with the agent name for diagnostic context. *)
let update_local_agent_state config ~agent_name f =
  let agent_file =
    Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
  in
  if Sys.file_exists agent_file
  then
    with_file_lock config agent_file (fun () ->
      let json = read_json config agent_file in
      match agent_of_yojson json with
      | Ok agent -> write_json config agent_file (agent_to_yojson (f agent))
      | Error msg ->
        Log.Misc.error "update_local_agent_state: parse failed for %s: %s" agent_name msg)
;;

(** Tighter variant of [resolve_agent_name] for task ownership guards.
    Only accepts the resolved identity when it is the exact [-agent] suffix
    form of the normalised input (e.g. "keeper-coder" -> "keeper-coder-agent").
    Arbitrary prefix matches from [resolve_agent_name] that do not conform to
    this pattern are silently discarded and the normalised input is returned
    unchanged, preventing one caller from being mistakenly mapped to a
    different agent's identity. *)
let resolve_agent_name_strict config agent_name =
  let normalized = String.lowercase_ascii (String.trim agent_name) in
  let resolved = resolve_agent_name config normalized in
  if resolved = normalized
  then normalized
  else if resolved = normalized ^ "-agent"
  then resolved
  else normalized
;;

let normalize_execution_links (links : Types.task_execution_links) =
  { operation_id = trim_opt links.operation_id
  ; session_id = trim_opt links.session_id
  ; autoresearch_loop_id = trim_opt links.autoresearch_loop_id
  }
;;

let normalize_task_contract (contract : Types.task_contract) =
  { contract with
    completion_contract = normalized_string_list contract.completion_contract
  ; required_evidence = normalized_string_list contract.required_evidence
  ; inspect_gate_evidence = normalized_string_list contract.inspect_gate_evidence
  ; verify_gate_evidence = normalized_string_list contract.verify_gate_evidence
  ; links = normalize_execution_links contract.links
  }
;;

let empty_task_contract =
  { strict = false
  ; completion_contract = []
  ; required_evidence = []
  ; inspect_gate_evidence = []
  ; verify_gate_evidence = []
  ; links = { operation_id = None; session_id = None; autoresearch_loop_id = None }
  }
;;

let merge_execution_links
      (existing : Types.task_execution_links)
      ?session_id
      ?operation_id
      ?autoresearch_loop_id
      ()
  =
  { session_id =
      (match trim_opt session_id with
       | Some _ as value -> value
       | None -> trim_opt existing.session_id)
  ; operation_id =
      (match trim_opt operation_id with
       | Some _ as value -> value
       | None -> trim_opt existing.operation_id)
  ; autoresearch_loop_id =
      (match trim_opt autoresearch_loop_id with
       | Some _ as value -> value
       | None -> trim_opt existing.autoresearch_loop_id)
  }
;;

(** Merge optional OAS event_bus envelope identifiers (correlation_id,
    run_id) into the task activity payload. When both ids are absent the
    original payload is returned untouched, so existing callers compile
    and behave identically. *)
let merge_envelope_into_payload ?correlation_id ?run_id payload =
  let optional name = function
    | Some v -> [ name, `String v ]
    | None -> []
  in
  let extras = optional "correlation_id" correlation_id @ optional "run_id" run_id in
  if extras = []
  then payload
  else (
    match payload with
    | `Assoc fields -> `Assoc (fields @ extras)
    | _ ->
      Log.Misc.warn "emit_task_activity: non-Assoc payload, envelope fields skipped";
      payload)
;;

let emit_task_activity ?correlation_id ?run_id config ~agent_name ~task_id ~kind ~payload =
  let payload = merge_envelope_into_payload ?correlation_id ?run_id payload in
  try
    (Atomic.get Coord_hooks.activity_emit_fn)
      config
      ~actor:Coord_hooks.{ kind = task_actor_kind agent_name; id = agent_name }
      ~subject:Coord_hooks.{ kind = "task"; id = task_id }
      ~kind
      ~payload
      ~tags:[ "task"; kind ]
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.warn
      "task activity emit failed (%s %s): %s"
      kind
      task_id
      (Printexc.to_string exn)
;;

(* Issue #8354: was a verbatim duplicate of [Types.task_status_to_string].
   Folded to a single-line alias so adding a 7th task_status constructor
   only requires updating [Types]. The local name is kept so caller
   sites (224, 269, 863, 870, 1019, 1020) need no churn. *)
let task_status_to_string = Types.task_status_to_string

(** Current assignee from the task status, for error messages.

    LLMs that see "Invalid transition: claimed -> release" have no way
    to tell whether they're trying to release someone else's task vs
    using the wrong action name. Surfacing the current assignee in the
    failure lets the LLM see the ownership mismatch and stop retrying.

    Evidence: 2026-04-16 /loop iter 4 — 12+/15 masc_transition failures
    are "Invalid transition: claimed -> release" from keepers trying to
    release tasks owned by a different keeper. *)
let task_assignee_of_status = Types.task_assignee_of_status

(** Issue #7646: symmetric to [task_assignee_of_status]. When a transition
    fails for a reason other than ownership mismatch, surface what
    actions ARE legal from the current state so the LLM stops
    guess-retrying.

    Exhaustive [match] over [Types.task_status]: adding a 7th constructor
    will fail to compile. Each branch lists actions that
    [transition_task_r]'s match-arms accept for that status — keep this
    in sync if you add new transitions there. Verifier-FSM transitions
    require [MASC_VERIFICATION_FSM_ENABLED=true] but are listed
    unconditionally so the hint stays accurate when the flag is on; the
    flag-off case still rejects them and produces a more specific error. *)
let valid_next_actions_for_status : Types.task_status -> Types.task_action list = function
  | Types.Todo -> [ Types.Claim; Types.Cancel ]
  | Types.Claimed _ ->
    [ Types.Start
    ; Types.Done_action
    ; Types.Submit_for_verification
    ; Types.Release
    ; Types.Cancel
    ]
  | Types.InProgress _ ->
    [ Types.Done_action; Types.Submit_for_verification; Types.Release; Types.Cancel ]
  | Types.AwaitingVerification _ ->
    [ Types.Approve_verification; Types.Reject_verification ]
  | Types.Done _ | Types.Cancelled _ -> [] (* terminal *)
;;

let next_actions_hint status =
  match valid_next_actions_for_status status with
  | [] -> ""
  | xs ->
    Printf.sprintf
      ", valid_next_actions=[%s]"
      (String.concat ";" (List.map Types.task_action_to_string xs))
;;

let task_started_at_unix status =
  let default_time = Time_compat.now () in
  match status with
  | Types.Claimed { claimed_at; _ } -> Types.parse_iso8601 ~default_time claimed_at
  | Types.InProgress { started_at; _ } -> Types.parse_iso8601 ~default_time started_at
  | Types.Todo | Types.AwaitingVerification _ | Types.Done _ | Types.Cancelled _ ->
    default_time
;;

let task_transition_details
      ~from_status
      ~to_status
      ?notes
      ?reason
      ?duration_ms
      ?(forced = false)
      ()
  =
  let optional_field name = function
    | Some value -> [ name, value ]
    | None -> []
  in
  `Assoc
    ([ "from_status", `String (task_status_to_string from_status)
     ; "to_status", `String (task_status_to_string to_status)
     ; "forced", `Bool forced
     ]
     @ optional_field "notes" (Option.map (fun value -> `String value) notes)
     @ optional_field "reason" (Option.map (fun value -> `String value) reason)
     @ optional_field "duration_ms" (Option.map (fun value -> `Int value) duration_ms))
;;

let observe_task_transition
      config
      ~agent_name
      ~task_id
      ~(transition : Types.task_action)
      ~details
  =
  (Atomic.get Coord_hooks.observe_task_transition_fn)
    config
    ~agent_name
    ~task_id
    ~transition
    ~details
;;

(** Transition log event taxonomy. Variant instead of free-form string
    (#7520 Step 4) so typos at call-sites fail to compile. The two
    values correspond to the current fire points in this module — add
    a variant when a new transition event is introduced. *)
type transition_event_type =
  | Task_transition
  | Task_cancelled

let transition_event_type_to_string = function
  | Task_transition -> "task_transition"
  | Task_cancelled -> "task_cancelled"
;;

(** SSOT structured event for [log_event] sink. Wraps [task_transition_details]
    with an envelope (type/agent/actor_kind/task/from_status/to_status/ts) so
    every transition log line carries the same schema. Optional [?action]
    preserves the legacy "action" field used by the unified transition path
    so existing dashboard readers do not break. *)
let transition_log_event
      ~(event_type : transition_event_type)
      ~agent_name
      ~task_id
      ~from_status
      ~to_status
      ?action
      ?notes
      ?reason
      ?duration_ms
      ?handoff_context
      ?(forced = false)
      ?(now = now_iso ())
      ()
  : Yojson.Safe.t
  =
  let optional_field name = function
    | Some value -> [ name, value ]
    | None -> []
  in
  `Assoc
    ([ "type", `String (transition_event_type_to_string event_type)
     ; "agent", `String agent_name
     ; "actor_kind", `String (task_actor_kind agent_name)
     ; "task", `String task_id
     ; "from_status", `String (task_status_to_string from_status)
     ; "to_status", `String (task_status_to_string to_status)
     ; "forced", `Bool forced
     ; "ts", `String now
     ]
     @ optional_field "action" (Option.map (fun v -> `String v) action)
     @ optional_field "notes" (Option.map (fun v -> `String v) notes)
     @ optional_field "reason" (Option.map (fun v -> `String v) reason)
     @ optional_field "duration_ms" (Option.map (fun v -> `Int v) duration_ms)
     @ optional_field
         "handoff_context"
         (Option.map Types.task_handoff_context_to_yojson handoff_context))
;;

(** Normalize title for deduplication: lowercase, keep only alphanumeric+space.
    Deterministic string transform — no LLM involved. *)
let normalize_title_for_dedup (title : string) : string =
  let buf = Buffer.create (String.length title) in
  String.iter
    (fun c ->
       let lc = Char.lowercase_ascii c in
       if (lc >= 'a' && lc <= 'z') || (lc >= '0' && lc <= '9') || lc = ' '
       then Buffer.add_char buf lc)
    title;
  Buffer.contents buf |> String.trim
;;

(** Check if a task with a similar title already exists in the backlog.
    Returns [Some existing_task_id] if a duplicate is found, [None] otherwise.
    Uses normalized title comparison — deterministic, no fuzzy matching. *)
let find_duplicate_task (backlog : backlog) ~(title : string) ~(goal_id : string option)
  : string option
  =
  let norm = normalize_title_for_dedup title in
  if norm = ""
  then None
  else
    List.find_opt
      (fun (t : task) ->
         let t_norm = normalize_title_for_dedup t.title in
         t_norm = norm
         && Option.equal String.equal t.goal_id goal_id
         && not (Types.task_status_is_terminal t.task_status))
      backlog.tasks
    |> Option.map (fun t -> t.id)
;;

(** Add task — file-locked to prevent task ID collision under concurrency.
    Rejects tasks with duplicate titles (exact match after normalization)
    to prevent the same work from being created multiple times. *)
let add_task
      ?contract
      ?goal_id
      ?created_by
      config
      ~title
      ~priority
      ~description
  =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  let actor = Option.value ~default:"system" created_by in
  let goal_id = trim_opt goal_id in
  try
    with_file_lock config backlog_path (fun () ->
      match read_backlog_r config with
      | Error msg -> Printf.sprintf "❌ Error: %s" msg
      | Ok backlog ->
        (* Dedup guard: reject if an active task with the same normalized title exists *)
        (match find_duplicate_task backlog ~title ~goal_id with
         | Some existing_id ->
           Printf.sprintf
             "⚠️ Duplicate rejected: '%s' matches existing %s. Use that task instead."
             title
             existing_id
         | None ->
           let task_id = Printf.sprintf "task-%03d" (next_task_number config backlog) in
           let contract = Option.map normalize_task_contract contract in
           let new_task =
             { id = task_id
             ; title
             ; description
             ; goal_id
             ; task_status = Todo
             ; priority
             ; files = []
             ; created_at = now_iso ()
             ; created_by
             ; worktree = None
             ; stage = None
             ; contract
             ; handoff_context = None
             ; cycle_count = 0
             ; do_not_reclaim_reason = None
             }
           in
           let new_backlog =
             { tasks = backlog.tasks @ [ new_task ]
             ; last_updated = now_iso ()
             ; version = backlog.version + 1
             }
           in
           write_backlog config new_backlog;
           let created_by_json =
             match created_by with
             | Some value -> `String value
             | None -> `Null
           in
           emit_task_activity
             config
             ~agent_name:actor
             ~task_id
             ~kind:(Event_kind.Task.to_string Event_kind.Task.Created)
             ~payload:
               (`Assoc
                   [ "task_id", `String task_id
                   ; "title", `String title
                   ; "goal_id", Json_util.string_opt_to_json goal_id
                   ; "priority", `Int priority
                   ; "created_by", created_by_json
                   ; ( "strict_contract"
                     , `Bool
                         (match contract with
                          | Some contract -> contract.strict
                          | None -> false) )
                   ]);
           (Atomic.get Coord_hooks.on_task_mutation_fn) ();
           let _ =
             broadcast
               config
               ~from_agent:actor
               ~content:(Printf.sprintf "📋 New quest: %s" title)
           in
           Printf.sprintf "✅ Added %s: %s" task_id title))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Printf.sprintf "❌ Error: %s" (Printexc.to_string e)
;;

(** Add multiple tasks in a batch *)
let batch_add_tasks_internal ?created_by config tasks =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  let actor = Option.value ~default:"system" created_by in
  with_file_lock config backlog_path (fun () ->
    match read_backlog_r config with
    | Error msg -> Printf.sprintf "❌ Error adding batch tasks: %s" msg
    | Ok backlog ->
      (try
         let next_num = ref (next_task_number config backlog) in
         let added_tasks =
           List.map
             (fun (title, priority, description, contract, goal_id) ->
                let task_id = Printf.sprintf "task-%03d" !next_num in
                incr next_num;
                let contract = Option.map normalize_task_contract contract in
                { id = task_id
                ; title
                ; description
                ; goal_id
                ; task_status = Todo
                ; priority
                ; files = []
                ; created_at = now_iso ()
                ; created_by
                ; worktree = None
                ; stage = None
                ; contract
                ; handoff_context = None
                ; cycle_count = 0
                ; do_not_reclaim_reason = None
                })
             tasks
         in
         let new_backlog =
           { tasks = backlog.tasks @ added_tasks
           ; last_updated = now_iso ()
           ; version = backlog.version + 1
           }
         in
         write_backlog config new_backlog;
         List.iter
           (fun (task : Types.task) ->
              let created_by_json =
                match task.created_by with
                | Some value -> `String value
                | None -> `Null
              in
              emit_task_activity
                config
                ~agent_name:actor
                ~task_id:task.id
                ~kind:(Event_kind.Task.to_string Event_kind.Task.Created)
                ~payload:
                  (`Assoc
                      [ "task_id", `String task.id
                      ; "title", `String task.title
                      ; "goal_id", Json_util.string_opt_to_json task.goal_id
                      ; "priority", `Int task.priority
                      ; "created_by", created_by_json
                      ; ( "strict_contract"
                        , `Bool
                            (match task.contract with
                             | Some contract -> contract.strict
                             | None -> false) )
                      ]))
           added_tasks;
         let summary =
           String.concat ", " (List.map (fun (t : Types.task) -> t.id) added_tasks)
         in
         (Atomic.get Coord_hooks.on_task_mutation_fn) ();
         let msg =
           Printf.sprintf
             "📋 New batch of %d quests added: %s"
             (List.length added_tasks)
             summary
         in
         let _ = broadcast config ~from_agent:actor ~content:msg in
         Printf.sprintf "✅ Added %d tasks: %s" (List.length added_tasks) summary
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | e -> Printf.sprintf "❌ Error adding batch tasks: %s" (Printexc.to_string e)))
;;

let batch_add_tasks ?created_by config tasks =
  batch_add_tasks_internal
    ?created_by
    config
    (List.map
       (fun (title, priority, description, goal_id) ->
          title, priority, description, None, goal_id)
       tasks)
;;

let batch_add_tasks_with_contracts ?created_by config tasks =
  batch_add_tasks_internal ?created_by config tasks
;;

(** Claim task with file locking (TOCTOU prevention) *)
let claim_task config ~agent_name ~task_id =
  ensure_initialized config;
  (* Validate inputs *)
  match validate_agent_name agent_name, validate_task_id task_id with
  | Error e, _ -> Printf.sprintf "❌ %s" e
  | _, Error e -> Printf.sprintf "❌ %s" e
  | Ok _, Ok _ ->
    let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
    with_file_lock config backlog_path (fun () ->
      match read_backlog_r config with
      | Error msg -> Printf.sprintf "❌ Error: %s" msg
      | Ok backlog ->
        (try
           let found = ref false in
           let already_claimed = ref None in
           let blocked_reason = ref None in
           let new_tasks =
             List.map
               (fun task ->
                  if task.id = task_id
                  then (
                    found := true;
                    (* Cycle-prevention gate: see _r variant below for rationale. *)
                    (match task.do_not_reclaim_reason with
                     | Some r -> blocked_reason := Some r
                     | None -> ());
                    match task.task_status with
                    | _ when !blocked_reason <> None -> task
                    | Todo ->
                      { task with
                        task_status =
                          Claimed { assignee = agent_name; claimed_at = now_iso () }
                      }
                    | Claimed { assignee; _ }
                    | InProgress { assignee; _ }
                    | Done { assignee; _ }
                    | AwaitingVerification { assignee; _ }
                    | Cancelled { cancelled_by = assignee; _ } ->
                      already_claimed := Some assignee;
                      task)
                  else task)
               backlog.tasks
           in
           if not !found
           then Printf.sprintf "❌ Task %s not found" task_id
           else (
             match !blocked_reason with
             | Some r -> Printf.sprintf "🚫 Task %s blocked from re-claim: %s" task_id r
             | None ->
               (match !already_claimed with
                | Some other ->
                  Printf.sprintf "⚠ Task %s is already claimed by %s" task_id other
                | None ->
                  let new_backlog =
                    { tasks = new_tasks
                    ; last_updated = now_iso ()
                    ; version = backlog.version + 1
                    }
                  in
                  write_backlog config new_backlog;
                  update_local_agent_state config ~agent_name (fun agent ->
                    { agent with status = Busy; current_task = Some task_id });
                  let _ =
                    broadcast
                      config
                      ~from_agent:agent_name
                      ~content:(Printf.sprintf "📋 Claimed %s" task_id)
                  in
                  emit_task_activity
                    config
                    ~agent_name
                    ~task_id
                    ~kind:(Event_kind.Task.to_string Event_kind.Task.Claimed)
                    ~payload:(`Assoc [ "task_id", `String task_id ]);
                  log_event
                    config
                    (Yojson.Safe.to_string
                       (`Assoc
                           [ "type", `String "task_claim"
                           ; "agent", `String agent_name
                           ; "actor_kind", `String (task_actor_kind agent_name)
                           ; "task", `String task_id
                           ; "ts", `String (now_iso ())
                           ]));
                  observe_task_transition
                    config
                    ~agent_name
                    ~task_id
                    ~transition:Types.Claim
                    ~details:
                      (task_transition_details
                         ~from_status:Types.Todo
                         ~to_status:
                           (Types.Claimed
                              { assignee = agent_name; claimed_at = now_iso () })
                         ());
                  Printf.sprintf "✅ %s claimed %s" agent_name task_id))
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | e -> Printf.sprintf "❌ Error: %s" (Printexc.to_string e)))
;;

(** Result-returning version of claim_task for type-safe error handling. *)
let claim_task_r config ~agent_name ~task_id ()
  : string Types.masc_result
  =
  let open Result.Syntax in
  let* () = if not (is_initialized config) then Error Types.NotInitialized else Ok () in
  let* () =
    match validate_agent_name_r agent_name, validate_task_id_r task_id with
    | Error e, _ -> Error e
    | _, Error e -> Error e
    | Ok _, Ok _ -> Ok ()
  in
  (* BUG-005: Verify agent has joined before allowing claim. *)
  let actual_name = resolve_agent_name config agent_name in
  let filename = safe_filename actual_name ^ ".json" in
  let agent_path = Filename.concat (agents_dir config) filename in
  let agent_joined = path_exists config agent_path in
  let* () =
    if not agent_joined then Error (Types.AgentNotJoined actual_name) else Ok ()
  in
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    match read_backlog_r config with
    | Error msg -> Error (Types.IoError msg)
    | Ok backlog ->
      (try
         (* Check role constraint before attempting claim *)
         let target_task = List.find_opt (fun t -> t.id = task_id) backlog.tasks in
         let* task =
           match target_task with
           | None -> Error (Types.TaskNotFound task_id)
           | Some task -> Ok task
         in
         (* Cycle-prevention gate: refuse claim when do_not_reclaim_reason is set.
         The reason can come from cancel/release hard-stop logic or be applied
         directly by an operator. See PRs #7794 (schema), #7798 (cancel hook). *)
         let* () =
           match task.do_not_reclaim_reason with
           | None -> Ok ()
           | Some r ->
             Error
               (Types.TaskInvalidState
                  (Printf.sprintf "Task %s is blocked from re-claim: %s" task_id r))
         in
         (* fold_left to find+transform in a single pass without mutable refs.
         Uses polymorphic variants for inline state tracking. *)
         let claim_state, new_tasks =
           List.fold_left
             (fun (state, acc) t ->
                if t.id = task_id
                then (
                  match t.task_status with
                  | Todo ->
                    let t' =
                      { t with
                        task_status =
                          Claimed { assignee = agent_name; claimed_at = now_iso () }
                      }
                    in
                    `Claimed_ok, t' :: acc
                  | Claimed { assignee; _ }
                  | InProgress { assignee; _ }
                  | AwaitingVerification { assignee; _ }
                    when assignee = agent_name -> `Already_mine, t :: acc
                  | Claimed { assignee; _ }
                  | InProgress { assignee; _ }
                  | AwaitingVerification { assignee; _ }
                  | Done { assignee; _ }
                  | Cancelled { cancelled_by = assignee; _ } ->
                    `Claimed_by assignee, t :: acc)
                else state, t :: acc)
             (`Not_found, [])
             backlog.tasks
         in
         let new_tasks = List.rev new_tasks in
         match claim_state with
         | `Not_found -> Error (Types.TaskNotFound task_id)
         | `Claimed_by other -> Error (Types.TaskAlreadyClaimed { task_id; by = other })
         | `Already_mine ->
           Ok (Printf.sprintf "Task %s is already claimed by you" task_id)
         | `Claimed_ok ->
           let new_backlog =
             { tasks = new_tasks
             ; last_updated = now_iso ()
             ; version = backlog.version + 1
             }
           in
           write_backlog config new_backlog;
           update_local_agent_state config ~agent_name (fun agent ->
             { agent with status = Busy; current_task = Some task_id });
           let _ =
             broadcast
               config
               ~from_agent:agent_name
               ~content:(Printf.sprintf "📋 Claimed %s" task_id)
           in
           emit_task_activity
             config
             ~agent_name
             ~task_id
             ~kind:(Event_kind.Task.to_string Event_kind.Task.Claimed)
             ~payload:(`Assoc [ "task_id", `String task_id ]);
           log_event
             config
             (Yojson.Safe.to_string
                (`Assoc
                    [ "type", `String "task_claim"
                    ; "agent", `String agent_name
                    ; "actor_kind", `String (task_actor_kind agent_name)
                    ; "task", `String task_id
                    ; "ts", `String (now_iso ())
                    ]));
           observe_task_transition
             config
             ~agent_name
             ~task_id
             ~transition:Types.Claim
             ~details:
               (task_transition_details
                  ~from_status:Types.Todo
                  ~to_status:
                    (Types.Claimed { assignee = agent_name; claimed_at = now_iso () })
                  ());
           Ok (Printf.sprintf "✅ %s claimed %s" agent_name task_id)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | e -> Error (Types.IoError (Printexc.to_string e))))
;;

(** Unified task transition (single entrypoint).
    When [~force:true], release/cancel/done bypass the assignee guard.
    Used by keeper for orphan task cleanup. *)
let release_handoff_texts handoff_context =
  match handoff_context with
  | None -> []
  | Some handoff_context ->
    [ Some handoff_context.summary
    ; handoff_context.reason
    ; handoff_context.next_step
    ; handoff_context.failure_mode
    ]
    |> List.filter_map (function
      | None -> None
      | Some text ->
        let trimmed = String.trim text in
        if trimmed = "" then None else Some trimmed)
;;

let release_hard_stop_markers =
  [ "do not reclaim"
  ; "scope mismatch"
  ; "wrong keeper"
  ; "not found"
  ; "phantom"
  ; "repo access"
  ; "repo unavailable"
  ; "already done"
  ; "already completed"
  ; "completed by another"
  ; "invalid pr"
  ; "invalid issue"
  ]
;;

let release_should_block_reclaim handoff_context =
  List.exists
    (fun text ->
       let lower = String.lowercase_ascii text in
       List.exists
         (fun marker -> String_util.contains_substring lower marker)
         release_hard_stop_markers)
    (release_handoff_texts handoff_context)
;;

let derive_release_do_not_reclaim_reason (task : Types.task) handoff_context =
  match task.do_not_reclaim_reason with
  | Some _ as existing -> existing
  | None ->
    let next_cycle = task.cycle_count + 1 in
    let first_text =
      match release_handoff_texts handoff_context with
      | text :: _ -> Some text
      | [] -> None
    in
    if release_should_block_reclaim handoff_context
    then
      Some
        (Option.value first_text ~default:(Printf.sprintf "auto: %d releases" next_cycle))
    else if next_cycle >= 3
    then Some (Printf.sprintf "auto: %d releases" next_cycle)
    else None
;;

let transition_task_r
      config
      ~agent_name
      ~task_id
      ~action
      ?expected_version
      ?(notes = "")
      ?(reason = "")
      ?handoff_context
      ?(force = false)
      ()
  : string Types.masc_result
  =
  let open Result.Syntax in
  let* () = if not (is_initialized config) then Error Types.NotInitialized else Ok () in
  let* () =
    match validate_agent_name_r agent_name, validate_task_id_r task_id with
    | Error e, _ -> Error e
    | _, Error e -> Error e
    | Ok _, Ok _ -> Ok ()
  in
  (* BUG-006: Resolve agent name to canonical form (e.g. "keeper-coder" ->
     "keeper-coder-agent") so the assignee guard matches the name recorded
     at claim time.  Only the exact [-agent] suffix form is accepted;
     broader prefix matches from [resolve_agent_name] are discarded to
     prevent ambiguous identity mapping across keeper agent files. *)
  let agent_name = resolve_agent_name_strict config agent_name in
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    try
      match read_backlog_r config with
      | Error msg -> Error (Types.IoError msg)
      | Ok backlog ->
        let* () =
          match expected_version with
          | Some v when backlog.version <> v ->
            Error
              (Types.TaskInvalidState
                 (Printf.sprintf
                    "Version mismatch (expected %d, got %d)"
                    v
                    backlog.version))
          | _ -> Ok ()
        in
        let task_opt = List.find_opt (fun t -> t.id = task_id) backlog.tasks in
        let* task =
          match task_opt with
          | None -> Error (Types.TaskNotFound task_id)
          | Some task -> Ok task
        in
        let now = now_iso () in
        let now_ts = Time_compat.now () in
        let action_s = Types.task_action_to_string action in
        let* decision =
          match
            Coord_task_lifecycle.decide
              ~verification_enabled:(Env_config_runtime.Verification.fsm_enabled ())
              ~new_verification_id:(fun () -> Random_id.prefixed ~prefix:"vrf-" ~bytes:16)
              ~agent_name
              ~task_id
              ~task_status:task.task_status
              ~action
              ~now
              ~force
              ~notes
              ~reason
          with
          | Ok decision -> Ok decision
          | Error Coord_task_lifecycle.Self_approval ->
            Error
              (Types.TaskInvalidState
                 "Self-approval not allowed: verifier must be a different agent")
          | Error Coord_task_lifecycle.Self_rejection ->
            Error
              (Types.TaskInvalidState
                 "Self-rejection not allowed: verifier must be a different agent")
          | Error Coord_task_lifecycle.Verification_disabled ->
            Error
              (Types.TaskInvalidState
                 "Verification FSM not enabled (MASC_VERIFICATION_FSM_ENABLED=false)")
          | Error Coord_task_lifecycle.Invalid_transition ->
            let assignee_hint =
              match task_assignee_of_status task.task_status with
              | Some a when a <> agent_name -> Printf.sprintf ", current_assignee=%s" a
              | _ -> ""
            in
            (* Issue #7646: ownership-mismatch dominates; only show
               valid_next_actions when the failure isn't an ownership
               problem. Otherwise the hint risks misdirecting the LLM
               toward retrying actions it cannot perform on someone
               else's task. *)
            let actions_hint =
              if assignee_hint <> "" then "" else next_actions_hint task.task_status
            in
            (* Concrete remediation. Field evidence 2026-04-17/18 showed
               ~30 [todo -> release] rejections — keepers called release
               on tasks they never claimed, got a terse FSM error, and
               retried with the same action rather than claiming first.
               Name the exact next call to make so small-LLM keepers can
               recover on the next turn. *)
            let remediation =
              let own_assignee =
                match task_assignee_of_status task.task_status with
                | Some a when a = agent_name -> true
                | _ -> false
              in
              match task.task_status, action with
              | Types.Todo, Types.Release ->
                " Remediation: task is still in 'todo'. Call masc_transition \
                 action=claim first, then action=release once you own it."
              | Types.Todo, (Types.Done_action | Types.Cancel) ->
                " Remediation: task is still in 'todo'. Call masc_transition \
                 action=claim then action=start before trying to finish or cancel it."
              | Types.Todo, Types.Start ->
                " Remediation: task is still in 'todo'. Call masc_transition \
                 action=claim first — start needs ownership."
              | Types.Claimed _, Types.Release when not own_assignee ->
                " Remediation: this task is claimed by another keeper. Use \
                 masc_board_post to ask that agent to release/hand off, or claim a \
                 different task with masc_claim_next."
              | Types.Claimed _, Types.Done_action when not own_assignee ->
                " Remediation: only the current assignee can mark a task done. Pick a \
                 different task or coordinate via masc_board_post."
              | (Types.Claimed _ | Types.InProgress _), Types.Cancel when not own_assignee
                ->
                " Remediation: cancellation requires owning the task. Use \
                 masc_board_post to ask the current assignee to cancel or release, or \
                 claim a different task with masc_claim_next."
              | Types.InProgress _, Types.Claim ->
                " Remediation: task is already in_progress under someone. Use \
                 masc_claim_next for unclaimed work."
              | Types.Done _, _ ->
                " Remediation: task is already in a terminal state (done). Use \
                 masc_add_task for new work or masc_tasks to find claimable items."
              | Types.Cancelled _, _ ->
                " Remediation: task is already cancelled. Use masc_add_task for new work \
                 or masc_tasks to find claimable items."
              | _ -> ""
            in
            Error
              (Types.TaskInvalidState
                 (Printf.sprintf
                    "Invalid transition: %s -> %s (%s, agent=%s%s%s).%s"
                    (task_status_to_string task.task_status)
                    action_s
                    task_id
                    agent_name
                    assignee_hint
                    actions_hint
                    remediation))
        in
        let new_status = decision.Coord_task_lifecycle.new_status in
        let set_current = decision.set_current in
        (match decision.drift with
         | Some Coord_task_lifecycle.Claimed_to_done_skip ->
           (* FSM drift: TLA+ KeeperTaskInterlock.DoneTask requires in_progress.
              Log WARN so dashboards can surface keepers that skip Start. The
              jump is still permitted for client compatibility; strictness
              ratchet follows once keeper_task_start is exposed. *)
           Log.RoomTask.warn
             "fsm_drift claimed_to_done_skip task=%s agent=%s force=%b"
             task_id
             agent_name
             force
         | None -> ());
        (match action, task.task_status with
         | Types.Release, Types.Todo ->
           (* Idempotent: already in backlog, nothing to release.
              Logged at debug so that callers passing a wrong task_id
              (e.g. confused the target of a multi-task release) can
              still detect the no-op without seeing it as an error. *)
           Log.RoomTask.debug "release on already-todo task %s — no-op" task_id
       | Types.Claim, _ | Types.Start, _ | Types.Done_action, _ | Types.Cancel, _
       | Types.Submit_for_verification, _ | Types.Approve_verification, _
       | Types.Reject_verification, _
       | Types.Release, Types.Claimed _ | Types.Release, Types.InProgress _
       | Types.Release, Types.AwaitingVerification _ | Types.Release, Types.Done _
       | Types.Release, Types.Cancelled _ -> ());
      if new_status = task.task_status && set_current = None then
        (* Idempotent no-op: status unchanged, skip write/events.
           Match None explicitly so set_current=Some is never silently dropped. *)
          Ok
            (Printf.sprintf
               "✅ %s already %s (no-op)"
               task_id
               (task_status_to_string task.task_status))
        else (
          let new_tasks =
            List.map
              (fun t ->
                 if t.id = task_id
                 then (
                   let cycle_count, do_not_reclaim_reason =
                     match action with
                     | Types.Release ->
                       ( t.cycle_count + 1
                       , derive_release_do_not_reclaim_reason t handoff_context )
                     | Types.Claim
                     | Types.Start
                     | Types.Done_action
                     | Types.Cancel
                     | Types.Submit_for_verification
                     | Types.Approve_verification
                     | Types.Reject_verification -> t.cycle_count, t.do_not_reclaim_reason
                   in
                   { t with
                     task_status = new_status
                   ; handoff_context =
                       (match action with
                        | Types.Release -> handoff_context
                        | Types.Claim
                        | Types.Start
                        | Types.Done_action
                        | Types.Cancel
                        | Types.Submit_for_verification
                        | Types.Approve_verification
                        | Types.Reject_verification -> None)
                   ; cycle_count
                   ; do_not_reclaim_reason
                   })
                 else t)
              backlog.tasks
          in
          let new_backlog =
            { tasks = new_tasks
            ; last_updated = now_iso ()
            ; version = backlog.version + 1
            }
          in
          write_backlog config new_backlog;
          update_local_agent_state config ~agent_name (fun agent ->
            match set_current with
            | Some _ -> { agent with status = Busy; current_task = Some task_id }
            | None ->
              if agent.current_task = Some task_id
              then { agent with status = Active; current_task = None }
              else agent);
          log_event
            config
            (Yojson.Safe.to_string
               (transition_log_event
                  ~event_type:Task_transition
                  ~agent_name
                  ~task_id
                  ~from_status:task.task_status
                  ~to_status:new_status
                  ~action:action_s
                  ~forced:force
                  ?notes:(trim_opt (Some notes))
                  ?reason:(trim_opt (Some reason))
                  ?handoff_context:
                    (match handoff_context with
                     | Some _ when action = Types.Release -> handoff_context
                     | _ -> None)
                  ()));
          (match action with
           | Types.Claim ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Claimed)
               ~payload:(`Assoc [ "task_id", `String task_id ])
           | Types.Start ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Started)
               ~payload:(`Assoc [ "task_id", `String task_id ])
           | Types.Done_action ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Done)
               ~payload:
                 (`Assoc
                     [ "task_id", `String task_id
                     ; ("notes", if notes = "" then `Null else `String notes)
                     ])
           | Types.Cancel ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Cancelled)
               ~payload:
                 (`Assoc
                     [ "task_id", `String task_id
                     ; ("reason", if reason = "" then `Null else `String reason)
                     ])
           | Types.Release ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Released)
               ~payload:
                 (`Assoc
                     ([ "task_id", `String task_id ]
                      @
                      match handoff_context with
                      | Some handoff_context ->
                        [ ( "handoff_context"
                          , Types.task_handoff_context_to_yojson handoff_context )
                        ]
                      | None -> []))
           | Types.Submit_for_verification ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Submit_for_verification)
               ~payload:(`Assoc [ "task_id", `String task_id ])
           | Types.Approve_verification ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Approved)
               ~payload:(`Assoc [ "task_id", `String task_id ])
           | Types.Reject_verification ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Rejected)
               ~payload:(`Assoc [ "task_id", `String task_id ]));
          let duration_ms =
            match action with
            | Types.Done_action | Types.Cancel ->
              Some
                (max
                   0
                   (int_of_float
                      ((now_ts -. task_started_at_unix task.task_status) *. 1000.0)))
            | Types.Claim
            | Types.Start
            | Types.Release
            | Types.Submit_for_verification
            | Types.Approve_verification
            | Types.Reject_verification -> None
          in
          observe_task_transition
            config
            ~agent_name
            ~task_id
            ~transition:action
            ~details:
              (task_transition_details
                 ~from_status:task.task_status
                 ~to_status:new_status
                 ?notes:(if notes = "" then None else Some notes)
                 ?reason:(if reason = "" then None else Some reason)
                 ?duration_ms
                 ~forced:force
                 ());
          (match action with
           | Types.Done_action ->
             (try
                let active = (Coord_state.read_state config).active_agents in
                (Atomic.get Coord_hooks.relation_on_task_done_fn)
                  ~assignee:agent_name
                  ~active_agents:active;
                (* Hebbian: strengthen only against agents with active tasks,
                 not the full room. See working_agents doc for rationale. *)
                let workers = working_agents config in
                (Atomic.get Coord_hooks.hebbian_on_task_done_fn)
                  config
                  ~assignee:agent_name
                  ~active_agents:workers
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.RoomTask.error
                  "transition relation/hebbian done hook: %s"
                  (Printexc.to_string exn))
           | Types.Cancel ->
             (try
                let workers = working_agents config in
                (Atomic.get Coord_hooks.hebbian_on_task_cancelled_fn)
                  config
                  ~agent_name
                  ~active_agents:workers
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.RoomTask.error
                  "transition hebbian cancel hook: %s"
                  (Printexc.to_string exn))
           | Types.Claim
           | Types.Start
           | Types.Release
           | Types.Submit_for_verification
           | Types.Approve_verification
           | Types.Reject_verification -> ());
          Ok
            (Printf.sprintf
               "✅ %s %s → %s"
               task_id
               (task_status_to_string task.task_status)
               (task_status_to_string new_status)))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (Types.IoError (Printexc.to_string e)))
;;

(** Release task back to backlog - transition wrapper *)
let release_task_r config ~agent_name ~task_id ?expected_version ?handoff_context ()
  : string Types.masc_result
  =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Types.Release
    ?expected_version
    ?handoff_context
    ()
;;

(** Force-release a task regardless of assignee. Keeper privilege. *)
let force_release_task_r config ~agent_name ~task_id ?handoff_context ()
  : string Types.masc_result
  =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Types.Release
    ?handoff_context
    ~force:true
    ()
;;

(** Force-done a task regardless of assignee. Keeper privilege. *)
let force_done_task_r config ~agent_name ~task_id ~notes () : string Types.masc_result =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Types.Done_action
    ~notes
    ~force:true
    ()
;;

(** Cancel a task - A2A compatible *)
let cancel_task_r config ~agent_name ~task_id ~reason : string Types.masc_result =
  if not (is_initialized config)
  then Error Types.NotInitialized
  else (
    let agent_name = resolve_agent_name_strict config agent_name in
    let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
    with_file_lock config backlog_path (fun () ->
      try
        match read_backlog_r config with
        | Error msg -> Error (Types.IoError msg)
        | Ok backlog ->
          let task_opt = List.find_opt (fun t -> t.id = task_id) backlog.tasks in
          (match task_opt with
           | None -> Error (Types.TaskNotFound task_id)
           | Some task ->
             (* Can cancel if: Todo, Claimed by me, or InProgress by me *)
             let can_cancel =
               match task.task_status with
               | Types.Todo -> true
               | Types.Claimed { assignee; _ }
               | Types.InProgress { assignee; _ }
               | Types.AwaitingVerification { assignee; _ } -> assignee = agent_name
               | Types.Done _ | Types.Cancelled _ -> false
             in
             if not can_cancel
             then
               Error
                 (Types.TaskInvalidState
                    (Printf.sprintf
                       "Cannot cancel task %s (already done/cancelled or owned by \
                        another agent)"
                       task_id))
             else (
               let new_tasks =
                 List.map
                   (fun t ->
                      if t.id = task_id
                      then (
                        let new_cycle = t.cycle_count + 1 in
                        (* Auto-set do_not_reclaim_reason when the operator flags
                     a hard stop in the cancel reason, or after 3 cycles. *)
                        let auto_dnr =
                          match t.do_not_reclaim_reason with
                          | Some _ as existing -> existing
                          | None ->
                            let lower = String.lowercase_ascii reason in
                            let flagged =
                              String_util.contains_substring lower "do not reclaim"
                              || String_util.contains_substring lower "scope mismatch"
                            in
                            if flagged && reason <> ""
                            then Some reason
                            else if new_cycle >= 3
                            then Some (Printf.sprintf "auto: %d cancellations" new_cycle)
                            else None
                        in
                        { t with
                          task_status =
                            Types.Cancelled
                              { cancelled_by = agent_name
                              ; cancelled_at = now_iso ()
                              ; reason = (if reason = "" then None else Some reason)
                              }
                        ; cycle_count = new_cycle
                        ; do_not_reclaim_reason = auto_dnr
                        })
                      else t)
                   backlog.tasks
               in
               let new_backlog =
                 { tasks = new_tasks
                 ; last_updated = now_iso ()
                 ; version = backlog.version + 1
                 }
               in
               write_backlog config new_backlog;
               (* Update agent status if they had this task *)
               update_local_agent_state config ~agent_name (fun agent ->
                 if agent.current_task = Some task_id
                 then { agent with status = Active; current_task = None }
                 else agent);
               let msg =
                 if reason = ""
                 then Printf.sprintf "🚫 Cancelled %s" task_id
                 else Printf.sprintf "🚫 Cancelled %s - %s" task_id reason
               in
               let _ = broadcast config ~from_agent:agent_name ~content:msg in
               emit_task_activity
                 config
                 ~agent_name
                 ~task_id
                 ~kind:(Event_kind.Task.to_string Event_kind.Task.Cancelled)
                 ~payload:
                   (`Assoc
                       [ "task_id", `String task_id
                       ; ("reason", if reason = "" then `Null else `String reason)
                       ]);
               log_event
                 config
                 (Yojson.Safe.to_string
                    (transition_log_event
                       ~event_type:Task_cancelled
                       ~agent_name
                       ~task_id
                       ~from_status:task.task_status
                       ~to_status:
                         (Types.Cancelled
                            { cancelled_by = agent_name
                            ; cancelled_at = now_iso ()
                            ; reason = (if reason = "" then None else Some reason)
                            })
                       ?reason:(if reason = "" then None else Some reason)
                       ()));
               observe_task_transition
                 config
                 ~agent_name
                 ~task_id
                 ~transition:Types.Cancel
                 ~details:
                   (task_transition_details
                      ~from_status:task.task_status
                      ~to_status:
                        (Types.Cancelled
                           { cancelled_by = agent_name
                           ; cancelled_at = now_iso ()
                           ; reason = (if reason = "" then None else Some reason)
                           })
                      ?reason:(if reason = "" then None else Some reason)
                      ~duration_ms:
                        (max
                           0
                           (int_of_float
                              ((Time_compat.now ()
                                -. task_started_at_unix task.task_status)
                               *. 1000.0)))
                      ());
               (* Hebbian: weaken only against agents with active tasks *)
               (try
                  let workers = working_agents config in
                  (Atomic.get Coord_hooks.hebbian_on_task_cancelled_fn)
                    config
                    ~agent_name
                    ~active_agents:workers
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                  Log.RoomTask.error
                    "hebbian task_cancelled hook error: %s"
                    (Printexc.to_string exn));
               Ok (Printf.sprintf "🚫 %s cancelled %s" agent_name task_id)))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (Types.IoError (Printexc.to_string e))))
;;

(* Scheduling functions are in Coord_task_schedule.
   Re-export claim_next_result from Types for backward compatibility. *)
type claim_next_result = Types.claim_next_result =
  | Claim_next_claimed of
      { task_id : string
      ; title : string
      ; priority : int
      ; released_task_id : string option
      ; message : string
      }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of { excluded_count : int }
  | Claim_next_error of string

let link_task_execution_artifacts_r
      config
      ~task_id
      ?session_id
      ?operation_id
      ?autoresearch_loop_id
      ()
  : string Types.masc_result
  =
  if not (is_initialized config)
  then Error Types.NotInitialized
  else (
    let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
    with_file_lock config backlog_path (fun () ->
      try
        match read_backlog_r config with
        | Error msg -> Error (Types.IoError msg)
        | Ok backlog ->
          (match List.find_opt (fun task -> task.id = task_id) backlog.tasks with
           | None -> Error (Types.TaskNotFound task_id)
           | Some task ->
             let existing_contract =
               match task.contract with
               | Some contract -> normalize_task_contract contract
               | None -> empty_task_contract
             in
             let updated_contract =
               { existing_contract with
                 links =
                   merge_execution_links
                     existing_contract.links
                     ?session_id
                     ?operation_id
                     ?autoresearch_loop_id
                     ()
               }
               |> normalize_task_contract
             in
             let new_tasks =
               List.map
                 (fun candidate ->
                    if candidate.id = task_id
                    then { candidate with contract = Some updated_contract }
                    else candidate)
                 backlog.tasks
             in
             let new_backlog =
               { tasks = new_tasks
               ; last_updated = now_iso ()
               ; version = backlog.version + 1
               }
             in
             write_backlog config new_backlog;
             emit_task_activity
               config
               ~agent_name:"system"
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Linked)
               ~payload:
                 (`Assoc
                     ([ "task_id", `String task_id ]
                      @ (match trim_opt session_id with
                         | Some session_id -> [ "session_id", `String session_id ]
                         | None -> [])
                      @ (match trim_opt operation_id with
                         | Some operation_id -> [ "operation_id", `String operation_id ]
                         | None -> [])
                      @
                      match trim_opt autoresearch_loop_id with
                      | Some autoresearch_loop_id ->
                        [ "autoresearch_loop_id", `String autoresearch_loop_id ]
                      | None -> []));
             log_event
               config
               (Yojson.Safe.to_string
                  (`Assoc
                      ([ "type", `String "task_linked"
                       ; "agent", `String "system"
                       ; "actor_kind", `String "system"
                       ; "task", `String task_id
                       ; "ts", `String (now_iso ())
                       ]
                       @ (match trim_opt session_id with
                          | Some session_id -> [ "session_id", `String session_id ]
                          | None -> [])
                       @ (match trim_opt operation_id with
                          | Some operation_id -> [ "operation_id", `String operation_id ]
                          | None -> [])
                       @
                       match trim_opt autoresearch_loop_id with
                       | Some autoresearch_loop_id ->
                         [ "autoresearch_loop_id", `String autoresearch_loop_id ]
                       | None -> [])));
             Ok (Printf.sprintf "✅ Linked execution artifacts for %s" task_id))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (Types.IoError (Printexc.to_string e))))
;;
