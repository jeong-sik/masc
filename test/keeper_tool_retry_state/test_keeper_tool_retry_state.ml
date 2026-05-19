(* Standalone Alcotest unit tests for [Keeper_tool_retry_state]. *)

open Keeper_tool_retry_state

let reset () = reset_for_test ()

(* ── normalize ────────────────────────────────────────────────── *)

let test_normalize_idempotent () =
  let inputs =
    [ ""
    ; "Plain"
    ; "   trim me   "
    ; "Mixed\tCASE\nand\rWS"
    ; String.make (normalize_length_cap + 50) 'X'
    ]
  in
  List.iter
    (fun s ->
      let once = normalize s in
      let twice = normalize once in
      Alcotest.(check string)
        (Printf.sprintf "normalize idempotent for %S" s)
        once
        twice)
    inputs
;;

let test_normalize_trims_and_lowercases () =
  Alcotest.(check string)
    "trim+lowercase"
    "foo bar"
    (normalize "  FOO   BAR  ")
;;

let test_normalize_collapses_whitespace_runs () =
  Alcotest.(check string)
    "tabs/newlines collapse to single space"
    "a b c"
    (normalize "A\t\tB\n\nC")
;;

let test_normalize_length_cap () =
  let raw = String.make (normalize_length_cap + 50) 'A' in
  let out = normalize raw in
  Alcotest.(check int)
    "output length <= cap"
    normalize_length_cap
    (String.length out)
;;

let test_normalize_preserves_non_ascii () =
  (* Non-ASCII bytes (e.g. UTF-8 continuation bytes) must pass
     through untouched; only ASCII A..Z is lowercased. *)
  let raw = "café" in
  let out = normalize raw in
  (* The "c" is already lowercase and "afé" contains a non-ASCII
     sequence — output should equal input post-trim. *)
  Alcotest.(check string) "non-ASCII passthrough" "café" out
;;

(* ── record / classification ──────────────────────────────────── *)

let test_first_returns_first () =
  reset ();
  let out =
    record
      ~tool_name:"keeper_bash"
      ~error_signature:(normalize "spawn failed")
      ~attempt:1
      ()
  in
  match out with
  | `First -> ()
  | `Repeated _ -> Alcotest.fail "expected `First, got `Repeated"
  | `Threshold_silence _ ->
    Alcotest.fail "expected `First, got `Threshold_silence"
;;

let test_second_returns_repeated_2 () =
  reset ();
  let sig_ = normalize "spawn failed" in
  let _ : outcome =
    record ~tool_name:"keeper_bash" ~error_signature:sig_ ~attempt:1 ()
  in
  let out =
    record ~tool_name:"keeper_bash" ~error_signature:sig_ ~attempt:2 ()
  in
  match out with
  | `Repeated n ->
    Alcotest.(check int) "count should be 2" 2 n
  | `First -> Alcotest.fail "expected `Repeated, got `First"
  | `Threshold_silence _ ->
    Alcotest.fail "expected `Repeated, got `Threshold_silence"
;;

let test_attempt_param_does_not_affect_fingerprint () =
  (* attempt is for logging only; fingerprint is (tool, signature). *)
  reset ();
  let sig_ = normalize "boom" in
  let _ : outcome =
    record ~tool_name:"keeper_bash" ~error_signature:sig_ ~attempt:1 ()
  in
  let out =
    record ~tool_name:"keeper_bash" ~error_signature:sig_ ~attempt:1 ()
  in
  match out with
  | `Repeated 2 -> ()
  | `Repeated n -> Alcotest.failf "expected Repeated 2, got Repeated %d" n
  | _ ->
    Alcotest.fail
      "expected `Repeated 2 even with attempt=1 reused (attempt is \
       advisory)"
;;

