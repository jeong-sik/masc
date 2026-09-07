module Lane = Masc_tui_types.Browser_lane_view

let () =
  let page : Lane.page = {
    tab_id = 1; title = "Slack"; url = "https://app.slack.com/client/T/C";
    text = "Alice\nFirst message\n\nBob\n두 번째 메시지\n"; chars = 44; truncated = false;
  } in
  let reading : Lane.reading = {
    tabs = [{ id = 1; title = "Slack"; url = page.url; active = true }];
    page = Some page; source = Live; app = Slack; elapsed_ms = 1.;
  } in
  let view = { (Lane.create Slack) with reading = Some reading } in
  let lines = Masc_tui_types.browser_lane_page_lines ~cols:100 view in
  if lines <> ["Alice"; "First message"; ""; "Bob"; "두 번째 메시지"; ""] then
    failwith "Slack message boundaries, blank lines and trailing newline must survive projection";
  print_endline "PASS Slack multiline and blank-line projection"
