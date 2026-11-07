open Alcotest
module Lane = Browser_lane
module Config = Browser_configuration
let parse text = match Otoml.Parser.from_string_result text with
  | Error detail -> fail detail
  | Ok toml -> Config.parse toml
let parsed text = match parse text with Ok config -> config | Error detail -> fail detail
let rejects text = check bool "invalid browser setting refused" true (Result.is_error (parse text))

let test_config () =
  check bool "no browser table configures nothing" true (Config.equal Config.none (parsed ""));
  let config = parsed "[browser.live.bidi]\nfirefox = '/fixture/firefox'\nprofile = '/fixture/profile'\n" in
  check bool "live BiDi paths" true
    (config.live_bidi = Some {firefox="/fixture/firefox";profile="/fixture/profile";port=Config.default_live_bidi_port})

let invalid = [
  "a lane switch", "[browser.live]\nenabled=false";
  "unknown backend key", "[browser.live.ego]\nenabld=false";
  "wrong table type", "[browser]\nlive=false";
  "stray browser key", "[browser]\nenabled=false";
  "relative path", "[browser.live.bidi]\nfirefox='firefox'\nprofile='/fixture/profile'";
]

let with_lane f = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run (fun sw ->
    let current = ref Lane.Enabled in
    Lane.install_activity_observer (Some (fun _ -> !current));
    Eio.Switch.on_release sw (fun () -> Lane.install_activity_observer None);
    f sw current))
let refused = function Lane.Rejected_before_effect _ -> () | _ -> fail "new work must be refused before effect"

let test_off_preselection () = with_lane (fun _ current ->
  current := Disabled;
  let rejected route verb code =
    match Lane.resolve_target ~verb route with
    | Error error -> check string "activity precedes selection" code (Lane.selection_error_code error)
    | Ok _ -> fail "unavailable activity selected a browser" in
  rejected (Lane.Live_route None) Lane.Tabs_list "browser_lane_off";
  rejected (Lane.Live_route None) (Lane.Page_document {tab_id=1}) "browser_lane_off";
  current := Unobserved;
  rejected (Lane.Live_route None) Lane.Tabs_list "browser_activity_unavailable")

let test_off_preselected_stale () = with_lane (fun sw current ->
  let client_id = match Lane.client_id_of_string "00000000-0000-4000-8000-000000000002" with
    | Ok id -> id | Error detail -> fail detail in
  let client_info : Lane.client_info = {client_id;browser=Firefox;version="fixture";transport=Browser_lane.Webdriver_bidi; engine_version="fixture";space=None} in
  ignore (Lane.take_command ~client_info ~window_sec:0.001);
  Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id));
  let target = match Lane.resolve_target ~verb:Lane.Tabs_list (Live_route (Some client_id)) with
    | Ok target -> target | Error _ -> fail "target" in
  current := Disabled;
  ignore (Lane.disconnect_client ~client_id);
  let check = function
    | Ok (Lane.Rejected_before_effect message) -> check string "off is the stale-target remedy"
        (Lane.activity_rejection_message (Lane.Lane_off Lane.Lane_name.Live)) message
    | _ -> fail "off must precede the stale-client diagnostic" in
  check (Lane.issue_for_actor ~actor:None ~target ~verb:Tabs_list ~timeout_sec:1.);
  check (Lane.issue_document_if_idle ~target ~tab_id:1 ~timeout_sec:1.))

let test_live_retains_accepted () = with_lane (fun sw current ->
  let client_id = match Lane.client_id_of_string "00000000-0000-4000-8000-000000000001" with
    | Ok id -> id | Error detail -> fail detail in
  let client_info : Lane.client_info = {client_id;browser=Firefox;version="fixture";transport=Browser_lane.Webdriver_bidi; engine_version="fixture";space=None} in
  ignore (Lane.take_command ~client_info ~window_sec:0.001);
  Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id));
  let target = match Lane.resolve_target ~verb:Lane.Tabs_list (Live_route (Some client_id)) with Ok target -> target | Error _ -> fail "target" in
  let work = Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_for_actor ~actor:None ~target ~verb:Tabs_list ~timeout_sec:1.) in
  let issued = match Lane.take_command ~client_info ~window_sec:1. with Ok (Some command) -> command | _ -> fail "command" in
  current := Disabled;
  (match Lane.issue_for_actor ~actor:None ~target ~verb:Tabs_list ~timeout_sec:1. with Ok value -> refused value | Error _ -> fail "route");
  (match Lane.issue_document_if_idle ~target ~tab_id:1 ~timeout_sec:1. with Ok value -> refused value | Error _ -> fail "route");
  check bool "off does not disconnect live client" true
    (Lane.inventory_observation Lane.Lane_name.Live = {activity=Disabled;backend=Live_clients 1});
  let payload = `Assoc ["ok",`Bool true] in
  check bool "accepted result still delivered" true (Lane.deliver_result ~client_id ~id:issued.id ~payload=Ok ());
  (match Eio.Promise.await work with Ok (Ok (Answered value)) -> check bool "owned payload" true (value=payload) | _ -> fail "accepted live request lost");
  check bool "no new request queued" true (Lane.take_command ~client_info ~window_sec:0.001=Ok None))

let () = run "Browser activity" [
  "configuration", test_case "live paths are read" `Quick test_config
    :: List.map (fun (name,text) -> test_case name `Quick (fun () -> rejects text)) invalid;
  "admission", [test_case "off precedes selection" `Quick test_off_preselection;
    test_case "off precedes preselected stale client" `Quick test_off_preselected_stale;
    test_case "accepted live request survives off" `Quick test_live_retains_accepted];
]
