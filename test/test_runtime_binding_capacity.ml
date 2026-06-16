(** RFC-0153 §4.2.4: per-binding HTTP concurrency gate.

    Covers: ungated [None] runs free; [Some n] caps concurrent holders and a
    saturated key surfaces [`Slot_timeout]; a permit is released on normal return
    AND on exception (no leak); distinct keys are independent. *)

module Cap = Masc.Runtime_binding_capacity

(* [None] / [Some n <= 0] run the thunk directly with no semaphore. *)
let test_ungated () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let ran = ref false in
  let r =
    Cap.with_slot_result ~clock ~key:"ungated" ~max_concurrent:None (fun () ->
      ran := true;
      42)
  in
  Alcotest.(check bool) "thunk ran ungated" true !ran;
  (match r with
   | Ok v -> Alcotest.(check int) "ungated returns thunk value" 42 v
   | Error `Slot_timeout -> Alcotest.fail "ungated must not time out");
  (* Some 0 is also ungated. *)
  (match Cap.with_slot_result ~clock ~key:"ungated0" ~max_concurrent:(Some 0) (fun () -> 7) with
   | Ok v -> Alcotest.(check int) "Some 0 ungated returns value" 7 v
   | Error `Slot_timeout -> Alcotest.fail "Some 0 must be ungated")

(* [Some 1]: the second concurrent holder on the same key times out. *)
let test_cap_blocks_second () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let key = "cap-blocks" in
  let entered, resolve_entered = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let second = ref None in
  Eio.Fiber.fork ~sw (fun () ->
    ignore
      (Cap.with_slot_result ~clock ~wait_timeout_sec:5.0 ~key
         ~max_concurrent:(Some 1) (fun () ->
           Eio.Promise.resolve resolve_entered ();
           Eio.Promise.await release)));
  Eio.Promise.await entered;
  Eio.Fiber.fork ~sw (fun () ->
    second
    := Some
         (Cap.with_slot_result ~clock ~wait_timeout_sec:0.05 ~key
            ~max_concurrent:(Some 1) (fun () -> ())));
  Eio.Time.sleep clock 0.2;
  (match !second with
   | Some (Error `Slot_timeout) -> ()
   | Some (Ok ()) -> Alcotest.fail "second holder must not acquire while cap=1 is held"
   | None -> Alcotest.fail "second holder did not resolve");
  Eio.Promise.resolve resolve_release ()

(* A permit taken by a thunk that raises is still released (no leak): a later
   acquire on the same key succeeds. *)
let test_release_on_exception () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let key = "release-on-exn" in
  (match
     Cap.with_slot_result ~clock ~wait_timeout_sec:1.0 ~key ~max_concurrent:(Some 1)
       (fun () -> failwith "boom")
   with
   | exception Failure _ -> ()
   | _ -> Alcotest.fail "exception should propagate through with_slot_result");
  (* If the permit leaked, this acquire would time out. *)
  match
    Cap.with_slot_result ~clock ~wait_timeout_sec:0.5 ~key ~max_concurrent:(Some 1)
      (fun () -> "ok")
  with
  | Ok v -> Alcotest.(check string) "permit reusable after exception" "ok" v
  | Error `Slot_timeout ->
    Alcotest.fail "permit leaked: acquire timed out after a raising thunk"

(* Distinct keys do not contend: a held key-A does not block key-B. *)
let test_distinct_keys_independent () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let entered, resolve_entered = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let other = ref None in
  Eio.Fiber.fork ~sw (fun () ->
    ignore
      (Cap.with_slot_result ~clock ~wait_timeout_sec:5.0 ~key:"key-A"
         ~max_concurrent:(Some 1) (fun () ->
           Eio.Promise.resolve resolve_entered ();
           Eio.Promise.await release)));
  Eio.Promise.await entered;
  Eio.Fiber.fork ~sw (fun () ->
    other
    := Some
         (Cap.with_slot_result ~clock ~wait_timeout_sec:0.5 ~key:"key-B"
            ~max_concurrent:(Some 1) (fun () -> "B")));
  Eio.Time.sleep clock 0.2;
  (match !other with
   | Some (Ok "B") -> ()
   | Some (Ok _) -> Alcotest.fail "unexpected value for key-B"
   | Some (Error `Slot_timeout) ->
     Alcotest.fail "key-B blocked by an unrelated key-A holder"
   | None -> Alcotest.fail "key-B holder did not resolve");
  Eio.Promise.resolve resolve_release ()

let () =
  Alcotest.run
    "runtime_binding_capacity"
    [ ( "gate"
      , [ Alcotest.test_case "ungated None/Some0 runs free" `Quick test_ungated
        ; Alcotest.test_case "cap=1 blocks second holder" `Quick test_cap_blocks_second
        ; Alcotest.test_case "permit released on exception" `Quick test_release_on_exception
        ; Alcotest.test_case "distinct keys independent" `Quick test_distinct_keys_independent
        ] )
    ]
