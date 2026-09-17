open Alcotest

(* The sync-failure guard around [Eio.Fiber.fork_daemon].

   Against a live Eio runtime the only synchronous throw a daemon launch
   makes is [Invalid_argument "Switch finished!"] from the switch check --
   the launch happens after the switch is done, exactly what a key handler
   racing the TUI teardown sees. The check itself runs under the scheduler's
   effects, so both tests go through [Eio_main.run]; a real finished switch
   reproduces the throw with no server and no waiting.

   A daemon body only runs when the scheduler reaches it, so what the tests
   pin down is the launch's own behavior: a finished switch runs the failure
   move and never the body, an open switch runs neither. *)

let test_a_finished_switch_runs_the_failure_move () =
  Eio_main.run (fun _ ->
      let finished = ref None in
      Eio.Switch.run (fun sw -> finished := Some sw);
      match !finished with
      | None -> fail "could not capture a finished switch"
      | Some sw ->
          let failures = ref [] in
          let daemon_ran = ref false in
          Masc_tui_fork_guard.launch ~sw
            ~on_sync_failure:(fun detail -> failures := detail :: !failures)
            (fun () ->
              daemon_ran := true;
              `Stop_daemon);
          check (list string) "one failure move, with the switch's own complaint"
            [ "Invalid_argument(\"Switch finished!\")" ] !failures;
          check bool "the daemon body never ran" false !daemon_ran)

let test_an_open_switch_makes_no_failure_move () =
  Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
          let failures = ref [] in
          Masc_tui_fork_guard.launch ~sw
            ~on_sync_failure:(fun detail -> failures := detail :: !failures)
            (fun () -> `Stop_daemon);
          check (list string) "no failure move on an open switch" [] !failures))

let suite =
  [
    ("finished switch", [ test_case "runs the failure move" `Quick
                            test_a_finished_switch_runs_the_failure_move ]);
    ("open switch", [ test_case "makes no failure move" `Quick
                        test_an_open_switch_makes_no_failure_move ]);
  ]

let () = run "test_tui_fork_guard" suite
