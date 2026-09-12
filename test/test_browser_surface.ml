open Alcotest
module Surface = Masc.Browser_surface
let test_strict_input () =
  List.iter (fun json -> match Surface.parse_request json with
      | Error _ -> () | Ok _ -> fail "invalid read request accepted")
    [`Assoc ["lane", `Bool true]; `Assoc ["app",`String "unknown"];
     `Assoc ["tabId",`Int (-1)]; `Assoc ["tabID",`Int 1]]

let test_tool_input_recovery () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let module Tools = Masc.Tool_misc_browser_lane in
      let valid_id = "10000000-0000-4000-8000-000000000001" in
      let invalid_id = valid_id ^ "1" in
      let client_id = match Browser_lane.client_id_of_string valid_id with
        | Ok id -> id | Error detail -> fail detail in
      let info : Browser_lane.client_info =
        {client_id;browser=Browser_lane.Firefox;version="fixture";engine_version="fixture"} in
      Eio.Switch.on_release sw (fun () -> ignore (Browser_lane.disconnect_client ~client_id));
      ignore (Browser_lane.take_command ~client_info:info ~window_sec:0.001);
      let input_id id = `Assoc ["lane",`String "live";"clientId",`String id] in
      let interact id = `Assoc ["lane",`String "live";"clientId",`String id;
        "tabId",`Int 1;"action",`String "follow_link";"expectedUrl",`String "https://example.org/";
        "documentId",`String "observed";"nodeId",`String "link"] in
      let read fields = Tools.handle_read ~tool_name:"BrowserRead" ~start_time:0.
        (`Assoc (["tabId",`Int 1] @ fields)) in
      let cases = [
        "malformed connection in tabs", (fun () -> Tools.handle_tabs ~tool_name:"BrowserTabs"
          ~start_time:0. (input_id invalid_id));
        "malformed connection in read", (fun () -> read ["clientId",`String invalid_id]);
        "malformed connection in follow", (fun () ->
          let result, phase = Tools.handle_interact_with_phase ~tool_name:"BrowserInteract"
            ~start_time:0. (interact invalid_id) in
          check bool "argument failure happens before interaction effects" true
            (phase = Tool_result.Proven_pre_effect); result);
        "navigation guard on text read", (fun () -> read ["mode",`String "text";
          "navigationSource",`Assoc ["url",`String "https://example.org/";"documentId",`String "observed"]]);
        "malformed scene source", (fun () -> read ["mode",`String "scene";"navigationSource",`Assoc []]);
        "malformed scene scope", (fun () -> read ["mode",`String "scene";"scope",`Assoc []]);
        "malformed scene URL", (fun () -> read ["mode",`String "scene";"expectedUrl",`Int 1]);
        "missing scene tab", (fun () -> Tools.handle_read ~tool_name:"BrowserRead"
          ~start_time:0. (`Assoc ["mode",`String "scene"]));
        "malformed act", (fun () -> Tools.handle_act ~tool_name:"BrowserAct"
          ~start_time:0. (`Assoc []));
        "unknown session action", (fun () -> Tools.handle_session ~tool_name:"BrowserOpen"
          ~start_time:0. (`Assoc ["action",`String "unknown"]));
        "malformed navigation URL", (fun () -> Tools.handle_goto ~tool_name:"BrowserGoto"
          ~start_time:0. (`Assoc ["url",`Int 1]))] in
      List.iter (fun (name, run) ->
        match run () with
        | Tool_result.Failed failure ->
          check bool (name ^ " is caller validation, not changed-state rejection") true
            (failure.class_ = Tool_result.Policy_rejection);
          check bool (name ^ " has no dispatched effect") true
            (failure.effect_disposition = Tool_result.Proven_pre_effect);
          check string (name ^ " carries typed invalid-input detail") "invalid_input"
            Yojson.Safe.Util.(failure.data |> member "kind" |> to_string)
        | _ -> fail (name ^ " was accepted")) cases;
      check bool "malformed requests queued no command to the connected browser" true
        (Browser_lane.take_command ~client_info:info ~window_sec:0.001 = Ok None);
      let unavailable, phase = Tools.handle_interact_with_phase ~tool_name:"BrowserInteract"
        ~start_time:0. (interact "10000000-0000-4000-8000-000000000002") in
      check bool "valid identity of an absent browser remains a state rejection" true
        (Tool_result.failure_class unavailable = Some Tool_result.Workflow_rejection
         && phase = Tool_result.Proven_pre_effect);
      let corrected = Eio.Fiber.fork_promise ~sw (fun () ->
        Tools.handle_tabs ~tool_name:"BrowserTabs" ~start_time:0. (input_id valid_id)) in
      let command = match Browser_lane.take_command ~client_info:info ~window_sec:1. with
        | Ok (Some command) -> command | _ -> fail "corrected request did not reach the same browser" in
      ignore (Browser_lane.deliver_result ~client_id ~id:command.id
        ~payload:(`Assoc ["ok",`Bool true;"data",`List []]));
      let result = Eio.Promise.await_exn corrected in
      check bool "correcting the argument succeeds without reconnecting or changing the page" true
        (match result with Tool_result.Completed _ -> true | _ -> false);
      check string "corrected response retains the observed connection" valid_id
        Yojson.Safe.Util.(Tool_result.data result |> member "clientId" |> to_string)))
