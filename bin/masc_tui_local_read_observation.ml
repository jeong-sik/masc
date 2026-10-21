type source = Local_keepers | Local_work
type intent = Poll | Refresh
type identity =
  { source:source; intent:intent; request_id:int; demand_revision:string
  ; workspace_revision:int; workspace_fingerprint:string option }
type stage = Io | Task_comparison
type failure = Raised | Interrupted
type worker_context = Shared_worker | Inline
type worker_outcome = Body_returned | Body_failed of failure
type caller_outcome = Returned | Caller_failed of failure | Not_started
type comparison = Immediate | Compare
type rejection = Wrong_source | Workspace_withdrawn | Superseded
type admission = Accepted | Accepted_failure | Rejected of rejection
type application = Applied | Apply_failed of failure | Read_failure_applied
type retirement = Replaced | Read_invalidated
type event =
  | Caller_started | Submitted of stage | Worker_entered of stage * worker_context
  | Worker_returned of stage * worker_outcome | Submission_observed of stage * caller_outcome
  | Comparison_decided of comparison | Caller_observed of caller_outcome
  | Ui_admission of admission | Ui_application of application | Retired of retirement
  | Cancellation_requested | Registration_released
type stage_facts =
  { submitted_ns:int64 option; worker_entered:(int64 * worker_context) option
  ; worker_returned:(int64 * worker_outcome) option; caller_observed:(int64 * caller_outcome) option }
type facts =
  { requested_ns:int64; caller_started_ns:int64 option; io:stage_facts; comparison:stage_facts
  ; comparison_decided:(int64 * comparison) option; caller_observed:(int64 * caller_outcome) option
  ; ui_admission:(int64 * admission) option; ui_application:(int64 * application) option
  ; retired:(int64 * retirement) option; cancellation_requested_ns:int64 option
  ; registration_released_ns:int64 option }
let empty_stage = {submitted_ns=None;worker_entered=None;worker_returned=None;caller_observed=None}
type t = {id:string;pid:int;identity:identity;facts:facts Atomic.t}
let process_id=Uuidm.(v4_gen (Random.State.make_self_init ()) () |> to_string)
let sequence=Atomic.make 0
let rec next_id () = let old=Atomic.get sequence in
  if Atomic.compare_and_set sequence old (old+1) then process_id ^ ":" ^ string_of_int old else next_id ()
let first previous value = match previous with None -> Some value | Some _ -> previous
let update_stage (facts : facts) stage update = match stage with
  | Io -> {facts with io=update facts.io}
  | Task_comparison -> {facts with comparison=update facts.comparison}
let record (facts : facts) ~at = function
  | Caller_started -> {facts with caller_started_ns=first facts.caller_started_ns at}
  | Submitted stage -> update_stage facts stage (fun f -> {f with submitted_ns=first f.submitted_ns at})
  | Worker_entered (stage,context) -> update_stage facts stage (fun f -> {f with worker_entered=first f.worker_entered (at,context)})
  | Worker_returned (stage,outcome) -> update_stage facts stage (fun f -> {f with worker_returned=first f.worker_returned (at,outcome)})
  | Submission_observed (stage,outcome) -> update_stage facts stage (fun f -> {f with caller_observed=first f.caller_observed (at,outcome)})
  | Comparison_decided decision -> {facts with comparison_decided=first facts.comparison_decided (at,decision)}
  | Caller_observed outcome -> {facts with caller_observed=first facts.caller_observed (at,outcome)}
  | Ui_admission outcome -> {facts with ui_admission=first facts.ui_admission (at,outcome)}
  | Ui_application outcome -> {facts with ui_application=first facts.ui_application (at,outcome)}
  | Retired reason -> {facts with retired=first facts.retired (at,reason)}
  | Cancellation_requested -> {facts with cancellation_requested_ns=first facts.cancellation_requested_ns at}
  | Registration_released -> {facts with registration_released_ns=first facts.registration_released_ns at}
let ns n = `String (Int64.to_string n)
let optional f = function None -> `Null | Some x -> f x
let failure = function Raised -> "raised" | Interrupted -> "interrupted"
let caller = function Returned -> "returned" | Caller_failed why -> failure why | Not_started -> "not_started"
let worker = function Body_returned -> "body_returned" | Body_failed why -> failure why
let stage_name = function Io -> "io" | Task_comparison -> "task_comparison"
let event_name = function
  | Caller_started -> "caller_started" | Submitted s -> stage_name s ^ "_submitted"
  | Worker_entered (s,_) -> stage_name s ^ "_worker_entered"
  | Worker_returned (s,_) -> stage_name s ^ "_worker_returned"
  | Submission_observed (s,_) -> stage_name s ^ "_caller_observed"
  | Comparison_decided _ -> "comparison_decided" | Caller_observed _ -> "caller_observed"
  | Ui_admission _ -> "ui_admission" | Ui_application _ -> "ui_application"
  | Retired _ -> "retired" | Cancellation_requested -> "cancellation_requested"
  | Registration_released -> "registration_released"
let admission = function
  | Accepted -> `String "accepted" | Accepted_failure -> `String "accepted_failure"
  | Rejected why -> `Assoc ["rejected",`String (match why with
      | Wrong_source -> "wrong_source" | Workspace_withdrawn -> "workspace_withdrawn" | Superseded -> "superseded")]
let application = function Applied -> "applied" | Read_failure_applied -> "read_failure_applied"
  | Apply_failed why -> "apply_" ^ failure why
