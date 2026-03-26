open Alcotest
open Masc_mcp

(** Test Mitosis module - 2-Phase Cell Division Pattern *)

(* ===== safe_sub tests ===== *)

let test_safe_sub_normal () =
  let result = Mitosis.safe_sub "hello world" 0 5 in
  check string "normal substring" "hello" result

let test_safe_sub_negative_start () =
  let result = Mitosis.safe_sub "hello" (-1) 3 in
  check string "negative start returns empty" "" result

let test_safe_sub_negative_len () =
  let result = Mitosis.safe_sub "hello" 0 (-1) in
  check string "negative len returns empty" "" result

let test_safe_sub_start_beyond_len () =
  let result = Mitosis.safe_sub "hello" 10 3 in
  check string "start beyond length returns empty" "" result

let test_safe_sub_len_exceeds () =
  let result = Mitosis.safe_sub "hello" 3 100 in
  check string "len exceeds returns rest" "lo" result

let test_safe_sub_empty_string () =
  let result = Mitosis.safe_sub "" 0 5 in
  check string "empty string returns empty" "" result

(* ===== deduplicate_lines tests ===== *)

let test_dedup_no_overlap () =
  let base = "line1\nline2\nline3" in
  let delta = "line4\nline5" in
  let result = Mitosis.deduplicate_lines ~base ~delta in
  check string "no overlap keeps all" "line4\nline5" result

let test_dedup_full_overlap () =
  let base = "this is a longer line\nanother long line here" in
  let delta = "this is a longer line\nanother long line here" in
  let result = Mitosis.deduplicate_lines ~base ~delta in
  (* Should be empty since both lines are duplicates *)
  check string "full overlap removes all" "" result

let test_dedup_partial_overlap () =
  let base = "existing long line here\nkeep this one" in
  let delta = "existing long line here\nnew unique line" in
  let result = Mitosis.deduplicate_lines ~base ~delta in
  (* First line filtered out, only "new unique line" remains *)
  check string "partial overlap removes duplicates" "new unique line" result

let test_dedup_short_lines_kept () =
  let base = "short\nthis is a long line" in
  let delta = "short\nnew" in
  let result = Mitosis.deduplicate_lines ~base ~delta in
  (* Short lines (<=10 chars) are always kept *)
  check string "short lines always kept" "short\nnew" result

(* ===== compress_to_dna tests ===== *)

let test_compress_ratio () =
  let context = String.make 1000 'a' in
  let result = Mitosis.compress_to_dna ~ratio:0.1 ~context in
  check int "10% compression" 100 (String.length result)

let test_compress_ratio_over_100 () =
  let context = "short" in
  let result = Mitosis.compress_to_dna ~ratio:2.0 ~context in
  check string "ratio > 1 returns original" "short" result

(* ===== 2-Phase mitosis tests ===== *)

let test_should_prepare_at_50 () =
  let config = Mitosis.default_config in
  let cell = Mitosis.create_stem_cell ~generation:0 in
  let cell = { cell with state = Mitosis.Active; phase = Mitosis.Idle } in
  let result = Mitosis.should_prepare ~config ~cell ~context_ratio:0.5 in
  check bool "should prepare at 50%" true result

let test_should_not_prepare_below_threshold () =
  let config = Mitosis.default_config in
  let cell = Mitosis.create_stem_cell ~generation:0 in
  let cell = { cell with state = Mitosis.Active; phase = Mitosis.Idle } in
  let result = Mitosis.should_prepare ~config ~cell ~context_ratio:0.3 in
  check bool "should not prepare at 30%" false result

let test_should_not_prepare_when_already_prepared () =
  let config = Mitosis.default_config in
  let cell = Mitosis.create_stem_cell ~generation:0 in
  let cell = { cell with
    state = Mitosis.Prepared;
    phase = Mitosis.ReadyForHandoff "some dna"
  } in
  let result = Mitosis.should_prepare ~config ~cell ~context_ratio:0.6 in
  check bool "should not re-prepare" false result

