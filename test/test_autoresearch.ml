(** Autoresearch Module Tests

    Tests for autonomous experiment loop types, serialization,
    state management, storage, MCP tool dispatch, insights,
    git helpers, retry, and LLM prompt construction. *)

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
    ?(llm_model = "glm")
    ?(target_file = "target.py")
    ?(status = AR.Running)
    ?(current_cycle = 0)
    ?(baseline = 1.0)
    ?(best_score = 1.0)
    ?(best_cycle = 0)
    ?(history = [])
    ?(total_keeps = 0)
    ?(total_discards = 0)
    ?(insights = [])
    ?(cycle_timeout_s = 60.0)
    ?(max_cycles = 10)
    ?(workdir = "/tmp/autoresearch-test")
    () : AR.loop_state =
  let now = 1000000.0 in
  {
    loop_id;
    goal;
    metric_fn;
    llm_model;
    target_file;
    status;
    error_message = None;
    current_cycle;
    baseline;
    best_score;
    best_cycle;
    history;
    total_keeps;
    total_discards;
    insights;
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
  check int "max_cycles" 10 (json |> member "max_cycles" |> to_int);
  check string "llm_model" "glm" (json |> member "llm_model" |> to_string);
  check string "target_file" "target.py" (json |> member "target_file" |> to_string);
  check int "insights_count" 0 (json |> member "insights_count" |> to_int)

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
    ~target_file:"model.py"
    ~cycle_timeout_s:120.0
    ~max_cycles:50
    ~workdir:"/tmp/test" () in
  check bool "loop_id starts with ar-" true
    (String.length state.loop_id >= 3
     && String.sub state.loop_id 0 3 = "ar-");
  check string "goal" "Optimize throughput" state.goal;
  check string "metric_fn" "echo 99.9" state.metric_fn;
  check string "llm_model default" "glm" state.llm_model;
  check string "target_file" "model.py" state.target_file;
  check bool "status running" true (state.status = AR.Running);
  check int "current_cycle" 0 state.current_cycle;
  check (float 0.001) "baseline" 0.0 state.baseline;
  check int "max_cycles" 50 state.max_cycles;
  check (float 0.001) "cycle_timeout_s" 120.0 state.cycle_timeout_s;
  check (list string) "insights empty" [] state.insights

let test_create_state_custom_llm () =
  Mirage_crypto_rng_unix.use_default ();
  let state = AR.create_state
    ~goal:"test" ~metric_fn:"echo 1.0" ~llm_model:"claude"
    ~target_file:"main.py"
    ~cycle_timeout_s:60.0 ~max_cycles:5 ~workdir:"/tmp/test" () in
  check string "custom llm_model" "claude" state.llm_model;
  check string "target_file" "main.py" state.target_file

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
  (* Equal score -> Discard (strict improvement required) *)
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
(* Insights — FIFO + message format             *)
(* ============================================ *)

let test_insights_keep_message () =
  let state = make_state ~baseline:1.0 ~best_score:1.0 () in
  state.current_cycle <- 3;
  ignore (AR.record_cycle state
    ~hypothesis:"batch_size=64"
    ~score_before:1.0 ~score_after:1.5
    ~commit_hash:None ~elapsed_ms:50 ~model_used:"m");
  check int "one insight" 1 (List.length state.insights);
  let msg = List.hd state.insights in
  check bool "contains cycle" true (Masc_mcp.Autoresearch.contains_substring msg "Cycle 3");
  check bool "contains improved" true (Masc_mcp.Autoresearch.contains_substring msg "improved")

let test_insights_discard_message () =
  let state = make_state ~baseline:2.0 ~best_score:2.0 () in
  state.current_cycle <- 5;
  ignore (AR.record_cycle state
    ~hypothesis:"lr=0.01"
    ~score_before:2.0 ~score_after:1.8
    ~commit_hash:None ~elapsed_ms:50 ~model_used:"m");
  let msg = List.hd state.insights in
  check bool "contains no improvement" true
    (Masc_mcp.Autoresearch.contains_substring msg "no improvement")

let test_insights_fifo_limit () =
  let state = make_state ~baseline:1.0 ~best_score:1.0 () in
  (* Add 12 cycles to generate 12 insights *)
  for i = 0 to 11 do
    state.current_cycle <- i;
    ignore (AR.record_cycle state
      ~hypothesis:(Printf.sprintf "h%d" i)
      ~score_before:(float_of_int i) ~score_after:(float_of_int (i + 1))
      ~commit_hash:None ~elapsed_ms:50 ~model_used:"m")
  done;
  check int "insights capped at 10" 10 (List.length state.insights)

(* ============================================ *)
(* add_insight direct test                      *)
(* ============================================ *)

let test_add_insight_basic () =
  let state = make_state () in
  AR.add_insight state "test insight 1";
  AR.add_insight state "test insight 2";
  check int "two insights" 2 (List.length state.insights);
  check string "most recent first" "test insight 2" (List.hd state.insights)

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
(* contains_substring                           *)
(* ============================================ *)

let test_contains_substring () =
  check bool "found" true (AR.contains_substring "hello world" "world");
  check bool "not found" false (AR.contains_substring "hello" "xyz");
  check bool "empty needle" true (AR.contains_substring "hello" "");
  check bool "needle too long" false (AR.contains_substring "hi" "hello")

(* ============================================ *)
(* measure_metric_with_retry                    *)
(* ============================================ *)

let test_retry_parse_failure_no_retry () =
  (* Parse failure (not a float) should not retry *)
  with_tmpdir (fun workdir ->
    match AR.measure_metric_with_retry ~workdir ~timeout_s:5.0 ~max_retries:2 "echo notanumber" with
    | Error msg ->
      check bool "parse error" true (AR.contains_substring msg "not a float")
    | Ok _ -> fail "expected error for non-float output"
  )

let test_retry_success_no_retry () =
  with_tmpdir (fun workdir ->
    match AR.measure_metric_with_retry ~workdir ~timeout_s:5.0 ~max_retries:2 "echo 42.5" with
    | Ok (v, _ms) ->
      check (float 0.001) "value" 42.5 v
    | Error e -> fail ("unexpected error: " ^ e)
  )

(* ============================================ *)
(* git_commit_cycle message format              *)
(* ============================================ *)

let test_git_commit_cycle_format () =
  (* git_commit no longer uses --allow-empty, so we must create a real file change *)
  with_tmpdir (fun workdir ->
    (* Initialize a git repo with an initial commit *)
    ignore (Sys.command (Printf.sprintf
      "cd %s && git init -q -b test-branch && git config user.email 'test@test.com' && git config user.name 'Test' && echo 'init' > init.txt && git add init.txt && git commit -m init -q"
      (Filename.quote workdir)));
    (* Create a file change so git_commit_cycle has something to commit *)
    let oc = open_out (Filename.concat workdir "target.py") in
    output_string oc "print('hello')";
    close_out oc;
    match AR.git_commit_cycle ~workdir ~cycle:5 ~hypothesis:"use dropout" ~baseline:0.85 with
    | Ok (Some hash) ->
      check bool "hash non-empty" true (String.length hash > 0);
      let cmd = Printf.sprintf "cd %s && git log -1 --format=%%s" (Filename.quote workdir) in
      let ic = Unix.open_process_in cmd in
      let msg = Fun.protect ~finally:(fun () ->
        ignore (Unix.close_process_in ic)
      ) (fun () -> try input_line ic with End_of_file -> "") in
      check bool "contains [autoresearch]" true (AR.contains_substring msg "[autoresearch]");
      check bool "contains cycle 5" true (AR.contains_substring msg "cycle 5");
      check bool "contains hypothesis" true (AR.contains_substring msg "use dropout")
    | Ok None -> fail "expected commit hash, got Ok None (no diff)"
    | Error e -> fail (Printf.sprintf "expected commit hash, got Error: %s" e)
  )

(* ============================================ *)
(* build_code_change_prompt                     *)
(* ============================================ *)

let test_build_code_change_prompt_basic () =
  let prompt = AR.build_code_change_prompt
    ~goal:"Reduce latency" ~baseline:0.85 ~history:[] ~insights:[]
    ~file_content:"print('hello')" ~target_file:"target.py" in
  check bool "contains goal" true (AR.contains_substring prompt "Reduce latency");
  check bool "contains baseline" true (AR.contains_substring prompt "0.85");
  check bool "contains target_file" true (AR.contains_substring prompt "target.py");
  check bool "contains <current_code>" true (AR.contains_substring prompt "<current_code>");
  check bool "contains file content" true (AR.contains_substring prompt "print('hello')");
  check bool "contains <modified_code> instruction" true
    (AR.contains_substring prompt "<modified_code>")

let test_build_code_change_prompt_with_history () =
  let history = [make_cycle ~cycle:1 ~hypothesis:"batch=32" ()] in
  let prompt = AR.build_code_change_prompt
    ~goal:"test" ~baseline:1.0 ~history ~insights:["prev insight"]
    ~file_content:"x = 1" ~target_file:"t.py" in
  check bool "contains history" true (AR.contains_substring prompt "batch=32");
  check bool "contains insight" true (AR.contains_substring prompt "prev insight");
  check bool "contains code" true (AR.contains_substring prompt "x = 1")

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
  let args = `Assoc [("goal", `String "optimize"); ("target_file", `String "t.py")] in
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
(* Cycle dispatch                               *)
(* ============================================ *)

let test_dispatch_cycle_no_loop () =
  let ctx : Tool.context = { base_path = "/tmp" } in
  Tool.latest_loop_id := None;
  Hashtbl.clear Tool.active_loops;
  match Tool.dispatch ctx ~name:"masc_autoresearch_cycle" ~args:(`Assoc []) with
  | Some (false, json_str) ->
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    check bool "error for no loop" true
      (String.length (json |> member "error" |> to_string) > 0)
  | _ -> fail "expected error for no loop"

