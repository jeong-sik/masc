(** Tests for Lamport clock *)

module L = Lamport

let test_create () =
  let clock = L.create () in
  Alcotest.(check int) "initial is 0" 0 (L.current clock)

let test_tick () =
  let clock = L.create () in
  let t1 = L.tick clock in
  let t2 = L.tick clock in
  Alcotest.(check bool) "tick increments" true (t2 > t1);
  Alcotest.(check int) "first tick is 1" 1 t1;
  Alcotest.(check int) "second tick is 2" 2 t2

let test_recv_advances () =
  let clock = L.create () in
  let _ = L.tick clock in  (* local = 1 *)
  let t = L.recv clock ~remote_time:10 in
  Alcotest.(check int) "recv max(1,10)+1 = 11" 11 t

let test_recv_local_ahead () =
  let clock = L.create () in
  for _ = 1 to 20 do ignore (L.tick clock) done;  (* local = 20 *)
  let t = L.recv clock ~remote_time:5 in
  Alcotest.(check int) "recv max(20,5)+1 = 21" 21 t

let test_happened_before () =
  Alcotest.(check bool) "1 before 2" true (L.happened_before 1 2);
  Alcotest.(check bool) "2 not before 1" false (L.happened_before 2 1);
  Alcotest.(check bool) "same not before" false (L.happened_before 5 5)

let test_compare_timestamps () =
  Alcotest.(check int) "1 < 2" (-1) (L.compare_timestamps 1 2);
  Alcotest.(check int) "2 > 1" 1 (L.compare_timestamps 2 1);
  Alcotest.(check int) "equal" 0 (L.compare_timestamps 5 5)

let test_reset () =
  let clock = L.create () in
  let _ = L.tick clock in
  L.reset clock;
  Alcotest.(check int) "reset to 0" 0 (L.current clock)

let () =
  Alcotest.run "Lamport" [
    "basic", [
      Alcotest.test_case "create" `Quick test_create;
      Alcotest.test_case "tick" `Quick test_tick;
      Alcotest.test_case "recv advances" `Quick test_recv_advances;
      Alcotest.test_case "recv local ahead" `Quick test_recv_local_ahead;
      Alcotest.test_case "happened_before" `Quick test_happened_before;
      Alcotest.test_case "compare" `Quick test_compare_timestamps;
      Alcotest.test_case "reset" `Quick test_reset;
    ];
  ]
