module Lane = Masc_tui_types.Browser_lane_view
open Lane

let expect message condition = if not condition then failwith message
let success = function Ok value -> value | Error detail -> failwith detail
let tab id title = `Assoc ["id", `Int id; "title", `String title;
                           "url", `String "https://example.org/"; "active", `Bool (id = 2)]
let firefox = { client_id = "11111111-1111-4111-8111-111111111111"; browser = Firefox;
                transport = Browser_lane.Web_extension; space = None; space_observation = None; interactions = []; last_activities = [] }
let zen = { client_id = "22222222-2222-4222-8222-222222222222"; browser = Zen;
            transport = Browser_lane.Web_extension; space = None; space_observation = None; interactions = []; last_activities = [] }
let pinned () = choose_client firefox { (create ()) with clients = Some [firefox; zen] }
(* A connection list that came with no word of the BiDi host. *)
let found listed = { listed; bidi_host = Host_not_reported;
  inventory_report = Inventory_not_reported; automatic = None; unavailable = Backends_not_reported }

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
  { state; attach = host_attach; keeper = Status.Not_known; message = "the server's own sentence" }
let host state = Host_reported (host_report state)
let host_ending ?(reason = "stopped by SIGINT") session : Record.ending =
  { at = 1_791_000_060.; reason; session; because = Record.Reason_only }
let host_ended ?reason session =
  let ending = host_ending ?reason session in
  host (Record.Ended ({ host_entry with ended = Some ending }, ending))
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

(* Drag admission follows the screenshot's connection, including Ego, rather
   than the wording used to describe that decision in the footer. *)
let test_screenshot_drag_support () =
  let ego = { bidi with client_id = "44444444-4444-4444-8444-444444444444";
                        transport = Browser_lane.Ego_task_space; space = Some {id=51;name="fixture Space"} } in
  let view = { (create ()) with clients = Some [firefox; bidi; ego] } in
  let shot ?(source="live") client = success (decode_screenshot (screenshot_response ~source ~client ())) in
  expect "an extension screenshot names the connection a drag needs"
    (screenshot_drag_support view (shot firefox.client_id)
     = Drag_needs [Browser_lane.Webdriver_bidi; Browser_lane.Ego_task_space]);
  List.iter (fun (client : client) ->
    expect "the screenshot's native connection takes the drag"
      (screenshot_drag_support view (shot client.client_id) = Drag_served);
    expect "the chosen client answers when the list has not been read"
      (screenshot_drag_support (choose_client client (create ())) (shot client.client_id) = Drag_served))
    [bidi; ego];
  expect "a client the view no longer holds is not given a rule"
    (screenshot_drag_support (create ()) (shot firefox.client_id) = Drag_unknown);
  expect "the server's own browser takes the drag"
    (screenshot_drag_support (create ()) (shot ~source:"automation" firefox.client_id) = Drag_served)
let test_pointer_decision () =
  let shot ?(source="live") client = success (decode_screenshot (screenshot_response ~source ~client ())) in
  let drag (shot : screenshot) =
    Browser_lane.Drag {from={x=0.1;y=0.1}; to_={x=0.2;y=0.2}; viewport=shot.viewport;via=[];duration_ms=0} in
  let click (shot : screenshot) = Browser_lane.Click_at {point={x=0.1;y=0.1}; viewport=shot.viewport; button=Browser_lane.Pointer.Primary} in
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
  let ego = { bidi with client_id = "44444444-4444-4444-8444-444444444444";
                        transport = Browser_lane.Ego_task_space; space = Some {id=51;name="fixture Space"} } in
  let ego_view = { (create ()) with clients = Some [firefox; ego] } in
  let on_ego = shot ego.client_id in
  expect "a drag is sent on the observed Ego connection"
    (sends ego_view on_ego (drag on_ego));
  expect "an Ego connection can serve the drag refused on an extension"
    (pointer_decision ego_view on_extension (drag on_extension) = Pointer_unserved (unserved true));
  let automation = shot ~source:"automation" firefox.client_id in
  expect "the server's own browser answers for itself" (sends both automation (drag automation));
  expect "a connection the view no longer holds is left to the server"
    (sends (create ()) on_extension (drag on_extension));
  let busy_view = { both with load = Loading (3, Read) } in
  expect "a request in flight consumes the gesture, served or not"
    (pointer_decision busy_view on_extension (drag on_extension) = Pointer_consumed
     && pointer_decision busy_view on_bidi (click on_bidi) = Pointer_consumed)

(* A refused gesture is not a failed read: the read state stays, a background
   refresh does not erase it, and the next input does. The rows' wording is
   not checked here; what another program wrote never reaches them. *)
let test_unserved_gesture () =
  let drag_unserved ?(serving_listed = false) host =
    {asked = Browser_lane.Web_extension; capability = Browser_lane.Trusted_drag; serving_listed; host} in
  let hostile = "A\027[2J\nINJECTED " ^ String.make 400 'x' in
  let rows = unserved_gesture_rows (drag_unserved (host_ended ~reason:hostile Record.Session_left)) in
  expect "a host's own words are not in the rows of a refused gesture"
    (List.for_all (fun row ->
       not (String.contains row '\027') && not (String_util.contains_substring row "INJECTED"))
       rows);
  let ready = loaded () in
  let unserved = drag_unserved (host_ended Record.Session_left) in
  let refused = refuse_gesture unserved ready in
  expect "a refused gesture is not a failed read"
    (refused.load = ready.load && read_status refused = Read_ok && not (busy refused));
  expect "the background refresh keeps running" (cadence_operation refused = Some Read_refresh);
  let refreshed = accept ~generation:5 (decode (response ()))
      { refused with load = Loading (5, Read_refresh) } in
  expect "a refresh that lands keeps the refusal"
    (refreshed.load = Idle && refreshed.unserved_gesture = Some unserved);
  (* The rows read the host recorded with the refusal, not the current one, so
     what is learned of the host afterwards does not rewrite them. *)
  let later = { refreshed with bidi_host = host (Record.Running host_entry) } in
  expect "a later word of the host leaves the refusal as it was"
    (unserved_rows later = unserved_rows refreshed);
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

(* The viewport cadence's redraw skip in [Masc_tui] compares the settled
   screenshot record field by field (source, client, tab, title, url,
   viewport) before spending a redraw on it. The comparison input is exactly
   what [accept_screenshot] hands the redraw path, so a settled viewport shot
   that decodes identical keeps the cadence armed with the very record the
   skip will compare against, and any field change decodes different here
   already. That pins the skip's inputs without driving a terminal. *)
let test_viewport_cadence_skip_inputs () =
  let pending = { (loaded ()) with load = Loading (9, Viewport_cadence 2) } in
  (* A cadence tick lands on a loading view; the re-arm mirrors what
     [cadence_operation] launches between two ticks. *)
  let settle ~generation response view =
    let settled, shot = accept_screenshot ~generation (decode_screenshot response) view in
    (settled, Option.get shot) in
  let rearm generation view = { view with load = Loading (generation, Viewport_cadence 2) } in
  let settled, shot = settle ~generation:9 (screenshot_response ()) pending in
  expect "a settled cadence shot is idle and owned by the selected tab"
    (settled.load = Idle && shot.source = Live && shot.tab_id = 2
     && shot.title = "second" && shot.url = "https://example.org/");
  expect "the identical re-read decodes to the same skip inputs"
    (let _, again = settle ~generation:10 (screenshot_response ()) (rearm 10 settled) in
     again.source = shot.source && again.client_id = shot.client_id
     && again.tab_id = shot.tab_id && again.title = shot.title
     && again.url = shot.url && again.viewport = shot.viewport);
  List.iter (fun (field, response) ->
    expect ("a changed " ^ field ^ " already decodes different, so the skip cannot hold")
      (let _, changed = settle ~generation:11 response (rearm 11 settled) in
       not (changed.title = shot.title && changed.url = shot.url
            && changed.viewport = shot.viewport)))
    [ ("title", `Assoc [ "ok", `Bool true; "data", `Assoc [
          "source", `String "live"; "clientId", `String firefox.client_id; "tabId", `Int 2;
          "title", `String "moved"; "url", `String "https://example.org/";
          "mimeType", `String "image/png"; "data", `String "UE5H";
          "viewport", `Assoc [ "documentId", `String "fixture"; "width", `Int 800; "height", `Int 600;
                               "scrollX", `Int 0; "scrollY", `Int 0 ]; "elapsed_ms", `Float 13. ] ]);
      ("url", `Assoc [ "ok", `Bool true; "data", `Assoc [
          "source", `String "live"; "clientId", `String firefox.client_id; "tabId", `Int 2;
          "title", `String "second"; "url", `String "https://example.org/moved";
          "mimeType", `String "image/png"; "data", `String "UE5H";
          "viewport", `Assoc [ "documentId", `String "fixture"; "width", `Int 800; "height", `Int 600;
                               "scrollX", `Int 0; "scrollY", `Int 0 ]; "elapsed_ms", `Float 13. ] ]);
      ("viewport", `Assoc [ "ok", `Bool true; "data", `Assoc [
          "source", `String "live"; "clientId", `String firefox.client_id; "tabId", `Int 2;
          "title", `String "second"; "url", `String "https://example.org/";
          "mimeType", `String "image/png"; "data", `String "UE5H";
          "viewport", `Assoc [ "documentId", `String "fixture"; "width", `Int 800; "height", `Int 600;
                               "scrollX", `Int 3; "scrollY", `Int 0 ]; "elapsed_ms", `Float 13. ] ]) ];
  expect "the armed cadence keeps naming the settled viewport tab"
    (cadence_operation ~viewport:shot settled = Some (Viewport_cadence 2));
  expect "a busy view arms no cadence, so no skip input is produced at all"
    (cadence_operation ~viewport:shot {(loaded ()) with load = Loading (9, Viewport_cadence 2)} = None)

