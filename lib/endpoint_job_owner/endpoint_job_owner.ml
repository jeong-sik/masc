module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module L = Endpoint_job_launch
module C = Endpoint_job_lifetime
module D = Endpoint_job_result

let ( let* ) = Result.bind

type error =
  | Registry_error of R.error
  | Launch_error of L.error
  | Lifetime_error of C.error
  | Result_error of D.error
  | Binding_mismatch
  | Admission_mismatch
  | Launch_unknown
  | Result_digest_mismatch
  | Execution_unavailable of string
  | Owner_stopped
  | Controller_failed of exn

let error_to_string = function
  | Registry_error error -> R.error_to_string error
  | Launch_error error -> L.error_to_string error
  | Lifetime_error error -> C.error_to_string error
  | Result_error error -> D.error_to_string error
  | Binding_mismatch -> "endpoint original binding mismatch"
  | Admission_mismatch -> "endpoint original admission mismatch"
  | Launch_unknown -> "endpoint original live launch ownership is unknown"
  | Result_digest_mismatch -> "endpoint original result digest mismatch"
  | Execution_unavailable detail -> "endpoint execution unavailable: " ^ detail
  | Owner_stopped -> "endpoint original owner stopped"
  | Controller_failed error -> "endpoint original controller failed: " ^ Printexc.to_string error

type 'a completion = {
  value : 'a Eio.Promise.t;
  resolver : 'a Eio.Promise.u;
  finished : bool Atomic.t;
}

let completion () =
  let value,resolver=Eio.Promise.create () in
  {value;resolver;finished=Atomic.make false}

let finish completion value =
  if Atomic.compare_and_set completion.finished false true then
    Eio.Promise.resolve completion.resolver value

type control_kind = Activation | Cancellation

type request = {
  kind : control_kind;
  completion : (unit,error) result completion;
}

type execution_state = Awaiting_activation | Owned of C.t | Unknown_launch
type actor_state = Running | Failed of exn | Stopped
type stop_reason = Actor_failed of exn | Endpoint_stopped

type operation = {
  controller : t;
  source : R.record Atomic.t;
  execution : execution_state Atomic.t;
  result : (P.Sha256.t,error) result completion Atomic.t;
  active : request option Atomic.t;
  pending_activation : request option Atomic.t;
  pending_cancellation : request option Atomic.t;
  queue : Eio.Mutex.t;
  changed : Eio.Condition.t;
  actor : actor_state Atomic.t;
}
and t = {
  sw : Eio.Switch.t;
  fs : Eio.Fs.dir_ty Eio.Path.t;
  cgroup_parent_path : string;
  registry : R.t;
  new_id : unit -> P.Id.t;
  resolve_execution : P.spec -> (L.execution,string) result;
  before_request : unit -> unit;
  operations : (string,operation) Hashtbl.t;
  admissions : (string,admission) Hashtbl.t;
  operations_lock : Eio.Mutex.t;
}
and admission = {
  binding : P.binding;
  spec : P.spec;
  completion : (operation,error) result completion;
}

exception Actor_stop

let new_request kind = {kind;completion=completion ()}
let current_result operation = Atomic.get operation.result

let stop_operation operation reason =
  let state,error=match Atomic.get operation.actor,reason with
    | Stopped,(Actor_failed _ | Endpoint_stopped)
    | (Running | Failed _),Endpoint_stopped -> Stopped,Owner_stopped
    | (Running | Failed _),Actor_failed ex -> Failed ex,Controller_failed ex
  in
  Atomic.set operation.actor state;
  let finish_request (request : request) = finish request.completion (Error error) in
  Option.iter finish_request (Atomic.get operation.active);
  Option.iter finish_request (Atomic.get operation.pending_activation);
  Option.iter finish_request (Atomic.get operation.pending_cancellation);
  Atomic.set operation.active None;
  Atomic.set operation.pending_activation None;
  Atomic.set operation.pending_cancellation None;
  (* A controller failure is not a native job outcome. The independent lifetime
     remains responsible for an already owned original and its result. *)
  (match Atomic.get operation.execution with
   | Awaiting_activation -> finish (current_result operation) (Error error)
   | Owned _ | Unknown_launch -> ());
  Eio.Condition.broadcast operation.changed

