module Lane = Masc_tui_types.Browser_lane_view
open Lane

let expect message condition = if not condition then failwith message
let success = function Ok value -> value | Error detail -> failwith detail
let tab id title = `Assoc ["id", `Int id; "title", `String title;
                           "url", `String "https://example.org/"; "active", `Bool (id = 2)]
let response ?(source="live") ?(app="browser") ?(page_id=2) () =
  `Assoc ["ok", `Bool true; "data", `Assoc [
    "source", `String source; "app", `String app; "elapsed_ms", `Float 12.5;
    "tabs", `List [tab 1 "first"; tab 2 "second"];
    "page", `Assoc ["tabId", `Int page_id; "title", `String "second";
      "url", `String "https://example.org/"; "text", `String "real page text";
      "chars", `Int 14; "truncated", `Bool false]]]

let loaded () =
  let view = { (create Browser) with load = Loading (1, Read) } in
  accept ~generation:1 (decode (response ())) view

let test_read_and_selection () =
  let view = loaded () in
  expect "successful read selects returned page" (view.selected_tab = Some 2);
  let moved = select_tab 1 view in
  expect "next tab wraps" (moved.selected_tab = Some 1);
  expect "request carries selected tab"
    (request_body moved = `Assoc ["lane", `String "live"; "app", `String "browser"; "tabId", `Int 1]);
  expect "previous tab wraps" ((select_tab (-1) moved).selected_tab = Some 2)

let test_refresh_rediscovers_tabs () =
  let previous = { (loaded ()) with load = Failed "selected tab closed" } in
  let retry = refresh previous in
  expect "explicit refresh rediscovers tabs without stale id"
    (request_body retry = `Assoc ["lane", `String "live"; "app", `String "browser"]);
  expect "rediscovery retains previous content until reply" (retry.reading = previous.reading)

let test_stale_response () =
  let current = { (switch_source Automation (create Slack)) with load = Loading (4, Read) } in
  let late = accept ~generation:3 (decode (response ())) current in
  expect "old generation cannot replace new source/app" (late = current);
  let wrong_source = accept ~generation:4 (decode (response ())) current in
  expect "wrong source/app rejected" (match wrong_source.load with Failed _ -> true | _ -> false);
  expect "wrong source/app cannot publish content" (wrong_source.reading = None)

let test_session_generation () =
  List.iter (fun operation ->
    let view = { (create Browser) with load = Loading (7, operation) } in
    expect "read cannot settle session or navigation operation"
      (accept ~generation:7 (decode (response ())) view = view))
    [Open_session; Close_session; Goto "https://example.org/?q=한글"]

let test_failed_refresh () =
  let previous = loaded () in
  let refreshed = accept ~generation:2 (Error "Firefox disconnected")
      { previous with load = Loading (2, Read) } in
  expect "failure stays visible" (refreshed.load = Failed "Firefox disconnected");
  expect "failure preserves last successful reading" (refreshed.reading = previous.reading)

let test_source_switch () =
  let view = switch_source Automation { (loaded ()) with url_draft = Some "https://example.org" } in
  expect "switch clears content, selection and hidden URL input"
    (view.reading = None && view.selected_tab = None && view.url_draft = None);
  expect "live is the default" ((create Slack).source = Live);
  expect "Slack filter is explicit"
    (request_body (create Slack) = `Assoc ["lane", `String "live"; "app", `String "slack"])

let test_malformed_response () =
  List.iter (fun json -> expect "malformed schema rejected" (Result.is_error (decode json)))
    [response ~source:"unknown" (); response ~app:"unknown" (); response ~page_id:99 ();
     `Assoc ["ok", `Bool true; "data", `Assoc []]];
  expect "server failure preserved"
    (decode (`Assoc ["ok", `Bool false; "error", `String "no Firefox session"]) = Error "no Firefox session")

let test_empty_tabs () =
  let reading = success (decode (`Assoc ["ok", `Bool true; "data", `Assoc [
    "source", `String "automation"; "app", `String "slack"; "elapsed_ms", `Int 0;
    "tabs", `List []; "page", `Null]])) in
  expect "empty Slack tab set is distinct from failure" (reading.tabs = [] && reading.page = None)

let () =
  List.iter (fun (name, test) -> test (); Printf.printf "PASS %s\n%!" name)
    ["read and tab selection", test_read_and_selection;
     "closed-tab refresh recovery", test_refresh_rediscovers_tabs;
     "stale response and provenance", test_stale_response;
     "session generation", test_session_generation;
     "failed refresh preserves evidence", test_failed_refresh;
     "source switch and Slack filter", test_source_switch;
     "malformed response", test_malformed_response;
     "empty tabs", test_empty_tabs]
