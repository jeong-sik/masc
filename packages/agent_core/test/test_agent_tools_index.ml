open Alcotest
open Agent_sdk

let make_tool ?(content = "ok") name =
  Tool.create
    ~name
    ~description:("desc:" ^ name ^ ":" ^ content)
    ~parameters:[]
    (fun _ -> Ok { Types.content; _meta = None })
;;

let tool_description = function
  | None -> None
  | Some (tool : Tool.t) -> Some tool.schema.description
;;

let legacy_find tools name =
  List.find_opt (fun (tool : Tool.t) -> String.equal tool.schema.name name) tools
;;

let check_lookup_matches_legacy tools name =
  let index = Agent_tools.build_index tools in
  check
    (option string)
    ("lookup " ^ name)
    (tool_description (legacy_find tools name))
    (tool_description (Agent_tools.find_in_index index name))
;;

let test_exact_lookup_matches_list_find () =
  let tools = [ make_tool "alpha"; make_tool "beta"; make_tool "gamma" ] in
  List.iter (check_lookup_matches_legacy tools) [ "alpha"; "beta"; "gamma"; "missing" ]
;;

let test_duplicate_exact_name_preserves_first_match () =
  let tools = [ make_tool ~content:"first" "dup"; make_tool ~content:"second" "dup" ] in
  let index = Agent_tools.build_index tools in
  match Agent_tools.find_in_index index "dup" with
  | None -> fail "expected dup"
  | Some tool ->
    check string "first duplicate wins" "desc:dup:first" tool.schema.description
;;

let test_case_variant_never_dispatches () =
  let tools = [ make_tool "READ_FILE" ] in
  let index = Agent_tools.build_index tools in
  check
    (option string)
    "case variant is not inferred"
    None
    (tool_description (Agent_tools.find_in_index index "read_file"))
;;

let test_user_tool_case_variant_does_not_fallback () =
  let tools = [ make_tool "mytool" ] in
  let index = Agent_tools.build_index tools in
  (match Agent_tools.find_in_index index "mytool" with
   | None -> fail "exact match should still work"
   | Some _ -> ());
  check
    (option string)
    "case-variant returns None for user tool"
    None
    (tool_description (Agent_tools.find_in_index index "MYTOOL"));
  check
    (option string)
    "title-cased variant returns None for user tool"
    None
    (tool_description (Agent_tools.find_in_index index "MyTool"))
;;

let test_user_tool_case_variant_does_not_dispatch_neighbor () =
  (* Stronger regression: a user tool is registered under its lowercase
     name. A title-case variant must return None, not silently dispatch
     the lowercase neighbor (which would alter tool identity and audit context). *)
  let tools = [ make_tool ~content:"lowercased" "fetcha" ] in
  let index = Agent_tools.build_index tools in
  check
    (option string)
    "uppercase variant of unregistered user tool returns None"
    None
    (tool_description (Agent_tools.find_in_index index "FetchA"))
;;

let () =
  run
    "Agent_tools_index"
    [ ( "lookup"
      , [ test_case
            "exact lookup matches list find"
            `Quick
            test_exact_lookup_matches_list_find
        ; test_case
            "duplicate exact name preserves first match"
            `Quick
            test_duplicate_exact_name_preserves_first_match
        ; test_case
            "case variant never dispatches"
            `Quick
            test_case_variant_never_dispatches
        ; test_case
            "user tool case variant does not fallback"
            `Quick
            test_user_tool_case_variant_does_not_fallback
        ; test_case
            "user tool case variant does not dispatch lowercase neighbor"
            `Quick
            test_user_tool_case_variant_does_not_dispatch_neighbor
        ] )
    ]
;;
