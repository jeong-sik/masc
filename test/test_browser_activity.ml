open Alcotest
module Lane = Browser_lane
module Config = Browser_configuration
let parse text = match Otoml.Parser.from_string_result text with
  | Error detail -> fail detail
  | Ok toml -> Config.parse toml
let parsed text = match parse text with Ok config -> config | Error detail -> fail detail
let rejects text = check bool "invalid browser setting refused" true (Result.is_error (parse text))

let test_config () =
  check bool "omitted activity preserves behavior" true (Config.equal Config.none (parsed ""));
  let config = parsed {|[browser.live]
enabled = false
[browser.automation]
enabled = false
geckodriver = "/fixture/geckodriver"
binary = "/fixture/browser"
[browser.stagehand]
enabled = false
chrome = "/fixture/chrome"
extension = "/fixture/extension"
profile = "/fixture/profile"
|} in
  check bool "three lanes off independently" true
    (not config.live_enabled && not config.automation_enabled && not config.stagehand_enabled);
  check bool "off retains automation paths" true
    (config.automation = Some {driver="/fixture/geckodriver";binary=Some "/fixture/browser"});
  check bool "off retains stagehand paths" true
    (config.stagehand = Some {chrome="/fixture/chrome";extension="/fixture/extension";profile=Some "/fixture/profile"});
  let one = parsed "[browser.automation]\nenabled = false\n" in
  check bool "activity without backend configuration remains observable" true
    (one.automation=None && not one.automation_enabled && one.live_enabled && one.stagehand_enabled);
  let flat = parsed "[browser]\ngeckodriver = '/fixture/driver'\n" in
  let nested = parsed "[browser.automation]\ngeckodriver = '/fixture/driver'\n" in
  check bool "one accepting deployment reads either location" true (Config.equal flat nested)

let invalid = [
  "both automation locations", "[browser]\ngeckodriver='/fixture/driver'\n[browser.automation]\nenabled=false";
  "flat binary and nested driver", "[browser]\nbinary='/fixture/browser'\n[browser.automation]\ngeckodriver='/fixture/driver'";
  "wrong flag type", "[browser.live]\nenabled='false'";
  "unknown backend key", "[browser.automation]\nenabld=false";
  "wrong table type", "[browser]\nlive=false";
  "stray browser key", "[browser]\nenabled=false";
  "relative path even when off", "[browser.automation]\nenabled=false\ngeckodriver='driver'";
  "partial stagehand even when off", "[browser.stagehand]\nenabled=false\nchrome='/fixture/chrome'";
  "stagehand empty table", "[browser.stagehand]";
]

let with_lane f = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run (fun sw ->
    let current = ref Lane.Enabled in
    Lane.install_activity_observer (Some (fun _ -> !current));
    Eio.Switch.on_release sw (fun () ->
      Lane.install_activity_observer None;
      Lane.install_automation_executor None;
      Lane.install_automation_document_observer None;
      Lane.install_stagehand_executor None);
    f sw current))
