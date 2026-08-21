(** Goal_verification_agent — the RFC-0387 stage-2 verifier caller.

    The goal-side analogue of {!Completion_authority_agent}: an
    application-owned LLM agent, not a Keeper, with no Keeper identity, task
    action, or lifecycle. It drains the durable verification requests the gate
    persists BEFORE any model call — [Criterion_pending] rows written at goal
    creation (B2) and [Proof_pending] rows written before the phase enters
    [Verifying] (B3) — judges each through
    {!Task.Anti_rationalization.review} (so provider selection is the
    [verifier_exact] exact-output lane with frozen-order failover), and
    commits the verdict through the typed internal boundary
    {!Workspace_goals.commit_verifier_decision}, so the FSM decides, the
    ledger records, the phase writes, and the event emits — none of that
    logic is duplicated here and no public MCP action can name a verdict.

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
  | Deferred of
      { retryable : bool
      ; reason : string
      }

let should_schedule_retry = function
  | Committed -> false
  | Deferred { retryable; reason = _ } -> retryable
;;

let pending_kind_to_string = function
  | Criterion_check -> "criterion"
  | Completion_proof -> "proof"
;;

let pending_work_same_goal left right = String.equal left.goal_id right.goal_id

let pending_kind_rank = function
  | Criterion_check -> 0
  | Completion_proof -> 1
;;

(* A goal's criterion must settle before its completion proof can run. Keep
   ledger order within each goal (the scanner emits criterion before proof)
   while preserving first-goal order for deterministic worker admission. *)
let group_pending_by_goal work =
  let groups = Hashtbl.create (List.length work) in
  let goal_order = ref [] in
  List.iter
    (fun item ->
       match Hashtbl.find_opt groups item.goal_id with
       | Some existing -> Hashtbl.replace groups item.goal_id (existing @ [ item ])
       | None ->
         goal_order := item.goal_id :: !goal_order;
         Hashtbl.add groups item.goal_id [ item ])
    work;
  List.rev_map
    (fun goal_id ->
       Hashtbl.find groups goal_id
       |> List.stable_sort (fun left right ->
         Int.compare (pending_kind_rank left.kind) (pending_kind_rank right.kind)))
    !goal_order
;;

(* {1 Scan}

   One ledger load per wake, joined in memory — never a decode per row. The
   P0-2 cross-check runs here: a goal whose phase is [Verifying] but whose
   ledger row lost the durable proof request is re-armed via
   [mark_proof_pending] and joins the work set, the same recovery
   [answer_verifying_repeat] performs on the MCP surface. A [Verifying] goal
   with a committed proof verdict is the crash-between-writes case: the exact
   stored verdict reconciles the missing phase/event effect without another
   model call or ledger rewrite. *)

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
             | Goal_verification.Proof_refuted _ -> []
           in
           criterion @ proof)
        records
    in
    let rec reconcile_verifying acc = function
      | [] -> Ok (List.rev acc)
      | (goal : Goal_store.goal) :: rest ->
        if
          List.exists
            (fun work ->
               (match work.kind with
                | Completion_proof -> true
                | Criterion_check -> false)
               && String.equal work.goal_id goal.id)
            from_rows
        then reconcile_verifying acc rest
        else
          match
            List.find_opt
              (fun (record : Goal_verification.record) ->
                String.equal record.goal_id goal.id)
              records
          with
          | Some
              { Goal_verification.completion = Goal_verification.Proof_pending _; _ } ->
            reconcile_verifying acc rest
          | Some
              { Goal_verification.completion =
                  (Goal_verification.Proof_proven _ | Goal_verification.Proof_refuted _)
              ; _
              } ->
            (match Workspace_goals.reconcile_committed_proof config ~goal_id:goal.id with
             | Error detail ->
               Error
                 (Printf.sprintf
                    "goal verifier could not reconcile committed proof goal_id=%s \
                     detail=%s"
                    goal.id
                    detail)
             | Ok Workspace_goals.No_committed_proof ->
               Error
                 (Printf.sprintf
                    "goal verifier saw a committed proof but reconciliation \
                     found none goal_id=%s"
                    goal.id)
             | Ok (Workspace_goals.Reconciled phase) ->
               Log.Misc.info
                 "goal verifier reconciled committed proof after restart \
                  goal_id=%s phase=%s"
                 goal.id
                 (Goal_phase.to_string phase);
               reconcile_verifying acc rest
             | Ok (Workspace_goals.Reconciliation_not_needed phase) ->
               Log.Misc.info
                 "goal verifier skipped proof reconciliation after concurrent \
                  phase change goal_id=%s phase=%s"
                 goal.id
                 (Goal_phase.to_string phase);
               reconcile_verifying acc rest)
          | Some
              { Goal_verification.completion = Goal_verification.Completion_idle; _ }
          | None ->
            (match Goal_verification.mark_proof_pending config ~goal_id:goal.id with
             | Ok _ ->
               Log.Misc.info
                 "goal verifier re-armed a missing proof request (P0-2) goal_id=%s"
                 goal.id;
               reconcile_verifying
                 ({ goal_id = goal.id; kind = Completion_proof } :: acc)
                 rest
             | Error msg ->
               Error
                 (Printf.sprintf
                    "goal verifier could not re-arm a missing proof request \
                     goal_id=%s detail=%s"
                    goal.id
                    msg))
    in
    (match
       reconcile_verifying
         []
         (Goal_store.list_goals config ~phase:Goal_phase.Verifying ())
     with
     | Error _ as error -> error
     | Ok rearmed -> Ok (from_rows @ rearmed))
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
  let verification_evidence =
    Task.Completion_review.concrete_verification_evidence task
  in
  let producer = Masc_domain.task_performer_of_status task.task_status in
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
     ; ( "producer"
       , match producer with
         | Some producer -> `String producer
         | None -> `Null )
     ; ( "verification_evidence"
       , Task.Completion_review.verification_evidence_to_yojson
           verification_evidence )
     ]
     @ status_fields)