let mark_launch_unknown operation =
  match Atomic.get operation.execution with
  | Owned _ | Unknown_launch -> ()
  | Awaiting_activation ->
      Atomic.set operation.execution Unknown_launch;
      finish (current_result operation) (Error Launch_unknown)

let update_source operation record =
  Atomic.set operation.source record;
  match R.launch_state record with
  | R.Not_requested -> ()
  | R.Requested _ -> mark_launch_unknown operation

let refresh operation =
  let* record=R.refresh (Atomic.get operation.source) |> Result.map_error (fun error -> Registry_error error) in
  update_source operation record;
  Ok record

let reset_result_for_control operation =
  match Atomic.get operation.execution with
  | Owned _ | Unknown_launch -> ()
  | Awaiting_activation ->
    let current=current_result operation in
    let replace=match Eio.Promise.peek current.value with
      | Some (Ok _) | Some (Error (Launch_unknown | Owner_stopped)) -> false
      | Some (Error (Registry_error _ | Launch_error _ | Lifetime_error _ | Result_error _
        | Binding_mismatch | Admission_mismatch | Execution_unavailable _
        | Result_digest_mismatch | Controller_failed _)) -> true
      | None -> false
    in
    if replace then ignore (Atomic.compare_and_set operation.result current (completion ()))

let publish_unlaunched operation source () =
  let published=Eio.Switch.run (fun sw ->
    let* proof=R.settle_cancelled_admission ~sw source |> Result.map_error (fun error -> Registry_error error) in
    let* result=D.publish_unlaunched ~sw ~proof |> Result.map_error (fun error -> Result_error error) in
    Ok (D.sha256 result)) in
  match published with
  | Ok digest -> Ok digest
  | Error error ->
    match refresh operation with
    | Ok _ -> Error error
    | Error refresh_error -> Error refresh_error

let result_ready operation =
  match Eio.Promise.peek (current_result operation).value with
  | Some (Ok _) -> true
  | Some (Error _) | None -> false

let map_lifetime_error = function
  | C.Owner_stopped -> Owner_stopped
  | C.Registry_error error -> Registry_error error
  | C.Result_error error -> Result_error error
  | (C.Supervisor_error _ | C.Job_failed _) as error -> Lifetime_error error

let cancelled_activation operation current =
  let followup=if result_ready operation then None else Some (publish_unlaunched operation current) in
  Error (Registry_error R.Launch_cancelled),followup

let bridge_result operation job =
  (* Observers accepted before activation already hold this cell. Later native
     observers read the lifetime directly, including after endpoint teardown. *)
  let result_cell=current_result operation in
  let sw=operation.controller.sw in
  Eio.Switch.check sw;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    match C.await_result job with
    | value -> finish result_cell (Result.map_error map_lifetime_error value);`Stop_daemon
    | exception (Eio.Cancel.Cancelled _ as ex) ->
        let bt=Printexc.get_raw_backtrace () in
        finish result_cell (Error Owner_stopped);
        Printexc.raise_with_backtrace ex bt
    | exception ex -> finish result_cell (Error (Controller_failed ex));`Stop_daemon)

let start_intent operation intent execution =
  Atomic.set operation.source (R.launch_record intent);
  let job=C.start_effect_workspace ~sw:operation.controller.sw ~fs:operation.controller.fs
    ~cgroup_parent_path:operation.controller.cgroup_parent_path ~execution intent in
  Atomic.set operation.execution (Owned job);
  bridge_result operation job;
  Ok (),None

let reconcile_activation_error operation error =
  match refresh operation with
  | Error refresh_error -> Error refresh_error,None
  | Ok current ->
    match Atomic.get operation.execution with
    | Owned _ -> Ok (),None
    | Unknown_launch -> Error Launch_unknown,None
    | Awaiting_activation ->
      if R.cancellation_state current=R.Cancellation_requested then cancelled_activation operation current
      else Error (Registry_error error),None

