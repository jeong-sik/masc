type shutdown_cancel_failure =
  { cause : exn
  ; backtrace : Printexc.raw_backtrace
  }

type outcome =
  | Completed
  | Shutdown_before_start
  | Shutdown_requested
  | Shutdown_cancel_failed of shutdown_cancel_failure
  | Cancelled_by_parent of exn
  | Failed of exn

type exit =
  { outcome : outcome
  ; cleanup_error : string option
  }

type cancellation_control =
  { context : Eio.Cancel.t
  ; owner_domain : Domain.id
  }

type state =
  | Not_started
  | Starting
  | Running of cancellation_control
  | Cancellation_requested
  | Finalizing
  | Exited

exception Shutdown_cancel
exception Shutdown_cancel_failure of shutdown_cancel_failure

type cancellation_origin =
  | Shutdown_request
  | External_cancel of exn

let classify_cancellation_cause = function
  | Shutdown_cancel -> Shutdown_request
  | cause -> External_cancel cause
;;

module Id = struct
  type t = string

  let prefix = "lane-"
  (* NDT-OK: UUID entropy is identity only; lifecycle decisions compare the
     typed value and never branch on its random contents. *)
  let rng = Random.State.make_self_init () (* NDT-OK: identity entropy only *)
  let rng_mutex = Eio.Mutex.create ()

  let generate () =
    let uuid =
      Eio.Mutex.use_ro rng_mutex (fun () -> Uuidm.v4_gen rng ())
    in
    prefix ^ Uuidm.to_string uuid
  ;;

  let of_string value =
    let prefix_length = String.length prefix in
    if
      String.length value = prefix_length + 36
      && String.equal (String.sub value 0 prefix_length) prefix
    then
      match Uuidm.of_string (String.sub value prefix_length 36) with
      | Some _ -> Ok value
      | None -> Error (Printf.sprintf "invalid Keeper lane id: %S" value)
    else Error (Printf.sprintf "invalid Keeper lane id: %S" value)
  ;;

  let to_string value = value
  let equal = String.equal
end

type t =
  { id : Id.t
  ; state : state Atomic.t
  ; exited_p : exit Eio.Promise.t
  ; exited_r : exit Eio.Promise.u
  }

type start_error =
  | Already_started
  | Already_exited
  | Fork_failed of exn

type cancel_result =
  | Cancel_requested
  | Cancel_already_requested
  | Cancel_already_exiting
  | Cancel_wrong_domain
  | Cancel_not_committed of exn
  | Cancel_committed_with_failure of exn

let start_error_to_string = function
  | Already_started -> "lane already started"
  | Already_exited -> "lane already exited"
  | Fork_failed exn -> Printf.sprintf "lane fork failed: %s" (Printexc.to_string exn)
;;

let create () =
  let exited_p, exited_r = Eio.Promise.create () in
  { id = Id.generate ()
  ; state = Atomic.make Not_started
  ; exited_p
  ; exited_r
  }
;;

let id t = t.id
let exited t = t.exited_p
let peek_exit t = Eio.Promise.peek t.exited_p
let await_exit t = Eio.Promise.await t.exited_p

let rec claim_start t =
  if Atomic.compare_and_set t.state Not_started Starting
  then Ok ()
  else
    match Atomic.get t.state with
    | Not_started -> claim_start t
    | Starting | Running _ | Cancellation_requested -> Error Already_started
    | Finalizing | Exited -> Error Already_exited
;;

type attach_result =
  | Scope_attached
  | Cancel_before_attach

let rec attach_control t context =
  let current = Atomic.get t.state in
  match current with
  | Starting ->
    let control = { context; owner_domain = Domain.self () } in
    if Atomic.compare_and_set t.state current (Running control)
    then Scope_attached
    else attach_control t context
  | Cancellation_requested -> Cancel_before_attach
  | Not_started | Running _ | Finalizing | Exited ->
    invalid_arg "Keeper_lane.attach_control: invalid lane state"
;;

let cleanup_result cleanup outcome =
  Eio.Cancel.protect (fun () ->
    try
      match cleanup outcome with
      | Ok () -> None
      | Error detail -> Some detail
    with
    | exn -> Some (Printexc.to_string exn))
;;

let rec claim_finalization t =
  let current = Atomic.get t.state in
  match current with
  | Starting | Running _ | Cancellation_requested ->
    if Atomic.compare_and_set t.state current Finalizing
    then true
    else claim_finalization t
  | Not_started | Finalizing | Exited -> false
;;

let resolve_exit_once t outcome cleanup =
  if claim_finalization t
  then (
    let cleanup_error = cleanup_result cleanup outcome in
    Atomic.set t.state Exited;
    Eio.Promise.resolve t.exited_r { outcome; cleanup_error };
    true)
  else false
;;

