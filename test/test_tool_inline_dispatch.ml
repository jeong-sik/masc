open Alcotest

let schema name description : Masc_domain.tool_schema =
  { name; description; input_schema = `Assoc [] }

let tool_names json =
  Yojson.Safe.Util.(
    json
    |> member "tools"
    |> to_list
    |> List.map (fun item -> item |> member "name" |> to_string))

let test_discover_tools_uses_bm25_ranking_not_substring_or () =
  let schemas =
    [
      schema "masc_room_read" "Read room messages and channel activity";
      schema "masc_file_read" "Read file contents from the workspace";
      schema "masc_worktree_create" "Create an isolated git branch workspace";
    ]
  in
  let json =
    Masc_mcp.Tool_inline_dispatch.For_testing.discover_tools_json
      ~query:"read file contents"
      ~limit:2
      schemas
  in
  match tool_names json with
  | first :: _ -> check string "best match" "masc_file_read" first
  | [] -> fail "expected at least one tool"

let test_discover_tools_returns_empty_for_unmatched_query () =
  let schemas =
    [
      schema "masc_room_read" "Read room messages and channel activity";
      schema "masc_file_read" "Read file contents from the workspace";
    ]
  in
  let json =
    Masc_mcp.Tool_inline_dispatch.For_testing.discover_tools_json
      ~query:"zzzzzzzz"
      ~limit:5
      schemas
  in
  check int "unmatched count" 0 (List.length (tool_names json))

let test_discover_tools_marks_bm25_scoring () =
  let schemas = [ schema "masc_file_read" "Read file contents" ] in
  let json =
    Masc_mcp.Tool_inline_dispatch.For_testing.discover_tools_json
      ~query:"file"
      ~limit:5
      schemas
  in
  check
    string
    "scoring"
    "bm25"
    Yojson.Safe.Util.(json |> member "scoring" |> to_string)

let () =
  run
    "tool_inline_dispatch"
    [
      ( "discover_tools",
        [
          test_case
            "BM25 ranks specific tool above substring hit"
            `Quick
            test_discover_tools_uses_bm25_ranking_not_substring_or;
          test_case
            "unmatched query returns empty"
            `Quick
            test_discover_tools_returns_empty_for_unmatched_query;
          test_case
            "response marks bm25 scoring"
            `Quick
            test_discover_tools_marks_bm25_scoring;
        ] );
    ]
;;
