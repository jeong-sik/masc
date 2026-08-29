(** Goal_verification_agent — the RFC-0387 stage-2 verifier caller.

    The goal-side analogue of {!Completion_authority_agent}: an
    application-owned LLM agent, not a Keeper, with no Keeper identity, task
    action, or lifecycle. It drains the durable [Proof_pending] rows the gate
    persists BEFORE any model call, written before the phase enters
    [Verifying] (B3), asks one question of each — did the goal's declared
    metric reach its declared target value — through
    {!Task.Anti_rationalization.run} (so provider selection is the
    [verifier_exact] exact-output lane with frozen-order failover), and
    commits the verdict through the typed internal boundary
    {!Workspace_goals.commit_verifier_decision}, so the FSM decides, the
    ledger records, the phase writes, and the event emits — none of that
    logic is duplicated here and no public MCP action can name a verdict.

    Authority is the fixed identity
    [System_llm_agent { agent_run_id = "verifier_exact" }] (RFC-0361 D7(b)):
    the handler binds [ctx.agent_name] into the verdict, and this lane's
    context names the lane. Evidence is the model's stated reason, which the
    verdict itself now carries on either outcome, and
    config/prompts/goal_verification.proof.md makes it mandatory for both. A
    verdict without a stated reason is not a judgment: nothing is committed and
    the pending row stays durable.

    Failure keeps evidence: an unavailable evaluator, a malformed reply after
    all slots failed, or a refused commit leaves the pending row durable and
    stops. Nothing re-runs the same review on a clock — the next scan comes
    from a Keeper requesting completion or from another review committing a
    verdict. No wall-clock expiry and no retry timer anywhere. *)

type pending_work = { goal_id : string }

type process_outcome =
  | Committed
  | Deferred of string

let pending_work_same_goal left right = String.equal left.goal_id right.goal_id

(* Preserve first-goal order for deterministic worker admission. *)
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
  List.rev_map (fun goal_id -> Hashtbl.find groups goal_id) !goal_order
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
           match record.completion with
           | Goal_verification.Proof_pending _ ->
             [ { goal_id = record.goal_id } ]
           | Goal_verification.Completion_idle
           | Goal_verification.Proof_proven _
           | Goal_verification.Proof_refuted _ -> [])
        records
    in
    let rec reconcile_verifying acc = function
      | [] -> Ok (List.rev acc)
      | (goal : Goal_store.goal) :: rest ->
        if
          List.exists
            (fun work -> String.equal work.goal_id goal.id)
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
                 ({ goal_id = goal.id } :: acc)
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

