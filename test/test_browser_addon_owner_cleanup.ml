open Alcotest
module B = Browser_lane
module W = Masc.Browser_addon_wire
module Owner = Masc.Browser_addon_owner
let ok = function Ok value -> value | Error message -> fail message
let unknown = function
  | W.Service_refusal {disposition=W.Outcome_unknown;_} -> true
  | W.Service_refusal {disposition=W.Not_started;_}
  | W.Snapshot_result _|Model_reply _|Poll_result _|Receipt|Issue_result _ -> false

let scenario () = Eio_main.run (fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () -> Eio.Switch.run (fun sw ->
    let incarnation="0b000000-0000-4000-8000-000000000003" in
    let owner=ok (Owner.create ~incarnation) in
    Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
    let send ()=Owner.dispatch owner {W.incarnation;command=W.Retire} in
    let automation_started,start_automation=Eio.Promise.create ()
    and chrome_started,start_chrome=Eio.Promise.create ()
    and automation_settled,settle_automation=Eio.Promise.create ()
    and chrome_settled,settle_chrome=Eio.Promise.create () in
    let automation_calls=ref 0 and chrome_calls=ref 0 in
    ok (Owner.attach_automation owner ~locate:false
      ~execute:(fun _ -> fail "retirement must not dispatch browser input")
      ~session:(fun () -> B.Browser_closed)
      ~document:(fun ~tab_id:_ -> fail "retirement must not read a page")
      ~cleanup:(fun () -> incr automation_calls;Eio.Promise.resolve start_automation ();
        Eio.Promise.await automation_settled;Error "automation settlement unconfirmed"));
    ok (Owner.attach_stagehand owner
      ~execute:(fun ~actor:_ _ -> fail "retirement must not dispatch Chrome input")
      ~session:(fun () -> B.Browser_closed)
      ~cleanup:(fun () -> incr chrome_calls;Eio.Promise.resolve start_chrome ();
        Eio.Promise.await chrome_settled;raise (Failure "private backend diagnostic")));
    let cancelling,cancel=Eio.Promise.create () in
    let first=Eio.Fiber.fork_promise ~sw (fun () ->
      try Eio.Cancel.sub (fun context ->
        Eio.Promise.resolve cancel context;
        let reply=send () in Eio.Fiber.check ();Some reply)
      with Eio.Cancel.Cancelled _ -> Eio.Fiber.check ();None) in
    Eio.Promise.await automation_started;Eio.Promise.await chrome_started;
    Eio.Cancel.cancel (Eio.Promise.await cancelling) Exit;
    let second=Eio.Fiber.fork_promise ~sw send in
    Eio.Fiber.yield ();
    check bool "cancelled Retire still joins its original cleanup" true (Eio.Promise.peek first=None);
    Eio.Promise.resolve settle_automation ();
    Eio.Fiber.yield ();
    check bool "one failed cleanup cannot skip the other" true (Eio.Promise.peek second=None);
    Eio.Promise.resolve settle_chrome ();
    check bool "caller cancellation propagates after cleanup" true (Eio.Promise.await_exn first=None);
    let reply=Eio.Promise.await_exn second in
    check bool "cleanup failures cannot become a retirement receipt" true (unknown reply);
    check bool "cleanup exceptions do not leak private diagnostics" true
      (match reply with
       | W.Service_refusal {message;_} ->
         message="automation settlement unconfirmed; Stagehand backend cleanup raised; settlement is unconfirmed"
       | W.Snapshot_result _|Model_reply _|Poll_result _|Receipt|Issue_result _ -> false);
    check bool "repeated Retire retains the same failure" true (send ()=reply);
    check int "failed automation cleanup is not replayed" 1 !automation_calls;
    check int "raised Chrome cleanup is not replayed" 1 !chrome_calls)))

let () = run "browser addon cleanup" ["lifecycle",[
  test_case "all backends settle despite failure and caller cancellation" `Quick scenario]]
