(* P17 tests: turn execution budget *)

module EB = Masc_exec.Exec_budget

(* --- tests --- *)

let test_create_default () =
  let t = EB.create () in
  let json = EB.to_json t in
  (match json with
   | `Assoc fields ->
     (match List.assoc_opt "count" fields with
      | Some (`Int 0) -> ()
      | _ -> Alcotest.fail "count should be 0");
     (match List.assoc_opt "limit" fields with
      | Some (`Int 30) -> ()
      | _ -> Alcotest.fail "limit should be 30");
     (match List.assoc_opt "soft_limit" fields with
      | Some (`Int 20) -> ()
      | _ -> Alcotest.fail "soft_limit should be 20")
   | _ -> Alcotest.fail "expected assoc")

let test_create_custom () =
  let t = EB.create ~limit:10 ~soft_limit:5 () in
  let json = EB.to_json t in
  (match json with
   | `Assoc fields ->
     (match List.assoc_opt "limit" fields with
      | Some (`Int 10) -> ()
      | _ -> Alcotest.fail "limit should be 10")
   | _ -> Alcotest.fail "expected assoc")

let test_record_increments () =
  let t = EB.create ~limit:10 ~soft_limit:5 () in
  EB.record t ~duration_ms:100;
  EB.record t ~duration_ms:200;
  EB.record t ~duration_ms:300;
  let json = EB.to_json t in
  (match json with
   | `Assoc fields ->
     (match List.assoc_opt "count" fields with
      | Some (`Int 3) -> ()
      | _ -> Alcotest.fail "count should be 3");
     (match List.assoc_opt "cumulative_ms" fields with
      | Some (`Int 600) -> ()
      | _ -> Alcotest.fail "cumulative_ms should be 600")
   | _ -> Alcotest.fail "expected assoc")

let test_check_ok () =
  let t = EB.create ~limit:10 ~soft_limit:5 () in
  (match EB.check t with
   | EB.Ok { remaining } -> Alcotest.(check int) "remaining" 5 remaining
   | _ -> Alcotest.fail "should be Ok")

let test_check_soft_warning () =
  let t = EB.create ~limit:10 ~soft_limit:5 () in
  for _ = 1 to 5 do EB.record t ~duration_ms:100 done;
  (match EB.check t with
   | EB.Soft_warning { remaining; limit } ->
       Alcotest.(check int) "remaining" 5 remaining;
       Alcotest.(check int) "limit" 10 limit
   | _ -> Alcotest.fail "should be Soft_warning at count=5")

let test_check_hard_stop () =
  let t = EB.create ~limit:10 ~soft_limit:5 () in
  for _ = 1 to 10 do EB.record t ~duration_ms:100 done;
  (match EB.check t with
   | EB.Hard_stop { count; limit; cumulative_ms } ->
       Alcotest.(check int) "count" 10 count;
       Alcotest.(check int) "limit" 10 limit;
       Alcotest.(check int) "cumulative_ms" 1000 cumulative_ms
   | _ -> Alcotest.fail "should be Hard_stop at count=10")

let test_reset () =
  let t = EB.create ~limit:10 ~soft_limit:5 () in
  for _ = 1 to 8 do EB.record t ~duration_ms:50 done;
  EB.reset t;
  (match EB.check t with
   | EB.Ok { remaining } -> Alcotest.(check int) "remaining" 5 remaining
   | _ -> Alcotest.fail "should be Ok after reset")

let test_status_json_soft () =
  let t = EB.create ~limit:10 ~soft_limit:5 () in
  for _ = 1 to 5 do EB.record t ~duration_ms:100 done;
  (match EB.check t with
   | EB.Soft_warning _ as status ->
     let json = EB.status_to_json status in
     (match json with
      | `Assoc fields ->
        (match List.assoc_opt "level" fields with
         | Some (`String "soft_warning") -> ()
         | _ -> Alcotest.fail "level should be soft_warning");
        (match List.assoc_opt "suggestion" fields with
         | Some (`String _) -> ()
         | _ -> Alcotest.fail "should have suggestion")
      | _ -> Alcotest.fail "expected assoc")
   | _ -> Alcotest.fail "wrong status")

let test_status_json_null_when_ok () =
  let t = EB.create () in
  (match EB.check t with
   | Ok _ as status ->
     let json = EB.status_to_json status in
     (match json with `Null -> () | _ -> Alcotest.fail "should be Null")
   | _ -> Alcotest.fail "should be Ok")

let () =
  test_create_default ();
  test_create_custom ();
  test_record_increments ();
  test_check_ok ();
  test_check_soft_warning ();
  test_check_hard_stop ();
  test_reset ();
  test_status_json_soft ();
  test_status_json_null_when_ok ();
  print_endline "test_exec_budget: 9/9 passed"
