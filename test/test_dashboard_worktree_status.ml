open Alcotest

module Worktree_status = Masc_mcp.Dashboard_worktree_status
module Gate = Masc_mcp.Tool_resource_gate

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

let with_query_runner run f =
  Worktree_status.For_testing.set_query_pr_runner run;
  Fun.protect
    ~finally:Worktree_status.For_testing.clear_query_pr_runner
    f
;;

let test_query_pr_for_branch_parses_runner_output () =
  let invoked = Atomic.make false in
  with_query_runner
    (fun argv ->
       Atomic.set invoked true;
       check
         (list string)
         "argv"
         [ "gh"
         ; "pr"
         ; "list"
         ; "--head"
         ; "feature/gate"
         ; "--json"
         ; "number,state"
         ; "--limit"
         ; "1"
         ]
         argv;
       {|[{"number":42,"state":"OPEN"}]|})
    (fun () ->
       let pr_number, pr_state =
         Worktree_status.For_testing.query_pr_for_branch "feature/gate"
       in
       check (option int) "pr number" (Some 42) pr_number;
       check (option string) "pr state" (Some "open") pr_state;
       check bool "runner invoked" true (Atomic.get invoked))
;;

let test_query_pr_for_branch_respects_github_gate () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    Fun.protect
      ~finally:Gate.For_testing.reset
      (fun () ->
         Gate.For_testing.set_limits ~github:1 ();
         with_env "MASC_TOOL_GATE_WAIT_TIMEOUT_SEC" "0.01" (fun () ->
           let invoked = Atomic.make false in
           with_query_runner
             (fun _argv ->
                Atomic.set invoked true;
                {|[{"number":99,"state":"OPEN"}]|})
             (fun () ->
                Gate.with_permit_raw
                  ~clock
                  ~tool_name:"keeper_pr_list"
                  ~arguments:(`Assoc [])
                  ~is_read_only:false
                  ~on_reject:(fun message ->
                    failf "unexpected outer github gate rejection: %s" message)
                  (fun () ->
                     let pr_number, pr_state =
                       Worktree_status.For_testing.query_pr_for_branch
                         ~clock
                         "feature/saturated"
                     in
                     check (option int) "pr number omitted" None pr_number;
                     check (option string) "pr state omitted" None pr_state;
                     check bool "runner not invoked" false (Atomic.get invoked))))))
;;

let () =
  run
    "Dashboard_worktree_status"
    [ ( "github_gate"
      , [ test_case
            "query_pr_for_branch parses runner output"
            `Quick
            test_query_pr_for_branch_parses_runner_output
        ; test_case
            "query_pr_for_branch respects saturated github gate"
            `Quick
            test_query_pr_for_branch_respects_github_gate
        ] )
    ]
;;
