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
    space=(match transport with B.Ego_task_space -> Some {B.id=50+n;name="Route fixture"})}
let ego=client 2 B.Ego_lite B.Ego_task_space
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
  run_with [one Ego [ego]]
    (fun ~config:_ ~host ~issue ~attached:_ ->
      reaches "an ego client reaches the ego worker" ~issue (live ego) B.Backend.Ego;
      check (list string) "the choice lists the clients of the worker"
        (ids [ego]) (ids (snapshot host).clients);
      List.iter (fun backend -> check bool (B.Backend.to_wire backend ^ " is observed on its own worker") true
        (Result.is_ok (Browser_addon_host.snapshot host ~backend))) B.Backend.all)

let a_user_owned_refusal_routes_its_reclaim () =
  run_with [one Ego []]
    (fun ~config:_ ~host ~issue:_ ~attached ->
      let worker=match attached with [worker] -> worker | _ -> fail "expected the one ego worker" in
      let verb=B.Page_act (B.Action.Control B.Action.Take_over) in
      let call ()=Browser_addon_host.issue host ~preference:(Browser_selection.Exact (B.Live_route None)) verb in
      refuses_before_dispatch "a live lane that refused no Space is not reclaimed" attached
        Tool_result.Workflow_rejection call;
      worker.F.set_snapshot (F.Snapshot_ego_refused {space="masc-keepers";ids=[36]});
      reaches_instance "a user-owned refusal routes its reclaim to the refusing worker"
        attached worker (B.Live_route None) verb call)

let independent_ego_spaces_route_exact_clients () =
  let first={ego with space=Some {B.id=51;name="First Goal"}} in
  let second={ego with client_id=(client 5 B.Ego_lite B.Ego_task_space).client_id;
    space=Some {B.id=52;name="Second Goal"}} in
  run_with [one Ego [first];one Ego [second]]
    (fun ~config ~host ~issue ~attached ->
      reaches_instance "first Space reaches exactly its publisher" attached (List.nth attached 0) (live first) B.Tabs_list
        (fun () -> fst (issue (live first)));
      reaches_instance "second Space reaches exactly its publisher" attached (List.nth attached 1) (live second) B.Tabs_list
        (fun () -> fst (issue (live second)));
      check (list string) "all distinct live clients remain visible" (ids [first;second]) (ids (snapshot host).clients);
      let goal=match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"Second Space routing" ~metric:"verified" ~target_value:"1" () with
        | Ok (goal, _, _) -> goal.id | Error error -> fail (Goal_store.write_error_to_string error) in
      let bound=match Browser_addon_host.bind_goal_space host ~goal_id:goal ~client_id:second.client_id with
        | Ok commit -> commit.binding | Error error -> fail (Browser_goal_space.error_message error) in
      let second_instance=(List.nth attached 1).F.instance_id in
      check bool "Goal pin records the actual manual publisher" true
        (bound.installation=Lane_addon_tool_request_owner.Manual second_instance);
      reaches_instance "a bound initial browse dispatches on that exact Space" attached (List.nth attached 1)
        (live second) B.Tabs_list
        (fun () -> Browser_addon_host.issue ~goal_space:bound host ~preference:Browser_selection.Automatic B.Tabs_list);
      check bool "unbound automatic browse never guesses among clients" true
        (Result.is_error (Browser_addon_host.issue host ~preference:Browser_selection.Automatic B.Tabs_list)));
  let conflicting={second with space=first.space} in
  run_with [one Ego [first];one Ego [conflicting]]
    (fun ~config:_ ~host ~issue ~attached:_ ->
      refused "first controller of duplicate native Space is refused" ~because:"multiple browser controllers" ~issue (live first);
      refused "second controller of duplicate native Space is refused" ~because:"multiple browser controllers" ~issue (live conflicting);
      check (list string) "duplicate native controllers are excluded from choices" [] (ids (snapshot host).clients))