let test_dispatch_cycle_stopped_loop () =
  let ctx : Tool.context = { base_path = "/tmp" } in
  let state = make_state ~loop_id:"ar-stopped" ~status:AR.Stopped () in
  Hashtbl.replace Tool.active_loops "ar-stopped" state;
  Tool.latest_loop_id := Some "ar-stopped";
  match Tool.dispatch ctx ~name:"masc_autoresearch_cycle" ~args:(`Assoc []) with
  | Some (false, json_str) ->
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    check bool "error for stopped" true
      (AR.contains_substring (json |> member "error" |> to_string) "not running")
  | _ -> fail "expected error for stopped loop"

let test_dispatch_cycle_at_max () =
  with_tmpdir (fun base_path ->
    let ctx : Tool.context = { base_path } in
    let state = make_state ~loop_id:"ar-maxed" ~current_cycle:10 ~max_cycles:10 () in
    Hashtbl.replace Tool.active_loops "ar-maxed" state;
    Tool.latest_loop_id := Some "ar-maxed";
    match Tool.dispatch ctx ~name:"masc_autoresearch_cycle" ~args:(`Assoc []) with
    | Some (true, json_str) ->
      let json = Yojson.Safe.from_string json_str in
      let open Yojson.Safe.Util in
      check string "status completed" "completed"
        (json |> member "status" |> to_string)
    | Some (false, s) -> fail ("unexpected error: " ^ s)
    | None -> fail "expected Some for cycle tool"
  )

