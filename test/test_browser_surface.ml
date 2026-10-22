module Browser_selection = Masc.Browser_selection
(* This standalone fixture explicitly enables new Browser work. *)
let () = Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled))

open Alcotest
module Surface = Masc.Browser_surface
(* A workspace path nothing creates: these scenarios never reach an installed
   browser-lane host, so the tools observe no launcher there. *)
let no_workspace = Filename.concat (Filename.get_temp_dir_name ()) "masc-browser-surface-no-workspace"
let test_strict_input () =
  List.iter (fun json -> match Surface.parse_request json with
      | Error _ -> () | Ok _ -> fail "invalid read request accepted")
    [`Assoc ["lane", `Bool true]; `Assoc ["app",`String "unknown"];
     `Assoc ["tabId",`Int (-1)]; `Assoc ["tabID",`Int 1]]

(* The scene and the screenshot are rebuilt around the route's connection
   fields, so each names the live connection once, whatever the browser sent
   under those names. *)
let test_live_scene_and_capture_state_their_connection () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let client_id = match Browser_lane.client_id_of_string "40000000-0000-4000-8000-000000000001" with
        | Ok id -> id | Error detail -> fail detail in
      let info : Browser_lane.client_info =
        {client_id;browser=Browser_lane.Firefox;version="fixture";transport=Browser_lane.Webdriver_bidi;
         engine_version="fixture"} in
      Eio.Switch.on_release sw (fun () -> ignore (Browser_lane.disconnect_client ~client_id));
      ignore (Browser_lane.take_command ~client_info:info ~window_sec:0.001);
      let request : Surface.request = {route=Browser_selection.Exact (Browser_lane.Live_route (Some client_id));tab_id=Some 7} in
      let forged = ["clientId",`String "forged";"transport",`String "carrier_pigeon"] in
      let viewport = `Assoc ["documentId",`String "fixture";"width",`Int 800;"height",`Int 600;
        "scrollX",`Int 0;"scrollY",`Int 0] in
      let answered name read data =
        let pending = Eio.Fiber.fork_promise ~sw read in
        let command = match Browser_lane.take_command ~client_info:info ~window_sec:1. with
          | Ok (Some command) -> command | _ -> fail (name ^ " did not reach the browser") in
        ignore (Browser_lane.deliver_result ~client_id ~id:command.id
          ~payload:(`Assoc ["ok",`Bool true;"data",`Assoc (data @ forged)]));
        let fields = match Eio.Promise.await_exn pending with
          | Ok (`Assoc fields) -> fields
          | Ok _ -> fail (name ^ " is not an object")
          | Error failure -> fail (Surface.failure_message failure) in
        List.iter (fun (key, expected) ->
          check bool (name ^ " states its " ^ key ^ " once, the route's") true
            (List.filter (fun (field, _) -> field = key) fields = [key, `String expected]))
          ["clientId", Browser_lane.client_id_to_string client_id; "transport", "webdriver_bidi"] in
      answered "a live scene" (fun () -> Masc.Browser_scene.read request ~max_chars:1000)
        ["tabId",`Int 7;"schema",`String "masc.browser.scene.v1";"documentId",`String "fixture";
         "url",`String "https://example.org";"title",`String "Page";
         "viewport",`Assoc ["width",`Int 800;"height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0];
         "nodes",`List [];"truncated",`Bool false;"view",`String "content";"scope",`Null];
      answered "a live screenshot" (fun () -> Surface.capture request)
        ["tabId",`Int 7;"url",`String "https://example.org";"title",`String "Page";
         "mimeType",`String "image/png";"viewport",viewport;
         "data",`String (Base64.encode_string "\137PNG\r\n\026\nfixture")]))
let test_remote_failure () =
  match Surface.decode_answer ~lane:Browser_lane.Lane_name.Live (Browser_lane.Answered
    (`Assoc ["ok",`Bool false;"error",`String "tab closed"])) with
  | Error "tab closed" -> () | _ -> fail "backend failure became success"
(* An absent backend is reported the way its own lane is set up: the
   stagehand lane has no connection to lose, only a table to configure. *)
let test_absent_lane_names_its_setup () =
  let lanes = Browser_lane.Lane_name.all in
  List.iter (fun lane ->
      match Surface.decode_answer ~lane Browser_lane.Lane_absent with
      | Error message -> check string (Browser_lane.Lane_name.to_wire lane) (Browser_lane.lane_absent_message lane) message
      | Ok _ -> fail "an absent lane answered")
    lanes;
  check int "each lane has its own message" (List.length lanes)
    (List.length (List.sort_uniq String.compare (List.map Browser_lane.lane_absent_message lanes)))
let answer data = Browser_lane.Answered (`Assoc ["ok", `Bool true; "data", data])
let tab id url active = `Assoc ["id", `Int id; "title", `String "Page";
  "url", `String url; "active", `Bool active]
let with_browser ?unavailable tabs f =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let reads = ref [] in
      Browser_lane.install_automation_executor (Some (function
        | Browser_lane.Tabs_list -> answer (match unavailable with
            | None -> `List tabs
            | Some unavailable -> `Assoc ["tabs",`List tabs;"complete",`Bool false;
                               "unavailableTabs",`List unavailable])
        | Browser_lane.Page_read { tab_id = Some id; max_chars = Some 50_000 } ->
          reads := id :: !reads;
          answer (`Assoc ["tabId", `Int id; "url", `String "https://example.org/page";
            "title", `String "Page"; "text", `String "Observed page";
            "chars", `Int 13; "truncated", `Bool false])
        | _ -> fail "unexpected browser command"));
      Eio.Switch.on_release sw (fun () -> Browser_lane.install_automation_executor None);
      f reads))
let request tab_id : Surface.request = { route = Browser_selection.Exact Browser_lane.Automation_route; tab_id }
let read_ok request = match Surface.read request with
  | Ok data -> data | Error failure -> fail (Surface.failure_message failure)
let selection data = Yojson.Safe.Util.member "selection" data
let test_partial_inventory_preserves_requested_work () =
  let unavailable = [`Assoc ["id",`Int 12;"error",`String "unsupported operation"]] in
  with_browser ~unavailable [tab 41 "https://example.org/page" true] (fun reads ->
    let data = read_ok (request (Some 41)) in
    check bool "successful read retains incomplete inventory" true
      (Yojson.Safe.Util.member "complete" data = `Bool false);
    check bool "unreadable tab evidence is retained" true
      (Yojson.Safe.Util.member "unavailableTabs" data = `List unavailable);
    (match Surface.read (request (Some 12)) with
     | Error (Surface.Unobserved detail) ->
       check string "present is distinguished from closed"
         "selected tab 12 is present but unreadable: unsupported operation" detail
     | _ -> fail "unreadable requested tab was substituted or silently lost");
    check (list int) "only the requested readable tab was read" [41] !reads)

