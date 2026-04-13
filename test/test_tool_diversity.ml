(** Test_tool_diversity — QCheck + Alcotest for Masc_mcp.Keeper_tool_diversity.

    Tests the information-theoretic invariants:
    1. Entropy is non-negative
    2. Entropy <= log2(N) for N categories
    3. Normalized entropy in [0, 1]
    4. Uniform distribution maximizes entropy
    5. Single-tool distribution has zero entropy *)

open Alcotest

(* ── Unit tests ──────────────────────────────────────────────── *)

let test_shannon_entropy_uniform () =
  let h = Masc_mcp.Keeper_tool_diversity.shannon_entropy [10; 10; 10; 10] in
  check (float 0.001) "log2(4) = 2.0" 2.0 h

let test_shannon_entropy_single () =
  let h = Masc_mcp.Keeper_tool_diversity.shannon_entropy [100] in
  check (float 0.001) "single tool = 0" 0.0 h

let test_shannon_entropy_empty () =
  let h = Masc_mcp.Keeper_tool_diversity.shannon_entropy [] in
  check (float 0.001) "empty = 0" 0.0 h

let test_normalized_uniform () =
  let raw = Masc_mcp.Keeper_tool_diversity.shannon_entropy [10; 10; 10; 10] in
  let h = Masc_mcp.Keeper_tool_diversity.normalized_entropy ~n_categories:4 raw in
  check (float 0.001) "uniform = 1.0" 1.0 h

let test_stats_of_registry () =
  let entries : (string * Masc_mcp.Keeper_types.tool_call_entry) list = [
    ("tool_a", { count = 50; successes = 45; failures = 5; last_used_at = 0.0 });
    ("tool_b", { count = 10; successes = 10; failures = 0; last_used_at = 0.0 });
  ] in
  let stats = Masc_mcp.Keeper_tool_diversity.stats_of_registry_entries entries in
  check int "two stats" 2 (List.length stats);
  let first = List.hd stats in
  check string "first name" "tool_a" first.name;
  check int "first count" 50 first.count

(* ── QCheck properties ───────────────────────────────────── *)

let int_list_gen ~min_len ~max_len ~min_val ~max_val =
  QCheck.Gen.(list_size (int_range min_len max_len) (int_range min_val max_val))
  |> QCheck.make

let qc_entropy_non_negative =
  QCheck.Test.make ~name:"entropy is non-negative"
    ~count:200
    (int_list_gen ~min_len:1 ~max_len:10 ~min_val:0 ~max_val:1000)
    (fun counts ->
      let h = Masc_mcp.Keeper_tool_diversity.shannon_entropy counts in
      h >= 0.0)

let qc_entropy_bounded =
  QCheck.Test.make ~name:"entropy <= log2(N)"
    ~count:200
    (int_list_gen ~min_len:2 ~max_len:20 ~min_val:1 ~max_val:100)
    (fun counts ->
      let h = Masc_mcp.Keeper_tool_diversity.shannon_entropy counts in
      let n = List.length counts in
      h <= Float.log2 (Float.of_int n) +. 0.001)

let qc_normalized_in_unit =
  QCheck.Test.make ~name:"normalized entropy in [0,1]"
    ~count:200
    (int_list_gen ~min_len:2 ~max_len:20 ~min_val:1 ~max_val:100)
    (fun counts ->
      let h = Masc_mcp.Keeper_tool_diversity.shannon_entropy counts in
      let n = List.length counts in
      let nh = Masc_mcp.Keeper_tool_diversity.normalized_entropy ~n_categories:n h in
      nh >= -0.001 && nh <= 1.001)

(* ── Test registration ──────────────────────────────────── *)

let () =
  run "Masc_mcp.Keeper_tool_diversity"
    [
      ( "unit",
        [
          test_case "shannon_entropy uniform" `Quick test_shannon_entropy_uniform;
          test_case "shannon_entropy single" `Quick test_shannon_entropy_single;
          test_case "shannon_entropy empty" `Quick test_shannon_entropy_empty;
          test_case "normalized uniform" `Quick test_normalized_uniform;
          test_case "stats_of_registry" `Quick test_stats_of_registry;
        ] );
      ( "qcheck",
        List.map QCheck_alcotest.to_alcotest
          [ qc_entropy_non_negative;
            qc_entropy_bounded;
            qc_normalized_in_unit ] );
    ]
