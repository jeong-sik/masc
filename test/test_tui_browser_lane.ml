module Lane = Masc_tui_types.Browser_lane_view
open Lane

let expect message condition = if not condition then failwith message
let success = function Ok value -> value | Error detail -> failwith detail
let tab id title = `Assoc ["id", `Int id; "title", `String title;
                           "url", `String "https://example.org/"; "active", `Bool (id = 2)]
let firefox = { client_id = "11111111-1111-4111-8111-111111111111"; browser = Firefox }
let zen = { client_id = "22222222-2222-4222-8222-222222222222"; browser = Zen }
let pinned () = choose_client firefox { (create ()) with clients = Some [firefox; zen] }
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

let test_raw_refresh_scroll_identity () =
  let initial = loaded () in
  let reading = success (decode (response ())) in
  let refresh previous returned =
    accept ~generation:20 (Ok returned)
      {initial with reading=previous;scroll=37;load=Loading (20,Read_refresh)} in
  expect "same raw page retains operator scroll"
    ((refresh (Some reading) reading).scroll=37);
  let changed_page = {reading with page=Option.map
    (fun (page : page) -> {page with url="https://example.org/new"}) reading.page} in
  expect "external navigation resets raw scroll"
    ((refresh (Some reading) changed_page).scroll=0);
  List.iter (fun previous ->
    expect "changed or absent prior identity resets raw scroll"
      ((refresh previous reading).scroll=0))
    [None;Some {reading with page=None};
     Some {reading with source=Automation;client_id=None};
     Some {reading with client_id=Some zen.client_id};
     Some {reading with page=Option.map (fun (page : page) -> {page with tab_id=1}) reading.page}];
  expect "missing returned page resets raw scroll"
    ((refresh (Some reading) {reading with page=None;tabs=[]}).scroll=0)

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
  expect "automation does not invent a browser brand"
    (browser_label (switch_source Automation (create ())) = Some "browser");
  expect "live Zen keeps the normalized server identity"
    (browser_label (choose_client zen { (create ()) with clients = Some [zen] }) = Some "Zen");
  expect "live with no browser chosen has no browser to name"
    (browser_label (create ()) = None);
  expect "browser context identifies source without keeper prerequisite"
    (context_label (switch_source Automation (create ())) =
     "Browser Lane · automation · browser page reader");
  expect "browser context identifies live source"
    (context_label (pinned ()) = "Browser Lane · live · Firefox page reader");
  expect "an unchosen browser is not read as a page reader's name"
    (context_label (create ()) = "Browser Lane · live · no browser")

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
    "data", `String "UE5H"; "viewport", `Assoc ["documentId",`String "fixture";
      "width",`Int 800;"height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0]; "elapsed_ms", `Float 13.]]

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
  let empty, read = accept_clients ~generation:20 (Ok []) (discover (create ())) in
  expect "empty successful discovery is a browser connection state"
    (not read && empty.load = No_browser && read_status empty = Browser_missing);
  expect "dismissing picker retains known connection absence"
    (read_status { empty with client_picker = None } = Browser_missing);
  let lost, read = accept_clients ~generation:20 (Ok []) (discover (loaded ())) in
  expect "disconnected selected client stays pinned without calling another browser"
    (not read && lost.selected_client = Some firefox && read_status lost = Browser_missing);
  let restored, read = accept_clients ~generation:20 (Ok [firefox]) (discover lost) in
  expect "same client can reconnect after empty discovery"
    (read && restored.selected_client = Some firefox && restored.load = Idle);
  let failed, read = accept_clients ~generation:20 (Error "HTTP 401") (discover (create ())) in
  expect "discovery errors stay errors, not missing-browser guidance"
    (not read && read_status failed = Read_failed && not (awaiting_browser failed));
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

(* The picker's empty row reads the list, not the failure: a discovery that
   failed has no list, and an empty one is an answer. *)
