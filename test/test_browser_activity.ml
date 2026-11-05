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
  let config = parsed {|[browser.automation]
geckodriver = "/fixture/geckodriver"
binary = "/fixture/browser"
|} in
  check bool "automation paths" true
    (config.automation = Some {driver="/fixture/geckodriver";binary=Some "/fixture/browser"});
  let flat = parsed "[browser]\ngeckodriver = '/fixture/driver'\n" in
  let nested = parsed "[browser.automation]\ngeckodriver = '/fixture/driver'\n" in
  check bool "either automation location is read" true (Config.equal flat nested)

let invalid = [
  "both automation locations", "[browser]\ngeckodriver='/fixture/driver'\n[browser.automation]\ngeckodriver='/fixture/driver'";
  "flat binary and nested driver", "[browser]\nbinary='/fixture/browser'\n[browser.automation]\ngeckodriver='/fixture/driver'";
  "a lane switch", "[browser.live]\nenabled=false";
  "unknown backend key", "[browser.automation]\nenabld=false";
  "wrong table type", "[browser]\nlive=false";
  "stray browser key", "[browser]\nenabled=false";
  "relative path", "[browser.automation]\ngeckodriver='driver'";
]

let with_lane f = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run (fun sw ->
    let current = ref Lane.Enabled in
    Lane.install_activity_observer (Some (fun _ -> !current));
    Eio.Switch.on_release sw (fun () ->
      Lane.install_activity_observer None;
      Lane.install_automation_executor None;
      Lane.install_automation_document_observer None);
    f sw current))
let refused = function Lane.Rejected_before_effect _ -> () | _ -> fail "new work must be refused before effect"
let answer = Lane.Answered (`String "accepted")
let is_answer value = check bool "executor answered" true (value=answer)

let test_off_and_close () = with_lane (fun _ current ->
  let calls = ref [] in
  let execute verb = calls := verb :: !calls; answer in
  Lane.install_automation_executor (Some execute);
  Lane.install_automation_document_observer (Some (fun ~tab_id:_ -> execute (Lane.Page_document {tab_id=1})));
  current := Disabled;
  refused (Lane.issue_automation ~verb:Tabs_list ~timeout_sec:1.);
  refused (Lane.issue_server_lane Server_automation ~verb:(Session_open {headless=None}) ~timeout_sec:1.);
  (match Lane.issue_document_if_idle ~target:Automation ~tab_id:1 ~timeout_sec:1. with Ok value -> refused value | Error _ -> fail "route");
  check int "off executes nothing" 0 (List.length !calls);
  List.iter (fun lane -> List.iter (fun verb ->
    is_answer (Lane.issue_server_lane lane ~verb ~timeout_sec:1.)) [Lane.Session_status;Session_close])
    [Lane.Server_automation];
  check int "the backend retains status and close" 2 (List.length !calls);
  (match Lane.inventory_observation Lane.Lane_name.Automation with
   | {activity=Disabled;backend=Executor_registered true} -> ()
   | _ -> fail "off and executor registration are independent");
  current := Enabled;
  is_answer (Lane.issue_automation ~verb:Tabs_list ~timeout_sec:1.);
  Lane.install_activity_observer None;
  refused (Lane.issue_automation ~verb:Tabs_list ~timeout_sec:1.);
  is_answer (Lane.issue_automation ~verb:Session_close ~timeout_sec:1.))

let test_off_preselection () = with_lane (fun _ current ->
  current := Disabled;
  let rejected route verb code =
    match Lane.resolve_target ~verb route with
    | Error error -> check string "activity precedes selection" code (Lane.selection_error_code error)
    | Ok _ -> fail "unavailable activity selected a browser" in
  rejected (Lane.Live_route None) Lane.Tabs_list "browser_lane_off";
  rejected (Lane.Live_route None) (Lane.Page_document {tab_id=1}) "browser_lane_off";
  List.iter (fun route -> List.iter (fun verb ->
    check bool "status and close still resolve server lanes" true
      (Result.is_ok (Lane.resolve_target ~verb route))) [Lane.Session_status;Session_close])
    [Lane.Automation_route];
  current := Unobserved;
  rejected (Lane.Live_route None) Lane.Tabs_list "browser_activity_unavailable")

let test_off_preselected_stale () = with_lane (fun sw current ->
  let client_id = match Lane.client_id_of_string "00000000-0000-4000-8000-000000000002" with
    | Ok id -> id | Error detail -> fail detail in
  let client_info : Lane.client_info = {client_id;browser=Firefox;version="fixture";transport=Browser_lane.Web_extension; engine_version="fixture";space=None} in
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
  let client_info : Lane.client_info = {client_id;browser=Firefox;version="fixture";transport=Browser_lane.Web_extension; engine_version="fixture";space=None} in
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

let test_locate_selection_and_wait () = with_lane (fun sw _ ->
  let calls=ref 0 in
  let locate = Lane.Page_locate {tab_id=0;instruction=None} in
  Lane.install_automation_executor ~locate:false (Some (fun _ -> incr calls;answer));
  refused (Lane.issue_automation ~verb:locate ~timeout_sec:0.001);
  check int "locate selection off dispatches no model verb" 0 !calls;
  is_answer (Lane.issue_automation ~verb:Lane.Tabs_list ~timeout_sec:1.);
  check int "locate selection off preserves native commands" 1 !calls;
  let entered,enter=Eio.Promise.create () and finished,finish=Eio.Promise.create () in
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve finish ())) (fun () ->
    Lane.install_automation_executor ~locate:true (Some (fun actual ->
      incr calls;
      check bool "original work retained" true (actual=locate);
      Eio.Promise.resolve enter ();Eio.Promise.await finished;answer));
    let work=Eio.Fiber.fork_promise ~sw (fun () -> Lane.issue_automation ~verb:locate ~timeout_sec:0.001) in
    Eio.Promise.await entered;
    (* Deliberately cross the supplied quick response clock. Only this fixture
       uses a delay; model work retains its original owner. *)
    Time_compat.sleep 0.01;
    check bool "original work survives the quick browser clock" true (Eio.Promise.peek work=None);
    Eio.Promise.resolve finish ();
    is_answer (Eio.Promise.await_exn work)))

let () = run "Browser activity" [
  "configuration", test_case "paths retained and accepting locations" `Quick test_config
    :: List.map (fun (name,text) -> test_case name `Quick (fun () -> rejects text)) invalid;
  "admission", [test_case "off precedes selection" `Quick test_off_preselection;
    test_case "off precedes preselected stale client" `Quick test_off_preselected_stale;
    test_case "off and unavailable keep status/close" `Quick test_off_and_close;
    test_case "accepted automation request finishes" `Quick test_accepted_finishes;
    test_case "accepted live request survives off" `Quick test_live_retains_accepted;
    test_case "locate selection and original waiting scope" `Quick test_locate_selection_and_wait];
]
