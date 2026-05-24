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
    "keeper_bash projects to visible Bash"
    (Some "Bash")
    (Projection.model_name ~visible_tool_names:[ "Bash" ] "keeper_bash");
  match
    Projection.resolve_model_name ~visible_tool_names:[ "keeper_bash"; "Bash" ]
      "keeper_bash"
  with
  | Use_public_name { public_name; internal_name } ->
    check string "public alias" "Bash" public_name;
    check string "internal handler" "keeper_bash" internal_name
  | _ -> fail "expected visible public alias to win over visible internal name"
;;

let test_hidden_alias_reports_blocker () =
  check
    (option string)
    "hidden keeper_bash has no model-callable name"
    None
    (Projection.model_name ~visible_tool_names:[ "Read" ] "keeper_bash");
  let text =
    Projection.render_reference
      ~context:Model_facing
      ~visible_tool_names:[ "Read" ]
      "keeper_bash"
  in
  check_contains "blocker text mentions no active schema name" "No active schema name" text;
  check_contains "blocker text mentions public alias" "Bash" text;
  check_contains "blocker text tells report" "Report the blocker" text
;;

let test_internal_audit_context_is_explicit () =
  let model_text =
    Projection.render_reference
      ~context:Model_facing
      ~visible_tool_names:[ "Bash" ]
      "keeper_bash"
  in
  check string "model-facing context uses public alias" "Bash" model_text;
  let audit_text =
    Projection.render_reference
      ~context:Internal_audit
      ~visible_tool_names:[ "Bash" ]
      "keeper_bash"
  in
  check string "audit context may name internal handler" "keeper_bash" audit_text
;;

let test_unknown_name_does_not_gain_alias () =
  let text =
    Projection.render_reference
      ~context:Model_facing
      ~visible_tool_names:[ "Bash" ]
      "keeper_not_real"
  in
  check_contains "unknown guidance names unknown" "Unknown tool name keeper_not_real" text;
  check_not_contains "unknown guidance does not suggest Bash" "Use Bash" text
;;

let test_blocker_guidance_only_when_hidden () =
  check
    (option string)
    "visible alias has no blocker"
    None
    (Projection.blocker_guidance ~visible_tool_names:[ "Bash" ] "keeper_bash");
  match Projection.blocker_guidance ~visible_tool_names:[ "Read" ] "keeper_bash" with
  | None -> fail "expected hidden alias blocker guidance"
  | Some text ->
    check_contains "blocker names internal subject" "keeper_bash" text;
    check_contains "blocker lists public alias" "Bash" text
;;

let test_filter_model_visible_suggestions () =
  let result =
    Projection.filter_model_visible_suggestions
      [ "masc_status"; "keeper_bash"; "Bash"; "keeper_shell"; "Read"; "keeper_fs_edit" ]
  in
  check int "public names preserved" 1 (List.length (List.filter (String.equal "Bash") result));
  check int "masc names preserved" 1 (List.length (List.filter (String.equal "masc_status") result));
  check int "Read preserved" 1 (List.length (List.filter (String.equal "Read") result));
  check bool "no keeper_bash in output" false (List.exists (String.equal "keeper_bash") result);
  check bool "no keeper_shell in output" false (List.exists (String.equal "keeper_shell") result);
  (* keeper_shell → "Grep" (its public alias), keeper_fs_edit → "Edit" *)
  check bool "keeper_shell mapped to Grep" true (List.exists (String.equal "Grep") result);
  check bool "keeper_fs_edit mapped to Edit" true (List.exists (String.equal "Edit") result)
;;

let test_public_alias_for_internal () =
  check (option string) "keeper_bash → Bash" (Some "Bash")
    (Projection.public_alias_for_internal "keeper_bash");
  check (option string) "keeper_shell → Grep" (Some "Grep")
    (Projection.public_alias_for_internal "keeper_shell");
  check (option string) "keeper_fs_edit → Edit" (Some "Edit")
    (Projection.public_alias_for_internal "keeper_fs_edit");
  check (option string) "unknown → None" None
    (Projection.public_alias_for_internal "keeper_not_real");
  check (option string) "public name → None (not internal)" None
    (Projection.public_alias_for_internal "Bash")
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
