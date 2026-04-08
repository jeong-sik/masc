(** Unit tests for Eval_gate module — Pre/Post execution gates. *)

open Masc_mcp

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let with_tmpdir f =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_eval_gate_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with _ -> ());
  Fun.protect ~finally:(fun () ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))
  ) (fun () -> f dir)

let make_acc dir =
  Trajectory.create_accumulator
    ~masc_root:dir ~keeper_name:"test-keeper"
    ~trace_id:"gate-test" ~generation:0

let default_config = Eval_gate.default_config

(* Ensure destructive set is populated for tests that use
   Tool_dispatch.is_destructive (populated by mcp_server_eio.ml in production). *)
let () = Tool_dispatch.init_destructive_set ["keeper_bash"; "keeper_fs_edit"]

(* ================================================================ *)
(* Test: detect_destructive                                          *)
(* ================================================================ *)

let test_detect_rm_rf () =
  match Eval_gate.detect_destructive "rm -rf /tmp/test" with
  | Some (_pat, desc) ->
      Alcotest.(check string) "rm -rf desc" "recursive forced deletion" desc
  | None -> Alcotest.fail "Should detect rm -rf"

let test_detect_force_push () =
  match Eval_gate.detect_destructive "git push --force origin main" with
  | Some (_pat, desc) ->
      Alcotest.(check string) "force push desc" "force push" desc
  | None -> Alcotest.fail "Should detect force push"

let test_detect_safe_command () =
  match Eval_gate.detect_destructive "ls -la /tmp" with
  | Some _ -> Alcotest.fail "ls should be safe"
  | None -> ()

let test_detect_drop_table () =
  match Eval_gate.detect_destructive "psql -c 'DROP TABLE users'" with
  | Some (_pat, desc) ->
      Alcotest.(check string) "drop table desc" "SQL table drop" desc
  | None -> Alcotest.fail "Should detect DROP TABLE"

let test_detect_case_insensitive () =
  match Eval_gate.detect_destructive "RM -RF /data" with
  | Some _ -> ()
  | None -> Alcotest.fail "Should detect RM -RF (case insensitive)"

(* ================================================================ *)
(* Test: pre_check — deny list                                       *)
(* ================================================================ *)

let test_pre_deny_list () =
  let config = { default_config with denied_tools = ["evil_tool"] } in
  let decision = Eval_gate.pre_check
    ~config ~accumulated_cost:0.0 ~trajectory_acc:None
    ~tool_name:"evil_tool" ~args_json:"{}" in
  match decision with
  | Trajectory.Reject reason ->
      Alcotest.(check bool) "deny list reason" true
        (String.length reason > 0 &&
         let r = String.lowercase_ascii reason in
         (try ignore (Str.search_forward (Str.regexp_string "deny") r 0); true
          with Not_found -> false))
  | Trajectory.Pass -> Alcotest.fail "Should reject denied tool"

(* ================================================================ *)
(* Test: pre_check — allowlist                                       *)
(* ================================================================ *)

let test_pre_allowlist_reject () =
  let config = { default_config with
    allowlist_enabled = true;
    allowed_tools = ["keeper_bash"; "keeper_fs_read"];
  } in
  let decision = Eval_gate.pre_check
    ~config ~accumulated_cost:0.0 ~trajectory_acc:None
    ~tool_name:"keeper_dangerous" ~args_json:"{}" in
  match decision with
  | Trajectory.Reject _ -> ()
  | Trajectory.Pass -> Alcotest.fail "Should reject tool not in allowlist"

let test_pre_allowlist_pass () =
  let config = { default_config with
    allowlist_enabled = true;
    allowed_tools = ["keeper_bash"; "keeper_fs_read"];
  } in
  let decision = Eval_gate.pre_check
    ~config ~accumulated_cost:0.0 ~trajectory_acc:None
    ~tool_name:"keeper_bash" ~args_json:"{}" in
  match decision with
  | Trajectory.Pass -> ()
  | Trajectory.Reject r -> Alcotest.fail (Printf.sprintf "Should pass: %s" r)

(* ================================================================ *)
(* Test: pre_check — cost budget                                     *)
(* ================================================================ *)

let test_pre_cost_exceeded () =
  let decision = Eval_gate.pre_check
    ~config:default_config ~accumulated_cost:0.60 ~trajectory_acc:None
    ~tool_name:"keeper_bash" ~args_json:"{\"command\": \"echo hi\"}" in
  match decision with
  | Trajectory.Reject reason ->
      Alcotest.(check bool) "cost exceeded reason" true
        (let r = String.lowercase_ascii reason in
         try ignore (Str.search_forward (Str.regexp_string "cost") r 0); true
         with Not_found -> false)
  | Trajectory.Pass -> Alcotest.fail "Should reject when cost exceeded"

