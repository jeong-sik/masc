(** Goal_verification_agent — the RFC-0387 stage-2 verifier caller.

    The goal-side analogue of {!Completion_authority_agent}: an
    application-owned LLM agent, not a Keeper, with no Keeper identity, task
    action, or lifecycle. It drains the durable [Proof_pending] rows the gate
    persists BEFORE any model call, written before the phase enters
    [Verifying] (B3), asks one question of each — did the goal's declared
    metric reach its declared target value — through
    {!Goal_verifier_worker.run} (so provider selection is the
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
    config/prompts/goal_verification.md (slot proof) makes it mandatory for both. A
    verdict without a stated reason is not a judgment: nothing is committed and
    the pending row stays durable.

    Failure keeps evidence. Typed transient provider failures retry the same
    request after the earliest candidate rest; permanent or unclassified
    failures wait for an explicit completion request or configuration recovery.
    Every retry restores its linked original and rechecks the request identity. Unknown dispatch never replays. No wall-clock expiry. *)

type pending_work = { goal_id : string }

(* Why a review ended without a verdict. *)
type deferral =
  | Review_not_bound of { detail : string }
  | Proof_lookup_unavailable of { detail : string }
  | Not_reviewed of
      { gate : string
      ; detail : string
      ; evaluator_runtime : string option
      ; retryable_runtimes : string list
      ; model_absent_runtimes : string list
          (** Candidates whose typed refusal was model-absence (a retired or
              unknown model). Permanent for the unchanged request: excluded
              from [retryable_runtimes], so they can arm no retry; named here
              so the deferral records per-candidate outcomes, not only the
              last candidate's error (2026-10-07 audit F-02). *)
      }
  | Verdict_without_reason
  | Commit_refused of { detail : string }

type process_outcome =
  | Committed
  | Superseded
  | Deferred of deferral

(* The Board notice keys its repeat check on [gate], as a Task stall does: a
   review the evaluator declined keeps the evaluator's gate name, every other
   stop is keyed by its constructor. *)
let deferral_gate = function
  | Review_not_bound _ -> "Review_not_bound"
  | Proof_lookup_unavailable _ -> "Proof_lookup_unavailable"
  | Not_reviewed { gate; _ } -> gate
  | Verdict_without_reason -> "Verdict_without_reason"
  | Commit_refused _ -> "Commit_refused"
;;

(* A review that raised is keyed the same way, by its own name, and is the
   gate the Task verifier's notice uses for the same event. *)
let raised_gate = "Raised"

let deferral_detail = function
  | Not_reviewed { detail; model_absent_runtimes; _ } ->
    (* Display-only suffix: names the permanently refused candidates so the
       WARN line and the run-ledger row carry per-candidate outcomes, not only
       the last candidate's error. Never matched. *)
    if model_absent_runtimes = []
    then detail
    else Printf.sprintf "%s | model_absent=%s" detail (String.concat "," model_absent_runtimes)
  | Review_not_bound { detail }
  | Proof_lookup_unavailable { detail }
  | Commit_refused { detail } -> detail
  | Verdict_without_reason ->
    "verdict without a stated reason is not a judgment; the pending row stays \
     durable"
;;

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

   List candidate Goals, then revalidate every transition under the Goal lock
   against the primary ledger. A display recovery snapshot cannot authorize
   review or reconciliation. Recovery re-arms only still-Verifying Goals; an
   ordinary criterion edit must not become an implicit completion request. *)

(* Why a scan produced no work: a store this build cannot read. It is
   recorded as a durable row and one WARN line (RFC-0444 §2.3 row 7). *)
type scan_failure = Scan_skipped of Goal_store.unavailable

let scan_failure_to_string = function
  | Scan_skipped unavailable -> Goal_store.unavailable_to_string unavailable
;;

(* One Verifying goal whose ledger the scan could read but not reconcile or
   re-arm. The scan skips that goal and keeps collecting the others; its
   pending row stays durable, and the Goal rows the operator reads carry the
   failure until a scan no longer finds it. *)
type reconcile_failure =
  { failed_goal_id : string
  ; step : Goal_reconcile_step.t
  ; failure : Goal_store.write_error
  }

type scan =
  { collected : pending_work list
  ; unreconciled : reconcile_failure list
  }

let collect_pending config : (scan, scan_failure) result =
  match Goal_store.list_goals_result config ~phase:Goal_phase.Verifying () with
  | Error unavailable -> Error (Scan_skipped unavailable)
  | Ok goals ->
    let collect_goal (goal : Goal_store.goal) =
      match Workspace_goals.reconcile_committed_proof config ~goal_id:goal.id with
      | Error failure -> Error (Goal_reconcile_step.Reconcile_proof, failure)
      | Ok (Workspace_goals.Reconciled _ | Workspace_goals.Reconciliation_not_needed _) ->
        Ok None
      | Ok Workspace_goals.No_committed_proof ->
        Workspace_goals.recover_current_proof config ~goal_id:goal.id
        |> Result.map (fun rearmed -> if rearmed then Some { goal_id = goal.id } else None)
        |> Result.map_error (fun failure -> Goal_reconcile_step.Rearm_proof, failure)
    in
    let collected, unreconciled =
      List.fold_left
        (fun (collected, unreconciled) (goal : Goal_store.goal) ->
           match collect_goal goal with
           | Ok None -> collected, unreconciled
           | Ok (Some work) -> work :: collected, unreconciled
           | Error (step, failure) ->
             collected, { failed_goal_id = goal.id; step; failure } :: unreconciled)
        ([], [])
        goals
    in
    Ok { collected = List.rev collected; unreconciled = List.rev unreconciled }
;;

(* Derived from the latest completed scan and replaced by the next one; never
   written to a store. A scan the goal store refused leaves it as it was,
   because that scan saw no goal to judge either way. *)
let last_unreconciled : reconcile_failure list Atomic.t = Atomic.make []

let publish_unreconciled failures =
  Atomic.set last_unreconciled failures;
  List.iter
    (fun { failed_goal_id; step; failure } ->
       Log.Misc.error
         "goal verifier ledger %s failed goal_id=%s; its pending row stays undrained: %s"
         (Goal_reconcile_step.to_string step)
         failed_goal_id
         (Goal_store.write_error_to_string failure))
    failures
;;

let unreconciled_to_yojson (goal : Goal_store.goal) =
  match
    List.find_opt
      (fun { failed_goal_id; _ } -> String.equal failed_goal_id goal.id)
      (Atomic.get last_unreconciled)
  with
  | None -> `Null
  (* The operator dropped or reopened it after that scan; the next scan will
     not list it, and until then the old failure is not this goal's state. *)
  | Some _ when goal.phase <> Goal_phase.Verifying -> `Null
  | Some { step; failure; _ } ->
    `Assoc
      [ "step", `String (Goal_reconcile_step.to_string step)
      ; "detail", `String (Goal_store.write_error_to_string failure)
      ]
;;

(* RFC-0444 §2.3 row 7 and criterion 3: one WARN line per skipped scan, and
   one durable row in the verification-runs store carrying the value the scan
   saw. The line is written first because it is the evidence the criterion
   counts; a row append that fails is then reported by the scan's own
   exception path, not by a missing line. *)
let scan_skipped_log_prefix = "goal verifier scan skipped"

let skip_scan (unavailable : Goal_store.unavailable) =
  Log.Misc.warn
    "%s: %s"
    scan_skipped_log_prefix
    (Goal_store.unavailable_to_string unavailable);
  Goal_verification_run_registry.record_scan_skipped
    (Goal_verification_run_registry.global ())
    ~run_id:(Random_id.uuid_v7 ())
    ~started_at:(Time_compat.now ())
    ~unavailable
;;

(* {1 Retained Goal review host}

   The existing Goal lock/proof ledger and registry remain their owners.
   Original selection precedes lookup or prompt construction. *)
module Original = Goal_verifier_original
module Worker = Goal_verifier_worker
module Host = Goal_verifier_host
module Progress = Lane_addon_request_progress
module Registry = Goal_verification_run_registry
let ( let* ) = Result.bind
let owner_store config = Lane_addon_store.create
  ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons")
let worker_detail = function
  | Worker.Store_unavailable detail | Original_invalid detail | Authority_changed detail
  | Execution_pending detail -> detail
let originals_for_goal store ~goal_id = Worker.inventory_for_goal ~store ~goal_id
  ~installation_id:Worker.host_installation_id
  ~package_id:Worker.host_package_id |> Result.map_error worker_detail
let reload_original store retained =
  let original = Worker.original retained in
  let subject = Original.subject original in
  let* current = Worker.load ~store ~installation_id:Worker.host_installation_id ~package_id:Worker.host_package_id
    ~goal_id:subject.goal_id ~request_id:subject.request_id ~attempt:(Original.attempt original)
    |> Result.map_error worker_detail in
  match current with Some value -> Ok value | None -> Error "Goal original disappeared before host observation"

(* {1 Processing} *)

let defer ~goal_id deferral =
  Log.Misc.warn
    "goal verifier deferred goal_id=%s gate=%s reason=%s"
    goal_id
    (deferral_gate deferral)
    (deferral_detail deferral);
  Deferred deferral
;;

(* Report the scheduling owner's actual disposition. The Board neither arms
   retries nor supplies their authority. *)
let announce_stall ~goal_id ~request_id ~disposition ~gate ~detail ~evaluator_runtime =
  match
    Verification_protocol.notify_stalled_verification_with_runtime
      ~authority:Workspace_goals.verifier_authority
      ~subject:(Verification_protocol.Goal_review { goal_id; request_id; disposition })
      ~gate
      ~detail
      ~evaluator_runtime
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Misc.error
      "goal verifier stall notice did not reach the Board; the line above \
       stands goal_id=%s request_id=%s error=%s"
      goal_id
      request_id
      (Printexc.to_string exn)
;;

let announce_deferral ~goal_id ~request_id ~disposition deferral =
  let evaluator_runtime =
    match deferral with
    | Not_reviewed { evaluator_runtime; _ } -> evaluator_runtime
    | Review_not_bound _ | Proof_lookup_unavailable _ | Verdict_without_reason
    | Commit_refused _ -> None
  in
  announce_stall
    ~goal_id
    ~request_id
    ~disposition
    ~gate:(deferral_gate deferral)
    ~detail:(deferral_detail deferral)
    ~evaluator_runtime
;;

(* Capture the Goal and its durable request under the Goal lock. The callback
   performs no writes; the model runs only after this lock is released. *)
let bind_review = Goal_verification.bind_review
;;

(* A review that raised stalls the request the way a deferral does, under the
   gate the Task verifier uses for the same event. Nothing arms a retry: the
   scheduling owner isolates the exception and the Goal waits in Verifying for
   the next request_complete. Only a request that still stands is announced.
   An exception while reading it is logged, not raised over the review's own
   exception; a Goal that has left Verifying, or a read that returns an error,
   posts nothing. *)
let announce_raised ~config ~goal_id ~request_id ~evaluator_runtime ~detail =
  match bind_review config ~goal_id with
  | Ok (_, (current, _, _)) when String.equal current request_id ->
    announce_stall
      ~goal_id
      ~request_id
      ~disposition:Verification_protocol.No_retry_armed
      ~gate:raised_gate
      ~detail
      ~evaluator_runtime
  | Ok _ | Error _ -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Misc.error
      "goal verifier could not read the request to announce a raised review \
       goal_id=%s request_id=%s error=%s"
      goal_id
      request_id
      (Printexc.to_string exn)
;;

let new_run () : Worker.run_identity =
  {run_id=Random_id.uuid_v7 (); started_at=Time_compat.now ()}

let retained_recovery_work config work =
  let store = owner_store config in
  match Worker.inventory_by_goal ~store ~installation_id:Worker.host_installation_id
    ~package_id:Worker.host_package_id with
  | Error error ->
    (* Unknown metadata cannot be attributed to an independent Goal. Pending
       processing repeats the same strict discovery before any dispatch. *)
    Log.Misc.error "goal verifier original metadata unavailable: %s" (worker_detail error);
    work
  | Ok goals ->
    List.fold_left (fun work (goal_id,originals) ->
      match originals with
      | Error error ->
        Log.Misc.error "goal verifier original unavailable goal_id=%s: %s"
          goal_id (worker_detail error);
        work
      | Ok rows ->
        List.fold_left (fun work retained ->
          let needed = match Host.needs_recovery ~registry:(Registry.global ()) retained with
            | Ok needed -> needed
            | Error error ->
              Log.Misc.error "goal verifier retained observation unavailable goal_id=%s: %s"
                goal_id (Host.error_to_string error);
              true in
          if needed && not (List.exists (fun item -> item.goal_id=goal_id) work)
          then work @ [{goal_id}] else work) work rows) work goals
;;

let process_pending_work ?(sw : Eio.Switch.t option = None)
    ?(schedule_retry = fun ~goal_id:_ ~request_id:_ _ -> Verification_protocol.No_retry_armed)
    config (work : pending_work) : process_outcome =
  let store = owner_store config in
  let registry = Registry.global () in
  let active = ref None in
  let publish retained outcome = Host.publish ~store ~registry retained ~outcome
    |> Result.map_error Host.error_to_string in
  let fail_original detail = defer ~goal_id:work.goal_id (Proof_lookup_unavailable {detail}) in
  let conflict_outcome retained detail =
    let subject = Original.subject (Worker.original retained) in
    match Goal_verification.get_record_authoritative config ~goal_id:subject.goal_id with
    | Error observation -> defer ~goal_id:work.goal_id (Commit_refused {detail=observation})
    | Ok record ->
      let replacement = match record with
        | Some {Goal_verification.completion=Proof_pending pending; _} -> pending.request_id <> subject.request_id
        | Some {completion=(Proof_proven verdict | Proof_refuted verdict | Human_confirmed (verdict,_)); _} ->
          verdict.request_id <> subject.request_id
        | None | Some {completion=Completion_idle; _} -> false in
      let observation = if replacement then Registry.Superseded {detail} else Registry.Deferred {detail} in
      (match publish retained observation with
       | Error detail -> defer ~goal_id:work.goal_id (Commit_refused {detail})
       | Ok () -> if replacement then Superseded else defer ~goal_id:work.goal_id (Commit_refused {detail})) in
  let commit retained =
    let subject = Original.subject (Worker.original retained) in
    match Host.commit_proof ~config ~store ~registry retained with
    | Ok () ->
      Log.Misc.info "goal verifier committed retained goal_id=%s run_id=%s"
        subject.goal_id (Worker.run_identity retained).run_id;
      Committed
    | Error (Host.Conflict detail) ->
      conflict_outcome retained detail
    | Error (Host.Unavailable detail | Invalid_original detail) ->
      let detail = match publish retained (Registry.Deferred {detail}) with
        | Ok () -> detail | Error observation -> detail ^ " | observation: " ^ observation in
      defer ~goal_id:work.goal_id (Commit_refused {detail}) in
  let recover rows =
    List.fold_left (fun (committed, failed) retained ->
      let subject = Original.subject (Worker.original retained) in
      if subject.goal_id <> work.goal_id then committed, failed
      else match Host.needs_recovery ~registry retained with
      | Error error -> committed, Some (Host.error_to_string error)
      | Ok false -> committed, failed
      | Ok true ->
        active := Some retained;
        (match Progress.phase (Worker.progress retained) with
         | Judged _ | Committing _ | Commit_unknown _ | Finished _ ->
           (match commit retained with
            | Committed -> true, failed
            | Superseded -> committed, failed
            | Deferred deferral -> committed, Some (deferral_detail deferral))
         | Conflicted _ ->
           (match conflict_outcome retained "original proof conflicted with a later Goal state" with
            | Committed | Superseded -> committed, failed
            | Deferred deferral -> committed, Some (deferral_detail deferral))
         | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
           (match publish retained (Registry.Deferred {detail="retained original review has no settled Goal proof"}) with
            | Ok () -> committed, failed | Error detail -> committed, Some detail)))
      (false,None) rows in
  let process_current ~recovered =
    match bind_review config ~goal_id:work.goal_id with
    | Error _ when recovered -> Committed
    | Error detail -> defer ~goal_id:work.goal_id (Review_not_bound {detail})
    | Ok (_, (request_id, criterion, _)) ->
      let operation () =
        let* selected = Worker.frontier ~store ~installation_id:Worker.host_installation_id
          ~package_id:Worker.host_package_id ~goal_id:work.goal_id ~request_id ~new_run
          |> Result.map_error worker_detail in
        let* retained, prepared_authority = match selected with
          | Some retained -> Ok (retained, None)
          | None ->
            let* authority = Verification_authority_tools.create_goal_review ~config ~goal_id:work.goal_id in
            let subject = Verification_authority_tools.goal_review_subject authority in
            let* () = if subject.request_id=request_id && Goal_store.criterion_equal subject.criterion criterion
              then Ok () else Error "Goal proof changed during original preparation" in
            let* original = Original.prepare ~attempt:0 ~authority in
            let* retained = Worker.retain ~store ~installation_id:Worker.host_installation_id ~package_id:Worker.host_package_id
              ~run:(new_run ()) original |> Result.map_error worker_detail in
            Ok (retained, Some authority) in
        active := Some retained;
        let* () = Host.ensure_registered ~registry retained |> Result.map_error Host.error_to_string in
        let* restored = Worker.restored_receipt retained |> Result.map_error worker_detail in
        let execution = match restored with
          | Some receipt -> Ok receipt
          | None ->
            let authority = match prepared_authority with
              | Some authority -> Ok authority
              | None -> Verification_authority_tools.create_goal_review ~config ~goal_id:work.goal_id in
            (match authority with
             | Error detail -> Error (Worker.Authority_changed detail)
             | Ok authority -> Worker.run ~store ~retained ~authority ~sw
                 ~provider_rest:Verification_retry.provider_rest ()) in
        let* saved = reload_original store retained in
        active := Some saved;
        let result = match execution with
          | Error error ->
            let detail = worker_detail error in
            let* () = publish saved (Registry.Deferred {detail}) in
            let deferral = match error with
              | Worker.Execution_pending _ ->
                let* receipt = Worker.observed_receipt saved |> Result.map_error worker_detail in
                Ok (Not_reviewed {gate="Original_pending"; detail;
                  evaluator_runtime=Option.map (fun receipt -> receipt.Worker.result.evaluator_runtime) receipt;
                  retryable_runtimes=[]; model_absent_runtimes=[]})
              | Store_unavailable _ | Original_invalid _ | Authority_changed _ ->
                Ok (Proof_lookup_unavailable {detail}) in
            let* deferral = deferral in
            Ok (defer ~goal_id:work.goal_id deferral)
          | Ok receipt ->
            let result = receipt.Worker.result in
            (match result.verdict with
             | None ->
               let detail = match result.fallback_reason with Some reason -> reason
                 | None -> Task.Anti_rationalization.gate_to_string result.gate in
               let deferral = Not_reviewed {
                 gate=Task.Anti_rationalization.gate_to_string result.gate; detail;
                 evaluator_runtime=Some result.evaluator_runtime; retryable_runtimes=result.retryable_runtimes;
                 model_absent_runtimes=result.model_absent_runtimes} in
               let* () = publish saved (Registry.Deferred {detail=deferral_detail deferral}) in
               Ok (defer ~goal_id:work.goal_id deferral)
             | Some (Task.Anti_rationalization.Approve reason | Reject reason) when String.trim reason = "" ->
               let* () = publish saved (Registry.Deferred {detail=deferral_detail Verdict_without_reason}) in
               Ok (defer ~goal_id:work.goal_id Verdict_without_reason)
             | Some (Approve _ | Reject _) -> Ok (commit saved)) in
        let* outcome = result in
        let outcome = match outcome with
          | Committed | Superseded -> outcome
          | Deferred _ ->
            (match bind_review config ~goal_id:work.goal_id with
             | Ok (_, (current,_,_)) when current <> request_id -> Superseded
             | Ok _ | Error _ -> outcome) in
        (match outcome with
         | Deferred deferral ->
           (match bind_review config ~goal_id:work.goal_id with
            | Ok (_, (current,_,_)) when current=request_id ->
              let disposition = schedule_retry ~goal_id:work.goal_id ~request_id deferral in
              announce_deferral ~goal_id:work.goal_id ~request_id ~disposition deferral
            | Ok _ | Error _ -> ())
         | Committed | Superseded -> ());
        Ok outcome in
      (match operation () with Ok outcome -> outcome | Error detail -> fail_original detail) in
  try
    match originals_for_goal store ~goal_id:work.goal_id with
    | Error detail -> fail_original detail
    | Ok rows ->
      let recovered, failure = recover rows in
      (match failure with
       | Some detail -> defer ~goal_id:work.goal_id (Commit_refused {detail})
       | None -> process_current ~recovered)
  with
  | Eio.Cancel.Cancelled _ as exn ->
    Eio.Cancel.protect (fun () ->
      match !active with
      | None -> ()
      | Some retained ->
        (match reload_original store retained with
         | Error detail -> Log.Misc.error "goal cancellation original read failed: %s" detail
         | Ok saved ->
           match publish saved (Registry.Review_cancelled {detail="review fiber cancelled: " ^ Printexc.to_string exn}) with
           | Ok () -> () | Error detail -> Log.Misc.error "goal cancellation observation failed: %s" detail));
    raise exn
  | exn ->
    (match !active with
     | None -> ()
     | Some retained ->
       let subject = Original.subject (Worker.original retained) in
       announce_raised ~config ~goal_id:work.goal_id ~request_id:subject.request_id
         ~evaluator_runtime:None ~detail:(Printexc.to_string exn);
       match reload_original store retained with
       | Error detail -> Log.Misc.error "raised Goal original read failed: %s" detail
       | Ok saved ->
         match publish saved (Registry.Raised {detail=Printexc.to_string exn}) with
         | Ok () -> () | Error detail -> Log.Misc.error "raised Goal observation failed: %s" detail);
    raise exn
;;

let drain_once ?(sw : Eio.Switch.t option = None) config : (unit, scan_failure) result =
  match collect_pending config with
  | Error (Scan_skipped unavailable) as error ->
    skip_scan unavailable;
    error
  | Ok { collected; unreconciled } ->
    publish_unreconciled unreconciled;
    List.iter
      (fun item ->
         (* RFC-0387: per-row outcomes are logged at the point of decision
            (commit/defer); the synchronous drain discards them. *)
         (* fire-and-forget: per-row results are durable in the ledger. *)
         ignore (process_pending_work ~sw config item))
      (retained_recovery_work config collected);
    Ok ()
;;

(* {1 Daemon}

   Mirrors {!Completion_authority_agent}: a condition-variable wake installed
   as {!Workspace_hooks.goal_verification_pending_fn} and bounded concurrency
   via a semaphore. A committed verdict requests another scan; a deferral
   stays durable. Transient evaluator failures arm a request-scoped retry.
   Other deferrals wait for an explicit wake. No wall-clock expiry. *)

(* One claimed review. [requested] retains a wake that arrived while the
   review ran. [abandon] is resolved when the Goal leaves [Verifying] through
   an operator Drop or Reopen: the review is cancelled and its claim released,
   so a verifier lane that never answers does not keep a slot or block the
   Goal's next request. A Promise is used because the operator's transition
   can run on another domain; resolving one is domain-safe. *)
type claim =
  { work : pending_work
  ; requested : bool
  ; abandoned : unit Eio.Promise.t
  ; abandon : unit Eio.Promise.u
  }

type runtime =
  { config : Workspace_utils_backend_setup.config
  ; sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; retries : (string * string * string) list Atomic.t
  ; wake : Eio.Condition.t
  ; pending : bool Atomic.t
  ; in_flight : claim list Atomic.t
  }

let active_runtime : runtime option Atomic.t = Atomic.make None
let max_concurrent_reviews = 4

let claim_review (runtime : runtime) work =
  let abandoned, abandon = Eio.Promise.create () in
  let claim = { work; requested = false; abandoned; abandon } in
  let rec loop () =
    let current = Atomic.get runtime.in_flight in
    if List.exists (fun candidate -> pending_work_same_goal work candidate.work) current
    then None
    else if Atomic.compare_and_set runtime.in_flight current (claim :: current)
    then Some claim
    else loop ()
  in
  loop ()
;;

(* Mark an active claim in the same atomic state that releases it. A wake
   racing with release is either retained here or sees an already free Goal
   and is handled by the ordinary scan. No interval exists where both miss it. *)
let retain_active_wake (runtime : runtime) ~goal_id =
  let rec loop () =
    let current = Atomic.get runtime.in_flight in
    let next = List.map (fun claim ->
      { claim with requested = claim.requested || String.equal claim.work.goal_id goal_id })
      current in
    if Atomic.compare_and_set runtime.in_flight current next then () else loop ()
  in loop ()
;;

let release_review (runtime : runtime) work =
  let rec loop () =
    let current = Atomic.get runtime.in_flight in
    let retained = List.exists (fun candidate ->
      pending_work_same_goal candidate.work work && candidate.requested) current in
    let next = List.filter (fun candidate ->
      not (pending_work_same_goal candidate.work work)) current in
    if Atomic.compare_and_set runtime.in_flight current next then retained else loop ()
  in loop ()
;;

let request_scan (runtime : runtime) =
  Atomic.set runtime.pending true;
  Eio.Condition.broadcast runtime.wake
;;

let remove_retry (runtime : runtime) key =
  let rec loop () =
    let current = Atomic.get runtime.retries in
    if not (List.mem key current) then false
    else if Atomic.compare_and_set runtime.retries current (List.filter ((<>) key) current)
    then true else loop ()
  in loop ()
;;

let clear_retries (runtime : runtime) ~goal_id =
  Atomic.get runtime.retries |> List.iter (fun ((id, _, _) as key) ->
    if String.equal id goal_id then ignore (remove_retry runtime key))
;;

let schedule_retry (runtime : runtime) ~goal_id ~request_id deferral =
  if List.exists (fun claim -> String.equal claim.work.goal_id goal_id && claim.requested)
       (Atomic.get runtime.in_flight)
  then Verification_protocol.No_retry_armed
  else match deferral with
  | Not_reviewed {retryable_runtimes = _ :: _ as runtimes; _} ->
    (* [runtimes] is built at the walk: model-absence refusals (retired or
       unknown models) are classified permanent there and can never appear in
       it, so this arms only while a candidate that reported a typed transient
       failure could serve again. *)
    let key = goal_id, request_id, Random_id.uuid_v7 () in
    let rec admit () =
      let current = Atomic.get runtime.retries in
      if List.exists (fun (id, request, _) -> String.equal id goal_id && String.equal request request_id) current then false
      else if Atomic.compare_and_set runtime.retries current (key :: current) then true
      else admit ()
    in
    if not (admit ()) then Verification_protocol.Retry_scheduled {delay=Shared_timer}
    else (
      let seconds = Verification_retry.delay
          ~retry_interval_sec:Env_config.Timeouts.maintenance_pulse_interval_sec
          ~now:(Eio.Time.now runtime.clock) runtimes in
      Eio.Fiber.fork_daemon ~sw:runtime.sw (fun () ->
        Eio.Time.sleep runtime.clock seconds;
        if remove_retry runtime key then (
          match bind_review runtime.config ~goal_id with
          | Ok (_, (current, _, _)) when String.equal current request_id ->
            retain_active_wake runtime ~goal_id;
            request_scan runtime
          | Ok _ | Error _ -> ());
        `Stop_daemon);
      Verification_protocol.Retry_scheduled {delay=Full_interval {seconds}})
  | Not_reviewed _ | Review_not_bound _ | Proof_lookup_unavailable _
  | Verdict_without_reason | Commit_refused _ -> Verification_protocol.No_retry_armed
;;

(* Resolve the abandon promise of the Goal's claimed review, if one runs.
   A Goal with no claimed review has nothing to cancel. *)
let abandon_review (runtime : runtime) ~goal_id =
  clear_retries runtime ~goal_id;
  Atomic.get runtime.in_flight
  |> List.iter (fun claim ->
    if String.equal claim.work.goal_id goal_id
    then (
      if Eio.Promise.try_resolve claim.abandon ()
      then
        Log.Misc.info
          "goal verifier abandoning in-flight review goal_id=%s: the Goal left verifying"
          goal_id))
;;

(* A completed review or an armed retry frees capacity for other Goals.
   Waiting retries are excluded from scans until their own timer or an explicit
   request wakes them. Permanent deferrals do not request another scan. *)
let process_goal_work (runtime : runtime) (claim : claim) work =
  match work with
  | [] -> ()
  | representative :: _ ->
    let committed_any =
      Eio.Switch.run (fun release_sw ->
        Eio.Switch.on_release release_sw (fun () ->
          if release_review runtime representative then request_scan runtime);
        (* The review runs in its own switch inside the first branch, so an
           abandon cancels the review and every fiber it forked before the
           claim is released. The cancelled review records Review_cancelled
           on the run registry; any verdict it would have delivered is
           refused by the commit, since the Goal is no longer verifying. *)
        Eio.Fiber.first
          (fun () ->
             Eio.Switch.run (fun work_sw ->
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
                             ~schedule_retry:(schedule_retry runtime)
                             runtime.config
                             item
                         with
                         | Committed | Superseded -> loop true rest
                         | Deferred (Not_reviewed {retryable_runtimes = _ :: _; _}) -> true
                         | Deferred (Review_not_bound _) | Deferred (Proof_lookup_unavailable _)
                         | Deferred (Not_reviewed _) | Deferred (Verdict_without_reason)
                         | Deferred (Commit_refused _) -> committed)
                    in
                    loop false work)))
          (fun () ->
             Eio.Promise.await claim.abandoned;
             false))
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
  | Error (Scan_skipped unavailable) -> skip_scan unavailable
  | Ok { collected = work; unreconciled } ->
    publish_unreconciled unreconciled;
    let work = retained_recovery_work runtime.config work in
    let active = Atomic.get runtime.in_flight in
    let available = max 0 (max_concurrent_reviews - List.length active) in
    let eligible =
      group_pending_by_goal work
      |> List.filter (function
        | [] -> false
        | representative :: _ ->
          not (List.exists (fun candidate -> pending_work_same_goal representative candidate.work) active)
          && not (List.exists (fun (id, _, _) -> String.equal id representative.goal_id)
                    (Atomic.get runtime.retries)))
    in
    let selected = take_items available eligible in
    List.iter
      (function
        | [] -> ()
        | representative :: _ as goal_work ->
          match claim_review runtime representative with
          | Some claim ->
            Eio.Fiber.fork ~sw:runtime.sw (fun () ->
              process_goal_work runtime claim goal_work)
          | None -> ())
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
         clear_retries runtime ~goal_id;
         retain_active_wake runtime ~goal_id;
         request_scan runtime;
         Log.Misc.info "goal verifier scheduled goal_id=%s" goal_id));
  Atomic.set Workspace_hooks.goal_verification_abandoned_fn
    (fun config ~goal_id ->
       if String.equal config.base_path runtime.config.base_path
       then abandon_review runtime ~goal_id
       else
         Log.Misc.error
           "goal verifier rejected an abandon from another base path goal_id=%s"
           goal_id)