let test_activity_refresh_preserves_pending_read () =
  let original = {(loaded ()) with scroll=9; load=Loading (42, Read_refresh);
    refresh_pending=Some 42;url_draft=Some "https://example.org/draft"} in
  let work : Browser_lane.interaction_activity =
    {request_id="activity-read";actor=Some "keeper/reader";action="page.snapshot";
     tab_id=Some 2;phase=Browser_lane.Interaction_running} in
  let current={firefox with interactions=[work];last_activities=[{
    Browser_lane.work;outcome=Browser_lane.Activity_returned}]} in
  let updated=accept_activity (Ok (found [current;zen])) original in
  expect "activity settles independently from the original pending read"
    (updated.selected_client=Some current && updated.load=original.load
     && updated.refresh_pending=original.refresh_pending && updated.scroll=9
     && updated.selected_tab=original.selected_tab && updated.reading=original.reading
     && updated.scene=original.scene && updated.url_draft=original.url_draft
     && request_body updated=request_body original);
  let failed=accept_activity (Error "inventory disconnected") updated in
  expect "activity failure retains page and activity evidence"
    (failed.selected_client=updated.selected_client && failed.clients=updated.clients
     && failed.reading=updated.reading && failed.load=updated.load
     && failed.activity_error=Some "inventory disconnected");
  let replaced=accept_activity (Ok (found [zen])) failed in
  expect "activity refresh cannot silently change the selected browser"
    (replaced.selected_client=failed.selected_client && not (selected_client_available replaced)
     && replaced.selected_tab=original.selected_tab && replaced.load=original.load
     && replaced.activity_error=None)