let start_native operation current execution =
  let launch_id=operation.controller.new_id () in
  try
    let intent=R.commit_launch current ~confirmed_admission_id:(R.admission_id current) ~launch_id in
    match intent with
    | Ok intent -> start_intent operation intent execution
    | Error error -> reconcile_activation_error operation error
  with
  | Eio.Cancel.Cancelled _ as ex ->
      let bt=Printexc.get_raw_backtrace () in
      mark_launch_unknown operation;
      Printexc.raise_with_backtrace ex bt
  | ex ->
      let error=Controller_failed ex in
      mark_launch_unknown operation;
      finish (current_result operation) (Error error);
      Error error,None

let run_activate operation =
  match refresh operation with
  | Error error -> Error error,None
  | Ok current ->
    match Atomic.get operation.execution with
    | Owned _ -> Ok (),None
    | Unknown_launch -> Error Launch_unknown,None
    | Awaiting_activation ->
      if R.cancellation_state current=R.Cancellation_requested then cancelled_activation operation current
      else
        (match L.check_execution_domain (R.specification current) with
         | Error error -> Error (Launch_error error),None
         | Ok () ->
           match operation.controller.resolve_execution (R.specification current) with
           | Error detail -> Error (Execution_unavailable detail),None
           | Ok execution -> start_native operation current execution)

let run_cancel operation =
  match Atomic.get operation.execution with
  | Owned job ->
    (match C.cancel job |> Result.map_error map_lifetime_error with
     | Error error -> Error error,None
     | Ok current -> update_source operation current;Ok (),None)
  | Unknown_launch | Awaiting_activation ->
    let source=Atomic.get operation.source in
    (match R.request_cancel source ~confirmed_admission_id:(R.admission_id source) with
     | Error error -> Error (Registry_error error),None
     | Ok current ->
       update_source operation current;
       (match R.launch_state current with
        | R.Requested _ -> Ok (),None
        | R.Not_requested ->
          if result_ready operation then Ok (),None
          else Ok (),Some (publish_unlaunched operation current)))

let run_request operation request =
  match request.kind with
  | Activation -> run_activate operation
  | Cancellation -> run_cancel operation

let complete_active operation (request : request) outcome =
  finish request.completion outcome;
  Eio.Mutex.use_ro operation.queue (fun () ->
    match Atomic.get operation.active with
    | Some current when current==request -> Atomic.set operation.active None
    | Some _ | None -> ());
  Eio.Condition.broadcast operation.changed

let next_request operation =
  Eio.Mutex.use_ro operation.queue (fun () ->
    let promote pending =
      match Atomic.get pending with
      | Some request ->
          Atomic.set pending None;
          Atomic.set operation.active (Some request);
          Some request
      | None -> None
    in
    let rec wait () =
      match Atomic.get operation.actor with
      | Failed _ | Stopped -> raise Actor_stop
      | Running ->
        match promote operation.pending_cancellation with
        | Some request -> request
        | None ->
          match promote operation.pending_activation with
          | Some request -> request
          | None -> Eio.Condition.await operation.changed operation.queue;wait ()
    in
    wait ())

let rec actor_loop operation =
  let request=next_request operation in
  operation.controller.before_request ();
  reset_result_for_control operation;
  let result_cell=current_result operation in
  let outcome,followup=match run_request operation request with
    | outcome -> outcome
    | exception (Eio.Cancel.Cancelled _ as ex) ->
        let bt=Printexc.get_raw_backtrace () in
        Printexc.raise_with_backtrace ex bt
    | exception ex -> Error (Controller_failed ex),None
  in
  complete_active operation request outcome;
  (match outcome,followup with
   | Error error,None ->
     (match Atomic.get operation.execution with
      | Awaiting_activation -> finish result_cell (Error error)
      | Owned _ | Unknown_launch -> ())
   (* A request error reaches its caller through [complete_active]. With a followup, the result cell takes the publish outcome and the request error is not repeated there. *)
   | Ok (),None | Ok (),Some _ | Error _,Some _ -> ());
  (match followup with
   | Some publish -> finish result_cell (publish ())
   | None -> ());
  actor_loop operation