let test_should_handoff_at_80 () =
  let config = Mitosis.default_config in
  let cell = Mitosis.create_stem_cell ~generation:0 in
  let cell = { cell with
    state = Mitosis.Prepared;
    phase = Mitosis.ReadyForHandoff "dna"
  } in
  let result = Mitosis.should_handoff ~config ~cell ~context_ratio:0.8 in
  check bool "should handoff at 80%" true result

let test_should_not_handoff_at_60 () =
  let config = Mitosis.default_config in
  let cell = Mitosis.create_stem_cell ~generation:0 in
  let cell = { cell with
    state = Mitosis.Prepared;
    phase = Mitosis.ReadyForHandoff "dna"
  } in
  let result = Mitosis.should_handoff ~config ~cell ~context_ratio:0.6 in
  check bool "should not handoff at 60%" false result

(* ===== auto_mitosis_check_2phase tests ===== *)

(** Mock spawn_fn for testing *)
let mock_spawn_fn ~prompt:_ =
  Spawn.{
    success = true;
    output = "mock spawn success";
    exit_code = 0;
    elapsed_ms = 100;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  }

let test_auto_mitosis_noaction_low_ratio () =
  let config = Mitosis.default_config in
  let pool = Mitosis.init_pool ~config in
  let cell = Mitosis.create_stem_cell ~generation:0 in
  let cell = { cell with state = Mitosis.Active; phase = Mitosis.Idle } in
  let full_context = "short context" in
  let result = Mitosis.auto_mitosis_check_2phase
    ~config ~pool ~cell ~context_ratio:0.3 ~full_context ~spawn_fn:mock_spawn_fn in
  match result with
  | Mitosis.NoAction -> ()
  | _ -> Alcotest.fail "expected NoAction at 30% context"

let test_auto_mitosis_prepared_at_threshold () =
  let config = Mitosis.default_config in
  let pool = Mitosis.init_pool ~config in
  let cell = Mitosis.create_stem_cell ~generation:0 in
  let cell = { cell with state = Mitosis.Active; phase = Mitosis.Idle } in
  let full_context = String.make 2000 'a' in
  let result = Mitosis.auto_mitosis_check_2phase
    ~config ~pool ~cell ~context_ratio:0.55 ~full_context ~spawn_fn:mock_spawn_fn in
  match result with
  | Mitosis.Prepared prepared_cell ->
      check Alcotest.string "prepared cell state" "prepared"
        (Mitosis.state_to_string prepared_cell.state);
      check Alcotest.string "prepared cell phase" "ready_for_handoff"
        (Mitosis.phase_to_string prepared_cell.phase)
  | _ -> Alcotest.fail "expected Prepared at 55% context"

let test_auto_mitosis_handoff_at_threshold () =
  let config = Mitosis.default_config in
  let pool = Mitosis.init_pool ~config in
  let cell = Mitosis.create_stem_cell ~generation:0 in
  let cell = { cell with
    state = Mitosis.Prepared;
    phase = Mitosis.ReadyForHandoff "existing dna"
  } in
  let full_context = String.make 2000 'a' in
  let result = Mitosis.auto_mitosis_check_2phase
    ~config ~pool ~cell ~context_ratio:0.85 ~full_context ~spawn_fn:mock_spawn_fn in
  match result with
  | Mitosis.Handoff (spawn_result, child_cell, _new_pool, _handoff_dna) ->
      check Alcotest.bool "spawn success" true spawn_result.success;
      check Alcotest.int "child generation" 1 child_cell.generation
  | _ -> Alcotest.fail "expected Handoff at 85% context"

let test_auto_mitosis_handoff_from_idle () =
  (* Emergency case: hit handoff threshold without prepare phase *)
  let config = Mitosis.default_config in
  let pool = Mitosis.init_pool ~config in
  let cell = Mitosis.create_stem_cell ~generation:0 in
  let cell = { cell with state = Mitosis.Active; phase = Mitosis.Idle } in
  let full_context = String.make 2000 'a' in
  let result = Mitosis.auto_mitosis_check_2phase
    ~config ~pool ~cell ~context_ratio:0.9 ~full_context ~spawn_fn:mock_spawn_fn in
  match result with
  | Mitosis.Handoff (spawn_result, child_cell, _new_pool, _handoff_dna) ->
      check Alcotest.bool "spawn success" true spawn_result.success;
      check Alcotest.int "child generation" 1 child_cell.generation
  | _ -> Alcotest.fail "expected emergency Handoff at 90% from Idle"

