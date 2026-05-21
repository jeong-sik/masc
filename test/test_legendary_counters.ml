open Masc_mcp
module LC = Legendary_counters

let test_initial_zero () =
  LC.reset ();
  let s = LC.snapshot () in
  Alcotest.(check int)
    "shell_gate_worker_dev_tools_allow"
    0
    s.shell_gate_worker_dev_tools_allow
;;

let test_shell_gate_partition () =
  LC.reset ();
  LC.incr_shell_gate ~caller:LC.Worker_dev_tools ~verdict:LC.Allow;
  LC.incr_shell_gate ~caller:LC.Tool_code_write ~verdict:LC.Reject;
  LC.incr_shell_gate
    ~caller:LC.Keeper_shell_bash
    ~verdict:LC.Cannot_parse;
  let s = LC.snapshot () in
  Alcotest.(check int)
    "worker allow"
    1
    s.shell_gate_worker_dev_tools_allow;
  Alcotest.(check int)
    "tool_code_write reject"
    1
    s.shell_gate_tool_code_write_reject;
  Alcotest.(check int)
    "keeper cannot_parse"
    1
    s.shell_gate_keeper_shell_bash_cannot_parse
;;

let test_gh_exit_class_partition () =
  LC.reset ();
  LC.incr_gh_exit_class Gh_exit_class.Ok_0;
  LC.incr_gh_exit_class Gh_exit_class.Auth_failed;
  LC.incr_gh_exit_class Gh_exit_class.Auth_failed;
  let s = LC.snapshot () in
  Alcotest.(check int) "ok = 1" 1 s.gh_exit_ok_0;
  Alcotest.(check int) "auth_failed = 2" 2 s.gh_exit_auth_failed;
  Alcotest.(check int) "network = 0" 0 s.gh_exit_network
;;

let test_snapshot_json_shape () =
  LC.reset ();
  LC.incr_shell_gate ~caller:LC.Keeper_shell_bash ~verdict:LC.Reject;
  let json =
    LC.snapshot_to_json (LC.snapshot ())
  in
  let s = Yojson.Safe.to_string json in
  Alcotest.(check bool)
    "has shell_gate_keeper_shell_bash_reject"
    true
    (Astring.String.is_infix
       ~affix:"\"shell_gate_keeper_shell_bash_reject\":1"
       s)
;;

let test_reset () =
  LC.incr_gh_exit_class Gh_exit_class.Network;
  LC.reset ();
  let s = LC.snapshot () in
  Alcotest.(check int) "post-reset gh_network" 0 s.gh_exit_network
;;

let () =
  Alcotest.run
    "legendary_counters"
    [ ( "basic"
      , [ Alcotest.test_case "initial zero" `Quick test_initial_zero
        ; Alcotest.test_case "shell gate partition" `Quick test_shell_gate_partition
        ; Alcotest.test_case "gh exit class partition" `Quick test_gh_exit_class_partition
        ; Alcotest.test_case "snapshot JSON shape" `Quick test_snapshot_json_shape
        ; Alcotest.test_case "reset" `Quick test_reset
        ] )
    ]
;;
