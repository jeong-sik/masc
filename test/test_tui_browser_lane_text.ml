module Lane = Masc_tui_types.Browser_lane_view

let () =
  let page : Lane.page = {
    tab_id = 1; title = "Discussion"; url = "https://example.org/discussion";
    text = "Alice\nFirst message\n\nBob\n두 번째 메시지\n"; chars = 44; truncated = false;
  } in
  let reading : Lane.reading = {
    tabs = [{ id = 1; title = "Discussion"; url = page.url; active = true }];
    page = Some page; source = Live; elapsed_ms = 1.;
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
