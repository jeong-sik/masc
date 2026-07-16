open Masc

let make_meta () =
  let json =
    `Assoc
      [ "name", `String "read-runner-keeper"
      ; "agent_name", `String "agent-read-runner"
      ; "trace_id", `String "trace-read-runner"
      ; "allowed_paths", `List [ `String "*" ]
      ; "sandbox_profile", `String "docker"
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e

let config = Workspace.default_config "/tmp/masc-read-runner-test"
let meta = make_meta ()

module Calls = struct
  let events = ref []
  let ok_exit_codes = ref []
  let reset () = events := []; ok_exit_codes := []
  let push event = events := event :: !events
  let events () = List.rev !events
end

module Mock_backend = struct
  let should_route_read ~meta:_ =
    Calls.push "should_route_read";
    true

  let container_path_of_host ~config:_ ~meta:_ ~host_path =
    Calls.push ("container_path:" ^ host_path);
    Ok ("/container" ^ host_path)

  let read_file
      ?turn_sandbox_factory:_
      ~config:_
      ~meta:_
      ~host_path
      ~max_bytes
      ~timeout_sec
      () =
    Calls.push
      (Printf.sprintf
         "read_file:%s:%d:%.1f"
         host_path
         max_bytes
         timeout_sec);
    Ok "mock file body"

  let run_command_with_status
      ?turn_sandbox_factory:_
      ?(ok_exit_codes = [ 0 ])
      ~config:_
      ~meta:_
      ~command_argv
      ~max_bytes
      ~timeout_sec
      () =
    Calls.ok_exit_codes := ok_exit_codes;
    Calls.push
      (Printf.sprintf
         "run_status:%s:%d:%.1f"
         (String.concat "," command_argv)
         max_bytes
         timeout_sec);
    Ok (Unix.WEXITED 0, "mock command output")

  let run_command
      ?turn_sandbox_factory:_
      ?(ok_exit_codes = [ 0 ])
      ~config:_
      ~meta:_
      ~command_argv
      ~max_bytes
      ~timeout_sec
      () =
    Calls.ok_exit_codes := ok_exit_codes;
    Calls.push
      (Printf.sprintf
         "run:%s:%d:%.1f"
         (String.concat "," command_argv)
         max_bytes
         timeout_sec);
    Ok "mock stdout"
end

module Runner = Keeper_sandbox_read_runner.Make (Mock_backend)

let test_route_labels_match_sandbox_runner () =
  Alcotest.(check string)
    "host via"
    (Keeper_sandbox_runner.route_label Keeper_sandbox_runner.Host)
    Runner.host_via;
  Alcotest.(check string)
    "backend via"
    (Keeper_sandbox_runner.route_label Keeper_sandbox_runner.Sandbox_backend)
    Runner.backend_via

let test_mock_backend_forwards_read_contract () =
  Calls.reset ();
  Alcotest.(check bool)
    "should route"
    true
    (Runner.should_route_read ~meta);
  Alcotest.(check (result string string))
    "container path"
    (Ok "/container/host/file.txt")
    (Runner.container_path_of_host
       ~config
       ~meta
       ~host_path:"/host/file.txt");
  Alcotest.(check (result string string))
    "read file"
    (Ok "mock file body")
    (Runner.read_file
       ~config
       ~meta
       ~host_path:"/host/file.txt"
       ~max_bytes:128
       ~timeout_sec:2.5
       ());
  Alcotest.(check (list string))
    "events"
    [ "should_route_read"
    ; "container_path:/host/file.txt"
    ; "read_file:/host/file.txt:128:2.5"
    ]
    (Calls.events ())

let test_mock_backend_forwards_command_contract () =
  Calls.reset ();
  (match
     Runner.run_command_with_status
       ~ok_exit_codes:[ 0; 1 ]
       ~config
       ~meta
       ~command_argv:[ "rg"; "needle"; "/container/repo" ]
       ~max_bytes:512
       ~timeout_sec:3.0
       ()
   with
   | Ok (Unix.WEXITED 0, "mock command output") -> ()
   | Ok (status, output) ->
     Alcotest.failf
       "unexpected status/output: %s %S"
       (Keeper_alerting_path.process_status_to_json status |> Yojson.Safe.to_string)
       output
   | Error msg -> Alcotest.failf "unexpected error: %s" msg);
  Alcotest.(check (list int)) "status ok exits" [ 0; 1 ] !(Calls.ok_exit_codes);
  Alcotest.(check (result string string))
    "run command"
    (Ok "mock stdout")
    (Runner.run_command
       ~ok_exit_codes:[ 0 ]
       ~config
       ~meta
       ~command_argv:[ "cat"; "/container/file" ]
       ~max_bytes:64
       ~timeout_sec:1.0
       ());
  Alcotest.(check (list string))
    "events"
    [ "run_status:rg,needle,/container/repo:512:3.0"
    ; "run:cat,/container/file:64:1.0"
    ]
    (Calls.events ())

let () =
  Alcotest.run
    "keeper_sandbox_read_runner"
    [ ( "mock-backend"
      , [ Alcotest.test_case
            "route labels come from sandbox runner"
            `Quick
            test_route_labels_match_sandbox_runner
        ; Alcotest.test_case
            "read operations delegate to backend"
            `Quick
            test_mock_backend_forwards_read_contract
        ; Alcotest.test_case
            "command operations delegate to backend"
            `Quick
            test_mock_backend_forwards_command_contract
        ] )
    ]
