let () =
  let open Masc_mcp.Keeper_relevance_check in
  let check_bool label expected got =
    if expected <> got then
      Alcotest.fail (Printf.sprintf "%s: expected %b, got %b" label expected got)
  in
  let check_float_approx label expected got =
    if Float.abs (expected -. got) > 0.01 then
      Alcotest.fail (Printf.sprintf "%s: expected %.2f, got %.2f" label expected got)
  in

  (* --- extract_keywords: basic tokenization --- *)
  let kws = extract_keywords "The quick brown fox jumps over the lazy dog" in
  assert (List.length kws >= 4);
  assert (List.mem "quick" kws);
  assert (List.mem "brown" kws);
  assert (List.mem "fox" kws);
  assert (List.mem "jumps" kws);
  (* stop words removed *)
  assert (not (List.mem "the" kws));
  assert (not (List.mem "over" kws));

  (* --- extract_keywords: deduplication --- *)
  let dup_kws = extract_keywords "test test test value value" in
  assert (List.length dup_kws = 2);

  (* --- extract_keywords: short tokens filtered --- *)
  let short_kws = extract_keywords "a b c de fg" in
  assert (List.length short_kws = 0 || (List.mem "de" short_kws && List.mem "fg" short_kws));

  (* --- extract_keywords: punctuation stripped --- *)
  let punct_kws = extract_keywords "hello, world! this-is_a test." in
  assert (List.mem "hello" punct_kws);
  assert (List.mem "world" punct_kws);
  assert (List.mem "test" punct_kws);

  (* --- extract_keywords: empty input --- *)
  let empty_kws = extract_keywords "" in
  assert (List.length empty_kws = 0);

  (* --- check: full coverage --- *)
  let full_result =
    check ~input_content:"deploy production server"
      ~reply_text:"I will deploy the production server now." ()
  in
  check_float_approx "full coverage" 1.0 full_result.coverage_ratio;
  check_bool "is_relevant full" true (is_relevant full_result);
  assert (List.length full_result.uncovered_keywords = 0);

  (* --- check: partial coverage --- *)
  let partial_result =
    check ~input_content:"deploy production server database migration"
      ~reply_text:"Starting the database migration now." ()
  in
  assert (partial_result.coverage_ratio > 0.0);
  assert (partial_result.coverage_ratio < 1.0);
  assert (List.mem "database" partial_result.covered_keywords);
  assert (List.mem "migration" partial_result.covered_keywords);
  assert (List.mem "deploy" partial_result.uncovered_keywords);
  assert (List.mem "production" partial_result.uncovered_keywords);

  (* --- check: zero coverage --- *)
  let zero_result =
    check ~input_content:"fix authentication token expiry bug"
      ~reply_text:"The weather is sunny today." ()
  in
  check_float_approx "zero coverage" 0.0 zero_result.coverage_ratio;
  check_bool "is_relevant zero" false (is_relevant zero_result);

  (* --- check: empty input → trivially relevant --- *)
  let empty_input_result =
    check ~input_content:""
      ~reply_text:"any response" ()
  in
  check_float_approx "empty input" 1.0 empty_input_result.coverage_ratio;
  check_bool "is_relevant empty input" true (is_relevant empty_input_result);

  (* --- check: empty reply --- *)
  let empty_reply_result =
    check ~input_content:"deploy production server"
      ~reply_text:"" ()
  in
  check_float_approx "empty reply" 0.0 empty_reply_result.coverage_ratio;
  check_bool "is_relevant empty reply" false (is_relevant empty_reply_result);

  (* --- is_relevant: threshold boundary --- *)
  let boundary_relevant =
    { input_keywords = ["a"; "b"; "c"]; covered_keywords = ["a"];
      uncovered_keywords = ["b"; "c"]; coverage_ratio = 0.333 }
  in
  check_bool "boundary 0.333 relevant" true (is_relevant boundary_relevant);

  let boundary_irrelevant =
    { input_keywords = ["a"; "b"; "c"; "d"]; covered_keywords = ["a"];
      uncovered_keywords = ["b"; "c"; "d"]; coverage_ratio = 0.25 }
  in
  check_bool "boundary 0.25 irrelevant" false (is_relevant boundary_irrelevant);

  print_endline "test_keeper_relevance_check: all passed"