let test_client_activity_preserves_connection () =
  let initial = { (loaded ()) with scroll = 8 } in
  let queued : Browser_lane.interaction_activity =
    { request_id="0199c0de-0000-4000-8000-0000000000a1"; actor=Some "fixture-keeper";
      action="hover_at"; tab_id=Some 2; phase=Browser_lane.Interaction_queued } in
  let discover selected = { selected with load=Loading (24, Discover Read_after_discovery) } in
  let refresh selected interactions =
    let current = { firefox with interactions } in
    let next, read = accept_clients ~generation:24 (Ok (found [current;zen])) (discover selected) in
    expect "transient activity retains the connection and authorizes its read"
      (read && next.selected_client=Some current && selected_client_available next);
    expect "activity refresh preserves tab, scroll and reading"
      (next.selected_tab=selected.selected_tab && next.scroll=selected.scroll
       && next.reading=selected.reading && next.selection=selected.selection);
    expect "cadence and requests retain their exact owner"
      (cadence_operation next=Some Read_refresh && request_body next=request_body initial);
    expect "current browser picker uses immutable connection identity"
      (browser_choice_selected selected (Connected_browser current));
    let pinned = choose_browser (Connected_browser current) {selected with client_picker=Some 0} in
    expect "pinning same connection refreshes activity without clearing content"
      (pinned.selection=Bound_explicit && pinned.selected_client=Some current
       && pinned.selected_tab=selected.selected_tab && pinned.scroll=selected.scroll
       && pinned.reading=selected.reading
       && browser_choice_operation (Connected_browser current) ~before:selected pinned=None);
    next in
  let queued_view = refresh initial [queued] in
  let running_view = refresh queued_view [{queued with phase=Browser_lane.Interaction_running}] in
  ignore (refresh running_view []);
  ignore (refresh {initial with selection=Bound_automatic} [queued]);
  List.iter (fun replacement ->
    let lost, read = accept_clients ~generation:24 (Ok (found [replacement])) (discover running_view) in
    expect "changed connection identity never reuses a tab or authorizes input"
      (not read && not (selected_client_available lost) && lost.selected_tab=None
       && lost.reading=None && lost.scroll=0 && lost.selected_client=running_view.selected_client
       && not (browser_choice_selected running_view (Connected_browser replacement))))
    [{firefox with client_id=zen.client_id}; {firefox with browser=Zen};
     {firefox with transport=Browser_lane.Webdriver_bidi}]

let test_client_connection_ownership () =
  let discover t = { t with load = Loading (20, Discover Read_after_discovery) } in
  let empty, read = accept_clients ~generation:20 (Ok (found [])) (discover (create ())) in
  expect "a server without automatic policy cannot invent an available browser"
    (not read && empty.selection=Unbound && read_status empty = Read_failed);
  expect "dismissing picker retains the missing policy refusal"
    (read_status { empty with client_picker = None } = Read_failed);
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
  expect "multiple clients without server policy require explicit choice" (not read && choose.selected_client = None && choose.client_picker = Some 0 && read_status choose = Read_failed);
  let first, read = accept_clients ~generation:20 (Ok (found [firefox])) (discover (create ())) in
  expect "a singleton without server policy is not silently inferred" (not read && first.selected_client=None && first.client_picker=Some 0);
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

let test_page_context_decode () =
  let context : Masc.Browser_surface.ego_page =
    {label=Some "p1";target_id="T1";opened_by=Masc.Browser_surface.Agent_created} in
  let value=match tab 2 "Page" with `Assoc fields ->
    `Assoc (("egoPage",Masc.Browser_surface.ego_page_to_json context)::fields) | _ -> assert false in
  let parsed=success (parse_tab value) in
  expect "TUI retains SDK Page context without inferring control" (parsed.ego_page=Some context);
  let unknown={context with label=None;opened_by=Unknown_origin} in
  let value=match tab 2 "User tab" with `Assoc fields ->
    `Assoc (("egoPage",Masc.Browser_surface.ego_page_to_json unknown)::fields) | _ -> assert false in
  expect "unmanaged and unknown origin remain distinct observations"
    ((success (parse_tab value)).ego_page=Some unknown)

