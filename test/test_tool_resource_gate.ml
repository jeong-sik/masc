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
    "plain keeper_bash"
    "shell"
    (classify
       "keeper_bash"
       ~args:(`Assoc [ "cmd", `String "dune build @check" ]));
  check
    string
    "keeper_bash docker"
    "docker"
    (classify
       "keeper_bash"
       ~args:(`Assoc [ "cmd", `String "docker ps" ]));
  check
    string
    "keeper_bash gh"
    "github"
    (classify
       "keeper_bash"
       ~args:(`Assoc [ "cmd", `String "gh pr checks --watch" ]));
  check
    string
    "keeper_shell rg"
    "filesystem_read"
    (classify
       "keeper_shell"
       ~is_read_only:true
       ~args:(`Assoc [ "op", `String "rg" ]));
  check
    string
    "keeper_shell git_clone"
    "github"
    (classify
       "keeper_shell"
       ~is_read_only:true
       ~args:(`Assoc [ "op", `String "git_clone" ]));
  check
    string
    "keeper_shell unknown op defaults visibly to shell"
    "shell"
    (classify
       "keeper_shell"
       ~is_read_only:true
       ~args:(`Assoc [ "op", `String "future_op" ]));
  check string "board write" "board_write" (classify "masc_board_post");
  check string "transition" "coordination_write" (classify "masc_transition");
  check
    string
    "dashboard worktree gh lookup"
    "github"
    (classify ~is_read_only:true "dashboard_worktree_status.gh_pr_list");
  check string "bash output bypasses gate" "ungated" (classify "keeper_bash_output");
  check string "bash kill bypasses gate" "ungated" (classify "keeper_bash_kill");
  check string "worker shell_exec" "shell" (classify "shell_exec");
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
               ~tool_name:"keeper_bash"
               ~arguments:(`Assoc [ "cmd", `String "sleep 1" ])
               ~is_read_only:false
               ~start_time:(Eio.Time.now clock)
               (fun () ->
                  Eio.Promise.resolve unblock_blocker ();
                  Eio.Promise.await release_blocker;
                  Tool_result.quick_ok ~tool_name:"keeper_bash" "done")
           in
           check bool "blocker succeeded" true result.success)
        (fun () ->
           Eio.Promise.await blocker_started;
           let result =
             Gate.with_permit
               ~clock
               ~tool_name:"keeper_bash"
               ~arguments:(`Assoc [ "cmd", `String "echo queued" ])
               ~is_read_only:false
               ~start_time:(Eio.Time.now clock)
               (fun () -> Tool_result.quick_ok ~tool_name:"keeper_bash" "ran")
           in
           Eio.Promise.resolve resolve_release ();
           check bool "second call rejected while saturated" false result.success;
           check
             (option string)
             "transient backpressure"
             (Some "transient_error")
             (Option.map
                Tool_result.tool_failure_class_to_string
                result.failure_class))))
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

let test_24_keeper_shell_burst_stays_bounded () =
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
                     ~tool_name:"keeper_bash"
                     ~arguments:(`Assoc [ "cmd", `String (Printf.sprintf "echo k%d" i) ])
                     ~is_read_only:false
                     ~start_time:(Eio.Time.now clock)
                     (fun () ->
                        let now = atomic_inc inflight in
                        atomic_max max_inflight now;
                        Eio.Time.sleep clock 0.02;
                        ignore (atomic_dec inflight : int);
                        Tool_result.quick_ok ~tool_name:"keeper_bash" "done")
                 in
                 if result.success then ignore (atomic_inc successes : int))
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
                  , "keeper_bash"
                  , `Assoc [ "cmd", `String "echo shell" ] )
             |> add_cases 4
                  ( github
                  , "keeper_bash"
                  , `Assoc [ "cmd", `String "gh pr list" ] )
             |> add_cases 4
                  ( docker
                  , "keeper_bash"
                  , `Assoc [ "cmd", `String "docker ps" ] )
             |> add_cases 4
                  ( fs_write
                  , "masc_code_write"
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
                    if result.success then ignore (atomic_inc successes : int)))
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

let test_remediation_tools_bypass_saturated_shell_lane () =
  Eio_main.run (fun env ->
    Fun.protect
      ~finally:Gate.For_testing.reset
      (fun () ->
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
                    ~tool_name:"keeper_bash"
                    ~arguments:(`Assoc [ "cmd", `String "sleep 1" ])
                    ~is_read_only:false
                    ~start_time:(Eio.Time.now clock)
                    (fun () ->
                       Eio.Promise.resolve unblock_blocker ();
                       Eio.Promise.await release_blocker;
                       Tool_result.quick_ok ~tool_name:"keeper_bash" "done")
                in
                check bool "blocking shell call completed" true result.success)
             (fun () ->
                Eio.Promise.await blocker_started;
                let output =
                  Gate.with_permit
                    ~clock
                    ~tool_name:"keeper_bash_output"
                    ~arguments:(`Assoc [ "task_id", `String "bgt-test" ])
                    ~is_read_only:false
                    ~start_time:(Eio.Time.now clock)
                    (fun () ->
                       Tool_result.quick_ok ~tool_name:"keeper_bash_output" "out")
                in
                let kill =
                  Gate.with_permit
                    ~clock
                    ~tool_name:"keeper_bash_kill"
                    ~arguments:(`Assoc [ "task_id", `String "bgt-test" ])
                    ~is_read_only:false
                    ~start_time:(Eio.Time.now clock)
                    (fun () ->
                       Tool_result.quick_ok ~tool_name:"keeper_bash_kill" "killed")
                in
                Eio.Promise.resolve resolve_release ();
                check bool "output bypassed saturated shell" true output.success;
                check bool "kill bypassed saturated shell" true kill.success))))
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
            test_24_keeper_shell_burst_stays_bounded
        ; test_case "mixed 24 keeper burst stays bounded" `Quick
            test_mixed_24_keeper_burst_stays_bounded
        ; test_case "remediation tools bypass saturated shell lane" `Quick
            test_remediation_tools_bypass_saturated_shell_lane
        ] )
    ]
;;
