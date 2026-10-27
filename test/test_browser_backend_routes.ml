(* RFC browser-backends-end-alone S-L2: each browser source is served by the
   one worker whose package names it. Real native installations, one
   scripted worker per package; no browser is opened. *)
open Alcotest
open Masc
module B = Browser_lane
module F = Browser_addon_fixture
let require = function Ok value -> value | Error detail -> fail detail
let client n browser transport = {B.client_id=require (B.client_id_of_string
    (Printf.sprintf "0c000000-0000-4000-8000-%012d" n));browser;version="1";engine_version="1";transport}
let bidi=client 1 B.Firefox B.Webdriver_bidi
let ego=client 2 B.Ego_lite B.Ego_task_space
let extension=client 3 B.Zen B.Web_extension
let tabs=B.Answered (`Assoc ["ok",`Bool true;"data",`Assoc ["tabs",`List []]])
let run_with workers check_routes =
  let base=Filename.temp_dir "browser-backend-routes-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    Eio_main.run (fun env ->
      Time_compat.set_clock (Eio.Stdenv.clock env);
      let config=Workspace.default_config base in
      let reached=ref [] in
      let respond ~backend ~route _verb=reached:=(backend,route) :: !reached;tabs in
      F.with_workers ~env ~config ~workers ~respond (fun () ->
        let host=match Browser_addon_host.connect ~config ~access:Lane_addon_sources.Operator_configuration
            ~principal:(Lane_addon_call_context.Host_actor "backend-routes") ~reserved:[] with
          | Ok host -> host | Error _ -> fail "the browser services must connect" in
        (* Which worker the one command reached, or none. *)
        let issue route=reached:=[];
          let result=Browser_addon_host.issue host ~preference:(Browser_selection.Exact route) B.Tabs_list in
          result,!reached in
        check_routes ~config ~host ~issue)))
let reaches name ~issue route backend=match issue route with
  | Ok _,[reached] -> check bool name true (reached=(backend,route))
  | Ok _,([]|_::_::_) -> fail (name ^ ": the command must reach exactly one worker")
  | Error result,_ -> fail (name ^ ": " ^ Tool_result.message result)
let refused name ~issue route=match issue route with
  | Error result,[] -> check bool name true (Tool_result.is_failed result)
  | Ok _,_ -> fail (name ^ ": the command must be refused")
  | Error _,_::_ -> fail (name ^ ": a refused command reached a worker")
let ids clients=List.sort compare (List.map (fun (c:B.client_info) -> B.client_id_to_string c.client_id) clients)
let snapshot host=match Browser_addon_host.selection_snapshot host with
  | Ok (published,_) -> published
  | Error (Browser_addon_host.Snapshot_unavailable detail|Snapshot_unreadable detail) -> fail detail

let every_source_reaches_its_own_worker () =
  run_with [{F.backend=Automation;clients=[]};{backend=Stagehand;clients=[]};
            {backend=Owned_firefox;clients=[bidi]};{backend=Ego;clients=[ego]};
            {backend=External_host;clients=[extension]}]
    (fun ~config:_ ~host ~issue ->
      reaches "automation reaches the automation worker" ~issue B.Automation_route B.Backend.Automation;
      reaches "Stagehand reaches the Stagehand worker" ~issue B.Stagehand_route B.Backend.Stagehand;
      reaches "a BiDi client reaches the owned Firefox worker" ~issue
        (B.Live_route (Some bidi.client_id)) B.Backend.Owned_firefox;
      reaches "an ego client reaches the ego worker" ~issue (B.Live_route (Some ego.client_id)) B.Backend.Ego;
      reaches "an extension client reaches the external host worker" ~issue
        (B.Live_route (Some extension.client_id)) B.Backend.External_host;
      let published=snapshot host in
      check (list string) "the choice lists the clients of every live worker"
        (ids [bidi;ego;extension]) (ids published.clients);
      check bool "automation is read from its own worker" true published.automation.registered;
      check bool "Stagehand is read from its own worker" true published.stagehand.registered;
      List.iter (fun backend -> check bool (B.Backend.to_wire backend ^ " is observed on its own worker") true
        (Result.is_ok (Browser_addon_host.snapshot host ~backend))) B.Backend.all)

