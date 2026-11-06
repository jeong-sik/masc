(** Lease on the recovery store of one lane. [create] wraps the store,
    [borrow] and [release] count the borrows in flight, [close_and_drain]
    rejects new borrows and waits until the borrows in flight have been
    released, and [with_store] lends the store to a callback and releases it
    afterwards. [run_with_cleanup] runs a body and then a cleanup that
    cancellation does not interrupt, and raises the failures of either.

    This module is private to [fs_compat_internal] and has no interface file.
    [Publication_recovery_access] includes it. *)

open Publication_recovery_access_model

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

let run_with_cleanup ~cleanup body =
  let body_outcome = capture body in
  let cleanup_outcome =
    Eio.Cancel.protect (fun () -> capture cleanup)
  in
  let parent_outcome = capture Eio.Fiber.check in
  let body_cancellation, body_failure =
    match body_outcome with
    | Raised (((Eio.Cancel.Cancelled _) as exception_), backtrace) ->
      Some (exception_, backtrace), None
    | Raised failure -> None, Some failure
    | Returned _ -> None, None
  in
  let parent_cancellation =
    match parent_outcome with
    | Raised (((Eio.Cancel.Cancelled _) as exception_), backtrace) ->
      Some (exception_, backtrace)
    | Returned () -> None
    | Raised failure -> raise_with_backtrace failure
  in
  let cancellation =
    match body_cancellation with
    | Some _ as cancellation -> cancellation
    | None -> parent_cancellation
  in
  match cleanup_outcome, cancellation, body_failure, body_outcome with
  | Raised cleanup, Some ((_, cancellation_backtrace) as cancellation), _, _ ->
    Printexc.raise_with_backtrace
      (Eio.Cancel.Cancelled
         (Cleanup_failed { body = body_failure; cancellation = Some cancellation; cleanup }))
      cancellation_backtrace
  | Raised cleanup, None, body, _ ->
    Printexc.raise_with_backtrace
      (Cleanup_failed { body; cancellation = None; cleanup })
      (snd cleanup)
  | Returned (), Some ((_, cancellation_backtrace) as cancellation), Some body, _ ->
    Printexc.raise_with_backtrace
      (Eio.Cancel.Cancelled
         (Body_failed_during_cancellation { body; cancellation }))
      cancellation_backtrace
  | Returned (), Some cancellation, None, _ -> raise_with_backtrace cancellation
  | Returned (), None, Some body, _ -> raise_with_backtrace body
  | Returned (), None, None, Returned value -> value
  | Returned (), None, None, Raised _ ->
    raise (Invariant_violation Cleanup_body_outcome_lost)
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
