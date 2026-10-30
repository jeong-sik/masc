module Browser_selection = Masc.Browser_selection

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

(* The scene and the screenshot are rebuilt around the chosen connection's
   fields, so each names the live connection once, whatever the browser sent
   under those names. *)
let test_live_scene_and_capture_state_their_connection () =
  let client_id = match Browser_lane.client_id_of_string "40000000-0000-4000-8000-000000000001" with
    | Ok id -> id | Error detail -> fail detail in
  let info : Browser_lane.client_info =
    {client_id;browser=Browser_lane.Firefox;version="fixture";transport=Browser_lane.Webdriver_bidi;
     engine_version="fixture";space=None} in
  let binding = Masc.Browser_binding.of_browser
    {Browser_selection.route=Browser_lane.Live_route (Some client_id);reason=Browser_selection.Explicit_browser}
    (Browser_selection.Connected info) in
  let forged = ["clientId",`String "forged";"transport",`String "carrier_pigeon"] in
  let viewport = `Assoc ["documentId",`String "fixture";"width",`Int 800;"height",`Int 600;
    "scrollX",`Int 0;"scrollY",`Int 0] in
  let stated name result =
    let fields = match result with
      | Ok (`Assoc fields) -> fields
      | Ok _ -> fail (name ^ " is not an object")
      | Error detail -> fail detail in
    List.iter (fun (key, expected) ->
      check bool (name ^ " states its " ^ key ^ " once, the route's") true
        (List.filter (fun (field, _) -> field = key) fields = [key, `String expected]))
      ["clientId", Browser_lane.client_id_to_string client_id; "transport", "webdriver_bidi"] in
  let scene = match Masc.Browser_scene.parse_request (`Assoc ["lane",`String "live";
      "clientId",`String (Browser_lane.client_id_to_string client_id);"tabId",`Int 7;"maxChars",`Int 1000]) with
    | Ok request -> request | Error detail -> fail detail in
  stated "a live scene" (Masc.Browser_scene.project scene ~binding ~started:0L (`Assoc (
    ["tabId",`Int 7;"schema",`String "masc.browser.scene.v1";"documentId",`String "fixture";
     "url",`String "https://example.org";"title",`String "Page";
     "viewport",`Assoc ["width",`Int 800;"height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0];
     "nodes",`List [];"truncated",`Bool false;"view",`String "content";"scope",`Null] @ forged)));
  stated "a live screenshot" (Surface.capture_from ~binding ~tab_id:7 ~started:0L (`Assoc (
    ["tabId",`Int 7;"url",`String "https://example.org";"title",`String "Page";
     "mimeType",`String "image/png";"viewport",viewport;
     "data",`String (Base64.encode_string "\137PNG\r\n\026\nfixture")] @ forged)))
let tab id url active = `Assoc ["id", `Int id; "title", `String "Page";
  "url", `String url; "active", `Bool active]
let owned = Masc.Browser_binding.of_browser
  {Browser_selection.route=Browser_lane.Automation_route;reason=Browser_selection.Explicit_browser}
  Browser_selection.Owned_automation
let page_of id = `Assoc ["tabId", `Int id; "url", `String "https://example.org/page";
  "title", `String "Page"; "text", `String "Observed page"; "chars", `Int 13; "truncated", `Bool false]
(* What the host's tab read does with the browser's two answers
   (Browser_addon_view.read): plan from the tab list, read the chosen tab,
   project both. [reads] lists the tabs read, newest first. *)
let with_browser ?unavailable tabs f =
  let reads = ref [] in
  let raw = match unavailable with
    | None -> `List tabs
    | Some unavailable -> `Assoc ["tabs",`List tabs;"complete",`Bool false;"unavailableTabs",`List unavailable] in
  let read tab_id = Result.bind (Surface.prepare_read ~tab_id raw) (fun plan ->
    let page = Option.map (fun (tab : Surface.tab) -> reads := tab.id :: !reads; page_of tab.id)
      (Surface.selected_tab plan) in
    Surface.project_read plan ~binding:owned ~started:0L ~page) in
  f read reads
let read_ok read tab_id = match read tab_id with Ok data -> data | Error detail -> fail detail
let selection data = Yojson.Safe.Util.member "selection" data
let test_partial_inventory_preserves_requested_work () =
  let unavailable = [`Assoc ["id",`Int 12;"error",`String "unsupported operation"]] in
  with_browser ~unavailable [tab 41 "https://example.org/page" true] (fun read reads ->
    let data = read_ok read (Some 41) in
    check bool "successful read retains incomplete inventory" true
      (Yojson.Safe.Util.member "complete" data = `Bool false);
    check bool "unreadable tab evidence is retained" true
      (Yojson.Safe.Util.member "unavailableTabs" data = `List unavailable);
    (match read (Some 12) with
     | Error detail ->
       check string "present is distinguished from closed"
         "selected tab 12 is present but unreadable: unsupported operation" detail
     | _ -> fail "unreadable requested tab was substituted or silently lost");
    check (list int) "only the requested readable tab was read" [41] !reads)

let test_partial_inventory_without_unavailable_tabs () =
  with_browser ~unavailable:[] [tab 41 "https://example.org/page" true] (fun read reads ->
    let data = read_ok read (Some 41) in
    check bool "empty unavailable list does not claim a complete inventory" true
      (Yojson.Safe.Util.member "complete" data = `Bool false
       && Yojson.Safe.Util.member "unavailableTabs" data = `List []);
    check (list int) "the requested readable tab is still read" [41] !reads);
  with_browser ~unavailable:[] [] (fun read reads ->
    let data = read_ok read None in
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
  with_browser [in_window 41 (`Int 0); in_window 73 (`Int 1)] (fun read _ ->
    let rows = Yojson.Safe.Util.(read_ok read None |> member "tabs" |> to_list) in
    check bool "each tab keeps the window it is in" true
      (List.map (Yojson.Safe.Util.member "windowId") rows = [`Int 0; `Int 1]));
  with_browser [tab 41 "https://example.org/page" true] (fun read _ ->
    let rows = Yojson.Safe.Util.(read_ok read None |> member "tabs" |> to_list) in
    check bool "a tab with no window names none" true
      (List.map (Yojson.Safe.Util.member "windowId") rows = [`Null]));
  with_browser [in_window 41 (`String "w1")] (fun read _ ->
    match read None with
    | Error _ -> ()
    | Ok _ -> fail "a window that is not a number was accepted")

let test_tab_dialog_is_kept_and_checked () =
  let with_dialog id dialog = match tab id "https://example.org/page" (id = 41) with
    | `Assoc fields -> `Assoc (fields @ ["dialog", dialog])
    | other -> other in
  let dialogs tabs = with_browser tabs (fun read _ ->
    Yojson.Safe.Util.(read_ok read None |> member "tabs" |> to_list |> List.map (member "dialog"))) in
  let prompt = `Assoc ["type",`String "prompt";"message",`String "name?";"defaultValue",`String "dflt"] in
  check bool "a tab keeps the dialog it is blocked on, and one with none names none" true
    (dialogs [with_dialog 41 prompt; tab 73 "https://example.org/page" false] = [prompt; `Null]);
  List.iter (fun (label, dialog) ->
    with_browser [with_dialog 41 dialog] (fun read _ ->
      match read None with
      | Error _ -> ()
      | Ok _ -> fail ("a malformed dialog was accepted: " ^ label)))
    ["a kind the browser does not have", `Assoc ["type",`String "popup";"message",`String "x"];
     "a message that is not text", `Assoc ["type",`String "alert";"message",`Int 1];
     "no message", `Assoc ["type",`String "alert"];
     "a default that is not text", `Assoc ["type",`String "prompt";"message",`String "x";"defaultValue",`Int 1];
     "not an object", `String "alert"]

let test_any_website_selection () =
  with_browser [tab 41 "https://docs.example.org/guide" false;
                tab 73 "https://app.example.org/dashboard" true] (fun read reads ->
    check bool "active tab answer names the selection" true
      (selection (read_ok read None) = `String "active");
    check bool "requested tab answer names the selection" true
      (selection (read_ok read (Some 41)) = `String "requested");
    check (list int) "active tab then explicit tab, independent of website" [41; 73] !reads;
    check bool "closed selected tab fails" true
      (Result.is_error (read (Some 99)));
    check int "closed selection must not read another tab" 2 (List.length !reads))
let test_empty_browser () =
  with_browser [] (fun read reads ->
    let data = read_ok read None in
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
                tab 42 "https://docs.example.org/other" false] (fun read reads ->
    let data = read_ok read None in
    check bool "tab list is still reported" true
      (Yojson.Safe.Util.(data |> member "tabs" |> to_list |> List.length) = 2);
    check bool "no active tab yields none_active with a null page" true
      (selection data = `String "none_active" && Yojson.Safe.Util.member "page" data = `Null);
    check (list int) "no page read happens for an unmade choice" [] !reads;
    check bool "requesting one of the inactive tabs still reads it" true
      (selection (read_ok read (Some 42)) = `String "requested");
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
  let capture ?(actual=7) ?(payload=Base64.encode_string "\137PNG\r\n\026\nfixture") () =
    Surface.capture_from ~binding:owned ~tab_id:7 ~started:0L (`Assoc ["tabId", `Int actual;
      "url", `String "https://example.org"; "title", `String "Fixture"; "mimeType", `String "image/png";
      "data", `String payload; "viewport", `Assoc ["documentId",`String "fixture";
        "width",`Int 800;"height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0]]) in
  check bool "explicit capture succeeds" true (Result.is_ok (capture ()));
  check bool "wrong tab result refused" true (Result.is_error (capture ~actual:8 ()));
  check bool "non-image payload refused" true
    (Result.is_error (capture ~payload:(Base64.encode_string "not PNG") ()))

let test_native_capture_coordinate_scope () =
  let options=match Browser_lane.Capture.of_json (`Assoc ["fullPage",`Bool true;"scale",`String "css"]) with
    | Ok options -> options | Error detail -> fail detail in
  let viewport=`Assoc ["documentId",`String "fixture";"width",`Int 800;"height",`Int 600;
    "scrollX",`Int 0;"scrollY",`Int 0] in
  let payload=["tabId",`Int 7;"url",`String "https://example.org";"title",`String "Fixture";
    "mimeType",`String "image/png";"data",`String (Base64.encode_string "\137PNG\r\n\026\nfixture")] in
  let echo=["captureOptions",Browser_lane.Capture.to_json options] in
  let native fields=Surface.native_capture_from ~binding:owned ~tab_id:7 ~started:0L ~options (`Assoc fields) in
  (match native (payload@echo) with
   | Ok json -> check bool "page image carries options without viewport geometry" true
       (Yojson.Safe.Util.member "scope" json=`String "page"
        && Yojson.Safe.Util.member "captureOptions" json=Browser_lane.Capture.to_json options
        && Yojson.Safe.Util.member "viewport" json=`Null)
   | Error detail -> fail detail);
  List.iter (fun fields -> check bool "unbound or mixed-scope native image refused" true
      (Result.is_error (native fields)))
    [payload;payload@["captureOptions",`Assoc []];payload@echo@["viewport",viewport];
     ("tabId",`Int 8)::List.remove_assoc "tabId" (payload@echo);payload@echo@echo];
  check bool "native image cannot become a pointer frame" true
    (Result.is_error (Surface.capture_from ~binding:owned ~tab_id:7 ~started:0L
      (`Assoc (payload@echo@["viewport",viewport]))));
  check bool "HTTP capture retains typed native options" true
    (match Surface.parse_screenshot_request (`Assoc ["lane",`String "automation";"tabId",`Int 7;
      "screenshotOptions",Browser_lane.Capture.to_json options]) with
     | Ok (_,Some actual) -> actual=options | Ok (_,None)|Error _ -> false);
  List.iter (fun json -> check bool "HTTP capture rejects invalid native request" true
      (Result.is_error (Surface.parse_screenshot_request json)))
    [`Assoc ["tabId",`Int 7;"screenshotOptions",`Null];
     `Assoc ["tabId",`Int 7;"screenshotOptions",`Assoc ["path",`String "/tmp/caller.png"]];
     `Assoc ["tabId",`Int 7;"screenshotOptions",`Assoc [];"screenshotOptions",`Assoc []]]

let test_scoped_scene_acknowledgement () =
  let scene ?(url="https://example.org") ~view ~scope () = `Assoc ["tabId",`Int 7;
    "schema",`String "masc.browser.scene.v1";"documentId",`String "fixture";"url",`String url;
    "title",`String "Page";"viewport",`Assoc ["width",`Int 800;"height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0];
    "nodes",`List [];"truncated",`Bool false;"view",`String view;"scope",scope] in
  let request fields = match Masc.Browser_scene.parse_request
      (`Assoc (["lane",`String "automation";"tabId",`Int 7;"maxChars",`Int 1000] @ fields)) with
    | Ok request -> request | Error detail -> fail detail in
  let project request data = Masc.Browser_scene.project request ~binding:owned ~started:0L data in
  let scope = `Assoc ["documentId",`String "fixture";"nodeId",`String "region"] in
  let scoped = request ["scope",scope] and regions = request ["view",`String "regions"] in
  check bool "exact scoped scene accepted" true
    (Result.is_ok (project scoped (scene ~view:"content" ~scope ())));
  check bool "delayed navigation cannot return old URL as destination" true
    (Result.is_error (project (request ["expectedUrl",`String "https://example.org/destination"])
      (scene ~view:"content" ~scope:`Null ())));
  check bool "matching SPA URL is observable without new document or content readiness claim" true
    (Result.is_ok (project (request ["expectedUrl",`String "https://example.org"])
      (scene ~view:"content" ~scope:`Null ())));
  let actual_url = match project regions (scene ~url:"https://example.org/canonical" ~view:"regions" ~scope:`Null ()) with
    | Ok json -> Yojson.Safe.Util.(json |> member "url" |> to_string)
    | Error detail -> fail detail in
  check string "unguarded observation exposes final redirect URL" "https://example.org/canonical" actual_url;
  check bool "connector ignoring scope must fail rather than return whole page" true
    (Result.is_error (project scoped (scene ~view:"content" ~scope:`Null ())));
  check bool "connector ignoring region view must fail" true
    (Result.is_error (project regions (scene ~view:"content" ~scope:`Null ())));
  check bool "duplicate scope fields rejected" true (Result.is_error (Masc.Browser_scene.scope_of_json
    (`Assoc ["documentId",`String "fixture";"nodeId",`String "a";"nodeId",`String "b"])))

(* The public browser tools as a Keeper or the dashboard calls them. In a
   workspace nothing created there is no browser Add-on, so a request the
   tool accepts fails at that lookup as an unavailable dependency, while one
   it refuses fails earlier as the caller's input. *)
let addon_tool ?keeper_name tool fields = Masc.Browser_addon_tools.handle
    ~config:(Masc.Workspace.default_config no_workspace)
    ~access:Masc.Lane_addon_sources.Operator_configuration
    ~principal:(Lane_addon_call_context.Host_actor "browser-surface-tester") ~reserved:[]
    ~keeper_name ~tool ~tool_name:"BrowserTool" ~start_time:(Tool_timing.start ()) (`Assoc fields)
let refused_as_input result =
  Tool_result.failure_class result = Some Tool_result.Policy_rejection
  && (match result with
      | Tool_result.Failed failure -> failure.effect_disposition = Tool_result.Proven_pre_effect
      | Tool_result.Completed _ | Tool_result.Deferred _ -> false)
let reaches_the_addon_lookup result =
  Tool_result.failure_class result = Some Tool_result.Dependency_unavailable

let test_malformed_arguments_reach_no_browser () =
  let module Cap = Masc.Browser_capabilities in
  let invalid_id = `String "not-a-browser-uuid" in
  let read fields = addon_tool Cap.Read (("lane",`String "automation") :: ("tabId",`Int 1) :: fields) in
  List.iter (fun (name, result) -> check bool name true (refused_as_input result))
    [ "a malformed connection in tabs", addon_tool Cap.Tabs ["lane",`String "live";"clientId",invalid_id]
    ; "a malformed connection in read",
      addon_tool Cap.Read ["lane",`String "live";"clientId",invalid_id;"tabId",`Int 1]
    ; "a navigation guard on a text read",
      read ["mode",`String "text";
            "navigationSource",`Assoc ["url",`String "https://example.org/";"documentId",`String "observed"]]
    ; "a text cap below the range", read ["mode",`String "text";"maxChars",`Int 0]
    ; "a text cap past the most",
      read ["mode",`String "text";"maxChars",`Int (Masc.Browser_page_script.max_text_chars + 1)]
    ; "a malformed scene source", read ["mode",`String "scene";"navigationSource",`Assoc []]
    ; "a malformed scene scope", read ["mode",`String "scene";"scope",`Assoc []]
    ; "a malformed scene URL", read ["mode",`String "scene";"expectedUrl",`Int 1]
    ; "a scene with no tab", addon_tool Cap.Read ["lane",`String "automation";"mode",`String "scene"]
    ; "a malformed act", addon_tool Cap.Act []
    ; "an unknown session action", addon_tool Cap.Session ["action",`String "unknown"]
    ; "a malformed navigation URL", addon_tool Cap.Goto ["url",`Int 1]
    ; "a document source read with a text cap", read ["mode",`String "html";"maxChars",`Int 100]
    ; "a document source read with no tab", addon_tool Cap.Read ["lane",`String "automation";"mode",`String "html"]
    ; "a document source read in a frame",
      read ["mode",`String "html";"framePath",`List [`String "#frame"]] ];
  check bool "a well-formed text read goes on to find the browser Add-on" true
    (reaches_the_addon_lookup (read ["mode",`String "text"]));
  check bool "a document source read with a tab goes on to find the browser Add-on" true
    (reaches_the_addon_lookup (read ["mode",`String "html"]));
  (* A client may fill in every default the schema declares, so a document
     source read carrying them must still go on: no declared default may be
     an argument html refuses. *)
  let declared_defaults = Yojson.Safe.Util.(Tool_schemas_misc_toml.browser_read.Masc_domain.input_schema
    |> member "properties" |> to_assoc
    |> List.filter_map (fun (name, property) ->
      match member "default" property with `Null -> None | value -> Some (name, value))) in
  check bool "the schema walk sees the mode default" true (List.mem_assoc "mode" declared_defaults);
  let schema_defaults = List.filter (fun (name, _) -> not (List.mem name ["mode";"lane";"tabId"]))
    declared_defaults in
  check bool "a document source read carrying the schema defaults goes on to find the browser Add-on" true
    (reaches_the_addon_lookup (read (("mode",`String "html") :: schema_defaults)))

(* A click or fill on an ego snapshot target goes to a live connection only,
   with expectedUrl. *)
let test_a_snapshot_target_is_checked_before_any_browser () =
  let module Cap = Masc.Browser_capabilities in
  let interact lane fields = addon_tool Cap.Interact (("lane",`String lane) :: ("tabId",`Int 1) :: fields) in
  let click = ["action",`String "click";"target",`Assoc ["ref",`Int 12]] in
  let url = ["expectedUrl",`String "https://example.org/"] in
  let live fields = interact "live" (("clientId",`String "0c000000-0000-4000-8000-000000000001") :: fields) in
  List.iter (fun (name, result) -> check bool name true (refused_as_input result))
    [ "a target on the automation browser", interact "automation" (click @ url)
    ; "a target on the Stagehand browser", interact "stagehand" (click @ url)
    ; "a fill target on the automation browser",
      interact "automation" (["action",`String "fill";"target",`Assoc ["ref",`Int 5];"text",`String "Ada"] @ url)
    ; "a target without expectedUrl", live click ];
  check bool "a target click on a live connection goes on to find the browser Add-on" true
    (reaches_the_addon_lookup (live (click @ url)))

(* hand_off and take_over act on the whole space of a live ego connection,
   named by its observed clientId. *)
let test_a_hand_off_is_checked_before_any_browser () =
  let module Cap = Masc.Browser_capabilities in
  let act fields = addon_tool Cap.Act fields in
  let live fields = act (("lane",`String "live") :: ("clientId",`String "0c000000-0000-4000-8000-000000000001") :: fields) in
  List.iter (fun (name, result) -> check bool name true (refused_as_input result))
    [ "a hand-off on the automation browser", act ["lane",`String "automation";"action",`String "hand_off"]
    ; "a take-over on the Stagehand browser", act ["lane",`String "stagehand";"action",`String "take_over"]
    ; "a hand-off with no connection named", act ["lane",`String "live";"action",`String "hand_off"]
    ; "a hand-off with no lane", act ["action",`String "hand_off"]
    ; "a hand-off of one tab", live ["action",`String "hand_off";"tabId",`Int 1] ];
  List.iter (fun (name, result) -> check bool name true (reaches_the_addon_lookup result))
    [ "a hand-off on a named live connection goes on to find the browser Add-on", live ["action",`String "hand_off"]
    ; "and so does a take-over", live ["action",`String "take_over"] ]

(* An ego snapshot is read over a live connection only, with its scope and
   root given to that mode alone and a root that is a ref. *)
let test_a_snapshot_read_is_checked_before_any_browser () =
  let module Cap = Masc.Browser_capabilities in
  let live fields = addon_tool Cap.Read (("lane",`String "live")
    :: ("clientId",`String "0c000000-0000-4000-8000-000000000001") :: ("tabId",`Int 1) :: fields) in
  let snapshot fields = live (("mode",`String "snapshot") :: fields) in
  List.iter (fun (name, result) -> check bool name true (refused_as_input result))
    [ "a snapshot on the automation browser",
      addon_tool Cap.Read ["lane",`String "automation";"tabId",`Int 1;"mode",`String "snapshot"]
    ; "a snapshot scope on a text read", live ["mode",`String "text";"snapshotScope",`String "full_page"]
    ; "a root on a scene read", live ["mode",`String "scene";"root",`String "@12"]
    ; "a subtree with no root", snapshot ["snapshotScope",`String "subtree"]
    ; "a root that is not a ref", snapshot ["snapshotScope",`String "subtree";"root",`String "12"]
    ; "a root on a viewport snapshot", snapshot ["root",`String "@12"]
    ; "an unknown snapshot scope", snapshot ["snapshotScope",`String "page"]
    ; "a snapshot in a frame", snapshot ["framePath",`List [`String "#frame"]] ];
  List.iter (fun (name, result) -> check bool name true (reaches_the_addon_lookup result))
    [ "a viewport snapshot goes on to find the browser Add-on", snapshot []
    ; "and a subtree under a ref", snapshot ["snapshotScope",`String "subtree";"root",`String "ref=12"] ]

(* A Keeper keeps a screenshot under its workspace; another caller gets the
   image in the result. Either way the input is valid and the tool goes on
   to find the browser Add-on. *)
let test_screenshot_reaches_the_addon_with_or_without_a_keeper () =
  let read keeper_name = addon_tool ?keeper_name Masc.Browser_capabilities.Read
      ["lane",`String "automation";"mode",`String "screenshot";"tabId",`Int 73] in
  check bool "a screenshot without a Keeper goes on to find the browser Add-on" true
    (reaches_the_addon_lookup (read None));
  check bool "a Keeper's screenshot goes on to find the browser Add-on" true
    (reaches_the_addon_lookup (read (Some "browser-screenshot-keeper")))

let () = run "browser surface" ["behavior",[
  test_case "a screenshot reaches the Add-on with or without a Keeper" `Quick test_screenshot_reaches_the_addon_with_or_without_a_keeper;
  test_case "native screenshot images cannot address a viewport" `Quick test_native_capture_coordinate_scope;
  test_case "malformed tool arguments reach no browser" `Quick test_malformed_arguments_reach_no_browser;
  test_case "a snapshot read is checked before any browser" `Quick test_a_snapshot_read_is_checked_before_any_browser;
  test_case "a snapshot target is checked before any browser" `Quick test_a_snapshot_target_is_checked_before_any_browser;
  test_case "a hand-off is checked before any browser" `Quick test_a_hand_off_is_checked_before_any_browser;
  test_case "unreadable tabs do not block the requested readable tab" `Quick test_partial_inventory_preserves_requested_work;
  test_case "partial inventories remain incomplete without unavailable tabs" `Quick test_partial_inventory_without_unavailable_tabs;
  test_case "a tab keeps its window and a malformed one is refused" `Quick test_tab_window_is_kept_and_checked;
  test_case "a tab keeps and checks the dialog it is blocked on" `Quick test_tab_dialog_is_kept_and_checked;
  test_case "scoped scene acknowledgement" `Quick test_scoped_scene_acknowledgement;
  test_case "read any website by active or explicit tab" `Quick test_any_website_selection;
  test_case "empty browser has no page" `Quick test_empty_browser;
  test_case "no active tab is not guessed" `Quick test_no_active_tab_is_not_guessed;
  test_case "scene node requires sourceContext" `Quick test_scene_node_requires_source_context;
  test_case "invalid input is refused" `Quick test_strict_input;
  test_case "capture target and image identity" `Quick test_capture_identity;
  test_case "a live scene and screenshot state their connection" `Quick
    test_live_scene_and_capture_state_their_connection]]