let test_pre_cost_within_budget () =
  let decision = Eval_gate.pre_check
    ~config:default_config ~accumulated_cost:0.10 ~trajectory_acc:None
    ~tool_name:"keeper_bash" ~args_json:"{\"command\": \"echo hi\"}" in
  match decision with
  | Trajectory.Pass -> ()
  | Trajectory.Reject r -> Alcotest.fail (Printf.sprintf "Should pass: %s" r)

(* ================================================================ *)
(* Test: pre_check — destructive bash detection                      *)
(* ================================================================ *)

let test_pre_destructive_bash () =
  let decision = Eval_gate.pre_check
    ~config:default_config ~accumulated_cost:0.0 ~trajectory_acc:None
    ~tool_name:"keeper_bash"
    ~args_json:"{\"command\": \"rm -rf /tmp/dangerous\"}" in
  match decision with
  | Trajectory.Reject reason ->
      Alcotest.(check bool) "destructive reason" true
        (let r = String.lowercase_ascii reason in
         try ignore (Str.search_forward (Str.regexp_string "destructive") r 0); true
         with Not_found -> false)
  | Trajectory.Pass -> Alcotest.fail "Should reject destructive bash"

let test_pre_safe_bash () =
  let decision = Eval_gate.pre_check
    ~config:default_config ~accumulated_cost:0.0 ~trajectory_acc:None
    ~tool_name:"keeper_bash"
    ~args_json:"{\"command\": \"ls -la\"}" in
  match decision with
  | Trajectory.Pass -> ()
  | Trajectory.Reject r -> Alcotest.fail (Printf.sprintf "Should pass: %s" r)

(* ================================================================ *)
(* Test: pre_check — entropy detection with accumulator              *)
(* ================================================================ *)

let test_pre_entropy () =
  with_tmpdir (fun dir ->
    let acc = make_acc dir in
    Trajectory.increment_turn acc;
    let repeated_args = "{\"command\": \"echo hi\"}" in
    let mk tool args = { Trajectory.
      ts = 1000.0; ts_iso = ""; turn = acc.Trajectory.turn; round = 0;
      tool_name = tool; args_json = args;
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 10;
      error = None; cost_usd = 0.0001;
    } in
    (* Add 3 consecutive same-tool calls with same args *)
    Trajectory.record_entry acc (mk "keeper_bash" repeated_args);
    Trajectory.record_entry acc (mk "keeper_bash" repeated_args);
    Trajectory.record_entry acc (mk "keeper_bash" repeated_args);
    let decision = Eval_gate.pre_check
      ~config:default_config ~accumulated_cost:0.0
      ~trajectory_acc:(Some acc)
      ~tool_name:"keeper_bash"
      ~args_json:repeated_args in
    match decision with
    | Trajectory.Reject reason ->
        Alcotest.(check bool) "entropy reason" true
          (let r = String.lowercase_ascii reason in
           try ignore (Str.search_forward (Str.regexp_string "entropy") r 0); true
           with Not_found -> false)
    | Trajectory.Pass -> Alcotest.fail "Should reject due to entropy")

(* ================================================================ *)
(* Test: pre_check — entropy does NOT trigger with different args    *)
(* ================================================================ *)

let test_pre_entropy_different_args () =
  with_tmpdir (fun dir ->
    let acc = make_acc dir in
    Trajectory.increment_turn acc;
    let mk tool args = { Trajectory.
      ts = 1000.0; ts_iso = ""; turn = acc.Trajectory.turn; round = 0;
      tool_name = tool; args_json = args;
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 10;
      error = None; cost_usd = 0.0001;
    } in
    (* Add 3 consecutive same-tool calls but with different args *)
    Trajectory.record_entry acc (mk "keeper_bash" "{\"command\": \"echo a\"}");
    Trajectory.record_entry acc (mk "keeper_bash" "{\"command\": \"echo b\"}");
    Trajectory.record_entry acc (mk "keeper_bash" "{\"command\": \"echo c\"}");
    let decision = Eval_gate.pre_check
      ~config:default_config ~accumulated_cost:0.0
      ~trajectory_acc:(Some acc)
      ~tool_name:"keeper_bash"
      ~args_json:"{\"command\": \"echo d\"}" in
    match decision with
    | Trajectory.Reject _ -> Alcotest.fail "Should NOT reject: different args do not form an entropy streak"
    | Trajectory.Pass -> ())

