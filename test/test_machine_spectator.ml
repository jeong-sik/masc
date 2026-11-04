open Alcotest

let with_env f = Eio_main.run (fun env -> Eio.Switch.run (fun sw -> f env sw))

let test_ticker_stops_with_the_observer_stream () = with_env (fun env sw ->
  let calls = ref 0 in
  Machine_spectator.For_testing.with_step
    (fun ~config:_ ~machine:_ -> incr calls; Ok ())
    (fun () ->
      let stop_promise, stop = Eio.Promise.create () in
      Machine_spectator.start ~sw ~stop_promise ~machine:Masc.Machine_lane.Msx
        ~config:(Masc.Workspace.default_config "/fixture");
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.45;
      check bool "the active spectator advanced the machine" true (!calls > 0);
      Eio.Promise.resolve stop ();
      let stopped = !calls in
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.45;
      check int "a closed stream advances nothing more" stopped !calls))

let () =
  run "machine spectator"
    [ "lifecycle", [ test_case "ticker stops with its observer stream" `Quick
        test_ticker_stops_with_the_observer_stream ] ]