(* ===== extract_delta tests ===== *)

let test_extract_delta_short_session () =
  let config = { Mitosis.default_config with min_context_for_delta = 1000 } in
  let result = Mitosis.extract_delta ~config ~full_context:"short" ~since_len:0 in
  check string "short session returns empty" "" result

let test_extract_delta_no_new_content () =
  let config = Mitosis.default_config in
  let context = String.make 2000 'a' in
  let result = Mitosis.extract_delta ~config ~full_context:context ~since_len:2000 in
  check string "no new content returns empty" "" result

let test_extract_delta_noise_filter () =
  let config = { Mitosis.default_config with
    min_context_for_delta = 100;
    min_delta_len = 100;
    dna_compression_ratio = 1.0  (* No compression for test *)
  } in
  let context = String.make 200 'a' ^ "tiny" in
  let result = Mitosis.extract_delta ~config ~full_context:context ~since_len:200 in
  check string "tiny delta filtered as noise" "" result

(* ===== cell state tests ===== *)

let test_cell_state_to_string () =
  check string "stem" "stem" (Mitosis.state_to_string Mitosis.Stem);
  check string "active" "active" (Mitosis.state_to_string Mitosis.Active);
  check string "prepared" "prepared" (Mitosis.state_to_string Mitosis.Prepared);
  check string "dividing" "dividing" (Mitosis.state_to_string Mitosis.Dividing);
  check string "apoptotic" "apoptotic" (Mitosis.state_to_string Mitosis.Apoptotic)

let test_phase_to_string () =
  check string "idle" "idle" (Mitosis.phase_to_string Mitosis.Idle);
  check string "ready" "ready_for_handoff"
    (Mitosis.phase_to_string (Mitosis.ReadyForHandoff "dna"))

(* ===== Test suites ===== *)

let safe_sub_tests = [
  "normal", `Quick, test_safe_sub_normal;
  "negative start", `Quick, test_safe_sub_negative_start;
  "negative len", `Quick, test_safe_sub_negative_len;
  "start beyond len", `Quick, test_safe_sub_start_beyond_len;
  "len exceeds", `Quick, test_safe_sub_len_exceeds;
  "empty string", `Quick, test_safe_sub_empty_string;
]

(* ===== deduplicate_lines performance tests ===== *)

let test_dedup_large_input () =
  (* Generate large input: 10k base lines, 1k delta lines *)
  let make_lines n prefix =
    List.init n (fun i -> Printf.sprintf "%s line number %d with meaningful content" prefix i)
    |> String.concat "\n"
  in
  let base = make_lines 10000 "base" in
  let delta = make_lines 1000 "delta" in

  let start = Unix.gettimeofday () in
  let result = Mitosis.deduplicate_lines ~base ~delta in
  let elapsed = Unix.gettimeofday () -. start in

  (* All delta lines should be kept (no overlap with base) *)
  let result_lines = String.split_on_char '\n' result in
  check int "all delta lines kept" 1000 (List.length result_lines);

  (* Performance: should complete well under 1 second *)
  check bool "dedup 10k+1k lines under 0.5s" true (elapsed < 0.5);
  Printf.printf "[PERF] deduplicate_lines (10k+1k): %.4fs\n%!" elapsed

