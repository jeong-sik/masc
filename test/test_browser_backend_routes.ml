(* RFC browser-backends-end-alone S-L2: each browser source is served by the
   one worker whose package names it. Real native installations, one
   scripted worker per package; no browser is opened. *)
open Alcotest
open Masc
module B = Browser_lane
module F = Browser_addon_fixture
let require = function Ok value -> value | Error detail -> fail detail
let client n browser transport = {B.client_id=require (B.client_id_of_string
    (Printf.sprintf "0c000000-0000-4000-8000-%012d" n));browser;version="1";engine_version="1";transport;space=None}
let bidi=client 1 B.Firefox B.Webdriver_bidi
let ego=client 2 B.Ego_lite B.Ego_task_space
let extension=client 3 B.Zen B.Web_extension
(* A client an automation worker reports; it serves no live source. *)
let stray=client 4 B.Firefox B.Webdriver_bidi
let one backend clients={F.serves=backend;clients;exports=true}
let tabs=B.Answered (`Assoc ["ok",`Bool true;"data",`Assoc ["tabs",`List []]])
let run_with workers check_routes =
  let base=Filename.temp_dir "browser-backend-routes-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    Eio_main.run (fun env ->
      Time_compat.set_clock (Eio.Stdenv.clock env);
      let config=Workspace.default_config base in
      (* Every command any worker received, before it checks its clients. *)
      let received=ref [] in
      let respond ~serves:_ ~route:_ _verb=tabs in
      F.with_workers ~env ~config ~workers ~received:(fun ~serves ~route -> received:=(serves,route) :: !received)
        ~respond (fun attached ->
        let host=match Browser_addon_host.connect ~config ~access:Lane_addon_sources.Operator_configuration
            ~principal:(Lane_addon_call_context.Host_actor "backend-routes") ~reserved:[] with
          | Ok host -> host | Error _ -> fail "the browser services must connect" in
        (* Which workers the one command reached. *)
        let issue route=received:=[];
          let result=Browser_addon_host.issue host ~preference:(Browser_selection.Exact route) B.Tabs_list in
          result,!received in
        check_routes ~config ~host ~issue ~attached)))
let reaches name ~issue route serves=match issue route with
  | Ok _,[reached] -> check bool name true (reached=(serves,route))
  | Ok _,([]|_::_::_) -> fail (name ^ ": the command must reach exactly one worker")
  | Error result,_ -> fail (name ^ ": " ^ Tool_result.message result)
let refused ?because name ~issue route=match issue route with
  | Error result,[] -> check bool name true (Tool_result.is_failed result
      && match because with None -> true | Some reason -> String_util.string_contains_substring ~needle:reason (Tool_result.message result))
  | Ok _,_ -> fail (name ^ ": the command must be refused")
  | Error _,_::_ -> fail (name ^ ": a refused command reached a worker")
(* The reason a command is refused when a client's live source is doubled;
   without it the client is refused only as one the choice does not list. *)
let doubled_live="served by more than one attached browser Add-on"
let ids clients=List.sort compare (List.map (fun (c:B.client_info) -> B.client_id_to_string c.client_id) clients)
let snapshot host=match Browser_addon_host.selection_snapshot host with
  | Ok (published,_) -> published
  | Error (Browser_addon_host.Snapshot_unavailable detail|Snapshot_unreadable detail) -> fail detail
let live client=B.Live_route (Some client.B.client_id)

let every_source_reaches_its_own_worker () =
  run_with [one Automation [stray];one Stagehand [];one Owned_firefox [bidi];one Ego [ego];
            one External_host [extension]]
    (fun ~config:_ ~host ~issue ~attached:_ ->
      reaches "automation reaches the automation worker" ~issue B.Automation_route B.Backend.Automation;
      reaches "Stagehand reaches the Stagehand worker" ~issue B.Stagehand_route B.Backend.Stagehand;
      reaches "a BiDi client reaches the owned Firefox worker" ~issue (live bidi) B.Backend.Owned_firefox;
      reaches "an ego client reaches the ego worker" ~issue (live ego) B.Backend.Ego;
      reaches "an extension client reaches the external host worker" ~issue (live extension)
        B.Backend.External_host;
      refused "a client a worker of no live source reports is not routed" ~issue (live stray);
      let published=snapshot host in
      check (list string) "the choice lists the clients of the live workers only"
        (ids [bidi;ego;extension]) (ids published.clients);
      (* Each worker reports only its own source registered, so a report read
         from the wrong worker would say unregistered. *)
      check bool "automation is read from its own worker" true published.automation.registered;
      check bool "Stagehand is read from its own worker" true published.stagehand.registered;
      List.iter (fun backend -> check bool (B.Backend.to_wire backend ^ " is observed on its own worker") true
        (Result.is_ok (Browser_addon_host.snapshot host ~backend))) B.Backend.all)

