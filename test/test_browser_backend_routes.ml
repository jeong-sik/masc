(* RFC browser-backends-end-alone S-L2: each browser source is served by the
   one worker whose package names it. Real native installations, one
   scripted worker per package; no browser is opened. *)
open Alcotest
open Masc
module B = Browser_lane
module F = Browser_addon_fixture
let require = function Ok value -> value | Error detail -> fail detail
let client n browser transport = {B.client_id=require (B.client_id_of_string
    (Printf.sprintf "0c000000-0000-4000-8000-%012d" n));browser;version="1";engine_version="1";transport;
    space=(match transport with B.Ego_task_space -> Some {B.id=51;name="Route fixture"}
      | Web_extension|Webdriver_bidi -> None)}
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
let ids clients=List.sort compare (List.map (fun (c:B.client_info) -> B.client_id_to_string c.client_id) clients)
let snapshot host=match Browser_addon_host.selection_snapshot host with
  | Ok (published,_) -> published
  | Error (Browser_addon_host.Snapshot_unavailable detail|Snapshot_unreadable detail) -> fail detail
let live client=B.Live_route (Some client.B.client_id)
let ledger attached = List.map (fun (worker:F.attached) -> worker.instance_id,worker.commands ()) attached
let reaches_instance name attached (intended:F.attached) route verb call =
  let before=ledger attached in
  (match call () with Ok _ -> () | Error result -> fail (name ^ ": " ^ Tool_result.message result));
  List.iter (fun (worker:F.attached) ->
    let earlier=List.assoc worker.instance_id before in
    let expected=if worker.instance_id=intended.instance_id then earlier @ [route,verb] else earlier in
    check bool (name ^ ": exact per-instance command ledger") true (worker.commands ()=expected)) attached
let refuses_before_dispatch name attached class_ call =
  let before=ledger attached in
  (match call () with
   | Error (Tool_result.Failed (failure:Tool_result.failure_payload)) ->
       check bool (name ^ ": typed refusal") true
         (failure.class_=class_ && failure.effect_disposition=Tool_result.Proven_pre_effect)
   | Ok _|Error (Tool_result.Completed _|Deferred _) -> fail (name ^ ": expected a pre-effect refusal"));
  check bool (name ^ ": no worker received a command") true (ledger attached=before)

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

let independent_ego_spaces_route_exact_clients () =
  let first={ego with space=Some {B.id=51;name="First Goal"}} in
  let second={ego with client_id=(client 5 B.Ego_lite B.Ego_task_space).client_id;
    space=Some {B.id=52;name="Second Goal"}} in
  run_with [one Ego [first];one Ego [second];one External_host [extension]]
    (fun ~config ~host ~issue ~attached ->
      reaches_instance "first Space reaches exactly its publisher" attached (List.nth attached 0) (live first) B.Tabs_list
        (fun () -> fst (issue (live first)));
      reaches_instance "second Space reaches exactly its publisher" attached (List.nth attached 1) (live second) B.Tabs_list
        (fun () -> fst (issue (live second)));
      check (list string) "all distinct live clients remain visible" (ids [first;second;extension]) (ids (snapshot host).clients);
      let goal=match Goal_store.upsert_goal config ~title:"Second Space routing" ~metric:"verified" ~target_value:"1" () with
        | Ok (goal,_) -> goal.id | Error error -> fail (Goal_store.write_error_to_string error) in
      let bound=match Browser_addon_host.bind_goal_space host ~goal_id:goal ~client_id:second.client_id with
        | Ok commit -> commit.binding | Error error -> fail (Browser_goal_space.error_message error) in
      let second_instance=(List.nth attached 1).F.instance_id in
      check string "Goal pin records the actual second publisher" second_instance bound.addon_instance_id;
      reaches_instance "a bound initial browse dispatches on that exact Space" attached (List.nth attached 1)
        (live second) B.Tabs_list
        (fun () -> Browser_addon_host.issue ~goal_space:bound host ~preference:Browser_selection.Automatic B.Tabs_list);
      check bool "unbound automatic browse never guesses among clients" true
        (Result.is_error (Browser_addon_host.issue host ~preference:Browser_selection.Automatic B.Tabs_list)));
  let conflicting={second with space=first.space} in
  run_with [one Ego [first];one Ego [conflicting];one External_host [extension]]
    (fun ~config:_ ~host ~issue ~attached:_ ->
      refused "first controller of duplicate native Space is refused" ~because:"multiple browser controllers" ~issue (live first);
      refused "second controller of duplicate native Space is refused" ~because:"multiple browser controllers" ~issue (live conflicting);
      reaches "unrelated client remains usable" ~issue (live extension) B.Backend.External_host;
      check (list string) "duplicate native controllers are excluded from choices" (ids [extension]) (ids (snapshot host).clients))