let resolve_exit_without_cleanup t outcome =
  if claim_finalization t
  then (
    Atomic.set t.state Exited;
    Eio.Promise.resolve t.exited_r { outcome; cleanup_error = None };
    true)
  else false
;;

let rec request_cancel t =
  let current = Atomic.get t.state in
  match current with
  | Not_started ->
    if Atomic.compare_and_set t.state current Finalizing
    then (
      Atomic.set t.state Exited;
      Eio.Promise.resolve
        t.exited_r
        { outcome = Shutdown_before_start; cleanup_error = None };
      Cancel_requested)
    else request_cancel t
  | Starting ->
    if Atomic.compare_and_set t.state current Cancellation_requested
    then Cancel_requested
    else request_cancel t
  | Running control ->
    if Domain.self () <> control.owner_domain
    then Cancel_wrong_domain
    else
      (match Eio.Cancel.get_error control.context with
       | Some _ -> Cancel_already_exiting
       | None ->
         if Atomic.compare_and_set t.state current Cancellation_requested
         then
           (try
              Eio.Cancel.cancel control.context Shutdown_cancel;
              Cancel_requested
            with
            | exn ->
              (match Eio.Cancel.get_error control.context with
               | Some (Eio.Cancel.Cancelled _) -> Cancel_committed_with_failure exn
               | None ->
                 let _ =
                   Atomic.compare_and_set
                     t.state
                     Cancellation_requested
                     (Running control)
                 in
                 Cancel_not_committed exn
               | Some _ -> Cancel_not_committed exn))
         else request_cancel t)
  | Cancellation_requested -> Cancel_already_requested
  | Finalizing | Exited -> Cancel_already_exiting
;;

let fork ~sw t ~with_run_scope ~run ~cleanup =
  match claim_start t with
  | Error _ as error -> error
  | Ok () ->
    let started = Atomic.make false in
    (try
       Eio.Fiber.fork ~sw (fun () ->
         Atomic.set started true;
         let outcome =
           try
             (* Attach a cancellation scope before [with_run_scope] can wait
                for an external readiness promise. The actual lane switch is
                nested inside the run scope so every lane child still joins
                before that scope releases its resources. *)
             Eio.Cancel.sub (fun control ->
               try
                 match attach_control t control with
                 | Cancel_before_attach ->
                   Eio.Cancel.cancel control Shutdown_cancel;
                   Eio.Cancel.check control
                 | Scope_attached ->
                   Eio.Cancel.check control;
                   with_run_scope (fun () ->
                     Eio.Switch.run (fun lane_sw -> run lane_sw));
                   Eio.Cancel.check control
               with
               | exn ->
                 let backtrace = Printexc.get_raw_backtrace () in
                 (match Eio.Cancel.get_error control, exn with
                  | ( Some (Eio.Cancel.Cancelled Shutdown_cancel)
                    , Eio.Cancel.Cancelled Shutdown_cancel ) ->
                    Printexc.raise_with_backtrace exn backtrace
                  | Some (Eio.Cancel.Cancelled Shutdown_cancel), exn ->
                    let cause =
                      match exn with
                      | Eio.Cancel.Cancelled cause -> cause
                      | exn -> exn
                    in
                    Printexc.raise_with_backtrace
                      (Shutdown_cancel_failure { cause; backtrace })
                      backtrace
                  | (Some _ | None), exn ->
                    Printexc.raise_with_backtrace exn backtrace));
             Completed
           with
           | Shutdown_cancel_failure failure -> Shutdown_cancel_failed failure
           | Eio.Cancel.Cancelled Shutdown_cancel -> Shutdown_requested
           | Eio.Cancel.Cancelled cause -> Cancelled_by_parent cause
           | exn -> Failed exn
         in
         match resolve_exit_once t outcome cleanup with
         | true -> ()
         | false ->
           (* A concurrent rejected-fork path already settled the same lane. *)
           ());
       if Atomic.get started
       then Ok ()
       else
         match Eio.Switch.get_error sw with
         | None ->
           (* [Fiber.fork] accepted the child. It may not have been scheduled
              yet, but Eio only drops the fork when the target switch is
              already cancelling. *)
           Ok ()
         | Some cause ->
           let outcome = Cancelled_by_parent cause in
           if resolve_exit_once t outcome cleanup
           then Error (Fork_failed cause)
           else Ok ()
     with
     | exn ->
       let outcome = Failed exn in
       (match resolve_exit_once t outcome cleanup with
        | true -> ()
        | false ->
          (* The child won the exact-once settlement race before fork raised. *)
          ());
       Error (Fork_failed exn))
;;

let reject_before_start t ~reason =
  match claim_start t with
  | Error _ as error -> error
  | Ok () ->
    if resolve_exit_without_cleanup t (Failed reason)
    then Ok ()
    else Error Already_exited
;;