let spawn_actor operation =
  let sw=operation.controller.sw in
  Eio.Switch.check sw;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    match Eio.Fiber.yield ();actor_loop operation with
    | () -> `Stop_daemon
    | exception Actor_stop -> `Stop_daemon
    | exception (Eio.Cancel.Cancelled _ as ex) ->
        let bt=Printexc.get_raw_backtrace () in
        stop_operation operation Endpoint_stopped;
        Printexc.raise_with_backtrace ex bt
    | exception ex ->
        stop_operation operation (Actor_failed ex);
        `Stop_daemon);
  Eio.Switch.check sw

let start_operation operation =
  let sw=operation.controller.sw in
  Eio.Switch.check sw;
  Eio.Switch.on_release sw (fun () -> stop_operation operation Endpoint_stopped);
  spawn_actor operation

let enqueue operation kind =
  (* All control scheduling is in the endpoint's domain. No I/O or yield occurs
     while inspecting/updating these slots; the actor yields before its work. *)
  let restart=match Atomic.get operation.actor with
    | Running | Stopped -> false
    | Failed _ ->
        Eio.Switch.check operation.controller.sw;
        Atomic.set operation.actor Running;
        true
  in
  let outcome=Eio.Mutex.use_ro operation.queue (fun () ->
    match Atomic.get operation.actor with
    | Stopped -> `Stopped Owner_stopped
    | Failed ex -> `Stopped (Controller_failed ex)
    | Running ->
      let active=match Atomic.get operation.active with
        | Some request when request.kind=kind -> Some request
        | Some _ | None -> None
      in
      let pending=match kind with
        | Activation -> Atomic.get operation.pending_activation
        | Cancellation -> Atomic.get operation.pending_cancellation
      in
      match active,pending with
      | Some request,_ | None,Some request -> `Existing request
      | None,None ->
          let request=new_request kind in
          (match kind with
           | Activation -> Atomic.set operation.pending_activation (Some request)
           | Cancellation -> Atomic.set operation.pending_cancellation (Some request));
          `New request) in
  if restart then spawn_actor operation;
  match outcome with
  | `Stopped error ->
      let request=new_request kind in
      finish request.completion (Error error);
      request
  | `Existing request -> request
  | `New request -> Eio.Condition.broadcast operation.changed;request

let reconcile_if_cancelled operation =
  match Atomic.get operation.actor with
  | Failed _ | Stopped -> ()
  | Running ->
    let source=Atomic.get operation.source in
    match R.cancellation_state source,R.launch_state source with
    | R.Cancellation_requested,R.Not_requested -> ignore (enqueue operation Cancellation)
    | R.Cancellation_requested,R.Requested _ | R.No_cancellation,_ -> ()

let make_operation controller record =
  let execution=match R.launch_state record with
    | R.Not_requested -> Awaiting_activation
    | R.Requested _ -> Unknown_launch
  in
  let operation={
    controller;
    source=Atomic.make record;
    execution=Atomic.make execution;
    result=Atomic.make (completion ());
    active=Atomic.make None;
    pending_activation=Atomic.make None;
    pending_cancellation=Atomic.make None;
    queue=Eio.Mutex.create ();
    changed=Eio.Condition.create ();
    actor=Atomic.make Running;
  } in
  (match execution with
   | Owned _ | Awaiting_activation -> ()
   | Unknown_launch -> finish (current_result operation) (Error Launch_unknown));
  operation

let bind_record controller record =
  let binding=R.binding record in
  let key=P.Id.to_string binding.P.operation_id in
  let operation,is_new=Eio.Mutex.use_rw ~protect:false controller.operations_lock (fun () ->
    match Hashtbl.find_opt controller.operations key with
    | Some operation -> operation,false
    | None ->
        let operation=make_operation controller record in
        Hashtbl.add controller.operations key operation;
        operation,true) in
  let original=Atomic.get operation.source in
  if R.binding original<>binding then Error Binding_mismatch
  else if R.admission_id original<>R.admission_id record then Error Admission_mismatch
  else (
    update_source operation record;
    if is_new then start_operation operation;
    reconcile_if_cancelled operation;
    Ok operation)

let admission_key binding = P.Id.to_string binding.P.operation_id

let remove_admission controller key pending =
  Eio.Cancel.protect (fun () ->
    Eio.Mutex.use_rw ~protect:false controller.operations_lock (fun () ->
      match Hashtbl.find_opt controller.admissions key with
      | Some current when current==pending -> Hashtbl.remove controller.admissions key
      | Some _ | None -> ()))