;;

let start ~sw ~clock ~(config : Workspace_utils_backend_setup.config) =
  Eio.Switch.check sw;
  let runtime =
    { config
    ; sw
    ; clock
    ; retries = Atomic.make []
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
    let previous_abandoned_hook =
      Atomic.get Workspace_hooks.goal_verification_abandoned_fn
    in
    install_callback runtime;
    Eio.Switch.on_release sw (fun () ->
      if Atomic.compare_and_set active_runtime owner None
      then (
        (* No scan runs after this, so its last list would read as current. *)
        Atomic.set last_unreconciled [];
        Atomic.set
          Workspace_hooks.goal_verification_pending_fn
          previous_pending_hook;
        Atomic.set
          Workspace_hooks.goal_verification_abandoned_fn
          previous_abandoned_hook));
    Eio.Fiber.fork_daemon ~sw (fun () -> run runtime)
;;

module For_testing = struct
  let retry_pending ~goal_id =
    match Atomic.get active_runtime with
    | None -> false
    | Some runtime -> List.exists (fun (id, _, _) -> String.equal id goal_id) (Atomic.get runtime.retries)

  let scan_active_once () =
    match Atomic.get active_runtime with
    | None -> false
    | Some runtime ->
      Atomic.set runtime.pending false;
      process_pending runtime;
      true

  let collect_pending = collect_pending
  let process_pending_work ?(sw = None) config work = process_pending_work ~sw config work
  let drain_once = drain_once

  type nonrec pending_work = pending_work = { goal_id : string }

  type nonrec deferral = deferral =
    | Review_not_bound of { detail : string }
    | Proof_lookup_unavailable of { detail : string }
    | Not_reviewed of
      { gate : string
      ; detail : string
      ; evaluator_runtime : string option
      ; retryable_runtimes : string list
      ; model_absent_runtimes : string list
          (** Candidates whose typed refusal was model-absence (a retired or
              unknown model). Permanent for the unchanged request: excluded
              from [retryable_runtimes], so they can arm no retry; named here
              so the deferral records per-candidate outcomes, not only the
              last candidate's error (2026-10-07 audit F-02). *)
      }
    | Verdict_without_reason
    | Commit_refused of { detail : string }

  type nonrec process_outcome = process_outcome =
    | Committed
    | Superseded
    | Deferred of deferral

  let deferral_gate = deferral_gate
  let deferral_detail = deferral_detail

  type nonrec scan_failure = scan_failure = Scan_skipped of Goal_store.unavailable

  type nonrec reconcile_failure = reconcile_failure =
    { failed_goal_id : string
    ; step : Goal_reconcile_step.t
    ; failure : Goal_store.write_error
    }

  type nonrec scan = scan =
    { collected : pending_work list
    ; unreconciled : reconcile_failure list
    }

  let scan_failure_to_string = scan_failure_to_string
end
