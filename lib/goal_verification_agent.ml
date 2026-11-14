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

(* A review the evaluator declined keeps the evaluator's gate name; every
   other stop is named by its constructor. *)
let deferral_gate = function
  | Review_not_bound _ -> "Review_not_bound"
  | Proof_lookup_unavailable _ -> "Proof_lookup_unavailable"
  | Not_reviewed { gate; _ } -> gate
  | Verdict_without_reason -> "Verdict_without_reason"
  | Commit_refused _ -> "Commit_refused"
;;

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

(* {1 Scan}

   List candidate Goals, then revalidate every transition under the Goal lock
   against the primary ledger. A display recovery snapshot cannot authorize
   review or reconciliation. Recovery retains only a matching pending request;
   a missing or inconsistent record does not authorize a new request. *)

(* Why a scan produced no work: a store this build cannot read. It is
   recorded as a durable row and one WARN line (RFC-0444 §2.3 row 7). *)
type scan_failure = Scan_skipped of Goal_store.unavailable

let scan_failure_to_string = function
  | Scan_skipped unavailable -> Goal_store.unavailable_to_string unavailable
;;

(* One Verifying goal whose ledger the scan could not reconcile or bind to a
   current request. The scan skips it and keeps collecting the others; Goal
   rows carry the failure until a scan no longer finds it. *)
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
        |> Result.map (fun pending -> if pending then Some { goal_id = goal.id } else None)
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
open Result.Syntax
let owner_store config = Lane_addon_store.of_config config
let worker_detail = Worker.error_to_string

type original_read_binding = {
  root : string;
  goal_id : string;
  request_id : string;
  criterion : Goal_store.criterion;
}

(* A read owns this exact immutable observation object. A newer read replaces
   it, so a late result cannot clear or overwrite the newer observation. None
   means no failure has yet been observed for the in-flight read. This is
   display evidence only; the durable original and Goal ledger own all work. *)
type original_read_observation = {
  binding : original_read_binding;
  failure : Worker.error option;
}

(* These observations are published together so one response can render the
   same scan and original-read view for every Goal. They remain in-process
   observations, not a snapshot of either durable ledger. *)
type observation_snapshot = {
  reconciliation : (string * reconcile_failure list) option;
  original_reads : original_read_observation list;
}

let observations = Atomic.make { reconciliation=None; original_reads=[] }
let capture_observations () = Atomic.get observations

(* What the planning projection shows of an observation snapshot: the scan's
   failures and each original read's failure. An in-flight read with no
   failure shows nothing, and neither does a scan that found no failure. The
   row looks each failure up by Goal, so order is not shown: a reread moves
   its observation to the head of the list. *)
let shown snapshot =
  let reconciliation =
    match snapshot.reconciliation with
    | Some (root, (_ :: _ as failures)) -> Some (root, List.sort compare failures)
    | Some (_, []) | None -> None
  in
  ( reconciliation
  , List.filter_map
      (fun observed -> Option.map (fun failure -> observed.binding, failure) observed.failure)
      snapshot.original_reads
    |> List.sort compare )

(* The observations live in this process only, so the planning projection
   changes with them and no store write announces it (RFC-0480 §3.4). *)
let announce_if_shown_changed config ~before ~after =
  if shown before <> shown after then Goal_store.notify_projection_change config

