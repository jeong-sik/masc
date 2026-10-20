open Alcotest
module B = Browser_lane
module W = Masc.Browser_addon_wire
module Owner = Masc.Browser_addon_owner
let ok = function Ok value -> value | Error message -> fail message
let unknown = function
  | W.Service_refusal {disposition=W.Outcome_unknown;_} -> true
  | W.Service_refusal {disposition=W.Not_started;_}
  | W.Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false

let scenario () = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () -> Eio.Switch.run (fun sw ->
    let incarnation="0b000000-0000-4000-8000-000000000003" in
    let owner=ok (Owner.create ~incarnation) in
    Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
    let send ()=Owner.dispatch owner {W.incarnation;command=W.Retire} in
    let automation_started,start_automation=Eio.Promise.create ()
    and chrome_started,start_chrome=Eio.Promise.create ()
    and live_started,start_live=Eio.Promise.create ()
    and live_settled,settle_live=Eio.Promise.create ()
    and automation_settled,settle_automation=Eio.Promise.create ()
    and chrome_settled,settle_chrome=Eio.Promise.create () in
    Fun.protect ~finally:(fun () ->
      (* These test barriers must not outlive a failed assertion or cancellation;
         protected production cleanup is joined by the enclosing switch. *)
      ignore (Eio.Promise.try_resolve settle_automation ());
      ignore (Eio.Promise.try_resolve settle_live ());
      ignore (Eio.Promise.try_resolve settle_chrome ())) (fun () ->
    let automation_calls=ref 0 and chrome_calls=ref 0 and live_calls=ref 0 in
    let client_id=ok (B.client_id_of_string "0b000000-0000-4000-8000-000000000004") in
    check bool "unregistered clients grant no owned cleanup" true
      (Result.is_error (Owner.attach_live owner ~client_id ~cleanup:(fun () -> fail "foreign cleanup")));
    let client:B.client_info={client_id;browser=B.Firefox;version="fixture";
      engine_version="fixture";transport=B.Webdriver_bidi} in
    (match Owner.dispatch owner {W.incarnation;command=W.Poll {client;window_sec=0.001}} with
     | W.Poll_result _ -> ()
     | Service_refusal _|Snapshot_result _|Model_reply _|Download_reply _|Receipt|Issue_result _ -> fail "live registration refused");
    ok (Owner.attach_live owner ~client_id ~cleanup:(fun () ->
      incr live_calls;Eio.Promise.resolve start_live ();Eio.Promise.await live_settled;Ok ()));
    ok (Owner.attach_automation owner ~locate:false
      ~execute:(fun _ -> fail "retirement must not dispatch browser input")
      ~session:(fun () -> B.Browser_closed)
      ~document:(fun ~tab_id:_ -> fail "retirement must not read a page")
      ~cleanup:(fun () -> incr automation_calls;Eio.Promise.resolve start_automation ();
        Eio.Promise.await automation_settled;Error "automation settlement unconfirmed"));
    ok (Owner.attach_stagehand owner ~models:true
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
    Eio.Promise.await automation_started;Eio.Promise.await chrome_started;Eio.Promise.await live_started;
    check bool "retirement fences original live client before joining it" true
      (not (List.exists (fun (client:B.client_info) -> client.client_id=client_id) (B.active_clients ())));
    Eio.Cancel.cancel (Eio.Promise.await cancelling) Exit;
    let second=Eio.Fiber.fork_promise ~sw send in
    Eio.Fiber.yield ();
    check bool "cancelled Retire still joins its original cleanup" true (Eio.Promise.peek first=None);
    Eio.Promise.resolve settle_automation ();
    Eio.Fiber.yield ();
    check bool "one failed cleanup cannot skip the other" true (Eio.Promise.peek second=None);
    Eio.Promise.resolve settle_chrome ();
    Eio.Fiber.yield ();
    check bool "live child settlement is joined too" true (Eio.Promise.peek second=None);
    Eio.Promise.resolve settle_live ();
    check bool "caller cancellation propagates after cleanup" true (Eio.Promise.await_exn first=None);
    let reply=Eio.Promise.await_exn second in
    check bool "cleanup failures cannot become a retirement receipt" true (unknown reply);
    check bool "cleanup exceptions do not leak private diagnostics" true
      (match reply with
       | W.Service_refusal {message;_} ->
         message="automation settlement unconfirmed; Stagehand backend cleanup raised; settlement is unconfirmed"
       | W.Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false);
    check bool "repeated Retire retains the same failure" true (send ()=reply);
    check int "failed automation cleanup is not replayed" 1 !automation_calls;
    check int "owned live cleanup is not replayed" 1 !live_calls;
    check int "raised Chrome cleanup is not replayed" 1 !chrome_calls))))

let unconfirmed_downloads () =
  let root=Unix.realpath (Filename.temp_dir ~perms:0o700 "browser-owner-download-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let directory=Filename.concat root "downloads" in Unix.mkdir directory 0o700;
    let source=Filename.concat directory "completed.bin" in
    Out_channel.with_open_bin source (fun out -> output_string out "retained bytes");
    let downloads=ok (Masc.Browser_addon_downloads.create ~directory:root) in
    Eio_main.run (fun _env ->
      let incarnation="0b000000-0000-4000-8000-000000000005" in
      let owner=ok (Owner.create ~incarnation) in
      ok (Owner.attach_downloads owner downloads);
      ignore (ok (Eio_unix.run_in_systhread (fun () -> Owner.publish_download owner source)));
      ok (Owner.attach_automation owner ~locate:false
        ~execute:(fun _ -> fail "retirement must not issue browser input")
        ~session:(fun () -> B.Browser_closed)
        ~document:(fun ~tab_id:_ -> fail "retirement must not read a page")
        ~cleanup:(fun () -> Error "backend still owns its files"));
      let retire ()=Owner.dispatch owner {W.incarnation;command=W.Retire} in
      let first=retire () in
      check bool "unconfirmed backend cannot release the owner" true (unknown first);
      check bool "repeat retirement keeps its original failure" true (retire ()=first);
      let result=Eio_unix.run_in_systhread (fun () -> Masc.Browser_addon_downloads.cleanup downloads) in
      check bool "owner abandoned pins without authorizing file cleanup" true
        (result=Error "download cleanup requires confirmed backend teardown");
      check string "backend failure preserves original bytes" "retained bytes"
        (In_channel.with_open_bin source In_channel.input_all)))

let () = run "browser addon cleanup" ["lifecycle",[
  test_case "all backends settle despite failure and caller cancellation" `Quick scenario;
  test_case "unconfirmed backend abandons download pins without deleting files" `Quick unconfirmed_downloads]]