let a_missing_source_fails_alone () =
  run_with [{F.backend=Automation;clients=[]};{backend=Owned_firefox;clients=[bidi]}]
    (fun ~config:_ ~host ~issue ->
      refused "a source no worker serves is refused" ~issue B.Stagehand_route;
      refused "a live client no worker lists is refused" ~issue (B.Live_route (Some ego.client_id));
      reaches "automation is still served" ~issue B.Automation_route B.Backend.Automation;
      reaches "the BiDi client is still served" ~issue (B.Live_route (Some bidi.client_id)) B.Backend.Owned_firefox;
      check bool "the missing source has no snapshot" true
        (Result.is_error (Browser_addon_host.snapshot host ~backend:B.Backend.Stagehand));
      check bool "and is unobserved in the choice" false (snapshot host).stagehand.registered)

let a_doubled_source_fails_alone () =
  run_with [{F.backend=Automation;clients=[]};{backend=Automation;clients=[]};
            {backend=Stagehand;clients=[]};{backend=Ego;clients=[ego]}]
    (fun ~config:_ ~host ~issue ->
      refused "a source two workers serve is refused" ~issue B.Automation_route;
      reaches "Stagehand is still served" ~issue B.Stagehand_route B.Backend.Stagehand;
      reaches "the ego client is still served" ~issue (B.Live_route (Some ego.client_id)) B.Backend.Ego;
      check bool "the doubled source has no snapshot" true
        (Result.is_error (Browser_addon_host.snapshot host ~backend:B.Backend.Automation));
      check bool "and is unobserved in the choice" false (snapshot host).automation.registered)

let a_client_two_workers_list_is_refused () =
  run_with [{F.backend=Owned_firefox;clients=[bidi]};{backend=Ego;clients=[bidi;ego]}]
    (fun ~config:_ ~host:_ ~issue ->
      refused "a client two workers list is sent to neither" ~issue (B.Live_route (Some bidi.client_id));
      reaches "a client only one worker lists is served" ~issue (B.Live_route (Some ego.client_id)) B.Backend.Ego)

(* A native host's first poll goes to the one worker that serves external
   hosts; the other browser workers are not candidates. *)
let a_first_poll_needs_the_one_external_host_worker () =
  let poll name workers expected=run_with workers (fun ~config ~host:_ ~issue:_ ->
    Unix.mkdir (Filename.concat (Workspace.masc_dir config) Common.browser_lane_dirname) 0o700;
    check bool name true (match Browser_addon_ingress.poll ~config ~client:extension ~window_sec:0.001 with
      | Error (Browser_addon_ingress.Unavailable reason) -> reason=expected
      | Ok _|Error (Browser_addon_ingress.Registration_refused _|Outcome_unknown _) -> false)) in
  poll "no external host worker among the browser workers"
    [{F.backend=Automation;clients=[]};{backend=Owned_firefox;clients=[bidi]};{backend=Ego;clients=[ego]}]
    Browser_addon_ingress.No_addon;
  poll "two external host workers"
    [{F.backend=External_host;clients=[]};{backend=External_host;clients=[]}]
    Browser_addon_ingress.Ambiguous_addons

let () = run "browser backend routes" ["one worker per source",[
  test_case "every source reaches its own worker" `Slow every_source_reaches_its_own_worker;
  test_case "a missing source fails alone" `Slow a_missing_source_fails_alone;
  test_case "a doubled source fails alone" `Slow a_doubled_source_fails_alone;
  test_case "a client two workers list is refused" `Slow a_client_two_workers_list_is_refused;
  test_case "a first native poll needs the one external host worker" `Slow
    a_first_poll_needs_the_one_external_host_worker]]
