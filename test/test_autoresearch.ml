(** Autoresearch Module Tests

    Tests for autonomous experiment loop types, serialization,
    state management, storage, and MCP tool dispatch. *)

open Alcotest
module AR = Masc_mcp.Autoresearch
module Tool = Masc_mcp.Tool_autoresearch

(* ============================================ *)
(* Helper: deterministic state for testing      *)
(* ============================================ *)

let make_state
    ?(loop_id = "ar-test0001")
    ?(goal = "Reduce latency")
    ?(metric_fn = "echo 42.0")
    ?(status = AR.Running)
    ?(current_cycle = 0)
    ?(baseline = 1.0)
    ?(best_score = 1.0)
    ?(best_cycle = 0)
    ?(history = [])
    ?(total_keeps = 0)
    ?(total_discards = 0)
    ?(cycle_timeout_s = 60.0)
    ?(max_cycles = 10)
    ?(workdir = "/tmp/autoresearch-test")
    () : AR.loop_state =
  let now = 1000000.0 in
  {
    loop_id;
    goal;
    metric_fn;
    status;
    error_message = None;
    current_cycle;
    baseline;
    best_score;
    best_cycle;
    history;
    total_keeps;
    total_discards;
    start_time = now;
    updated_at = now;
    cycle_timeout_s;
    max_cycles;
    workdir;
  }

(* ============================================ *)
(* Decision serialization                       *)
(* ============================================ *)

let test_decision_roundtrip () =
  check string "keep" "keep" (AR.decision_to_string AR.Keep);
  check string "discard" "discard" (AR.decision_to_string AR.Discard);
  let keep = AR.decision_of_string "keep" in
  check bool "roundtrip keep" true (keep = AR.Keep);
  let discard = AR.decision_of_string "discard" in
  check bool "roundtrip discard" true (discard = AR.Discard)

let test_decision_invalid () =
  let raised = ref false in
  (try ignore (AR.decision_of_string "unknown")
   with Invalid_argument _ -> raised := true);
  check bool "invalid decision raises" true !raised

(* ============================================ *)
(* Status serialization                         *)
(* ============================================ *)

let test_status_roundtrip () =
  let cases = [
    (AR.Running, "running");
    (AR.Completed, "completed");
    (AR.Stopped, "stopped");
    (AR.Error, "error");
  ] in
  List.iter (fun (status, expected) ->
    check string ("status_to_string " ^ expected) expected
      (AR.status_to_string status);
    check bool ("status_of_string " ^ expected) true
      (AR.status_of_string expected = Some status)
  ) cases;
  check (option reject) "unknown status" None (AR.status_of_string "bogus")

(* ============================================ *)
(* Cycle record JSON roundtrip                  *)
(* ============================================ *)

let make_cycle ?(cycle = 1) ?(hypothesis = "try X")
    ?(score_before = 1.0) ?(score_after = 1.5) () : AR.cycle_record =
  {
    cycle;
    hypothesis;
    score_before;
    score_after;
    delta = score_after -. score_before;
    decision = if score_after > score_before then AR.Keep else AR.Discard;
    commit_hash = Some "abc1234";
    elapsed_ms = 500;
    model_used = "test-model";
    timestamp = 1000000.0;
  }

let test_cycle_json_roundtrip () =
  let original = make_cycle () in
  let json = AR.cycle_to_yojson original in
  let parsed = AR.cycle_of_yojson json in
  check int "cycle" original.cycle parsed.cycle;
  check string "hypothesis" original.hypothesis parsed.hypothesis;
  check (float 0.001) "score_before" original.score_before parsed.score_before;
  check (float 0.001) "score_after" original.score_after parsed.score_after;
  check (float 0.001) "delta" original.delta parsed.delta;
  check string "decision" "keep" (AR.decision_to_string parsed.decision);
  check (option string) "commit_hash" (Some "abc1234") parsed.commit_hash;
  check int "elapsed_ms" 500 parsed.elapsed_ms;
  check string "model_used" "test-model" parsed.model_used

let test_cycle_json_discard () =
  let record = make_cycle ~score_before:2.0 ~score_after:1.0 () in
  let json = AR.cycle_to_yojson record in
  let parsed = AR.cycle_of_yojson json in
  check string "decision discard" "discard" (AR.decision_to_string parsed.decision)

