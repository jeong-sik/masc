(** Goal_verification_agent — the RFC-0387 stage-2 verifier caller.

    The goal-side analogue of {!Completion_authority_agent}: an
    application-owned LLM agent, not a Keeper, with no Keeper identity, task
    action, or lifecycle. It drains the durable verification requests the gate
    persists BEFORE any model call — [Criterion_pending] rows written at goal
    creation (B2) and [Proof_pending] rows written before the phase enters
    [Verifying] (B3) — judges each through
    {!Task.Anti_rationalization.review} (so provider selection is the
    [verifier_exact] exact-output lane with frozen-order failover), and
    commits the verdict by riding the exact MCP commit path:
    {!Workspace_goals.handle_goal_transition} with the gate action, so the
    FSM decides, the ledger records, the phase writes, and the event emits —
    none of that logic is duplicated here.

    Authority is the fixed identity
    [System_llm_agent { agent_run_id = "verifier_exact" }] (RFC-0361 D7(b)):
    the handler binds [ctx.agent_name] into the verdict, and this lane's
    context names the lane. Evidence is the model's stated reason; the
    verdict channel drops the reason for [Approve], so it is captured from
    the successful [report_review_verdict] tool call via [on_tool_result],
    and the goal templates (config/prompts/goal_verification.proof.md and
    goal_verification.criterion.md) make the reason mandatory for both
    outcomes. A verdict without a stated reason is not a judgment: nothing is
    committed and the pending row stays durable.

    Failure keeps evidence: an unavailable evaluator, a malformed reply after
    all slots failed, or a refused commit leaves the pending row durable and
    schedules a maintenance-pulse retry. No wall-clock expiry anywhere. *)

type pending_kind =
  | Criterion_check
  | Completion_proof

type pending_work =
  { goal_id : string
  ; kind : pending_kind
  }

type process_outcome =
  | Committed
  | Deferred of { retryable : bool }

let should_schedule_retry = function
  | Committed -> false
  | Deferred { retryable } -> retryable
;;

let pending_kind_to_string = function
  | Criterion_check -> "criterion"
  | Completion_proof -> "proof"
;;

let pending_work_equal left right =
  String.equal left.goal_id right.goal_id
  && (match left.kind, right.kind with
      | Criterion_check, Criterion_check | Completion_proof, Completion_proof -> true
      | Criterion_check, Completion_proof | Completion_proof, Criterion_check -> false)
;;

(* {1 Scan}

   One ledger load per wake, joined in memory — never a decode per row. The
   P0-2 cross-check runs here: a goal whose phase is [Verifying] but whose
   ledger row lost the durable proof request is re-armed via
   [mark_proof_pending] and joins the work set, the same recovery
   [answer_verifying_repeat] performs on the MCP surface. A [Verifying] goal
   with a committed verdict ([Proof_proven] / [Human_confirmed]) is the
   crash-between-writes case the keeper's repeated [request_complete]
   reconciles; the lane must not overwrite that verdict. *)

let collect_pending config : (pending_work list, string) result =
  match Goal_verification.load_records config with
  | Error _ as error -> error
  | Ok records ->
    let from_rows =
      List.concat_map
        (fun (record : Goal_verification.record) ->
           let criterion =
             match record.criterion with
             | Goal_verification.Criterion_pending _ ->
               [ { goal_id = record.goal_id; kind = Criterion_check } ]
             | Goal_verification.Criterion_unchecked
             | Goal_verification.Criterion_viable _
             | Goal_verification.Criterion_unreachable _ -> []
           in
           let proof =
             match record.completion with
             | Goal_verification.Proof_pending _ ->
               [ { goal_id = record.goal_id; kind = Completion_proof } ]
             | Goal_verification.Completion_idle
             | Goal_verification.Proof_proven _
             | Goal_verification.Proof_refuted _
             | Goal_verification.Human_confirmed _ -> []
           in
           criterion @ proof)
        records
    in
    let rearmed =
      Goal_store.list_goals config ~phase:Goal_phase.Verifying ()
      |> List.filter_map (fun (goal : Goal_store.goal) ->
        if
          List.exists
            (fun work ->
               (match work.kind with
                | Completion_proof -> true
                | Criterion_check -> false)
               && String.equal work.goal_id goal.id)
            from_rows
        then None
        else
          match
            List.find_opt
              (fun (record : Goal_verification.record) ->
                String.equal record.goal_id goal.id)
              records
          with
          | Some
              { Goal_verification.completion =
                  ( Goal_verification.Proof_proven _
                  | Goal_verification.Human_confirmed _
                  | Goal_verification.Proof_pending _ )
              ; _
              } -> None
          | Some
              { Goal_verification.completion =
                  ( Goal_verification.Completion_idle
                  | Goal_verification.Proof_refuted _ )
              ; _
              }
          | None ->
            (match Goal_verification.mark_proof_pending config ~goal_id:goal.id with
             | Ok _ ->
               Log.Misc.info
                 "goal verifier re-armed a missing proof request (P0-2) goal_id=%s"
                 goal.id;
               Some { goal_id = goal.id; kind = Completion_proof }
             | Error msg ->
               Log.Misc.error
                 "goal verifier could not re-arm a missing proof request goal_id=%s \
                  detail=%s"
                 goal.id
                 msg;
               None))
    in
    Ok (from_rows @ rearmed)
