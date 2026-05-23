(** Tests for Masc_mcp.Lockfree_atomic helpers. *)

module L = Masc_mcp.Lockfree_atomic

let test_update_single () =
  let a = Atomic.make 0 in
  L.update a (fun n -> n + 1);
  Alcotest.(check int) "single update increments" 1 (Atomic.get a)

let test_update_never_loses_work () =
  (* Sequential invariant: N updates → N net increments. *)
  let a = Atomic.make 0 in
  for _ = 1 to 1000 do
    L.update a (fun n -> n + 1)
  done;
  Alcotest.(check int) "no updates lost" 1000 (Atomic.get a)

let test_update_with_commit_returns_derived_value () =
  let a = Atomic.make 10 in
  let prev =
    L.update_with_commit a (fun n -> { L.next_state = n * 2; result = n })
  in
  Alcotest.(check int) "commit returns pre-update snapshot" 10 prev;
  Alcotest.(check int) "state transformed" 20 (Atomic.get a)

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

let () =
  Alcotest.run "Lockfree_atomic" [
    "update", [
      Alcotest.test_case "single increment" `Quick test_update_single;
      Alcotest.test_case "1k sequential" `Quick test_update_never_loses_work;
    ];
    "update_with_commit", [
      Alcotest.test_case "derived value" `Quick
        test_update_with_commit_returns_derived_value;
      Alcotest.test_case "map insert" `Quick test_update_with_commit_on_map;
    ];
  ]
