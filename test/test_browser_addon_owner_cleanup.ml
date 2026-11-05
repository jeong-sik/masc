open Alcotest
module B = Browser_lane
module W = Masc.Browser_addon_wire
module Owner = Masc.Browser_addon_owner
let ok = function Ok value -> value | Error message -> fail message
let unknown = function
  | W.Service_refusal {disposition=W.Outcome_unknown;_} -> true
  | W.Service_refusal {disposition=W.Not_started;_}
  | W.Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false

let scenario () =
  let root=Unix.realpath (Filename.temp_dir ~perms:0o700 "browser-owner-download-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
  let directory=Filename.concat root "downloads" in Unix.mkdir directory 0o700;
  let source=Filename.concat directory "completed.bin" in
  Out_channel.with_open_bin source (fun out -> output_string out "retained bytes");
  let downloads=ok (Masc.Browser_addon_downloads.create ~directory:root) in
  Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () -> Eio.Switch.run (fun sw ->
    let incarnation="0b000000-0000-4000-8000-000000000003" in
    let owner=ok (Owner.create ~incarnation) in
    Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
    ok (Owner.attach_downloads owner downloads);
    ignore (ok (Eio_unix.run_in_systhread (fun () -> Owner.publish_download owner source)));
    let send ()=Owner.dispatch owner {W.incarnation;command=W.Retire} in
    let automation_started,start_automation=Eio.Promise.create ()
    and live_started,start_live=Eio.Promise.create ()
    and live_settled,settle_live=Eio.Promise.create ()
    and automation_settled,settle_automation=Eio.Promise.create () in
    Fun.protect ~finally:(fun () ->
      (* These test barriers must not outlive a failed assertion or cancellation;
         protected production cleanup is joined by the enclosing switch. *)
      ignore (Eio.Promise.try_resolve settle_automation ());
      ignore (Eio.Promise.try_resolve settle_live ())) (fun () ->
    let automation_calls=ref 0 and live_calls=ref 0 in
    let client_id=ok (B.client_id_of_string "0b000000-0000-4000-8000-000000000004") in
    check bool "unregistered clients grant no owned cleanup" true
      (Result.is_error (Owner.attach_live owner ~client_id ~cleanup:(fun () -> fail "foreign cleanup")));
    let client:B.client_info={client_id;browser=B.Firefox;version="fixture";
      engine_version="fixture";transport=B.Webdriver_bidi;space=None} in
    (match Owner.dispatch owner {W.incarnation;command=W.Poll {client;window_sec=0.001}} with
     | W.Poll_result _ -> ()
     | Service_refusal _|Snapshot_result _|Model_reply _|Download_reply _|Receipt|Issue_result _ -> fail "live registration refused");
    ok (Owner.attach_live owner ~client_id ~cleanup:(fun () ->
      incr live_calls;Eio.Promise.resolve start_live ();Eio.Promise.await live_settled;Error "live settlement unconfirmed"));
    (* The owner ends its own connection, so the lane does not time it. *)
    check bool "the owner holds the live connection it attached" true
      (match B.resolve_target ~verb:B.Tabs_list (B.Live_route (Some client_id)) with
       | Ok (B.Live_client attached) ->
         (match attached.liveness with B.Worker_held -> true | B.Polled _ -> false)
       | Ok (B.Automation) | Error _ -> false);
    ok (Owner.attach_automation owner ~locate:false
      ~execute:(fun _ -> fail "retirement must not dispatch browser input")
      ~session:(fun () -> B.Browser_closed)
      ~document:(fun ~tab_id:_ -> fail "retirement must not read a page")
      ~cleanup:(fun () -> incr automation_calls;Eio.Promise.resolve start_automation ();
        Eio.Promise.await automation_settled;raise (Failure "private backend diagnostic")));
    let cancelling,cancel=Eio.Promise.create () in
    let first=Eio.Fiber.fork_promise ~sw (fun () ->
      try Eio.Cancel.sub (fun context ->
        Eio.Promise.resolve cancel context;
        let reply=send () in Eio.Fiber.check ();Some reply)
      with Eio.Cancel.Cancelled _ -> Eio.Fiber.check ();None) in
    Eio.Promise.await automation_started;Eio.Promise.await live_started;
    check bool "retirement fences original live client before joining it" true
      (not (List.exists (fun (client:B.client_info) -> client.client_id=client_id) (B.active_clients ())));
    Eio.Cancel.cancel (Eio.Promise.await cancelling) Exit;
    let second=Eio.Fiber.fork_promise ~sw send in
    Eio.Fiber.yield ();
    check bool "cancelled Retire still joins its original cleanup" true (Eio.Promise.peek first=None);
    Eio.Promise.resolve settle_automation ();
    Eio.Fiber.yield ();
    check bool "one failed cleanup cannot skip the other" true (Eio.Promise.peek second=None);
    Eio.Promise.resolve settle_live ();
    check bool "caller cancellation propagates after cleanup" true (Eio.Promise.await_exn first=None);
    let reply=Eio.Promise.await_exn second in
    check bool "cleanup failures cannot become a retirement receipt" true (unknown reply);
    check bool "cleanup exceptions do not leak private diagnostics" true
      (match reply with
       | W.Service_refusal {message;_} ->
         message="live settlement unconfirmed; automation backend cleanup raised; settlement is unconfirmed; download cleanup requires confirmed backend teardown"
       | W.Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false);
    check bool "repeated Retire retains the same failure" true (send ()=reply);
    check int "raised automation cleanup is not replayed" 1 !automation_calls;
    check int "failed live cleanup is not replayed" 1 !live_calls;
    let result=Eio_unix.run_in_systhread (fun () -> Masc.Browser_addon_downloads.cleanup downloads) in
    check bool "owner abandoned pins without authorizing file cleanup" true
      (result=Error "download cleanup requires confirmed backend teardown");
    check string "backend failure preserves original bytes" "retained bytes"
      (In_channel.with_open_bin source In_channel.input_all))))))