let test_threshold_silence_fires_at_threshold () =
  reset ();
  let threshold = 5 in
  let sig_ = normalize "container_create_failed" in
  (* First four records: `First then 3× `Repeated. *)
  for i = 1 to threshold - 1 do
    let _ : outcome =
      record
        ~silence_threshold:threshold
        ~tool_name:"keeper_bash"
        ~error_signature:sig_
        ~attempt:i
        ()
    in
    ()
  done;
  let out =
    record
      ~silence_threshold:threshold
      ~tool_name:"keeper_bash"
      ~error_signature:sig_
      ~attempt:threshold
      ()
  in
  match out with
  | `Threshold_silence n ->
    Alcotest.(check int) "count at threshold" threshold n
  | `First -> Alcotest.fail "expected `Threshold_silence, got `First"
  | `Repeated _ ->
    Alcotest.fail "expected `Threshold_silence, got `Repeated"
;;

let test_threshold_silence_fires_only_once () =
  reset ();
  let threshold = 3 in
  let sig_ = normalize "timeout" in
  for i = 1 to threshold do
    let _ : outcome =
      record
        ~silence_threshold:threshold
        ~tool_name:"masc_transition"
        ~error_signature:sig_
        ~attempt:i
        ()
    in
    ()
  done;
  let out =
    record
      ~silence_threshold:threshold
      ~tool_name:"masc_transition"
      ~error_signature:sig_
      ~attempt:(threshold + 1)
      ()
  in
  match out with
  | `Repeated n ->
    Alcotest.(check int)
      "post-silence records return Repeated with running count"
      (threshold + 1)
      n
  | `First ->
    Alcotest.fail "expected `Repeated after silence, got `First"
  | `Threshold_silence _ ->
    Alcotest.fail "expected `Repeated, got second `Threshold_silence"
;;

(* ── distinct keys ────────────────────────────────────────────── *)

let test_distinct_tool_names_independent () =
  reset ();
  let sig_ = normalize "same error" in
  let _ =
    record ~tool_name:"keeper_bash" ~error_signature:sig_ ~attempt:1 ()
  in
  let _ =
    record ~tool_name:"keeper_bash" ~error_signature:sig_ ~attempt:2 ()
  in
  let out =
    record ~tool_name:"masc_worktree_create" ~error_signature:sig_ ~attempt:1 ()
  in
  match out with
  | `First -> ()
  | _ ->
    Alcotest.fail "expected `First for fresh tool_name"
;;

let test_distinct_signatures_independent () =
  reset ();
  let _ =
    record
      ~tool_name:"keeper_bash"
      ~error_signature:(normalize "spawn failed")
      ~attempt:1
      ()
  in
  let out =
    record
      ~tool_name:"keeper_bash"
      ~error_signature:(normalize "timeout")
      ~attempt:1
      ()
  in
  match out with
  | `First -> ()
  | _ ->
    Alcotest.fail "expected `First for fresh error_signature"
;;

let test_key_separator_no_collision () =
  (* "ab" ++ "cd" must not collide with "a" ++ "bcd". *)
  reset ();
  let _ =
    record
      ~tool_name:"ab"
      ~error_signature:(normalize "cd")
      ~attempt:1
      ()
  in
  let out =
    record
      ~tool_name:"a"
      ~error_signature:(normalize "bcd")
      ~attempt:1
      ()
  in
  match out with
  | `First -> ()
  | _ ->
    Alcotest.fail
      "expected `First — key separator must prevent prefix collision"
;;

(* ── reset / introspection ────────────────────────────────────── *)

let test_reset_for_test_clears_state () =
  reset ();
  let sig_ = normalize "err" in
  let _ =
    record ~tool_name:"keeper_bash" ~error_signature:sig_ ~attempt:1 ()
  in
  Alcotest.(check int)
    "occurrence_count before reset"
    1
    (occurrence_count ~tool_name:"keeper_bash" ~error_signature:sig_);
  reset_for_test ();
  Alcotest.(check int)
    "occurrence_count after reset"
    0
    (occurrence_count ~tool_name:"keeper_bash" ~error_signature:sig_);
  Alcotest.(check int) "cardinality after reset" 0 (cardinality ())
;;

let test_cardinality_tracks_distinct_pairs () =
  reset ();
  Alcotest.(check int) "empty" 0 (cardinality ());
  let sig_a = normalize "a" in
  let sig_b = normalize "b" in
  let _ =
    record ~tool_name:"keeper_bash" ~error_signature:sig_a ~attempt:1 ()
  in
  Alcotest.(check int) "one pair" 1 (cardinality ());
  let _ =
    record ~tool_name:"keeper_bash" ~error_signature:sig_a ~attempt:2 ()
  in
  Alcotest.(check int) "same pair, still 1" 1 (cardinality ());
  let _ =
    record ~tool_name:"keeper_bash" ~error_signature:sig_b ~attempt:1 ()
  in
  Alcotest.(check int) "second signature" 2 (cardinality ());
  let _ =
    record ~tool_name:"masc_transition" ~error_signature:sig_a ~attempt:1 ()
  in
  Alcotest.(check int) "second tool" 3 (cardinality ())
;;

let test_occurrence_count_zero_for_missing () =
  reset ();
  Alcotest.(check int)
    "missing pair returns 0"
    0
    (occurrence_count
       ~tool_name:"never_seen"
       ~error_signature:(normalize "nope"))
;;

(* ── production scenario ──────────────────────────────────────── *)

