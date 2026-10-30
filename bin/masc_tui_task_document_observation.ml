type source = Work of string | Async of
  { submitted_by:string; request_id:string; keeper_name:string; run_id:string; task_id:string }
type identity =
  { source:source; part:Masc_tui_task_document.part; columns:int; generation:int64
  ; workspace_revision:int; workspace_fingerprint:string option }
type failure = Raised | Interrupted
type worker_context = Shared_worker | Inline
type worker_outcome = Prepared | Worker_failed of failure
type caller_outcome = Returned | Caller_failed of failure | Not_started
type rejection = Reading_withdrawn | Superseded | Source_or_width_changed
type admission = Applied | Applied_failure | Rejected of rejection
type retirement = Replaced | Source_unavailable | Reading_suspended | Workspace_withdrawn | Rejected_owner
type event =
  | Requested | Caller_started | Submit_requested | Worker_entered of worker_context
  | Worker_returned of worker_outcome | Caller_observed of caller_outcome
  | Ui_disposition of admission | Retired of retirement
  | Cancellation_requested | Registration_released
type facts =
  { requested_ns:int64 option; caller_started_ns:int64 option; submit_requested_ns:int64 option
  ; worker_entered:(int64 * worker_context) option; worker_returned:(int64 * worker_outcome) option
  ; caller_observed:(int64 * caller_outcome) option; ui_disposition:(int64 * admission) option
  ; retired:(int64 * retirement) option; cancellation_requested_ns:int64 option
  ; registration_released_ns:int64 option }
let empty =
  {requested_ns=None;caller_started_ns=None;submit_requested_ns=None;worker_entered=None;
   worker_returned=None;caller_observed=None;ui_disposition=None;retired=None;
   cancellation_requested_ns=None;registration_released_ns=None}
type t = {id:string;pid:int;identity:identity;facts: facts Atomic.t}
let process_id=Uuidm.(v4_gen (Random.State.make_self_init ()) () |> to_string)
let sequence=Atomic.make 0
let rec next_id () = let old=Atomic.get sequence in
  if Atomic.compare_and_set sequence old (old+1) then process_id ^ ":" ^ string_of_int old else next_id ()
let record facts ~at_ns = function
  | Requested -> (match facts.requested_ns with None -> {facts with requested_ns=Some at_ns} | Some _ -> facts)
  | Caller_started -> (match facts.caller_started_ns with None -> {facts with caller_started_ns=Some at_ns} | Some _ -> facts)
  | Submit_requested -> (match facts.submit_requested_ns with None -> {facts with submit_requested_ns=Some at_ns} | Some _ -> facts)
  | Worker_entered context -> (match facts.worker_entered with None -> {facts with worker_entered=Some(at_ns,context)} | Some _ -> facts)
  | Worker_returned outcome -> (match facts.worker_returned with None -> {facts with worker_returned=Some(at_ns,outcome)} | Some _ -> facts)
  | Caller_observed outcome -> (match facts.caller_observed with None -> {facts with caller_observed=Some(at_ns,outcome)} | Some _ -> facts)
  | Ui_disposition outcome -> (match facts.ui_disposition with None -> {facts with ui_disposition=Some(at_ns,outcome)} | Some _ -> facts)
  | Retired reason -> (match facts.retired with None -> {facts with retired=Some(at_ns,reason)} | Some _ -> facts)
  | Cancellation_requested -> (match facts.cancellation_requested_ns with None -> {facts with cancellation_requested_ns=Some at_ns} | Some _ -> facts)
  | Registration_released -> (match facts.registration_released_ns with None -> {facts with registration_released_ns=Some at_ns} | Some _ -> facts)
