module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module L = Endpoint_job_launch
module S = Endpoint_job_supervisor
module D = Endpoint_job_result
let ( let* ) = Result.bind
type error =
  | Registry_error of R.error
  | Supervisor_error of S.error
  | Result_error of D.error
  | Owner_stopped
  | Job_failed of exn
let error_to_string = function
  | Registry_error e -> R.error_to_string e
  | Supervisor_error e -> S.error_to_string e
  | Result_error e -> D.error_to_string e
  | Owner_stopped -> "endpoint job lifetime stopped"
  | Job_failed e -> "endpoint job failed: " ^ Printexc.to_string e
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
type cancellation = (R.record,error) result completion
type t = {
  endpoint : Eio.Switch.t;
  source : R.record;
  startup : (S.launch_outcome,error) result completion;
  result : (P.Sha256.t,error) result completion;
  cancellation : cancellation option Atomic.t;
}
let original t=P.original ~binding:(R.binding t.source) ~admission_id:(R.admission_id t.source)
let await_result t=Eio.Promise.await t.result.value
let stop t error = finish t.startup (Error error);finish t.result (Error error)
let terminal_result ~sw intent = function
  | S.Not_performed {error=S.Registry_error R.Launch_cancelled;pipe_cleanup_errors=_} ->
    let* proof=R.retire_cancelled_launch ~sw intent |> Result.map_error (fun e -> Registry_error e) in
    let* result=D.publish_unlaunched ~sw ~proof |> Result.map_error (fun e -> Result_error e) in
    Ok (D.sha256 result)
  | S.Not_performed {error;pipe_cleanup_errors=_} -> Error (Supervisor_error error)
  | S.Performed {value=Error error;registry_release_error=_;pipe_cleanup_errors=_} ->
    Error (Supervisor_error error)
  | S.Performed {value=Ok owner;registry_release_error=_;pipe_cleanup_errors=_} ->
    let* receipt=S.await_result owner |> Result.map_error (fun e -> Supervisor_error e) in
    Ok receipt.sha256
let start_effect_workspace ~sw ~fs ~cgroup_parent_path ~execution intent =
  Eio.Switch.check sw;
  let t={endpoint=sw;source=R.launch_record intent;startup=completion ();result=completion ();
    cancellation=Atomic.make None} in
  Eio.Switch.on_release sw (fun () -> stop t Owner_stopped);
  Eio.Switch.check sw;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (try
      Eio.Fiber.yield ();
      Eio.Switch.run (fun job_sw ->
        let outcome=S.launch_effect_workspace ~sw:job_sw ~fs ~cgroup_parent_path ~execution intent in
        finish t.startup (Ok outcome);
        finish t.result (terminal_result ~sw:job_sw intent outcome);
        (* No control observer owns these resources. Release will require a
           separate digest-bound durable host-consumption capability. *)
        Eio.Fiber.await_cancel ())
     with
     | Eio.Cancel.Cancelled _ as ex ->
       let bt=Printexc.get_raw_backtrace () in stop t Owner_stopped;
       Printexc.raise_with_backtrace ex bt
     | ex -> stop t (Job_failed ex));
    `Stop_daemon);
  Eio.Switch.check sw;
  t
let load_result ~sw t =
  let* digest=await_result t in
  let* storage=R.open_storage ~sw t.source |> Result.map_error (fun e -> Registry_error e) in
  D.load ~sw ~storage ~expected_sha256:(Some digest) |> Result.map_error (fun e -> Result_error e)
let cancel_original t =
  let request ()=R.request_cancel t.source ~confirmed_admission_id:(R.admission_id t.source)
    |> Result.map_error (fun e -> Registry_error e) in
  let after_startup () =
    let* outcome=Eio.Promise.await t.startup.value in
    match outcome with
    | S.Performed {value=Ok owner;registry_release_error=_;pipe_cleanup_errors=_} ->
      S.cancel owner |> Result.map_error (fun e -> Supervisor_error e)
    | S.Not_performed _ -> request ()
    | S.Performed {value=Error error;registry_release_error=_;pipe_cleanup_errors=_} ->
      let* _=request () in Error (Supervisor_error error) in
  match request () with
  | Ok _ | Error (Registry_error R.Busy) -> after_startup ()
  | Error (Registry_error _ | Supervisor_error _ | Result_error _ | Owner_stopped | Job_failed _) as e -> e
let cancel t =
  Eio.Switch.check t.endpoint;
  let pending=completion () in
  let proposed=Some pending in
  let rec reserve () =
    match Atomic.get t.cancellation with
    | Some existing -> `Existing existing
    | None -> if Atomic.compare_and_set t.cancellation None proposed then `New else reserve () in
  let pending=match reserve () with
    | `Existing existing -> existing
    | `New ->
      let complete value =
        finish pending value;
        ignore (Atomic.compare_and_set t.cancellation proposed None) in
      (try
        let hook=Eio.Switch.on_release_cancellable t.endpoint (fun () -> complete (Error Owner_stopped)) in
        Eio.Switch.check t.endpoint;
        Eio.Fiber.fork_daemon ~sw:t.endpoint (fun () ->
          (match (Eio.Fiber.yield ();cancel_original t) with
           | value -> complete value
           | exception (Eio.Cancel.Cancelled _ as ex) ->
             let bt=Printexc.get_raw_backtrace () in complete (Error Owner_stopped);
             Eio.Switch.remove_hook hook;Printexc.raise_with_backtrace ex bt
           | exception ex -> complete (Error (Job_failed ex)));
          Eio.Switch.remove_hook hook;
          `Stop_daemon);
        Eio.Switch.check t.endpoint
       with ex ->
         let bt=Printexc.get_raw_backtrace () in complete (Error Owner_stopped);
         Printexc.raise_with_backtrace ex bt);
      pending in
  Eio.Promise.await pending.value
