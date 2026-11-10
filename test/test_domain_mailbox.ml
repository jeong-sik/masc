(* Domain_mailbox: operations cross from other domains to one fiber in order,
   and the end of the mailbox loses none (RFC
   http-transport-runs-on-its-own-domain §3.3). Every case sends from real
   domains: a second sender on the serving domain could not take the
   interleavings the gate exists for. *)

let with_domains f = Eio_main.run (fun env -> f (Eio.Stdenv.domain_mgr env))

let test_order () =
  with_domains (fun domain_mgr ->
    let count = 100_000 in
    let box = Domain_mailbox.create () in
    let next = ref 0 in
    Eio.Fiber.both
      (fun () ->
         Domain_mailbox.serve
           box
           ~handle:(fun i ->
             Alcotest.(check int) "taken in the order sent" !next i;
             incr next;
             if i = count - 1 then `Finished else `Continue)
           ~unhandled:(fun i -> Alcotest.failf "operation %d was left unhandled" i))
      (fun () ->
         Eio.Domain_manager.run domain_mgr (fun () ->
           for i = 0 to count - 1 do
             if not (Domain_mailbox.send box i) then Alcotest.failf "send %d refused" i
           done));
    Alcotest.(check int) "all handled" count !next;
    Alcotest.(check bool) "a send after the end is refused" false (Domain_mailbox.send box 0))
;;

(* Three domains send while the serving fiber finishes after a few
   operations. Each operation is counted where it ended up; none may be
   counted twice or not at all. Without the gate in [send] an operation
   queued after the drain is counted nowhere (seen on 2026-11-10 in each of
   three runs of this case, within 1,400 rounds). *)
let test_the_end_loses_no_operation () =
  with_domains (fun domain_mgr ->
    let rounds = 2_000
    and senders = 3
    and per_sender = 40 in
    let unhandled_total = ref 0 in
    for round = 1 to rounds do
      let box = Domain_mailbox.create () in
      let seen = Array.init (senders * per_sender) (fun _ -> Atomic.make 0) in
      let handled = ref 0 in
      let stop_after = 1 + (round mod 50) in
      Eio.Fiber.all
        ((fun () ->
           Domain_mailbox.serve
             box
             ~handle:(fun i ->
               Atomic.incr seen.(i);
               incr handled;
               if !handled >= stop_after then `Finished else `Continue)
             ~unhandled:(fun i ->
               Atomic.incr seen.(i);
               incr unhandled_total))
         :: List.init senders (fun sender () ->
           Eio.Domain_manager.run domain_mgr (fun () ->
             for k = 0 to per_sender - 1 do
               let i = (sender * per_sender) + k in
               if not (Domain_mailbox.send box i) then Atomic.incr seen.(i)
             done)));
      Array.iteri
        (fun i count ->
           if Atomic.get count <> 1
           then
             Alcotest.failf
               "round %d: operation %d ended up in %d places"
               round
               i
               (Atomic.get count))
        seen
    done;
    Alcotest.(check bool) "some operations were left unhandled" true (!unhandled_total > 0))
;;

let test_cancellation_ends_the_mailbox () =
  with_domains (fun domain_mgr ->
    for _ = 1 to 200 do
      let box = Domain_mailbox.create () in
      let handled = ref 0
      and unhandled = ref 0 in
      let accepted = Atomic.make 0 in
      (try
         Eio.Switch.run (fun sw ->
           Eio.Fiber.fork ~sw (fun () ->
             Domain_mailbox.serve
               box
               ~handle:(fun () ->
                 incr handled;
                 `Continue)
               ~unhandled:(fun () -> incr unhandled));
           Eio.Fiber.fork ~sw (fun () ->
             Eio.Domain_manager.run domain_mgr (fun () ->
               for _ = 1 to 200 do
                 if Domain_mailbox.send box () then Atomic.incr accepted
               done));
           Eio.Fiber.yield ();
           Eio.Switch.fail sw Exit)
       with
       | Exit -> ());
      Alcotest.(check int)
        "every accepted operation was handled or left unhandled"
        (Atomic.get accepted)
        (!handled + !unhandled);
      Alcotest.(check bool) "a send after the end is refused" false (Domain_mailbox.send box ())
    done)
;;

let test_a_raising_handler_ends_the_mailbox () =
  with_domains (fun (_ : _ Eio.Domain_manager.t) ->
    let box = Domain_mailbox.create () in
    List.iter (fun i -> ignore (Domain_mailbox.send box i : bool)) [ 1; 2; 3; 4 ];
    let unhandled = ref [] in
    (match
       Domain_mailbox.serve
         box
         ~handle:(fun i -> if i = 2 then failwith "boom" else `Continue)
         ~unhandled:(fun i -> unhandled := i :: !unhandled)
     with
     | () -> Alcotest.fail "serve returned"
     | exception Failure _ -> ());
    Alcotest.(check (list int))
      "the operation in hand, then the queued ones"
      [ 2; 3; 4 ]
      (List.rev !unhandled);
    Alcotest.(check bool) "a send after the end is refused" false (Domain_mailbox.send box 5))
;;

let () =
  Alcotest.run
    "domain_mailbox"
    [ ( "mailbox"
      , [ Alcotest.test_case "operations arrive in order" `Quick test_order
        ; Alcotest.test_case "the end loses no operation" `Quick test_the_end_loses_no_operation
        ; Alcotest.test_case "cancellation ends the mailbox" `Quick test_cancellation_ends_the_mailbox
        ; Alcotest.test_case "a raising handler ends the mailbox" `Quick
            test_a_raising_handler_ends_the_mailbox
        ] )
    ]
;;
