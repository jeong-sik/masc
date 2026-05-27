open Alcotest

module Projection = Masc_mcp.Keeper_tool_name_projection

let contains needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  let rec loop i =
    if i + nlen > hlen
    then false
    else if String.sub haystack i nlen = needle
    then true
    else loop (i + 1)
  in
  loop 0
;;

let check_contains label needle text = check bool label true (contains needle text)
let check_not_contains label needle text = check bool label false (contains needle text)

let test_visible_public_alias_wins () =
  check
    (option string)
    "tool_execute projects to visible Execute"
    (Some "Execute")
    (Projection.model_name ~visible_tool_names:[ "Execute" ] "tool_execute");
  check
    (option string)
    "mcp-prefixed public Execute remains visible"
    (Some "Execute")
    (Projection.model_name ~visible_tool_names:[ "Execute" ] "mcp__masc__Execute");
  match
    Projection.resolve_model_name ~visible_tool_names:[ "tool_execute"; "Execute" ]
      "tool_execute"
  with
  | Use_public_name { public_name; internal_name } ->
    check string "public alias" "Execute" public_name;
    check string "internal handler" "tool_execute" internal_name
  | _ -> fail "expected visible public alias to win over visible internal name"
;;

let test_hidden_alias_reports_blocker () =
  check
    (option string)
    "hidden tool_execute has no model-callable name"
    None
    (Projection.model_name ~visible_tool_names:[ "ReadFile" ] "tool_execute");
  let text =
    Projection.render_reference
      ~context:Model_facing
      ~visible_tool_names:[ "ReadFile" ]
      "tool_execute"
  in
  check_contains "blocker text mentions no active schema name" "No active schema name" text;
  check_contains "blocker text mentions public alias" "Execute" text;
  check_contains "blocker text tells report" "Report the blocker" text
;;

let test_internal_audit_context_is_explicit () =
  let model_text =
    Projection.render_reference
      ~context:Model_facing
      ~visible_tool_names:[ "Execute" ]
      "tool_execute"
  in
  check string "model-facing context uses public alias" "Execute" model_text;
  let audit_text =
    Projection.render_reference
      ~context:Internal_audit
      ~visible_tool_names:[ "Execute" ]
      "tool_execute"
  in
  check string "audit context may name internal handler" "tool_execute" audit_text
;;

let test_unknown_name_does_not_gain_alias () =
  let text =
    Projection.render_reference
      ~context:Model_facing
      ~visible_tool_names:[ "Execute" ]
      "keeper_not_real"
  in
  check_contains "unknown guidance names unknown" "Unknown tool name keeper_not_real" text;
  check_not_contains "unknown guidance does not suggest Execute" "Use Execute" text
;;

let test_blocker_guidance_only_when_hidden () =
  check
    (option string)
    "visible alias has no blocker"
    None
    (Projection.blocker_guidance ~visible_tool_names:[ "Execute" ] "tool_execute");
  match Projection.blocker_guidance ~visible_tool_names:[ "ReadFile" ] "tool_execute" with
  | None -> fail "expected hidden alias blocker guidance"
  | Some text ->
    check_contains "blocker names internal subject" "tool_execute" text;
    check_contains "blocker lists public alias" "Execute" text
;;

let test_filter_model_visible_suggestions () =
  let result =
    Projection.filter_model_visible_suggestions
      [ "masc_status"
      ; "tool_execute"
      ; "Execute"
      ; "tool_search_files"
      ; "ReadFile"
      ; "tool_edit_file"
      ]
  in
  check int "public names preserved" 1 (List.length (List.filter (String.equal "Execute") result));
  check int "masc names preserved" 1 (List.length (List.filter (String.equal "masc_status") result));
  check int "ReadFile preserved" 1 (List.length (List.filter (String.equal "ReadFile") result));
  check bool "no tool_execute in output" false (List.exists (String.equal "tool_execute") result);
  check bool "no tool_search_files in output" false (List.exists (String.equal "tool_search_files") result);
  (* tool_search_files -> "SearchFiles", tool_edit_file -> "EditFile". *)
  check bool "tool_search_files mapped to SearchFiles" true
    (List.exists (String.equal "SearchFiles") result);
  check bool "tool_edit_file mapped to EditFile" true
    (List.exists (String.equal "EditFile") result)
;;

let test_public_alias_for_internal () =
  check (option string) "tool_execute -> Execute" (Some "Execute")
    (Projection.public_alias_for_internal "tool_execute");
  check (option string) "tool_search_files -> SearchFiles" (Some "SearchFiles")
    (Projection.public_alias_for_internal "tool_search_files");
  check (option string) "tool_edit_file -> EditFile" (Some "EditFile")
    (Projection.public_alias_for_internal "tool_edit_file");
  check (option string) "unknown -> None" None
    (Projection.public_alias_for_internal "keeper_not_real");
  check (option string) "public name -> None (not internal)" None
    (Projection.public_alias_for_internal "Execute")
;;

let () =
  run
    "keeper_tool_name_projection"
    [ ( "projection"
      , [ test_case "visible public alias wins" `Quick test_visible_public_alias_wins
        ; test_case "hidden alias reports blocker" `Quick test_hidden_alias_reports_blocker
        ; test_case "internal audit context is explicit" `Quick
            test_internal_audit_context_is_explicit
        ; test_case "unknown name does not gain alias" `Quick
            test_unknown_name_does_not_gain_alias
        ; test_case "blocker guidance only when hidden" `Quick
            test_blocker_guidance_only_when_hidden
        ; test_case "filter suggestions removes internal names" `Quick
            test_filter_model_visible_suggestions
        ; test_case "public alias for internal" `Quick
            test_public_alias_for_internal
        ] )
    ]
;;