let finish_admission controller key pending outcome =
  finish pending.completion outcome;
  remove_admission controller key pending

let run_admission controller key pending =
  let work () =
    let* record=R.admit controller.registry ~new_admission_id:(controller.new_id ())
      ~binding:pending.binding ~spec:pending.spec |> Result.map_error (fun error -> Registry_error error) in
    bind_record controller record
  in
  match work () with
  | outcome -> finish_admission controller key pending outcome;outcome
  | exception ex ->
      let bt=Printexc.get_raw_backtrace () in
      finish_admission controller key pending (Error (Controller_failed ex));
      Printexc.raise_with_backtrace ex bt

let validate_admission binding spec operation =
  let source=Atomic.get operation.source in
  if R.binding source<>binding || R.specification source<>spec then Error Binding_mismatch
  else Ok operation

let validate_lookup original operation =
  let source=Atomic.get operation.source in
  if R.binding source<>original.P.binding then Error Binding_mismatch
  else if R.admission_id source<>original.P.admission_id then Error Admission_mismatch
  else Ok operation

let create_with_hook ~before_request ~sw ~fs ~registry ~cgroup_parent_path ~new_id ~resolve_execution =
  Eio.Switch.check sw;
  {sw;fs;cgroup_parent_path;registry;new_id;resolve_execution;before_request;operations=Hashtbl.create 32;
   admissions=Hashtbl.create 32;operations_lock=Eio.Mutex.create ()}

let create = create_with_hook ~before_request:(fun () -> ())

let admit controller ~binding ~spec =
  let key=admission_key binding in
  let reserved=Eio.Mutex.use_rw ~protect:false controller.operations_lock (fun () ->
    match Hashtbl.find_opt controller.admissions key with
    | Some pending when pending.binding=binding && pending.spec=spec -> `Join pending.completion
    | Some _ -> `Conflict
    | None ->
        let pending={binding;spec;completion=completion ()} in
        Hashtbl.add controller.admissions key pending;
        `Run pending) in
  let* operation=match reserved with
    | `Conflict -> Error Binding_mismatch
    | `Join pending -> Eio.Promise.await pending.value
    | `Run pending -> run_admission controller key pending
  in
  validate_admission binding spec operation

let lookup controller original =
  let binding=original.P.binding in
  let key=admission_key binding in
  let pending=Eio.Mutex.use_ro controller.operations_lock (fun () ->
    Hashtbl.find_opt controller.admissions key) in
  match pending with
  | Some pending when pending.binding<>binding -> Error Binding_mismatch
  | Some pending ->
      let* operation=Eio.Promise.await pending.completion.value in
      validate_lookup original operation
  | None ->
      let* record=R.load controller.registry ~binding |> Result.map_error (fun error -> Registry_error error) in
      if R.binding record<>binding then Error Binding_mismatch
      else if R.admission_id record<>original.P.admission_id then Error Admission_mismatch
      else bind_record controller record

let original operation =
  let source=Atomic.get operation.source in
  P.original ~binding:(R.binding source) ~admission_id:(R.admission_id source)

let inspect_original operation = refresh operation
let activate operation = enqueue operation Activation
let cancel operation = enqueue operation Cancellation
let await_request (request : request) = Eio.Promise.await request.completion.value

let await_result operation =
  match Atomic.get operation.execution with
  | Unknown_launch -> Error Launch_unknown
  | Owned job -> C.await_result job |> Result.map_error map_lifetime_error
  | Awaiting_activation -> Eio.Promise.await (current_result operation).value

let load_result ~sw ~expected_sha256 operation =
  let* expected=match Atomic.get operation.execution with
    | Unknown_launch -> Ok expected_sha256
    | Owned _ | Awaiting_activation ->
      let* digest=await_result operation in
      (match expected_sha256 with
       | Some expected when expected<>digest -> Error Result_digest_mismatch
       | Some _ | None -> Ok (Some digest))
  in
  let* storage=R.open_storage ~sw (Atomic.get operation.source)
    |> Result.map_error (fun error -> Registry_error error) in
  D.load ~sw ~storage ~expected_sha256:expected |> Result.map_error (fun error -> Result_error error)

module For_testing = struct
  let create = create_with_hook
end