let ns n = `String (Int64.to_string n)
let optional f = function None -> `Null | Some x -> f x
let timed f (at,value) = `Assoc ["at_ns",ns at;"value",f value]
let failure = function Raised -> "raised" | Interrupted -> "interrupted"
let caller = function Returned -> "returned" | Caller_failed why -> failure why | Not_started -> "not_started"
let worker = function Prepared -> "prepared" | Worker_failed why -> failure why
let rejection = function Reading_withdrawn -> "reading_withdrawn" | Superseded -> "superseded" | Source_or_width_changed -> "source_or_width_changed"
let admission = function Applied -> `String "applied" | Applied_failure -> `String "applied_failure"
  | Rejected why -> `Assoc ["rejected",`String (rejection why)]
let retirement = function Replaced -> "replaced" | Source_unavailable -> "source_unavailable"
  | Reading_suspended -> "reading_suspended" | Workspace_withdrawn -> "workspace_withdrawn" | Rejected_owner -> "rejected_owner"
let phase = function Requested -> "requested" | Caller_started -> "caller_started" | Submit_requested -> "submit_requested"
  | Worker_entered _ -> "worker_entered" | Worker_returned _ -> "worker_returned" | Caller_observed _ -> "caller_observed"
  | Ui_disposition _ -> "ui_disposition" | Retired _ -> "retired" | Cancellation_requested -> "cancellation_requested"
  | Registration_released -> "registration_released"
let snapshot_facts t f =
  let source=match t.identity.source with
    | Work task_id -> `Assoc ["consumer",`String "work";"task_id",`String task_id]
    | Async source -> `Assoc ["consumer",`String "async_source";"task_id",`String source.task_id;
      "submitted_by",`String source.submitted_by;"request_id",`String source.request_id;
      "keeper_name",`String source.keeper_name;"run_id",`String source.run_id] in
  let elapsed start finish=match start,finish with Some a,Some b -> ns(Int64.sub b a) | None,_ | _,None -> `Null in
  `Assoc ["schema",`String "masc.tui-task-document-observation/v1";"capture_id",`String t.id;"pid",`Int t.pid;
    "source",source;"part",`String(match t.identity.part with Masc_tui_task_document.Body -> "body" | History -> "history");
    "columns",`Int t.identity.columns;"generation",ns t.identity.generation;
    "workspace_revision",`Int t.identity.workspace_revision;
    "workspace_fingerprint",optional (fun s -> `String s) t.identity.workspace_fingerprint;
    "requested_ns",optional ns f.requested_ns;"caller_started_ns",optional ns f.caller_started_ns;
    "submit_requested_ns",optional ns f.submit_requested_ns;
    "worker_entered",optional (timed (fun c -> `String(match c with Shared_worker -> "shared_worker" | Inline -> "inline"))) f.worker_entered;
    "worker_returned",optional (timed (fun o -> `String(worker o))) f.worker_returned;
    "caller_observed",optional (timed (fun o -> `String(caller o))) f.caller_observed;
    "ui_disposition",optional (timed admission) f.ui_disposition;
    "retired",optional (timed (fun r -> `String(retirement r))) f.retired;
    "cancellation_requested_ns",optional ns f.cancellation_requested_ns;
    "registration_released_ns",optional ns f.registration_released_ns;
    "submit_to_worker_elapsed_ns",elapsed f.submit_requested_ns (Option.map fst f.worker_entered);
    "worker_body_elapsed_ns",elapsed (Option.map fst f.worker_entered) (Option.map fst f.worker_returned);
    "request_to_ui_observed_ns",elapsed f.requested_ns (Option.map fst f.ui_disposition)]
let snapshot_json t = snapshot_facts t (Atomic.get t.facts)
let facts t = Atomic.get t.facts
let observe t event =
  let at_ns=Mtime_clock.elapsed_ns () in
  let rec update () = let old=Atomic.get t.facts in let next=record old ~at_ns event in
    if next==old then None else if Atomic.compare_and_set t.facts old next then Some next else update () in
  match update () with
  | None -> ()
  | Some captured ->
    let emit () =
      try Log.Transport.info "tui_task_document=%s" (Yojson.Safe.to_string (`Assoc
        ["phase",`String(phase event);"at_ns",ns at_ns;"snapshot",snapshot_facts t captured])) with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> () (* Diagnostic sink failures never classify preparation or admission. *) in
    match Eio_guard.execution_context () with
    | Eio_guard.Eio_fiber -> Eio.Cancel.protect emit
    | Non_eio -> emit ()
let create identity =
  let t={id=next_id ();pid=Unix.getpid ();identity;facts=Atomic.make empty} in
  observe t Requested;t

let run t ~name prepare =
  observe t Caller_started;
  let failure = function Eio.Cancel.Cancelled _ -> Interrupted | _ -> Raised in
  let worker () =
    observe t (Worker_entered (if Executor_pool_ref.in_worker_context () then Shared_worker else Inline));
    match prepare () with
    | rows -> observe t (Worker_returned Prepared);rows
    | exception exn ->
      let bt=Printexc.get_raw_backtrace () in
      observe t (Worker_returned (Worker_failed (failure exn)));
      Printexc.raise_with_backtrace exn bt in
  observe t Submit_requested;
  match Masc_tui_response_decode.run ~name worker with
  | result -> observe t (Caller_observed Returned);result
  | exception exn ->
    let bt=Printexc.get_raw_backtrace () in
    observe t (Caller_observed (Caller_failed (failure exn)));
    Printexc.raise_with_backtrace exn bt
