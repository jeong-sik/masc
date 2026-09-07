module Lane = Masc_tui_types.Browser_lane_view

let () =
  let page : Lane.page = {
    tab_id = 1; title = "Discussion"; url = "https://example.org/discussion";
    text = "Alice\nFirst message\n\nBob\n두 번째 메시지\n"; chars = 44; truncated = false;
  } in
  let reading : Lane.reading = {
    tabs = [{ id = 1; title = "Discussion"; url = page.url; active = true }];
    page = Some page; source = Live; client_id = Some "11111111-1111-4111-8111-111111111111"; elapsed_ms = 1.;
  } in
  let view = { (Lane.create ()) with reading = Some reading } in
  let lines = Masc_tui_types.browser_lane_page_lines ~cols:100 view in
  if lines <> ["Alice"; "First message"; ""; "Bob"; "두 번째 메시지"; ""] then
    failwith "Page paragraph boundaries, blank lines and trailing newline must survive projection";
  print_endline "PASS page multiline and blank-line projection"

let () =
  let draft = "https://example.org/discussion/" ^ String.make 100 'q' ^ "/한글" in
  let row = Masc_tui_types.browser_lane_url_line ~cols:80 draft in
  if not (String.ends_with ~suffix:"/한글▏" row) then
    failwith "long Unicode URL must keep the edited tail and caret visible";
  if Masc_tui_message_layout.display_width row > 76 then
    failwith "URL editor must fit the terminal content cells";
  print_endline "PASS long Unicode URL viewport"

let () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.view <- Keepers Keeper_message;
  state.search <- Some "retained search";
  state.composer_focused <- true;
  Buffer.add_string state.msg_input "unsent draft";
  show_browser_lane state;
  release_composer_for_browser_reader state;
  let view = Option.get state.browser_lane in
  state.browser_lane <- Some { view with scroll = 7; selected_tab = Some 42;
    load = Lane.Loading (9, Lane.Read) };
  hide_browser_lane state;
  assert (state.view = Keepers Keeper_message);
  assert (state.search = Some "retained search" && state.composer_focused);
  assert (Buffer.contents state.msg_input = "unsent draft");
  assert (browser_lane_on_screen state = None);
  (* A reply can settle while hidden without showing the reader or losing
     its scroll. It is the retained model's request, not the visible surface's. *)
  state.browser_lane <- Option.map (Lane.accept ~generation:9 (Error "offline"))
    state.browser_lane;
  show_browser_lane state;
  let restored = Option.get (browser_lane_on_screen state) in
  assert (restored.scroll = 7 && restored.selected_tab = Some 42);
  assert (restored.load = Lane.Failed "offline");
  (* Reopening while shown must keep the original return destination. *)
  show_browser_lane state;
  hide_browser_lane state;
  assert (state.view = Keepers Keeper_message);
  state.view <- Connectors;
  assert (browser_lane_on_screen state = None);
  show_browser_lane state;
  hide_browser_lane state;
  assert (state.view = Connectors && browser_lane_on_screen state = None);
  show_browser_lane state;
  leave_browser_lane_for_surface state Overview;
  state.view <- Overview;
  state.composer_focused <- true;
  leave_browser_lane_for_surface state Connectors;
  state.view <- Connectors;
  assert (browser_lane_on_screen state = None);
  assert state.composer_focused;
  print_endline "PASS reader hide/reopen, hidden reply, navigation, repeated open and draft ownership"
