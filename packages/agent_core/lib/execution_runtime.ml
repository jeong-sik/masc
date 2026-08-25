type create_error = Non_positive_domain_count of int

type stats =
  { pool_requested : int
  ; reentrant_inline : int
  ; caller_cancelled : int
  }

type run_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace option
  }

type t =
  { pool : Eio.Executor_pool.t
  ; observations : stats Atomic.t
  ; lifecycle : lifecycle Atomic.t
  }

and stop_reason =
  | Pending
  | Caller_cancelled
  | Runtime_released

and cancellation = { stop_reason : stop_reason Atomic.t }

and lifecycle =
  | Accepting of cancellation list
  | Released

type current_job =
  { runtime : t
  ; cancellation : cancellation
  }

exception Caller_cancelled
exception Runtime_released

type 'a worker_outcome =
  | Worker_completed of 'a
  | Worker_raised of run_failure

let current_job = Eio.Fiber.create_key ()

let rec update observation f =
  let current = Atomic.get observation in
  let next = f current in
  if not (Atomic.compare_and_set observation current next) then update observation f
;;

let signal cancellation reason =
  ignore (Atomic.compare_and_set cancellation.stop_reason Pending reason : bool)
;;

let rec register t cancellation =
  let current = Atomic.get t.lifecycle in
  match current with
  | Released -> false
  | Accepting active ->
    let next = Accepting (cancellation :: active) in
    if Atomic.compare_and_set t.lifecycle current next
    then true
    else register t cancellation
;;

let rec unregister t cancellation =
  let current = Atomic.get t.lifecycle in
  match current with
  | Released -> ()
  | Accepting active ->
    let next = Accepting (List.filter (fun item -> item != cancellation) active) in
    if not (Atomic.compare_and_set t.lifecycle current next)
    then unregister t cancellation
;;

let release t =
  match Atomic.exchange t.lifecycle Released with
  | Released -> ()
  | Accepting active ->
    List.iter (fun cancellation -> signal cancellation Runtime_released) active
;;

let create ~sw ~domain_mgr ~domain_count =
  if domain_count <= 0
  then Error (Non_positive_domain_count domain_count)
  else (
    let pool = Eio.Executor_pool.create ~sw ~domain_count domain_mgr in
    let t =
      { pool
      ; observations =
          Atomic.make { pool_requested = 0; reentrant_inline = 0; caller_cancelled = 0 }
      ; lifecycle = Atomic.make (Accepting [])
      }
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      try Eio.Fiber.await_cancel () with
      | Eio.Cancel.Cancelled _ ->
        release t;
        `Stop_daemon);
    Eio.Switch.on_release sw (fun () -> release t);
    Ok t)
;;

let create_error_to_string = function
  | Non_positive_domain_count domain_count ->
    Printf.sprintf
      "execution runtime domain_count must be positive, received %d"
      domain_count
;;

let pp_create_error formatter error =
  Format.pp_print_string formatter (create_error_to_string error)
;;

let stats t = Atomic.get t.observations

module Private = struct
  exception Caller_cancelled = Caller_cancelled
  exception Runtime_released = Runtime_released

  type nonrec run_failure = run_failure =
    { exception_ : exn
    ; backtrace : Printexc.raw_backtrace option
    }

  let capture ?backtrace exception_ = { exception_; backtrace }

  let reraise_caller_cancelled failure =
    match failure.exception_ with
    | Caller_cancelled as exn ->
      let backtrace =
        Option.value ~default:(Printexc.get_raw_backtrace ()) failure.backtrace
      in
      Printexc.raise_with_backtrace exn backtrace
    | _ -> ()
  ;;

  let check_cancellation t =
    (match Eio.Fiber.get current_job with
     | Some current when current.runtime == t ->
       (match Atomic.get current.cancellation.stop_reason with
        | Pending -> ()
        | Caller_cancelled -> raise_notrace Caller_cancelled
        | Runtime_released -> raise_notrace Runtime_released)
     | None | Some _ -> ());
    Eio.Fiber.check ()
  ;;

  let signal_caller_cancellation t cancellation exn backtrace =
    signal cancellation Caller_cancelled;
    update t.observations (fun stats ->
      { stats with caller_cancelled = stats.caller_cancelled + 1 });
    Printexc.raise_with_backtrace exn backtrace
  ;;

  let run_cpu t fn =
    match Eio.Fiber.get current_job with
    | Some current when current.runtime == t ->
      update t.observations (fun stats ->
        { stats with reentrant_inline = stats.reentrant_inline + 1 });
      (match fn () with
       | value -> Ok value
       | exception exn ->
         let backtrace = Printexc.get_raw_backtrace () in
         let failure = capture ~backtrace exn in
         reraise_caller_cancelled failure;
         Error failure)
    | None | Some _ ->
      update t.observations (fun stats ->
        { stats with pool_requested = stats.pool_requested + 1 });
      let cancellation = { stop_reason = Atomic.make Pending } in
      if not (register t cancellation)
      then Error (capture Runtime_released)
      else
        Fun.protect
          ~finally:(fun () -> unregister t cancellation)
          (fun () ->
             match
               Eio.Executor_pool.submit t.pool ~weight:1.0 (fun () ->
                 Eio.Fiber.with_binding
                   current_job
                   { runtime = t; cancellation }
                   (fun () ->
                      match fn () with
                      | value -> Worker_completed value
                      | exception exn ->
                        let backtrace = Printexc.get_raw_backtrace () in
                        Worker_raised (capture ~backtrace exn)))
             with
             | Ok (Worker_completed value) -> Ok value
             | Ok (Worker_raised failure) ->
               reraise_caller_cancelled failure;
               Error failure
             | Error exn -> Error (capture exn)
             | exception (Eio.Cancel.Cancelled _ as exn) ->
               let backtrace = Printexc.get_raw_backtrace () in
               signal_caller_cancellation t cancellation exn backtrace
             | exception exn ->
               let backtrace = Printexc.get_raw_backtrace () in
               Error (capture ~backtrace exn))
  ;;
end