let test_cycle_json_null_hash () =
  let record = { (make_cycle ()) with commit_hash = None } in
  let json = AR.cycle_to_yojson record in
  let parsed = AR.cycle_of_yojson json in
  check (option string) "null hash" None parsed.commit_hash

(* ============================================ *)
(* State serialization                          *)
(* ============================================ *)

let test_state_to_yojson () =
  let state = make_state () in
  let json = AR.state_to_yojson state in
  let open Yojson.Safe.Util in
  check string "loop_id" "ar-test0001" (json |> member "loop_id" |> to_string);
  check string "goal" "Reduce latency" (json |> member "goal" |> to_string);
  check string "status" "running" (json |> member "status" |> to_string);
  check int "current_cycle" 0 (json |> member "current_cycle" |> to_int);
  check (float 0.001) "baseline" 1.0 (json |> member "baseline" |> to_float);
  check int "max_cycles" 10 (json |> member "max_cycles" |> to_int)

let test_state_with_error () =
  let state = make_state ~status:AR.Error () in
  state.error_message <- Some "metric failed";
  let json = AR.state_to_yojson state in
  let open Yojson.Safe.Util in
  check string "error" "metric failed" (json |> member "error" |> to_string)

(* ============================================ *)
(* create_state                                 *)
(* ============================================ *)

let test_create_state () =
  Mirage_crypto_rng_unix.use_default ();
  let state = AR.create_state
    ~goal:"Optimize throughput"
    ~metric_fn:"echo 99.9"
    ~cycle_timeout_s:120.0
    ~max_cycles:50
    ~workdir:"/tmp/test" () in
  check bool "loop_id starts with ar-" true
    (String.length state.loop_id >= 3
     && String.sub state.loop_id 0 3 = "ar-");
  check string "goal" "Optimize throughput" state.goal;
  check string "metric_fn" "echo 99.9" state.metric_fn;
  check bool "status running" true (state.status = AR.Running);
  check int "current_cycle" 0 state.current_cycle;
  check (float 0.001) "baseline" 0.0 state.baseline;
  check int "max_cycles" 50 state.max_cycles;
  check (float 0.001) "cycle_timeout_s" 120.0 state.cycle_timeout_s

(* ============================================ *)
(* record_cycle — Keep vs Discard               *)
(* ============================================ *)

let test_record_cycle_keep () =
  let state = make_state ~baseline:1.0 ~best_score:1.0 () in
  let record = AR.record_cycle state
    ~hypothesis:"Try bigger batch"
    ~score_before:1.0
    ~score_after:1.5
    ~commit_hash:(Some "def5678")
    ~elapsed_ms:200
    ~model_used:"glm" in
  check bool "decision is Keep" true (record.decision = AR.Keep);
  check (float 0.001) "delta" 0.5 record.delta;
  check int "total_keeps" 1 state.total_keeps;
  check int "total_discards" 0 state.total_discards;
  check (float 0.001) "baseline updated" 1.5 state.baseline;
  check (float 0.001) "best_score updated" 1.5 state.best_score;
  check int "history length" 1 (List.length state.history)

let test_record_cycle_discard () =
  let state = make_state ~baseline:2.0 ~best_score:2.0 () in
  let record = AR.record_cycle state
    ~hypothesis:"Try smaller LR"
    ~score_before:2.0
    ~score_after:1.8
    ~commit_hash:None
    ~elapsed_ms:150
    ~model_used:"claude" in
  check bool "decision is Discard" true (record.decision = AR.Discard);
  check int "total_discards" 1 state.total_discards;
  check (float 0.001) "baseline unchanged" 2.0 state.baseline;
  check (float 0.001) "best_score unchanged" 2.0 state.best_score

let test_record_cycle_equal_score () =
  (* Equal score → Discard (strict improvement required) *)
  let state = make_state ~baseline:1.0 ~best_score:1.0 () in
  let record = AR.record_cycle state
    ~hypothesis:"No change"
    ~score_before:1.0
    ~score_after:1.0
    ~commit_hash:None
    ~elapsed_ms:100
    ~model_used:"test" in
  check bool "equal score is Discard" true (record.decision = AR.Discard)

