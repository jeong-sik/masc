(* One prefix, one place. Before this module the literal sat in four files and
   the two removers disagreed on the bare prefix -- these cases pin the answer
   the four call sites now share, including that disagreement's resolution. *)

let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let test_add_and_strip_are_inverse () =
  check_string "add then strip returns the name" "masc_status"
    (Tool_transport_prefix.strip (Tool_transport_prefix.add "masc_status"));
  check_string "add writes the wire spelling" "mcp__masc__masc_status"
    (Tool_transport_prefix.add "masc_status")
;;

let test_strip_leaves_an_unprefixed_name_alone () =
  check_string "no prefix" "masc_status" (Tool_transport_prefix.strip "masc_status");
  check_string "empty" "" (Tool_transport_prefix.strip "");
  (* Not a prefix hit: the underscores differ, and a substring match would
     wrongly treat this as one. *)
  check_string "near miss" "mcp_masc_status"
    (Tool_transport_prefix.strip "mcp_masc_status")
;;

let test_the_bare_prefix_is_not_a_tool_name () =
  (* The two removers this module replaced answered differently here: one
     returned the input, the other the empty string. Stripping to "" names no
     tool, so the input stands. *)
  check_string "bare prefix stands" "mcp__masc__"
    (Tool_transport_prefix.strip "mcp__masc__");
  check_bool "bare prefix still reads as prefixed" true
    (Tool_transport_prefix.has "mcp__masc__")
;;

let test_has_matches_only_at_the_start () =
  check_bool "prefixed" true (Tool_transport_prefix.has "mcp__masc__masc_status");
  check_bool "unprefixed" false (Tool_transport_prefix.has "masc_status");
  check_bool "prefix in the middle" false
    (Tool_transport_prefix.has "x_mcp__masc__masc_status")
;;

let () =
  Alcotest.run
    "tool-transport-prefix"
    [ ( "prefix"
      , [ Alcotest.test_case "add and strip are inverse" `Quick
            test_add_and_strip_are_inverse
        ; Alcotest.test_case "strip leaves an unprefixed name alone" `Quick
            test_strip_leaves_an_unprefixed_name_alone
        ; Alcotest.test_case "the bare prefix is not a tool name" `Quick
            test_the_bare_prefix_is_not_a_tool_name
        ; Alcotest.test_case "has matches only at the start" `Quick
            test_has_matches_only_at_the_start
        ] )
    ]
;;