let unreadable_live_controller_never_authorizes_ego_input () =
  let first={ego with space=Some {B.id=51;name="First Goal"}} in
  let second={ego with client_id=(client 5 B.Ego_lite B.Ego_task_space).client_id;
    space=Some {B.id=52;name="Second Goal"}} in
  run_with [one Ego [first];one Ego [second];one External_host [extension];one Automation []]
    (fun ~config ~host ~issue:_ ~attached ->
      let first_worker=List.nth attached 0 and second_worker=List.nth attached 1
      and extension_worker=List.nth attached 2 and automation=List.nth attached 3 in
      let bind title client =
        let goal=match Goal_store.upsert_goal config ~title ~metric:"verified" ~target_value:"1" () with
          | Ok (goal,_) -> goal.id | Error error -> fail (Goal_store.write_error_to_string error) in
        match Browser_addon_host.bind_goal_space host ~goal_id:goal ~client_id:client.B.client_id with
        | Ok commit -> commit.binding | Error error -> fail (Browser_goal_space.error_message error) in
      let first_goal=bind "First owned Space" first and second_goal=bind "Second owned Space" second in
      let goto=B.Page_goto {url="https://fixture.invalid/owned";tab_id=Some 1}
      and open_session=B.Session_open {headless=None} in
      let exact client verb ()=Browser_addon_host.issue host ~preference:(Browser_selection.Exact (live client)) verb in
      let goal binding verb ()=Browser_addon_host.issue ~goal_space:binding host ~preference:Browser_selection.Automatic verb in
      second_worker.set_snapshot (F.Snapshot_clients [{second with space=first.space}]);
      refuses_before_dispatch "known duplicate Space refuses exact Page navigation" attached Tool_result.Workflow_rejection
        (exact first goto);
      refuses_before_dispatch "known duplicate Space refuses stored Goal open" attached Tool_result.Workflow_rejection
        (goal first_goal open_session);
      second_worker.set_snapshot F.Snapshot_unavailable;
      refuses_before_dispatch "unreadable sibling cannot authorize exact Ego Page navigation" attached Tool_result.Dependency_unavailable
        (exact first goto);
      refuses_before_dispatch "unreadable sibling cannot authorize stored Goal open" attached Tool_result.Dependency_unavailable
        (goal first_goal open_session);
      refuses_before_dispatch "unreadable sibling cannot authorize exact Ego document read" attached Tool_result.Dependency_unavailable
        (exact first (B.Page_document {tab_id=1}));
      let unbound_goal=match Goal_store.upsert_goal config ~title:"Unknown controller pin" ~metric:"verified" ~target_value:"1" () with
        | Ok (goal,_) -> goal.id | Error error -> fail (Goal_store.write_error_to_string error) in
      check bool "unknown controller prevents a new Goal pin" true
        (match Browser_addon_host.bind_goal_space host ~goal_id:unbound_goal ~client_id:first.client_id with
         | Error (Browser_goal_space.Unavailable _) -> true
         | Ok _|Error (Invalid _|Conflict _|Goal_reference _) -> false);
      check bool "refused Goal pin wrote no binding" true (Browser_goal_space.find config ~goal_id:unbound_goal=Ok None);
      reaches_instance "exact extension input remains independent" attached extension_worker (live extension) goto
        (exact extension goto);
      second_worker.set_snapshot (F.Snapshot_clients [second]);
      automation.set_snapshot F.Snapshot_unavailable;
      reaches_instance "unreadable Automation does not block exact Ego input" attached first_worker (live first) goto
        (exact first goto);
      reaches_instance "unreadable Automation does not block a stored Goal" attached first_worker (live first) open_session
        (goal first_goal open_session);
      reaches_instance "second distinct Space reaches its exact instance" attached second_worker (live second) goto
        (exact second goto);
      let reconnected={second with client_id=(client 6 B.Ego_lite B.Ego_task_space).client_id} in
      second_worker.set_snapshot (F.Snapshot_clients [reconnected]);
      reaches_instance "Goal re-resolves its own Space after client reconnect" attached second_worker (live reconnected) B.Tabs_list
        (goal second_goal B.Tabs_list))

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
  test_case "independent Ego Spaces route exact clients and reject duplicate controllers" `Slow independent_ego_spaces_route_exact_clients;
  test_case "unknown live controllers refuse Ego input and reads before dispatch" `Slow unreadable_live_controller_never_authorizes_ego_input;
  test_case "a service without its command still counts" `Slow a_service_without_its_command_still_counts;
  test_case "a client two workers list is refused" `Slow a_client_two_workers_list_is_refused;
  test_case "a first native poll needs the one external host worker" `Slow
    a_first_poll_needs_the_one_external_host_worker]]
