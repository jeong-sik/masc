(** Unit tests for Sliding_window_rate_limit *)

open Sliding_window_rate_limit

let test_create () =
  let limiter = create ~window_sec:1.0 ~max_requests:5 () in
  Alcotest.(check (float 1e-9)) "window_sec" 1.0 (window_sec limiter);
  Alcotest.(check int) "max_requests" 5 (max_requests limiter);
  ()

let test_basic_accept () =
  let limiter = create ~window_sec:60.0 ~max_requests:3 () in
  Alcotest.(check bool) "first" true (check limiter ~key:"a");
  Alcotest.(check bool) "second" true (check limiter ~key:"a");
  Alcotest.(check bool) "third" true (check limiter ~key:"a");
  ()

let test_basic_reject () =
  let limiter = create ~window_sec:60.0 ~max_requests:3 () in
  ignore (check limiter ~key:"a");
  ignore (check limiter ~key:"a");
  ignore (check limiter ~key:"a");
  Alcotest.(check bool) "fourth blocked" false (check limiter ~key:"a");
  ()

let test_remaining () =
  let limiter = create ~window_sec:60.0 ~max_requests:5 () in
  Alcotest.(check int) "fresh" 5 (remaining limiter ~key:"a");
  ignore (check limiter ~key:"a");
  Alcotest.(check int) "after_one" 4 (remaining limiter ~key:"a");
  ignore (check limiter ~key:"a");
  ignore (check limiter ~key:"a");
  Alcotest.(check int) "after_three" 2 (remaining limiter ~key:"a");
  ()

let test_independent_keys () =
  let limiter = create ~window_sec:60.0 ~max_requests:2 () in
  Alcotest.(check bool) "a1" true (check limiter ~key:"a");
  Alcotest.(check bool) "a2" true (check limiter ~key:"a");
  Alcotest.(check bool) "a3 blocked" false (check limiter ~key:"a");
  Alcotest.(check bool) "b1 fresh" true (check limiter ~key:"b");
  Alcotest.(check bool) "b2" true (check limiter ~key:"b");
  Alcotest.(check bool) "b3 blocked" false (check limiter ~key:"b");
  ()

let test_window_expiry () =
  let limiter = create ~window_sec:0.1 ~max_requests:2 () in
  ignore (check limiter ~key:"x");
  ignore (check limiter ~key:"x");
  Alcotest.(check bool) "first blocked" false (check limiter ~key:"x");
  Unix.sleepf 0.15;
  Alcotest.(check bool) "after sleep allowed" true (check limiter ~key:"x");
  ()

let test_cleanup_removes_stale () =
  let limiter = create ~window_sec:60.0 ~max_requests:5 () in
  ignore (check limiter ~key:"fresh");
  ignore (check limiter ~key:"stale");
  Unix.sleepf 0.01;
  let removed = cleanup limiter ~older_than_seconds:0.005 in
  Alcotest.(check int) "one stale removed" 1 removed;
  Alcotest.(check bool) "fresh still works" true (check limiter ~key:"fresh");
  ()

let test_cleanup_none_stale () =
  let limiter = create ~window_sec:60.0 ~max_requests:5 () in
  ignore (check limiter ~key:"a");
  let removed = cleanup limiter ~older_than_seconds:3600.0 in
  Alcotest.(check int) "none removed" 0 removed;
  ()

let test_zero_max_requests () =
  let limiter = create ~window_sec:60.0 ~max_requests:0 () in
  Alcotest.(check bool) "always blocked" false (check limiter ~key:"any");
  ()

let test_high_burst () =
  let limiter = create ~window_sec:10.0 ~max_requests:100 () in
  let results = List.init 100 (fun _ -> check limiter ~key:"burst") in
  let accepted = List.filter (fun x -> x) results |> List.length in
  Alcotest.(check int) "all 100 accepted" 100 accepted;
  Alcotest.(check bool) "101st blocked" false (check limiter ~key:"burst");
  ()

let () =
  Alcotest.run "Sliding_window_rate_limit" [
    "basics", [
      Alcotest.test_case "create" `Quick test_create;
      Alcotest.test_case "basic accept" `Quick test_basic_accept;
      Alcotest.test_case "basic reject" `Quick test_basic_reject;
      Alcotest.test_case "remaining count" `Quick test_remaining;
    ];
    "keys", [
      Alcotest.test_case "independent keys" `Quick test_independent_keys;
    ];
    "window", [
      Alcotest.test_case "window expiry" `Quick test_window_expiry;
    ];
    "cleanup", [
      Alcotest.test_case "removes stale" `Quick test_cleanup_removes_stale;
      Alcotest.test_case "none stale" `Quick test_cleanup_none_stale;
    ];
    "edge", [
      Alcotest.test_case "zero max" `Quick test_zero_max_requests;
      Alcotest.test_case "high burst" `Quick test_high_burst;
    ];
  ]