let test_record_cycle_best_tracking () =
  let state = make_state ~baseline:1.0 ~best_score:1.0 () in
  (* Cycle 0: improve to 2.0 *)
  state.current_cycle <- 0;
  ignore (AR.record_cycle state
    ~hypothesis:"a" ~score_before:1.0 ~score_after:2.0
    ~commit_hash:None ~elapsed_ms:50 ~model_used:"m");
  check (float 0.001) "best after cycle 0" 2.0 state.best_score;
  check int "best_cycle after 0" 0 state.best_cycle;
  (* Cycle 1: improve to 3.0 *)
  state.current_cycle <- 1;
  ignore (AR.record_cycle state
    ~hypothesis:"b" ~score_before:2.0 ~score_after:3.0
    ~commit_hash:None ~elapsed_ms:50 ~model_used:"m");
  check (float 0.001) "best after cycle 1" 3.0 state.best_score;
  check int "best_cycle after 1" 1 state.best_cycle;
  (* Cycle 2: regress to 2.5 (discard, best unchanged) *)
  state.current_cycle <- 2;
  ignore (AR.record_cycle state
    ~hypothesis:"c" ~score_before:3.0 ~score_after:2.5
    ~commit_hash:None ~elapsed_ms:50 ~model_used:"m");
  check (float 0.001) "best unchanged after discard" 3.0 state.best_score;
  check int "best_cycle unchanged" 1 state.best_cycle

(* ============================================ *)
(* should_continue                              *)
(* ============================================ *)

let test_should_continue_running () =
  let state = make_state ~current_cycle:5 ~max_cycles:10 () in
  check bool "running under max" true (AR.should_continue state)

let test_should_continue_at_max () =
  let state = make_state ~current_cycle:10 ~max_cycles:10 () in
  check bool "at max cycles" false (AR.should_continue state)

let test_should_continue_stopped () =
  let state = make_state ~status:AR.Stopped ~current_cycle:5 ~max_cycles:10 () in
  check bool "stopped" false (AR.should_continue state)

(* ============================================ *)
(* summary                                      *)
(* ============================================ *)

let test_summary_includes_recent () =
  let state = make_state () in
  (* Add 3 cycles *)
  List.iter (fun i ->
    state.current_cycle <- i;
    ignore (AR.record_cycle state
      ~hypothesis:(Printf.sprintf "h%d" i)
      ~score_before:1.0
      ~score_after:(1.0 +. float_of_int i *. 0.1)
      ~commit_hash:None ~elapsed_ms:50 ~model_used:"m")
  ) [0; 1; 2];
  let json = AR.summary state in
  let open Yojson.Safe.Util in
  let recent = json |> member "recent_cycles" |> to_list in
  check int "recent_cycles count" 3 (List.length recent)

(* ============================================ *)
(* Storage paths                                *)
(* ============================================ *)

let test_results_dir () =
  let dir = AR.results_dir ~base_path:"/home/test" "ar-abc123" in
  check string "results_dir" "/home/test/.masc/autoresearch/ar-abc123" dir

let test_results_file () =
  let path = AR.results_file ~base_path:"/home/test" "ar-abc123" in
  check string "results_file"
    "/home/test/.masc/autoresearch/ar-abc123/results.jsonl" path

let test_state_file () =
  let path = AR.state_file ~base_path:"/home/test" "ar-abc123" in
  check string "state_file"
    "/home/test/.masc/autoresearch/ar-abc123/state.json" path

(* ============================================ *)
(* File I/O (temp directory)                    *)
(* ============================================ *)

let with_tmpdir f =
  let dir = Filename.temp_dir "autoresearch_test" "" in
  Fun.protect ~finally:(fun () ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))
  ) (fun () -> f dir)