(* ================================================================ *)
(* Test: pre_check — turn call limit                                 *)
(* ================================================================ *)

let test_pre_turn_limit () =
  with_tmpdir (fun dir ->
    let acc = make_acc dir in
    let config = { default_config with max_tool_calls_per_turn = 2 } in
    Trajectory.increment_turn acc;
    (* Add different tools to avoid entropy, but reach turn limit *)
    let mk tool = { Trajectory.
      ts = 1000.0; ts_iso = ""; turn = acc.Trajectory.turn; round = 0;
      tool_name = tool; args_json = "{}";
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 10;
      error = None; cost_usd = 0.0001;
    } in
    Trajectory.record_entry acc (mk "keeper_bash");
    Trajectory.record_entry acc (mk "keeper_fs_read");
    let decision = Eval_gate.pre_check
      ~config ~accumulated_cost:0.0
      ~trajectory_acc:(Some acc)
      ~tool_name:"keeper_status"
      ~args_json:"{}" in
    match decision with
    | Trajectory.Reject reason ->
        Alcotest.(check bool) "turn limit reason" true
          (let r = String.lowercase_ascii reason in
           try ignore (Str.search_forward (Str.regexp_string "turn") r 0); true
           with Not_found -> false)
    | Trajectory.Pass -> Alcotest.fail "Should reject due to turn limit")

(* ================================================================ *)
(* Test: post_eval                                                   *)
(* ================================================================ *)

let test_post_eval_normal () =
  let result = Eval_gate.post_eval
    ~config:default_config ~tool_name:"keeper_bash"
    ~result:"{\"output\": \"hello\"}"
    ~duration_ms:100 ~accumulated_cost:0.01 in
  Alcotest.(check bool) "no error" false result.Eval_gate.has_error;
  Alcotest.(check bool) "no warning" false result.Eval_gate.should_warn

let test_post_eval_error () =
  let result = Eval_gate.post_eval
    ~config:default_config ~tool_name:"keeper_bash"
    ~result:"{\"error\": \"command not found\"}"
    ~duration_ms:100 ~accumulated_cost:0.01 in
  Alcotest.(check bool) "has error" true result.Eval_gate.has_error;
  Alcotest.(check bool) "error message present" true
    (result.Eval_gate.error_message <> None)

let test_post_eval_cost_warning () =
  let result = Eval_gate.post_eval
    ~config:default_config ~tool_name:"keeper_bash"
    ~result:"{\"output\": \"ok\"}"
    ~duration_ms:100 ~accumulated_cost:0.42 in
  Alcotest.(check bool) "should warn" true result.Eval_gate.should_warn

let test_post_eval_slow () =
  let result = Eval_gate.post_eval
    ~config:default_config ~tool_name:"keeper_bash"
    ~result:"{\"output\": \"ok\"}"
    ~duration_ms:35000 ~accumulated_cost:0.01 in
  Alcotest.(check bool) "should warn (slow)" true result.Eval_gate.should_warn;
  match result.Eval_gate.warning with
  | Some w ->
      Alcotest.(check bool) "slow warning" true
        (let r = String.lowercase_ascii w in
         try ignore (Str.search_forward (Str.regexp_string "slow") r 0); true
         with Not_found -> false)
  | None -> Alcotest.fail "Should have slow warning"

(* ================================================================ *)
(* Test: guarded_execute                                             *)
(* ================================================================ *)

let test_guarded_execute_pass () =
  let (decision, result_opt, eval_opt, duration_ms) =
    Eval_gate.guarded_execute
      ~config:default_config ~accumulated_cost:0.0
      ~trajectory_acc:None
      ~tool_name:"keeper_bash"
      ~args_json:"{\"command\": \"echo hello\"}"
      ~execute:(fun () -> "{\"output\": \"hello\"}")
  in
  Alcotest.(check bool) "pass" true (decision = Trajectory.Pass);
  Alcotest.(check bool) "has result" true (result_opt <> None);
  Alcotest.(check bool) "has eval" true (eval_opt <> None);
  Alcotest.(check bool) "positive duration" true (duration_ms >= 0)