let test_dedup_with_overlap () =
  (* 50% overlap scenario *)
  let make_lines n prefix =
    List.init n (fun i -> Printf.sprintf "%s line number %d with content" prefix i)
    |> String.concat "\n"
  in
  let base = make_lines 1000 "shared" in
  let delta_unique = make_lines 500 "unique" in
  let delta_dup = make_lines 500 "shared" in  (* Same as base *)
  let delta = delta_dup ^ "\n" ^ delta_unique in

  let start = Unix.gettimeofday () in
  let result = Mitosis.deduplicate_lines ~base ~delta in
  let elapsed = Unix.gettimeofday () -. start in

  (* Only unique lines should remain (500) *)
  let result_lines = String.split_on_char '\n' result in
  check int "only unique lines kept" 500 (List.length result_lines);
  Printf.printf "[PERF] deduplicate_lines (1k+1k, 50%% overlap): %.4fs\n%!" elapsed

let test_dedup_empty_inputs () =
  let result1 = Mitosis.deduplicate_lines ~base:"" ~delta:"" in
  check string "empty both" "" result1;

  let result2 = Mitosis.deduplicate_lines ~base:"some base content here" ~delta:"" in
  check string "empty delta" "" result2;

  let result3 = Mitosis.deduplicate_lines ~base:"" ~delta:"some delta content" in
  check string "empty base" "some delta content" result3

let test_dedup_trailing_newlines () =
  let base = "line one here\nline two here\n" in
  let delta = "new line here\n" in
  let result = Mitosis.deduplicate_lines ~base ~delta in
  (* Should handle trailing newlines gracefully *)
  check bool "handles trailing newline" true (String.length result > 0)

let test_dedup_whitespace_only () =
  let base = "meaningful content here\n   \n\t\t\n" in
  let delta = "   \n\t\t\nnew content here" in
  let result = Mitosis.deduplicate_lines ~base ~delta in
  (* Whitespace-only lines (<=10 chars when trimmed) should be kept *)
  check bool "whitespace lines kept" true (String.length result > 0)

let dedup_tests = [
  "no overlap", `Quick, test_dedup_no_overlap;
  "full overlap", `Quick, test_dedup_full_overlap;
  "partial overlap", `Quick, test_dedup_partial_overlap;
  "short lines kept", `Quick, test_dedup_short_lines_kept;
]

let dedup_perf_tests = [
  "large input (10k+1k)", `Quick, test_dedup_large_input;
  "overlap scenario", `Quick, test_dedup_with_overlap;
  "empty inputs", `Quick, test_dedup_empty_inputs;
  "trailing newlines", `Quick, test_dedup_trailing_newlines;
  "whitespace only", `Quick, test_dedup_whitespace_only;
]

let compress_tests = [
  "ratio 10%", `Quick, test_compress_ratio;
  "ratio > 100%", `Quick, test_compress_ratio_over_100;
]

let two_phase_tests = [
  "prepare at 50%", `Quick, test_should_prepare_at_50;
  "no prepare below threshold", `Quick, test_should_not_prepare_below_threshold;
  "no re-prepare", `Quick, test_should_not_prepare_when_already_prepared;
  "handoff at 80%", `Quick, test_should_handoff_at_80;
  "no handoff at 60%", `Quick, test_should_not_handoff_at_60;
]

let auto_mitosis_tests = [
  "noaction at 30%", `Quick, test_auto_mitosis_noaction_low_ratio;
  "prepared at 55%", `Quick, test_auto_mitosis_prepared_at_threshold;
  "handoff at 85%", `Quick, test_auto_mitosis_handoff_at_threshold;
  "emergency handoff from idle", `Quick, test_auto_mitosis_handoff_from_idle;
]

let delta_tests = [
  "short session", `Quick, test_extract_delta_short_session;
  "no new content", `Quick, test_extract_delta_no_new_content;
  "noise filter", `Quick, test_extract_delta_noise_filter;
]

let state_tests = [
  "cell state to string", `Quick, test_cell_state_to_string;
  "phase to string", `Quick, test_phase_to_string;
]

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  run "Mitosis" [
    "safe_sub", safe_sub_tests;
    "deduplicate", dedup_tests;
    "deduplicate_perf", dedup_perf_tests;
    "compress", compress_tests;
    "2-phase", two_phase_tests;
    "auto_mitosis", auto_mitosis_tests;
    "delta", delta_tests;
    "state", state_tests;
  ]
