open Alcotest

module Gate = Masc_mcp.Tool_resource_gate

let cls name =
  Gate.For_testing.resource_class_to_string name
;;

let classify ?(is_read_only = false) ?(args = `Assoc []) tool_name =
  Gate.For_testing.classify ~tool_name ~arguments:args ~is_read_only |> cls
;;

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some prior -> Unix.putenv name prior
      | None -> Unix.putenv name "")
    f
;;

let test_classifies_host_local_bottlenecks () =
  check
    string
    "Execute local argv"
    "shell"
    (classify
       "Execute"
       ~args:
         (`Assoc
           [ "executable", `String "scripts/dune-local.sh"
           ; "argv", `List [ `String "build"; `String "@check" ]
           ]));
  check
    string
    "Execute docker argv"
    "docker"
    (classify
       "Execute"
       ~args:
         (`Assoc
           [ "executable", `String "docker"; "argv", `List [ `String "ps" ] ]));
  check
    string
    "Execute gh argv"
    "github"
    (classify
       "Execute"
       ~args:
         (`Assoc
           [ "executable", `String "gh"
           ; "argv", `List [ `String "pr"; `String "checks"; `String "--watch" ]
           ]));
  check
    string
    "SearchFiles public alias"
    "filesystem_read"
    (classify
       "SearchFiles"
       ~is_read_only:true
       ~args:(`Assoc [ "pattern", `String "Tool_resource_gate" ]));
  check
    string
    "Read public alias"
    "filesystem_read"
    (classify
       "ReadFile"
       ~is_read_only:true
       ~args:(`Assoc [ "file_path", `String "lib/tool_resource_gate.ml" ]));
  check
    string
    "Write public alias"
    "filesystem_write"
    (classify
       "WriteFile"
       ~args:(`Assoc [ "file_path", `String "x"; "content", `String "y" ]));
  check
    string
    "SearchWeb public alias"
    "web"
    (classify "SearchWeb" ~args:(`Assoc [ "query", `String "masc" ]));
  check
    string
    "tool_search_files legacy git_clone defaults visibly to shell"
    "shell"
    (classify
       "tool_search_files"
       ~is_read_only:true
       ~args:(`Assoc [ "op", `String "git_clone" ]));
  check
    string
    "tool_search_files unknown op defaults visibly to shell"
    "shell"
    (classify
       "tool_search_files"
       ~is_read_only:true
       ~args:(`Assoc [ "op", `String "future_op" ]));
  check string "board write" "board_write" (classify "masc_board_post");
  check string "transition" "coordination_write" (classify "masc_transition");
  check string "worker shell_exec" "shell" (classify "shell_exec");
  check
    string
    "unknown docker-looking tool does not pick docker by substring"
    "generic_write"
    (classify "future_docker_helper");
  check
    string
    "unknown read-only fs-looking tool stays ungated"
    "ungated"
    (classify ~is_read_only:true "future_fs_reader");
  check string "status stays ungated" "ungated" (classify ~is_read_only:true "masc_status")
;;

let test_gate_rejects_when_lane_is_saturated () =
  Eio_main.run (fun env ->
    Gate.For_testing.set_limits ~shell:1 ();
    with_env "MASC_TOOL_GATE_WAIT_TIMEOUT_SEC" "0.05" (fun () ->
      let clock = Eio.Stdenv.clock env in
      let blocker_started, unblock_blocker = Eio.Promise.create () in
      let release_blocker, resolve_release = Eio.Promise.create () in
      Eio.Fiber.both
        (fun () ->
           let result =
             Gate.with_permit
               ~clock
               ~tool_name:"tool_execute"
               ~arguments:(`Assoc [ "cmd", `String "sleep 1" ])
               ~is_read_only:false
               ~start_time:(Eio.Time.now clock)
               (fun () ->
                  Eio.Promise.resolve unblock_blocker ();
                  Eio.Promise.await release_blocker;
                  Tool_result.quick_ok ~tool_name:"tool_execute" "done")
           in
           check bool "blocker succeeded" true (Tool_result.is_success result))
        (fun () ->
           Eio.Promise.await blocker_started;
           let result =
             Gate.with_permit
               ~clock
               ~tool_name:"tool_execute"
               ~arguments:(`Assoc [ "cmd", `String "echo queued" ])
               ~is_read_only:false
               ~start_time:(Eio.Time.now clock)
               (fun () -> Tool_result.quick_ok ~tool_name:"tool_execute" "ran")
           in
           Eio.Promise.resolve resolve_release ();
           check bool "second call rejected while saturated" false (Tool_result.is_success result);
           check
             (option string)
             "transient backpressure"
             (Some "transient_error")
             (Option.map
                Tool_result.tool_failure_class_to_string
                (Tool_result.failure_class result)))))
;;

let test_snapshot_exposes_gate_state () =
  Gate.For_testing.set_limits ~shell:3 ~docker:2 ();
  match Gate.snapshot_json () with
  | `Assoc fields ->
    check bool "enabled field" true (List.mem_assoc "enabled" fields);
    check bool "gates field" true (List.mem_assoc "gates" fields)
  | _ -> fail "expected snapshot object"
;;

let atomic_inc a =
  let rec loop () =
    let current = Atomic.get a in
    if Atomic.compare_and_set a current (current + 1)
    then current + 1
    else loop ()
  in
  loop ()
;;

let atomic_dec a =
  let rec loop () =
    let current = Atomic.get a in
    if Atomic.compare_and_set a current (current - 1)
    then current - 1
    else loop ()
  in
  loop ()
;;

let atomic_max a value =
  let rec loop () =
    let current = Atomic.get a in
    if value <= current || Atomic.compare_and_set a current value then () else loop ()
  in
  loop ()
;;

let test_24_tool_search_files_burst_stays_bounded () =
  Eio_main.run (fun env ->
    Fun.protect
      ~finally:Gate.For_testing.reset
      (fun () ->
         Gate.For_testing.set_limits ~shell:4 ();
         with_env "MASC_TOOL_GATE_WAIT_TIMEOUT_SEC" "2.0" (fun () ->
           let clock = Eio.Stdenv.clock env in
           let successes = Atomic.make 0 in
           let inflight = Atomic.make 0 in
           let max_inflight = Atomic.make 0 in
           Eio.Switch.run (fun sw ->
             for i = 1 to 24 do
               Eio.Fiber.fork ~sw (fun () ->
                 let result =
                   Gate.with_permit
                     ~clock
                     ~tool_name:"tool_execute"
                     ~arguments:(`Assoc [ "cmd", `String (Printf.sprintf "echo k%d" i) ])
                     ~is_read_only:false
                     ~start_time:(Eio.Time.now clock)
                     (fun () ->
                        let now = atomic_inc inflight in
                        atomic_max max_inflight now;
                        Eio.Time.sleep clock 0.02;
                        ignore (atomic_dec inflight : int);
                        Tool_result.quick_ok ~tool_name:"tool_execute" "done")
                 in
                 if (Tool_result.is_success result) then ignore (atomic_inc successes : int))
             done);
           check int "all 24 calls completed" 24 (Atomic.get successes);
           check bool "shell lane stayed bounded" true (Atomic.get max_inflight <= 4);
           check int "no permit leaked" 0 (Atomic.get inflight))))
;;

type lane_tracker =
  { lane : string
  ; limit : int
  ; inflight : int Atomic.t
  ; max_inflight : int Atomic.t
  }

let lane_tracker lane limit =
  { lane; limit; inflight = Atomic.make 0; max_inflight = Atomic.make 0 }
;;

let rec add_cases count case acc =
  if count <= 0 then acc else add_cases (count - 1) case (case :: acc)
;;

let test_mixed_24_keeper_burst_stays_bounded () =
  Eio_main.run (fun env ->
    Fun.protect
      ~finally:Gate.For_testing.reset
      (fun () ->
         Gate.For_testing.set_limits
           ~shell:2
           ~github:2
           ~docker:1
           ~filesystem_write:3
           ~board_write:2
           ~coordination_write:2
           ();
         with_env "MASC_TOOL_GATE_WAIT_TIMEOUT_SEC" "3.0" (fun () ->
           let clock = Eio.Stdenv.clock env in
           let shell = lane_tracker "shell" 2 in
           let github = lane_tracker "github" 2 in
           let docker = lane_tracker "docker" 1 in
           let fs_write = lane_tracker "filesystem_write" 3 in
           let board = lane_tracker "board_write" 2 in
           let coord = lane_tracker "coordination_write" 2 in
           let cases =
             []
             |> add_cases 4
                  ( shell
                  , "tool_execute"
                  , `Assoc [ "executable", `String "echo"; "argv", `List [ `String "shell" ] ] )
             |> add_cases 4
                  ( github
                  , "tool_execute"
                  , `Assoc
                      [ "executable", `String "gh"
                      ; "argv", `List [ `String "pr"; `String "list" ]
                      ] )
             |> add_cases 4
                  ( docker
                  , "tool_execute"
                  , `Assoc
                      [ "executable", `String "docker"
                      ; "argv", `List [ `String "ps" ]
                      ] )
             |> add_cases 4
                  ( fs_write
                  , "tool_write_file"
                  , `Assoc [ "path", `String "x"; "content", `String "y" ] )
             |> add_cases 4 (board, "masc_board_post", `Assoc [])
             |> add_cases 4 (coord, "masc_transition", `Assoc [])
           in
           let successes = Atomic.make 0 in
           Eio.Switch.run (fun sw ->
             List.iter
               (fun (tracker, tool_name, arguments) ->
                  Eio.Fiber.fork ~sw (fun () ->
                    let result =
                      Gate.with_permit
                        ~clock
                        ~tool_name
                        ~arguments
                        ~is_read_only:false
                        ~start_time:(Eio.Time.now clock)
                        (fun () ->
                           let now = atomic_inc tracker.inflight in
                           atomic_max tracker.max_inflight now;
                           Eio.Time.sleep clock 0.02;
                           ignore (atomic_dec tracker.inflight : int);
                           Tool_result.quick_ok ~tool_name "done")
                    in
                    if (Tool_result.is_success result) then ignore (atomic_inc successes : int)))
               cases);
           check int "all mixed 24 calls completed" 24 (Atomic.get successes);
           List.iter
             (fun tracker ->
                check
                  bool
                  (tracker.lane ^ " lane stayed bounded")
                  true
                  (Atomic.get tracker.max_inflight <= tracker.limit);
                check int (tracker.lane ^ " permit released") 0
                  (Atomic.get tracker.inflight))
             [ shell; github; docker; fs_write; board; coord ])))
;;

let () =
  run
    "Tool_resource_gate"
    [ ( "classification"
      , [ test_case "classifies host-local bottlenecks" `Quick
            test_classifies_host_local_bottlenecks
        ] )
    ; ( "admission"
      , [ test_case "rejects saturated shell lane" `Quick
            test_gate_rejects_when_lane_is_saturated
        ; test_case "snapshot exposes gate state" `Quick test_snapshot_exposes_gate_state
        ; test_case "24 keeper shell burst stays bounded" `Quick
            test_24_tool_search_files_burst_stays_bounded
        ; test_case "mixed 24 keeper burst stays bounded" `Quick
            test_mixed_24_keeper_burst_stays_bounded
        ] )
    ]
;;
