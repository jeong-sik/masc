let check = Alcotest.check
let test_deferred_owner_activation () =
  let previous = Runtime_startup_state.get () in
  Fun.protect ~finally:(fun () -> Runtime_startup_state.set previous) (fun () ->
    Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
      Runtime_startup_state.set (Setup_required Config_missing);
      let configured = ref false and starts = ref 0 and attempts = ref 0 in
      Server_model_setup_resume.install ~sw ~base_path:"/fixture-owner"
        ~resume:(fun () ->
          incr attempts;
          if not !configured then Error Configuration_unavailable
          else (Runtime_startup_state.set Available; Ok false));
      Eio.Fiber.fork ~sw (fun () ->
        Runtime_startup_state.await_available ();
        incr starts);
      Eio.Fiber.yield ();
      check Alcotest.int "model-less owner does not boot keeper services" 0 !starts;
      (match Server_model_setup_resume.request ~base_path:"/other-owner" with
       | Error Workspace_mismatch -> () | _ -> Alcotest.fail "cross-workspace resume accepted");
      check Alcotest.int "wrong owner never invokes activation" 0 !attempts;
      (match Server_model_setup_resume.request ~base_path:"/fixture-owner" with
       | Error Configuration_unavailable -> () | _ -> Alcotest.fail "invalid config activated services");
      Runtime_startup_state.note_runtime_loaded ();
      Eio.Fiber.yield ();
      check Alcotest.int "config save alone cannot activate skipped services" 0 !starts;
      configured := true;
      (match Server_model_setup_resume.request ~base_path:"/fixture-owner" with
       | Ok false -> () | _ -> Alcotest.fail "conversation needs no exact-output authority");
      Eio.Fiber.yield ();
      check Alcotest.int "same owner resumes deferred services" 1 !starts;
      ignore (Server_model_setup_resume.request ~base_path:"/fixture-owner");
      Eio.Fiber.yield ();
      check Alcotest.int "repeat resume never forks duplicate service" 1 !starts)));
  match Server_model_setup_resume.request ~base_path:"/fixture-owner" with
  | Error Owner_not_ready -> () | _ -> Alcotest.fail "closed owner retained activation authority"

let () = Alcotest.run "model setup resume"
  ["owner lifecycle",[Alcotest.test_case "save, retry and exactly-once activation" `Quick test_deferred_owner_activation]]
