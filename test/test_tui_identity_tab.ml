(** The Identity tab's numbering.

    The screen prints a number beside each provider and a keypress acts on
    that number. Both read [identity_connectable], and this is what says so:
    if one side ever filters differently the numbers stop naming what they
    appear to name, and an operator attaches the wrong Keeper to the wrong
    service. *)

let check = Alcotest.check

let declared ?tools ?(also_on = []) ?enabled ?switch_problem id label =
  Masc_tui_types.Identity_declared
    { idp_id = id
    ; idp_label = label
    ; idp_tools = tools
    ; idp_also_on = also_on
    ; idp_enabled = enabled
    ; idp_switch_problem = switch_problem
    }

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
    (Masc_tui_types.identity_cursor_provider ~query:"" ~providers 1)

let test_a_cursor_past_the_end_names_the_last_row () =
  (* A list that shrank under a cursor -- a declaration stopped reading, say
     -- answers from a row that is there rather than from none at all. *)
  let providers = [ declared "atlassian" "Atlassian" ] in
  check Alcotest.int "clamped" 0
    (Masc_tui_types.identity_cursor_clamped ~query:"" ~providers 7);
  check
    (Alcotest.option (Alcotest.pair Alcotest.string Alcotest.string))
    "still names something" (Some ("atlassian", "Atlassian"))
    (Masc_tui_types.identity_cursor_provider ~query:"" ~providers 7)

let test_nothing_connectable_names_nothing () =
  let providers = [ unreadable "jira" "unreadable" ] in
  check
    (Alcotest.option (Alcotest.pair Alcotest.string Alcotest.string))
    "no row to start" None
    (Masc_tui_types.identity_cursor_provider ~query:"" ~providers 0)

