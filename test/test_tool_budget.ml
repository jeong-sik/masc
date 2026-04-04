(** Tests for Tool_budget — token budget limiter for tool descriptions *)

module Tool_budget = Masc_mcp.Tool_budget
let mk_schema name desc : Types.tool_schema =
  { name; description = desc; input_schema = `Assoc [] }

(* Helper: always returns 0 usage *)
let no_usage _ = 0

let schema_a =
  mk_schema "masc_join" "Join the coordination room."

let schema_b =
  mk_schema "masc_board_post" "Post a message to the board."

let schema_c =
  mk_schema "masc_risc_pipeline_status" "Get RISC pipeline status for advanced debugging."

let all_test_schemas = [ schema_a; schema_b; schema_c ]

let () =
  let open Alcotest in
  run "Tool_budget"
    [
      ( "estimate_tokens",
        [
          test_case "empty string returns 0" `Quick (fun () ->
              check int "empty" 0 (Tool_budget.estimate_tokens ""));
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
      ( "ordering",
        [
          test_case "ties fall back to name ordering" `Quick (fun () ->
              let s1 = mk_schema "masc_board_search" "Search the board." in
              let s2 = mk_schema "masc_board_post" "Post to the board." in
              let budget = Tool_budget.estimate_tokens s1.description in
              let result =
                Tool_budget.filter_by_budget ~budget_tokens:budget
                  ~usage_counts:no_usage ~tool_schemas:[ s1; s2 ]
              in
              check int "one tool" 1 (List.length result);
              check string "alphabetical tiebreaker"
                "masc_board_post"
                (List.hd result).name);
        ] );
      ( "usage_frequency",
        [
          test_case "higher usage ranked first" `Quick (fun () ->
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
      ( "p3_budget_audit",
        [
          test_case "no single tool description exceeds 500 tokens" `Quick (fun () ->
              let max_per_tool = 500 in
              let schemas = Masc_mcp.Config.raw_all_tool_schemas in
              let violations =
                List.filter_map
                  (fun (s : Types.tool_schema) ->
                    let tokens = Tool_budget.estimate_tokens s.description in
                    if tokens > max_per_tool then
                      Some (Printf.sprintf "%s: %d tokens" s.name tokens)
                    else None)
                  schemas
              in
              if violations <> [] then
                Alcotest.fail
                  (Printf.sprintf "P3 violation: %d tools exceed %d tokens:\n%s"
                     (List.length violations) max_per_tool
                     (String.concat "\n" violations)));
          test_case "public MCP surface total under 15K tokens" `Quick (fun () ->
              let max_total = 15000 in
              let schemas =
                Masc_mcp.Config.visible_tool_schemas () in
              let total =
                List.fold_left
                  (fun acc (s : Types.tool_schema) ->
                    acc + Tool_budget.estimate_tokens s.description)
                  0 schemas
              in
              if total > max_total then
                Alcotest.fail
                  (Printf.sprintf
                     "P3 violation: public surface total = %d tokens (limit %d)"
                     total max_total));
        ] );
    ]
