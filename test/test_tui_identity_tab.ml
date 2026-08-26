(** The Identity tab's numbering.

    The screen prints a number beside each provider and a keypress acts on
    that number. Both read [identity_connectable], and this is what says so:
    if one side ever filters differently the numbers stop naming what they
    appear to name, and an operator attaches the wrong Keeper to the wrong
    service. *)

let check = Alcotest.check

let declared ?tools id label =
  Masc_tui_types.Identity_declared
    { idp_id = id; idp_label = label; idp_tools = tools }

let unreadable id problem =
  Masc_tui_types.Identity_unreadable { idp_id = id; idp_problem = problem }

let ids providers =
  List.map fst (Masc_tui_types.identity_connectable providers)

let test_a_broken_declaration_does_not_take_a_number () =
  (* It is still shown -- an operator has to see why the provider they came
     for is missing -- but pressing 2 has to reach the second one that can
     actually be connected, not the broken one sitting between them. *)
  let providers =
    [ declared "atlassian" "Atlassian";
      unreadable "jira" "id does not match the file name";
      declared "slack" "Slack" ]
  in
  check (Alcotest.list Alcotest.string) "only what can be connected"
    [ "atlassian"; "slack" ] (ids providers)

let test_the_order_is_the_declared_order () =
  let providers = [ declared "b" "B"; declared "a" "A" ] in
  check (Alcotest.list Alcotest.string) "not re-sorted behind the screen's back"
    [ "b"; "a" ] (ids providers)

let test_nothing_connectable_is_not_an_error () =
  let providers = [ unreadable "jira" "unreadable" ] in
  check (Alcotest.list Alcotest.string) "no numbers to press" [] (ids providers)

(* ── when the tick stops asking ──────────────────────────────────────── *)

let login ~provider =
  {
    Masc_tui_types.ils_keeper = "attaching-fixture";
    ils_provider = provider;
    ils_label = "Whatever The Screen Calls It";
    ils_url = "https://auth.example.com/authorize?x=1";
  }

let test_a_login_lands_when_its_service_reports_tools () =
  let providers = [ declared ~tools:[ "getJiraIssue" ] "atlassian" "Atlassian" ] in
  check Alcotest.bool "landed" true
    (Masc_tui_types.identity_login_landed ~providers
       ~login:(login ~provider:"atlassian"))

let test_attached_with_no_tools_still_counts_as_landed () =
  (* A service can be attached and offer nothing. The login did happen, and
     a tick that kept asking would ask forever. *)
  let providers = [ declared ~tools:[] "atlassian" "Atlassian" ] in
  check Alcotest.bool "landed" true
    (Masc_tui_types.identity_login_landed ~providers
       ~login:(login ~provider:"atlassian"))

let test_not_attached_has_not_landed () =
  let providers = [ declared "atlassian" "Atlassian" ] in
  check Alcotest.bool "still waiting" false
    (Masc_tui_types.identity_login_landed ~providers
       ~login:(login ~provider:"atlassian"))

let test_another_service_landing_does_not_end_this_login () =
  (* Matched by id, not by the label a screen shows: a declaration is free
     to change what it is called. *)
  let providers =
    [ declared ~tools:[ "sendMessage" ] "slack" "Whatever The Screen Calls It" ]
  in
  check Alcotest.bool "this login is still outstanding" false
    (Masc_tui_types.identity_login_landed ~providers
       ~login:(login ~provider:"atlassian"))

(* ── the cursor, once the list outgrew the digits ───────────────────── *)

let test_the_cursor_names_a_provider () =
  let providers =
    [ declared "atlassian" "Atlassian";
      unreadable "jira" "unreadable";
      declared "slack" "Slack" ]
  in
  (* Indexes the connectable list, so the broken declaration in the middle
     does not shift what the second row means. *)
  check
    (Alcotest.option (Alcotest.pair Alcotest.string Alcotest.string))
    "the second connectable one"
    (Some ("slack", "Slack"))
    (Masc_tui_types.identity_cursor_provider ~providers 1)

let test_a_cursor_past_the_end_names_the_last_row () =
  (* A list that shrank under a cursor -- a declaration stopped reading, say
     -- answers from a row that is there rather than from none at all. *)
  let providers = [ declared "atlassian" "Atlassian" ] in
  check Alcotest.int "clamped" 0
    (Masc_tui_types.identity_cursor_clamped ~providers 7);
  check
    (Alcotest.option (Alcotest.pair Alcotest.string Alcotest.string))
    "still names something" (Some ("atlassian", "Atlassian"))
    (Masc_tui_types.identity_cursor_provider ~providers 7)

let test_nothing_connectable_names_nothing () =
  let providers = [ unreadable "jira" "unreadable" ] in
  check
    (Alcotest.option (Alcotest.pair Alcotest.string Alcotest.string))
    "no row to start" None
    (Masc_tui_types.identity_cursor_provider ~providers 0)

let test_the_provider_row_sits_below_the_preamble () =
  (* The key handler scrolls the pane to the line a provider is drawn on.
     Both sides read the preamble rather than counting it, so a line added
     to the header moves the cursor's target with it. *)
  let preamble = List.length (Masc_tui_types.identity_preamble ~keeper:"k") in
  check Alcotest.int "first provider" preamble
    (Masc_tui_types.identity_provider_line ~index:0);
  check Alcotest.int "fourth provider" (preamble + 3)
    (Masc_tui_types.identity_provider_line ~index:3)

let () =
  Alcotest.run "tui_identity_tab"
    [ ( "numbering",
        [ Alcotest.test_case "a broken declaration does not take a number"
            `Quick test_a_broken_declaration_does_not_take_a_number;
          Alcotest.test_case "the order is the declared order" `Quick
            test_the_order_is_the_declared_order;
          Alcotest.test_case "nothing connectable is not an error" `Quick
            test_nothing_connectable_is_not_an_error;
        ] );
      ( "the cursor",
        [ Alcotest.test_case "names a provider" `Quick
            test_the_cursor_names_a_provider;
          Alcotest.test_case "past the end names the last row" `Quick
            test_a_cursor_past_the_end_names_the_last_row;
          Alcotest.test_case "nothing connectable names nothing" `Quick
            test_nothing_connectable_names_nothing;
          Alcotest.test_case "a provider row sits below the preamble" `Quick
            test_the_provider_row_sits_below_the_preamble;
        ] );
      ( "when the tick stops asking",
        [ Alcotest.test_case "a login lands when its service reports tools"
            `Quick test_a_login_lands_when_its_service_reports_tools;
          Alcotest.test_case "attached with no tools still counts as landed"
            `Quick test_attached_with_no_tools_still_counts_as_landed;
          Alcotest.test_case "not attached has not landed" `Quick
            test_not_attached_has_not_landed;
          Alcotest.test_case "another service landing does not end this login"
            `Quick test_another_service_landing_does_not_end_this_login;
        ] );
    ]