let test_clients_decode () =
  let row ?(transport="web_extension") ?(space=`Null) ?(observation=`Null) id browser =
    `Assoc ["clientId", `String id; "browser", `String browser; "transport", `String transport; "space",space;
      "spaceObservation",observation; "interactions", `List []; "lastActivities", `List []] in
  let envelope rows = `Assoc ["ok", `Bool true; "data", `Assoc ["clients", `List rows]] in
  expect "backend-normalized Zen identity preserved"
    (decode_clients (envelope [row zen.client_id "zen"]) = Ok [zen]);
  let bidi = {firefox with client_id=zen.client_id; transport=Browser_lane.Webdriver_bidi} in
  let clients = success (decode_clients (envelope
    [row firefox.client_id "firefox"; row ~transport:"webdriver_bidi" bidi.client_id "firefox"])) in
  expect "same Firefox retains two distinct transports" (clients = [firefox; bidi]);
  let space : Browser_lane.ego_space = {id=51;name="SDK Space"} in
  let ego={bidi with browser=Ego_lite;transport=Browser_lane.Ego_task_space;space=Some space} in
  expect "Ego inventory preserves the observed Space identity"
    (decode_clients (envelope [row ~transport:"ego_task_space" ~space:(Browser_lane.ego_space_to_json space)
      ego.client_id "ego_lite"]) = Ok [ego]);
  let observed : Masc.Browser_ego_space_observation.t =
    {space={space with name="SDK current name"};ownership="future-native-owner";observed_at=1793046401.836675} in
  let observed_json=Masc.Browser_ego_space_observation.to_json observed in
  let observed_row observation=row ~transport:"ego_task_space"
    ~space:(Browser_lane.ego_space_to_json space) ~observation ego.client_id "ego_lite" in
  expect "native Space metadata and its own timestamp are preserved"
    (decode_clients (envelope [observed_row observed_json])=Ok [{ego with space_observation=Some observed}]);
  List.iter (fun observation ->
    expect "foreign malformed and duplicate native metadata is refused"
      (Result.is_error (decode_clients (envelope [observed_row observation]))))
    [Masc.Browser_ego_space_observation.to_json {observed with space={space with id=52}};
     Masc.Browser_ego_space_observation.to_json {observed with observed_at=infinity};
     Masc.Browser_ego_space_observation.to_json {observed with ownership=" "};
     (match observed_json with `Assoc fields -> `Assoc (("ownership",`String "other")::fields) | _ -> assert false)];
  expect "non Ego transport cannot publish Space control metadata"
    (Result.is_error (decode_clients (envelope [row ~observation:observed_json firefox.client_id "firefox"])));
  expect "missing metadata field is not silently treated as unknown"
    (Result.is_error (decode_clients (envelope [match observed_row observed_json with
      | `Assoc fields -> `Assoc (List.remove_assoc "spaceObservation" fields) | _ -> assert false])));
  let original={ (choose_client ego {(create ()) with clients=Some [ego]}) with
    load=Loading (91,Read_refresh);refresh_pending=Some 91;selected_tab=Some 2;
    scroll=37;url_draft=Some "https://example.org/draft"} in
  let observed_client={ego with space_observation=Some observed} in
  let updated=accept_activity (Ok (found [observed_client])) original in
  expect "metadata refresh does not change the pending request or connection authority"
    (updated.selected_client=Some observed_client && same_client ego observed_client
     && updated.load=original.load && updated.refresh_pending=original.refresh_pending
     && updated.selected_tab=original.selected_tab && updated.scroll=original.scroll
     && updated.url_draft=original.url_draft && request_body updated=request_body original);
  let unavailable=accept_activity (Error "worker unreachable") updated in
  expect "failed refresh retains dated metadata with the original failure"
    (unavailable.selected_client=Some observed_client && unavailable.activity_error=Some "worker unreachable");
  let invalidated=accept_activity (Ok (found [ego])) unavailable in
  expect "matching null publication clears cached metadata without changing request ownership"
    (invalidated.selected_client=Some ego && invalidated.load=original.load
     && request_body invalidated=request_body original && invalidated.activity_error=None);
  let refresh client =
    let waiting={ (choose_client ego {(create ()) with clients=Some [ego]}) with
      load=Loading (91,Discover Read_after_discovery);selected_tab=Some 2} in
    accept_clients ~generation:91 (Ok (found [client])) waiting in
  let renamed={ego with space=Some {space with name="Renamed Space"}} in
  let same,read=refresh renamed in
  expect "renaming a Space refreshes its name without losing its binding"
    (read && same.selected_client=Some renamed && same.selected_tab=Some 2);
  let replaced={ego with space=Some {space with id=52}} in
  let changed,read=refresh replaced in
  expect "reusing a UUID for another Space never reads the replacement implicitly"
    (not read && changed.selected_tab=None && changed.selected_client=Some ego);
  List.iter (fun value -> expect "invalid Space identity is refused by the TUI inventory"
    (Result.is_error (decode_clients (envelope [value]))))
    [row ~transport:"ego_task_space" ego.client_id "ego_lite";
     row ~space:(Browser_lane.ego_space_to_json space) firefox.client_id "firefox"];
  expect "picker identifies the extension connection"
    (browser_choice_label (Connected_browser firefox) = "Firefox · " ^ firefox.client_id ^ " · existing login");
  expect "picker identifies the trusted hover connection"
    (browser_choice_label (Connected_browser bidi) = "Firefox · " ^ bidi.client_id ^ " · existing login");
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
  let action = Browser_lane.Click_at {point={x=0.5;y=0.5};viewport=shot.viewport;button=Browser_lane.Pointer.Primary} in
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
    (browser_choices (create ()) = [Automatic_browser; Work_browser]);
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

let test_bidi_host_discovery () =
  let row id = `Assoc ["clientId", `String id; "browser", `String "firefox";
                       "interactions", `List []; "lastActivities", `List []; "transport", `String "web_extension";"space",`Null;"spaceObservation",`Null] in
  let answer extra =
    `Assoc ["ok", `Bool true; "data", `Assoc (("clients", `List [row firefox.client_id]) :: extra)] in
  let ended = host_report (let ending = host_ending Record.Session_left in
                           Record.Ended ({ host_entry with ended = Some ending }, ending)) in
  expect "the server's report is read with the list"
    (decode_discovery (answer ["bidiHost", Status.report_to_json ended])
     = Ok { listed = [firefox]; bidi_host = Host_reported ended;
         inventory_report=Inventory_not_reported; automatic=None; unavailable=Backends_not_reported });
  expect "a server that says nothing of the host still lists its connections"
    (decode_discovery (answer []) = Ok (found [firefox])
     && decode_discovery (answer ["bidiHost", `Null]) = Ok (found [firefox]));
  let conflict = Masc.Browser_addon_observation.Ego_user_owned_name {space="masc";observed_at=42.} in
  let decoded = success (decode_discovery (answer ["unavailable",`List [Masc.Browser_addon_observation.unavailable_to_json conflict]])) in
  expect "the same discovery retains the unavailable backend and its original observation"
    (decoded.listed=[firefox] && decoded.unavailable=Backends_unavailable [conflict]);
  let observed = { (create ()) with unavailable=decoded.unavailable } in
  expect "switching sources retains the last backend observation"
    ((switch_source Automation observed).unavailable=observed.unavailable
     && (choose_automatic observed).unavailable=observed.unavailable);
  expect "connection-list refresh follows the current input owner"
    (list_reload observed=Open_browser_list
     && list_reload {observed with client_picker=Some 0}=Reload_picker
     && list_reload {observed with url_draft=Some "https://example.test"}=Close_url_draft_then_open
     && list_reload {observed with load=Loading (42,Read)}=Wait_until_idle);
  let renewed, _ = accept_clients ~generation:41 (Ok (found [firefox]))
      {observed with load=Loading (41, Discover Choose_client)} in
  expect "a new discovery replaces the previous worker's backend observation"
    (renewed.unavailable=Backends_not_reported);
  let unreadable = success (decode_discovery (answer ["unavailable",`String "invalid"])) in
  expect "an unreadable backend report does not discard the client list"
    (unreadable.listed=[firefox] && match unreadable.unavailable with
      | Backends_unreadable _ -> true | Backends_not_reported | Backends_unavailable _ -> false);
  (match decode_discovery (answer ["bidiHost", `Assoc ["state", `String "paused"]]) with
   | Ok { listed; bidi_host = Host_report_unreadable { message = None; _ }; inventory_report=_; automatic=_; unavailable=_ } ->
       expect "a report this TUI cannot read does not cost the list" (listed = [firefox])
   | Ok _ | Error _ -> failwith "an unreadable host report was not kept apart from the list");
  (* A server of another build may send a report this one cannot read. The
     paragraph it wrote for the operator is still theirs to read. *)
  (match
     decode_discovery
       (answer ["bidiHost", `Assoc ["state", `String "paused"; "message", `String "The host is paused."]])
   with
   | Ok { listed = _; bidi_host = Host_report_unreadable { message; _ }; inventory_report=_; automatic=_; unavailable=_ } ->
       expect "the server's paragraph outlives a report this TUI cannot read"
         (message = Some "The host is paused.")
   | Ok _ | Error _ -> failwith "an unreadable host report lost the server's paragraph");
  (match decode_discovery (answer ["bidiHost", `String "running"]) with
   | Ok { listed; bidi_host = Host_report_unreadable { message = None; _ }; inventory_report=_; automatic=_; unavailable=_ } ->
       expect "a report that is no object does not cost the list either" (listed = [firefox])
   | Ok _ | Error _ -> failwith "a host report that is no object was not kept apart from the list");
  let discover t = { t with load = Loading (40, Discover Choose_client) } in
  let reported, _ =
    accept_clients ~generation:40 (Ok { listed = [firefox]; bidi_host = Host_reported ended;
        inventory_report=Inventory_not_reported; automatic=None; unavailable=Backends_not_reported })
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
     && waiting = { reported with clients = None; bidi_host = Host_not_reported;
         inventory_report=Inventory_not_reported; automatic=None })

(* One value per operation constructor. [expected_refresh] names every
   constructor with no catch-all, so a new operation breaks this build until
   its class here is decided, like it does in [operation_is_refresh]. *)
let test_operation_is_refresh () =
  let node : Browser_lane.node_ref = {document_id="observed-document";node_id="region"} in
  let guard = { expected_url = "https://example.org/";
                navigation_source = { url = "https://example.org/"; document_id = "observed-document" } } in
  let operations =
    [ Discover Choose_client; Discover Read_after_discovery; Read; Open_session; Close_session
    ; Goto "https://example.org/"; Screenshot 2; Read_refresh; Scene_read 2; Scene_regions 2
    ; Scene_refresh {tab_id=2;scene_view=Browser_lane.Content;scope=None}
    ; Scene_scroll {tab_id=2;document_id="observed-document";expected_url="https://example.org/";
                    scene_view=Browser_lane.Content;scope=None;delta_y=1}
    ; Scene_focus {tab_id=2;target=node}
    ; Scene_click {tab_id=2;document_id="observed-document";node_id="region";
                   expected_url="https://example.org/";scope=None}
    ; Scene_follow {tab_id=2;document_id="observed-document";node_id="region";
                    expected_url="https://example.org/"}
    ; Scene_follow_refresh {tab_id=2;guard;scene_view=Browser_lane.Content}
    ; Viewport_refresh {tab_id=2;expected_url="https://example.org/"}
    ; Viewport_cadence 2
    ; Viewport_pointer {tab_id=2;expected_url="https://example.org/";action=Browser_lane.Activate_tab} ] in
  let expected_refresh = function
    | Read_refresh | Scene_refresh _ | Scene_follow_refresh _ | Viewport_cadence _ -> true
    | Discover _ | Read | Open_session | Close_session | Goto _ | Screenshot _
    | Scene_read _ | Scene_regions _ | Scene_scroll _ | Scene_focus _
    | Scene_click _ | Scene_follow _ | Viewport_refresh _ | Viewport_pointer _ -> false in
  expect "the list holds one value for each constructor, two for Discover"
    (List.length operations = 19);
  List.iter (fun operation ->
    expect "an operation is a refresh exactly when the table says"
      (operation_is_refresh operation = expected_refresh operation);
    let loading = {(create ()) with load = Loading (7, operation)} in
    let yielded = yield_refresh_to_input loading in
    expect "operator input drops a refresh and leaves every other operation loading"
      (if expected_refresh operation then yielded.load = Idle else yielded = loading))
    operations;
  expect "the operator's own viewport refresh is not a refresh the cadence owns"
    (not (operation_is_refresh (Viewport_refresh {tab_id=2;expected_url="https://example.org/"})));
  List.iter (fun load ->
    let t = {(create ()) with load} in
    expect "input leaves a lane with nothing loading alone" (yield_refresh_to_input t = t))
    [Idle; No_browser; Failed "x"]

(* Exercise the server recommendation boundary and concrete request owners,
   rather than screen copy or layout. *)
let automatic_answer ?(listed=[firefox;zen]) browse work =
  let row (client : client) = `Assoc ["clientId",`String client.client_id;
    "browser",`String (Browser_lane.browser_name client.browser);
    "transport",`String (Browser_lane.live_transport_to_string client.transport);"space",Browser_lane.client_space_to_json client.space;"spaceObservation",`Null;"interactions",`List [];"lastActivities",`List []] in
  `Assoc ["ok",`Bool true;"data",`Assoc ["clients",`List (List.map row listed);
    "automatic",`Assoc ["browse",browse;"work",work]]]
let recommended lane client reason = `Assoc ["ok",`Bool true;"data",`Assoc [
  "lane",`String lane;"clientId",(match client with None->`Null | Some id->`String id);
  "reason",`String reason]]
let unavailable = `Assoc ["ok",`Bool false;"error",`Assoc [
  "code",`String "no_available_browser";"message",`String "No connected browser"]]
let recommended_work = recommended "stagehand" None "preferred_work_browser"
let automatic_discover ?(generation=101) view answer =
  accept_clients ~generation (decode_discovery answer)
    {view with load=Loading (generation,Discover Read_after_discovery)}

let test_automatic_browser_binding () =
  let answer = automatic_answer
    (recommended "live" (Some zen.client_id) "existing_login") recommended_work in
  let bound, read = automatic_discover (create ()) answer in
  expect "server choice wins even with multiple connected browsers"
    (read && bound.selection=Bound_automatic && bound.selected_client=Some zen);
  expect "all subsequent requests carry the concrete selected identity"
    (request_body bound=`Assoc ["lane",`String "live";"clientId",`String zen.client_id]);
  let changed = automatic_answer
    (recommended "live" (Some firefox.client_id) "available_connected_browser") recommended_work in
  let same, read = automatic_discover bound changed in
  expect "a recommendation refresh cannot transfer an existing binding"
    (read && same.selected_client=Some zen);
  let missing = automatic_answer ~listed:[firefox]
    (recommended "live" (Some firefox.client_id) "existing_login") recommended_work in
  let lost, read = automatic_discover bound missing in
  expect "disconnect does not rebind or authorize a read against another browser"
    (not read && lost.selected_client=Some zen && not (selected_client_available lost));
  let pending = {(create ()) with load=Loading (101,Discover Read_after_discovery)} in
  let manual = choose_client firefox pending in
  expect "a pending automatic reply cannot take an explicit selection"
    (accept_clients ~generation:101 (decode_discovery answer) manual=(manual,false));
  let explicit = choose_browser (Connected_browser zen) bound in
  expect "explicitly choosing the same browser pins it without dropping content"
    (explicit.selection=Bound_explicit && explicit.selected_client=bound.selected_client);
  let live_override, read = automatic_discover (switch_source Live (create ())) answer in
  expect "an advanced live override requests a concrete client rather than automatic work"
    (not read && live_override.selection=Live_unbound && live_override.selected_client=None
     && live_override.client_picker=Some 0);
  let no_policy, read = automatic_discover (create ())
    (`Assoc ["ok",`Bool true;"data",`Assoc ["clients",`List []]]) in
  expect "old servers never trigger an inferred backend or an open"
    (not read && no_policy.selection=Unbound && Result.is_error (match no_policy.load with
      Failed detail->Error detail | Idle | No_browser | Loading _->Ok ()))

let test_automatic_work_requests () =
  let ambiguous = `Assoc ["ok",`Bool false;"error",`Assoc [
    "code",`String "ambiguous_browsers";"message",`String "Choose a connected browser"]] in
  let refusal, read = automatic_discover (create ())
    (automatic_answer ambiguous recommended_work) in
  expect "ambiguous connected browsers do not become a work-browser open prompt"
    (not read && refusal.selection=Unbound && refusal.source=Live
     && refusal.selected_client=None && not refusal.pending_open
     && refusal.client_picker=Some 0 && refusal.load=Failed "Choose a connected browser");
  List.iter (fun code ->
    let refused = `Assoc ["ok",`Bool false;"error",`Assoc [
      "code",`String code;"message",`String "Keep the original refusal"]] in
    let same, read = automatic_discover (create ())
      (automatic_answer refused recommended_work) in
    expect "other selection refusals never authorize a work fallback"
      (not read && same.selection=Unbound && same.source=Live
       && same.load=Failed "Keep the original refusal"))
    ["browser_binding_required";"new_server_refusal"];
  let empty = automatic_answer ~listed:[] unavailable recommended_work in
  let prompt, read = automatic_discover (create ()) empty in
  expect "entering the reader with no browser binds a work recommendation without opening it"
    (not read && prompt.source=Stagehand && prompt.load=No_browser
     && prompt.reading=None && cadence_operation prompt=None);
  let selected, operation = prepare_open (pinned ()) in
  expect "explicit open discovers the work recommendation instead of opening the login browser"
    (selected.selection=Work_unbound && selected.pending_open && operation=Discover Read_after_discovery);
  let pending = {selected with load=Loading (202,operation)} in
  let ignored, read = accept_clients ~generation:201 (decode_discovery empty) pending in
  expect "a stale discovery keeps the newer open continuation untouched"
    (not read && ignored=pending && ignored.pending_open);
  let opened, continue = accept_clients ~generation:202 (decode_discovery empty) pending in
  expect "current work discovery dispatches one open against its concrete owned source"
    (continue && opened.source=Stagehand && discovery_continuation opened=Open_session);
  let endpoint, body, _ = success (action_request ~source:opened.source Open_session) in
  expect "the actual shared HTTP request builder opens a visible work browser"
    (endpoint="session" && body=`Assoc ["action",`String "open";"headless",`Bool false;
      "lane",`String "stagehand"]);
  let owned = {(switch_source Automation (create ())) with selected_tab=Some 7} in
  let retained, operation = prepare_open owned in
  expect "choosing the same advanced owned browser preserves its tab and owner"
    (choose_browser Automation_browser owned=owned
     && browser_choice_operation Automation_browser ~before:owned owned=None);
  expect "an already bound owned browser remains the open/navigation/close owner"
    (retained=owned && operation=Open_session &&
      action_request ~source:retained.source (Goto "https://example.org/") =
      Ok ("goto",`Assoc ["url",`String "https://example.org/";"lane",`String "automation"],65.0));
  let session = automatic_answer ~listed:[]
    (recommended "automation" None "existing_work_session")
    (recommended "automation" None "existing_work_session") in
  let existing, read = automatic_discover (create ()) session in
  expect "an existing owned session can be read without opening another window"
    (read && existing.source=Automation && discovery_continuation existing=Read);
  let wrong_id = recommended "stagehand" (Some zen.client_id) "existing_work_session" in
  let unknown_reason = recommended "stagehand" None "unknown_reason" in
  List.iter (fun invalid ->
    let decoded = success (decode_discovery (automatic_answer invalid recommended_work)) in
    let refused, read = automatic_discover (create ()) (automatic_answer invalid recommended_work) in
    expect "invalid automatic decision is refused without hiding manual choices"
      (Result.is_error (decode_recommendation invalid) && decoded.listed=[firefox;zen]
       && not read && refused.selection=Unbound && refused.clients=Some [firefox;zen]))
    [wrong_id;unknown_reason];
  expect "work decisions cannot name an existing login browser"
    (Result.is_error (decode_automatic (`Assoc ["automatic",`Assoc ["browse",unavailable;
      "work",recommended "live" (Some zen.client_id) "existing_login"]])));
  let switched = choose_work (loaded ()) in
  expect "choosing work only discovers its owner and does not open a window"
    (browser_choice_operation Work_browser ~before:(loaded ()) switched
     = Some (Discover Read_after_discovery));
  let retry = {(create ()) with load=Failed "automatic decision unavailable"} in
  expect "explicitly choosing Automatic can retry an unbound refusal"
    (browser_choice_operation Automatic_browser ~before:retry
      (choose_browser Automatic_browser retry) = Some (Discover Read_after_discovery));
  expect "work selection clears stale tabs and screenshot ownership"
    (switched.selected_tab=None && switched.selected_client=None && switched.reading=None
     && switched.scene=None && switched.selection=Work_unbound)

let with_inventory_fields extra = function
  | `Assoc fields ->
      (match List.assoc_opt "data" fields with
       | Some (`Assoc data) -> `Assoc (("data",`Assoc (extra @ data))::List.remove_assoc "data" fields)
       | _ -> failwith "discovery data must be an object")
  | _ -> failwith "discovery must be an object"

let test_inventory_report_preserves_request_owner () =
  let module I=Masc.Browser_connection_inventory in
  let issues=I.[Source_unavailable {instance_id="worker-a";message="connection unavailable"};
    Source_unreadable {instance_id="worker-b";message="invalid snapshot"};
    Source_unready {instance_id="worker-c";message="starting"};
    Duplicate_client {client_id=success (Browser_lane.client_id_of_string zen.client_id);
      instances=["worker-a";"worker-b"]}] in
  let refusal=`Assoc ["ok",`Bool false;"error",`Assoc [
    "code",`String "browser_binding_required";"message",`String "Choose an observed client"]] in
  let answer=automatic_answer refusal refusal
    |> with_inventory_fields ["inventoryIssues",I.issues_to_json issues] in
  let discovered=success (decode_discovery answer) in
  expect "all typed inventory issues retain the separately valid client rows"
    (discovered.inventory_report=Inventory_reported issues && discovered.listed=[firefox;zen]);
  let original={(loaded ()) with load=Loading (77,Read_refresh);refresh_pending=Some 77;
    scroll=11;url_draft=Some "https://example.org/draft"} in
  let current=accept_activity (Ok discovered) original in
  expect "inventory activity cannot consume or retarget the pending page read"
    (current.inventory_report=Inventory_reported issues && current.clients=Some [firefox;zen]
      && current.selected_client=original.selected_client && current.selected_tab=original.selected_tab
      && current.reading=original.reading && current.scene=original.scene
      && current.load=original.load && current.refresh_pending=original.refresh_pending
      && current.scroll=original.scroll && current.url_draft=original.url_draft
      && request_body current=request_body original);
  let failed=accept_activity (Error "inventory disconnected") current in
  expect "failed activity retains the last inventory issues and request owner"
    (failed.inventory_report=current.inventory_report && failed.selected_client=current.selected_client
      && failed.reading=current.reading && failed.load=current.load);
  let work=choose_work current in
  expect "explicit work selection retains the inventory observation it presents"
    (work.inventory_report=current.inventory_report && work.clients=current.clients);
  let withdrawn=withdraw_discovery current in
  expect "withdrawing inventory does not withdraw the selected Page"
    (withdrawn.inventory_report=Inventory_not_reported && withdrawn.clients=None
      && withdrawn.selected_client=current.selected_client && withdrawn.selected_tab=current.selected_tab
      && withdrawn.reading=current.reading && withdrawn.load=current.load);
  let waiting={original with load=Loading (78,Discover Choose_client)} in
  let refreshed,read=accept_clients ~generation:78 (Ok discovered) waiting in
  expect "discovery publishes issues without changing the explicit Page owner"
    (not read && refreshed.inventory_report=Inventory_reported issues
      && refreshed.selected_client=waiting.selected_client && refreshed.selected_tab=waiting.selected_tab
      && refreshed.reading=waiting.reading);
  let failed,_=accept_clients ~generation:78 (Error "offline")
    {refreshed with load=Loading (78,Discover Choose_client)} in
  expect "failed discovery reports no inventory rather than an empty successful report"
    (failed.inventory_report=Inventory_not_reported && failed.selected_client=refreshed.selected_client
      && failed.selected_tab=refreshed.selected_tab && failed.reading=refreshed.reading);
  let unreported=accept_activity (Ok (found [firefox;zen])) current in
  expect "an absent next report withdraws only the previous inventory report"
    (unreported.inventory_report=Inventory_not_reported && unreported.reading=current.reading
      && unreported.load=current.load)

let test_invalid_inventory_never_recommends_a_fallback () =
  let automatic=automatic_answer unavailable recommended_work in
  let invalid = function
    | Some {browse=Error {kind=Invalid_automatic_response;_};
        work=Error {kind=Invalid_automatic_response;_}} -> true
    | Some _|None -> false in
  List.iter (fun extra ->
    let answer=with_inventory_fields extra automatic in
    let decoded=success (decode_discovery answer) in
    expect "unreadable inventory preserves valid rows and refuses both automatic decisions"
      (decoded.listed=[firefox;zen] && invalid decoded.automatic
        && (match decoded.inventory_report with Inventory_report_unreadable _ -> true
          | Inventory_not_reported|Inventory_reported _ -> false));
    List.iter (fun view ->
      let refused,read=automatic_discover view answer in
      expect "unreadable inventory never becomes an owned-browser fallback or open"
        (not read && refused.source=Live && refused.clients=Some [firefox;zen]
          && refused.selected_client=None && not refused.pending_open
          && (match refused.load with Failed _ -> true | Idle|No_browser|Loading _ -> false)))
      [create ();{(choose_work (create ())) with pending_open=true}])
    [["inventoryIssues",`Null];["inventoryIssues",`Assoc []];
     ["inventoryIssues",`List [`Assoc ["kind",`String "future";"instanceId",`String "worker-a";"message",`String "unknown"]]];
     ["inventoryIssues",`List [`Assoc ["kind",`String "unready";"instanceId",`String "worker-a";
       "message",`String "one";"message",`String "two"]]];
     ["inventoryIssues",`List [];"inventoryIssues",`List []]]

