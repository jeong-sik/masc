(* Tests for Runtime_binding_capacity — the per-binding provider concurrency
   gate (RFC-0153 §4.2.3). Verifies the gate caps simultaneous holders at
   [max_concurrent], runs ungated for the unconfigured [0] marker, releases the
   slot on exception, and keeps distinct keys independent. *)

open Alcotest

let bump_peak peak observed =
  let rec loop () =
    let p = Atomic.get peak in
    if observed > p && not (Atomic.compare_and_set peak p observed) then loop ()
  in
  loop ()

(* 6 fibers, cap 2: at most 2 may hold a slot at once. Each holder yields
   several times so admitted fibers overlap in scheduling, making the observed
   peak deterministically equal to the cap rather than racing below it. *)
let test_caps_concurrency () =
  Eio_main.run @@ fun _env ->
  let cur = Atomic.make 0 and peak = Atomic.make 0 in
  let body () =
    Runtime_binding_capacity.with_slot ~key:"cap-test" ~max_concurrent:2
      (fun () ->
        let observed = Atomic.fetch_and_add cur 1 + 1 in
        bump_peak peak observed;
        for _ = 1 to 5 do
          Eio.Fiber.yield ()
        done;
        Atomic.decr cur)
  in
  Eio.Fiber.all (List.init 6 (fun _ -> body));
  check int "peak holders equals cap" 2 (Atomic.get peak);
  check int "all slots drained" 0 (Atomic.get cur)

(* [max_concurrent <= 0] = unconfigured binding: run ungated, create no
   semaphore (so a 0-permit deadlock is impossible and the key is absent from
   the snapshot). *)
let test_zero_is_ungated () =
  Eio_main.run @@ fun _env ->
  let ran = Atomic.make 0 in
  Eio.Fiber.all
    (List.init 4 (fun _ ->
         fun () ->
           Runtime_binding_capacity.with_slot ~key:"ungated" ~max_concurrent:0
             (fun () -> Atomic.incr ran)));
  check int "all ran ungated" 4 (Atomic.get ran);
  let has_ungated =
    List.exists
      (fun (k, _, _) -> String.equal k "ungated")
      (Runtime_binding_capacity.snapshot ())
  in
  check bool "ungated key creates no slot" false has_ungated

(* An exception inside the body must still release the slot; the next acquire
   on a cap-1 key must then proceed instead of deadlocking. *)
let test_release_on_exception () =
  Eio_main.run @@ fun _env ->
  let key = "exc-key" in
  (try
     Runtime_binding_capacity.with_slot ~key ~max_concurrent:1 (fun () ->
         failwith "boom")
   with Failure _ -> ());
  let ran = ref false in
  Runtime_binding_capacity.with_slot ~key ~max_concurrent:1 (fun () ->
      ran := true);
  check bool "slot released after exception" true !ran

(* Distinct keys get distinct semaphores sized by their own cap; the snapshot
   reports each key's configured cap. *)
let test_distinct_keys () =
  Eio_main.run @@ fun _env ->
  Runtime_binding_capacity.with_slot ~key:"A" ~max_concurrent:2 (fun () -> ());
  Runtime_binding_capacity.with_slot ~key:"B" ~max_concurrent:3 (fun () -> ());
  let cap_of k =
    List.find_map
      (fun (key, _, cap) -> if String.equal key k then Some cap else None)
      (Runtime_binding_capacity.snapshot ())
  in
  check (option int) "key A cap 2" (Some 2) (cap_of "A");
  check (option int) "key B cap 3" (Some 3) (cap_of "B")

let () =
  run "runtime_binding_capacity"
    [
      ( "gate",
        [
          test_case "caps simultaneous holders at max_concurrent" `Quick
            test_caps_concurrency;
          test_case "max_concurrent <= 0 runs ungated" `Quick
            test_zero_is_ungated;
          test_case "releases slot on exception" `Quick
            test_release_on_exception;
          test_case "distinct keys are independent" `Quick test_distinct_keys;
        ] );
    ]
