module Lane = Masc_tui_types.Browser_lane_view
open Lane

let expect message condition = if not condition then failwith message
let success = function Ok value -> value | Error detail -> failwith detail
let tab id title = `Assoc ["id", `Int id; "title", `String title;
                           "url", `String "https://example.org/"; "active", `Bool (id = 2)]
let firefox = { client_id = "11111111-1111-4111-8111-111111111111"; browser = Firefox }
let zen = { client_id = "22222222-2222-4222-8222-222222222222"; browser = Zen }
let pinned () = choose_client firefox { (create ()) with clients = [firefox; zen] }
let response ?(source="live") ?(client=firefox.client_id) ?(page_id=2) () =
  `Assoc ["ok", `Bool true; "data", `Assoc [
    "source", `String source; "clientId", (if source = "automation" then `Null else `String client); "elapsed_ms", `Float 12.5;
    "tabs", `List [tab 1 "first"; tab 2 "second"];
    "page", `Assoc ["tabId", `Int page_id; "title", `String "second";
      "url", `String "https://example.org/"; "text", `String "real page text";
      "chars", `Int 14; "truncated", `Bool false]]]

let loaded () =
  let view = { (pinned ()) with load = Loading (1, Read) } in
  accept ~generation:1 (decode (response ())) view

let test_read_and_selection () =
  let view = loaded () in
  expect "successful read selects returned page" (view.selected_tab = Some 2);
  let moved = select_tab 1 view in
  expect "next tab wraps" (moved.selected_tab = Some 1);
  expect "request carries selected tab"
    (request_body moved = `Assoc ["lane", `String "live"; "clientId", `String firefox.client_id; "tabId", `Int 1]);
  expect "previous tab wraps" ((select_tab (-1) moved).selected_tab = Some 2)