let test_append_cycle_creates_file () =
  with_tmpdir (fun base_path ->
    let record = make_cycle () in
    AR.append_cycle ~base_path "ar-test" record;
    let path = AR.results_file ~base_path "ar-test" in
    check bool "file exists" true (Sys.file_exists path);
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    (* Verify it's valid JSON *)
    let json = Yojson.Safe.from_string line in
    let open Yojson.Safe.Util in
    check int "cycle in file" 1 (json |> member "cycle" |> to_int)
  )

let test_append_cycle_appends () =
  with_tmpdir (fun base_path ->
    let r1 = make_cycle ~cycle:1 ~hypothesis:"first" () in
    let r2 = make_cycle ~cycle:2 ~hypothesis:"second" () in
    AR.append_cycle ~base_path "ar-test" r1;
    AR.append_cycle ~base_path "ar-test" r2;
    let path = AR.results_file ~base_path "ar-test" in
    let ic = open_in path in
    let lines = ref [] in
    (try while true do lines := input_line ic :: !lines done
     with End_of_file -> ());
    close_in ic;
    check int "two lines" 2 (List.length !lines)
  )

let test_save_state_creates_file () =
  with_tmpdir (fun base_path ->
    let state = make_state ~loop_id:"ar-save-test" () in
    AR.save_state ~base_path state;
    let path = AR.state_file ~base_path "ar-save-test" in
    check bool "state file exists" true (Sys.file_exists path);
    let ic = open_in path in
    let buf = Buffer.create 256 in
    (try while true do Buffer.add_char buf (input_char ic) done
     with End_of_file -> ());
    close_in ic;
    let json = Yojson.Safe.from_string (Buffer.contents buf) in
    let open Yojson.Safe.Util in
    check string "saved loop_id" "ar-save-test"
      (json |> member "loop_id" |> to_string)
  )

(* ============================================ *)
(* Tool dispatch                                *)
(* ============================================ *)

let test_dispatch_unknown_returns_none () =
  let ctx : Tool.context = { base_path = "/tmp" } in
  let result = Tool.dispatch ctx ~name:"masc_unknown_tool" ~args:(`Assoc []) in
  check (option reject) "unknown tool" None result

let test_dispatch_start_missing_goal () =
  let ctx : Tool.context = { base_path = "/tmp" } in
  let args = `Assoc [("metric_fn", `String "echo 1.0")] in
  match Tool.dispatch ctx ~name:"masc_autoresearch_start" ~args with
  | Some (false, json_str) ->
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let error = json |> member "error" |> to_string in
    check bool "error mentions goal" true (String.length error > 0)
  | Some (true, _) -> fail "expected error for missing goal"
  | None -> fail "expected Some for start tool"

let test_dispatch_start_missing_metric () =
  let ctx : Tool.context = { base_path = "/tmp" } in
  let args = `Assoc [("goal", `String "optimize")] in
  match Tool.dispatch ctx ~name:"masc_autoresearch_start" ~args with
  | Some (false, json_str) ->
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let error = json |> member "error" |> to_string in
    check bool "error mentions metric" true (String.length error > 0)
  | Some (true, _) -> fail "expected error for missing metric_fn"
  | None -> fail "expected Some for start tool"

let test_dispatch_status_no_loop () =
  let ctx : Tool.context = { base_path = "/tmp" } in
  (* Clear global state *)
  Tool.latest_loop_id := None;
  Hashtbl.clear Tool.active_loops;
  match Tool.dispatch ctx ~name:"masc_autoresearch_status" ~args:(`Assoc []) with
  | Some (false, json_str) ->
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let error = json |> member "error" |> to_string in
    check bool "no loop error" true (String.length error > 0)
  | _ -> fail "expected error for no running loop"

let test_dispatch_inject_missing_hypothesis () =
  let ctx : Tool.context = { base_path = "/tmp" } in
  Tool.latest_loop_id := Some "ar-test";
  let state = make_state ~loop_id:"ar-test" () in
  Hashtbl.replace Tool.active_loops "ar-test" state;
  let args = `Assoc [] in
  match Tool.dispatch ctx ~name:"masc_autoresearch_inject" ~args with
  | Some (false, json_str) ->
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let error = json |> member "error" |> to_string in
    check bool "error for missing hypothesis" true (String.length error > 0)
  | _ -> fail "expected error for missing hypothesis"

let test_dispatch_inject_success () =
  let ctx : Tool.context = { base_path = "/tmp" } in
  let state = make_state ~loop_id:"ar-inject" () in
  Hashtbl.replace Tool.active_loops "ar-inject" state;
  Tool.latest_loop_id := Some "ar-inject";
  Hashtbl.clear Tool.pending_hypotheses;
  let args = `Assoc [("hypothesis", `String "try dropout=0.3")] in
  match Tool.dispatch ctx ~name:"masc_autoresearch_inject" ~args with
  | Some (true, json_str) ->
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    check string "status" "hypothesis_queued"
      (json |> member "status" |> to_string);
    check bool "pending stored" true
      (Hashtbl.mem Tool.pending_hypotheses "ar-inject")
  | Some (false, s) -> fail ("unexpected error: " ^ s)
  | None -> fail "expected Some for inject tool"

let test_dispatch_stop_success () =
  with_tmpdir (fun base_path ->
    let ctx : Tool.context = { base_path } in
    let state = make_state ~loop_id:"ar-stop-test" () in
    Hashtbl.replace Tool.active_loops "ar-stop-test" state;
    Tool.latest_loop_id := Some "ar-stop-test";
    let args = `Assoc [("reason", `String "done testing")] in
    match Tool.dispatch ctx ~name:"masc_autoresearch_stop" ~args with
    | Some (true, json_str) ->
      let json = Yojson.Safe.from_string json_str in
      let open Yojson.Safe.Util in
      check string "status" "stopped"
        (json |> member "status" |> to_string);
      check string "reason" "done testing"
        (json |> member "reason" |> to_string);
      check bool "state updated" true (state.status = AR.Stopped)
    | Some (false, s) -> fail ("unexpected error: " ^ s)
    | None -> fail "expected Some for stop tool"
  )

(* ============================================ *)
(* Schema validation                            *)
(* ============================================ *)

let test_schemas_count () =
  check int "4 tool schemas" 4 (List.length Tool.schemas)

let test_schemas_names () =
  let names = List.map (fun (s : Masc_mcp.Types.tool_schema) -> s.name) Tool.schemas in
  check bool "start" true (List.mem "masc_autoresearch_start" names);
  check bool "status" true (List.mem "masc_autoresearch_status" names);
  check bool "stop" true (List.mem "masc_autoresearch_stop" names);
  check bool "inject" true (List.mem "masc_autoresearch_inject" names)

(* ============================================ *)
(* Test runner                                  *)
(* ============================================ *)

let () =
  Mirage_crypto_rng_unix.use_default ();
  run "Autoresearch" [
    ("decision", [
      test_case "roundtrip" `Quick test_decision_roundtrip;
      test_case "invalid" `Quick test_decision_invalid;
    ]);
    ("status", [
      test_case "roundtrip" `Quick test_status_roundtrip;
    ]);
    ("cycle_json", [
      test_case "roundtrip" `Quick test_cycle_json_roundtrip;
      test_case "discard" `Quick test_cycle_json_discard;
      test_case "null hash" `Quick test_cycle_json_null_hash;
    ]);
    ("state_json", [
      test_case "to_yojson" `Quick test_state_to_yojson;
      test_case "with error" `Quick test_state_with_error;
    ]);
    ("create_state", [
      test_case "defaults" `Quick test_create_state;
    ]);
    ("record_cycle", [
      test_case "keep" `Quick test_record_cycle_keep;
      test_case "discard" `Quick test_record_cycle_discard;
      test_case "equal score" `Quick test_record_cycle_equal_score;
      test_case "best tracking" `Quick test_record_cycle_best_tracking;
    ]);
    ("should_continue", [
      test_case "running" `Quick test_should_continue_running;
      test_case "at max" `Quick test_should_continue_at_max;
      test_case "stopped" `Quick test_should_continue_stopped;
    ]);
    ("summary", [
      test_case "recent cycles" `Quick test_summary_includes_recent;
    ]);
    ("storage_paths", [
      test_case "results_dir" `Quick test_results_dir;
      test_case "results_file" `Quick test_results_file;
      test_case "state_file" `Quick test_state_file;
    ]);
    ("file_io", [
      test_case "append creates" `Quick test_append_cycle_creates_file;
      test_case "append appends" `Quick test_append_cycle_appends;
      test_case "save state" `Quick test_save_state_creates_file;
    ]);
    ("tool_dispatch", [
      test_case "unknown tool" `Quick test_dispatch_unknown_returns_none;
      test_case "start missing goal" `Quick test_dispatch_start_missing_goal;
      test_case "start missing metric" `Quick test_dispatch_start_missing_metric;
      test_case "status no loop" `Quick test_dispatch_status_no_loop;
      test_case "inject missing hypothesis" `Quick test_dispatch_inject_missing_hypothesis;
      test_case "inject success" `Quick test_dispatch_inject_success;
      test_case "stop success" `Quick test_dispatch_stop_success;
    ]);
    ("schemas", [
      test_case "count" `Quick test_schemas_count;
      test_case "names" `Quick test_schemas_names;
    ]);
  ]