(* ============================================ *)
(* Schema validation                            *)
(* ============================================ *)

let test_schemas_count () =
  check int "5 tool schemas" 5 (List.length Tool.schemas)

let test_schemas_names () =
  let names = List.map (fun (s : Masc_mcp.Types.tool_schema) -> s.name) Tool.schemas in
  check bool "start" true (List.mem "masc_autoresearch_start" names);
  check bool "status" true (List.mem "masc_autoresearch_status" names);
  check bool "stop" true (List.mem "masc_autoresearch_stop" names);
  check bool "inject" true (List.mem "masc_autoresearch_inject" names);
  check bool "cycle" true (List.mem "masc_autoresearch_cycle" names)

let test_schemas_cycle_present () =
  let names = List.map (fun (s : Masc_mcp.Types.tool_schema) -> s.name) Tool.schemas in
  let has_cycle = List.exists (fun n -> AR.contains_substring n "cycle") names in
  check bool "has cycle tool" true has_cycle

(* ============================================ *)
(* parse_llm_code_response                      *)
(* ============================================ *)

let test_parse_llm_code_response_ok () =
  let response =
    "Some preamble text.\n\
     <hypothesis>Increase batch size to 64</hypothesis>\n\
     <modified_code>\n\
     batch_size = 64\n\
     train(batch_size)\n\
     </modified_code>\n\
     Some trailing text." in
  match AR.parse_llm_code_response response with
  | Ok (hyp, code) ->
    check string "hypothesis" "Increase batch size to 64" hyp;
    check bool "code contains batch_size" true
      (AR.contains_substring code "batch_size = 64");
    check bool "code contains train" true
      (AR.contains_substring code "train(batch_size)")
  | Error e -> fail ("unexpected error: " ^ e)