let test_refresh_rediscovers_tabs () =
  let previous = { (loaded ()) with load = Failed "selected tab closed" } in
  let retry = refresh previous in
  expect "explicit refresh rediscovers tabs without stale id"
    (request_body retry = `Assoc ["lane", `String "live"; "clientId", `String firefox.client_id]);
  expect "rediscovery retains previous content until reply" (retry.reading = previous.reading)

let test_stale_response () =
  let current = { (switch_source Automation (create ())) with load = Loading (4, Read) } in
  let late = accept ~generation:3 (decode (response ())) current in
  expect "old generation cannot replace new source" (late = current);
  let wrong_source = accept ~generation:4 (decode (response ())) current in
  expect "wrong source rejected" (match wrong_source.load with Failed _ -> true | _ -> false);
  expect "wrong source cannot publish content" (wrong_source.reading = None)

let test_session_generation () =
  List.iter (fun operation ->
    let view = { (create ()) with load = Loading (7, operation) } in
    expect "read cannot settle session or navigation operation"
      (accept ~generation:7 (decode (response ())) view = view))
    [Open_session; Close_session; Goto "https://example.org/?q=한글"; Screenshot 2]

let test_navigation_failure_recovery () =
  let url = "https://example.org/?q=한글" in
  let pending = { (switch_source Automation (create ())) with load = Loading (9, Goto url) } in
  let failed = fail_action "navigation failed" pending in
  expect "failed URL restored for editing" (failed.url_draft = Some url);
  expect "failure is visible and retry is possible"
    (failed.load = Failed "navigation failed" && not (busy failed))

let test_failed_refresh () =
  let previous = loaded () in
  let refreshed = accept ~generation:2 (Error "Firefox disconnected")
      { previous with load = Loading (2, Read) } in
  expect "failure stays visible" (refreshed.load = Failed "Firefox disconnected");
  expect "failure preserves last successful reading" (refreshed.reading = previous.reading)

let test_http_read_status_provenance () =
  expect "unread is distinct from failure" (read_status (create ()) = Unread);
  let ready = loaded () in
  expect "successful request records read ok" (read_status ready = Read_ok);
  expect "pending read does not report retained content as current success"
    (read_status { ready with load = Loading (2, Read) } = Reading);
  expect "session action has its own status"
    (read_status { ready with load = Loading (3, Open_session) } = Operating);
  expect "failed read overrides retained success"
    (read_status { ready with load = Failed "connection refused" } = Read_failed)

let test_operator_reader_context () =
  expect "browser context identifies source without keeper prerequisite"
    (context_label (switch_source Automation (create ())) =
     "Browser Lane · automation · Firefox page reader");
  expect "browser context identifies live source"
    (context_label (pinned ()) = "Browser Lane · live · Firefox page reader")

let test_source_switch () =
  let view = switch_source Automation { (loaded ()) with url_draft = Some "https://example.org" } in
  expect "switch clears content, selection and hidden URL input"
    (view.reading = None && view.selected_tab = None && view.url_draft = None);
  expect "live is the default" ((create ()).source = Live);
  expect "browser request only needs the source"
    (request_body (create ()) = `Assoc ["lane", `String "live"])

let test_malformed_response () =
  List.iter (fun json -> expect "malformed schema rejected" (Result.is_error (decode json)))
    [response ~source:"unknown" (); response ~page_id:99 ();
     `Assoc ["ok", `Bool true; "data", `Assoc []]];
  expect "server failure preserved"
    (decode (`Assoc ["ok", `Bool false; "error", `String "no Firefox session"]) = Error "no Firefox session")

let test_empty_tabs () =
  let reading = success (decode (`Assoc ["ok", `Bool true; "data", `Assoc [
    "source", `String "automation"; "clientId", `Null; "elapsed_ms", `Int 0;
    "tabs", `List []; "page", `Null]])) in
  expect "empty tab set is distinct from failure" (reading.tabs = [] && reading.page = None)

let screenshot_response ?(source="live") ?(client=firefox.client_id) ?(tab_id=2) ?(mime="image/png") () =
  `Assoc ["ok", `Bool true; "data", `Assoc [
    "source", `String source; "clientId", (if source = "automation" then `Null else `String client); "tabId", `Int tab_id; "title", `String "second";
    "url", `String "https://example.org/"; "mimeType", `String mime;
    "data", `String "UE5H"; "elapsed_ms", `Float 13.]]

let test_screenshot_ownership_and_draft () =
  let pending = { (loaded ()) with scroll = 3; url_draft = Some "https://example.org/?q=한글";
      load = Loading (8, Screenshot 2) } in
  let settled, screenshot = accept_screenshot ~generation:8 (decode_screenshot (screenshot_response ())) pending in
  expect "matching screenshot settles busy state" (not (busy settled) && Option.is_some screenshot);
  expect "screenshot never replaces source, selection or draft"
    (settled.reading = pending.reading && settled.selected_tab = pending.selected_tab
     && settled.scroll = 3 && settled.url_draft = pending.url_draft);
  expect "late screenshot cannot settle another operation"
    (accept_screenshot ~generation:7 (decode_screenshot (screenshot_response ())) pending = (pending, None));
  List.iter (fun response ->
    let failed, preview = accept_screenshot ~generation:8 (decode_screenshot response) pending in
    expect "wrong screenshot ownership is visible, no overlay" (match failed.load with Failed _ -> preview = None | _ -> false);
    expect "failure retains source and draft" (failed.reading = pending.reading && failed.url_draft = pending.url_draft))
    [screenshot_response ~source:"automation" (); screenshot_response ~tab_id:1 ()];
  let failed, preview = accept_screenshot ~generation:8 (Error "selected tab closed") pending in
  expect "closed tab failure does not fall back to active tab"
    (failed.selected_tab = Some 2 && failed.load = Failed "selected tab closed" && preview = None);
  expect "non-PNG payload rejected" (Result.is_error (decode_screenshot (screenshot_response ~mime:"image/jpeg" ())))

let test_client_connection_ownership () =
  let discover t = { t with load = Loading (20, Discover Read_after_discovery) } in
  let choose, read = accept_clients ~generation:20 (Ok [firefox; zen]) (discover (create ())) in
  expect "two clients require explicit choice, no read" (not read && choose.selected_client = None && choose.client_picker = Some 0 && read_status choose = Unread);
  let first, read = accept_clients ~generation:20 (Ok [firefox]) (discover (create ())) in
  expect "fresh singleton can be pinned" (read && first.selected_client = Some firefox);
  let old = { (loaded ()) with scroll = 8 } in
  let disconnected, read = accept_clients ~generation:20 (Ok [zen]) (discover old) in
  expect "missing pin never rebinds singleton with same tab ids"
    (not read && disconnected.selected_client = Some firefox && disconnected.selected_tab = None
     && disconnected.reading = None && disconnected.scroll = 0 && not (selected_client_available disconnected));
  let chosen = choose_client zen disconnected in
  expect "explicit client choice clears old tab state" (chosen.selected_tab = None && chosen.reading = None && chosen.scroll = 0);
  expect "new read pins only client, never old tab" (request_body chosen =
    `Assoc ["lane", `String "live"; "clientId", `String zen.client_id]);
  let pending = { chosen with load = Loading (22, Read) } in
  let wrong = accept ~generation:22 (decode (response ())) pending in
  expect "same tab id from another client is refused" (wrong.reading = None && match wrong.load with Failed _ -> true | _ -> false);
  let right = accept ~generation:22 (decode (response ~client:zen.client_id ())) pending in
  expect "selected client response accepted" (right.selected_tab = Some 2 && right.load = Idle);
  let capture = { right with load = Loading (23, Screenshot 2) } in
  let refused, image = accept_screenshot ~generation:23 (decode_screenshot (screenshot_response ())) capture in
  expect "same tab id screenshot from wrong client is refused" (image = None && match refused.load with Failed _ -> true | _ -> false);
  expect "late discovery cannot replace chosen client"
    (accept_clients ~generation:20 (Ok [firefox]) pending = (pending, false));
  expect "automation sends no native client ID" (request_body (switch_source Automation right) = `Assoc ["lane", `String "automation"])

let test_clients_decode () =
  let row id browser = `Assoc ["clientId", `String id; "browser", `String browser] in
  let envelope rows = `Assoc ["ok", `Bool true; "data", `Assoc ["clients", `List rows]] in
  expect "backend-normalized Zen identity preserved"
    (decode_clients (envelope [row zen.client_id "zen"]) = Ok [zen]);
  List.iter (fun rows -> expect "invalid client inventory rejected" (Result.is_error (decode_clients (envelope rows))))
    [[row "" "zen"]; [row zen.client_id "unknown"]; [row zen.client_id "zen"; row zen.client_id "firefox"]];
  let missing_id = `Assoc ["ok", `Bool true; "data", `Assoc [
    "source", `String "live"; "clientId", `Null; "elapsed_ms", `Int 0;
    "tabs", `List []; "page", `Null]] in
  expect "live responses require explicit client ID" (Result.is_error (decode missing_id))

let () =
  List.iter (fun (name, test) -> test (); Printf.printf "PASS %s\n%!" name)
    ["client connection ownership", test_client_connection_ownership;
     "client inventory contract", test_clients_decode;
     "screenshot ownership, draft and stale tab", test_screenshot_ownership_and_draft;
     "read and tab selection", test_read_and_selection;
     "closed-tab refresh recovery", test_refresh_rediscovers_tabs;
     "stale response and provenance", test_stale_response;
     "session generation", test_session_generation;
     "failed refresh preserves evidence", test_failed_refresh;
     "navigation failure preserves editable URL", test_navigation_failure_recovery;
     "HTTP read status provenance", test_http_read_status_provenance;
     "operator reader context", test_operator_reader_context;
     "source switch", test_source_switch;
     "malformed response", test_malformed_response;
     "empty tabs", test_empty_tabs]