(* A refused scan keeps the previous completed scan's observation. *)
let publish_unreconciled config failures =
  let rec publish () =
    let current = Atomic.get observations in
    let next = {current with reconciliation=Some (Workspace.masc_dir config, failures)} in
    if Atomic.compare_and_set observations current next
    then announce_if_shown_changed config ~before:current ~after:next
    else publish ()
  in
  publish ();
  List.iter
    (fun { failed_goal_id; step; failure } ->
       Log.Misc.error
         "goal verifier ledger %s failed goal_id=%s; its pending row stays undrained: %s"
         (Goal_reconcile_step.to_string step)
         failed_goal_id
         (Goal_store.write_error_to_string failure))
    failures
;;

let same_original_goal left right =
  String.equal left.root right.root && String.equal left.goal_id right.goal_id

let same_original_binding left right =
  same_original_goal left right
  && String.equal left.request_id right.request_id
  && Goal_store.criterion_equal left.criterion right.criterion

let begin_original_read config binding =
  let rec replace () =
    let current = Atomic.get observations in
    let failure = match List.find_opt (fun observed -> same_original_binding observed.binding binding) current.original_reads with
      | Some observed -> observed.failure
      | None -> None in
    let observed = {binding; failure} in
    let original_reads = observed :: List.filter (fun previous -> not (same_original_goal previous.binding binding)) current.original_reads in
    let next = {current with original_reads} in
    if Atomic.compare_and_set observations current next
    then (announce_if_shown_changed config ~before:current ~after:next; observed)
    else replace ()
  in replace ()

let finish_original_read config observed failure =
  let rec replace () =
    let current = Atomic.get observations in
    if not (List.exists (fun candidate -> candidate == observed) current.original_reads) then false
    else
      let original_reads = List.filter_map (fun candidate ->
        if candidate == observed then Option.map (fun failure -> {observed with failure=Some failure}) failure
        else Some candidate) current.original_reads in
      let next = {current with original_reads} in
      if Atomic.compare_and_set observations current next
      then (announce_if_shown_changed config ~before:current ~after:next; true)
      else replace ()
  in replace ()

let abandon_original_read config observed =
  (* Cancellation/exception is not a successful original read. Preserve a
     previously observed failure, if any, rather than clearing it as repaired. *)
  ignore (finish_original_read config observed observed.failure)

let retire_observations config snapshot ~root =
  let retired_reads = List.filter (fun observed -> String.equal observed.binding.root root) snapshot.original_reads in
  let rec replace () =
    let current = Atomic.get observations in
    let reconciliation = match snapshot.reconciliation with
      | Some (observed_root, _) when String.equal observed_root root
          && current.reconciliation == snapshot.reconciliation -> None
      | Some _ | None -> current.reconciliation in
    let original_reads = List.filter (fun candidate ->
      not (List.exists (fun observed -> candidate == observed) retired_reads)) current.original_reads in
    let next = {reconciliation; original_reads} in
    if Atomic.compare_and_set observations current next
    then announce_if_shown_changed config ~before:current ~after:next
    else replace ()
  in replace ()

let unreconciled_from_snapshot_to_yojson snapshot ~config ~record (goal : Goal_store.goal) =
  let render step detail = `Assoc [
    "step", `String (Goal_reconcile_step.to_string step); "detail", `String detail] in
  if goal.phase <> Goal_phase.Verifying then `Null
  else
    let root = Workspace.masc_dir config in
    let reconciliation = match snapshot.reconciliation with
      | Some (observed_root, failures) when String.equal root observed_root ->
        List.find_opt (fun failure -> String.equal failure.failed_goal_id goal.id) failures
      | Some _ | None -> None in
    match reconciliation with
    | Some {step; failure; _} -> render step (Goal_store.write_error_to_string failure)
    | None ->
      match record with
      | Some {Goal_verification.goal_id; completion=Proof_pending pending; _}
        when String.equal goal_id goal.id
          && Goal_store.criterion_equal pending.criterion (Goal_store.criterion_of_goal goal) ->
        let binding = {root; goal_id; request_id=pending.request_id; criterion=pending.criterion} in
        (match List.find_opt (fun observed -> same_original_binding observed.binding binding)
           snapshot.original_reads with
         | Some {failure=Some error; _} -> render Goal_reconcile_step.Read_original (worker_detail error)
         | Some {failure=None; _} | None -> `Null)
      | Some {completion=(Completion_idle | Proof_pending _ | Proof_proven _ | Proof_refuted _ | Human_confirmed _); _}
      | None -> `Null

let unreconciled_to_yojson ~config ~record goal =
  unreconciled_from_snapshot_to_yojson (capture_observations ()) ~config ~record goal

let originals_for_goal store ~goal_id = Worker.inventory_for_goal ~store ~goal_id
  ~installation_id:Worker.host_installation_id
  ~package_id:Worker.host_package_id
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

(* Capture the Goal and its durable request under the Goal lock. The callback
   performs no writes; the model runs only after this lock is released. *)
let bind_review config ~goal_id =
  Goal_verification.bind_review config ~goal_id
  |> Result.map_error Goal_verification.review_binding_error_to_string
;;

let original_read_binding config ~goal_id =
  match bind_review config ~goal_id with
  | Ok (_, (request_id, criterion, _)) ->
    Some {root=Workspace.masc_dir config; goal_id; request_id; criterion}
  | Error _ -> None

let observe_original_read config ~goal_id read =
  let before = capture_observations () in
  let observed = Option.map (begin_original_read config) (original_read_binding config ~goal_id) in
  Fun.protect ~finally:(fun () -> Option.iter (abandon_original_read config) observed) (fun () ->
    match read () with
    | Ok _ as result ->
      Option.iter (fun observed ->
        ignore (finish_original_read config observed None);
        announce_if_shown_changed config ~before ~after:(capture_observations ())) observed;
      result
    | Error error as result ->
      (* Keep the failure. Unknown authority is not a successful original
         read. Projection checks the current binding. *)
      Option.iter (fun observed ->
        ignore (finish_original_read config observed (Some error));
        announce_if_shown_changed config ~before ~after:(capture_observations ())) observed;
      result)

let new_run () : Worker.run_identity =
  {run_id=Random_id.uuid_v7 (); started_at=Time_compat.now ()}

let retained_recovery_work config (work : pending_work list) =
  let store = owner_store config in
  match Worker.inventory_by_goal ~store ~installation_id:Worker.host_installation_id
    ~package_id:Worker.host_package_id with
  | Error error ->
    (* Unknown metadata cannot be attributed to an independent Goal. Pending
       processing repeats the same strict discovery before any dispatch. *)
    Log.Misc.error "goal verifier original metadata unavailable: %s" (worker_detail error);
    work
  | Ok (goals, invalid) ->
    List.iter (fun (request_id,error) ->
      Log.Misc.error "goal verifier original metadata unavailable request_id=%s: %s"
        request_id (worker_detail error)) invalid;
    List.fold_left (fun (work : pending_work list) (goal_id,originals) ->
      match originals with
      | Error error ->
        Log.Misc.error "goal verifier original unavailable goal_id=%s: %s"
          goal_id (worker_detail error);
        (* Keep the owned recovery discoverable. Processing returns a per-Goal
           Proof_lookup_unavailable deferral; this does not arm a retry or
           create a pending-request diagnostic for a phase-moved Goal. *)
        if not (List.exists (fun (item : pending_work) -> item.goal_id=goal_id) work)
        then work @ [{goal_id}] else work
      | Ok rows ->
        List.fold_left (fun (work : pending_work list) retained ->
          let needed = match Host.needs_recovery ~registry:(Registry.global ()) retained with
            | Ok needed -> needed
            | Error error ->
              Log.Misc.error "goal verifier retained observation unavailable goal_id=%s: %s"
                goal_id (Host.error_to_string error);
              true in
          if needed && not (List.exists (fun (item : pending_work) -> item.goal_id=goal_id) work)
          then work @ [{goal_id}] else work) work rows) work goals
;;

let process_pending_work ?(sw : Eio.Switch.t option = None)
    ?(schedule_retry = fun ~goal_id:_ ~request_id:_ _ -> ())
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
      (* One lookup authority per processing: a new attempt, the first attempt
         and the dispatch check all read the same value. *)
      let lookup_authority = Eio.Lazy.from_fun ~cancel:`Record (fun () ->
        Verification_authority_tools.create_goal_review ~config ~goal_id:work.goal_id) in
      let prepare_authority () = Eio.Lazy.force lookup_authority in
      (* One attempt: select or prepare the original, register its run, and
         execute it unless its result is already retained. *)
      let attempt () =
        let* selected = Worker.frontier ~authority:prepare_authority ~store
          ~installation_id:Worker.host_installation_id
          ~package_id:Worker.host_package_id ~goal_id:work.goal_id ~request_id ~new_run
          |> Result.map_error worker_detail in
        let* retained = match selected with
          | Some retained -> Ok retained
          | None ->
            let* authority = prepare_authority () in
            let subject = Verification_authority_tools.goal_review_subject authority in
            let* () = if subject.request_id=request_id && Goal_store.criterion_equal subject.criterion criterion
              then Ok () else Error "Goal proof changed during original preparation" in
            let* original = Original.prepare ~attempt:0 ~authority in
            Worker.retain ~store ~installation_id:Worker.host_installation_id ~package_id:Worker.host_package_id
              ~run:(new_run ()) original |> Result.map_error worker_detail in
        active := Some retained;
        let* () = Host.ensure_registered ~registry retained |> Result.map_error Host.error_to_string in
        let* restored = Worker.restored_receipt retained |> Result.map_error worker_detail in
        let execution = match restored with
          | Some receipt -> Ok receipt
          | None ->
            (match prepare_authority () with
             | Error detail -> Error (Worker.Authority_unavailable detail)
             | Ok authority -> Worker.run ~store ~retained ~authority ~sw
                 ~provider_rest:Verification_retry.provider_rest ()) in
        let* saved = reload_original store retained in
        active := Some saved;
        Ok (saved, execution) in
      let operation () =
        let* saved, execution = attempt () in
        (* HIGH-RISK-UNREVIEWED: an attempt refused before dispatch because its
           lookup authority or answer format moved is asked again once in this
           same processing. Its run row is published as deferred first, and the
           refused attempt is no longer the active one: a cancellation before
           the next attempt is retained leaves that row as published. The walk
           then opens the next attempt with the authority this processing
           prepared, and the worker checks it against that same value. A second
           refusal keeps its own record and waits for the next processing. *)
        let* saved, execution = match execution with
          | Error (Worker.Authority_changed change) ->
            let* () = publish saved (Registry.Deferred {detail=Verifier_review_authority_change.to_string change}) in
            active := None;
            attempt ()
          | Ok _ | Error (Worker.Store_unavailable _ | Original_invalid _ | Destination_mismatch _
              | Authority_unavailable _ | Question_changed | Execution_pending _) -> Ok (saved, execution) in
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
              | Store_unavailable _ | Original_invalid _ | Destination_mismatch _ | Authority_unavailable _
              | Question_changed | Authority_changed _ ->
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
              schedule_retry ~goal_id:work.goal_id ~request_id deferral
            | Ok _ | Error _ -> ())
         | Committed | Superseded -> ());
        Ok outcome in
      (match operation () with Ok outcome -> outcome | Error detail -> fail_original detail) in
  try
    match observe_original_read config ~goal_id:work.goal_id
      (fun () -> originals_for_goal store ~goal_id:work.goal_id) with
    | Error error -> fail_original (worker_detail error)
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
    publish_unreconciled config unreconciled;
    List.iter
      (fun item ->
         (* RFC-0387: per-row outcomes are logged at the point of decision
            (commit/defer); the synchronous drain discards them. *)
         ignore (process_pending_work ~sw config item))
      (retained_recovery_work config collected);
    Ok ()
;;

(* {1 Daemon}

   A condition-variable wake installed as
   {!Workspace_hooks.goal_verification_pending_fn} requests discovery. The
   observed Goal queue is distinct from active reviews: returning capacity
   serves its remaining entries without rediscovering failed Goals. Transient
   evaluator failures arm a request-scoped retry. Other deferrals wait for an
   explicit wake. No wall-clock expiry. *)

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

(* A queued identity is not a stored request or an execution grant. Claims
   and exact retry reservations share one CAS: a replacement claim cannot be
   admitted between retiring an old timer and retaining that timer's wake. *)
type scheduling =
  { ready : pending_work list
  ; in_flight : claim list
  ; retries : (string * string * string) list
  }

type runtime =
  { config : Workspace_utils_backend_setup.config
  ; sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; wake : Eio.Condition.t
  ; pending : bool Atomic.t
  ; scheduling : scheduling Atomic.t
  }

let active_runtime : runtime option Atomic.t = Atomic.make None
let max_concurrent_reviews = 4

let reserve_review (runtime : runtime) =
  (* The promises are allocated once, outside the pure CAS retry. They become
     observable only when their claim is installed. *)
  let abandoned, abandon = Eio.Promise.create () in
  let rec loop () =
    let current = Atomic.get runtime.scheduling in
    if List.length current.in_flight >= max_concurrent_reviews
    then None
    else match current.ready with
      | [] -> None
      | work :: ready ->
        let unavailable =
          List.exists (fun candidate -> pending_work_same_goal work candidate.work) current.in_flight
          || List.exists (fun (id, _, _) -> String.equal work.goal_id id)
               current.retries in
        if unavailable then (
          ignore (Atomic.compare_and_set runtime.scheduling current {current with ready});
          loop ())
        else
          let claim = { work; requested = false; abandoned; abandon } in
          let next = {current with ready; in_flight=claim :: current.in_flight} in
          if Atomic.compare_and_set runtime.scheduling current next
          then Some claim else loop ()
  in
  loop ()
;;

(* Retire this Goal's timers and mark its active claim in one atomic state.
   Retry admission either precedes this wake and is cleared, or observes the
   retained wake and cannot arm. A wake racing with release is retained here
   or sees a free Goal and is handled by the ordinary scan. *)
let retain_active_wake (runtime : runtime) ~goal_id =
  let rec loop () =
    let current = Atomic.get runtime.scheduling in
    let in_flight = List.map (fun claim ->
      { claim with requested = claim.requested || String.equal claim.work.goal_id goal_id })
      current.in_flight in
    let retries = List.filter (fun (id, _, _) -> not (String.equal id goal_id)) current.retries in
    if Atomic.compare_and_set runtime.scheduling current {current with in_flight; retries}
    then () else loop ()
  in loop ()
;;

let same_claim left right = left.abandoned == right.abandoned

let release_review (runtime : runtime) claim =
  let rec loop () =
    let current = Atomic.get runtime.scheduling in
    let retained = List.exists (fun candidate ->
      same_claim candidate claim && candidate.requested) current.in_flight in
    let in_flight = List.filter (fun candidate -> not (same_claim candidate claim)) current.in_flight in
    if Atomic.compare_and_set runtime.scheduling current {current with in_flight}
    then retained else loop ()
  in loop ()
;;

let request_scan (runtime : runtime) =
  Atomic.set runtime.pending true;
  Eio.Condition.broadcast runtime.wake
;;

let remove_retry (runtime : runtime) key =
  let rec loop () =
    let current = Atomic.get runtime.scheduling in
    if not (List.mem key current.retries) then false
    else if Atomic.compare_and_set runtime.scheduling current
      {current with retries=List.filter ((<>) key) current.retries}
    then true else loop ()
  in loop ()
;;

let clear_retries (runtime : runtime) ~goal_id =
  (Atomic.get runtime.scheduling).retries |> List.iter (fun ((id, _, _) as key) ->
    if String.equal id goal_id then ignore (remove_retry runtime key))
;;

let finish_retry (runtime : runtime) ((goal_id, _, _) as key) =
  let rec loop () =
    let current = Atomic.get runtime.scheduling in
    if not (List.mem key current.retries) then false
    else
      let in_flight = List.map (fun claim ->
        {claim with requested=claim.requested || String.equal claim.work.goal_id goal_id})
        current.in_flight in
      let next = {current with in_flight; retries=List.filter ((<>) key) current.retries} in
      if Atomic.compare_and_set runtime.scheduling current next then true else loop ()
  in loop ()
;;

let schedule_retry (runtime : runtime) ~goal_id ~request_id deferral =
  match deferral with
  | Not_reviewed {retryable_runtimes = _ :: _ as runtimes; _} ->
    (* [runtimes] is built at the walk: model-absence refusals (retired or
       unknown models) are classified permanent there and can never appear in
       it, so this arms only while a candidate that reported a typed transient
       failure could serve again. *)
    let key = goal_id, request_id, Random_id.uuid_v7 () in
    let rec admit () =
      let current = Atomic.get runtime.scheduling in
      if List.exists (fun claim -> String.equal claim.work.goal_id goal_id && claim.requested)
           current.in_flight then `Wake_retained
      else if List.exists (fun (id, request, _) -> String.equal id goal_id && String.equal request request_id)
           current.retries then `Already_armed
      else if Atomic.compare_and_set runtime.scheduling current
           {current with retries=key :: current.retries} then `Admitted
      else admit ()
    in
    (match admit () with
    | `Wake_retained | `Already_armed -> ()
    | `Admitted ->
      let seconds = Verification_retry.delay
          ~retry_interval_sec:Env_config.Timeouts.maintenance_pulse_interval_sec
          ~now:(Eio.Time.now runtime.clock) runtimes in
      Eio.Fiber.fork_daemon ~sw:runtime.sw (fun () ->
        let rec reread_after delay =
          Eio.Time.sleep runtime.clock delay;
          if List.mem key (Atomic.get runtime.scheduling).retries then
            match Goal_verification.bind_review runtime.config ~goal_id with
            | Ok (_, (current, _, _)) when String.equal current request_id ->
              if finish_retry runtime key then request_scan runtime
            | Ok _ | Error (Goal_verification.No_current_review _) ->
              ignore (remove_retry runtime key)
            | Error (Goal_verification.Binding_unavailable detail) ->
              Log.Misc.warn
                "goal verifier retry binding unavailable goal_id=%s request_id=%s; retaining retry: %s"
                goal_id request_id detail;
              if List.mem key (Atomic.get runtime.scheduling).retries then
                reread_after Env_config.Timeouts.maintenance_pulse_interval_sec
        in
        reread_after seconds;
        `Stop_daemon))
  | Not_reviewed _ | Review_not_bound _ | Proof_lookup_unavailable _
  | Verdict_without_reason | Commit_refused _ -> ()
;;

(* Resolve the abandon promise of the Goal's claimed review, if one runs.
   A Goal with no claimed review has nothing to cancel. *)
let abandon_review (runtime : runtime) ~goal_id =
  clear_retries runtime ~goal_id;
  (Atomic.get runtime.scheduling).in_flight
  |> List.iter (fun claim ->
    if String.equal claim.work.goal_id goal_id
    then (
      if Eio.Promise.try_resolve claim.abandon ()
      then
        Log.Misc.info
          "goal verifier abandoning in-flight review goal_id=%s: the Goal left verifying"
          goal_id))
;;

(* Every settlement returns capacity to work already observed. Only a wake
   explicitly retained by this claim requests another discovery; a failure
   does not automatically put itself back in the ready queue. *)
let process_goal_work (runtime : runtime) (claim : claim) =
  Eio.Switch.run (fun release_sw ->
    Eio.Switch.on_release release_sw (fun () ->
      if release_review runtime claim then request_scan runtime
      else Eio.Condition.broadcast runtime.wake);
    (* Install cleanup before yielding. The caller has already reserved the
       full batch, so nested scans see every admitted Goal before any work. *)
    Eio.Fiber.yield ();
    (* An abandon cancels the review and its children before the claim is
       released. The original commit still revalidates the Goal's authority. *)
    Eio.Fiber.first
      (fun () ->
        Eio.Switch.run (fun work_sw ->
          Cancel_safe.observe
            ~on_exn:(fun exn ->
              Log.Misc.error
                "goal verifier isolated unexpected worker failure goal_id=%s detail=%s"
                claim.work.goal_id
                (Printexc.to_string exn))
            (fun () ->
              ignore (process_pending_work
                ~sw:(Some work_sw)
                ~schedule_retry:(schedule_retry runtime)
                runtime.config claim.work))))
      (fun () -> Eio.Promise.await claim.abandoned))
;;

let enqueue_pending (runtime : runtime) work =
  let rec loop () =
    let current = Atomic.get runtime.scheduling in
    let fresh = List.fold_left (fun added item ->
      if List.exists (pending_work_same_goal item) current.ready
         || List.exists (pending_work_same_goal item) added
         || List.exists (fun claim -> pending_work_same_goal item claim.work) current.in_flight
         || List.exists (fun (id, _, _) -> String.equal item.goal_id id) current.retries
      then added else item :: added) [] work in
    let next = {current with ready=current.ready @ List.rev fresh} in
    if Atomic.compare_and_set runtime.scheduling current next then () else loop ()
  in loop ()
;;

let discover_pending (runtime : runtime) =
  Eio.Switch.check runtime.sw;
  match collect_pending runtime.config with
  | Error (Scan_skipped unavailable) -> skip_scan unavailable
  | Ok { collected = work; unreconciled } ->
    publish_unreconciled runtime.config unreconciled;
    let work = retained_recovery_work runtime.config work in
    Eio.Switch.check runtime.sw;
    enqueue_pending runtime work
;;

let requeue_unstarted (runtime : runtime) claims =
  let rec loop () =
    let current = Atomic.get runtime.scheduling in
    let still_owned = List.filter (fun claim ->
      List.exists (same_claim claim) current.in_flight) claims in
    let in_flight = List.filter (fun claim ->
      not (List.exists (same_claim claim) still_owned)) current.in_flight in
    let ready = List.map (fun claim -> claim.work) still_owned @ current.ready in
    if Atomic.compare_and_set runtime.scheduling current {current with ready; in_flight}
    then Eio.Condition.broadcast runtime.wake else loop ()
  in loop ()
;;

let dispatch_ready (runtime : runtime) =
  let rec reserve claims =
    match Eio.Switch.check runtime.sw; reserve_review runtime with
    | None -> List.rev claims
    | Some claim -> reserve (claim :: claims)
    | exception exn ->
      let bt = Printexc.get_raw_backtrace () in
      requeue_unstarted runtime (List.rev claims);
      Printexc.raise_with_backtrace exn bt
  in
  let rec launch = function
    | [] -> ()
    | claim :: rest ->
      let entered = ref false in
      (match
         Eio.Switch.check runtime.sw;
         Eio.Fiber.fork ~sw:runtime.sw (fun () ->
           entered := true;
           process_goal_work runtime claim);
         (* Eio's fork may return without entering its callback if the switch
            was cancelled. A returned reservation is not an execution. *)
         Eio.Switch.check runtime.sw
       with
       | () -> launch rest
       | exception exn ->
         let bt = Printexc.get_raw_backtrace () in
         requeue_unstarted runtime (if !entered then rest else claim :: rest);
         Printexc.raise_with_backtrace exn bt)
  in
  launch (reserve [])
;;

let process_pending (runtime : runtime) =
  discover_pending runtime;
  dispatch_ready runtime
;;

let run (runtime : runtime) : [ `Stop_daemon ] =
  Eio.Condition.loop_no_mutex runtime.wake (fun () ->
    Cancel_safe.observe
      ~on_exn:(fun exn ->
        Log.Misc.error
          "goal verifier isolated unexpected scan failure detail=%s"
          (Printexc.to_string exn))
      (fun () ->
        if Atomic.exchange runtime.pending false then discover_pending runtime;
        dispatch_ready runtime);
    None)
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
    ; wake = Eio.Condition.create ()
    ; pending = Atomic.make true
    ; scheduling = Atomic.make {ready=[]; in_flight=[]; retries=[]}
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
      let snapshot = capture_observations () in
      if Atomic.compare_and_set active_runtime owner None
      then (
        (* No scan runs after this, so its last list would read as current. *)
        Atomic.set runtime.scheduling {ready=[]; in_flight=[]; retries=[]};
        retire_observations config snapshot ~root:(Workspace.masc_dir config);
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
    | Some runtime -> List.exists (fun (id, _, _) -> String.equal id goal_id)
        (Atomic.get runtime.scheduling).retries

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