let refused = function Lane.Rejected_before_effect _ -> () | _ -> fail "new work must be refused before effect"
let answer = Lane.Answered (`String "accepted")
let is_answer value = check bool "executor answered" true (value=answer)

let test_off_and_close () = with_lane (fun _ current ->
  let calls = ref [] in
  let execute verb = calls := verb :: !calls; answer in
  Lane.install_automation_executor (Some execute);
  Lane.install_stagehand_executor (Some execute);
  Lane.install_automation_document_observer (Some (fun ~tab_id:_ -> execute (Lane.Page_document {tab_id=1})));
  current := Disabled;
  refused (Lane.issue_automation ~verb:Tabs_list ~timeout_sec:1.);
  refused (Lane.issue_server_lane Server_automation ~verb:(Session_open {headless=None}) ~timeout_sec:1.);
  refused (Lane.issue_stagehand ~verb:Tabs_list ~timeout_sec:None);
  (match Lane.issue_for ~target:Stagehand ~verb:Tabs_list ~timeout_sec:1. with Ok value -> refused value | Error _ -> fail "route");
  (match Lane.issue_document_if_idle ~target:Automation ~tab_id:1 ~timeout_sec:1. with Ok value -> refused value | Error _ -> fail "route");
  check int "off executes nothing" 0 (List.length !calls);
  List.iter (fun lane -> List.iter (fun verb ->
    is_answer (Lane.issue_server_lane lane ~verb ~timeout_sec:1.)) [Lane.Session_status;Session_close])
    [Lane.Server_automation;Server_stagehand];
  check int "both backends retain status and close" 4 (List.length !calls);
  (match Lane.inventory_observation Lane.Lane_name.Automation with
   | {activity=Disabled;backend=Executor_registered true} -> ()
   | _ -> fail "off and executor registration are independent");
  current := Enabled;
  is_answer (Lane.issue_automation ~verb:Tabs_list ~timeout_sec:1.);
  Lane.install_activity_observer None;
  refused (Lane.issue_automation ~verb:Tabs_list ~timeout_sec:1.);
  is_answer (Lane.issue_automation ~verb:Session_close ~timeout_sec:1.))

let test_accepted_finishes () = with_lane (fun sw current ->
  let started, start = Eio.Promise.create () in
  let finish, complete = Eio.Promise.create () in
  Lane.install_automation_executor (Some (fun _ -> Eio.Promise.resolve start (); Eio.Promise.await finish; answer));
  let work = Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_automation ~verb:Tabs_list ~timeout_sec:1.) in
  Eio.Promise.await started;
  current := Disabled;
  refused (Lane.issue_automation ~verb:Tabs_list ~timeout_sec:1.);
  Eio.Promise.resolve complete ();
  match Eio.Promise.await work with Ok value -> is_answer value | Error ex -> raise ex)

let test_live_retains_accepted () = with_lane (fun sw current ->
  let client_id = match Lane.client_id_of_string "00000000-0000-4000-8000-000000000001" with
    | Ok id -> id | Error detail -> fail detail in
  let client_info : Lane.client_info = {client_id;browser=Firefox;version="fixture";engine_version="fixture"} in
  ignore (Lane.take_command ~client_info ~window_sec:0.001);
  Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id));
  let target = match Lane.resolve_target (Live_route (Some client_id)) with Ok target -> target | Error _ -> fail "target" in
  let work = Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for ~target ~verb:Tabs_list ~timeout_sec:1.) in
  let issued = match Lane.take_command ~client_info ~window_sec:1. with Ok (Some command) -> command | _ -> fail "command" in
  current := Disabled;
  (match Lane.issue_for ~target ~verb:Tabs_list ~timeout_sec:1. with Ok value -> refused value | Error _ -> fail "route");
  (match Lane.issue_document_if_idle ~target ~tab_id:1 ~timeout_sec:1. with Ok value -> refused value | Error _ -> fail "route");
  check bool "off does not disconnect live client" true
    (Lane.inventory_observation Lane.Lane_name.Live = {activity=Disabled;backend=Live_clients 1});
  let payload = `Assoc ["ok",`Bool true] in
  check bool "accepted result still delivered" true (Lane.deliver_result ~client_id ~id:issued.id ~payload=Ok ());
  (match Eio.Promise.await work with Ok (Ok (Answered value)) -> check bool "owned payload" true (value=payload) | _ -> fail "accepted live request lost");
  check bool "no new request queued" true (Lane.take_command ~client_info ~window_sec:0.001=Ok None))

let () = run "Browser activity" [
  "configuration", test_case "paths retained and accepting locations" `Quick test_config
    :: List.map (fun (name,text) -> test_case name `Quick (fun () -> rejects text)) invalid;
  "admission", [test_case "off and unavailable keep status/close" `Quick test_off_and_close;
    test_case "accepted automation request finishes" `Quick test_accepted_finishes;
    test_case "accepted live request survives off" `Quick test_live_retains_accepted];
]
