open Alcotest
module B = Browser_lane
module W = Masc.Browser_addon_wire
module Owner = Masc.Browser_addon_owner
let ok = function Ok value -> value | Error message -> fail message
let incarnation = "0b000000-0000-4000-8000-000000000001"
let other_incarnation = "0b000000-0000-4000-8000-000000000002"
let id = ok (B.client_id_of_string "0c000000-0000-4000-8000-000000000001")
let client = {B.client_id=id;browser=B.Firefox;version="158";engine_version="158";transport=B.Webdriver_bidi;space=None}
let receipt = function
  | W.Receipt -> true
  | W.Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Issue_result _|Service_refusal _ -> false
let pre_effect = function
  | W.Service_refusal {disposition=W.Not_started;_} -> true
  | W.Service_refusal {disposition=W.Outcome_unknown;_}
  | W.Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false
let command = function
  | W.Poll_result {command=Some command;_} -> command
  | W.Poll_result {command=None;_}|Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Receipt|Issue_result _|Service_refusal _ -> fail "expected dispatched command"
let scenario () = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () -> Eio.Switch.run (fun sw ->
    let owner = ok (Owner.create ~incarnation) in
    Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
    let send command = Owner.dispatch owner {W.incarnation;command} in
    let poll = Eio.Fiber.fork_promise ~sw (fun () -> send (W.Poll {client;window_sec=2.})) in
    let rec registered () = if B.connected_clients ()=[] then (Eio.Fiber.yield ();registered ()) in
    registered ();
    let issue () = send (W.Issue {route=B.Live_route (Some id);
      verb=B.Page_interact {frame_path=[];tab_id=7;expected_url=Some "https://example.org/";action=B.Hover (B.Selector "#row")};
      actor=Some "keeper";timeout_sec=2.;only_if_idle=false}) in
    let pending = Eio.Fiber.fork_promise ~sw issue in
    let issued = command (Eio.Promise.await_exn poll) in
    check (option string) "actor crosses queue" (Some "keeper")
      (match issued.verb_json with `Assoc fields ->
        (match List.assoc_opt "actor" fields with Some (`String actor) -> Some actor | _ -> None)
       | _ -> None);
    check bool "wrong incarnation cannot deliver" true
      (pre_effect (Owner.dispatch owner {W.incarnation=other_incarnation;
        command=W.Deliver {client_id=id;id=issued.id;payload=`Null}}));
    let payload = `Assoc ["ok",`Bool false;"effectPhase",`String "partial";
      "data",`Assoc ["created_tab_ids",`List [`Int 9]];"error",`String "partial failure"] in
    check bool "result channel answers while issue waits" true
      (receipt (send (W.Deliver {client_id=id;id=issued.id;payload})));
    check bool "partial effect payload preserved exactly" true
      (match Eio.Promise.await_exn pending with
       | W.Issue_result (Ok (B.Answered actual)) -> actual=payload
       | W.Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
       | W.Issue_result (Error _)|Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Service_refusal _ -> false);
    check bool "identical result retry is idempotent" true
      (receipt (send (W.Deliver {client_id=id;id=issued.id;payload})));
    check bool "changed retry is refused" true
      (pre_effect (send (W.Deliver {client_id=id;id=issued.id;payload=`Null})));
    check bool "unpinned browser cannot execute" true
      (pre_effect (send (W.Issue {route=B.Live_route None;verb=B.Tabs_list;actor=None;timeout_sec=2.;only_if_idle=false})));
    let take_over_route () = W.Issue {route=B.Live_route None;
      verb=B.Page_act (B.Action.Control B.Action.Take_over);actor=None;timeout_sec=2.;only_if_idle=false} in
    check bool "take_over without a client is refused until the lane refused a Space" true
      (pre_effect (send (take_over_route ())));
    let claimed_ids=ref [] in
    let reopen=ref (Ok (Owner.Reopening {space="masc-keepers"})) in
    let recover : Masc.Browser_addon_observation.unavailable -> (Owner.ego_recovered, string) result = function
      | Masc.Browser_addon_observation.Ego_user_owned_name {ids;_} ->
        claimed_ids:=ids; (match ids with
         | [space_id] -> Ok (Owner.Reclaimed {space_id;space_name="masc-keepers"})
         | _ -> Error "the owner never passes an ambiguous id list")
      | Ego_space_missing _ -> !reopen in
    ok (Owner.attach_ego_recovery owner recover);
    check bool "a recovery hook alone does not admit the claim" true
      (pre_effect (send (take_over_route ())));
    ok (Owner.mark_ego_user_owned_name owner ~space:"masc-keepers" ~ids:[7] ~observed_at:1.);
    (match send (take_over_route ()) with
     | W.Issue_result (Ok (B.Answered receipt)) ->
         check (list int) "the claim sees exactly the published Space id" [7] !claimed_ids;
         check bool "the claim receipt names the reclaimed Space" true
           (receipt=`Assoc ["ok",`Bool true;"action",`String "take_over";"spaceId",`Int 7;
             "spaceName",`String "masc-keepers";"reclaimed",`Bool true]);
         check bool "the tool reads a reclaim as a success" true
           (Option.is_none (Masc.Browser_addon_tool.failure_of_reply (W.Issue_result (Ok (B.Answered receipt)))))
     | W.Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
     | W.Issue_result (Error _)|W.Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|W.Service_refusal _ ->
         check bool "the claim answers with a reclaimed receipt" true false);
    check bool "a second refusal is not published over the first" true
      (Result.is_error (Owner.mark_ego_user_owned_name owner ~space:"second" ~ids:[9] ~observed_at:2.));
    Owner.clear_ego_unavailable owner;
    ok (Owner.mark_ego_user_owned_name owner ~space:"shared" ~ids:[3;4] ~observed_at:3.);
    check bool "an ambiguous published refusal does not claim" true
      (pre_effect (send (take_over_route ())));
    check (list int) "an ambiguous refusal never reaches the claim" [7] !claimed_ids;
    Owner.clear_ego_unavailable owner;
    check bool "a cleared refusal admits no claim" true
      (pre_effect (send (take_over_route ())));
    (* A missing Space is recovered by opening the configured name again;
       the answer says so without a Space number it does not have yet. *)
    ok (Owner.mark_ego_space_missing owner ~space:"masc-keepers" ~space_id:12 ~observed_at:5.);
    check bool "a second record is not published over a missing Space" true
      (Result.is_error (Owner.mark_ego_user_owned_name owner ~space:"other" ~ids:[9] ~observed_at:6.));
    (match send (take_over_route ()) with
     | W.Issue_result (Ok (B.Answered receipt)) ->
         check bool "a missing Space is reopened by name" true
           (receipt=`Assoc ["ok",`Bool true;"action",`String "take_over";"spaceName",`String "masc-keepers";"reopening",`Bool true]);
         check bool "the tool reads a reopening as a success" true
           (Option.is_none (Masc.Browser_addon_tool.failure_of_reply (W.Issue_result (Ok (B.Answered receipt)))))
     | W.Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
     | W.Issue_result (Error _)|W.Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|W.Service_refusal _ ->
         check bool "a missing Space is reopened by name" true false);
    reopen:=Error "configured by number";
    check bool "a recovery that cannot reopen is refused" true
      (pre_effect (send (take_over_route ())));
    check (list int) "a missing Space never reaches the claim" [7] !claimed_ids;
    Owner.clear_ego_unavailable owner;
    List.iter (fun (space,space_id,observed_at) ->
      check bool "an unreadable missing Space is not published" true
        (Result.is_error (Owner.mark_ego_space_missing owner ~space ~space_id ~observed_at)))
      ["",12,1.;"masc",0,1.;"masc",12,(-1.);"masc",12,Float.nan];
    (* One claim at a time: a second while one runs is refused before the
       SDK is asked anything. *)
    ok (Owner.mark_ego_user_owned_name owner ~space:"busy" ~ids:[11] ~observed_at:4.);
    Owner.detach_ego_recovery owner;
    let claimed,claim_entered=Eio.Promise.create () and release,release_claim=Eio.Promise.create () in
    ok (Owner.attach_ego_recovery owner (fun _ ->
      ignore (Eio.Promise.try_resolve claim_entered ());
      ignore (Eio.Promise.await release);
      Ok (Owner.Reclaimed {space_id=11;space_name="busy"})));
    let running=Eio.Fiber.fork_promise ~sw (fun () -> send (take_over_route ())) in
    ignore (Eio.Promise.await claimed);
    check bool "a second reclaim while one runs is refused" true
      (pre_effect (send (take_over_route ())));
    ignore (Eio.Promise.try_resolve release_claim ());
    (match Eio.Promise.await_exn running with
     | W.Issue_result (Ok (B.Answered receipt)) ->
         check bool "the running reclaim answers with a receipt" true
           (receipt=`Assoc ["ok",`Bool true;"action",`String "take_over";"spaceId",`Int 11;
             "spaceName",`String "busy";"reclaimed",`Bool true])
     | W.Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
     | W.Issue_result (Error _)|W.Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|W.Service_refusal _ ->
         check bool "the running reclaim answers with a receipt" true false);
    Owner.clear_ego_unavailable owner;
    check bool "wrong incarnation cannot register" true
      (pre_effect (Owner.dispatch owner {W.incarnation=other_incarnation;command=W.Poll {client;window_sec=2.}}));
    let poll = Eio.Fiber.fork_promise ~sw (fun () -> send (W.Poll {client;window_sec=2.})) in
    let pending = Eio.Fiber.fork_promise ~sw issue in
    let issued = command (Eio.Promise.await_exn poll) in
    let closing,begin_close=Eio.Promise.create () and settled,finish_close=Eio.Promise.create () in
    let chrome_closing,begin_chrome_close=Eio.Promise.create ()
    and chrome_settled,finish_chrome_close=Eio.Promise.create () in
    let chrome_entered,enter_chrome=Eio.Promise.create () and chrome_wait,_=Eio.Promise.create () in
    Fun.protect ~finally:(fun () ->
      (* Release test-owned barriers before the switch joins protected cleanup,
         including when an assertion or the test's liveness guard fails. *)
      ignore (Eio.Promise.try_resolve finish_close ());
      ignore (Eio.Promise.try_resolve finish_chrome_close ())) (fun () ->
    let automation_calls=ref 0 and automation_cleanups=ref 0 and chrome_cleanups=ref 0
    and chrome_calls=ref 0 and chrome_actors=ref [] in
    ok (Owner.attach_automation owner ~locate:false
      ~execute:(fun _ -> incr automation_calls;B.Answered (`Assoc ["ok",`Bool true;"data",`Null]))
      ~session:(fun () -> B.Browser_closed)
      ~document:(fun ~tab_id:_ -> B.Rejected_before_effect "no document")
      ~cleanup:(fun () -> incr automation_cleanups;ignore (Eio.Promise.try_resolve begin_close ());
        Eio.Promise.await settled;Ok ()));
    check bool "unattached Chrome refuses before dispatch" true
      (pre_effect (send (W.Issue {route=B.Stagehand_route;verb=B.Session_status;
        actor=Some "keeper";timeout_sec=2.;only_if_idle=false})));
    check bool "companion cannot attach without the owned Chrome backend" true
      (Result.is_error (Owner.attach_extensions owner (fun _ -> fail "unattached companion ran")));
    ok (Owner.attach_stagehand owner ~models:true
      ~execute:(fun ~actor verb ->
        incr chrome_calls;chrome_actors:=actor:: !chrome_actors;
        (match verb with
         | B.Page_interact _ -> Eio.Promise.resolve enter_chrome ();Eio.Promise.await chrome_wait
         | _ -> ());
        B.Answered (`Assoc ["ok",`Bool true;"data",`Null]))
      ~session:(fun () -> B.Browser_closed)
      ~cleanup:(fun () -> incr chrome_cleanups;Eio.Promise.resolve begin_chrome_close ();
        Eio.Promise.await chrome_settled;Ok ()));
    check bool "a second Chrome backend cannot replace the owner" true
      (Result.is_error (Owner.attach_stagehand owner ~models:true
        ~execute:(fun ~actor:_ _ -> fail "replacement must not run")
        ~session:(fun () -> B.Browser_open) ~cleanup:(fun () -> fail "replacement must not close")));
    let extension_entered,enter_extension=Eio.Promise.create ()
    and extension_wait,_=Eio.Promise.create () in
    let extension_calls=ref 0 and extension_cancelled=ref false in
    ok (Owner.attach_extensions owner (fun _ ->
      incr extension_calls; Eio.Promise.resolve enter_extension ();
      Fun.protect ~finally:(fun () -> extension_cancelled:=true)
        (fun () -> Eio.Promise.await extension_wait)));
    check bool "a second companion cannot replace the owner" true
      (Result.is_error (Owner.attach_extensions owner (fun _ -> fail "replacement companion ran")));
    let extension=W.Extension (Masc.Browser_extension_protocol.Release incarnation) in
    check bool "wrong incarnation cannot reach the private companion" true
      (pre_effect (Owner.dispatch owner {W.incarnation=other_incarnation;command=extension}));
    let extension_pending=Eio.Fiber.fork_promise ~sw (fun () -> send extension) in
    Eio.Promise.await extension_entered;
    check int "private extension executes once" 1 !extension_calls;
    check bool "private extension wait does not hold owner admission" true
      (match send W.Snapshot with W.Snapshot_result _ -> true
       | Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _|Service_refusal _ -> false);
    let owned=Owner.snapshot owner |> Yojson.Safe.Util.member "owned_backends" |> Masc.Browser_addon_inventory.owned_of_json |> ok in
    check bool "ready backend is visible without inventing an open session" true
      (let automation,chrome=owned in automation.registered && chrome.registered
        && automation.session=B.Browser_closed && chrome.session=B.Browser_closed
        && automation.activity=B.Enabled && chrome.activity=B.Enabled);
    check bool "an unselected locate consumer refuses before backend work" true
      (pre_effect (send (W.Issue {route=B.Automation_route;verb=B.Page_locate {tab_id=1;instruction=None};
        actor=Some "keeper";timeout_sec=2.;only_if_idle=false})));
    check int "selection off sends no backend command" 0 !automation_calls;
    ignore (send (W.Issue {route=B.Automation_route;verb=B.Session_status;actor=Some "keeper";timeout_sec=2.;only_if_idle=false}));
    check int "owned backend command dispatched once" 1 !automation_calls;
    ignore (send (W.Issue {route=B.Stagehand_route;verb=B.Session_status;actor=Some "chrome-keeper";
      timeout_sec=2.;only_if_idle=false}));
    check (list (option string)) "Chrome receives the original actor" [Some "chrome-keeper"] !chrome_actors;
    let chrome_pending=Eio.Fiber.fork_promise ~sw (fun () ->
      send (W.Issue {route=B.Stagehand_route;
        verb=B.Page_interact {frame_path=[];tab_id=7;expected_url=None;action=B.Hover (B.Selector "#row")};
        actor=Some "chrome-keeper";timeout_sec=2.;only_if_idle=false})) in
    Eio.Promise.await chrome_entered;
    let retired=Eio.Fiber.fork_promise ~sw (fun () -> send W.Retire) in
    Eio.Promise.await closing;Eio.Promise.await chrome_closing;
    let also_retired=Eio.Fiber.fork_promise ~sw (fun () -> send W.Retire) in
    check bool "retirement starts both cleanups before joining either" true (Eio.Promise.peek retired=None);
    check bool "retirement fences new input before cleanup" true
      (pre_effect (send (W.Issue {route=B.Automation_route;verb=B.Session_status;actor=None;timeout_sec=2.;only_if_idle=false})));
    check bool "retirement fences Chrome before cleanup" true
      (pre_effect (send (W.Issue {route=B.Stagehand_route;verb=B.Session_status;actor=None;timeout_sec=2.;only_if_idle=false})));
    check bool "retirement revokes private extension admission" true (pre_effect (send extension));
    check bool "in-flight private extension outcome remains unknown" true
      (match Eio.Promise.await_exn extension_pending with
       | W.Service_refusal {disposition=W.Outcome_unknown;_} -> true
       | Service_refusal {disposition=W.Not_started;_}
       | Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false);
    check bool "retirement joins private extension cancellation" true !extension_cancelled;
    check int "private extension is never replayed" 1 !extension_calls;
    check bool "retirement removes both registry callbacks" true
      (B.inventory_observation B.Lane_name.Automation |> fun automation ->
        let chrome=B.inventory_observation B.Lane_name.Stagehand in
        automation.backend=B.Executor_registered false && chrome.backend=B.Executor_registered false);
    check bool "retired owner refuses a new Chrome backend" true
      (Result.is_error (Owner.attach_stagehand owner ~models:true
        ~execute:(fun ~actor:_ _ -> fail "retired owner must not execute")
        ~session:(fun () -> B.Browser_open) ~cleanup:(fun () -> fail "retired owner must not acquire")));
    Eio.Promise.resolve finish_close ();
    Eio.Fiber.yield ();
    check bool "one settled backend cannot release the other" true (Eio.Promise.peek retired=None);
    Eio.Promise.resolve finish_chrome_close ();
    check bool "retirement receipt follows both cleanups" true (receipt (Eio.Promise.await_exn retired));
    check bool "concurrent retirement joins the original cleanup" true (receipt (Eio.Promise.await_exn also_retired));
    check bool "repeated retirement observes the original result" true (receipt (send W.Retire));
    check int "automation cleanup executes once" 1 !automation_cleanups;
    check int "Chrome cleanup executes once" 1 !chrome_cleanups;
    check bool "in-flight Chrome input becomes unknown at retirement" true
      (match Eio.Promise.await_exn chrome_pending with
       | W.Service_refusal {disposition=W.Outcome_unknown;_} -> true
       | W.Service_refusal {disposition=W.Not_started;_}
       | W.Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false);
    check int "Chrome input was not replayed" 2 !chrome_calls;
    let result = Eio.Promise.await_exn pending in
    check bool "retirement does not prove no effect" true
      (match result with
       | W.Service_refusal {disposition=W.Outcome_unknown;_} -> true
       | W.Issue_result (Ok (B.Answered payload)) ->
           payload=`Assoc ["ok",`Bool false;"error",`String "client_disconnected"]
       | W.Service_refusal {disposition=W.Not_started;_}
       | W.Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
       | W.Issue_result (Error _)|Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt -> false);
    check bool "late result cannot attach to retired owner" true
      (pre_effect (send (W.Deliver {client_id=id;id=issued.id;payload})));
    check bool "retired owner cannot register again" true
      (pre_effect (send (W.Poll {client;window_sec=2.})));
    check int "retirement removed clients" 0 (List.length (B.connected_clients ()));
    check bool "same process cannot acquire a replacement registry" true
      (Result.is_error (Owner.create ~incarnation:other_incarnation))))))
let () = run "browser addon owner" ["lifecycle",[test_case "concurrent queue and retirement" `Quick scenario]]