;;

(* {1 Review request construction}

   The request rides the task-shaped {!Task.Anti_rationalization.review_request}
   record; the goal shape lives in the prompt templates
   (config/prompts/goal_verification.proof.md and
   goal_verification.criterion.md), which render [task_title] as the
   goal title, [task_description] as the declared success criterion
   (B1 makes metric/target_value mandatory at creation), and
   [completion_notes] as the goal record (criterion review) or the
   linked-task rollup (proof review). *)

let criterion_description (goal : Goal_store.goal) =
  let field name = function
    | Some value when String.trim value <> "" -> Printf.sprintf "%s: %s" name value
    | Some _ | None -> Printf.sprintf "%s: (not declared)" name
  in
  String.concat
    "\n"
    [ field "metric" goal.metric
    ; field "target_value" goal.target_value
    ; field "due_date" goal.due_date
    ]
;;

let task_rollup_json (task : Masc_domain.task) =
  let status_fields =
    match task.task_status with
    | Masc_domain.Done { assignee; completed_at; notes } ->
      [ "assignee", `String assignee
      ; "completed_at", `String completed_at
      ; ( "notes"
        , match notes with
          | Some notes -> `String notes
          | None -> `Null )
      ]
    | Masc_domain.Todo
    | Masc_domain.Claimed _
    | Masc_domain.InProgress _
    | Masc_domain.AwaitingVerification _
    | Masc_domain.Cancelled _ -> []
  in
  `Assoc
    ([ "task_id", `String task.id
     ; "title", `String task.title
     ; "status", `String (Masc_domain.task_status_to_string task.task_status)
     ]
     @ status_fields)
;;

(* A backlog that does not read is infrastructure failure: the proof review
   defers rather than judging a goal on an absent rollup. *)
