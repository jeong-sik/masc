open Alcotest

let run_domains_together count fn =
  let ready = Atomic.make 0 in
  let go = Atomic.make false in
  let domains =
    List.init count (fun index ->
      Domain.spawn (fun () ->
        ignore (Atomic.fetch_and_add ready 1);
        while not (Atomic.get go) do
          Domain.cpu_relax ()
        done;
        fn index))
  in
  while Atomic.get ready < count do
    Domain.cpu_relax ()
  done;
  Atomic.set go true;
  List.iter Domain.join domains

let test_unregister_if_current () =
  let open Masc_mcp.Sse in
  let session_id = "test_session" in
  let noop _ = () in

  let (id1, _, _) = register session_id ~push:noop ~last_event_id:0 in
  check bool "registered" true (exists session_id);

  (* Re-register same session_id (simulates reconnect) *)
  let (id2, _, _) = register session_id ~push:noop ~last_event_id:0 in
  check bool "still registered" true (exists session_id);

  (* Old connection cleanup must not unregister the new connection *)
  unregister_if_current session_id id1;
  check bool "new connection survives old cleanup" true (exists session_id);

  (* Current connection cleanup should unregister *)
  unregister_if_current session_id id2;
  check bool "unregistered" false (exists session_id);
  ()

let test_cleanup_stale_respects_touch () =
  let open Masc_mcp.Sse in
  let stale_sid = "stale_session_" ^ string_of_int (Random.int 1000000) in
  let alive_sid = "alive_session_" ^ string_of_int (Random.int 1000000) in
  let noop _ = () in
  let (_id1, _, _) = register stale_sid ~push:noop ~last_event_id:0 in
  let (_id2, _, _) = register alive_sid ~push:noop ~last_event_id:0 in

  Unix.sleepf 0.05;
  touch alive_sid;

  let evicted = cleanup_stale ~max_age_s:0.02 () in
  check bool "stale evicted" true (List.mem stale_sid evicted);
  check bool "stale removed" false (exists stale_sid);
  check bool "touched connection survives" true (exists alive_sid);

  unregister alive_sid

let test_concurrent_register_unregister () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let open Masc_mcp.Sse in
  let n = 50 in
  let prefix = "conc_" ^ string_of_int (Random.int 1000000) ^ "_" in
  let noop _ = () in
  let count_before = client_count () in
  (* N fibers register, then unregister concurrently.
     Switch.run waits for all forked fibers before returning. *)
  Eio.Switch.run (fun sw ->
    for i = 0 to n - 1 do
      Eio.Fiber.fork ~sw (fun () ->
        let sid = prefix ^ string_of_int i in
        let (_id, _, _) = register sid ~push:noop ~last_event_id:0 in
        Eio.Fiber.yield ();
        unregister sid)
    done);
  (* All fibers have completed — count should be restored *)
  let count_after = client_count () in
  check int "count restored" count_before count_after

let test_client_count_linearized_under_domain_contention () =
  let open Masc_mcp.Sse in
  let worker_count = 24 in
  let prefix = "count_linearized_" ^ string_of_int (Random.int 1_000_000) ^ "_" in
  let noop _ = () in
  let session_id index = prefix ^ string_of_int index in
  let count_before = client_count () in
  Fun.protect
    ~finally:(fun () ->
      for index = 0 to worker_count - 1 do
        unregister (session_id index)
      done)
    (fun () ->
      run_domains_together worker_count (fun index ->
        ignore (register (session_id index) ~push:noop ~last_event_id:0));
      check int "count after concurrent register" (count_before + worker_count)
        (client_count ());
      run_domains_together worker_count (fun index ->
        unregister (session_id index));
      check int "count restored after concurrent unregister" count_before
        (client_count ()))

let () =
  run "sse"
    [
      ("unregister_if_current", [test_case "guards reconnect" `Quick test_unregister_if_current]);
      ("cleanup_stale", [test_case "uses idle time" `Quick test_cleanup_stale_respects_touch]);
      ("concurrency", [
        test_case "concurrent register/unregister" `Quick test_concurrent_register_unregister;
        test_case "client_count linearized under domain contention" `Quick
          test_client_count_linearized_under_domain_contention;
      ]);
    ]