;;

let task_submitted_evidence (task : Masc_domain.task) =
  let evidence =
    Task.Completion_review.concrete_verification_evidence task
  in
  evidence.Task.Completion_review.submitted_evidence
;;

(* A backlog that does not read is infrastructure failure: the proof review
   defers rather than judging a goal on an absent rollup. *)
let linked_task_rollup config ~goal_id
  : (string * string list * Masc_domain.task list, string) result
  =
  match Workspace_backlog.read_backlog_r config with
  | Error detail -> Error detail
  | Ok backlog ->
    (match Workspace_goal_index.read_goal_task_links_r config with
     | Error detail -> Error detail
     | Ok goal_task_links ->
       let index =
         Workspace_goal_index.build_goal_task_index ~goal_task_links backlog.tasks
       in
       let tasks = Workspace_goal_index.tasks_for_goal index ~goal_id in
       let evidence_refs =
         tasks
         |> List.concat_map task_submitted_evidence
         |> List.sort_uniq String.compare
       in
       Ok
         ( Yojson.Safe.pretty_to_string (`List (List.map task_rollup_json tasks))
         , evidence_refs
         , tasks ))
;;

(* [review_request] is task-shaped and its [agent_name] names the producer whose
   work is being judged. A Goal has no producer: it is a shared intent that any
   Keeper may advance, and the evidence under review is the Goal's own declared
   criterion plus its linked Task rollup, not one agent's submission. The lane
   passes [No_lookup_surface], so this string builds no producer-bound tool
   surface -- it only tells the judge there is no single author to attribute. *)
let goal_producer_name = "no single producer (shared Goal)"

let task_producer (task : Masc_domain.task) =
  match Masc_domain.task_performer_of_status task.task_status with
  | Some producer when not (String.equal (String.trim producer) "") -> Ok producer
  | Some _ | None ->
    Error
      (Printf.sprintf
         "linked task %s has no performer tree for Goal verification"
         task.id)
;;

let rec task_producers = function
  | [] -> Ok []
  | task :: rest ->
    let open Result.Syntax in
    let* producer = task_producer task in
    let* producers = task_producers rest in
    Ok (producer :: producers)
;;

let linked_task_lookup config tasks =
  let open Result.Syntax in
  let* producers = task_producers tasks in
  let producers = List.sort_uniq String.compare producers in
  let* tools =
    Verification_authority_tools.create_forest ~config ~producers
  in
  let* root_layout = Verification_authority_tools.forest_root_layout tools in
  Ok
    (Task.Anti_rationalization.Lookup_tools
       { schemas = Verification_authority_tools.forest_schemas tools
       ; dispatch = Verification_authority_tools.dispatch_forest tools
       ; scope = Task.Anti_rationalization.Producer_forest { producers }
       ; root_layout
       })
;;

let build_review_request config (goal : Goal_store.goal) kind
  : ( Task.Anti_rationalization.review_request
      * string
      * Task.Anti_rationalization.lookup_surface
    , string )
      result
  =
  let base =
    { Task.Anti_rationalization.task_title = goal.title
    ; task_description = criterion_description goal
    ; completion_notes = ""
    ; agent_name = goal_producer_name
    ; task_id = goal.id
    ; evidence_refs = []
    }
  in
  match kind with
  | Criterion_check ->
    (* The creation-time check judges the declared success condition itself --
       whether it names something a verifier could later measure. No tree
       answers that, and there is no producer to name: nobody has done work on
       a Goal that was just created. [No_lookup_surface] states that the
       criterion text is the whole of what was checked. *)
    Ok
      ( { base with
          Task.Anti_rationalization.completion_notes =
            Yojson.Safe.pretty_to_string (Goal_store.goal_to_yojson goal)
        }
      , Prompt_names.goal_verification_criterion
      , Task.Anti_rationalization.No_lookup_surface )
  | Completion_proof ->
    (match linked_task_rollup config ~goal_id:goal.id with
     | Error _ as error -> error
     (* [admit_proof_against_criterion] refuses a proof with no linked Task, so
        this is unreachable. It fails loudly rather than building a review with
        no evidence and no tree: if the admission ever stops covering this, the
        judge must not silently rate the claim against itself. *)
     | Ok (_, _, []) ->
       Error
         "proof review reached build with no linked Task; admission should \
          have refused it"
     | Ok (rollup, evidence_refs, tasks) ->
       let open Result.Syntax in
       let* lookup = linked_task_lookup config tasks in
       Ok
         ( { base with
             Task.Anti_rationalization.completion_notes = rollup
           ; evidence_refs
           }
         , Prompt_names.goal_verification_proof
         , lookup ))
;;

(* {1 Verdict commit}

   The application-owned worker crosses a typed internal boundary. Public MCP
   callers can request lifecycle changes but cannot name verifier verdicts or
   impersonate the fixed verifier authority. *)

let commit_gate_verdict config ~goal_id ~verification_run_id ~decision ~evidence
  : (unit, string) result
  =
  let result =
    Workspace_goals.commit_verifier_decision
      ~tool_name:"goal_verifier_commit"
      ~start_time:(Time_compat.now ())
      config
      ~goal_id
      ~verification_run_id
      ~decision
      ~evidence
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
  Deferred { retryable; reason }
;;

let admit_proof_against_criterion config (work : pending_work) =
  match work.kind with
  | Criterion_check -> Ok ()
  | Completion_proof ->
    (match Goal_verification.get_record config ~goal_id:work.goal_id with
     | Error detail -> Error (true, detail)
     | Ok None ->
       Error (true, "proof request has no verification ledger record")
     | Ok (Some record) ->
       (match record.Goal_verification.criterion with
        | Goal_verification.Criterion_viable _ ->
          (* A completion proof is judged against the linked Tasks: their
             rollup is the evidence and their performers are the trees the
             judge may open. With no linked Task there is neither. The Goal's
             own metric and target are the CLAIM under review, so letting the
             review proceed on those alone would let the judge approve the
             claim by reading the claim -- the independent proof gate would be
             satisfied by prose.

             Retryable: nothing is wrong with the request, there is just
             nothing to verify yet. The pending row stays durable, and the
             first linked Task makes the next drain admissible. *)
          (match linked_task_rollup config ~goal_id:work.goal_id with
           | Error detail -> Error (true, detail)
           | Ok (_, _, []) ->
             Error
               ( true
               , "proof has no linked Task: the Goal's own metric and target \
                  are the claim under review, not evidence for it" )
           | Ok (_, _, _ :: _) -> Ok ())
        | Goal_verification.Criterion_pending _
        | Goal_verification.Criterion_unchecked ->
          Error
            ( true
            , "proof waits until the durable criterion verdict is viable" )
        | Goal_verification.Criterion_unreachable _ ->
          Error
            ( false
            , "proof refused because the durable criterion is unreachable" )))
;;

let process_pending_work_inner
      ?(sw : Eio.Switch.t option = None)
      ~observe_tool
      ~observe_evaluator_runtime
      ~persist_reviewed
      ~verification_run_id
      config
      (work : pending_work)
  : process_outcome
  =
  match admit_proof_against_criterion config work with
  | Error (retryable, reason) ->
    defer ~goal_id:work.goal_id ~kind:work.kind ~retryable ~reason
  | Ok () ->
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
        | Ok (review_request, prompt_name, lookup) ->
          (* The verdict channel drops the reason for [Approve]; capture the
             stated reason from the successful verdict tool call — exactly one
             such call exists per review, and it belongs to the winning slot
             (a slot that recorded a verdict never fails over). *)
          let stated_reason = ref None in
          let on_tool_result ~input result =
            observe_tool ~input result;
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
              ~lookup
              ~on_tool_result
              review_request
          in
          observe_evaluator_runtime result.evaluator_runtime;
          (match result.verdict with
           | None ->
             let detail =
               match result.fallback_reason with
               | Some reason -> reason
               | None -> Task.Anti_rationalization.gate_to_string result.gate
             in
             (* No verdict was committed. Only a typed evaluator error says
                anything about whether a repeat would end differently; without
                one — a reply that skipped the verdict tool call, a prompt or
                slot that would not resolve — nothing here justifies running
                the same review again, so this stops instead of re-arming the
                pulse. The row stays durable and the next real wake rescans
                it. *)
             (* [evaluator_error_retryable] was the only source for this and
                went with the implicit retry policy it belonged to. The comment
                above already says what is left: without a typed evaluator
                error nothing here justifies running the same review again. *)
             defer
               ~goal_id:work.goal_id
               ~kind:work.kind
               ~retryable:false
               ~reason:detail
           | Some review_verdict ->
             let evidence =
               match review_verdict with
               | Task.Anti_rationalization.Reject reason -> Some reason
               | Task.Anti_rationalization.Approve -> !stated_reason
             in
             (match evidence with
              | Some evidence when String.trim evidence <> "" ->
                let decision =
                  match work.kind, review_verdict with
                  | Completion_proof, Task.Anti_rationalization.Approve ->
                    Workspace_goals.Proof_proven
                  | Completion_proof, Task.Anti_rationalization.Reject reason ->
                    Workspace_goals.Proof_refuted { reason }
                  | Criterion_check, Task.Anti_rationalization.Approve ->
                    Workspace_goals.Criterion_viable
                  | Criterion_check, Task.Anti_rationalization.Reject reason ->
                    Workspace_goals.Criterion_unreachable { reason }
                in
                persist_reviewed ();
                (match
                   commit_gate_verdict
                     config
                     ~goal_id:work.goal_id
                     ~verification_run_id
                     ~decision
                     ~evidence
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

let registry_review_kind = function
  | Criterion_check -> Goal_verification_run_registry.Criterion
  | Completion_proof -> Goal_verification_run_registry.Proof
;;

let process_pending_work ?(sw : Eio.Switch.t option = None) config (work : pending_work)
  : process_outcome
  =
  let registry = Goal_verification_run_registry.global () in
  let run_id = Random_id.uuid_v7 () in
  let started_at = Time_compat.now () in
  let tools = ref [] in
  let evaluator_runtime = ref None in
  Goal_verification_run_registry.register_running
    registry
    ~run_id
    ~goal_id:work.goal_id
    ~review_kind:(registry_review_kind work.kind)
    ~authority_actor:Runtime.verifier_exact_lane_id
    ~started_at;
  let observe_tool ~input result =
    tools :=
      Verification_run_registry.observe_tool_result
        ~input
        ~finished_at:(Time_compat.now ())
        result
      :: !tools
  in
  let observe_evaluator_runtime runtime = evaluator_runtime := Some runtime in
  let persist outcome =
    Goal_verification_run_registry.mark_completed
      registry
      ~run_id
      ~outcome
      ~tools:(List.rev !tools)
      ?evaluator_runtime:!evaluator_runtime
      ~elapsed_s:(max 0.0 (Time_compat.now () -. started_at))
      ()
  in
  let persist_reviewed () = persist Goal_verification_run_registry.Reviewed in
  let complete outcome =
    let registry_outcome =
      match outcome with
      | Committed -> Goal_verification_run_registry.Committed
      | Deferred { retryable; reason } ->
        Goal_verification_run_registry.Deferred { retryable; detail = reason }
    in
    persist registry_outcome
  in
  try
    let outcome =
      process_pending_work_inner
        ~sw
        ~observe_tool
        ~observe_evaluator_runtime
        ~persist_reviewed
        ~verification_run_id:run_id
        config
        work
    in
    complete outcome;
    outcome
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Goal_verification_run_registry.mark_completed
      registry
      ~run_id
      ~outcome:
        (Goal_verification_run_registry.Raised
           { detail = Printexc.to_string exn })
      ~tools:(List.rev !tools)
      ?evaluator_runtime:!evaluator_runtime
      ~elapsed_s:(max 0.0 (Time_compat.now () -. started_at))
      ();
    raise exn
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
  }

let active_runtime : runtime option Atomic.t = Atomic.make None
let max_concurrent_reviews = 4

let claim_review (runtime : runtime) work =
  let rec loop () =
    let current = Atomic.get runtime.in_flight in
    if List.exists (pending_work_same_goal work) current
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
      List.filter (fun candidate -> not (pending_work_same_goal candidate work)) current
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
    Eio.Fiber.fork_daemon ~sw:runtime.sw (fun () ->
      Eio.Time.sleep runtime.clock runtime.retry_interval_sec;
      Atomic.set runtime.retry_scheduled false;
      request_scan runtime;
      `Stop_daemon)
;;

let process_goal_work (runtime : runtime) work =
  match work with
  | [] -> ()
  | representative :: _ ->
    let retryable =
      Eio.Switch.run (fun work_sw ->
        Eio.Switch.on_release work_sw (fun () ->
          release_review runtime representative);
        Cancel_safe.protect
          ~on_exn:(fun exn ->
            Log.Misc.error
              "goal verifier isolated unexpected worker failure goal_id=%s detail=%s"
              representative.goal_id
              (Printexc.to_string exn);
            true)
          (fun () ->
             let rec loop = function
               | [] -> false
               | item :: rest ->
                 (match
                    process_pending_work
                      ~sw:(Some work_sw)
                      runtime.config
                      item
                  with
                  | Committed -> loop rest
                  | Deferred { retryable; reason = _ } -> retryable)
             in
             loop work))
    in
    if retryable then schedule_retry runtime
;;

let take_items limit items =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | item :: rest -> loop (remaining - 1) (item :: acc) rest
  in
  loop limit [] items
;;

let process_pending (runtime : runtime) =
  match collect_pending runtime.config with
  | Error detail ->
    Log.Misc.error
      "goal verifier ledger read failed; pending rows remain undrained: %s"
      detail;
    schedule_retry runtime
  | Ok work ->
    let active = Atomic.get runtime.in_flight in
    let available = max 0 (max_concurrent_reviews - List.length active) in
    let eligible =
      group_pending_by_goal work
      |> List.filter (function
        | [] -> false
        | representative :: _ ->
          not (List.exists (pending_work_same_goal representative) active))
    in
    let selected = take_items available eligible in
    List.iter
      (function
        | [] -> ()
        | representative :: _ as goal_work ->
          if claim_review runtime representative
          then
            Eio.Fiber.fork ~sw:runtime.sw (fun () ->
              process_goal_work runtime goal_work))
      selected;
    if List.length selected < List.length eligible then schedule_retry runtime
;;

let run (runtime : runtime) : [ `Stop_daemon ] =
  Eio.Condition.loop_no_mutex runtime.wake (fun () ->
    if Atomic.exchange runtime.pending false
    then (
      Cancel_safe.observe
        ~on_exn:(fun exn ->
          Log.Misc.error
            "goal verifier isolated unexpected scan failure detail=%s"
            (Printexc.to_string exn);
          schedule_retry runtime)
        (fun () -> process_pending runtime);
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
    | Deferred of
        { retryable : bool
        ; reason : string
        }

  let should_schedule_retry = should_schedule_retry
  let group_pending_by_goal = group_pending_by_goal
end