let unreadable_live_controller_never_authorizes_ego_input () =
  let first={ego with space=Some {B.id=51;name="First Goal"}} in
  let second={ego with client_id=(client 5 B.Ego_lite B.Ego_task_space).client_id;
    space=Some {B.id=52;name="Second Goal"}} in
  run_with [one Ego [first];one Ego [second]]
    (fun ~config ~host ~issue:_ ~attached ->
      let first_worker=List.nth attached 0 and second_worker=List.nth attached 1 in
      let bind title client =
        let goal=match Goal_store.upsert_goal_with_events ~actor:"test" config ~title ~metric:"verified" ~target_value:"1" () with
          | Ok (goal, _, _) -> goal.id | Error error -> fail (Goal_store.write_error_to_string error) in
        match Browser_addon_host.bind_goal_space host ~goal_id:goal ~client_id:client.B.client_id with
        | Ok commit -> commit.binding | Error error -> fail (Browser_goal_space.error_message error) in
      let first_goal=bind "First owned Space" first and second_goal=bind "Second owned Space" second in
      let goto=B.Page_goto {url="https://fixture.invalid/owned";tab_id=Some 1}
      and discover=B.Tabs_list in
      let exact client verb ()=Browser_addon_host.issue host ~preference:(Browser_selection.Exact (live client)) verb in
      let goal binding verb ()=Browser_addon_host.issue ~goal_space:binding host ~preference:Browser_selection.Automatic verb in
      second_worker.set_snapshot (F.Snapshot_clients [{second with space=first.space}]);
      refuses_before_dispatch "known duplicate Space refuses exact Page navigation" attached Tool_result.Workflow_rejection
        (exact first goto);
      refuses_before_dispatch "known duplicate Space refuses stored Goal discovery" attached Tool_result.Workflow_rejection
        (goal first_goal discover);
      second_worker.set_snapshot F.Snapshot_unavailable;
      refuses_before_dispatch "unreadable sibling cannot authorize exact Ego Page navigation" attached Tool_result.Dependency_unavailable
        (exact first goto);
      refuses_before_dispatch "unreadable sibling cannot authorize stored Goal discovery" attached Tool_result.Dependency_unavailable
        (goal first_goal discover);
      refuses_before_dispatch "unreadable sibling cannot authorize exact Ego document read" attached Tool_result.Dependency_unavailable
        (exact first (B.Page_document {tab_id=1}));
      let unbound_goal=match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"Unknown controller pin" ~metric:"verified" ~target_value:"1" () with
        | Ok (goal, _, _) -> goal.id | Error error -> fail (Goal_store.write_error_to_string error) in
      check bool "unknown controller prevents a new Goal pin" true
        (match Browser_addon_host.bind_goal_space host ~goal_id:unbound_goal ~client_id:first.client_id with
         | Error (Browser_goal_space.Unavailable _) -> true
         | Ok _|Error (Invalid _|Conflict _|Goal_reference _) -> false);
      check bool "refused Goal pin wrote no binding" true (Browser_goal_space.find config ~goal_id:unbound_goal=Ok None);
      second_worker.set_snapshot (F.Snapshot_clients [second]);
      reaches_instance "a readable sibling admits exact Ego input again" attached first_worker (live first) goto
        (exact first goto);
      reaches_instance "and a stored Goal again" attached first_worker (live first) discover
        (goal first_goal discover);
      reaches_instance "second distinct Space reaches its exact instance" attached second_worker (live second) goto
        (exact second goto);
      let reconnected={second with client_id=(client 6 B.Ego_lite B.Ego_task_space).client_id} in
      second_worker.set_snapshot (F.Snapshot_clients [reconnected]);
      reaches_instance "Goal re-resolves its own Space after client reconnect" attached second_worker (live reconnected) B.Tabs_list
        (goal second_goal B.Tabs_list))

(* A service that advertises no browser command still serves its source:
   it is counted, so the source is not given to another, and a command to it
   is refused before any worker. *)
let () = run "browser backend routes" ["one worker per source",[
  test_case "every source reaches its own worker" `Slow every_source_reaches_its_own_worker;
  test_case "a user-owned refusal routes its reclaim" `Slow a_user_owned_refusal_routes_its_reclaim;
  test_case "independent Ego Spaces route exact clients and reject duplicate controllers" `Slow independent_ego_spaces_route_exact_clients;
  test_case "unknown live controllers refuse Ego input and reads before dispatch" `Slow unreadable_live_controller_never_authorizes_ego_input]]
