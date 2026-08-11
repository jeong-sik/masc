open Alcotest

module Lease = Masc.Keeper_external_resource_lease

let eio_test name fn =
  test_case name `Quick (fun () ->
    Eio_main.run @@ fun _env ->
    Eio.Switch.run fn)
;;

let test_same_resource_serializes sw =
  let first_entered, resolve_first_entered = Eio.Promise.create () in
  let release_first, resolve_release_first = Eio.Promise.create () in
  let second_attempting, resolve_second_attempting = Eio.Promise.create () in
  let second_entered, resolve_second_entered = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Lease.with_lease (Lease.File_path "/tmp/shared") (fun () ->
      Eio.Promise.resolve resolve_first_entered ();
      Eio.Promise.await release_first));
  Eio.Promise.await first_entered;
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Promise.resolve resolve_second_attempting ();
    Lease.with_lease (Lease.File_path "/tmp/shared") (fun () ->
      Eio.Promise.resolve resolve_second_entered ()));
  Eio.Promise.await second_attempting;
  Eio.Fiber.yield ();
  check bool
    "second holder waits"
    true
    (Option.is_none (Eio.Promise.peek second_entered));
  Eio.Promise.resolve resolve_release_first ();
  Eio.Promise.await second_entered
;;

let test_distinct_resources_overlap sw =
  let first_entered, resolve_first_entered = Eio.Promise.create () in
  let release_first, resolve_release_first = Eio.Promise.create () in
  let second_entered, resolve_second_entered = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Lease.with_lease (Lease.Host_cwd "/tmp/repo-a") (fun () ->
      Eio.Promise.resolve resolve_first_entered ();
      Eio.Promise.await release_first));
  Eio.Promise.await first_entered;
  Eio.Fiber.fork ~sw (fun () ->
    Lease.with_lease (Lease.Host_cwd "/tmp/repo-b") (fun () ->
      Eio.Promise.resolve resolve_second_entered ()));
  Eio.Promise.await second_entered;
  Eio.Promise.resolve resolve_release_first ()
;;

let test_resource_kinds_do_not_alias sw =
  let first_entered, resolve_first_entered = Eio.Promise.create () in
  let release_first, resolve_release_first = Eio.Promise.create () in
  let second_entered, resolve_second_entered = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Lease.with_lease (Lease.File_path "/tmp/same-bytes") (fun () ->
      Eio.Promise.resolve resolve_first_entered ();
      Eio.Promise.await release_first));
  Eio.Promise.await first_entered;
  Eio.Fiber.fork ~sw (fun () ->
    Lease.with_lease (Lease.Host_cwd "/tmp/same-bytes") (fun () ->
      Eio.Promise.resolve resolve_second_entered ()));
  Eio.Promise.await second_entered;
  Eio.Promise.resolve resolve_release_first ()
;;

let test_cancelled_holder_releases _sw =
  let entered, resolve_entered = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  (match
     Eio.Switch.run (fun child_sw ->
       Eio.Fiber.fork ~sw:child_sw (fun () ->
         Lease.with_lease (Lease.File_path "/tmp/cancelled") (fun () ->
           Eio.Promise.resolve resolve_entered ();
           Eio.Promise.await never));
       Eio.Promise.await entered;
       Eio.Switch.fail child_sw Exit)
   with
   | () -> fail "child switch unexpectedly completed"
   | exception Exit -> ());
  let reacquired = ref false in
  Lease.with_lease (Lease.File_path "/tmp/cancelled") (fun () ->
    reacquired := true);
  check bool "cancelled holder released lease" true !reacquired
;;

let test_cancelled_holder_unblocks_waiter sw =
  let holder_entered, resolve_holder_entered = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  let waiter_attempting, resolve_waiter_attempting = Eio.Promise.create () in
  let waiter_result, resolve_waiter_result = Eio.Promise.create () in
  (match
     Eio.Switch.run (fun holder_sw ->
       Eio.Fiber.fork ~sw:holder_sw (fun () ->
         Lease.with_lease (Lease.File_path "/tmp/cancelled-with-waiter") (fun () ->
           Eio.Promise.resolve resolve_holder_entered ();
           Eio.Promise.await never));
       Eio.Promise.await holder_entered;
       Eio.Fiber.fork ~sw (fun () ->
         Eio.Promise.resolve resolve_waiter_attempting ();
         let result =
           try
             Lease.with_lease
               (Lease.File_path "/tmp/cancelled-with-waiter")
               (fun () -> Ok ())
           with
           | exn -> Error exn
         in
         Eio.Promise.resolve resolve_waiter_result result);
       Eio.Promise.await waiter_attempting;
       Eio.Fiber.yield ();
       check bool
         "waiter is blocked before cancellation"
         true
         (Option.is_none (Eio.Promise.peek waiter_result));
       Eio.Switch.fail holder_sw Exit)
   with
   | () -> fail "holder switch unexpectedly completed"
   | exception Exit -> ());
  match Eio.Promise.await waiter_result with
  | Ok () -> ()
  | Error exn ->
    failf "waiting holder failed after cancellation: %s" (Printexc.to_string exn)
;;

let () =
  run
    "keeper_external_resource_lease"
    [ ( "lease"
      , [ eio_test "same resource serializes" test_same_resource_serializes
        ; eio_test "different resources overlap" test_distinct_resources_overlap
        ; eio_test "resource kinds do not alias" test_resource_kinds_do_not_alias
        ; eio_test "cancellation releases resource" test_cancelled_holder_releases
        ; eio_test
            "cancellation unblocks an existing waiter"
            test_cancelled_holder_unblocks_waiter
        ] )
    ]
;;