let test_parse_llm_code_response_no_tags () =
  let response = "Just some random text without any tags." in
  match AR.parse_llm_code_response response with
  | Error msg ->
    check bool "mentions hypothesis" true
      (AR.contains_substring msg "hypothesis")
  | Ok _ -> fail "expected error for missing tags"

let test_parse_llm_code_response_empty () =
  match AR.parse_llm_code_response "" with
  | Error msg ->
    check bool "mentions empty" true
      (AR.contains_substring msg "empty")
  | Ok _ -> fail "expected error for empty response"

let test_parse_llm_code_response_empty_hypothesis () =
  let response = "<hypothesis>  </hypothesis><modified_code>x=1</modified_code>" in
  match AR.parse_llm_code_response response with
  | Error msg ->
    check bool "mentions empty hypothesis" true
      (AR.contains_substring msg "Empty")
  | Ok _ -> fail "expected error for empty hypothesis"

(* ============================================ *)
(* validate_target_file                         *)
(* ============================================ *)

let test_validate_target_file_traversal () =
  match AR.validate_target_file ~workdir:"/tmp" "../secret" with
  | Error msg ->
    check bool "mentions .." true (AR.contains_substring msg "..")
  | Ok _ -> fail "expected error for path traversal"

let test_validate_target_file_absolute () =
  match AR.validate_target_file ~workdir:"/tmp" "/etc/passwd" with
  | Error msg ->
    check bool "mentions relative" true (AR.contains_substring msg "relative")
  | Ok _ -> fail "expected error for absolute path"

let test_validate_target_file_ok () =
  with_tmpdir (fun workdir ->
    let path = Filename.concat workdir "target.py" in
    let oc = open_out path in
    output_string oc "x = 1\n";
    close_out oc;
    match AR.validate_target_file ~workdir "target.py" with
    | Ok abs_path ->
      check bool "returns absolute" true (String.get abs_path 0 = '/');
      check bool "ends with target.py" true
        (AR.contains_substring abs_path "target.py")
    | Error e -> fail ("unexpected error: " ^ e)
  )

let test_validate_target_file_empty () =
  match AR.validate_target_file ~workdir:"/tmp" "" with
  | Error msg ->
    check bool "mentions empty" true (AR.contains_substring msg "empty")
  | Ok _ -> fail "expected error for empty target_file"

