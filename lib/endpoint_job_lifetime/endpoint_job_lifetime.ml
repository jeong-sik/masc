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
type original_error = Cancelled_original | Busy_original | Unavailable
let classify_original_error : R.error -> original_error = function
  | R.Launch_cancelled -> Cancelled_original
  | Busy -> Busy_original
  | Protection_refused _ | Authority_unavailable _ | Publication_failed _
  | Recovery_unavailable _ | Lock_failed _ | Commit_unconfirmed _
  | Binding_mismatch | Invalid_request _ | Execution_identity_changed
  | Endpoint_replaced | Missing_original | Admission_incomplete | Corrupt_original _
  | Launch_already_requested | Launch_intent_spent | Cancel_reconciliation_required | Stale_record | Cleanup_failed _
  | Unsupported_version _ -> Unavailable
let classify_startup_error : S.error -> original_error = function
  | S.Registry_error error -> classify_original_error error
  | Launch_error _ | Output_error _ | Pipe_unavailable | Pipe_cleanup_failed _
  | Registry_cleanup_failed _ | Interrupted | Supervisor_failed | Publication_failed _
  | Recovery_failed _ | Receipt_storage_unavailable | Result_encoding_failed _ -> Unavailable
(* A failed cleanup carries the error that ended the operation as its primary. *)
let rec cancel_needs_reconciliation : R.error -> bool = function
  | R.Cancel_reconciliation_required -> true
  | Cleanup_failed {primary=Some primary;cause=_} -> cancel_needs_reconciliation primary
  | Cleanup_failed {primary=None;cause=_} -> false
  | Protection_refused _ | Authority_unavailable _ | Publication_failed _
  | Recovery_unavailable _ | Lock_failed _ | Commit_unconfirmed _ | Busy
  | Binding_mismatch | Invalid_request _ | Execution_identity_changed
  | Endpoint_replaced | Missing_original | Admission_incomplete | Corrupt_original _
  | Launch_already_requested | Launch_cancelled | Launch_intent_spent | Stale_record
  | Unsupported_version _ -> false
let startup_needs_reconciliation : S.error -> bool = function
  | S.Registry_error error -> cancel_needs_reconciliation error
  | Launch_error _ | Output_error _ | Pipe_unavailable | Pipe_cleanup_failed _
  | Registry_cleanup_failed _ | Interrupted | Supervisor_failed | Publication_failed _
  | Recovery_failed _ | Receipt_storage_unavailable | Result_encoding_failed _ -> false
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
  intent : R.launch_intent;
  startup : (S.launch_outcome,error) result completion;
  result : (P.Sha256.t,error) result completion;
  cancellation : cancellation option Atomic.t;
  reconcile_cancel : bool Atomic.t;
}
let original t=P.original ~binding:(R.binding t.source) ~admission_id:(R.admission_id t.source)
let await_startup t=Eio.Promise.await t.startup.value
let await_result t=Eio.Promise.await t.result.value
let stop t error = finish t.startup (Error error);finish t.result (Error error)
(* A startup attempt can lose the registry to this job's own cancellation.
   Only that cancellation's completion is awaited; its outcome is not the
   job outcome, so the caller re-derives the result from the registry. *)
let settle_cancellation t = match Atomic.get t.cancellation with
  | Some pending -> ignore (Eio.Promise.await pending.value : (R.record,error) result); true
  | None -> false

let retire_unlaunched ~sw intent =
  let* proof=R.retire_cancelled_launch ~sw intent |> Result.map_error (fun e -> Registry_error e) in
  let* result=D.publish_unlaunched ~sw ~proof |> Result.map_error (fun e -> Result_error e) in
  Ok (D.sha256 result)

let terminal_result t ~sw intent = function
  | S.Not_performed {error;pipe_cleanup_errors=_} ->
    (match classify_startup_error error with
     | Cancelled_original -> retire_unlaunched ~sw intent
     | Busy_original ->
       if settle_cancellation t then retire_unlaunched ~sw intent
       else Error (Supervisor_error error)
     | Unavailable -> Error (Supervisor_error error))
  | S.Performed {value=Error error;registry_release_error=_;pipe_cleanup_errors=_} ->
    Error (Supervisor_error error)
  | S.Performed {value=Ok owner;registry_release_error=_;pipe_cleanup_errors=_} ->
    let* receipt=S.await_result owner |> Result.map_error (fun e -> Supervisor_error e) in
    Ok receipt.sha256
let start_effect_workspace ~sw ~fs ~cgroup_parent_path ~execution intent =
  Eio.Switch.check sw;
  let t={endpoint=sw;source=R.launch_record intent;intent;startup=completion ();result=completion ();
    cancellation=Atomic.make None;reconcile_cancel=Atomic.make false} in
  Eio.Switch.on_release sw (fun () -> stop t Owner_stopped);
  Eio.Switch.check sw;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (try
      Eio.Fiber.yield ();
      Eio.Switch.run (fun job_sw ->
        let outcome=S.launch_effect_workspace ~sw:job_sw ~fs ~cgroup_parent_path ~execution intent in
        let held=match outcome with
          | S.Not_performed {error;pipe_cleanup_errors=_} -> startup_needs_reconciliation error
          | S.Performed _ -> false in
        if held then Atomic.set t.reconcile_cancel true;
        finish t.startup (Ok outcome);
        if not held then finish t.result (terminal_result t ~sw:job_sw intent outcome);
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
  let request ()=R.request_cancel t.source ~confirmed_admission_id:(R.admission_id t.source) in
  let confirm ()=request () |> Result.map_error (fun e -> Registry_error e) in
  let after_startup () =
    let* outcome=Eio.Promise.await t.startup.value in
    match outcome with
    | S.Performed {value=Ok owner;registry_release_error=_;pipe_cleanup_errors=_} ->
      S.cancel owner |> Result.map_error (fun e -> Supervisor_error e)
    | S.Not_performed _ -> confirm ()
    | S.Performed {value=Error error;registry_release_error=_;pipe_cleanup_errors=_} ->
      let* _=confirm () in Error (Supervisor_error error) in
  match request () with
  | Ok _ -> after_startup ()
  | Error error -> (match classify_original_error error with
      | Busy_original -> after_startup ()
      | Cancelled_original | Unavailable -> Error (Registry_error error))
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
          (try
             let value=(Eio.Fiber.yield ();cancel_original t) in
             match value with
             | Ok _ when Atomic.get t.reconcile_cancel ->
               (match Eio.Switch.run (fun sw -> retire_unlaunched ~sw t.intent) with
                | Ok digest ->
                  Atomic.set t.reconcile_cancel false;
                  finish t.result (Ok digest);
                  complete value
                | Error error -> complete (Error error))
             | Ok _ | Error _ -> complete value
           with
           | Eio.Cancel.Cancelled _ as ex ->
             let bt=Printexc.get_raw_backtrace () in complete (Error Owner_stopped);
             Eio.Switch.remove_hook hook;Printexc.raise_with_backtrace ex bt
           | ex -> complete (Error (Job_failed ex)));
          Eio.Switch.remove_hook hook;
          `Stop_daemon);
        Eio.Switch.check t.endpoint
       with ex ->
         let bt=Printexc.get_raw_backtrace () in complete (Error Owner_stopped);
         Printexc.raise_with_backtrace ex bt);
      pending in
  Eio.Promise.await pending.value
