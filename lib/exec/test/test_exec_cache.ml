(* P19 tests: execution result cache *)

module EC = Masc_exec.Exec_cache

let test_create_empty () =
  let t = EC.create () in
  (match EC.lookup t "ls" with
   | None -> ()
   | _ -> Alcotest.fail "new cache should be empty")

let test_store_and_lookup () =
  let t = EC.create () in
  EC.store t ~cmd:"git status" ~exit_code:0 ~output:"clean" ~duration_ms:100;
  (match EC.lookup t "git status" with
   | Some entry ->
     Alcotest.(check int) "exit_code" 0 entry.exit_code;
     Alcotest.(check string) "output" "clean" entry.output;
     Alcotest.(check int) "duration_ms" 100 entry.duration_ms
   | None -> Alcotest.fail "should find stored entry")

let test_lookup_miss_increments () =
  let t = EC.create () in
  ignore (EC.lookup t "missing");
  let (_, misses) = EC.stats t in
  Alcotest.(check int) "misses" 1 misses

let test_lookup_hit_increments () =
  let t = EC.create () in
  EC.store t ~cmd:"ls" ~exit_code:0 ~output:"file.ml" ~duration_ms:10;
  ignore (EC.lookup t "ls");
  let (hits, _) = EC.stats t in
  Alcotest.(check int) "hits" 1 hits

let test_reset_clears () =
  let t = EC.create () in
  EC.store t ~cmd:"ls" ~exit_code:0 ~output:"a" ~duration_ms:10;
  EC.reset t;
  (match EC.lookup t "ls" with
   | None -> ()
   | _ -> Alcotest.fail "reset should clear entries");
  let (hits, misses) = EC.stats t in
  Alcotest.(check int) "hits" 0 hits;
  Alcotest.(check int) "misses" 1 misses

let test_invalidate () =
  let t = EC.create () in
  EC.store t ~cmd:"ls" ~exit_code:0 ~output:"a" ~duration_ms:10;
  EC.invalidate t "ls";
  (match EC.lookup t "ls" with
   | None -> ()
   | _ -> Alcotest.fail "invalidate should remove entry")

let test_overwrite () =
  let t = EC.create () in
  EC.store t ~cmd:"ls" ~exit_code:0 ~output:"v1" ~duration_ms:10;
  EC.store t ~cmd:"ls" ~exit_code:1 ~output:"v2" ~duration_ms:20;
  (match EC.lookup t "ls" with
   | Some entry ->
     Alcotest.(check string) "output" "v2" entry.output;
     Alcotest.(check int) "exit_code" 1 entry.exit_code
   | None -> Alcotest.fail "should find overwritten entry")

let test_to_json () =
  let t = EC.create () in
  EC.store t ~cmd:"ls" ~exit_code:0 ~output:"abc" ~duration_ms:10;
  ignore (EC.lookup t "ls");
  ignore (EC.lookup t "missing");
  let json = EC.to_json t in
  (match json with
   | `Assoc fields ->
     (match List.assoc_opt "hit_count" fields with
      | Some (`Int 1) -> ()
      | _ -> Alcotest.fail "hit_count should be 1");
     (match List.assoc_opt "miss_count" fields with
      | Some (`Int 1) -> ()
      | _ -> Alcotest.fail "miss_count should be 1");
     (match List.assoc_opt "entry_count" fields with
      | Some (`Int 1) -> ()
      | _ -> Alcotest.fail "entry_count should be 1");
     (match List.assoc_opt "size_bytes" fields with
      | Some (`Int 3) -> ()
      | _ -> Alcotest.fail "size_bytes should be 3 (length of 'abc')")
   | _ -> Alcotest.fail "expected assoc")

let test_multiple_commands () =
  let t = EC.create () in
  for i = 1 to 10 do
    EC.store t
      ~cmd:(Printf.sprintf "cmd%d" i)
      ~exit_code:0
      ~output:"ok"
      ~duration_ms:i
  done;
  for i = 1 to 10 do
    ignore (EC.lookup t (Printf.sprintf "cmd%d" i))
  done;
  let (hits, misses) = EC.stats t in
  Alcotest.(check int) "hits" 10 hits;
  Alcotest.(check int) "misses" 0 misses

let () =
  test_create_empty ();
  test_store_and_lookup ();
  test_lookup_miss_increments ();
  test_lookup_hit_increments ();
  test_reset_clears ();
  test_invalidate ();
  test_overwrite ();
  test_to_json ();
  test_multiple_commands ();
  print_endline "test_exec_cache: 9/9 passed"
