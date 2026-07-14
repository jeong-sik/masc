module Core = Capability_recovery_obligation

type registry = Core.registry

type access_error = Keeper_lane_not_available

type lane_open_error =
  | Invalid_owner of Core.validation_error
  | Store_failed of Core.transition_error

type invariant_violation =
  | Borrow_count_underflow
  | Borrow_count_overflow
  | Closing_without_active_borrows
  | Closed_with_active_borrows of int
  | Closed_without_drain_signal
  | Drain_signal_already_resolved

exception Invariant_violation of invariant_violation

type phase =
  | Open
  | Closing
  | Closed

type t =
  { store : Core.store
  ; mutex : Eio.Mutex.t
  ; mutable phase : phase
  ; mutable in_flight : int
  ; drained : unit Eio.Promise.t
  ; resolve_drained : unit Eio.Promise.u
  }

type 'a outcome =
  | Returned of 'a
  | Raised of Eio.Exn.with_bt

type borrow_decision =
  | Borrowed of Core.store
  | Borrow_rejected
  | Borrow_invariant of invariant_violation

type release_decision =
  | Released
  | Release_and_signal
  | Release_invariant of invariant_violation

type close_decision =
  | Close_and_signal
  | Await_drain
  | Already_drained
  | Close_invariant of invariant_violation

let access_error_to_string = function
  | Keeper_lane_not_available ->
    "keeper lane publication recovery store is not available"
;;

let validation_error_to_string = Core.validation_error_to_string
let transition_error_to_string = Core.transition_error_to_string

let lane_open_error_to_string = function
  | Invalid_owner error -> Core.validation_error_to_string error
  | Store_failed error -> Core.transition_error_to_string error
;;

let open_registry = Core.open_registry

let create store =
  let drained, resolve_drained = Eio.Promise.create () in
  { store
  ; mutex = Eio.Mutex.create ()
  ; phase = Open
  ; in_flight = 0
  ; drained
  ; resolve_drained
  }
;;

let capture f =
  match f () with
  | value -> Returned value
  | exception exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Raised (exception_, backtrace)
;;

let raise_with_backtrace (exception_, backtrace) =
  Printexc.raise_with_backtrace exception_ backtrace
;;

let raise_combined primary cleanup =
  Eio.Exn.combine primary cleanup |> raise_with_backtrace
;;

let run_with_cleanup ~cleanup body =
  let body_outcome = capture body in
  let cleanup_outcome =
    Eio.Cancel.protect (fun () -> capture cleanup)
  in
  match body_outcome, cleanup_outcome with
  | Returned value, Returned () ->
    Eio.Fiber.check ();
    value
  | Raised primary, Returned () -> raise_with_backtrace primary
  | Returned _, Raised cleanup -> raise_with_backtrace cleanup
  | Raised primary, Raised cleanup -> raise_combined primary cleanup
;;

let signal_drained t =
  if not (Eio.Promise.try_resolve t.resolve_drained ())
  then raise (Invariant_violation Drain_signal_already_resolved)
;;

let borrow t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    match t.phase with
    | Open when t.in_flight = max_int ->
      Borrow_invariant Borrow_count_overflow
    | Open ->
      t.in_flight <- t.in_flight + 1;
      Borrowed t.store
    | Closing when t.in_flight <= 0 ->
      Borrow_invariant Closing_without_active_borrows
    | Closing -> Borrow_rejected
    | Closed when t.in_flight <> 0 ->
      Borrow_invariant (Closed_with_active_borrows t.in_flight)
    | Closed -> Borrow_rejected)
;;

let release t =
  let decision =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      if t.in_flight <= 0
      then Release_invariant Borrow_count_underflow
      else
        match t.phase with
        | Open ->
          t.in_flight <- t.in_flight - 1;
          Released
        | Closing ->
          t.in_flight <- t.in_flight - 1;
          if t.in_flight = 0
          then (
            t.phase <- Closed;
            Release_and_signal)
          else Released
        | Closed ->
          Release_invariant
            (Closed_with_active_borrows t.in_flight))
  in
  match decision with
  | Released -> ()
  | Release_and_signal -> signal_drained t
  | Release_invariant invariant -> raise (Invariant_violation invariant)
;;

let close_and_drain t =
  let decision =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match t.phase with
      | Open when t.in_flight < 0 ->
        Close_invariant Borrow_count_underflow
      | Open when t.in_flight = 0 ->
        t.phase <- Closed;
        Close_and_signal
      | Open ->
        t.phase <- Closing;
        Await_drain
      | Closing when t.in_flight <= 0 ->
        Close_invariant Closing_without_active_borrows
      | Closing -> Await_drain
      | Closed when t.in_flight <> 0 ->
        Close_invariant (Closed_with_active_borrows t.in_flight)
      | Closed -> Already_drained)
  in
  match decision with
  | Close_and_signal -> signal_drained t
  | Await_drain -> Eio.Promise.await t.drained
  | Already_drained ->
    (match Eio.Promise.peek t.drained with
     | Some () -> ()
     | None -> raise (Invariant_violation Closed_without_drain_signal))
  | Close_invariant invariant -> raise (Invariant_violation invariant)
;;

let with_store t f =
  match borrow t with
  | Borrow_rejected ->
    Eio.Fiber.check ();
    Error Keeper_lane_not_available
  | Borrow_invariant invariant -> raise (Invariant_violation invariant)
  | Borrowed store ->
    run_with_cleanup
      ~cleanup:(fun () -> release t)
      (fun () ->
         Eio.Fiber.check ();
         Ok (f store))
;;

let with_lane ~registry ~owner f =
  match Core.owner_of_string owner with
  | Error error -> Error (Invalid_owner error)
  | Ok owner ->
    (match
       Core.with_store ~registry ~owner (fun store ->
         let access = create store in
         run_with_cleanup
           ~cleanup:(fun () -> close_and_drain access)
           (fun () -> f access))
     with
     | Ok value -> Ok value
     | Error error -> Error (Store_failed error))
;;
