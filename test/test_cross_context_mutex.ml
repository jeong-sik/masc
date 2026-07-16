module Lock = Cross_context_mutex

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
        ] )
    ]
;;