let linked_task_rollup config ~goal_id : (string, string) result =
  match Workspace_backlog.read_backlog_r config with
  | Error detail -> Error detail
  | Ok backlog ->
    let goal_task_links = Workspace_goal_index.read_goal_task_links config in
    let index =
      Workspace_goal_index.build_goal_task_index ~goal_task_links backlog.tasks
    in
    let tasks = Workspace_goal_index.tasks_for_goal index ~goal_id in
    Ok (Yojson.Safe.pretty_to_string (`List (List.map task_rollup_json tasks)))
;;

let goal_owner_name (goal : Goal_store.goal) =
  match goal.owner with
  | Some owner when String.trim owner <> "" -> owner
  | Some _ | None -> "unassigned"
;;

let build_review_request config (goal : Goal_store.goal) kind
  : (Task.Anti_rationalization.review_request * string, string) result
  =
  let base =
    { Task.Anti_rationalization.task_title = goal.title
    ; task_description = criterion_description goal
    ; completion_notes = ""
    ; agent_name = goal_owner_name goal
    ; task_id = goal.id
    ; evidence_refs = []
    }
  in
  match kind with
  | Criterion_check ->
    Ok
      ( { base with
          Task.Anti_rationalization.completion_notes =
            Yojson.Safe.pretty_to_string (Goal_store.goal_to_yojson goal)
        }
      , Prompt_names.goal_verification_criterion )
  | Completion_proof ->
    (match linked_task_rollup config ~goal_id:goal.id with
     | Error _ as error -> error
     | Ok rollup ->
       Ok
         ( { base with Task.Anti_rationalization.completion_notes = rollup }
         , Prompt_names.goal_verification_proof ))
;;

(* {1 Verdict commit}

   The commit rides the MCP handler itself — FSM decide, ledger commit, phase
   write, event — with the lane's fixed identity as the session name. The
   action strings come from {!Goal_phase.action_to_string}; nothing here
   matches on them. *)

let commit_gate_verdict config ~goal_id ~action ~evidence ~note
  : (unit, string) result
  =
  let ctx : Workspace_types.context =
    { config
    ; agent_name = Task.Anti_rationalization.verifier_exact_lane_id
    }
  in
  let args =
    `Assoc
      ([ "goal_id", `String goal_id
       ; "action", `String (Goal_phase.action_to_string action)
       ; "evidence", `String evidence
       ]
       @
       match note with
       | Some note -> [ "note", `String note ]
       | None -> [])
  in
  let result =
    Workspace_goals.handle_goal_transition
      ~tool_name:"masc_goal_transition"
      ~start_time:(Time_compat.now ())
      ctx
      args
  in
  if Tool_result.is_success result
  then Ok ()
  else Error (Tool_result.message result)
;;

(* {1 Processing} *)

let defer ~goal_id ~kind ~retryable ~reason =
  Log.Misc.warn
    "goal verifier deferred goal_id=%s kind=%s retryable=%b reason=%s"
    goal_id
    (pending_kind_to_string kind)
    retryable
    reason;
  Deferred { retryable }
;;

let process_pending_work ?(sw : Eio.Switch.t option = None) config (work : pending_work)
  : process_outcome
  =
  match Goal_store.get_goal config ~goal_id:work.goal_id with
  | None ->
    (* The row stays durable — failure keeps evidence — but retrying cannot
       conjure the goal back; the next wake rescan reports the same. *)
    defer
      ~goal_id:work.goal_id
      ~kind:work.kind
      ~retryable:false
      ~reason:"pending verification row names a goal that does not exist"
  | Some goal ->
    (match work.kind, goal.Goal_store.phase with
     | Completion_proof, Goal_phase.Verifying
     | Criterion_check, Goal_phase.Executing
     | Criterion_check, Goal_phase.Blocked
     | Criterion_check, Goal_phase.Paused
     | Criterion_check, Goal_phase.Verifying ->
       (match build_review_request config goal work.kind with
        | Error detail ->
          defer ~goal_id:work.goal_id ~kind:work.kind ~retryable:true ~reason:detail
        | Ok (review_request, prompt_name) ->
          (* The verdict channel drops the reason for [Approve]; capture the
             stated reason from the successful verdict tool call — exactly one
             such call exists per review, and it belongs to the winning slot
             (a slot that recorded a verdict never fails over). *)
          let stated_reason = ref None in
          let on_tool_result ~input result =
            if Tool_result.is_success result
            then
              match
                Task.Anti_rationalization.parse_review_verdict_from_json input
              with
              | Ok _ ->
                (match Json_util.get_string input "reason" with
                 | Some reason when String.trim reason <> "" ->
                   stated_reason := Some reason
                 | Some _ | None -> ())
              | Error _ -> ()
          in
          let result =
            Task.Anti_rationalization.review
              ~base_path:config.base_path
              ~sw
              ~prompt_name
              ~lookup:Task.Anti_rationalization.No_lookup_surface
              ~on_tool_result
              review_request
          in
          (match result.verdict with
           | None ->
             let detail =
               match result.fallback_reason with
               | Some reason -> reason
               | None -> Task.Anti_rationalization.gate_to_string result.gate
             in
             defer
               ~goal_id:work.goal_id
               ~kind:work.kind
               ~retryable:result.retryable
               ~reason:detail
           | Some review_verdict ->
             let evidence =
               match review_verdict with
               | Task.Anti_rationalization.Reject reason -> Some reason
               | Task.Anti_rationalization.Approve -> !stated_reason
             in
             (match evidence with
              | Some evidence when String.trim evidence <> "" ->
                let action, note =
                  match work.kind, review_verdict with
                  | Completion_proof, Task.Anti_rationalization.Approve ->
                    Goal_phase.Record_proof_proven, None
                  | Completion_proof, Task.Anti_rationalization.Reject reason ->
                    Goal_phase.Record_proof_refuted, Some reason
                  | Criterion_check, Task.Anti_rationalization.Approve ->
                    Goal_phase.Record_criterion_viable, None
                  | Criterion_check, Task.Anti_rationalization.Reject reason ->
                    Goal_phase.Record_criterion_unreachable, Some reason
                in
                (match
                   commit_gate_verdict
                     config
                     ~goal_id:work.goal_id
                     ~action
                     ~evidence
                     ~note
                 with
                 | Ok () ->
                   Log.Misc.info
                     "goal verifier committed goal_id=%s kind=%s verdict=%s"
                     work.goal_id
                     (pending_kind_to_string work.kind)
                     (Task.Anti_rationalization.verdict_constructor_name
                        review_verdict);
                   Committed
                 | Error detail ->
                   (* A refused commit (stale verifier answer, a phase that
                      moved under the review) consumes nothing: the pending
                      row stays durable and the next pulse re-reads it. *)
                   defer
                     ~goal_id:work.goal_id
                     ~kind:work.kind
                     ~retryable:true
                     ~reason:detail)
              | Some _ | None ->
                defer
                  ~goal_id:work.goal_id
                  ~kind:work.kind
                  ~retryable:true
                  ~reason:
                    "verdict without a stated reason is not a judgment; the \
                     pending row stays durable")))
     | Completion_proof, Goal_phase.Executing
     | Completion_proof, Goal_phase.Blocked
     | Completion_proof, Goal_phase.Paused ->
       (* The crash window of persist-before-model-call: the durable request
          exists but the phase write never landed. Reviewing now would produce
          a verdict the FSM must refuse ([Executing, Record_proof_*] is
          invalid), so the lane waits — the keeper's repeated
          [request_complete] re-converges the phase onto the pending row. *)
       defer
         ~goal_id:work.goal_id
         ~kind:work.kind
         ~retryable:true
         ~reason:
           "proof request is pending but the phase never entered verifying; \
            waiting for the gate to re-converge"
     | Completion_proof, Goal_phase.Completed
     | Completion_proof, Goal_phase.Dropped ->
       defer
         ~goal_id:work.goal_id
         ~kind:work.kind
         ~retryable:false
         ~reason:"proof request pending on a terminal goal; left durable"
     | Criterion_check, Goal_phase.Completed
     | Criterion_check, Goal_phase.Dropped ->
       (* Criterion verdicts are invalid on terminal goals — the creation-time
          declaration is settled history (RFC-0387 §5). The row stays durable
          as the honest record of a request that was never judged. *)
       defer
         ~goal_id:work.goal_id
         ~kind:work.kind
         ~retryable:false
         ~reason:"criterion request pending on a terminal goal; left durable")
;;

let drain_once ?(sw : Eio.Switch.t option = None) config : (unit, string) result =
  match collect_pending config with
  | Error _ as error -> error
  | Ok work ->
    List.iter
      (fun item ->
         (* RFC-0387: per-row outcomes are logged at the point of decision
            (commit/defer) and drive retry only inside the daemon's
            [process_work]; the synchronous drain discards them. *)
         (* fire-and-forget: per-row results are durable in the ledger. *)
         ignore (process_pending_work ~sw config item))
      work;
    Ok ()
;;

(* {1 Daemon}

   Mirrors {!Completion_authority_agent}: a condition-variable wake installed
   as {!Workspace_hooks.goal_verification_pending_fn}, bounded concurrency via
   a semaphore, and a maintenance-pulse-interval retry timer as the backstop
   for typed non-verdicts. No wall-clock expiry: a pending row is durable
   until a verdict commits over it. *)

type runtime =
  { config : Workspace_utils_backend_setup.config
  ; sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; wake : Eio.Condition.t
  ; pending : bool Atomic.t
  ; retry_scheduled : bool Atomic.t
  ; retry_interval_sec : float
  ; in_flight : pending_work list Atomic.t
  ; review_slots : Eio.Semaphore.t
  }

let active_runtime : runtime option Atomic.t = Atomic.make None

let claim_review (runtime : runtime) work =
  let rec loop () =
    let current = Atomic.get runtime.in_flight in
    if List.exists (pending_work_equal work) current
    then false
    else if Atomic.compare_and_set runtime.in_flight current (work :: current)
    then true
    else loop ()
  in
  loop ()
;;

let release_review (runtime : runtime) work =
  let rec loop () =
    let current = Atomic.get runtime.in_flight in
    let next =
      List.filter (fun candidate -> not (pending_work_equal candidate work)) current
    in
    if List.length next = List.length current
    then ()
    else if Atomic.compare_and_set runtime.in_flight current next
    then ()
    else loop ()
  in
  loop ()
;;

let request_scan (runtime : runtime) =
  Atomic.set runtime.pending true;
  Eio.Condition.broadcast runtime.wake
;;

let schedule_retry (runtime : runtime) =
  if Atomic.compare_and_set runtime.retry_scheduled false true
  then
    Eio.Fiber.fork ~sw:runtime.sw (fun () ->
      Eio.Time.sleep runtime.clock runtime.retry_interval_sec;
      Atomic.set runtime.retry_scheduled false;
      request_scan runtime)
;;

let process_work (runtime : runtime) work =
  if claim_review runtime work
  then (
    let outcome =
      Fun.protect
        ~finally:(fun () -> release_review runtime work)
        (fun () ->
           process_pending_work ~sw:(Some runtime.sw) runtime.config work)
    in
    if should_schedule_retry outcome then schedule_retry runtime)
  else
    Log.Misc.debug
      "goal verifier skipped duplicate in-flight review goal_id=%s kind=%s"
      work.goal_id
      (pending_kind_to_string work.kind)
;;

let process_pending (runtime : runtime) =
  match collect_pending runtime.config with
  | Error detail ->
    Log.Misc.error
      "goal verifier ledger read failed; pending rows remain undrained: %s"
      detail;
    schedule_retry runtime
  | Ok work ->
    List.iter
      (fun item ->
         Eio.Fiber.fork ~sw:runtime.sw (fun () ->
           Eio.Semaphore.acquire runtime.review_slots;
           (* fun-protect-finally-ok: [Eio.Semaphore.release] is
              non-suspending and must return the bounded review slot on
              normal completion, exception, or cancellation. *)
           Fun.protect
             ~finally:(fun () -> Eio.Semaphore.release runtime.review_slots)
             (fun () -> process_work runtime item)))
      work
;;

let run (runtime : runtime) : [ `Stop_daemon ] =
  Eio.Condition.loop_no_mutex runtime.wake (fun () ->
    if Atomic.exchange runtime.pending false
    then (
      process_pending runtime;
      None)
    else None)
;;

let install_callback (runtime : runtime) =
  Atomic.set Workspace_hooks.goal_verification_pending_fn
    (fun config ~goal_id ->
       if not (String.equal config.base_path runtime.config.base_path)
       then
         Log.Misc.error
           "goal verifier rejected wake from another base path goal_id=%s"
           goal_id
       else if String.equal (String.trim goal_id) ""
       then Log.Misc.error "goal verifier rejected an empty goal id"
       else (
         request_scan runtime;
         Log.Misc.info "goal verifier scheduled goal_id=%s" goal_id))
;;

let start ~sw ~clock ~(config : Workspace_utils_backend_setup.config) =
  Eio.Switch.check sw;
  let runtime =
    { config
    ; sw
    ; clock
    ; wake = Eio.Condition.create ()
    ; pending = Atomic.make true
    ; retry_scheduled = Atomic.make false
    ; retry_interval_sec = Env_config.Timeouts.maintenance_pulse_interval_sec
    ; in_flight = Atomic.make []
    ; review_slots = Eio.Semaphore.make 4
    }
  in
  let owner = Some runtime in
  match Atomic.compare_and_set active_runtime None owner with
  | false ->
    (match Atomic.get active_runtime with
     | Some active when String.equal active.config.base_path config.base_path ->
       Log.Misc.warn
         "goal verifier already started for base path %s"
         config.base_path
     | Some active ->
       Log.Misc.error
         "goal verifier already owns base path %s; refusing second base path %s"
         active.config.base_path
         config.base_path
     | None ->
       (* A concurrent starter won the CAS between the failed read and this
          branch. The next bootstrap owns the diagnostic; no duplicate lane is
          created here. *)
       Log.Misc.error "goal verifier start race left no visible owner")
  | true ->
    let previous_pending_hook =
      Atomic.get Workspace_hooks.goal_verification_pending_fn
    in
    install_callback runtime;
    Eio.Switch.on_release sw (fun () ->
      if Atomic.compare_and_set active_runtime owner None
      then
        Atomic.set
          Workspace_hooks.goal_verification_pending_fn
          previous_pending_hook);
    Eio.Fiber.fork_daemon ~sw (fun () -> run runtime)
;;

module For_testing = struct
  let collect_pending = collect_pending
  let process_pending_work = process_pending_work
  let drain_once = drain_once

  type nonrec pending_kind = pending_kind =
    | Criterion_check
    | Completion_proof

  type nonrec pending_work = pending_work = {
    goal_id : string;
    kind : pending_kind;
  }

  type nonrec process_outcome = process_outcome =
    | Committed
    | Deferred of { retryable : bool }

  let should_schedule_retry = should_schedule_retry
end