let test_inventory_issues_guard_automatic_recommendations () =
  let module I=Masc.Browser_connection_inventory in
  let issue=I.Source_unready {instance_id="worker-a";message="starting"} in
  let reported answer=with_inventory_fields ["inventoryIssues",I.issues_to_json [issue]] answer in
  let preferred=recommended "live" (Some zen.client_id) "existing_login" in
  List.iter (fun browse ->
    let answer=reported (automatic_answer browse recommended_work) in
    let decoded=success (decode_discovery answer) in
    let refused,read=automatic_discover (create ()) answer in
    expect "reported worker issues invalidate a success or no-browser fallback recommendation"
      (decoded.inventory_report=Inventory_reported [issue]
        && (match decoded.automatic with
          | Some {browse=Error {kind=Invalid_automatic_response;_};
              work=Error {kind=Invalid_automatic_response;_}} -> true
          | Some _|None -> false)
        && not read && refused.source=Live && refused.selected_client=None && not refused.pending_open))
    [preferred;unavailable];
  let refusal=`Assoc ["ok",`Bool false;"error",`Assoc [
    "code",`String "browser_binding_required";"message",`String "Original inventory refusal"]] in
  let decoded=success (decode_discovery (reported (automatic_answer refusal refusal))) in
  expect "an existing safe server refusal retains its typed reason"
    (match decoded.automatic with Some {browse=Error {kind=Binding_required;_};
        work=Error {kind=Binding_required;_}} -> true | Some _|None -> false);
  let answer=automatic_answer preferred recommended_work in
  let absent=success (decode_discovery answer) in
  let complete,read=automatic_discover (create ())
    (with_inventory_fields ["inventoryIssues",`List []] answer) in
  expect "missing and explicitly empty inventory reports remain distinct"
    (absent.inventory_report=Inventory_not_reported && complete.inventory_report=Inventory_reported []);
  expect "an explicitly empty report preserves the server's normal concrete recommendation"
    (read && complete.selected_client=Some zen)