let test_the_provider_row_sits_below_the_preamble () =
  (* The key handler scrolls the pane to the line a provider is drawn on.
     Both sides read the preamble rather than counting it, so a line added
     to the header moves the cursor's target with it. *)
  let preamble =
    List.length (Masc_tui_types.identity_preamble ~keeper:"k" ~notice:[])
  in
  check Alcotest.int "first provider" preamble
    (Masc_tui_types.identity_provider_line ~notice:[] ~index:0);
  check Alcotest.int "fourth provider" (preamble + 3)
    (Masc_tui_types.identity_provider_line ~notice:[] ~index:3)

let test_a_notice_pushes_the_list_down () =
  (* A refusal from one provider is drawn where the operator is looking,
     which is above the list. The row a keypress scrolls to has to move with
     it or the cursor lands on the wrong line by however tall the message
     is -- and the messages worth showing are the long ones. *)
  let notice = [ "first line"; "second line" ] in
  let bare = Masc_tui_types.identity_provider_line ~notice:[] ~index:0 in
  let with_notice = Masc_tui_types.identity_provider_line ~notice ~index:0 in
  check Alcotest.bool "the list starts lower" true (with_notice > bare);
  check Alcotest.int "by exactly the notice it was given"
    (bare + List.length notice) with_notice

let test_no_notice_reserves_no_room () =
  (* Nothing is held back for a message there is none of. A blank line kept
     "just in case" is a row the list is pushed down by on every screen that
     has nothing to report. *)
  check Alcotest.int "the hint and one blank, and that is all" 2
    (List.length (Masc_tui_types.identity_preamble ~keeper:"k" ~notice:[]))

(* ── typing to narrow the list ──────────────────────────────────────── *)

let sample =
  [ declared "googlesheets" "Google Sheets";
    declared "gmail" "Gmail";
    declared "linear" "Linear";
    unreadable "broken" "unreadable" ]

let matched query =
  List.map fst (Masc_tui_types.identity_connectable ~query sample)

let test_a_query_narrows_to_what_it_names () =
  check (Alcotest.list Alcotest.string) "both Google rows"
    [ "googlesheets"; "gmail" ] (matched "g");
  check (Alcotest.list Alcotest.string) "one of them" [ "googlesheets" ]
    (matched "sheet")

let test_the_id_is_searched_as_well_as_the_label () =
  (* The screen says "Google Sheets" and the tools are named
     "googlesheets_". An operator knows whichever one they know. *)
  check (Alcotest.list Alcotest.string) "found by its id" [ "googlesheets" ]
    (matched "googlesheets")

let test_case_does_not_matter () =
  check (Alcotest.list Alcotest.string) "typed lower, labelled upper"
    [ "linear" ] (matched "LINEAR")

let test_an_empty_query_is_the_whole_list () =
  check (Alcotest.list Alcotest.string) "everything connectable"
    [ "googlesheets"; "gmail"; "linear" ] (matched "")

let test_a_query_matching_nothing_is_not_an_error () =
  check (Alcotest.list Alcotest.string) "empty" [] (matched "zzz")

let test_the_cursor_indexes_what_is_left () =
  (* The number beside a row and the provider a keypress starts both come
     from the filtered list. If the cursor indexed the whole set, pressing
     enter on the second visible row would start whatever happens to be
     second overall. *)
  let at ~query index =
    Option.map fst
      (Masc_tui_types.identity_cursor_provider ~query ~providers:sample index)
  in
  (* Row three is Linear with no filter, and does not exist under "g" -- so
     the same index has to answer differently, and the filtered one clamps
     to the last row that is actually drawn. *)
  check (Alcotest.option Alcotest.string) "unfiltered, row three"
    (Some "linear") (at ~query:"" 2);
  check (Alcotest.option Alcotest.string) "filtered, clamped to the last one"
    (Some "gmail") (at ~query:"g" 2)

let test_the_filter_rows_say_how_much_is_left () =
  match
    Masc_tui_types.identity_filter_rows ~providers:sample (Some "g")
  with
  | [ line; "" ] ->
    let contains needle =
      Masc_tui_types.lowercase_contains ~needle line
    in
    check Alcotest.bool "the query is shown" true (contains "/g");
    check Alcotest.bool "and the count" true (contains "2 of 3")
  | rows ->
    Alcotest.failf "expected a line and a blank, got %d rows"
      (List.length rows)

let test_no_filter_takes_no_rows () =
  check Alcotest.int "nothing reserved" 0
    (List.length (Masc_tui_types.identity_filter_rows ~providers:sample None))

(* ── which other Keepers hold a service ─────────────────────────────── *)

let test_coverage_is_carried_per_provider () =
  (* A Keeper attaches on its own account, so "who else has this" is the one
     question this tab cannot answer from its own row -- and it is the answer
     that stops an operator consenting twice as the wrong account. *)
  let providers =
    [ declared ~also_on:[ "alpha"; "bravo" ] "atlassian" "Atlassian";
      declared "linear" "Linear" ]
  in
  let coverage id =
    List.find_map
      (function
        | Masc_tui_types.Identity_declared { idp_id; idp_also_on; _ }
          when String.equal idp_id id -> Some idp_also_on
        | Masc_tui_types.Identity_declared _
        | Masc_tui_types.Identity_unreadable _ -> None)
      providers
  in
  check
    (Alcotest.option (Alcotest.list Alcotest.string))
    "the two that have it"
    (Some [ "alpha"; "bravo" ])
    (coverage "atlassian");
  check
    (Alcotest.option (Alcotest.list Alcotest.string))
    "and none for the one nobody has" (Some []) (coverage "linear")

(* ── the app form ───────────────────────────────────────────────────── *)

let form field secret =
  { Masc_tui_types.iaf_provider = "slack"
  ; iaf_label = "Slack"
  ; iaf_field = field
  ; iaf_client_id = "an-app"
  ; iaf_client_secret = secret
  ; iaf_scopes = "chat:write"
  }

let test_the_secret_is_never_drawn () =
  (* A terminal scrolls back. A credential on screen is a credential in the
     scrollback, and in whatever recorded the session. *)
  let rows =
    Masc_tui_types.identity_app_form_rows
      (Some (form Masc_tui_types.App_client_secret "hunter2"))
  in
  let joined = String.concat "\n" rows in
  check Alcotest.bool "the value is nowhere" false
    (Masc_tui_types.lowercase_contains ~needle:"hunter2" joined);
  check Alcotest.bool "its length still shows" true
    (Masc_tui_types.lowercase_contains ~needle:"*******" joined)

let test_the_marker_is_on_the_field_taking_keys () =
  let marked field =
    Masc_tui_types.identity_app_form_rows (Some (form field ""))
    |> List.filter (fun row -> String.length row > 2 && row.[2] = '>')
    |> List.length
  in
  check Alcotest.int "exactly one row is marked" 1
    (marked Masc_tui_types.App_client_id);
  check Alcotest.int "and only one, whichever it is" 1
    (marked Masc_tui_types.App_scopes)

let test_a_closed_form_takes_no_rows () =
  check Alcotest.int "nothing reserved" 0
    (List.length (Masc_tui_types.identity_app_form_rows None))

(* ── what a paste carries into a field ──────────────────────────────── *)

let test_a_pasted_list_loses_its_newlines () =
  (* A scope list copied out of a browser arrives one per line. The
     terminal's own single-line helper is for drawing and turns a newline
     into the four characters "\x0A"; those were stored, sent to Slack
     inside a scope name, and came back as "Invalid permissions requested". *)
  check Alcotest.string "one line, single spaces"
    "chat:write files:read users:read"
    (Masc_tui_types.identity_field_paste
       "chat:write\nfiles:read\r\n  users:read\n")

let test_a_pasted_secret_loses_its_trailing_newline () =
  check Alcotest.string "nothing around it" "xoxp-abc123"
    (Masc_tui_types.identity_field_paste "  xoxp-abc123\n")

let test_a_paste_keeps_what_is_not_a_control_character () =
  (* Bytes at or above 0x80 are UTF-8, not control characters. *)
  check Alcotest.string "unharmed" "\xed\x95\x9c\xea\xb8\x80"
    (Masc_tui_types.identity_field_paste "\xed\x95\x9c\xea\xb8\x80")

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
          Alcotest.test_case "a notice pushes the list down" `Quick
            test_a_notice_pushes_the_list_down;
          Alcotest.test_case "no notice reserves no room" `Quick
            test_no_notice_reserves_no_room;
        ] );
      ( "which other Keepers hold a service",
        [ Alcotest.test_case "coverage is carried per provider" `Quick
            test_coverage_is_carried_per_provider;
        ] );
      ( "what a paste carries into a field",
        [ Alcotest.test_case "a pasted list loses its newlines" `Quick
            test_a_pasted_list_loses_its_newlines;
          Alcotest.test_case "a pasted secret loses its trailing newline"
            `Quick test_a_pasted_secret_loses_its_trailing_newline;
          Alcotest.test_case "a paste keeps what is not a control character"
            `Quick test_a_paste_keeps_what_is_not_a_control_character;
        ] );
      ( "the app form",
        [ Alcotest.test_case "the secret is never drawn" `Quick
            test_the_secret_is_never_drawn;
          Alcotest.test_case "the marker is on the field taking keys" `Quick
            test_the_marker_is_on_the_field_taking_keys;
          Alcotest.test_case "a closed form takes no rows" `Quick
            test_a_closed_form_takes_no_rows;
        ] );
      ( "typing to narrow the list",
        [ Alcotest.test_case "a query narrows to what it names" `Quick
            test_a_query_narrows_to_what_it_names;
          Alcotest.test_case "the id is searched as well as the label" `Quick
            test_the_id_is_searched_as_well_as_the_label;
          Alcotest.test_case "case does not matter" `Quick
            test_case_does_not_matter;
          Alcotest.test_case "an empty query is the whole list" `Quick
            test_an_empty_query_is_the_whole_list;
          Alcotest.test_case "a query matching nothing is not an error" `Quick
            test_a_query_matching_nothing_is_not_an_error;
          Alcotest.test_case "the cursor indexes what is left" `Quick
            test_the_cursor_indexes_what_is_left;
          Alcotest.test_case "the filter rows say how much is left" `Quick
            test_the_filter_rows_say_how_much_is_left;
          Alcotest.test_case "no filter takes no rows" `Quick
            test_no_filter_takes_no_rows;
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