(* One live connection per transport at a time. A connection that ended,
   as one whose ego Space went missing does, lets the next one attach and
   keeps its cleanup for retirement. *)
let an_ended_live_connection_yields_its_transport () =
  Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () -> Eio.Switch.run (fun sw ->
    let incarnation="0b000000-0000-4000-8000-000000000005" in
    let owner=ok (Owner.create ~incarnation) in
    Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
    let register id =
      let client_id=ok (B.client_id_of_string id) in
      let client:B.client_info={client_id;browser=B.Firefox;version="fixture";
        engine_version="fixture";transport=B.Webdriver_bidi;space=None} in
      (match Owner.dispatch owner {W.incarnation;command=W.Poll {client;window_sec=0.001}} with
       | W.Poll_result _ -> ()
       | Service_refusal _|Snapshot_result _|Model_reply _|Download_reply _|Receipt|Issue_result _ ->
         fail "live registration refused");
      client_id in
    let settled=ref 0 in
    let attach client_id result=Owner.attach_live owner ~client_id ~cleanup:(fun () -> incr settled;result) in
    let first=register "0b000000-0000-4000-8000-000000000006" in
    ok (attach first (Error "the first connection's Space was gone"));
    let second=register "0b000000-0000-4000-8000-000000000007" in
    check bool "a second connection of the transport is refused while the first serves" true
      (Result.is_error (attach second (Ok ())));
    Owner.disconnect_live owner first;
    ok (attach second (Ok ()));
    check bool "retirement settles the ended connection too" true
      (match Owner.dispatch owner {W.incarnation;command=W.Retire} with
       | W.Service_refusal {disposition=W.Outcome_unknown;message} -> message="the first connection's Space was gone"
       | W.Service_refusal {disposition=W.Not_started;_}
       | W.Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> false);
    check int "each attached connection is settled once" 2 !settled)))

(* A process holds one browser owner, so this case runs in its own process.
   An earlier case's process manager can interrupt the wait with SIGCHLD. *)
let rec reaped pid = match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> reaped pid
let isolated case () =
  let pid = Unix.create_process Sys.executable_name [|Sys.executable_name;"--case";case|] Unix.stdin Unix.stdout Unix.stderr in
  check bool ("isolated owner case " ^ case) true (reaped pid = Unix.WEXITED 0)

let () =
  if Array.length Sys.argv = 3 && Sys.argv.(1) = "--case" && Sys.argv.(2) = "reattach" then
    an_ended_live_connection_yields_its_transport ()
  else run "browser addon cleanup" ["lifecycle",[
    test_case "all backends settle despite failure and caller cancellation" `Quick scenario;
    test_case "an ended live connection yields its transport" `Quick (isolated "reattach")]]