(* ..foo is a legitimate filename, not path traversal *)
let test_validate_target_file_dotdot_prefix () =
  with_tmpdir (fun workdir ->
    let path = Filename.concat workdir "..foo" in
    let oc = open_out path in
    output_string oc "ok\n";
    close_out oc;
    match AR.validate_target_file ~workdir "..foo" with
    | Ok abs_path ->
      check bool "returns absolute" true (String.get abs_path 0 = '/');
      check bool "ends with ..foo" true (AR.contains_substring abs_path "..foo")
    | Error e -> fail ("..foo should be allowed: " ^ e)
  )

(* symlink pointing outside workdir should be rejected *)
let test_validate_target_file_symlink_escape () =
  with_tmpdir (fun workdir ->
    let link = Filename.concat workdir "escape.py" in
    Unix.symlink "/etc/hosts" link;
    match AR.validate_target_file ~workdir "escape.py" with
    | Error msg ->
      check bool "mentions symlink" true (AR.contains_substring msg "symlink")
    | Ok _ -> fail "symlink escaping workdir should be rejected"
  )

(* A directory path should be rejected — only regular files are valid *)
let test_validate_target_file_directory () =
  with_tmpdir (fun workdir ->
    let dir = Filename.concat workdir "subdir" in
    Unix.mkdir dir 0o755;
    match AR.validate_target_file ~workdir "subdir" with
    | Error msg ->
      check bool "mentions directory" true (AR.contains_substring msg "directory")
    | Ok _ -> fail "directory should be rejected as target_file"
  )

(* ============================================ *)
(* apply_code_change                            *)
(* ============================================ *)

let test_apply_code_change_writes () =
  with_tmpdir (fun workdir ->
    let path = Filename.concat workdir "target.py" in
    let oc = open_out path in
    output_string oc "original content\n";
    close_out oc;
    match AR.apply_code_change ~workdir ~target_file:"target.py"
            ~new_content:"modified content\n" with
    | Ok _ ->
      let actual = AR.read_file path in
      check string "file overwritten" "modified content\n" actual
    | Error e -> fail ("unexpected error: " ^ e)
  )

let test_apply_code_change_returns_original () =
  with_tmpdir (fun workdir ->
    let path = Filename.concat workdir "target.py" in
    let oc = open_out path in
    output_string oc "original\n";
    close_out oc;
    match AR.apply_code_change ~workdir ~target_file:"target.py"
            ~new_content:"new\n" with
    | Ok original ->
      check string "returns original" "original\n" original
    | Error e -> fail ("unexpected error: " ^ e)
  )

(* ============================================ *)
(* extract_tag                                  *)
(* ============================================ *)

let test_extract_tag_basic () =
  let text = "before <hypothesis>my idea</hypothesis> after" in
  match AR.extract_tag ~tag:"hypothesis" text with
  | Some content -> check string "tag content" "my idea" content
  | None -> fail "expected Some"

let test_extract_tag_missing () =
  let text = "no tags here" in
  check (option string) "missing tag" None (AR.extract_tag ~tag:"hypothesis" text)

(* ============================================ *)
(* Integration: full cycle keep/discard         *)
(* ============================================ *)

(** Helper: set up a temp git repo with a target file and metric script.
    metric.sh counts lines in target.py → score = line count. *)
let setup_integration_repo () =
  let workdir = Filename.temp_dir "ar_integ_" "" in
  (* Initialize git repo *)
  ignore (Sys.command (Printf.sprintf
    "cd %s && git init -q -b ar-work && git config user.email 'test@test.com' && git config user.name 'Test'"
    (Filename.quote workdir)));
  (* Create target.py with 3 lines *)
  let target = Filename.concat workdir "target.py" in
  let oc = open_out target in
  output_string oc "line1\nline2\nline3\n";
  close_out oc;
  (* Create metric.sh: count lines *)
  let metric = Filename.concat workdir "metric.sh" in
  let oc = open_out metric in
  output_string oc "#!/bin/sh\nwc -l < target.py | tr -d ' '\n";
  close_out oc;
  ignore (Sys.command (Printf.sprintf "chmod +x %s" (Filename.quote metric)));
  (* Initial commit *)
  ignore (Sys.command (Printf.sprintf
    "cd %s && git add -A && git commit -q -m 'initial'"
    (Filename.quote workdir)));
  workdir