let a_missing_source_fails_alone () =
  run_with [one Automation [];one Owned_firefox [bidi]]
    (fun ~config:_ ~host ~issue ~attached:_ ->
      refused "a source no worker serves is refused" ~issue B.Stagehand_route;
      refused "a live client no worker lists is refused" ~issue (live ego);
      reaches "automation is still served" ~issue B.Automation_route B.Backend.Automation;
      reaches "the BiDi client is still served" ~issue (live bidi) B.Backend.Owned_firefox;
      check bool "the missing source has no snapshot" true
        (Result.is_error (Browser_addon_host.snapshot host ~backend:B.Backend.Stagehand));
      check bool "and is unobserved in the choice" false (snapshot host).stagehand.registered)

let a_doubled_source_fails_alone () =
  run_with [one Automation [];one Automation [];one Stagehand [];one Ego [ego]]
    (fun ~config:_ ~host ~issue ~attached:_ ->
      refused "a source two workers serve is refused" ~issue B.Automation_route;
      reaches "Stagehand is still served" ~issue B.Stagehand_route B.Backend.Stagehand;
      reaches "the ego client is still served" ~issue (live ego) B.Backend.Ego;
      check bool "the doubled source has no snapshot" true
        (Result.is_error (Browser_addon_host.snapshot host ~backend:B.Backend.Automation));
      check bool "and is unobserved in the choice" false (snapshot host).automation.registered)

(* A client does not say which live source it came from, so no client of a
   worker serving a doubled live source is used, though that worker lists it. *)
let a_doubled_live_source_leaves_its_clients_unused () =
  run_with [one Ego [ego];one Ego [];one External_host [extension]]
    (fun ~config:_ ~host ~issue ~attached:_ ->
      refused "a client of a live source two workers serve is refused for that reason" ~because:doubled_live
        ~issue (live ego);
      reaches "a client of another live source is served" ~issue (live extension) B.Backend.External_host;
      check (list string) "the choice lists only the usable clients" (ids [extension]) (ids (snapshot host).clients))

(* A service that advertises no browser command still serves its source:
   it is counted, so the source is not given to another, and a command to it
   is refused before any worker. *)
let a_service_without_its_command_still_counts () =
  run_with [{F.serves=B.Backend.Automation;clients=[];exports=false};one Automation [];one Stagehand []]
    (fun ~config:_ ~host:_ ~issue ~attached:_ ->
      refused "a source one exporting and one silent service serve is doubled"
        ~because:"more than one attached browser Add-on serves" ~issue B.Automation_route;
      reaches "the other source is served" ~issue B.Stagehand_route B.Backend.Stagehand);
  run_with [{F.serves=B.Backend.Automation;clients=[];exports=false};one Stagehand []]
    (fun ~config:_ ~host:_ ~issue ~attached:_ ->
      refused "a command to the silent service is refused" ~because:"advertises no browser command"
        ~issue B.Automation_route;
      reaches "and the other source is served" ~issue B.Stagehand_route B.Backend.Stagehand)

let a_client_two_workers_list_is_refused () =
  run_with [one Owned_firefox [bidi];one Ego [bidi;ego]]
    (fun ~config:_ ~host:_ ~issue ~attached:_ ->
      refused "a client two workers list is sent to neither" ~issue (live bidi);
      reaches "a client only one worker lists is served" ~issue (live ego) B.Backend.Ego)

(* A native host's first poll goes to the one worker that serves external
   hosts; the other browser workers are not candidates. *)
let a_first_poll_needs_the_one_external_host_worker () =
  let poll ~config=
    Unix.mkdir (Filename.concat (Workspace.masc_dir config) Common.browser_lane_dirname) 0o700;
    Browser_addon_ingress.poll ~config ~client:extension ~window_sec:0.001 in
  run_with [one Automation [];one Ego [ego];one External_host []] (fun ~config ~host:_ ~issue:_ ~attached ->
    check bool "the poll is answered" true (poll ~config=Ok None);
    List.iter (fun (worker:F.attached) ->
      let expected=if worker.serves=B.Backend.External_host then [B.client_id_to_string extension.client_id] else [] in
      check (list string) "only the external host worker is polled" expected (worker.polled ())) attached);
  let unavailable name workers expected=run_with workers (fun ~config ~host:_ ~issue:_ ~attached:_ ->
    check bool name true (match poll ~config with
      | Error (Browser_addon_ingress.Unavailable reason) -> reason=expected
      | Ok _|Error (Browser_addon_ingress.Registration_refused _|Outcome_unknown _) -> false)) in
  unavailable "no external host worker among the browser workers"
    [one Automation [];one Owned_firefox [bidi];one Ego [ego]] Browser_addon_ingress.No_addon;
  unavailable "two external host workers" [one External_host [];one External_host []]
    Browser_addon_ingress.Ambiguous_addons

let () = run "browser backend routes" ["one worker per source",[
  test_case "every source reaches its own worker" `Slow every_source_reaches_its_own_worker;
  test_case "a missing source fails alone" `Slow a_missing_source_fails_alone;
  test_case "a doubled source fails alone" `Slow a_doubled_source_fails_alone;
  test_case "a doubled live source leaves its clients unused" `Slow a_doubled_live_source_leaves_its_clients_unused;
  test_case "a service without its command still counts" `Slow a_service_without_its_command_still_counts;
  test_case "a client two workers list is refused" `Slow a_client_two_workers_list_is_refused;
  test_case "a first native poll needs the one external host worker" `Slow
    a_first_poll_needs_the_one_external_host_worker]]
