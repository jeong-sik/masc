module Lane = Masc_tui_types.Browser_lane_view
open Lane

let expect message condition = if not condition then failwith message
let success = function Ok value -> value | Error detail -> failwith detail
let tab id title = `Assoc ["id", `Int id; "title", `String title;
                           "url", `String "https://example.org/"; "active", `Bool (id = 2)]
let firefox = { client_id = "11111111-1111-4111-8111-111111111111"; browser = Firefox;
                transport = Browser_lane.Web_extension }
let zen = { client_id = "22222222-2222-4222-8222-222222222222"; browser = Zen;
            transport = Browser_lane.Web_extension }
let pinned () = choose_client firefox { (create ()) with clients = Some [firefox; zen] }
(* A connection list that came with no word of the BiDi host. *)
let found listed = { listed; bidi_host = Host_not_reported }

module Record = Masc.Browser_bidi_host_record
module Status = Masc.Browser_bidi_host_status

(* The BiDi connection of the host the record below names. *)
let bidi = { firefox with client_id = "33333333-3333-4333-8333-333333333333";
             transport = Browser_lane.Webdriver_bidi }
let host_entry : Record.entry =
  { pid = 4242; started_at = 1_791_000_000.; bidi_url = "ws://127.0.0.1:9222/session"
  ; client_id = success (Browser_lane.client_id_of_string bidi.client_id)
  ; attached_at = Some 1_791_000_002.; unacknowledged = []; ended = None }
let host_attach : Status.attach =
  { launcher = "/workspace/.masc/browser-lane/host/launch"
  ; arguments = "--bidi-url ws://127.0.0.1:PORT/session"
  ; standing = Status.Launcher_installed }
let host_report state : Status.report =
  { state; attach = host_attach; message = "the server's own sentence" }
let host state = Host_reported (host_report state)
let host_ending ?(reason = "stopped by SIGINT") session : Record.ending =
  { at = 1_791_000_060.; reason; session; because = Record.Reason_only }
let host_ended ?reason session =
  let ending = host_ending ?reason session in
  host (Record.Ended ({ host_entry with ended = Some ending }, ending))
let unacknowledged ?(cause = Record.Unconfirmed) ?(outcome = Record.Unknown)
    ?(verb = Some Masc.Browser_bidi_peer.Page_interact) at : Record.unacknowledged =
  { request_id = Record.request_id_of_wire "0199c0de-0000-4000-8000-0000000000a1"
  ; verb; outcome; cause; at }
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
  expect "previous tab wraps" ((select_tab (-1) moved).selected_tab = Some 2);
  let direct = select_tab_index 0 view in
  expect "direct tab index selects the observed first tab" (direct.selected_tab = Some 1);
  expect "direct tab index clears the old scene" (direct.scene = None && direct.scroll = 0);
  expect "direct tab index does not reload the current tab"
    (select_tab_index 1 view == view);
  expect "out of range direct tab index is inert"
    ((select_tab_index 8 view).selected_tab = view.selected_tab)

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

(* The viewport footer's drag hint is the lane table's answer for the
   connection the screenshot names: two live screenshots can differ. *)
let test_screenshot_drag_hint () =
  let bidi = { firefox with client_id = "33333333-3333-4333-8333-333333333333";
               transport = Browser_lane.Webdriver_bidi } in
  let view = { (create ()) with clients = Some [firefox; bidi] } in
  let shot ?(source="live") client = success (decode_screenshot (screenshot_response ~source ~client ())) in
  expect "an extension screenshot names the connection a drag needs"
    (screenshot_drag_support view (shot firefox.client_id) = Drag_needs [Browser_lane.Webdriver_bidi]
     && screenshot_drag_hint view (shot firefox.client_id) = "drag: needs a BiDi connection");
  expect "a BiDi screenshot takes the drag"
    (screenshot_drag_hint view (shot bidi.client_id) = "drag: move");
  expect "the chosen client answers when the list has not been read"
    (screenshot_drag_hint (choose_client bidi (create ())) (shot bidi.client_id) = "drag: move");
  expect "a client the view no longer holds is not given a rule"
    (screenshot_drag_support (create ()) (shot firefox.client_id) = Drag_unknown);
  expect "the server's own browser takes the drag"
    (screenshot_drag_hint (create ()) (shot ~source:"automation" firefox.client_id) = "drag: move")

(* What an 80-column terminal leaves a Browser Lane row inside the surface
   frame. The rows below are written to fit it. *)
let row_cells = Masc_tui_frame.inner_width ~cols:80
let cells = Masc_tui_message_layout.display_width
let test_pointer_decision () =
  let shot ?(source="live") client = success (decode_screenshot (screenshot_response ~source ~client ())) in
  let drag (shot : screenshot) =
    Browser_lane.Drag {from={x=0.1;y=0.1}; to_={x=0.2;y=0.2}; viewport=shot.viewport} in
  let click (shot : screenshot) = Browser_lane.Click_at {point={x=0.1;y=0.1}; viewport=shot.viewport} in
  let wheel (shot : screenshot) =
    Browser_lane.Scroll_at {point={x=0.5;y=0.5}; viewport=shot.viewport; x=0; y=120} in
  let sends view (shot : screenshot) action =
    pointer_decision view shot action
    = Pointer_send (Viewport_pointer {tab_id = shot.tab_id; expected_url = shot.url; action}) in
  let both = { (create ()) with clients = Some [firefox; bidi] } in
  let ended = host_ended Record.Session_left in
  let alone = { (create ()) with clients = Some [firefox]; bidi_host = ended } in
  let on_extension = shot firefox.client_id and on_bidi = shot bidi.client_id in
  let unserved ?(host = Host_not_reported) serving_listed =
    {asked = Browser_lane.Web_extension; capability = Browser_lane.Trusted_drag; serving_listed; host} in
  expect "a drag on the extension is not sent, and a listed BiDi connection is known"
    (pointer_decision both on_extension (drag on_extension) = Pointer_unserved (unserved true));
  expect "with no BiDi connection listed the decision says so, with what was known of the host"
    (pointer_decision alone on_extension (drag on_extension)
     = Pointer_unserved (unserved ~host:ended false));
  expect "a point click and a wheel notch are sent on either connection"
    (List.for_all (fun (shot : screenshot) ->
       sends both shot (click shot) && sends both shot (wheel shot))
       [on_extension; on_bidi]);
  expect "a drag is sent on BiDi" (sends both on_bidi (drag on_bidi));
  let automation = shot ~source:"automation" firefox.client_id in
  expect "the server's own browser answers for itself" (sends both automation (drag automation));
  expect "a connection the view no longer holds is left to the server"
    (sends (create ()) on_extension (drag on_extension));
  let busy_view = { both with load = Loading (3, Read) } in
  expect "a request in flight consumes the gesture, served or not"
    (pointer_decision busy_view on_extension (drag on_extension) = Pointer_consumed
     && pointer_decision busy_view on_bidi (click on_bidi) = Pointer_consumed)

(* A refused gesture says what was not sent and the next step, on two rows
   at most, each of this file's own words. It is not a failed read: the read
   state stays, a background refresh does not erase it, and the next input
   does. *)
let test_unserved_gesture () =
  let drag_unserved ?(serving_listed = false) host =
    {asked = Browser_lane.Web_extension; capability = Browser_lane.Trusted_drag; serving_listed; host} in
  let not_listed = "Not sent · WebExtension: no drag · no BiDi connection is listed" in
  let says name unserved rows =
    let drawn = unserved_gesture_rows unserved in
    if drawn <> rows then failwith (name ^ ":\n" ^ String.concat "\n" drawn) in
  says "with a serving connection listed the next step is the picker"
    (drag_unserved ~serving_listed:true Host_not_reported)
    ["Not sent · WebExtension: no drag · BiDi serves it · b:choose browser"];
  says "with none listed and no word of the host, the next step is where attaching is written"
    (drag_unserved Host_not_reported)
    [not_listed; "Setup: " ^ Browser_lane.live_transport_setup_doc Browser_lane.Webdriver_bidi];
  (* With a report, the second row says where the host stood and sends the
     operator to the picker, which has the room for the rest. *)
  List.iter (fun (name, host, row) -> says name (drag_unserved host) [not_listed; row])
    [ "no host has run", host Record.Never_started,
      "BiDi host: none has run for this workspace · b:how to attach"
    ; "a host that ended", host_ended Record.Session_left,
      "BiDi host: ended 2026-10-03T04:01:00Z · b:why and what next"
    ; "a host that left no reason", host (Record.Died host_entry),
      "BiDi host: pid 4242 is gone, no reason recorded · b:what next"
    (* The gesture was refused for want of a listed BiDi connection, so a
       host that runs is one this server does not list. *)
    ; "a host this server does not list", host (Record.Running host_entry),
      "BiDi host: pid 4242 attached, not listed by this server · b:details"
    ; "a host still connecting", host (Record.Running { host_entry with attached_at = None }),
      "BiDi host: pid 4242 is connecting · b:details"
    ; "a running host with no readable record",
      host (Record.Unreadable { detail = "written as layout 2"; held = Some true }),
      "BiDi host: one runs, and its record cannot be read · b:details"
    ; "no host and no readable record",
      host (Record.Unreadable { detail = "torn"; held = Some false }),
      "BiDi host: none runs, and the last record cannot be read · b:details"
    ; "a lock that could not be asked",
      host (Record.Unreadable { detail = "Too many open files"; held = None }),
      "BiDi host: could not check whether one runs · b:details"
    ; "a report this TUI cannot read", Host_report_unreadable { detail = "no state"; message = None },
      "BiDi host: this TUI cannot read the server's report · b:details" ];
  says "a gesture BiDi does not serve says nothing of the BiDi host"
    {asked = Browser_lane.Webdriver_bidi; capability = Browser_lane.Tab_activation; serving_listed = false;
     host = host_ended Record.Session_left}
    ["Not sent · BiDi: no tab switch · no WebExtension connection is listed";
     "Setup: " ^ Browser_lane.live_transport_setup_doc Browser_lane.Web_extension];
  says "with a serving connection listed the host is not spoken of"
    (drag_unserved ~serving_listed:true (host (Record.Running host_entry)))
    ["Not sent · WebExtension: no drag · BiDi serves it · b:choose browser"];
  (* Nothing another program wrote is in these rows: a reason of any length
     and with any bytes leaves them as they are. *)
  let hostile = "A\027[2J\nINJECTED " ^ String.make 400 'x' in
  says "a host's own words are not in the rows of a refused gesture"
    (drag_unserved (host_ended ~reason:hostile Record.Session_left))
    [not_listed; "BiDi host: ended 2026-10-03T04:01:00Z · b:why and what next"];
  List.iter (fun host ->
  List.iter (fun asked ->
    List.iter (fun capability ->
      if not (Browser_lane.live_transport_serves asked capability) then
        List.iter (fun serving_listed ->
          let rows = unserved_gesture_rows {asked; capability; serving_listed; host} in
          expect "a refused gesture never takes more than two rows" (List.length rows <= 2);
          List.iter (fun row ->
            expect ("a refused gesture's row fits 80 columns: " ^ row) (cells ("  " ^ row) <= row_cells))
            rows)
          [true; false])
      Browser_lane.all_of_live_capability)
    Browser_lane.all_of_live_transport)
    [Host_not_reported; host Record.Never_started;
     host (Record.Running { host_entry with pid = 4_194_304 });
     host (Record.Running { host_entry with pid = 4_194_304; attached_at = None });
     host_ended Record.Session_unknown; host (Record.Died { host_entry with pid = 4_194_304 });
     host (Record.Unreadable { detail = "torn"; held = Some true });
     host (Record.Unreadable { detail = "torn"; held = Some false });
     host (Record.Unreadable { detail = "torn"; held = None });
     Host_report_unreadable { detail = "no state"; message = Some "the server's paragraph" }];
  let ready = loaded () in
  let unserved = drag_unserved (host_ended Record.Session_left) in
  let refused = refuse_gesture unserved ready in
  expect "a refused gesture is not a failed read"
    (refused.load = ready.load && read_status refused = Read_ok && not (busy refused));
  expect "the background refresh keeps running" (cadence_operation refused = Some Read_refresh);
  let refreshed = accept ~generation:5 (decode (response ()))
      { refused with load = Loading (5, Read_refresh) } in
  expect "a refresh that lands leaves the refusal on screen"
    (refreshed.load = Idle && refreshed.unserved_gesture = Some unserved);
  (* The rows say why the gesture was not sent when it was not: what is
     learned of the host afterwards does not rewrite them. *)
  let later = { refreshed with bidi_host = host (Record.Running host_entry) } in
  expect "a later word of the host leaves the refusal as it was said"
    (unserved_rows later
     = [not_listed; "BiDi host: ended 2026-10-03T04:01:00Z · b:why and what next"]);
  expect "a view with nothing refused draws no such rows" (unserved_rows ready = []);
  expect "the next input withdraws it"
    ((withdraw_unserved_gesture refreshed).unserved_gesture = None);
  expect "choosing a connection or finishing an action leaves no refusal about the old one"
    ((choose_client zen refreshed).unserved_gesture = None
     && (after_action refreshed).unserved_gesture = None
     && (switch_source Automation refreshed).unserved_gesture = None);
  expect "an input with nothing refused changes nothing"
    (withdraw_unserved_gesture ready == ready)

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
  let empty, read = accept_clients ~generation:20 (Ok (found [])) (discover (create ())) in
  expect "empty successful discovery is a browser connection state"
    (not read && empty.load = No_browser && read_status empty = Browser_missing);
  expect "dismissing picker retains known connection absence"
    (read_status { empty with client_picker = None } = Browser_missing);
  let lost, read = accept_clients ~generation:20 (Ok (found [])) (discover (loaded ())) in
  expect "disconnected selected client stays pinned without calling another browser"
    (not read && lost.selected_client = Some firefox && read_status lost = Browser_missing);
  let restored, read = accept_clients ~generation:20 (Ok (found [firefox])) (discover lost) in
  expect "same client can reconnect after empty discovery"
    (read && restored.selected_client = Some firefox && restored.load = Idle);
  let failed, read = accept_clients ~generation:20 (Error "HTTP 401") (discover (create ())) in
  expect "discovery errors stay errors, not missing-browser guidance"
    (not read && read_status failed = Read_failed && not (awaiting_browser failed));
  let choose, read = accept_clients ~generation:20 (Ok (found [firefox; zen])) (discover (create ())) in
  expect "two clients require explicit choice, no read" (not read && choose.selected_client = None && choose.client_picker = Some 0 && read_status choose = Unread);
  let first, read = accept_clients ~generation:20 (Ok (found [firefox])) (discover (create ())) in
  expect "fresh singleton can be pinned" (read && first.selected_client = Some firefox);
  let old = { (loaded ()) with scroll = 8 } in
  let disconnected, read = accept_clients ~generation:20 (Ok (found [zen])) (discover old) in
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
    (accept_clients ~generation:20 (Ok (found [firefox])) pending = (pending, false));
  expect "automation sends no native client ID" (request_body (switch_source Automation right) = `Assoc ["lane", `String "automation"])
  ;
  expect "stagehand sends its lane and no native client ID"
    (request_body (switch_source Stagehand right) = `Assoc ["lane", `String "stagehand"])

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
  let empty, _ = accept_clients ~generation:30 (Ok (found [])) (discover (create ())) in
  expect "an answered discovery with nothing in it says so"
    (row empty = Some "  No active native browser connections");
  let two, _ = accept_clients ~generation:30 (Ok (found [firefox; zen])) (discover (create ())) in
  expect "connections to offer need no empty row" (two.clients = Some [firefox; zen] && row two = None)

let test_clients_decode () =
  let row ?(transport="web_extension") id browser =
    `Assoc ["clientId", `String id; "browser", `String browser; "transport", `String transport] in
  let envelope rows = `Assoc ["ok", `Bool true; "data", `Assoc ["clients", `List rows]] in
  expect "backend-normalized Zen identity preserved"
    (decode_clients (envelope [row zen.client_id "zen"]) = Ok [zen]);
  let bidi = {firefox with client_id=zen.client_id; transport=Browser_lane.Webdriver_bidi} in
  let clients = success (decode_clients (envelope
    [row firefox.client_id "firefox"; row ~transport:"webdriver_bidi" bidi.client_id "firefox"])) in
  expect "same Firefox retains two distinct transports" (clients = [firefox; bidi]);
  expect "picker identifies the extension connection"
    (browser_choice_label (Connected_browser firefox) = "Firefox · WebExtension · existing login · " ^ firefox.client_id);
  expect "picker identifies the trusted hover connection"
    (browser_choice_label (Connected_browser bidi) = "Firefox · BiDi · existing login · " ^ bidi.client_id);
  List.iter (fun rows -> expect "invalid client inventory rejected" (Result.is_error (decode_clients (envelope rows))))
    [[row "" "zen"]; [row zen.client_id "unknown"]; [row zen.client_id "zen"; row zen.client_id "firefox"];
     [row ~transport:"unknown" firefox.client_id "firefox"];
     [`Assoc ["clientId", `String firefox.client_id; "browser", `String "firefox"]]];
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
        "whiteSpace",`String "normal";"sourceContext",`Null]]]] in
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