let test_remote_failure () =
  match Surface.decode_answer (Browser_lane.Answered
    (`Assoc ["ok",`Bool false;"error",`String "tab closed"])) with
  | Error "tab closed" -> () | _ -> fail "backend failure became success"
let answer data = Browser_lane.Answered (`Assoc ["ok", `Bool true; "data", data])
let tab id url active = `Assoc ["id", `Int id; "title", `String "Page";
  "url", `String url; "active", `Bool active]
let with_browser tabs f =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let reads = ref [] in
      Browser_lane.install_automation_executor (Some (function
        | Browser_lane.Tabs_list -> answer (`List tabs)
        | Browser_lane.Page_read { tab_id = Some id; max_chars = Some 50_000 } ->
          reads := id :: !reads;
          answer (`Assoc ["tabId", `Int id; "url", `String "https://example.org/page";
            "title", `String "Page"; "text", `String "Observed page";
            "chars", `Int 13; "truncated", `Bool false])
        | _ -> fail "unexpected browser command"));
      Eio.Switch.on_release sw (fun () -> Browser_lane.install_automation_executor None);
      f reads))
let request tab_id : Surface.request = { source = Automation; tab_id; client_id=None }
let read_ok request = match Surface.read request with
  | Ok data -> data | Error detail -> fail detail
let test_any_website_selection () =
  with_browser [tab 41 "https://docs.example.org/guide" false;
                tab 73 "https://app.example.org/dashboard" true] (fun reads ->
    ignore (read_ok (request None));
    ignore (read_ok (request (Some 41)));
    check (list int) "active tab then explicit tab, independent of website" [41; 73] !reads;
    check bool "closed selected tab fails" true
      (Result.is_error (Surface.read (request (Some 99))));
    check int "closed selection must not read another tab" 2 (List.length !reads))
let test_empty_browser () =
  with_browser [] (fun reads ->
    let data = read_ok (request None) in
    check bool "empty tabs are a successful empty observation" true
      (Yojson.Safe.Util.member "tabs" data = `List []
       && Yojson.Safe.Util.member "page" data = `Null);
    check (list int) "empty browser does not read an arbitrary page" [] !reads)

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
      let info raw browser : Browser_lane.client_info =
        let client_id = match Browser_lane.client_id_of_string raw with
          | Ok id -> id | Error error -> fail error in
        {client_id; browser; version="fixture"; engine_version="155.0.1"} in
      let first = info "10000000-0000-4000-8000-000000000001" Browser_lane.Firefox in
      let second = info "10000000-0000-4000-8000-000000000002" Browser_lane.Zen in
      List.iter (fun info -> Eio.Switch.on_release sw (fun () ->
        ignore (Browser_lane.disconnect_client ~client_id:info.Browser_lane.client_id))) [first;second];
      ignore (Browser_lane.take_command ~client_info:first ~window_sec:0.001);
      let pending = Eio.Fiber.fork_promise ~sw (fun () ->
        Surface.read {source=Live; tab_id=Some 1; client_id=None}) in
      let take info = match Browser_lane.take_command ~client_info:info ~window_sec:1. with
        | Ok (Some command) -> command | _ -> fail "selected client command missing" in
      let tabs_command = take first in
      ignore (Browser_lane.take_command ~client_info:second ~window_sec:0.001);
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
        check bool "reply identifies the original single client" true
          (Yojson.Safe.Util.member "clientId" data = `String (Browser_lane.client_id_to_string first.client_id));
        check bool "page belongs to the pinned browser" true
          (Yojson.Safe.Util.(data |> member "page" |> member "text") = `String "first-owned")
      | _ -> fail "second connection disrupted the once-resolved read"))

let test_keeper_discovers_clients_without_dispatch () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let info raw browser : Browser_lane.client_info =
        let client_id = match Browser_lane.client_id_of_string raw with
          | Ok id -> id | Error error -> fail error in
        {client_id; browser; version="fixture"; engine_version="155.0.1"} in
      let clients = [
        info "20000000-0000-4000-8000-000000000001" Browser_lane.Firefox;
        info "20000000-0000-4000-8000-000000000002" Browser_lane.Zen] in
      List.iter (fun info ->
        Eio.Switch.on_release sw (fun () ->
          ignore (Browser_lane.disconnect_client ~client_id:info.Browser_lane.client_id));
        ignore (Browser_lane.take_command ~client_info:info ~window_sec:0.001)) clients;
      let result = Masc.Tool_misc_browser_lane.handle_tabs
        ~tool_name:"BrowserTabs" ~start_time:0.0 (`Assoc []) in
      let data = Tool_result.data result in
      check bool "ambiguous failure stays actionable" true
        (Yojson.Safe.Util.member "error" data = `String "ambiguous_browser_clients");
      check int "both browser identities discoverable" 2
        (Yojson.Safe.Util.(data |> member "clients" |> to_list |> List.length));
      check bool "model-facing error preserves the same discovery payload" true
        (Yojson.Safe.from_string (Tool_result.message result) = data);
      List.iter (fun info -> check bool "no dispatch before explicit selection" true
        (Browser_lane.take_command ~client_info:info ~window_sec:0.001 = Ok None)) clients))