let test_inventory_summary_contract () =
  let module I=Masc.Browser_connection_inventory in
  let issue=I.Source_unready {instance_id="starting";message="not observed yet"} in
  let issues=I.issues_to_json [issue] in
  let answer=automatic_answer unavailable recommended_work in
  let invalid = function
    | Some {browse=Error {kind=Invalid_automatic_response;_};
        work=Error {kind=Invalid_automatic_response;_}} -> true
    | Some _|None -> false in
  List.iter (fun fields ->
    let response=with_inventory_fields fields answer in
    let decoded=success (decode_discovery response) in
    expect "an invalid completeness summary preserves rows and refuses both decisions"
      (decoded.listed=[firefox;zen] && invalid decoded.automatic
        && match decoded.inventory_report with Inventory_report_unreadable _ -> true
          | Inventory_not_reported|Inventory_reported _ -> false);
    List.iter (fun view ->
      let refused,read=automatic_discover view response in
      expect "an incomplete or contradictory summary cannot open a fallback browser"
        (not read && refused.clients=Some [firefox;zen] && refused.source=Live
          && refused.selected_client=None && not refused.pending_open
          && match refused.load with Failed _ -> true | Idle|No_browser|Loading _ -> false))
      [create ();{(choose_work (create ())) with pending_open=true}])
    [["inventoryComplete",`Bool false];
     ["inventoryComplete",`Bool false;"inventoryIssues",`List []];
     ["inventoryComplete",`Bool true];
     ["inventoryComplete",`Bool true;"inventoryIssues",issues];
     ["inventoryComplete",`Null;"inventoryIssues",`List []];
     ["inventoryComplete",`String "false";"inventoryIssues",`List []];
     ["inventoryComplete",`Bool true;"inventoryComplete",`Bool true;"inventoryIssues",`List []];
     ["inventoryComplete",`Bool true;"inventoryComplete",`Bool false;"inventoryIssues",`List []]];
  let partial=with_inventory_fields ["inventoryComplete",`Bool false;"inventoryIssues",issues] answer in
  let decoded=success (decode_discovery partial) in
  expect "a valid incomplete report retains its issue and blocks a conflicting fallback"
    (decoded.inventory_report=Inventory_reported [issue] && invalid decoded.automatic);
  List.iter (fun view ->
    let refused,read=automatic_discover view partial in
    expect "reported incomplete work stays unbound even with an open intent"
      (not read && refused.selected_client=None && not refused.pending_open && refused.source=Live))
    [create ();{(choose_work (create ())) with pending_open=true}];
  let complete,read=automatic_discover (create ())
    (with_inventory_fields ["inventoryComplete",`Bool true;"inventoryIssues",`List []]
      (automatic_answer (recommended "live" (Some zen.client_id) "existing_login") recommended_work)) in
  expect "a consistent complete report preserves the concrete server recommendation"
    (read && complete.inventory_report=Inventory_reported [] && complete.selected_client=Some zen)

let () =
  List.iter (fun (name, test) -> test (); Printf.printf "PASS %s\n%!" name)
    ["activity refresh preserves pending read", test_activity_refresh_preserves_pending_read;
     "client activity keeps connection", test_client_activity_preserves_connection;
     "automatic browser binding", test_automatic_browser_binding;
     "automatic work requests", test_automatic_work_requests;
     "inventory issues preserve request ownership", test_inventory_report_preserves_request_owner;
     "invalid inventory refuses fallback", test_invalid_inventory_never_recommends_a_fallback;
     "inventory issues guard recommendations", test_inventory_issues_guard_automatic_recommendations;
     "inventory completeness summary contract", test_inventory_summary_contract;
     "unified browser picker", test_unified_browser_picker;
     "the BiDi host report rides the connection list", test_bidi_host_discovery;
     "raw refresh scroll identity", test_raw_refresh_scroll_identity;
     "scoped refresh failure and region recovery", test_scoped_refresh_failure_retains_read_intent;
     "visual pointer navigation", test_visual_pointer_navigation;
     "visual scroll ownership", test_visual_scroll_ownership;
     "client connection ownership", test_client_connection_ownership;
     "picker empty row reads the list", test_picker_empty_row;
     "client inventory contract", test_clients_decode;
     "native Page context contract", test_page_context_decode;
     "screenshot drag support follows the connection", test_screenshot_drag_support;
     "every pointer gesture is decided before it is sent", test_pointer_decision;
     "a refused gesture stays until the next input", test_unserved_gesture;
     "screenshot ownership, draft and stale tab", test_screenshot_ownership_and_draft;
     "viewport cadence skip inputs", test_viewport_cadence_skip_inputs;
     "read and tab selection", test_read_and_selection;
     "closed-tab refresh recovery", test_refresh_rediscovers_tabs;
     "stale response and provenance", test_stale_response;
     "session generation", test_session_generation;
     "failed refresh preserves evidence", test_failed_refresh;
     "navigation failure preserves editable URL", test_navigation_failure_recovery;
     "HTTP read status provenance", test_http_read_status_provenance;
     "source switch", test_source_switch;
     "malformed response", test_malformed_response;
     "empty tabs", test_empty_tabs;
     "which operations are refreshes", test_operation_is_refresh]
