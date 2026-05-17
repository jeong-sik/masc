(** Tests for Keeper_goal_repair module. *)

let test_goal_title_of_purpose () =
  let open Alcotest in
  let module KGR = Masc_mcp.Keeper_goal_repair in
  let short = KGR.goal_title_of_purpose "do things" in
  check string "short" "do things (auto)" short;
  let empty = KGR.goal_title_of_purpose "" in
  check string "empty" "(unnamed keeper)" empty;
  let long = KGR.goal_title_of_purpose (String.make 200 'x') in
  check bool "long truncated" true (String.length long <= 130);
  let suffix_len = String.length "(auto)" in
  let ends_with_auto =
    String.length long >= suffix_len
    && String.sub long (String.length long - suffix_len) suffix_len = "(auto)"
  in
  check bool "long ends with (auto)" true ends_with_auto

let test_repair_source_to_string () =
  let open Alcotest in
  let module KGR = Masc_mcp.Keeper_goal_repair in
  check string "created" "created" (KGR.repair_source_to_string `Created);
  check string "reused"  "reused"  (KGR.repair_source_to_string `Reused)

let () =
  Alcotest.run "Keeper_goal_repair"
    [ ("goal_title_of_purpose",
       [ Alcotest.test_case "truncation" `Quick test_goal_title_of_purpose ]);
      ("repair_source",
       [ Alcotest.test_case "to_string" `Quick test_repair_source_to_string ])
    ]