let test_partial_inventory_without_unavailable_tabs () =
  with_browser ~unavailable:[] [tab 41 "https://example.org/page" true] (fun reads ->
    let data = read_ok (request (Some 41)) in
    check bool "empty unavailable list does not claim a complete inventory" true
      (Yojson.Safe.Util.member "complete" data = `Bool false
       && Yojson.Safe.Util.member "unavailableTabs" data = `List []);
    check (list int) "the requested readable tab is still read" [41] !reads);
  with_browser ~unavailable:[] [] (fun reads ->
    let data = read_ok (request None) in
    check bool "an empty partial inventory remains explicitly incomplete" true
      (Yojson.Safe.Util.member "complete" data = `Bool false
       && Yojson.Safe.Util.member "unavailableTabs" data = `List []
       && selection data = `String "none_active"
       && Yojson.Safe.Util.member "page" data = `Null);
    check (list int) "no page is guessed for an empty partial inventory" [] !reads)

let test_tab_window_is_kept_and_checked () =
  let in_window id window = match tab id "https://example.org/page" (id = 41) with
    | `Assoc fields -> `Assoc (fields @ ["windowId", window])
    | other -> other in
  with_browser [in_window 41 (`Int 0); in_window 73 (`Int 1)] (fun _ ->
    let rows = Yojson.Safe.Util.(read_ok (request None) |> member "tabs" |> to_list) in
    check bool "each tab keeps the window it is in" true
      (List.map (Yojson.Safe.Util.member "windowId") rows = [`Int 0; `Int 1]));
  with_browser [tab 41 "https://example.org/page" true] (fun _ ->
    let rows = Yojson.Safe.Util.(read_ok (request None) |> member "tabs" |> to_list) in
    check bool "a tab with no window names none" true
      (List.map (Yojson.Safe.Util.member "windowId") rows = [`Null]));
  with_browser [in_window 41 (`String "w1")] (fun _ ->
    match Surface.read (request None) with
    | Error _ -> ()
    | Ok _ -> fail "a window that is not a number was accepted")

let test_transport_unavailability_is_not_a_workflow_refusal () =
  List.iter (fun answer ->
    (match Surface.observe_answer ~lane:Browser_lane.Lane_name.Live answer with
     | Error (Surface.Unavailable _) -> ()
     | _ -> fail "transport unavailability lost its type"))
    [Browser_lane.Timed_out; Browser_lane.Lane_absent]

let test_any_website_selection () =
  with_browser [tab 41 "https://docs.example.org/guide" false;
                tab 73 "https://app.example.org/dashboard" true] (fun reads ->
    check bool "active tab answer names the selection" true
      (selection (read_ok (request None)) = `String "active");
    check bool "requested tab answer names the selection" true
      (selection (read_ok (request (Some 41))) = `String "requested");
    check (list int) "active tab then explicit tab, independent of website" [41; 73] !reads;
    check bool "closed selected tab fails" true
      (Result.is_error (Surface.read (request (Some 99))));
    check int "closed selection must not read another tab" 2 (List.length !reads))
let test_empty_browser () =
  with_browser [] (fun reads ->
    let data = read_ok (request None) in
    check bool "empty tabs are a successful empty observation" true
      (Yojson.Safe.Util.member "tabs" data = `List []
       && Yojson.Safe.Util.member "page" data = `Null
       && selection data = `String "none_active");
    check (list int) "empty browser does not read an arbitrary page" [] !reads)

(* Proves F410: with no requested tab and no active tab the read does not
   guess the first listed tab. The answer keeps the tab list, says
   selection = none_active and page = null, and issues no page read. On
   origin/main this returns tab 41's page and reads it. *)
let test_no_active_tab_is_not_guessed () =
  with_browser [tab 41 "https://docs.example.org/guide" false;
                tab 42 "https://docs.example.org/other" false] (fun reads ->
    let data = read_ok (request None) in
    check bool "tab list is still reported" true
      (Yojson.Safe.Util.(data |> member "tabs" |> to_list |> List.length) = 2);
    check bool "no active tab yields none_active with a null page" true
      (selection data = `String "none_active" && Yojson.Safe.Util.member "page" data = `Null);
    check (list int) "no page read happens for an unmade choice" [] !reads;
    check bool "requesting one of the inactive tabs still reads it" true
      (selection (read_ok (request (Some 42))) = `String "requested");
    check (list int) "only the requested tab was read" [42] !reads)

(* Proves F296: a scene node record without a sourceContext key is a
   producer defect and fails the scene decode. On origin/main the missing
   key folds into Browser_source_context.Unmapped and the scene decodes. *)
let test_scene_node_requires_source_context () =
  let node fields = `Assoc (["nodeId",`String "n";"kind",`String "text";"tag",`String "p";
    "text",`String "Body";"color",`String "black";"fontSize",`Int 16;"fontWeight",`String "400";
    "whiteSpace",`String "normal";
    "rects",`List [`Assoc ["x",`Int 0;"y",`Int 0;"width",`Int 10;"height",`Int 10]]] @ fields) in
  let scene node = `Assoc ["schema",`String "masc.browser.scene.v1";"documentId",`String "doc";
    "url",`String "https://example.org";"title",`String "Page";
    "viewport",`Assoc ["width",`Int 800;"height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0];
    "nodes",`List [node];"truncated",`Bool false;"view",`String "content";"scope",`Null] in
  (match Masc.Browser_scene.of_json (scene (node [])) with
   | Ok _ -> fail "scene node without sourceContext decoded as unmapped"
   | Error detail -> check string "missing key is named" "scene missing sourceContext" detail);
  (match Masc.Browser_scene.of_json (scene (node ["sourceContext",`Null])) with
   | Ok (scene : Masc.Browser_scene.t) ->
     check bool "explicit null is the unmapped element" true
       (List.map (fun (n : Masc.Browser_scene.node) -> n.source_context) scene.nodes
        = [Masc.Browser_source_context.Unmapped])
   | Error detail -> fail detail)

let test_capture_identity () =
  check bool "capture requires an explicit tab" true
    (Result.is_error (Surface.parse_capture_request (`Assoc [])));
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let actual_id = ref 7 in
      let payload = ref (Base64.encode_string "\137PNG\r\n\026\nfixture") in
      Browser_lane.install_automation_executor (Some (function
        | Browser_lane.Page_capture {tab_id=7} ->
          answer (`Assoc ["tabId", `Int !actual_id; "url", `String "https://example.org";
            "title", `String "Fixture"; "mimeType", `String "image/png";
            "data", `String !payload; "viewport", `Assoc ["documentId",`String "fixture";
              "width",`Int 800;"height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0]])
        | _ -> fail "capture used an implicit or different target"));
      Eio.Switch.on_release sw (fun () -> Browser_lane.install_automation_executor None);
      check bool "explicit capture succeeds" true
        (Result.is_ok (Surface.capture (request (Some 7))));
      actual_id := 8;
      check bool "wrong tab result refused" true
        (Result.is_error (Surface.capture (request (Some 7))));
      actual_id := 7; payload := Base64.encode_string "not PNG";
      check bool "non-image payload refused" true
        (Result.is_error (Surface.capture (request (Some 7))))))

let test_live_read_pins_client_between_hops () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let current = ref Browser_lane.Enabled in
      Browser_lane.install_activity_observer (Some (fun _ -> !current));
      Eio.Switch.on_release sw (fun () -> Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled)));
      let info raw browser : Browser_lane.client_info =
        let client_id = match Browser_lane.client_id_of_string raw with
          | Ok id -> id | Error error -> fail error in
        {client_id; browser; version="fixture"; transport=Browser_lane.Web_extension; engine_version="155.0.1"} in
      let first = info "10000000-0000-4000-8000-000000000001" Browser_lane.Firefox in
      let second = info "10000000-0000-4000-8000-000000000002" Browser_lane.Zen in
      List.iter (fun info -> Eio.Switch.on_release sw (fun () ->
        ignore (Browser_lane.disconnect_client ~client_id:info.Browser_lane.client_id))) [first;second];
      ignore (Browser_lane.take_command ~client_info:first ~window_sec:0.001);
      let pending = Eio.Fiber.fork_promise ~sw (fun () ->
        Surface.read {route=Browser_selection.Exact (Browser_lane.Live_route None); tab_id=None}) in
      let take info = match Browser_lane.take_command ~client_info:info ~window_sec:1. with
        | Ok (Some command) -> command | _ -> fail "selected client command missing" in
      let tabs_command = take first in
      ignore (Browser_lane.take_command ~client_info:second ~window_sec:0.001);
      current := Browser_lane.Disabled;
      ignore (Browser_lane.deliver_result ~client_id:first.client_id ~id:tabs_command.id
        ~payload:(`Assoc ["ok", `Bool true; "data", `List [tab 1 "https://example.org/first" true]]));
      check bool "new client cannot consume next hop" true
        (Browser_lane.take_command ~client_info:second ~window_sec:0.002 = Ok None);
      let read_command = take first in
      ignore (Browser_lane.deliver_result ~client_id:first.client_id ~id:read_command.id
        ~payload:(`Assoc ["ok", `Bool true; "data", `Assoc [
          "url", `String "https://example.org/first"; "title", `String "First browser";
          "text", `String "first-owned"; "chars", `Int 11; "truncated", `Bool false]]));
      match Eio.Promise.await pending with
      | Ok (Ok data) ->
        check bool "new live read is refused after off" true
          (Result.is_error (Surface.read {route=Browser_selection.Exact (Browser_lane.Live_route (Some first.client_id));tab_id=Some 1}));
        check bool "reply identifies the original single client" true
          (Yojson.Safe.Util.member "clientId" data = `String (Browser_lane.client_id_to_string first.client_id));
        check bool "and how that browser is reached" true
          (Yojson.Safe.Util.member "transport" data
           = `String (Browser_lane.live_transport_to_string first.transport));
        check bool "page belongs to the pinned browser" true
          (Yojson.Safe.Util.(data |> member "page" |> member "text") = `String "first-owned")
      | _ -> fail "second connection disrupted the once-resolved read"))

let test_scoped_scene_acknowledgement () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let ignores_scope = ref false in
      let observed_url = ref "https://example.org" in
      Browser_lane.install_automation_executor (Some (function
        | Browser_lane.Page_scene {tab_id;view;scope;_} ->
          let scope_json = match scope with None -> `Null | Some target ->
            `Assoc ["documentId",`String target.document_id;"nodeId",`String target.node_id] in
          answer (`Assoc ["tabId",`Int tab_id;"schema",`String "masc.browser.scene.v1";
            "documentId",`String "fixture";"url",`String !observed_url;"title",`String "Page";
            "viewport",`Assoc ["width",`Int 800;"height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0];
            "nodes",`List [];"truncated",`Bool false;
            "view",`String (if !ignores_scope then "content" else match view with Regions -> "regions" | Content -> "content");
            "scope",(if !ignores_scope then `Null else scope_json)])
        | _ -> fail "scoped scene dispatched an unrelated tool"));
      Eio.Switch.on_release sw (fun () -> Browser_lane.install_automation_executor None);
      let scope : Browser_lane.node_ref = {document_id="fixture";node_id="region"} in
      let read () = Masc.Browser_scene.read ~scope (request (Some 7)) ~max_chars:1000 in
      check bool "exact scoped scene accepted" true (Result.is_ok (read ()));
      check bool "delayed navigation cannot return old URL as destination" true
        (Result.is_error (Masc.Browser_scene.read ~expected_url:"https://example.org/destination"
          (request (Some 7)) ~max_chars:1000));
      check bool "matching SPA URL is observable without new document or content readiness claim" true
        (Result.is_ok (Masc.Browser_scene.read ~expected_url:"https://example.org"
          (request (Some 7)) ~max_chars:1000));
      observed_url := "https://example.org/canonical";
      let observed = Masc.Browser_scene.read ~view:Browser_lane.Regions (request (Some 7)) ~max_chars:1000 in
      let actual_url = match observed with
        | Ok json -> Yojson.Safe.Util.(json |> member "url" |> to_string)
        | Error failure -> fail (Surface.failure_message failure) in
      check string "unguarded observation exposes final redirect URL" "https://example.org/canonical" actual_url;
      ignores_scope := true;
      check bool "connector ignoring scope must fail rather than return whole page" true (Result.is_error (read ()));
      check bool "connector ignoring region view must fail" true
        (Result.is_error (Masc.Browser_scene.read ~view:Browser_lane.Regions (request (Some 7)) ~max_chars:1000));
      check bool "duplicate scope fields rejected" true (Result.is_error (Masc.Browser_scene.scope_of_json
        (`Assoc ["documentId",`String "fixture";"nodeId",`String "a";"nodeId",`String "b"])))))

let test_compound_read_keeps_admission () =
  Eio_main.run (fun env ->
    Time_compat.set_clock env#clock;
    Eio.Switch.run (fun sw ->
      let current = ref Browser_lane.Enabled in
      Browser_lane.install_activity_observer (Some (fun _ -> !current));
      Eio.Switch.on_release sw (fun () ->
        Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled));
        Browser_lane.install_automation_executor None;
        Browser_lane.install_stagehand_executor None);
      List.iter (fun (route, install) ->
        current := Browser_lane.Enabled;
        let calls = ref [] in
        install (Some (fun verb ->
          calls := verb :: !calls;
          match verb with
          | Browser_lane.Tabs_list ->
              current := Browser_lane.Disabled;
              Browser_lane.Answered (`Assoc ["ok",`Bool true;"data",`List [
                `Assoc ["id",`Int 7;"title",`String "accepted";"url",`String "https://example.org/";"active",`Bool true]]])
          | Browser_lane.Page_read _ -> Browser_lane.Answered (`Assoc ["ok",`Bool true;"data",`Assoc [
              "url",`String "https://example.org/";"title",`String "accepted";
              "text",`String "accepted page";"chars",`Int 13;"truncated",`Bool false]])
          | _ -> fail "compound read sent a different command"));
        let request : Surface.request = {route=Browser_selection.Exact route;tab_id=None} in
        let result = match Surface.read request with Ok value -> value | Error failure -> fail (Surface.failure_message failure) in
        check string "accepted page survives activity publication between hops" "accepted page"
          Yojson.Safe.Util.(member "page" result |> member "text" |> to_string);
        check int "both read phases execute" 2 (List.length !calls);
        check bool "new read is refused after off" true (Result.is_error (Surface.read request));
        check int "refused new request sends no command" 2 (List.length !calls))
        [Browser_lane.Automation_route,(fun executor -> Browser_lane.install_automation_executor executor);
         Browser_lane.Stagehand_route,(fun executor -> Browser_lane.install_stagehand_executor
           (Option.map (fun execute ~actor:_ verb -> execute verb) executor))]))

let test_automatic_selection_keeps_observed_browser () =
  Eio_main.run (fun env ->
    Time_compat.set_clock env#clock;
    Eio.Switch.run (fun sw ->
      let calls = ref [] in
      let opened = ref true in
      let execute verb =
        calls := verb :: !calls;
        match verb with
        | Browser_lane.Tabs_list -> answer (`List [tab 7 "https://example.org/" true])
        | Browser_lane.Page_read _ -> answer (`Assoc ["tabId",`Int 7;"url",`String "https://example.org/";
            "title",`String "Page";"text",`String "original browser";"chars",`Int 16;"truncated",`Bool false])
        | Browser_lane.Page_interact _ -> answer (`Assoc ["tabId",`Int 7;"url",`String "https://example.org/"])
        | Browser_lane.Page_document _ | Browser_lane.Page_downloads _ | Browser_lane.Page_capture _
        | Browser_lane.Page_scene _ | Browser_lane.Session_open _ | Browser_lane.Session_close
        | Browser_lane.Session_status | Browser_lane.Page_goto _ | Browser_lane.Page_elements _
        | Browser_lane.Page_act _ | Browser_lane.Page_context _ | Browser_lane.Page_instruct _
        | Browser_lane.Page_locate _ | Browser_lane.Page_extract _
        | Browser_lane.Page_console _ | Browser_lane.Page_network _ | Browser_lane.Page_cookies _ ->
          fail "unexpected command during automatic browser scenario" in
      Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled));
      Browser_lane.install_stagehand_executor (Some (fun ~actor:_ verb -> execute verb));
      Browser_lane.install_server_session_observer Browser_lane.Server_stagehand
        (Some (fun () -> if !opened then Browser_lane.Browser_open else Browser_lane.Browser_closed));
      Eio.Switch.on_release sw (fun () ->
        Browser_lane.install_stagehand_executor None;
        Browser_lane.install_server_session_observer Browser_lane.Server_stagehand None;
        Browser_lane.install_automation_executor None;
        Browser_lane.install_server_session_observer Browser_lane.Server_automation None);
      let initial = read_ok {route=Browser_selection.Automatic;tab_id=None} in
      check string "discovery binds its actual browser" "stagehand"
        Yojson.Safe.Util.(initial |> member "browserSelection" |> member "lane" |> to_string);
      check string "the active page is read on that browser" "original browser"
        Yojson.Safe.Util.(initial |> member "page" |> member "text" |> to_string);
      let before = List.length !calls in
      check bool "a browser-local tab cannot be automatically rerouted" true
        (Surface.read {route=Browser_selection.Automatic;tab_id=Some 7}
          = Error (Surface.Unchosen Browser_selection.Binding_required));
      check int "missing binding dispatches nothing" before (List.length !calls);
      let request = match Masc.Browser_interaction.parse (`Assoc ["lane",`String "stagehand";
          "tabId",`Int 7;"action",`String "scroll";"x",`Int 0;"y",`Int 100]) with
        | Ok request -> request | Error detail -> fail detail in
      let receipt = match Masc.Browser_interaction.perform request with
        | Ok receipt -> receipt | Error detail -> fail detail in
      check string "mutation receipt retains exact observed browser" "stagehand"
        Yojson.Safe.Util.(receipt |> member "browserSelection" |> member "lane" |> to_string);
      opened := false;
      Browser_lane.install_stagehand_executor None;
      Browser_lane.install_automation_executor (Some execute);
      Browser_lane.install_server_session_observer Browser_lane.Server_automation (Some (fun () -> Browser_lane.Browser_open));
      let before = List.length !calls in
      check bool "a lost owner does not fall back to another open browser" true
        (Result.is_error (Masc.Browser_interaction.perform request));
      check int "lost-owner mutation is never dispatched elsewhere" before (List.length !calls)))

let () = run "browser surface" ["behavior",[
  test_case "automatic discovery binds subsequent observations and input" `Quick test_automatic_selection_keeps_observed_browser;
  test_case "unreadable tabs do not block the requested readable tab" `Quick test_partial_inventory_preserves_requested_work;
  test_case "partial inventories remain incomplete without unavailable tabs" `Quick test_partial_inventory_without_unavailable_tabs;
  test_case "a tab keeps its window and a malformed one is refused" `Quick test_tab_window_is_kept_and_checked;
  test_case "transport availability keeps its failure class" `Quick test_transport_unavailability_is_not_a_workflow_refusal;
  test_case "compound read retains its original admission" `Quick test_compound_read_keeps_admission;
  test_case "scoped scene acknowledgement" `Quick test_scoped_scene_acknowledgement;
  test_case "read any website by active or explicit tab" `Quick test_any_website_selection;
  test_case "empty browser has no page" `Quick test_empty_browser;
  test_case "no active tab is not guessed" `Quick test_no_active_tab_is_not_guessed;
  test_case "scene node requires sourceContext" `Quick test_scene_node_requires_source_context;
  test_case "invalid input is refused" `Quick test_strict_input;
  test_case "backend failure is visible" `Quick test_remote_failure;
  test_case "an absent lane names its own setup" `Quick test_absent_lane_names_its_setup;
  test_case "capture target and image identity" `Quick test_capture_identity;
  test_case "a live scene and screenshot state their connection" `Quick
    test_live_scene_and_capture_state_their_connection;
  test_case "live read pins client across both hops" `Quick test_live_read_pins_client_between_hops]]
