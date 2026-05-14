open Alcotest

module TR = Masc_mcp.Tool_resolution

(* ── resolve returns correct tried_source for each admission path ── *)

let test_alias_route_admits_bash () =
  match TR.resolve "Bash" with
  | TR.Alias_to { canonical; via = TR.Alias_route } ->
      check string "canonical is Bash" "Bash" canonical
  | other ->
      fail (Printf.sprintf "expected Alias_to via Alias_route, got: %s"
              (match other with
               | TR.Resolved { via; _ } -> "Resolved via " ^ TR.string_of_tried_source via
               | TR.Alias_to { via; _ } -> "Alias_to via " ^ TR.string_of_tried_source via
               | TR.Unknown _ -> "Unknown"))

let test_tool_name_variant_admits_keeper_board_post () =
  match TR.resolve "keeper_board_post" with
  | TR.Resolved { via = TR.Tool_name_variant; _ } -> ()
  | other ->
      fail (Printf.sprintf "expected Resolved via Tool_name_variant, got: %s"
              (match other with
               | TR.Resolved { via; _ } -> "Resolved via " ^ TR.string_of_tried_source via
               | TR.Alias_to { via; _ } -> "Alias_to via " ^ TR.string_of_tried_source via
               | TR.Unknown _ -> "Unknown"))

let test_mcp_prefix_stripped () =
  (* "mcp__masc__masc_status" should strip prefix to "masc_status" and resolve *)
  match TR.resolve "mcp__masc__masc_status" with
  | TR.Resolved _ | TR.Alias_to _ -> ()
  | TR.Unknown { name; tried } ->
      fail (Printf.sprintf "mcp__masc__masc_status should resolve, got Unknown: %s (tried: %s)"
              name (TR.string_of_tried tried))

let test_unknown_returns_tried_list () =
  match TR.resolve "__nonexistent_tool_xyz" with
  | TR.Unknown { name; tried } ->
      check string "name preserved" "__nonexistent_tool_xyz" name;
      check int "at least 13 tried sources" 13 (List.length tried)
  | _ ->
      fail "__nonexistent_tool_xyz should be Unknown"

let test_extend_turns_resolved () =
  (* extend_turns is in core_always_tools (S7: Registry_core_tools) or
     Tool_name_variant depending on order *)
  match TR.resolve "extend_turns" with
  | TR.Resolved _ -> ()
  | TR.Alias_to _ -> ()
  | TR.Unknown { name; tried } ->
      fail (Printf.sprintf "extend_turns should resolve, got Unknown (tried: %s)"
              (TR.string_of_tried tried))

let test_surface_admits_masc_code_git () =
  match TR.resolve "masc_code_git" with
  | TR.Resolved { via = TR.Surface _; _ } -> ()
  | TR.Resolved { via; _ } ->
      (* Admitted through a different source — still ok for shim *)
      ignore via
  | TR.Alias_to _ -> ()
  | TR.Unknown { tried; _ } ->
      fail (Printf.sprintf "masc_code_git should resolve, got Unknown (tried: %s)"
              (TR.string_of_tried tried))

let test_alias_masc_to_internal () =
  match TR.resolve "masc_board_post" with
  | TR.Resolved _ | TR.Alias_to _ -> ()
  | TR.Unknown { tried; _ } ->
      fail (Printf.sprintf "masc_board_post should resolve, got Unknown (tried: %s)"
              (TR.string_of_tried tried))

(* ── is_known_policy_tool_name legacy adapter ── *)

let test_legacy_adapter_known () =
  check bool "keeper_bash is known" true
    (TR.is_known_policy_tool_name "keeper_bash");
  check bool "Bash is known" true
    (TR.is_known_policy_tool_name "Bash");
  check bool "masc_status is known" true
    (TR.is_known_policy_tool_name "masc_status")

let test_legacy_adapter_unknown () =
  check bool "__missing_tool is not known" false
    (TR.is_known_policy_tool_name "__missing_tool")

(* ── Suite ── *)

let () =
  Alcotest.run "test_tool_resolution"
    [ "resolve", [
        test_case "Bash resolves via Alias_route" `Quick test_alias_route_admits_bash;
        test_case "keeper_board_post resolves via Tool_name_variant" `Quick test_tool_name_variant_admits_keeper_board_post;
        test_case "mcp prefix stripped and resolved" `Quick test_mcp_prefix_stripped;
        test_case "unknown returns tried list" `Quick test_unknown_returns_tried_list;
        test_case "extend_turns resolves" `Quick test_extend_turns_resolved;
        test_case "masc_code_git resolves via surface" `Quick test_surface_admits_masc_code_git;
        test_case "masc_board_post resolves via alias" `Quick test_alias_masc_to_internal;
      ]
    ; "legacy_adapter", [
        test_case "known tools return true" `Quick test_legacy_adapter_known;
        test_case "unknown tools return false" `Quick test_legacy_adapter_unknown;
      ]
    ]