let test_scoped_scene_acknowledgement () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let ignores_scope = ref false in
      let observed_document = ref "fixture" in
      let observed_url = ref "https://example.org" in
      Browser_lane.install_automation_executor (Some (function
        | Browser_lane.Page_scene {tab_id;view;scope;_} ->
          let scope_json = match scope with None -> `Null | Some target ->
            `Assoc ["documentId",`String target.document_id;"nodeId",`String target.node_id] in
          answer (`Assoc ["tabId",`Int tab_id;"schema",`String "masc.browser.scene.v1";
            "documentId",`String !observed_document;"url",`String !observed_url;"title",`String "Page";
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
      let guarded_tool url = Masc.Tool_misc_browser_lane.handle_read
        ~tool_name:"BrowserRead" ~start_time:0.
        (`Assoc ["lane",`String "automation";"tabId",`Int 7;"mode",`String "regions";
          "expectedUrl",`String url]) in
      check bool "tool surface accepts matching destination guard" true
        (match guarded_tool "https://example.org" with Tool_result.Completed _ -> true | _ -> false);
      check bool "tool surface rejects old URL" true
        (match guarded_tool "https://example.org/destination" with Tool_result.Failed _ -> true | _ -> false);
      observed_url := "https://example.org/canonical";
      check bool "redirect does not bypass original URL guard" true
        (match guarded_tool "https://example.org" with Tool_result.Failed _ -> true | _ -> false);
      let observed = Masc.Browser_scene.read ~view:Browser_lane.Regions (request (Some 7)) ~max_chars:1000 in
      let actual_url = match observed with
        | Ok json -> Yojson.Safe.Util.(json |> member "url" |> to_string)
        | Error error -> fail error in
      check string "unguarded observation exposes final redirect URL" "https://example.org/canonical" actual_url;
      check bool "verified observed URL can be pinned without another follow" true
        (match guarded_tool actual_url with Tool_result.Completed _ -> true | _ -> false);
      let source : Masc.Browser_scene.navigation_source = {url= !observed_url;document_id= !observed_document} in
      let same_url_read ?(pin=true) () = Masc.Tool_misc_browser_lane.handle_read ~tool_name:"BrowserRead" ~start_time:0.
        (`Assoc (["lane",`String "automation";"tabId",`Int 7;"mode",`String "regions";
          "navigationSource",`Assoc ["url",`String source.url;
            "documentId",`String source.document_id]] @
          (if pin then ["expectedUrl",`String !observed_url] else []))) in
      check bool "same URL old document is not navigation progress" true
        (match same_url_read () with Tool_result.Failed _ -> true | _ -> false);
      check bool "redirect inspection retains old-document rejection without URL pin" true
        (match same_url_read ~pin:false () with Tool_result.Failed _ -> true | _ -> false);
      observed_url := "https://example.org/spa-next";
      check bool "redirect destination can be inspected while preserving source guard" true
        (match same_url_read ~pin:false () with Tool_result.Completed _ -> true | _ -> false);
      check bool "SPA changed URL permits same document observation" true
        (match same_url_read () with Tool_result.Completed _ -> true | _ -> false);
      observed_url := source.url;
      observed_document := "reloaded-document";
      check bool "same URL newly loaded document is observable" true
        (match same_url_read () with Tool_result.Completed _ -> true | _ -> false);
      observed_document := "fixture";
      ignores_scope := true;
      check bool "connector ignoring scope must fail rather than return whole page" true (Result.is_error (read ()));
      check bool "connector ignoring region view must fail" true
        (Result.is_error (Masc.Browser_scene.read ~view:Browser_lane.Regions (request (Some 7)) ~max_chars:1000));
      check bool "duplicate scope fields rejected" true (Result.is_error (Masc.Browser_scene.scope_of_json
        (`Assoc ["documentId",`String "fixture";"nodeId",`String "a";"nodeId",`String "b"])))))

let () = run "browser surface" ["behavior",[
  test_case "input correction resumes on the same connected browser" `Quick test_tool_input_recovery;
  test_case "scoped scene acknowledgement" `Quick test_scoped_scene_acknowledgement;
  test_case "read any website by active or explicit tab" `Quick test_any_website_selection;
  test_case "empty browser has no page" `Quick test_empty_browser;
  test_case "invalid input is refused" `Quick test_strict_input;
  test_case "backend failure is visible" `Quick test_remote_failure;
  test_case "capture target and image identity" `Quick test_capture_identity;
  test_case "Keeper discovers ambiguous clients without dispatch" `Quick test_keeper_discovers_clients_without_dispatch;
  test_case "live read pins client across both hops" `Quick test_live_read_pins_client_between_hops]]