let test_unified_browser_picker () =
  expect "server browsers stay selectable without native clients"
    (browser_choices (create ()) = [Stagehand_browser; Automation_browser]);
  let current = { (loaded ()) with scroll = 8; client_picker = Some 0 } in
  let same = choose_browser (Connected_browser firefox) current in
  expect "choosing current browser retains tab and scroll"
    (same = { current with client_picker = None });
  let stagehand = choose_browser Stagehand_browser current in
  expect "switching to Stagehand withdraws native tab and document"
    (stagehand.source = Stagehand && stagehand.selected_client = None
     && stagehand.selected_tab = None && stagehand.scene = None && stagehand.reading = None);
  let independent = choose_browser Automation_browser current in
  let waiting = { independent with scroll = 7; selected_tab = Some 3;
    load = Loading (90, Discover Choose_client) } in
  let discovered, read = accept_clients ~generation:90 (Ok (found [firefox])) waiting in
  expect "opening picker on server source does not switch to singleton live client"
    (not read && discovered.source = Automation && discovered.selected_tab = Some 3
     && discovered.scroll = 7 && discovered.client_picker = Some 0);
  let failed, read = accept_clients ~generation:90 (Error "offline") waiting in
  expect "failed native discovery retains server tab"
    (not read && failed.source = Automation && failed.selected_tab = Some 3 && failed.scroll = 7);
  let live = choose_browser (Connected_browser zen) discovered in
  expect "explicit live selection routes back to chosen connection"
    (live.source = Live && live.selected_client = Some zen && live.selected_tab = None
     && request_body live = `Assoc ["lane", `String "live"; "clientId", `String zen.client_id]);
  expect "stale discovery cannot overwrite explicit selection"
    (accept_clients ~generation:90 (Ok (found [firefox])) live = (live, false))

(* What the picker says of the BiDi host, for each thing the server can
   report of it. *)
let test_bidi_host_rows () =
  let width = row_cells - 2 in
  let viewing ?(clients = [firefox]) bidi_host = { (create ()) with clients = Some clients; bidi_host } in
  let drawn ?clients ?(width = width) host = bidi_host_rows ~width (viewing ?clients host) in
  let says ?clients name host rows =
    let drawn = drawn ?clients host in
    if drawn <> rows then failwith (name ^ ":\n" ^ String.concat "\n" drawn) in
  let setup = "Setup: docs/design/browser-bidi-live-host.md" in
  (* Where no host has left an address, the launcher's own words stand. *)
  let attach =
    ["Attach: '/workspace/.masc/browser-lane/host/launch'";
     "        --bidi-url ws://127.0.0.1:PORT/session";
     "        PORT: the --remote-debugging-port Firefox was started with"; setup] in
  (* After a host, the address it was given is the one to give again. The
     path and the address are one shell word each. *)
  let attach_again =
    ["Attach: '/workspace/.masc/browser-lane/host/launch'";
     "        --bidi-url 'ws://127.0.0.1:9222/session'"; setup] in
  let at = "At: ws://127.0.0.1:9222/session" in
  let running state = [Printf.sprintf "BiDi host: %s · pid 4242" state; at] in
  let ended = ["BiDi host: ended 2026-10-03T04:01:00Z · pid 4242"] in
  let listed_note = "A listed BiDi connection may be stale or belong to another host" in
  says "nothing reported draws nothing" Host_not_reported [];
  says "a host that never ran says so and how one is started" (host Record.Never_started)
    ("BiDi host: none has run for this workspace" :: attach);
  says ~clients:[firefox; bidi] "a listed connection beside a never-started host is distinguished"
    (host Record.Never_started)
    (["BiDi host: none has run for this workspace"; listed_note] @ attach);
  says "a host still connecting" (host (Record.Running { host_entry with attached_at = None }))
    (running "connecting");
  (* A host serves on the server that lists it. *)
  says ~clients:[firefox; bidi] "a host this server lists is not told how to start one"
    (host (Record.Running host_entry)) (running "attached");
  (* The first row is the one a short screen keeps, so it is the one that
     tells this host from one that serves. *)
  let unlisted =
    ["BiDi host: attached, not listed by this server · pid 4242";
     "No BiDi connection is listed · hover and drag stay refused";
     "With MASC_HTTP_BASE_URL or MASC_HTTP_PORT set, it polls another server";
     "If none appears, stop it and start it from a shell without them"; at] in
  says "an attached host this server does not list says what that costs"
    (host (Record.Running host_entry)) unlisted;
  says ~clients:[{ bidi with transport = Browser_lane.Web_extension }]
    "the same ID over the extension is not that host" (host (Record.Running host_entry)) unlisted;
  (* A BiDi connection under another ID may be this host, and hover and drag
     are sent to it either way: nothing is said to be refused. *)
  says ~clients:[firefox; { bidi with client_id = "44444444-4444-4444-8444-444444444444" }]
    "another BiDi connection beside the host is not a refusal"
    (host (Record.Running host_entry))
    ["BiDi host: attached, not listed under its recorded ID · pid 4242";
     "Another BiDi connection is listed · this host's if it registered again";
     "Otherwise that is another host, and this one polls elsewhere or stopped"; at];
  says ~clients:[firefox; { bidi with client_id = "44444444-4444-4444-8444-444444444444" }]
    "a host still connecting beside another BiDi connection is connecting"
    (host (Record.Running { host_entry with attached_at = None })) (running "connecting");
  says ~clients:[firefox; bidi] "a listed host whose record is behind is attached"
    (host (Record.Running { host_entry with attached_at = None })) (running "attached");
  says "a host that ended in order says when, why, and that Firefox takes the next"
    (host_ended Record.No_session_left)
    (ended @ ["That Firefox takes the next host if it still runs"; "Reason: stopped by SIGINT"]
     @ attach_again);
  says ~clients:[firefox; bidi] "a listed connection beside an ended host is distinguished"
    (host_ended Record.No_session_left)
    (ended @ ["That Firefox takes the next host if it still runs"; listed_note;
              "Reason: stopped by SIGINT"] @ attach_again);
  says ~clients:[firefox; bidi] "a stale listed connection cannot displace the restart instruction"
    (host_ended Record.Session_left)
    (ended @ ["Session end not confirmed · restart that Firefox before attaching";
              listed_note; "Reason: stopped by SIGINT"] @ attach_again);
  says ~clients:[firefox; bidi] "a listed connection beside a dead host is distinguished"
    (host (Record.Died host_entry))
    (["BiDi host: pid 4242 is gone · no reason recorded";
      "Its session may be left in Firefox · restart Firefox if a host is refused"; listed_note]
     @ attach_again);
  says "a session left in Firefox is the step before attaching" (host_ended Record.Session_left)
    (ended @ ["Session end not confirmed · restart that Firefox before attaching";
              "Reason: stopped by SIGINT"] @ attach_again);
  says "a host whose Firefox left does not claim a session is held"
    (host_ended ~reason:"BiDi connection ended: BiDi EOF" Record.Session_unknown)
    (ended @ ["Could not ask Firefox to end the session · restart it if it still runs";
              "Reason: BiDi connection ended: BiDi EOF"] @ attach_again);
  (* Firefox held a session when the host asked. Whether it still does is
     not in the record, so the next host is tried before a restart. *)
  says "a host Firefox refused a session says what held it"
    (host_ended ~reason:"BiDi command rejected: session not created" Record.Session_refused)
    (ended @ ["Firefox refused this host a session · it held one then";
              "Stop a host still attached there · restart that Firefox if refused again";
              "Reason: BiDi command rejected: session not created"] @ attach_again);
  (* A host that never reached Firefox left no session there, and what kept
     it from one is still there for the next. *)
  (let ending = host_ending ~reason:"BiDi connection failed: Connection refused" Record.No_session_left in
   says "a host that never got a session is not told that Firefox takes the next"
     (host (Record.Ended ({ host_entry with attached_at = None; ended = Some ending }, ending)))
     (ended @ ["It got no session · check that Firefox answers at that address first";
               "Reason: BiDi connection failed: Connection refused"] @ attach_again));
  says "a host that left no reason is not said to have crashed" (host (Record.Died host_entry))
    (["BiDi host: pid 4242 is gone · no reason recorded";
      "Its session may be left in Firefox · restart Firefox if a host is refused"] @ attach_again);
  (* A host that runs refuses the next one, so its unreadable record is no
     reason to start one. *)
  says "a running host whose record cannot be read is stopped first"
    (host (Record.Unreadable { detail = "written as layout 2; this reader knows 1"; held = Some true }))
    ["BiDi host: one runs, and its record cannot be read";
     "Stop that host before starting another · it refuses a second one";
     "Detail: written as layout 2; this reader knows 1"];
  says "an unreadable record with no host behind it is replaced by the next host"
    (host (Record.Unreadable { detail = "bidi-host.json is not JSON"; held = Some false }))
    (["BiDi host: none runs, and the last record cannot be read";
      "Detail: bidi-host.json is not JSON"] @ attach);
  says "a lock that could not be asked says only that"
    (host (Record.Unreadable { detail = "Too many open files"; held = None }))
    ["BiDi host: could not check whether one runs"; "Detail: Too many open files"];
  says "a report this TUI cannot read says so"
    (Host_report_unreadable { detail = "no state"; message = None })
    ["BiDi host: this TUI cannot read the server's report";
     "masc doctor reads the host's record and says where the host stands"; "Detail: no state"];
  (* The paragraph is longer than most screens have rows for. Where the
     state is said in full comes before it. *)
  says "and keeps the paragraph the server wrote for the operator"
    (Host_report_unreadable { detail = "no state"; message = Some "No BiDi browser host is running." })
    ["BiDi host: this TUI cannot read the server's report";
     "masc doctor reads the host's record and says where the host stands"; "Detail: no state";
     "Server: No BiDi browser host is running."];
  (* A launcher that is not there, or not as installed, is not one to run. *)
  let with_launcher standing state =
    Host_reported { (host_report state) with attach = { host_attach with standing } } in
  says "no lane installed: install it first"
    (with_launcher Status.Launcher_not_installed Record.Never_started)
    ["BiDi host: none has run for this workspace";
     "Attach: install the browser lane in this workspace first"; setup];
  says "a launcher that is not as installed: install again first"
    (with_launcher Status.Launcher_needs_reinstall (Record.Died host_entry))
    ["BiDi host: pid 4242 is gone · no reason recorded";
     "Its session may be left in Firefox · restart Firefox if a host is refused";
     "Attach: install the browser lane again first (launcher not as installed)"; setup];
  let with_results results = host (Record.Running { host_entry with unacknowledged = results }) in
  says ~clients:[firefox; bidi] "one unacknowledged result: what ran, and that its fate is unknown"
    (with_results [unacknowledged 1_791_000_030.])
    (running "attached"
     @ ["1 result unacknowledged · last: page.interact, outcome unknown";
        "at 2026-10-03T04:00:30Z · request 0199c0de-0000-4000-8000-0000000000a1"]);
  says ~clients:[firefox; bidi] "several: the count, and the last one with what settles it"
    (with_results [unacknowledged 1_791_000_030.;
                   unacknowledged ~cause:Record.Refused ~outcome:Record.Succeeded
                     ~verb:(Some Masc.Browser_bidi_peer.Tabs_list) 1_791_000_040.])
    (running "attached"
     @ ["2 results unacknowledged · last: tabs.list, ran, refused";
        "at 2026-10-03T04:00:40Z · request 0199c0de-0000-4000-8000-0000000000a1"]);
  says ~clients:[firefox; bidi] "a request the host could not name"
    (with_results [{ (unacknowledged ~cause:Record.Not_sent ~outcome:Record.Not_started ~verb:None
                        1_791_000_030.) with request_id = None }])
    (running "attached"
     @ ["1 result unacknowledged · last: unknown verb, not started, not sent";
        "at 2026-10-03T04:00:30Z · request not a UUID"]);
  (* What another program wrote is read whole: it takes the rows it needs. *)
  let long_reason = "stopped without learning whether Firefox still holds its BiDi session" in
  says "a reason longer than the row goes on to the next one"
    (host_ended ~reason:long_reason Record.Session_unknown)
    (ended
     @ ["Could not ask Firefox to end the session · restart it if it still runs";
        "Reason: stopped without learning whether Firefox still holds its BiDi";
        "        session"] @ attach_again);
  let long_launcher = "/Users/someone/me/workspace/yousleepwhen/masc/.masc/browser-lane/host/launch" in
  let wide_launcher = "/Users/상수/文書/画面/masc/.masc/browser-lane/host/launch" in
  let launched_from launcher =
    Host_reported { (host_report Record.Never_started) with attach = { host_attach with launcher } } in
  says "a launcher path longer than the row breaks before a slash, with every name whole"
    (launched_from long_launcher)
    ["BiDi host: none has run for this workspace";
     "Attach: '/Users/someone/me/workspace/yousleepwhen/masc/.masc/browser-lane";
     "        /host/launch'";
     "        --bidi-url ws://127.0.0.1:PORT/session";
     "        PORT: the --remote-debugging-port Firefox was started with"; setup];
  (* A single name longer than the row has nowhere better to break. It is
     still all there. *)
  let one_long_name = "/work/" ^ String.make 90 'n' ^ "/host/launch" in
  (* The launcher as its rows say it: each row without the cells its lead,
     or the blank under the lead, takes. *)
  let launcher_said rows =
    let lead = String.length "Attach: " in
    let rec launcher = function
      | [] -> []
      | row :: _ when String_util.contains_substring row "--bidi-url" -> []
      | row :: rest -> String.sub row lead (String.length row - lead) :: launcher rest in
    String.concat "" (launcher (List.tl rows)) in
  List.iter (fun (name, path) ->
      let rows = drawn (launched_from path) in
      expect (name ^ ":\n" ^ String.concat "\n" rows)
        (String.equal (launcher_said rows) (Filename.quote path)))
    [ "a name longer than the row is not cut", one_long_name
    (* A space in a name is part of the path, wherever the row ends. *)
    ; "a long name with a space keeps the space",
      "/work/" ^ String.make 60 'y' ^ " " ^ String.make 60 'z' ^ "/host/launch"
    (* The name is two cells longer than the 66 a row has beside the lead,
       and the space is the first of the two. *)
    ; "a space where a row would end is kept", "/work/" ^ String.make 65 'y' ^ " z/host/launch"
    ; "a path with spaces all through", "/my work/a b/c  d/host/launch"
    ; "wide characters in path components keep their display cells", wide_launcher ];
  (* Every row fits the width it was asked for, at 80 columns and narrower,
     whatever the record holds. *)
  let widest = unacknowledged ~cause:Record.Not_sent ~outcome:Record.Unknown
      ~verb:(Some Masc.Browser_bidi_peer.Page_elements) 1_791_000_030. in
  let big = { host_entry with pid = 4_194_304; bidi_url = "ws://127.0.0.1:9222/" ^ String.make 90 'p' } in
  let reason = String.make 300 'r' ^ " " ^ String.make 211 's' ^ "..." in
  let ending = host_ending ~reason Record.Session_refused in
  List.iter (fun width ->
      List.iter (fun host ->
          List.iter (fun row ->
              expect (Printf.sprintf "a BiDi host row fits %d cells: %s" width row) (cells row <= width))
            (drawn ~width host))
        [host Record.Never_started; host (Record.Running big);
         host (Record.Running { big with attached_at = None });
         host (Record.Ended ({ big with ended = Some ending }, ending));
         host_ended Record.Session_left; host_ended Record.Session_unknown; host (Record.Died big);
         host (Record.Running { big with unacknowledged = List.init 12 (fun _ -> widest) });
         host (Record.Unreadable { detail = String.make 200 'd'; held = Some true });
         host (Record.Unreadable { detail = String.make 200 'd'; held = Some false });
         Host_report_unreadable { detail = String.make 200 'd'; message = Some (String.make 900 'm') };
         host_ended Record.Session_refused;
         launched_from long_launcher; launched_from one_long_name;
         launched_from wide_launcher])
    [width; 56; 36; 14; 9];
  (* On a screen narrower than a lead leaves room beside it, the lead has a
     row of its own and what it opens is read on the rows under it. *)
  expect "a narrow screen still says what a lead opens"
    (drawn ~width:12 (host (Record.Unreadable { detail = "torn in two"; held = None }))
     = ["BiDi host:"; "could not"; "check"; "whether one"; "runs"; "Detail:"; "torn in two"]);
  (* How many rows the picker gives its choices: the host's first row and
     the row that counts the rest keep a place while the choices keep
     theirs. *)
  let choice_rows = picker_choice_rows in
  expect "with nothing under the choices they have every row"
    (choice_rows ~rows:5 ~choices:6 ~below:0 = 5);
  expect "the first two rows below and the count keep a place beside three choices"
    (choice_rows ~rows:6 ~choices:6 ~below:8 = 3);
  expect "two rows below with nothing after them need no count"
    (choice_rows ~rows:5 ~choices:6 ~below:2 = 3);
  expect "one row shorter, the first row below and the count keep theirs"
    (choice_rows ~rows:5 ~choices:6 ~below:8 = 3);
  expect "beside fewer than three of many choices, the choices keep the room"
    (choice_rows ~rows:4 ~choices:6 ~below:8 = 4);
  (* With no connection listed there are two choices, and both fit. *)
  expect "two choices are all there are, so the rows below keep theirs beside them"
    (choice_rows ~rows:5 ~choices:2 ~below:8 = 2
     && choice_rows ~rows:4 ~choices:2 ~below:8 = 2);
  expect "but not beside one of two"
    (choice_rows ~rows:3 ~choices:2 ~below:8 = 3);
  expect "a screen with no row for a choice still draws one"
    (choice_rows ~rows:0 ~choices:2 ~below:8 = 1);
  (* The rows of a report a short screen draws before the extension's. *)
  expect "the head of a report is its first two rows, and the rest follows"
    (picker_host_head ["a"; "b"; "c"; "d"] = (["a"; "b"], ["c"; "d"])
     && picker_host_head ["a"] = (["a"], []) && picker_host_head [] = ([], []));
  (* Rows that report a host come before the rows on the extension. Rows
     that only say how one is started come after them. *)
  let reports host = host_rows_report_a_host (viewing host) in
  expect "nothing reported and no host yet are how-to, not a report"
    (not (reports Host_not_reported) && not (reports (host Record.Never_started)));
  List.iter (fun (name, host) -> expect (name ^ " is a report of a host") (reports host))
    [ "a running host", host (Record.Running host_entry)
    ; "a host that ended", host_ended Record.No_session_left
    ; "a host that died", host (Record.Died host_entry)
    ; "a record that cannot be read", host (Record.Unreadable { detail = "torn"; held = None })
    ; "a report that cannot be read", Host_report_unreadable { detail = "no state"; message = None } ]

(* The report rides the connection list: it is read from the same answer,
   kept with the list, and dropped with it. *)
let test_bidi_host_discovery () =
  let row id = `Assoc ["clientId", `String id; "browser", `String "firefox";
                       "transport", `String "web_extension"] in
  let answer extra =
    `Assoc ["ok", `Bool true; "data", `Assoc (("clients", `List [row firefox.client_id]) :: extra)] in
  let ended = host_report (let ending = host_ending Record.Session_left in
                           Record.Ended ({ host_entry with ended = Some ending }, ending)) in
  expect "the server's report is read with the list"
    (decode_discovery (answer ["bidiHost", Status.report_to_json ended])
     = Ok { listed = [firefox]; bidi_host = Host_reported ended });
  expect "a server that says nothing of the host still lists its connections"
    (decode_discovery (answer []) = Ok (found [firefox])
     && decode_discovery (answer ["bidiHost", `Null]) = Ok (found [firefox]));
  (match decode_discovery (answer ["bidiHost", `Assoc ["state", `String "paused"]]) with
   | Ok { listed; bidi_host = Host_report_unreadable { message = None; _ } } ->
       expect "a report this TUI cannot read does not cost the list" (listed = [firefox])
   | Ok _ | Error _ -> failwith "an unreadable host report was not kept apart from the list");
  (* A server of another build may send a report this one cannot read. The
     paragraph it wrote for the operator is still theirs to read. *)
  (match
     decode_discovery
       (answer ["bidiHost", `Assoc ["state", `String "paused"; "message", `String "The host is paused."]])
   with
   | Ok { listed = _; bidi_host = Host_report_unreadable { message; _ } } ->
       expect "the server's paragraph outlives a report this TUI cannot read"
         (message = Some "The host is paused.")
   | Ok _ | Error _ -> failwith "an unreadable host report lost the server's paragraph");
  (match decode_discovery (answer ["bidiHost", `String "running"]) with
   | Ok { listed; bidi_host = Host_report_unreadable { message = None; _ } } ->
       expect "a report that is no object does not cost the list either" (listed = [firefox])
   | Ok _ | Error _ -> failwith "a host report that is no object was not kept apart from the list");
  let discover t = { t with load = Loading (40, Discover Choose_client) } in
  let reported, _ =
    accept_clients ~generation:40 (Ok { listed = [firefox]; bidi_host = Host_reported ended })
      (discover (create ())) in
  expect "the view holds what the discovery said" (reported.bidi_host = Host_reported ended);
  let again, _ = accept_clients ~generation:40 (Ok (found [firefox])) (discover reported) in
  expect "the next discovery replaces it" (again.bidi_host = Host_not_reported);
  let failed, _ = accept_clients ~generation:40 (Error "connection refused") (discover reported) in
  expect "a discovery that failed holds no report, as it holds no list"
    (failed.bidi_host = Host_not_reported && failed.clients = None);
  (* The picker opened from the server's own browser asks for the list too. *)
  let elsewhere, _ =
    accept_clients ~generation:40 (Error "connection refused")
      (discover { reported with source = Automation }) in
  expect "a failed discovery from another source holds no report either"
    (elsewhere.bidi_host = Host_not_reported && elsewhere.clients = None);
  let waiting = withdraw_discovery reported in
  expect "a picker waiting on a discovery shows neither of the read before it"
    (waiting.clients = None && bidi_host_rows ~width:74 waiting = []
     && waiting = { reported with clients = None; bidi_host = Host_not_reported })

let () =
  List.iter (fun (name, test) -> test (); Printf.printf "PASS %s\n%!" name)
    ["unified browser picker", test_unified_browser_picker;
     "the picker says where the BiDi host stands", test_bidi_host_rows;
     "the BiDi host report rides the connection list", test_bidi_host_discovery;
     "raw refresh scroll identity", test_raw_refresh_scroll_identity;
     "scoped refresh failure and region recovery", test_scoped_refresh_failure_retains_read_intent;
     "visual pointer navigation", test_visual_pointer_navigation;
     "visual scroll ownership", test_visual_scroll_ownership;
     "client connection ownership", test_client_connection_ownership;
     "picker empty row reads the list", test_picker_empty_row;
     "client inventory contract", test_clients_decode;
     "screenshot drag hint follows the connection", test_screenshot_drag_hint;
     "every pointer gesture is decided before it is sent", test_pointer_decision;
     "a refused gesture stays until the next input", test_unserved_gesture;
     "screenshot ownership, draft and stale tab", test_screenshot_ownership_and_draft;
     "read and tab selection", test_read_and_selection;
     "closed-tab refresh recovery", test_refresh_rediscovers_tabs;
     "stale response and provenance", test_stale_response;
     "session generation", test_session_generation;
     "failed refresh preserves evidence", test_failed_refresh;
     "navigation failure preserves editable URL", test_navigation_failure_recovery;
     "HTTP read status provenance", test_http_read_status_provenance;
     "source switch", test_source_switch;
     "malformed response", test_malformed_response;
     "empty tabs", test_empty_tabs]
