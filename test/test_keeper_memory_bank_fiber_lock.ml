open Masc

module Selection = Keeper_memory_bank_selection

exception Body_failure

let test_same_domain_eio_fibers_serialize () =
  Eio_main.run @@ fun _env ->
  let holder_entered_p, holder_entered_r = Eio.Promise.create () in
  let release_holder_p, release_holder_r = Eio.Promise.create () in
  let waiter_entered_p, waiter_entered_r = Eio.Promise.create () in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
    Selection.with_memory_bank_lock "same-path" (fun () ->
      Eio.Promise.resolve holder_entered_r ();
      Eio.Promise.await release_holder_p));
  Eio.Promise.await holder_entered_p;
  Eio.Fiber.fork ~sw (fun () ->
    Selection.with_memory_bank_lock "same-path" (fun () ->
      Eio.Promise.resolve waiter_entered_r ()));
  Eio.Fiber.yield ();
  Alcotest.(check bool)
    "waiter remains outside while holder yields"
    false
    (Eio.Promise.is_resolved waiter_entered_p);
  Eio.Promise.resolve release_holder_r ();
  Eio.Promise.await waiter_entered_p
;;

let test_domain_holder_cancelled_waiter_releases_gate () =
  Eio_main.run @@ fun _env ->
  let holder_entered = Atomic.make false in
  let release_holder = Atomic.make false in
  let waiter_entered = Atomic.make false in
  let holder =
    Domain.spawn (fun () ->
      Selection.with_memory_bank_lock "cross-context-path" (fun () ->
        Atomic.set holder_entered true;
        while not (Atomic.get release_holder) do
          Domain.cpu_relax ()
        done))
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set release_holder true;
      Domain.join holder)
    (fun () ->
      while not (Atomic.get holder_entered) do
        Eio.Fiber.yield ()
      done;
      let waiter_started = Atomic.make false in
      let outcome =
        Eio.Fiber.first
          (fun () ->
             Atomic.set waiter_started true;
             Selection.with_memory_bank_lock "cross-context-path" (fun () ->
               Atomic.set waiter_entered true);
             `Entered)
          (fun () ->
             while not (Atomic.get waiter_started) do
               Eio.Fiber.yield ()
             done;
             `Cancelled)
      in
      Alcotest.(check bool)
        "contended waiter is cancelled before entry"
        true
        (outcome = `Cancelled && not (Atomic.get waiter_entered));
      Atomic.set release_holder true);
  let reacquired =
    Selection.with_memory_bank_lock "cross-context-path" (fun () -> "reacquired")
  in
  Alcotest.(check string)
    "cancelled waiter leaves no gate or system mutex ownership"
    "reacquired"
    reacquired
;;

let test_exception_preserves_synchronous_semantics_and_reacquires () =
  Eio_main.run @@ fun _env ->
  let raised =
    match
      Selection.with_memory_bank_lock "exception-path" (fun () ->
        raise Body_failure)
    with
    | _ -> false
    | exception Body_failure -> true
  in
  Alcotest.(check bool) "body exception propagates synchronously" true raised;
  let result =
    Selection.with_memory_bank_lock "exception-path" (fun () -> 42)
  in
  Alcotest.(check int) "Eio lock is reacquired after exception" 42 result
;;

let test_different_paths_are_independent () =
  Eio_main.run @@ fun _env ->
  let holder_entered_p, holder_entered_r = Eio.Promise.create () in
  let release_holder_p, release_holder_r = Eio.Promise.create () in
  let other_entered_p, other_entered_r = Eio.Promise.create () in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
    Selection.with_memory_bank_lock "path-a" (fun () ->
      Eio.Promise.resolve holder_entered_r ();
      Eio.Promise.await release_holder_p));
  Eio.Promise.await holder_entered_p;
  Eio.Fiber.fork ~sw (fun () ->
    Selection.with_memory_bank_lock "path-b" (fun () ->
      Eio.Promise.resolve other_entered_r ()));
  Eio.Promise.await other_entered_p;
  Alcotest.(check bool)
    "different path enters while first path remains held"
    false
    (Eio.Promise.is_resolved release_holder_p);
  Eio.Promise.resolve release_holder_r ()
;;

let () =
  Alcotest.run
    "keeper_memory_bank_fiber_lock"
    [ ( "cross-context"
      , [ Alcotest.test_case
            "same-domain Eio fibers serialize"
            `Quick
            test_same_domain_eio_fibers_serialize
        ; Alcotest.test_case
            "Domain holder and cancelled waiter do not leak"
            `Quick
            test_domain_holder_cancelled_waiter_releases_gate
        ; Alcotest.test_case
            "exception propagates and lock reacquires"
            `Quick
            test_exception_preserves_synchronous_semantics_and_reacquires
        ; Alcotest.test_case
            "different paths remain independent"
            `Quick
            test_different_paths_are_independent
        ] )
    ]
;;
