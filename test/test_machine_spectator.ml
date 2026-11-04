open Alcotest

let with_env f = Eio_main.run (fun env -> Eio.Switch.run (fun sw -> f env sw))

let test_ticker_stops_with_the_observer_stream () = with_env (fun env sw ->
  let calls = ref 0 in
  Server_machine_spectator.For_testing.with_step
    (fun ~config:_ ~machine:_ -> incr calls; Ok ())
    (fun () ->
      let stop_promise, stop = Eio.Promise.create () in
      Server_machine_spectator.start ~sw ~clock:(Eio.Stdenv.clock env) ~stop_promise
        ~machine:Masc.Machine_lane.Msx
        ~config:(Masc.Workspace.default_config "/fixture");
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.45;
      check bool "the active spectator advanced the machine" true (!calls > 0);
      Eio.Promise.resolve stop ();
      let stopped = !calls in
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.45;
      check int "a closed stream advances nothing more" stopped !calls))

let test_observer_machine_query () =
  List.iter
    (fun (target, expected) ->
      match Server_machine_spectator.machine_of_request_target target with
      | Ok machine ->
          check string "the selected machine survives the query" expected
            (Option.value ~default:"" (Option.map Masc.Machine_lane.to_wire machine))
      | Error detail -> fail detail)
    [ "/mcp?sse_kind=observer", ""
    ; "/mcp?sse_kind=observer&machine=msx", "msx"
    ; "/mcp?sse_kind=observer&machine=dos", "dos" ];
  match Server_machine_spectator.machine_of_request_target "/mcp?sse_kind=observer&machine=other" with
  | Error _ -> ()
  | Ok _ -> fail "an unknown machine was admitted"

let () =
  run "machine spectator"
    [ "lifecycle", [ test_case "ticker stops with its observer stream" `Quick
        test_ticker_stops_with_the_observer_stream ]
    ; "query", [ test_case "only a named machine is admitted" `Quick
        test_observer_machine_query ] ]