(* {1 Proof prompt}

   A Goal declares a metric and a target value when it is created. The proof
   review asks one question: did that metric reach that target. The prompt is
   config/prompts/goal_verification.proof.md and its variables are the goal's
   own — nothing about Tasks reaches the judge, because a Task proves its own
   contract and says nothing about a Goal's metric. *)

(* The judge is told what it holds. A surface it is never described cannot be
   used: an evaluator that held read tools and was told nothing about them
   spent the whole review guessing paths (masc#29250). *)
let render_lookup_section (lookup : Task.Anti_rationalization.lookup_surface) =
  match lookup with
  | Task.Anti_rationalization.No_lookup_surface ->
    Ok
      "You hold no tool that opens anything. Nothing here can measure the \
       declared metric, so the only verdict this review can reach honestly is \
       a refusal that says so."
  | Task.Anti_rationalization.Lookup_tools { schemas; dispatch = _; root_layout } ->
    let tool_names =
      schemas
      |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
      |> String.concat ", "
    in
    let root_layout_lines =
      match root_layout with
      | [] -> "  (this root is empty)"
      | entries ->
        entries |> List.map (fun entry -> "  " ^ entry) |> String.concat "\n"
    in
    Prompt_registry.render_prompt_template
      Prompt_names.goal_verification_lookup
      [ "lookup_tools", tool_names; "lookup_root_layout", root_layout_lines ]
;;

let render_proof_prompt ~lookup (goal : Goal_store.goal) =
  let open Result.Syntax in
  let declared = function
    | Some value when String.trim value <> "" -> value
    | Some _ | None -> "(not declared)"
  in
  let* lookup_section = render_lookup_section lookup in
  Prompt_registry.render_prompt_template
    Prompt_names.goal_verification_proof
    [ "goal_title", goal.Goal_store.title
    ; "metric", declared goal.Goal_store.metric
    ; "target_value", declared goal.Goal_store.target_value
    ; "lookup_section", lookup_section
    ]
;;

(* The Goal proof read surface. It is built here rather than derived from
   anything the Goal links to: the root is the shared playground, one fixed
   workspace location, and every producer's tree sits under it. An unreadable
   root is not turned into "the tree is empty" — the review defers with the
   reason and the pending row stays durable. *)
let goal_proof_lookup config =
  let open Result.Syntax in
  let* tools = Verification_authority_tools.create_goal_proof ~config in
  let* root_layout = Verification_authority_tools.goal_proof_root_layout tools in
  Ok
    (Task.Anti_rationalization.Lookup_tools
       { schemas = Verification_authority_tools.schemas tools
       ; dispatch = Verification_authority_tools.dispatch tools
       ; root_layout
       })
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

let defer ~goal_id ~reason =
  Log.Misc.warn "goal verifier deferred goal_id=%s reason=%s" goal_id reason;
  Deferred reason
;;

(* Nothing stands between a pending proof request and the review. Whether the
   goal reached its target is the verdict's answer to give; a branch here that
   declined to run the review would be making that call without recording a
   reason. A goal that declared no metric is not refused here either — it is
   shown to the judge as undeclared and refused in a verdict that says so. *)

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
  match Goal_store.get_goal config ~goal_id:work.goal_id with
  | None ->
    (* The row stays durable — failure keeps evidence — but retrying cannot
       conjure the goal back; the next wake rescan reports the same. *)
    defer
      ~goal_id:work.goal_id
      ~reason:"pending verification row names a goal that does not exist"
  | Some goal ->
    (match goal.Goal_store.phase with
     | Goal_phase.Verifying ->
       (match goal_proof_lookup config with
        | Error detail ->
          defer
            ~goal_id:work.goal_id
            ~reason:("goal proof lookup surface unavailable: " ^ detail)
        | Ok lookup ->
       let on_tool_result ~input result = observe_tool ~input result in
       let result =
         Task.Anti_rationalization.run
           ~base_path:config.base_path
           ~sw
           ~log_info:(fun message ->
             Log.Misc.info
               "[goal-proof-review] goal_id=%s %s"
               work.goal_id
               message)
           ~log_warn:(fun message ->
             Log.Misc.warn
               "[goal-proof-review] goal_id=%s %s"
               work.goal_id
               message)
           ~render_prompt:(fun () -> render_proof_prompt ~lookup goal)
           ~lookup
           ~on_tool_result
           ()
       in
       observe_evaluator_runtime result.evaluator_runtime;
          (match result.verdict with
           | None ->
             let detail =
               match result.fallback_reason with
               | Some reason -> reason
               | None -> Task.Anti_rationalization.gate_to_string result.gate
             in
             (* No verdict was committed. The row stays durable and the next
                real wake rescans it — a Keeper re-requesting completion, or a
                worker slot coming free with work still queued. *)
             defer
               ~goal_id:work.goal_id
               ~reason:detail
           | Some review_verdict ->
             let evidence =
               match review_verdict with
               | Task.Anti_rationalization.Reject reason
               | Task.Anti_rationalization.Approve reason -> reason
             in
             if String.equal (String.trim evidence) ""
             then
               defer
                 ~goal_id:work.goal_id
                 ~reason:
                   "verdict without a stated reason is not a judgment; the \
                    pending row stays durable"
             else (
               let decision =
                 match review_verdict with
                 | Task.Anti_rationalization.Approve _ -> Workspace_goals.Proof_proven
                 | Task.Anti_rationalization.Reject reason ->
                   Workspace_goals.Proof_refuted { reason }
               in
               persist_reviewed ();
               match
                 commit_gate_verdict
                   config
                   ~goal_id:work.goal_id
                   ~verification_run_id
                   ~decision
                   ~evidence
               with
               | Ok () ->
                 Log.Misc.info
                   "goal verifier committed goal_id=%s verdict=%s"
                   work.goal_id
                   (Task.Anti_rationalization.verdict_constructor_name review_verdict);
                 Committed
               | Error detail ->
                 (* A refused commit (stale verifier answer, a phase that moved
                    under the review) consumes nothing: the pending row stays
                    durable and the next pulse re-reads it. *)
                 defer ~goal_id:work.goal_id ~reason:detail)))
     | Goal_phase.Executing ->
       (* The crash window of persist-before-model-call: the durable request
          exists but the phase write never landed. Reviewing now would produce
          a verdict the FSM must refuse ([Executing, Record_proof_*] is
          invalid), so the lane waits — the keeper's repeated
          [request_complete] re-converges the phase onto the pending row. *)
       defer
         ~goal_id:work.goal_id
         ~reason:
           "proof request is pending but the phase never entered verifying; \
            waiting for the gate to re-converge"
     | Goal_phase.Completed | Goal_phase.Dropped ->
       defer
         ~goal_id:work.goal_id
         ~reason:"proof request pending on a terminal goal; left durable")
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
    ~review_kind:Goal_verification_run_registry.Proof
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
      | Deferred reason -> Goal_verification_run_registry.Deferred { detail = reason }
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
  | Eio.Cancel.Cancelled _ as exn ->
    (* Same discipline as the task verifier: the cancelled review completes
       its observation row before the cancellation continues (W6). *)
    Eio.Cancel.protect (fun () ->
      persist
        (Goal_verification_run_registry.Review_cancelled
           { detail = "review fiber cancelled: " ^ Printexc.to_string exn }));
    raise exn
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
            (commit/defer); the synchronous drain discards them. *)
         (* fire-and-forget: per-row results are durable in the ledger. *)
         ignore (process_pending_work ~sw config item))
      work;
    Ok ()
;;

(* {1 Daemon}

   Mirrors {!Completion_authority_agent}: a condition-variable wake installed
   as {!Workspace_hooks.goal_verification_pending_fn} and bounded concurrency
   via a semaphore. A committed verdict requests another scan; a deferral
   stays durable and waits for an explicit completion request or another
   committed review. No wall-clock expiry or retry timer. *)

type runtime =
  { config : Workspace_utils_backend_setup.config
  ; sw : Eio.Switch.t
  ; wake : Eio.Condition.t
  ; pending : bool Atomic.t
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

(* Rescanning is driven by what happened, not by a clock. A committed verdict
   changes the ledger, so whatever else was queued deserves another look, and
   the worker slot this fiber held has just come free. A run that committed
   nothing changes nothing: scanning again would read the same rows and defer
   them again, so it stops and waits for a real wake — a Keeper requesting
   completion, or another worker committing. *)
let process_goal_work (runtime : runtime) work =
  match work with
  | [] -> ()
  | representative :: _ ->
    let committed_any =
      Eio.Switch.run (fun work_sw ->
        Eio.Switch.on_release work_sw (fun () ->
          release_review runtime representative);
        Cancel_safe.protect
          ~on_exn:(fun exn ->
            Log.Misc.error
              "goal verifier isolated unexpected worker failure goal_id=%s detail=%s"
              representative.goal_id
              (Printexc.to_string exn);
            false)
          (fun () ->
             let rec loop committed = function
               | [] -> committed
               | item :: rest ->
                 (match
                    process_pending_work
                      ~sw:(Some work_sw)
                      runtime.config
                      item
                  with
                  | Committed -> loop true rest
                  | Deferred _ -> committed)
             in
             loop false work))
    in
    if committed_any then request_scan runtime
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
      detail
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
      selected
;;

let run (runtime : runtime) : [ `Stop_daemon ] =
  Eio.Condition.loop_no_mutex runtime.wake (fun () ->
    if Atomic.exchange runtime.pending false
    then (
      Cancel_safe.observe
        ~on_exn:(fun exn ->
          Log.Misc.error
            "goal verifier isolated unexpected scan failure detail=%s"
            (Printexc.to_string exn))
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

let start ~sw ~(config : Workspace_utils_backend_setup.config) =
  Eio.Switch.check sw;
  let runtime =
    { config
    ; sw
    ; wake = Eio.Condition.create ()
    ; pending = Atomic.make true
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

  type nonrec pending_work = pending_work = { goal_id : string }

  type nonrec process_outcome = process_outcome =
    | Committed
    | Deferred of string

  let group_pending_by_goal = group_pending_by_goal
end