let test_guarded_execute_reject () =
  let executed = ref false in
  let (decision, result_opt, _eval_opt, _duration_ms) =
    Eval_gate.guarded_execute
      ~config:default_config ~accumulated_cost:0.0
      ~trajectory_acc:None
      ~tool_name:"keeper_bash"
      ~args_json:"{\"command\": \"rm -rf /\"}"
      ~execute:(fun () -> executed := true; "should not reach here")
  in
  Alcotest.(check bool) "rejected" true
    (match decision with Trajectory.Reject _ -> true | _ -> false);
  Alcotest.(check bool) "no result" true (result_opt = None);
  Alcotest.(check bool) "not executed" false !executed

let test_guarded_execute_exception () =
  let (decision, result_opt, eval_opt, _duration_ms) =
    Eval_gate.guarded_execute
      ~config:default_config ~accumulated_cost:0.0
      ~trajectory_acc:None
      ~tool_name:"keeper_status"
      ~args_json:"{}"
      ~execute:(fun () -> failwith "simulated failure")
  in
  Alcotest.(check bool) "pass (gate ok)" true (decision = Trajectory.Pass);
  match result_opt with
  | Some result ->
      Alcotest.(check bool) "error in result" true
        (let r = String.lowercase_ascii result in
         try ignore (Str.search_forward (Str.regexp_string "tool execution failed") r 0); true
         with Not_found -> false);
      Alcotest.(check bool) "has eval" true (eval_opt <> None)
  | None -> Alcotest.fail "Should have result (from exception handler)"

(* ================================================================ *)
(* Test: JSON serialization                                          *)
(* ================================================================ *)

let test_gate_config_to_json () =
  let json = Eval_gate.gate_config_to_json default_config in
  let open Yojson.Safe.Util in
  let max_cost = json |> member "max_cost_usd" |> to_float in
  Alcotest.(check (float 0.01)) "max_cost" 0.50 max_cost;
  let entropy = json |> member "entropy_threshold" |> to_int in
  Alcotest.(check int) "entropy threshold" 3 entropy

let test_post_eval_to_json () =
  let eval : Eval_gate.post_eval_result = {
    has_error = true;
    error_message = Some "test error";
    cost_usd = 0.001;
    should_warn = false;
    warning = None;
  } in
  let json = Eval_gate.post_eval_to_json eval in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "has_error json" true (json |> member "has_error" |> to_bool);
  Alcotest.(check string) "error msg json" "test error"
    (json |> member "error_message" |> to_string)

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Alcotest.run "Eval_gate" [
    ("destructive_detection", [
      Alcotest.test_case "detect rm -rf" `Quick test_detect_rm_rf;
      Alcotest.test_case "detect force push" `Quick test_detect_force_push;
      Alcotest.test_case "safe command" `Quick test_detect_safe_command;
      Alcotest.test_case "detect drop table" `Quick test_detect_drop_table;
      Alcotest.test_case "case insensitive" `Quick test_detect_case_insensitive;
    ]);
    ("pre_check", [
      Alcotest.test_case "deny list" `Quick test_pre_deny_list;
      Alcotest.test_case "allowlist reject" `Quick test_pre_allowlist_reject;
      Alcotest.test_case "allowlist pass" `Quick test_pre_allowlist_pass;
      Alcotest.test_case "cost exceeded" `Quick test_pre_cost_exceeded;
      Alcotest.test_case "cost within budget" `Quick test_pre_cost_within_budget;
      Alcotest.test_case "destructive bash" `Quick test_pre_destructive_bash;
      Alcotest.test_case "safe bash" `Quick test_pre_safe_bash;
      Alcotest.test_case "entropy" `Quick test_pre_entropy;
      Alcotest.test_case "entropy different args" `Quick test_pre_entropy_different_args;
      Alcotest.test_case "turn limit" `Quick test_pre_turn_limit;
    ]);
    ("post_eval", [
      Alcotest.test_case "normal" `Quick test_post_eval_normal;
      Alcotest.test_case "error" `Quick test_post_eval_error;
      Alcotest.test_case "cost warning" `Quick test_post_eval_cost_warning;
      Alcotest.test_case "slow execution" `Quick test_post_eval_slow;
    ]);
    ("guarded_execute", [
      Alcotest.test_case "pass and execute" `Quick test_guarded_execute_pass;
      Alcotest.test_case "reject no execute" `Quick test_guarded_execute_reject;
      Alcotest.test_case "exception handling" `Quick test_guarded_execute_exception;
    ]);
    ("json", [
      Alcotest.test_case "gate_config_to_json" `Quick test_gate_config_to_json;
      Alcotest.test_case "post_eval_to_json" `Quick test_post_eval_to_json;
    ]);
  ]