let event_fields = function
  | Caller_started | Submitted _ | Cancellation_requested | Registration_released -> []
  | Worker_entered (_,context) ->
      ["context",`String (match context with Shared_worker -> "shared_worker" | Inline -> "inline")]
  | Worker_returned (_,outcome) -> ["outcome",`String (worker outcome)]
  | Submission_observed (_,outcome) | Caller_observed outcome -> ["outcome",`String (caller outcome)]
  | Comparison_decided decision -> ["decision",`String (match decision with Immediate -> "immediate" | Compare -> "compare")]
  | Ui_admission outcome -> ["outcome",admission outcome]
  | Ui_application outcome -> ["outcome",`String (application outcome)]
  | Retired reason -> ["reason",`String (match reason with Replaced -> "replaced" | Read_invalidated -> "read_invalidated")]
let facts t = Atomic.get t.facts
let emit t ~at ~phase fields =
  let emit () = try Log.Transport.routine_lazy (fun () ->
    "tui_local_read=" ^ Yojson.Safe.to_string (`Assoc
      (["schema",`String "masc.tui-local-read-observation/v2";"capture_id",`String t.id;
        "phase",`String phase;"at_ns",ns at] @ fields))) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> () (* A diagnostic sink does not decide the read or application. *) in
  match Eio_guard.execution_context () with
  | Eio_guard.Eio_fiber -> Eio.Cancel.protect emit
  | Non_eio -> emit ()
let observe t event =
  let at=Mtime_clock.elapsed_ns () in
  let rec update () =
    let old=Atomic.get t.facts in let next=record old ~at event in
    if old=next then None
    else if Atomic.compare_and_set t.facts old next then Some next else update () in
  match update () with
  | None -> ()
  | Some _ -> emit t ~at ~phase:(event_name event) (event_fields event)
let create ~requested_ns identity =
  let t={id=next_id ();pid=Unix.getpid ();identity;facts=Atomic.make
    {requested_ns;caller_started_ns=None;io=empty_stage;comparison=empty_stage;
     comparison_decided=None;caller_observed=None;ui_admission=None;ui_application=None;
     retired=None;cancellation_requested_ns=None;registration_released_ns=None}} in
  (* Creation is observed even if no switch ever starts the caller. *)
  emit t ~at:requested_ns ~phase:"requested"
    ["pid",`Int t.pid;
     "source",`String (match t.identity.source with Local_keepers -> "keepers" | Local_work -> "work");
     "intent",`String (match t.identity.intent with Poll -> "poll" | Refresh -> "refresh");
     "request_id",`Int t.identity.request_id;"demand_revision",`String t.identity.demand_revision;
     "workspace_revision",`Int t.identity.workspace_revision;
     "workspace_fingerprint",optional (fun s -> `String s) t.identity.workspace_fingerprint];
  t
let failure_of_exception = function Eio.Cancel.Cancelled _ -> Interrupted | _ -> Raised
let run_stage t stage submit work =
  let worker () =
    observe t (Worker_entered (stage,if Executor_pool_ref.in_worker_context () then Shared_worker else Inline));
    match work () with
    | value -> observe t (Worker_returned (stage,Body_returned));value
    | exception exn -> let bt=Printexc.get_raw_backtrace () in
      observe t (Worker_returned (stage,Body_failed (failure_of_exception exn)));
      Printexc.raise_with_backtrace exn bt in
  observe t (Submitted stage);
  match submit worker with
  | value -> observe t (Submission_observed (stage,Returned));value
  | exception exn -> let bt=Printexc.get_raw_backtrace () in
    observe t (Submission_observed (stage,Caller_failed (failure_of_exception exn)));
    Printexc.raise_with_backtrace exn bt
let run t ~read ~prepare =
  observe t Caller_started;
  match prepare (run_stage t Io Domain_pool_ref.submit_io_or_inline read) with
  | value -> observe t (Caller_observed Returned);value
  | exception exn -> let bt=Printexc.get_raw_backtrace () in
    observe t (Caller_observed (Caller_failed (failure_of_exception exn)));
    Printexc.raise_with_backtrace exn bt
let compare_tasks t ~name work = run_stage t Task_comparison (Masc_tui_response_decode.run ~name) work
let apply t apply value =
  match apply value with
  | () -> observe t (Ui_application Applied)
  | exception exn -> let bt=Printexc.get_raw_backtrace () in
    observe t (Ui_application (Apply_failed (failure_of_exception exn)));
    Printexc.raise_with_backtrace exn bt
type pending = Awaiting_start | Io_queued | Io_running | Io_returning | Preparing
  | Comparison_queued | Comparison_running | Comparison_returning | Awaiting_ui
  | Read_failed of failure | Read_not_started
let pending t =
  let f=facts t in
  match f.caller_observed with
  | Some (_,Returned) -> Awaiting_ui
  | Some (_,Caller_failed failure) -> Read_failed failure
  | Some (_,Not_started) -> Read_not_started
  | None ->
    if Option.is_some f.comparison.caller_observed then Preparing
    else if Option.is_some f.comparison.worker_returned then Comparison_returning
    else if Option.is_some f.comparison.worker_entered then Comparison_running
    else if Option.is_some f.comparison.submitted_ns then Comparison_queued
    else if Option.is_some f.io.caller_observed then Preparing
    else if Option.is_some f.io.worker_returned then Io_returning
    else if Option.is_some f.io.worker_entered then Io_running
    else if Option.is_some f.io.submitted_ns then Io_queued
    else Awaiting_start
