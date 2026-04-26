(** Tests for Masc_mcp.Lockfree_atomic helpers. *)

module L = Masc_mcp.Lockfree_atomic

let test_update_single () =
  let a = Atomic.make 0 in
  L.update a (fun n -> n + 1);
  Alcotest.(check int) "single update increments" 1 (Atomic.get a)
;;

let test_update_with_result_returns_derived_value () =
  let a = Atomic.make 10 in
  let prev = L.update_with_result a (fun n -> n * 2, n) in
  Alcotest.(check int) "derived value is pre-update state" 10 prev;
  Alcotest.(check int) "state is transformed" 20 (Atomic.get a)
;;

let test_update_with_result_on_map () =
  let module SMap = Map.Make (String) in
  let a = Atomic.make SMap.empty in
  let inserted =
    L.update_with_result a (fun m ->
      let m' = SMap.add "k" 42 m in
      m', SMap.cardinal m')
  in
  Alcotest.(check int) "cardinal after insert" 1 inserted;
  Alcotest.(check bool) "key present" true (SMap.mem "k" (Atomic.get a))
;;

let test_update_with_result_replays_on_contention () =
  (* Manually stage contention by mutating between read and CAS.
     The helper must retry and eventually converge. *)
  let a = Atomic.make 0 in
  let interference_left = ref 2 in
  let total =
    L.update_with_result a (fun observed ->
      (* Simulate another writer bumping [a] between our read and commit
           for the first two invocations. *)
      if !interference_left > 0
      then (
        decr interference_left;
        Atomic.set a (observed + 100));
      observed + 1, observed)
  in
  (* Under contention the observed value changes each attempt, but the final
     commit must see whatever [Atomic.get] returned at that iteration. *)
  Alcotest.(check bool)
    "returned value is some previously observed snapshot"
    true
    (total >= 0);
  Alcotest.(check int) "final state is observed + 1" (total + 1) (Atomic.get a)
;;

let test_update_never_loses_work () =
  (* Sequential invariant: N updates → N net increments. *)
  let a = Atomic.make 0 in
  for _ = 1 to 1000 do
    L.update a (fun n -> n + 1)
  done;
  Alcotest.(check int) "no updates lost" 1000 (Atomic.get a)
;;

let test_update_with_commit_returns_derived_value () =
  let a = Atomic.make 10 in
  let prev = L.update_with_commit a (fun n -> { L.next_state = n * 2; result = n }) in
  Alcotest.(check int) "commit returns pre-update snapshot" 10 prev;
  Alcotest.(check int) "state transformed" 20 (Atomic.get a)
;;

let test_update_with_commit_on_map () =
  let module SMap = Map.Make (String) in
  let a = Atomic.make SMap.empty in
  let inserted =
    L.update_with_commit a (fun m ->
      let m' = SMap.add "k" 42 m in
      { L.next_state = m'; result = SMap.cardinal m' })
  in
  Alcotest.(check int) "cardinal after insert" 1 inserted;
  Alcotest.(check bool) "key present" true (SMap.mem "k" (Atomic.get a))
;;

let () =
  Alcotest.run
    "Lockfree_atomic"
    [ ( "update"
      , [ Alcotest.test_case "single increment" `Quick test_update_single
        ; Alcotest.test_case "1k sequential" `Quick test_update_never_loses_work
        ] )
    ; ( "update_with_result"
      , [ Alcotest.test_case
            "derived value"
            `Quick
            test_update_with_result_returns_derived_value
        ; Alcotest.test_case "map insert" `Quick test_update_with_result_on_map
        ; Alcotest.test_case
            "contention replay"
            `Quick
            test_update_with_result_replays_on_contention
        ] )
    ; ( "update_with_commit"
      , [ Alcotest.test_case
            "derived value"
            `Quick
            test_update_with_commit_returns_derived_value
        ; Alcotest.test_case "map insert" `Quick test_update_with_commit_on_map
        ] )
    ]
;;
