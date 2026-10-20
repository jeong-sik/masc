open Alcotest
module B = Browser_lane
module W = Masc.Browser_addon_wire
module Owner = Masc.Browser_addon_owner
let ok = function Ok value -> value | Error message -> fail message
let incarnation = "0b000000-0000-4000-8000-000000000001"
let other_incarnation = "0b000000-0000-4000-8000-000000000002"
let id = ok (B.client_id_of_string "0c000000-0000-4000-8000-000000000001")
let client = {B.client_id=id;browser=B.Firefox;version="158";engine_version="158";transport=B.Webdriver_bidi}
let receipt = function
  | W.Receipt -> true
  | W.Snapshot_result _|Poll_result _|Issue_result _|Service_refusal _ -> false
let pre_effect = function
  | W.Service_refusal {disposition=W.Not_started;_} -> true
  | W.Service_refusal {disposition=W.Outcome_unknown;_}
  | W.Snapshot_result _|Poll_result _|Receipt|Issue_result _ -> false
let command = function
  | W.Poll_result {command=Some command;_} -> command
  | W.Poll_result {command=None;_}|Snapshot_result _|Receipt|Issue_result _|Service_refusal _ -> fail "expected dispatched command"
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
      verb=B.Page_interact {tab_id=7;expected_url=Some "https://example.org/";action=B.Hover (B.Selector "#row")};
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
       | W.Issue_result (Error _)|Snapshot_result _|Poll_result _|Receipt|Service_refusal _ -> false);
    check bool "identical result retry is idempotent" true
      (receipt (send (W.Deliver {client_id=id;id=issued.id;payload})));
    check bool "changed retry is refused" true
      (pre_effect (send (W.Deliver {client_id=id;id=issued.id;payload=`Null})));
    check bool "unpinned browser cannot execute" true
      (pre_effect (send (W.Issue {route=B.Live_route None;verb=B.Tabs_list;actor=None;timeout_sec=2.;only_if_idle=false})));
    check bool "wrong incarnation cannot register" true
      (pre_effect (Owner.dispatch owner {W.incarnation=other_incarnation;command=W.Poll {client;window_sec=2.}}));
    let poll = Eio.Fiber.fork_promise ~sw (fun () -> send (W.Poll {client;window_sec=2.})) in
    let pending = Eio.Fiber.fork_promise ~sw issue in
    let issued = command (Eio.Promise.await_exn poll) in
    Owner.revoke owner;
    let result = Eio.Promise.await_exn pending in
    check bool "retirement does not prove no effect" true
      (match result with
       | W.Service_refusal {disposition=W.Outcome_unknown;_} -> true
       | W.Issue_result (Ok (B.Answered payload)) ->
           payload=`Assoc ["ok",`Bool false;"error",`String "client_disconnected"]
       | W.Service_refusal {disposition=W.Not_started;_}
       | W.Issue_result (Ok (B.Lane_absent|Timed_out|Refused _|Rejected_before_effect _))
       | W.Issue_result (Error _)|Snapshot_result _|Poll_result _|Receipt -> false);
    check bool "late result cannot attach to retired owner" true
      (pre_effect (send (W.Deliver {client_id=id;id=issued.id;payload})));
    check bool "retired owner cannot register again" true
      (pre_effect (send (W.Poll {client;window_sec=2.})));
    check int "retirement removed clients" 0 (List.length (B.connected_clients ()));
    check bool "same process cannot acquire a replacement registry" true
      (Result.is_error (Owner.create ~incarnation:other_incarnation)))))
let () = run "browser addon owner" ["lifecycle",[test_case "concurrent queue and retirement" `Quick scenario]]
