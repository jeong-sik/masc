(* P15 tests: failure pattern detection *)

module BH = Masc_exec.Bash_history

(* --- helpers --- *)

let tmp_dir =
  Filename.get_temp_dir_name ()
  ^ "/test_history_insight_"
  ^ string_of_int (Unix.getpid ())
;;

let setup () =
  if not (Sys.file_exists tmp_dir) then Unix.mkdir tmp_dir 0o755;
  tmp_dir
;;

let teardown () =
  let rec rm_rf path =
    if Sys.is_directory path
    then (
      let entries = Sys.readdir path in
      Array.iter (fun e -> rm_rf (Filename.concat path e)) entries;
      Unix.rmdir path)
    else Unix.unlink path
  in
  if Sys.file_exists tmp_dir then rm_rf tmp_dir
;;

let make_entry ~cmd ~success ~duration =
  { BH.ts = Unix.time ()
  ; BH.cmd_hash = BH.cmd_hash cmd
  ; BH.cmd_prefix =
      (* take first word as prefix *)
      (match String.split_on_char ' ' cmd with
       | [] -> cmd
       | w :: _ -> w)
  ; BH.semantic_kind = "Unknown"
  ; BH.duration_ms = duration
  ; BH.success
  }
;;

let append_entries dir name entries =
  List.iter (BH.append ~base_path:dir ~keeper_name:name) entries
;;

(* --- tests --- *)

let test_no_history_file () =
  let dir = setup () in
  let patterns = BH.failure_insight ~base_path:dir ~keeper_name:"nobody" in
  Alcotest.(check int) "no patterns" 0 (List.length patterns);
  teardown ()
;;

let test_healthy_history () =
  let dir = setup () in
  let entries =
    List.init 10 (fun i ->
      make_entry ~cmd:("cmd" ^ string_of_int i) ~success:true ~duration:100)
  in
  append_entries dir "healthy" entries;
  let patterns = BH.failure_insight ~base_path:dir ~keeper_name:"healthy" in
  Alcotest.(check int) "no patterns when healthy" 0 (List.length patterns);
  teardown ()
;;

let test_repeated_failure () =
  let dir = setup () in
  let entries =
    [ make_entry ~cmd:"npm test" ~success:true ~duration:500
    ; make_entry ~cmd:"npm test" ~success:false ~duration:200
    ; make_entry ~cmd:"npm test" ~success:false ~duration:200
    ; make_entry ~cmd:"npm test" ~success:false ~duration:200
    ]
  in
  append_entries dir "stuck" entries;
  let patterns = BH.failure_insight ~base_path:dir ~keeper_name:"stuck" in
  let repeated =
    List.filter
      (function
        | BH.Repeated_failure _ -> true
        | _ -> false)
      patterns
  in
  Alcotest.(check int) "one repeated pattern" 1 (List.length repeated);
  (match repeated with
   | [ BH.Repeated_failure { cmd_prefix; count } ] ->
     Alcotest.(check string) "prefix" "npm" cmd_prefix;
     Alcotest.(check int) "count" 3 count
   | _ -> Alcotest.fail "unexpected repeated pattern shape");
  teardown ()
;;

let test_high_failure_rate () =
  let dir = setup () in
  (* 6 failures out of 8 recent = 75% > 60% threshold *)
  let entries =
    [ make_entry ~cmd:"a" ~success:false ~duration:100
    ; make_entry ~cmd:"b" ~success:false ~duration:100
    ; make_entry ~cmd:"c" ~success:true ~duration:100
    ; make_entry ~cmd:"d" ~success:false ~duration:100
    ; make_entry ~cmd:"e" ~success:false ~duration:100
    ; make_entry ~cmd:"f" ~success:true ~duration:100
    ; make_entry ~cmd:"g" ~success:false ~duration:100
    ; make_entry ~cmd:"h" ~success:false ~duration:100
    ]
  in
  append_entries dir "flaky" entries;
  let patterns = BH.failure_insight ~base_path:dir ~keeper_name:"flaky" in
  let rate_pat =
    List.filter
      (function
        | BH.High_failure_rate _ -> true
        | _ -> false)
      patterns
  in
  Alcotest.(check int) "one rate pattern" 1 (List.length rate_pat);
  (match rate_pat with
   | [ BH.High_failure_rate { recent; failures; rate } ] ->
     Alcotest.(check int) "recent" 8 recent;
     Alcotest.(check int) "failures" 6 failures;
     (* 6/8 = 0.75 *)
     Alcotest.(check bool) "rate >= 0.6" true (rate >= 0.6)
   | _ -> Alcotest.fail "unexpected rate pattern shape");
  teardown ()
;;

let test_timeout_cluster () =
  let dir = setup () in
  let entries =
    [ make_entry ~cmd:"dune build" ~success:true ~duration:5000
    ; make_entry ~cmd:"dune build" ~success:false ~duration:35000
    ; make_entry ~cmd:"dune build" ~success:false ~duration:32000
    ]
  in
  append_entries dir "slow" entries;
  let patterns = BH.failure_insight ~base_path:dir ~keeper_name:"slow" in
  let timeouts =
    List.filter
      (function
        | BH.Timeout_cluster _ -> true
        | _ -> false)
      patterns
  in
  Alcotest.(check int) "one timeout pattern" 1 (List.length timeouts);
  (match timeouts with
   | [ BH.Timeout_cluster { cmd_prefix; count } ] ->
     Alcotest.(check string) "prefix" "dune" cmd_prefix;
     Alcotest.(check int) "count" 2 count
   | _ -> Alcotest.fail "unexpected timeout pattern shape");
  teardown ()
;;

let test_json_output () =
  let dir = setup () in
  let entries =
    [ make_entry ~cmd:"cargo test" ~success:false ~duration:100
    ; make_entry ~cmd:"cargo test" ~success:false ~duration:100
    ; make_entry ~cmd:"cargo test" ~success:false ~duration:100
    ]
  in
  append_entries dir "json_test" entries;
  let patterns = BH.failure_insight ~base_path:dir ~keeper_name:"json_test" in
  (match patterns with
   | [ (BH.Repeated_failure _ as pat) ] ->
     let json = BH.failure_pattern_to_json pat in
     (match json with
      | `Assoc fields ->
        (match List.assoc_opt "kind" fields with
         | Some (`String "repeated_failure") -> ()
         | _ -> Alcotest.fail "kind field missing or wrong")
      | _ -> Alcotest.fail "expected assoc json")
   | _ -> Alcotest.fail "expected exactly one repeated pattern");
  teardown ()
;;

let () =
  test_no_history_file ();
  test_healthy_history ();
  test_repeated_failure ();
  test_high_failure_rate ();
  test_timeout_cluster ();
  test_json_output ();
  print_endline "test_history_insight: 6/6 passed"
;;
