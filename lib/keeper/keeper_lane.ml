type outcome =
  | Completed
  | Shutdown_requested
  | Cancelled_by_parent of exn
  | Failed of exn

type exit =
  { outcome : outcome
  ; cleanup_error : string option
  }

type state =
  | Not_started
  | Starting
  | Running of Eio.Switch.t
  | Cancellation_requested
  | Finalizing
  | Exited

exception Shutdown_cancel

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
  | Cancel_signal_failed of exn

let start_error_to_string = function
  | Already_started -> "lane already started"
  | Already_exited -> "lane already exited"
  | Fork_failed exn -> Printf.sprintf "lane fork failed: %s" (Printexc.to_string exn)
;;

let create () =
  let exited_p, exited_r = Eio.Promise.create () in
  { id = Id.generate (); state = Atomic.make Not_started; exited_p; exited_r }
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

let rec attach_scope t lane_sw =
  let current = Atomic.get t.state in
  match current with
  | Starting ->
    if Atomic.compare_and_set t.state current (Running lane_sw)
    then Scope_attached
    else attach_scope t lane_sw
  | Cancellation_requested -> Cancel_before_attach
  | Not_started | Running _ | Finalizing | Exited ->
    invalid_arg "Keeper_lane.attach_scope: invalid lane state"
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
        { outcome = Shutdown_requested; cleanup_error = None };
      Cancel_requested)
    else request_cancel t
  | Starting ->
    if Atomic.compare_and_set t.state current Cancellation_requested
    then Cancel_requested
    else request_cancel t
  | Running lane_sw ->
    if Atomic.compare_and_set t.state current Cancellation_requested
    then
      (try
         Eio.Switch.fail lane_sw Shutdown_cancel;
         Cancel_requested
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         let _ = Atomic.compare_and_set t.state Cancellation_requested current in
         Cancel_signal_failed exn)
    else request_cancel t
  | Cancellation_requested -> Cancel_already_requested
  | Finalizing | Exited -> Cancel_already_exiting
;;

let fork ~sw t ~run ~cleanup =
  match claim_start t with
  | Error _ as error -> error
  | Ok () ->
    let started = Atomic.make false in
    (try
       Eio.Fiber.fork ~sw (fun () ->
         Atomic.set started true;
         let outcome =
           try
             Eio.Switch.run (fun lane_sw ->
               match attach_scope t lane_sw with
               | Scope_attached -> run lane_sw
               | Cancel_before_attach ->
                 Eio.Switch.fail lane_sw Shutdown_cancel;
                 Eio.Switch.check lane_sw);
             Completed
           with
           | Shutdown_cancel -> Shutdown_requested
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
