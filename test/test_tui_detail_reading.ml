open Alcotest
open Masc_tui_types
module Reading = Masc_tui_detail_reading

let state () =
  create_state ~workspace:"detail-reading-test" ~port:8935 ~refresh_interval:2. ()

let reading () = Reading.create ~title:"selected object" []

let test_selection_does_not_retarget_capture () =
  let state = state () in
  state.view <- Repositories;
  let captured = reading () in
  open_detail_reading state captured;
  state.repositories_cursor <- 7;
  check bool "capture owns keys" true (modal_owns_keys state);
  check bool "selection cannot replace captured source" true
    (match current_detail_reading state with Some held -> held == captured | None -> false);
  close_key_modals state;
  check bool "closed reader releases keys" false (modal_owns_keys state);
  check int "closing keeps underlying selection" 7 state.repositories_cursor

let test_workspace_revoke_cannot_resurrect_capture () =
  let state = state () in
  let old_authority = state.workspace_authority in
  open_detail_reading state (reading ());
  state.workspace_authority <- Workspace_authority 1;
  check bool "new workspace cannot read old capture" true
    (Option.is_none (current_detail_reading state));
  reconcile_detail_reading state;
  state.workspace_authority <- old_authority;
  check bool "returning does not reopen revoked capture" true
    (Option.is_none (current_detail_reading state))

let test_surface_change_releases_capture () =
  let state = state () in
  state.view <- Repositories;
  open_detail_reading state (reading ());
  state.view <- Config;
  reconcile_detail_reading state;
  state.view <- Repositories;
  check bool "capture cannot reopen on a later visit" true
    (Option.is_none (current_detail_reading state));
  check bool "hidden capture cannot own keys" false (modal_owns_keys state)

let test_navigation_normalizes_before_moving () =
  let held = Reading.move ~count:100 ~height:10 Reading.Last (reading ()) in
  let shrunk = Reading.move ~count:20 ~height:10 (Reading.By (-1)) held in
  check int "move from current bounds after resize" 9 (Reading.scroll ~count:20 ~height:10 shrunk);
  let last = Reading.move ~count:100 ~height:10 (Reading.By max_int) held in
  check int "large positive movement is bounded" 90 (Reading.scroll ~count:100 ~height:10 last);
  let first = Reading.move ~count:100 ~height:10 (Reading.By min_int) last in
  check int "large negative movement is bounded" 0 (Reading.scroll ~count:100 ~height:10 first)

let test_end_intent_survives_repreparation () =
  let held = Reading.move ~count:100 ~height:10 Reading.Last (reading ()) in
  check int "end stays selected when reflow expands the extent" 190
    (Reading.scroll ~count:200 ~height:10 held);
  (* Reflow can temporarily project one preparation notice. It must not
     replace the operator's last-edge intent with that notice's offset. *)
  let held = Reading.move ~count:1 ~height:10 Reading.Last held in
  let replaced = Reading.replace ~title:"same captured observation" [] held in
  check int "end follows the changed observation extent" 190
    (Reading.scroll ~count:200 ~height:10 replaced);
  let shorter = Reading.scroll ~count:20 ~height:10 replaced in
  check int "end also follows a shorter extent" 10 shorter;
  let moved = Reading.move ~count:200 ~height:10 (Reading.By (-1)) replaced in
  check int "relative navigation releases the end anchor" 189
    (Reading.scroll ~count:300 ~height:10 moved);
  let first = Reading.move ~count:300 ~height:10 Reading.First replaced in
  check int "first releases the end anchor" 0
    (Reading.scroll ~count:400 ~height:10 first);
  check int "a new capture does not inherit another capture's anchor" 0
    (Reading.scroll ~count:200 ~height:10 (reading ()))