let cleanup_integration_repo workdir =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote workdir)))

let test_full_cycle_keep () =
  let workdir = setup_integration_repo () in
  Fun.protect ~finally:(fun () -> cleanup_integration_repo workdir) (fun () ->
    (* Set up state *)
    let state = make_state
      ~loop_id:"ar-integ-keep"
      ~goal:"Maximize line count"
      ~metric_fn:"sh metric.sh"
      ~target_file:"target.py"
      ~workdir
      ~baseline:3.0
      ~best_score:3.0
      () in
    Hashtbl.replace Tool.active_loops "ar-integ-keep" state;
    Tool.latest_loop_id := Some "ar-integ-keep";
    (* Register mock generator: adds a line *)
    Tool.set_generator "ar-integ-keep"
      (fun ~goal:_ ~baseline:_ ~history:_ ~insights:_
           ~target_file:_ ~file_content ~llm_model:_ ->
        Ok ("Add a line", file_content ^ "line4\n"));
    let ctx : Tool.context = { base_path = workdir } in
    match Tool.dispatch ctx ~name:"masc_autoresearch_cycle" ~args:(`Assoc []) with
    | Some (true, json_str) ->
      let json = Yojson.Safe.from_string json_str in
      let open Yojson.Safe.Util in
      let decision = json |> member "decision" |> to_string in
      check string "decision is keep" "keep" decision;
      (* Verify baseline updated *)
      check (float 0.001) "baseline updated to 4" 4.0 state.baseline;
      (* Verify commit was kept (not reset) *)
      let ic = Unix.open_process_in
        (Printf.sprintf "cd %s && git log --oneline | wc -l | tr -d ' '"
          (Filename.quote workdir)) in
      let count = Fun.protect ~finally:(fun () ->
        ignore (Unix.close_process_in ic)
      ) (fun () -> try int_of_string (String.trim (input_line ic)) with _ -> 0) in
      check bool "two commits (init + cycle)" true (count >= 2)
    | Some (false, e) -> fail ("cycle error: " ^ e)
    | None -> fail "expected Some for cycle"
  )

let test_full_cycle_discard () =
  let workdir = setup_integration_repo () in
  Fun.protect ~finally:(fun () -> cleanup_integration_repo workdir) (fun () ->
    let state = make_state
      ~loop_id:"ar-integ-discard"
      ~goal:"Maximize line count"
      ~metric_fn:"sh metric.sh"
      ~target_file:"target.py"
      ~workdir
      ~baseline:3.0
      ~best_score:3.0
      () in
    Hashtbl.replace Tool.active_loops "ar-integ-discard" state;
    Tool.latest_loop_id := Some "ar-integ-discard";
    (* Register mock generator: removes a line (score decreases) *)
    Tool.set_generator "ar-integ-discard"
      (fun ~goal:_ ~baseline:_ ~history:_ ~insights:_
           ~target_file:_ ~file_content:_ ~llm_model:_ ->
        Ok ("Remove a line", "line1\nline2\n"));
    let ctx : Tool.context = { base_path = workdir } in
    match Tool.dispatch ctx ~name:"masc_autoresearch_cycle" ~args:(`Assoc []) with
    | Some (true, json_str) ->
      let json = Yojson.Safe.from_string json_str in
      let open Yojson.Safe.Util in
      let decision = json |> member "decision" |> to_string in
      check string "decision is discard" "discard" decision;
      (* Verify baseline unchanged *)
      check (float 0.001) "baseline unchanged" 3.0 state.baseline;
      (* Verify file was restored by git reset *)
      let content = AR.read_file (Filename.concat workdir "target.py") in
      check bool "file restored" true
        (AR.contains_substring content "line3");
      (* Verify only initial commit remains *)
      let ic = Unix.open_process_in
        (Printf.sprintf "cd %s && git log --oneline | wc -l | tr -d ' '"
          (Filename.quote workdir)) in
      let count = Fun.protect ~finally:(fun () ->
        ignore (Unix.close_process_in ic)
      ) (fun () -> try int_of_string (String.trim (input_line ic)) with _ -> 0) in
      check int "only initial commit" 1 count
    | Some (false, e) -> fail ("cycle error: " ^ e)
    | None -> fail "expected Some for cycle"
  )

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
      test_case "custom llm" `Quick test_create_state_custom_llm;
    ]);
    ("record_cycle", [
      test_case "keep" `Quick test_record_cycle_keep;
      test_case "discard" `Quick test_record_cycle_discard;
      test_case "equal score" `Quick test_record_cycle_equal_score;
      test_case "best tracking" `Quick test_record_cycle_best_tracking;
    ]);
    ("insights", [
      test_case "keep message" `Quick test_insights_keep_message;
      test_case "discard message" `Quick test_insights_discard_message;
      test_case "FIFO limit" `Quick test_insights_fifo_limit;
      test_case "add_insight basic" `Quick test_add_insight_basic;
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
    ("contains_substring", [
      test_case "basic" `Quick test_contains_substring;
    ]);
    ("retry", [
      test_case "parse failure no retry" `Quick test_retry_parse_failure_no_retry;
      test_case "success no retry" `Quick test_retry_success_no_retry;
    ]);
    ("git_helpers", [
      test_case "commit_cycle format" `Quick test_git_commit_cycle_format;
    ]);
    ("code_change_prompt", [
      test_case "basic" `Quick test_build_code_change_prompt_basic;
      test_case "with history" `Quick test_build_code_change_prompt_with_history;
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
    ("cycle_dispatch", [
      test_case "no loop" `Quick test_dispatch_cycle_no_loop;
      test_case "stopped loop" `Quick test_dispatch_cycle_stopped_loop;
      test_case "at max cycles" `Quick test_dispatch_cycle_at_max;
    ]);
    ("schemas", [
      test_case "count" `Quick test_schemas_count;
      test_case "names" `Quick test_schemas_names;
      test_case "cycle present" `Quick test_schemas_cycle_present;
    ]);
    ("parse_llm_code_response", [
      test_case "ok" `Quick test_parse_llm_code_response_ok;
      test_case "no tags" `Quick test_parse_llm_code_response_no_tags;
      test_case "empty" `Quick test_parse_llm_code_response_empty;
      test_case "empty hypothesis" `Quick test_parse_llm_code_response_empty_hypothesis;
    ]);
    ("validate_target_file", [
      test_case "traversal" `Quick test_validate_target_file_traversal;
      test_case "absolute" `Quick test_validate_target_file_absolute;
      test_case "ok" `Quick test_validate_target_file_ok;
      test_case "empty" `Quick test_validate_target_file_empty;
      test_case "dotdot prefix" `Quick test_validate_target_file_dotdot_prefix;
      test_case "symlink escape" `Quick test_validate_target_file_symlink_escape;
      test_case "directory" `Quick test_validate_target_file_directory;
    ]);
    ("apply_code_change", [
      test_case "writes file" `Quick test_apply_code_change_writes;
      test_case "returns original" `Quick test_apply_code_change_returns_original;
    ]);
    ("extract_tag", [
      test_case "basic" `Quick test_extract_tag_basic;
      test_case "missing" `Quick test_extract_tag_missing;
    ]);
    ("integration", [
      test_case "full cycle keep" `Quick test_full_cycle_keep;
      test_case "full cycle discard" `Quick test_full_cycle_discard;
    ]);
  ]