(* Regression-style scenario: replay the production fingerprint of
   the 2026-05-19 1000-line sample — 5 tools, the supervisor
   reissues each at most 3 attempts per cycle, the same failure
   recurs across cycles. The first attempt of each (tool, sig)
   should be [`First] (ERROR), attempts 2 and 3 of that cycle plus
   the first three attempts of the second cycle (counts 2..5)
   should be [`Repeated], and the 5th occurrence (default
   threshold) should fire one [`Threshold_silence]. *)
let test_production_scenario_5_tools () =
  reset ();
  let tools_with_sigs =
    [ "keeper_bash", normalize "spawn failed: ENOENT"
    ; "masc_worktree_create", normalize "branch already exists"
    ; "keeper_pr_review_comment", normalize "404 not found"
    ; "masc_transition", normalize "phase guard rejected"
    ; "Bash", normalize "exit code 1"
    ]
  in
  List.iter
    (fun (tool, sig_) ->
      let first =
        record ~tool_name:tool ~error_signature:sig_ ~attempt:1 ()
      in
      (match first with
       | `First -> ()
       | _ -> Alcotest.failf "%s: first record was not `First" tool);
      (* Three more records bring the count to 4 (still below
         default_silence_threshold = 5). *)
      for i = 2 to default_silence_threshold - 1 do
        let out =
          record ~tool_name:tool ~error_signature:sig_ ~attempt:i ()
        in
        match out with
        | `Repeated _ -> ()
        | _ ->
          Alcotest.failf
            "%s: pre-threshold record at attempt=%d was not `Repeated"
            tool
            i
      done;
      (* Fifth record: should trip Threshold_silence at count=5. *)
      let silence_outcome =
        record
          ~tool_name:tool
          ~error_signature:sig_
          ~attempt:default_silence_threshold
          ()
      in
      match silence_outcome with
      | `Threshold_silence n ->
        Alcotest.(check int)
          (Printf.sprintf "%s: silence count" tool)
          default_silence_threshold
          n
      | _ ->
        Alcotest.failf
          "%s: did not Threshold_silence at attempt=%d"
          tool
          default_silence_threshold)
    tools_with_sigs;
  Alcotest.(check int)
    "5 distinct (tool, signature) pairs registered"
    5
    (cardinality ())
;;

let () =
  Alcotest.run
    "keeper_tool_retry_state"
    [ ( "normalize"
      , [ Alcotest.test_case "idempotent" `Quick test_normalize_idempotent
        ; Alcotest.test_case
            "trims_and_lowercases"
            `Quick
            test_normalize_trims_and_lowercases
        ; Alcotest.test_case
            "collapses_whitespace_runs"
            `Quick
            test_normalize_collapses_whitespace_runs
        ; Alcotest.test_case
            "length_cap"
            `Quick
            test_normalize_length_cap
        ; Alcotest.test_case
            "preserves_non_ascii"
            `Quick
            test_normalize_preserves_non_ascii
        ] )
    ; ( "record"
      , [ Alcotest.test_case "first" `Quick test_first_returns_first
        ; Alcotest.test_case
            "second_returns_repeated_2"
            `Quick
            test_second_returns_repeated_2
        ; Alcotest.test_case
            "attempt_param_advisory"
            `Quick
            test_attempt_param_does_not_affect_fingerprint
        ; Alcotest.test_case
            "threshold_silence"
            `Quick
            test_threshold_silence_fires_at_threshold
        ; Alcotest.test_case
            "threshold_silence_only_once"
            `Quick
            test_threshold_silence_fires_only_once
        ] )
    ; ( "distinct_keys"
      , [ Alcotest.test_case
            "distinct_tool_names_independent"
            `Quick
            test_distinct_tool_names_independent
        ; Alcotest.test_case
            "distinct_signatures_independent"
            `Quick
            test_distinct_signatures_independent
        ; Alcotest.test_case
            "key_separator_no_collision"
            `Quick
            test_key_separator_no_collision
        ] )
    ; ( "reset_and_introspection"
      , [ Alcotest.test_case
            "reset_for_test_clears"
            `Quick
            test_reset_for_test_clears_state
        ; Alcotest.test_case
            "cardinality_tracks_distinct"
            `Quick
            test_cardinality_tracks_distinct_pairs
        ; Alcotest.test_case
            "occurrence_count_zero_for_missing"
            `Quick
            test_occurrence_count_zero_for_missing
        ] )
    ; ( "production_scenario"
      , [ Alcotest.test_case
            "5_tools_2026_05_19"
            `Quick
            test_production_scenario_5_tools
        ] )
    ]
;;
