module Lock = Cross_context_mutex

type cancellation_outcome =
  | Returned
  | Cancelled
  | Raised of string

exception Requested_cancel

let rec await_atomic flag =
  if Atomic.get flag
  then ()
  else (
    Eio.Fiber.yield ();
    await_atomic flag)
;;

let await_atomic_in_domain flag =
  while not (Atomic.get flag) do
    Domain.cpu_relax ()
  done
;;

let test_eio_waiter_yields_until_owner_releases () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let lock = Lock.create () in
  let owner_entered, resolve_owner_entered = Eio.Promise.create () in
  let release_owner, resolve_release_owner = Eio.Promise.create () in
  let waiter_attempted = Atomic.make false in
  let waiter_entered = Atomic.make false in
  let waiter_done, resolve_waiter_done = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Lock.with_lock lock (fun () ->
      Eio.Promise.resolve resolve_owner_entered ();
      Eio.Promise.await release_owner));
  Eio.Promise.await owner_entered;
  Eio.Fiber.fork ~sw (fun () ->
    Atomic.set waiter_attempted true;
    Lock.with_lock lock (fun () -> Atomic.set waiter_entered true);
    Eio.Promise.resolve resolve_waiter_done ());
  await_atomic waiter_attempted;
  Eio.Fiber.yield ();
  Alcotest.(check bool) "same lock remains serialized" false (Atomic.get waiter_entered);
  Eio.Promise.resolve resolve_release_owner ();
  Eio.Promise.await waiter_done;
  Alcotest.(check bool) "waiter enters after release" true (Atomic.get waiter_entered)
;;

let test_domain_owner_and_eio_waiter_share_lock () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let lock = Lock.create () in
  let independent = Lock.create () in
  let owner_entered = Atomic.make false in
  let release_owner = Atomic.make false in
  let waiter_attempted = Atomic.make false in
  let waiter_entered = Atomic.make false in
  let holder =
    Domain.spawn (fun () ->
      Lock.with_lock lock (fun () ->
        Atomic.set owner_entered true;
        await_atomic_in_domain release_owner))
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set release_owner true;
      Domain.join holder)
    (fun () ->
       await_atomic owner_entered;
       let waiter_done, resolve_waiter_done = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         Atomic.set waiter_attempted true;
         Lock.with_lock lock (fun () -> Atomic.set waiter_entered true);
         Eio.Promise.resolve resolve_waiter_done ());
       await_atomic waiter_attempted;
       Eio.Fiber.yield ();
       Alcotest.(check bool)
         "Eio waiter does not re-lock Domain-owned mutex"
         false
         (Atomic.get waiter_entered);
       Lock.with_lock independent (fun () -> ());
       Atomic.set release_owner true;
       Eio.Promise.await waiter_done;
       Alcotest.(check bool) "waiter enters after Domain release" true
         (Atomic.get waiter_entered))
;;

let test_exception_does_not_poison_lock () =
  Eio_main.run @@ fun _env ->
  let lock = Lock.create () in
  (match Lock.with_lock lock (fun () -> raise Exit) with
   | _ -> Alcotest.fail "expected callback exception"
   | exception Exit -> ());
  Alcotest.(check int) "lock is reusable" 42 (Lock.with_lock lock (fun () -> 42))
;;