let test_picker_empty_row () =
  let discover t = { t with load = Loading (30, Discover Choose_client); clients = None } in
  let row = Masc_tui_types.browser_lane_picker_empty_line in
  expect "nothing asked yet is unread" (row (create ()) = Some Masc_tui_types.page_unread_note);
  expect "a discovery in flight waits"
    (row (discover (create ())) = Some "  Waiting for active connections\xe2\x80\xa6");
  let failed, _ = accept_clients ~generation:30 (Error "connection refused") (discover (create ())) in
  expect "a failed discovery holds no list" (failed.clients = None && listed_clients failed = []);
  expect "a failed discovery is not an empty one" (row failed = Some Masc_tui_types.page_failed_note);
  let empty, _ = accept_clients ~generation:30 (Ok []) (discover (create ())) in
  expect "an answered discovery with nothing in it says so"
    (row empty = Some "  No active native browser connections");
  let two, _ = accept_clients ~generation:30 (Ok [firefox; zen]) (discover (create ())) in
  expect "connections to offer need no empty row" (two.clients = Some [firefox; zen] && row two = None)

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

let test_visual_scroll_ownership () =
  let view = loaded () in
  let expected_url = "https://example.org/" in
  let shot = success (decode_screenshot (screenshot_response ())) in
  let action = Browser_lane.Scroll_at {point={x=0.5;y=0.5};viewport=shot.viewport;x=0;y=120} in
  let pending = { view with load = Loading (41, Viewport_pointer {tab_id=2;expected_url;action}) } in
  let body = viewport_request ~tab_id:2 ~expected_url ~action view in
  let fields = match body with `Assoc fields -> fields | _ -> failwith "not an object" in
  expect "scroll targets observed client, tab and URL"
    (List.assoc "clientId" fields = `String firefox.client_id
     && List.assoc "tabId" fields = `Int 2
     && List.assoc "expectedUrl" fields = `String expected_url);
  let ready, image = accept_screenshot ~generation:41 (Ok shot) pending in
  expect "successful scroll releases busy state and admits new frame" (ready.load = Idle && image = Some shot);
  let late, image = accept_screenshot ~generation:40 (Ok shot) pending in
  expect "late scroll frame cannot replace current request" (late = pending && image = None);
  let changed = { shot with url = "https://example.org/another-page" } in
  let refused, image = accept_screenshot ~generation:41 (Ok changed) pending in
  expect "navigation during scroll cannot masquerade as observed page"
    (not (busy refused) && image = None && read_status refused = Read_failed);
  let refreshing = { pending with load = Loading (41, Viewport_refresh {tab_id=2; expected_url}) } in
  let refused, image = accept_screenshot ~generation:41 (Ok changed) refreshing in
  expect "refresh never silently repins a different URL" (not (busy refused) && image = None);
  let refused, image = accept_screenshot ~generation:41 (Error "scroll outcome unknown") pending in
  expect "failed effect is surfaced without retry" (not (busy refused) && image = None);
  let switched = switch_source Automation pending in
  let same, image = accept_screenshot ~generation:41 (Ok shot) switched in
  expect "closed or switched visual mode rejects an old frame" (same = switched && image = None)

let test_visual_pointer_navigation () =
  let shot = match decode_screenshot (screenshot_response ()) with Ok shot -> shot | Error e -> failwith e in
  let action = Browser_lane.Click_at {point={x=0.5;y=0.5};viewport=shot.viewport} in
  let pending = {(loaded ()) with load=Loading (52,Viewport_pointer {
    tab_id=2;expected_url=shot.url;action})} in
  let next = {shot with url="https://example.org/channel"} in
  let settled,image = accept_screenshot ~generation:52 (Ok next) pending in
  expect "clicked link may navigate the same selected tab" (not (busy settled) && image=Some next);
  let wrong = {next with tab_id=3} in
  let _,image = accept_screenshot ~generation:52 (Ok wrong) pending in
  expect "pointer completion never switches target tab" (image=None)

