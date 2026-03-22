(** Tests for Tool_budget — token budget limiter for tool descriptions *)

module Tool_budget = Masc_mcp.Tool_budget
module Tool_catalog = Masc_mcp.Tool_catalog

let mk_schema name desc : Types.tool_schema =
  { name; description = desc; input_schema = `Assoc [] }

(* Helper: always returns 0 usage *)
let no_usage _ = 0

let essential_schema =
  mk_schema "masc_join" "Join the coordination room."

let standard_schema =
  mk_schema "masc_board_post" "Post a message to the board."

let full_schema =
  mk_schema "masc_risc_pipeline_status" "Get RISC pipeline status for advanced debugging."

let all_test_schemas = [ essential_schema; standard_schema; full_schema ]

let () =
  let open Alcotest in
  run "Tool_budget"
    [
      ( "estimate_tokens",
        [
          test_case "empty string returns 1" `Quick (fun () ->
              check int "min 1" 1 (Tool_budget.estimate_tokens ""));
          test_case "4 chars = 1 token" `Quick (fun () ->
              check int "4 chars" 1 (Tool_budget.estimate_tokens "abcd"));
          test_case "5 chars = 2 tokens" `Quick (fun () ->
              check int "5 chars" 2 (Tool_budget.estimate_tokens "abcde"));
          test_case "100 chars = 25 tokens" `Quick (fun () ->
              check int "100 chars" 25
                (Tool_budget.estimate_tokens (String.make 100 'x')));
        ] );
      ( "budget_zero",
        [
          test_case "budget=0 returns empty list" `Quick (fun () ->
              let result =
                Tool_budget.filter_by_budget ~budget_tokens:0
                  ~usage_counts:no_usage ~tool_schemas:all_test_schemas
              in
              check int "empty" 0 (List.length result));
        ] );
      ( "budget_unlimited",
        [
          test_case "budget=max_int returns all tools" `Quick (fun () ->
              let result =
                Tool_budget.filter_by_budget ~budget_tokens:max_int
                  ~usage_counts:no_usage ~tool_schemas:all_test_schemas
              in
              check int "all tools" 3 (List.length result));
        ] );
      ( "tier_priority",
        [
          test_case "Essential tier tools are included first" `Quick (fun () ->
              (* Budget enough for ~1 tool description only *)
              let budget = Tool_budget.estimate_tokens essential_schema.description in
              let result =
                Tool_budget.filter_by_budget ~budget_tokens:budget
                  ~usage_counts:no_usage ~tool_schemas:all_test_schemas
              in
              check int "one tool" 1 (List.length result);
              check string "essential first"
                "masc_join"
                (List.hd result).name);
          test_case "Essential before Standard before Full" `Quick (fun () ->
              (* Give enough budget for exactly 2 tools *)
              let budget =
                Tool_budget.estimate_tokens essential_schema.description
                + Tool_budget.estimate_tokens standard_schema.description
              in
              let result =
                Tool_budget.filter_by_budget ~budget_tokens:budget
                  ~usage_counts:no_usage ~tool_schemas:all_test_schemas
              in
              check int "two tools" 2 (List.length result);
              check string "first is essential"
                "masc_join"
                (List.nth result 0).name;
              check string "second is standard"
                "masc_board_post"
                (List.nth result 1).name);
        ] );
      ( "usage_frequency",
        [
          test_case "higher usage ranked first within same tier" `Quick (fun () ->
              let s1 = mk_schema "masc_board_post" "Post a message." in
              let s2 = mk_schema "masc_board_search" "Search the board." in
              let usage_counts name =
                if name = "masc_board_search" then 100
                else if name = "masc_board_post" then 5
                else 0
              in
              (* Budget for 1 tool only *)
              let budget = Tool_budget.estimate_tokens s1.description in
              let result =
                Tool_budget.filter_by_budget ~budget_tokens:budget
                  ~usage_counts ~tool_schemas:[ s1; s2 ]
              in
              check int "one tool" 1 (List.length result);
              check string "higher usage wins"
                "masc_board_search"
                (List.hd result).name);
        ] );
      ( "default_budget",
        [
          test_case "returns None when env var not set" `Quick (fun () ->
              (* In test env, the env var should not be set *)
              check bool "no budget" true
                (Tool_budget.default_budget () = None));
        ] );
    ]