let test_durable_waiter_is_cancellable_before_acquisition () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let lock = Lock.create () in
  let owner_entered = Atomic.make false in
  let release_owner = Atomic.make false in
  let callback_entered = Atomic.make false in
  let holder =
    Domain.spawn (fun () ->
      Lock.with_lock lock (fun () ->
        Atomic.set owner_entered true;
        await_atomic_in_domain release_owner))
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set release_owner true;
      Domain.join holder)
    (fun () ->
       await_atomic owner_entered;
       let context, resolve_context = Eio.Promise.create () in
       let result, resolve_result = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         let outcome =
           try
             Eio.Cancel.sub (fun cancel_context ->
               Eio.Promise.resolve resolve_context cancel_context;
               Lock.with_durable_lock lock (fun () ->
                 Atomic.set callback_entered true);
               Returned)
           with
           | Eio.Cancel.Cancelled _ -> Cancelled
           | exn -> Raised (Printexc.to_string exn)
         in
         Eio.Promise.resolve resolve_result outcome);
       let cancel_context = Eio.Promise.await context in
       Eio.Cancel.cancel cancel_context Requested_cancel;
       (match Eio.Promise.await result with
        | Cancelled -> ()
        | Returned -> Alcotest.fail "cancelled waiter unexpectedly acquired the lock"
        | Raised detail -> Alcotest.failf "cancelled waiter raised: %s" detail);
       Alcotest.(check bool)
         "callback is not entered before acquisition"
         false
         (Atomic.get callback_entered);
       Atomic.set release_owner true;
       Alcotest.(check int)
         "lock remains reusable after cancelled waiter"
         7
         (Lock.with_lock lock (fun () -> 7)))
;;

let test_durable_callback_completes_before_cancellation_surfaces () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let lock = Lock.create () in
  let context, resolve_context = Eio.Promise.create () in
  let entered, resolve_entered = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let durable_result, resolve_durable_result = Eio.Promise.create () in
  let cancellation_result, resolve_cancellation_result = Eio.Promise.create () in
  let committed = Atomic.make false in
  Eio.Fiber.fork ~sw (fun () ->
    let cancellation_outcome =
      try
        Eio.Cancel.sub (fun cancel_context ->
          Eio.Promise.resolve resolve_context cancel_context;
          let durable_outcome =
            try
              Lock.with_durable_lock lock (fun () ->
                Eio.Promise.resolve resolve_entered ();
                Eio.Promise.await release;
                Atomic.set committed true);
              Returned
            with
            | Eio.Cancel.Cancelled _ -> Cancelled
            | exn -> Raised (Printexc.to_string exn)
          in
          Eio.Promise.resolve resolve_durable_result durable_outcome;
          match durable_outcome with
          | Returned ->
            Eio.Fiber.check ();
            Returned
          | Cancelled | Raised _ -> durable_outcome)
      with
      | Eio.Cancel.Cancelled _ -> Cancelled
      | exn -> Raised (Printexc.to_string exn)
    in
    Eio.Promise.resolve resolve_cancellation_result cancellation_outcome);
  let cancel_context = Eio.Promise.await context in
  Eio.Promise.await entered;
  Eio.Cancel.cancel cancel_context Requested_cancel;
  Eio.Fiber.yield ();
  Alcotest.(check bool)
    "durable callback remains active while cancellation is pending"
    false
    (Atomic.get committed);
  Eio.Promise.resolve resolve_release ();
  (match Eio.Promise.await durable_result with
   | Returned -> ()
   | Cancelled -> Alcotest.fail "durable lock hid its committed result"
   | Raised detail -> Alcotest.failf "durable callback raised: %s" detail);
  Alcotest.(check bool)
    "durable callback committed before returning"
    true
    (Atomic.get committed);
  (match Eio.Promise.await cancellation_result with
   | Cancelled -> ()
   | Returned -> Alcotest.fail "explicit cancellation check did not propagate"
   | Raised detail -> Alcotest.failf "cancellation check raised: %s" detail);
  Alcotest.(check int)
    "durable lock is reusable after cancellation"
    9
    (Lock.with_lock lock (fun () -> 9))
;;

let () =
  Alcotest.run
    "cross-context-mutex"
    [ ( "serialization"
      , [ Alcotest.test_case "Eio waiter yields" `Quick
            test_eio_waiter_yields_until_owner_releases
        ; Alcotest.test_case "Domain owner excludes Eio waiter" `Quick
            test_domain_owner_and_eio_waiter_share_lock
        ; Alcotest.test_case "callback exception releases lock" `Quick
            test_exception_does_not_poison_lock
        ; Alcotest.test_case "durable waiter acquisition is cancellable" `Quick
            test_durable_waiter_is_cancellable_before_acquisition
        ; Alcotest.test_case
            "durable callback completes before cancellation"
            `Quick
            test_durable_callback_completes_before_cancellation_surfaces
        ] )
    ]
;;