let test_scoped_refresh_failure_retains_read_intent () =
  let target : Browser_lane.node_ref = {document_id="observed-document";node_id="region"} in
  let scene_json ~document_id ~view ~scope =
    `Assoc ["ok",`Bool true;"data",`Assoc [
      "source",`String "live";"clientId",`String firefox.client_id;
      "tabId",`Int 2;"elapsed_ms",`Float 1.;"schema",`String "masc.browser.scene.v1";
      "documentId",`String document_id;"url",`String "https://example.org/";
      "title",`String "Observed region";"view",`String view;"scope",scope;
      "truncated",`Bool false;
      "viewport",`Assoc ["width",`Float 800.;"height",`Float 600.;"scrollX",`Float 0.;"scrollY",`Float 0.];
      "nodes",`List [`Assoc ["nodeId",`String "region";"kind",`String "region";
        "role",`String "main";"tag",`String "main";"text",`String "Region";
        "rects",`List [`Assoc ["x",`Float 0.;"y",`Float 0.;"width",`Float 100.;"height",`Float 20.]];
        "color",`String "black";"fontSize",`Float 16.;"fontWeight",`String "400";
        "whiteSpace",`String "normal"]]]] in
  let scoped = success (decode_scene (scene_json ~document_id:target.document_id ~view:"content"
    ~scope:(`Assoc ["documentId",`String target.document_id;"nodeId",`String target.node_id]))) in
  let focus = Scene_focus {tab_id=2;target} in
  let initial = loaded () in
  let focused = accept_scene ~generation:80 (Ok scoped)
    {initial with load=Loading (80,focus);read_view=read_view_for_operation focus initial.read_view} in
  expect "focused decoded scene accepted" (focused.scene=Some scoped);
  let refresh = Scene_refresh {tab_id=2;scene_view=Browser_lane.Content;scope=Some target} in
  expect "focused cadence retains exact region" (cadence_operation focused=Some refresh);
  let pending = {focused with load=Loading (81,refresh);
    read_view=read_view_for_operation refresh focused.read_view;refresh_pending=Some 81} in
  expect "busy refresh cannot launch another cadence" (cadence_operation pending=None);
  let operator_owned = yield_refresh_to_input pending in
  expect "operator input can proceed while the read is pending" (not (busy operator_owned));
  expect "superseding a result does not stack periodic reads" (cadence_operation operator_owned=None);
  let superseded = accept_scene ~generation:81 (Error "late background failure") operator_owned in
  expect "late result keeps the operator observation" (superseded.scene=focused.scene && superseded.load=Idle);
  expect "actual completion releases cadence slot" (superseded.refresh_pending=None && cadence_operation superseded=Some refresh);
  let failed = accept_scene ~generation:81 (Error "transport unavailable") pending in
  expect "failed refresh withdraws stale action references" (failed.scene=None && selected_scene_target failed=None);
  expect "retry retains original scoped scene intent" (cadence_operation failed=Some refresh);
  expect "picker owns cadence" (cadence_operation {failed with client_picker=Some 0}=None);
  expect "URL draft owns cadence" (cadence_operation {failed with url_draft=Some "https://example.org/new"}=None);
  let new_map = success (decode_scene (scene_json ~document_id:"replacement-document" ~view:"regions" ~scope:`Null)) in
  let retry = {failed with load=Loading (82,refresh)} in
  let resolved = accept_scene ~generation:82 (Ok new_map) retry in
  expect "replacement document returns an observed region map" (resolved.scene=Some new_map);
  expect "next cadence follows resolved map instead of expired scope"
    (cadence_operation resolved=Some (Scene_refresh {tab_id=2;scene_view=Browser_lane.Regions;scope=None}))

let () =
  List.iter (fun (name, test) -> test (); Printf.printf "PASS %s\n%!" name)
    ["raw refresh scroll identity", test_raw_refresh_scroll_identity;
     "scoped refresh failure and region recovery", test_scoped_refresh_failure_retains_read_intent;
     "visual pointer navigation", test_visual_pointer_navigation;
     "visual scroll ownership", test_visual_scroll_ownership;
     "client connection ownership", test_client_connection_ownership;
     "picker empty row reads the list", test_picker_empty_row;
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