let test_local_search_and_replacement () =
  let width=80 and height=1 in
  let prepared=Reading.replace_prepared ~title:"original" ~hints:"" ~width
    [Reading.Content "Pi\027[31mtch\027[0m";Content "other";Content "PITCH"] (reading ()) in
  let key key reading=match Reading.search_key ~width ~height ~key reading with
    | Some reading -> reading | None -> fail "search key not owned" in
  let held=key "/" prepared |> Reading.search_insert ~width ~height ~text:"pitch" in
  check int "styles do not interrupt the searchable content" 2 (Reading.search_count ~width held);
  check bool "query owns typed navigation letters" true (Reading.search_editing held);
  let held=key "enter" held in
  check bool "commit releases query input" false (Reading.search_editing held);
  let first=Reading.scroll ~count:3 ~height held in
  let next=key "n" held in
  check bool "next reaches a later match" true (Reading.scroll ~count:3 ~height next>first);
  let wrapped=key "n" next in
  check int "next wraps within this capture" first (Reading.scroll ~count:3 ~height wrapped);
  check int "previous reaches the last match" (Reading.scroll ~count:3 ~height next)
    (Reading.scroll ~count:3 ~height (key "N" wrapped));
  check int "old prepared rows are not searched at a new width" 0 (Reading.search_count ~width:40 held);
  let held=Reading.replace_prepared ~title:"same" ~hints:"" ~width:40
    [Reading.Content "pitch"] held in
  check int "same-source replacement keeps the query" 1 (Reading.search_count ~width:40 held);
  check (option string) "a new capture has no borrowed query" None (Reading.search_query (reading ()));
  let editing=key "/" next |> Reading.search_insert ~width ~height ~text:"esc밤" in
  let editing=key "backspace" editing in
  check (option string) "paste is text and erase removes one UTF8 scalar" (Some "esc")
    (Reading.search_query editing);
  let cancelled=key "esc" editing in
  check (option string) "cancel clears only the query" None (Reading.search_query cancelled);
  check string "cancel keeps the capture" "original" (Reading.title cancelled)

let test_section_authority_requires_complete_visibility () =
  let held = Reading.create_observation ~title:"relationships"
      [{heading="Selected"; body="sender and operation"};
       {heading="Other"; body="one\ntwo\nthree\nfour\nfive"}] in
  let visible = Reading.section_fully_visible ~width:80 ~height:4 ~index:0 in
  check bool "a complete section can supply a target" true (visible held);
  check bool "a partly visible section supplies no target" false
    (Reading.section_fully_visible ~width:80 ~height:2 ~index:0 held);
  let count = List.length (Reading.rows ~width:80 held) in
  let scrolled = Reading.move ~count ~height:4 Reading.Last held in
  check bool "a section outside the viewport supplies no target" false (visible scrolled);
  let prepared = Reading.replace_prepared ~title:"prepared" ~hints:"" ~width:80
      [Reading.Content "sender"] held in
  check bool "prepared text has no source-section authority" false (visible prepared);
  check bool "an absent section supplies no target" false
    (Reading.section_fully_visible ~width:80 ~height:4 ~index:2 held);
  check bool "zero content width supplies no target" false
    (Reading.section_fully_visible ~width:0 ~height:80 ~index:0 held);
  check bool "negative content width supplies no target" false
    (Reading.section_fully_visible ~width:(-1) ~height:80 ~index:0 held);
  let empty = Reading.create_observation ~title:"relationships"
      [{heading=""; body=""}] in
  check bool "even blank rows cannot supply a target at zero width" false
    (Reading.section_fully_visible ~width:0 ~height:4 ~index:0 empty);
  check bool "zero height supplies no target" false
    (Reading.section_fully_visible ~width:80 ~height:0 ~index:0 held);
  let narrow = Reading.create_observation ~title:"relationships"
      [{heading="A"; body="B"}; {heading="C"; body="밤"}] in
  check bool "another section's wide glyph does not revoke this section" true
    (Reading.section_fully_visible ~width:1 ~height:8 ~index:0 narrow);
  check bool "a wide body glyph clipped to one cell supplies no target" false
    (Reading.section_fully_visible ~width:1 ~height:8 ~index:1 narrow);
  check bool "the same glyph fits when two cells are available" true
    (Reading.section_fully_visible ~width:2 ~height:8 ~index:1 narrow);
  let emoji = Reading.create_observation ~title:"relationships"
      [{heading="👩‍💻"; body="x"}] in
  check bool "a clipped multi-scalar heading supplies no target" false
    (Reading.section_fully_visible ~width:1 ~height:8 ~index:0 emoji);
  check bool "a complete multi-scalar heading can supply a target" true
    (Reading.section_fully_visible ~width:2 ~height:8 ~index:0 emoji)

let () = run "detail reading ownership"
  [ "capture", [test_case "selection stays read-only" `Quick test_selection_does_not_retarget_capture;
                 test_case "workspace revoke" `Quick test_workspace_revoke_cannot_resurrect_capture;
                 test_case "surface revoke" `Quick test_surface_change_releases_capture];
    "navigation", [test_case "resize and edges" `Quick test_navigation_normalizes_before_moving;
                   test_case "end intent survives re-preparation" `Quick test_end_intent_survives_repreparation;
                   test_case "local search and replacement" `Quick test_local_search_and_replacement;
                   test_case "section visibility authority" `Quick test_section_authority_requires_complete_visibility] ]
