(** Deep tests for raw_trace.ml and raw_trace_query.ml — targeting the
    130 uncovered points at 71%.

    Exercises:
    - record_to_json / record_of_json roundtrip (hand-rolled, not ppx)
    - record_type_to_string / record_type_of_string
    - option_* helper functions via record serialization
    - safe_name sanitization
    - read_all via temp files
    - summarize_run / validate_run via JSONL files
    - create (which exercises ensure_dir internally)
    - Error paths: bad JSON, unknown record_type *)

open Agent_sdk

let tmpdir () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "oas_raw_trace_test_%d_%d" (Unix.getpid ()) (Random.int 0xFFFF))
  in
  Unix.mkdir dir 0o755;
  dir
;;

let write_jsonl path records =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
       List.iter
         (fun record ->
            output_string oc (Yojson.Safe.to_string (Raw_trace.record_to_json record));
            output_char oc '\n')
         records)
;;

(* ── record_type string conversion ──────────────────────────────── *)

let test_record_type_to_string () =
  let pairs =
    [ Raw_trace.Run_started, "run_started"
    ; Raw_trace.Assistant_block, "assistant_block"
    ; Raw_trace.Tool_execution_started, "tool_execution_started"
    ; Raw_trace.Tool_execution_finished, "tool_execution_finished"
    ; Raw_trace.Hook_invoked, "hook_invoked"
    ; Raw_trace.Run_finished, "run_finished"
    ]
  in
  List.iter
    (fun (rt, expected) ->
       Alcotest.(check string)
         (expected ^ " to_string")
         expected
         (Raw_trace.record_type_to_string rt))
    pairs
;;

let test_record_type_of_string () =
  let valid =
    [ "run_started"
    ; "assistant_block"
    ; "tool_execution_started"
    ; "tool_execution_finished"
    ; "hook_invoked"
    ; "run_finished"
    ]
  in
  List.iter
    (fun s ->
       match Raw_trace.record_type_of_string s with
       | Ok rt ->
         Alcotest.(check string) (s ^ " roundtrip") s (Raw_trace.record_type_to_string rt)
       | Error _ -> Alcotest.fail (Printf.sprintf "valid string %s rejected" s))
    valid
;;

let test_record_type_of_string_unknown () =
  match Raw_trace.record_type_of_string "bogus" with
  | Error (Error.Serialization (UnknownVariant { type_name; value })) ->
    Alcotest.(check string) "type_name" "raw_trace.record_type" type_name;
    Alcotest.(check string) "value" "bogus" value
  | Ok _ -> Alcotest.fail "should reject unknown record_type"
  | Error _ -> Alcotest.fail "wrong error variant"
;;

(* ── safe_name ──────────────────────────────────────────────────── *)

let test_safe_name () =
  Alcotest.(check string) "normal" "coder" (Raw_trace.safe_name "coder");
  Alcotest.(check string) "spaces" "my_agent" (Raw_trace.safe_name "my agent");
  Alcotest.(check string) "slashes" "path_to_agent" (Raw_trace.safe_name "path/to\\agent");
  Alcotest.(check string) "tabs_newlines" "a_b_c_d" (Raw_trace.safe_name "a\tb\nc\rd");
  Alcotest.(check string) "empty" "agent" (Raw_trace.safe_name "");
  Alcotest.(check string) "whitespace_only" "agent" (Raw_trace.safe_name "   ");
  Alcotest.(check string) "trimmed" "hello" (Raw_trace.safe_name "  hello  ")
;;

(* ── read_all with invalid JSON exercises parse_json_string ──────── *)

let test_read_all_invalid_json () =
  let dir = tmpdir () in
  let path = Filename.concat dir "bad.jsonl" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc "not valid json\n");
  match Raw_trace.read_all ~path () with
  | Ok _ -> Alcotest.fail "should reject invalid JSON"
  | Error _ -> () (* parse error propagated *)
;;

(* ── record_to_json / record_of_json roundtrip ──────────────────── *)

let mk_record
      ?(record_type = Raw_trace.Run_started)
      ?(seq = 1)
      ?(prompt = Some "hello")
      ?(tool_use_id = None)
      ?(tool_name = None)
      ?(tool_input = None)
      ?(tool_result = None)
      ?(tool_error = None)
      ?(tool_turn = None)
      ?(tool_planned_index = None)
      ?(tool_batch_index = None)
      ?(tool_batch_size = None)
      ?(tool_execution_mode = None)
      ?(hook_name = None)
      ?(hook_decision = None)
      ?(hook_detail = None)
      ?(final_text = None)
      ?(stop_reason = None)
      ?(error = None)
      ?(block_index = None)
      ?(block_kind = None)
      ?(assistant_block = None)
      ()
  : Raw_trace.record
  =
  { trace_version = Raw_trace.trace_version
  ; worker_run_id = "wr-test-0001"
  ; seq
  ; ts = 1.7e9
  ; agent_name = "test_agent"
  ; session_id = Some "s-test-001"
  ; record_type
  ; prompt
  ; model = Some "glm-5.1"
  ; tool_choice = Some (Agent_sdk.Types.tool_choice_to_json Agent_sdk.Types.Any)
  ; enable_thinking = Some false
  ; preserve_thinking = None
  ; thinking_budget = Some 2048
  ; reasoning_effort = Some "high"
  ; block_index
  ; block_kind
  ; assistant_block
  ; tool_use_id
  ; tool_name
  ; tool_input
  ; tool_turn
  ; tool_planned_index
  ; tool_batch_index
  ; tool_batch_size
  ; tool_execution_mode
  ; tool_result
  ; tool_error
  ; hook_name
  ; hook_decision
  ; hook_detail
  ; final_text
  ; stop_reason
  ; error
  }
;;

let test_record_to_json_roundtrip_run_started () =
  let r = mk_record () in
  let json = Raw_trace.record_to_json r in
  match Raw_trace.record_of_json json with
  | Ok decoded ->
    Alcotest.(check string) "worker_run_id" r.worker_run_id decoded.worker_run_id;
    Alcotest.(check int) "seq" r.seq decoded.seq;
    Alcotest.(check (option string)) "prompt" r.prompt decoded.prompt;
    Alcotest.(check bool) "record_type" true (decoded.record_type = Raw_trace.Run_started)
  | Error _ -> Alcotest.fail "record_of_json failed for run_started"
;;

let test_record_to_json_roundtrip_tool_exec () =
  let r =
    mk_record
      ~record_type:Raw_trace.Tool_execution_finished
      ~seq:5
      ~prompt:None
      ~tool_use_id:(Some "tu-abc")
      ~tool_name:(Some "bash")
      ~tool_input:(Some (`Assoc [ "cmd", `String "ls" ]))
      ~tool_planned_index:(Some 1)
      ~tool_batch_index:(Some 0)
      ~tool_batch_size:(Some 2)
      ~tool_result:(Some "output")
      ~tool_error:(Some false)
      ()
  in
  let json = Raw_trace.record_to_json r in
  match Raw_trace.record_of_json json with
  | Ok decoded ->
    Alcotest.(check (option string)) "tool_use_id" (Some "tu-abc") decoded.tool_use_id;
    Alcotest.(check (option string)) "tool_name" (Some "bash") decoded.tool_name;
    Alcotest.(check (option int)) "tool_batch_size" (Some 2) decoded.tool_batch_size;
    Alcotest.(check (option string)) "tool_result" (Some "output") decoded.tool_result;
    Alcotest.(check (option bool)) "tool_error" (Some false) decoded.tool_error
  | Error _ -> Alcotest.fail "record_of_json failed for tool_exec"
;;

let test_record_to_json_roundtrip_hook () =
  let r =
    mk_record
      ~record_type:Raw_trace.Hook_invoked
      ~seq:3
      ~prompt:None
      ~hook_name:(Some "pre_tool")
      ~hook_decision:(Some "allow")
      ~hook_detail:(Some "file access ok")
      ()
  in
  let json = Raw_trace.record_to_json r in
  match Raw_trace.record_of_json json with
  | Ok decoded ->
    Alcotest.(check (option string)) "hook_name" (Some "pre_tool") decoded.hook_name;
    Alcotest.(check (option string)) "hook_decision" (Some "allow") decoded.hook_decision;
    Alcotest.(check (option string))
      "hook_detail"
      (Some "file access ok")
      decoded.hook_detail
  | Error _ -> Alcotest.fail "record_of_json failed for hook"
;;

let test_record_to_json_roundtrip_assistant_block () =
  let block_json = `Assoc [ "type", `String "text"; "text", `String "Hello" ] in
  let r =
    mk_record
      ~record_type:Raw_trace.Assistant_block
      ~seq:2
      ~prompt:None
      ~block_index:(Some 0)
      ~block_kind:(Some "text")
      ~assistant_block:(Some block_json)
      ()
  in
  let json = Raw_trace.record_to_json r in
  match Raw_trace.record_of_json json with
  | Ok decoded ->
    Alcotest.(check (option int)) "block_index" (Some 0) decoded.block_index;
    Alcotest.(check (option string)) "block_kind" (Some "text") decoded.block_kind;
    Alcotest.(check bool) "assistant_block present" true (decoded.assistant_block <> None)
  | Error _ -> Alcotest.fail "record_of_json failed for assistant_block"
;;

let test_record_to_json_roundtrip_run_finished () =
  let r =
    mk_record
      ~record_type:Raw_trace.Run_finished
      ~seq:20
      ~prompt:None
      ~final_text:(Some "All done.")
      ~stop_reason:(Some "end_turn")
      ~error:None
      ()
  in
  let json = Raw_trace.record_to_json r in
  match Raw_trace.record_of_json json with
  | Ok decoded ->
    Alcotest.(check (option string)) "final_text" (Some "All done.") decoded.final_text;
    Alcotest.(check (option string)) "stop_reason" (Some "end_turn") decoded.stop_reason;
    Alcotest.(check (option string)) "error" None decoded.error
  | Error _ -> Alcotest.fail "record_of_json failed for run_finished"
;;

let test_record_to_json_all_none_optionals () =
  let r : Raw_trace.record =
    { trace_version = Raw_trace.trace_version
    ; worker_run_id = "wr-none"
    ; seq = 1
    ; ts = 1.0
    ; agent_name = "a"
    ; session_id = None
    ; record_type = Raw_trace.Run_started
    ; prompt = None
    ; model = None
    ; tool_choice = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; thinking_budget = None
    ; reasoning_effort = None
    ; block_index = None
    ; block_kind = None
    ; assistant_block = None
    ; tool_use_id = None
    ; tool_name = None
    ; tool_input = None
    ; tool_turn = None
    ; tool_planned_index = None
    ; tool_batch_index = None
    ; tool_batch_size = None
    ; tool_execution_mode = None
    ; tool_result = None
    ; tool_error = None
    ; hook_name = None
    ; hook_decision = None
    ; hook_detail = None
    ; final_text = None
    ; stop_reason = None
    ; error = None
    }
  in
  let json = Raw_trace.record_to_json r in
  match Raw_trace.record_of_json json with
  | Ok decoded ->
    Alcotest.(check (option string)) "session_id" None decoded.session_id;
    Alcotest.(check (option string)) "prompt" None decoded.prompt;
    Alcotest.(check (option string)) "tool_name" None decoded.tool_name
  | Error _ -> Alcotest.fail "all-none record failed"
;;

(* ── record_of_json error: bad record_type ──────────────────────── *)

let test_record_of_json_bad_type () =
  let json =
    `Assoc
      [ "trace_version", `Int Raw_trace.trace_version
      ; "worker_run_id", `String "wr-x"
      ; "seq", `Int 1
      ; "ts", `Float 1.0
      ; "agent_name", `String "a"
      ; "session_id", `Null
      ; "record_type", `String "invalid_type"
      ]
  in
  match Raw_trace.record_of_json json with
  | Error (Error.Serialization (UnknownVariant _)) -> ()
  | Ok _ -> Alcotest.fail "should reject invalid record_type"
  | Error _ -> Alcotest.fail "wrong error variant"
;;

(* ── load_lines / read_all via temp file ────────────────────────── *)

let test_read_all_empty_file () =
  let dir = tmpdir () in
  let path = Filename.concat dir "empty.jsonl" in
  let oc = open_out path in
  close_out oc;
  match Raw_trace.read_all ~path () with
  | Ok records -> Alcotest.(check int) "empty" 0 (List.length records)
  | Error _ -> Alcotest.fail "read_all failed on empty file"
;;

let test_read_all_with_records () =
  let dir = tmpdir () in
  let path = Filename.concat dir "records.jsonl" in
  let records =
    [ mk_record ~seq:1 ()
    ; mk_record
        ~record_type:Raw_trace.Run_finished
        ~seq:2
        ~prompt:None
        ~final_text:(Some "done")
        ~stop_reason:(Some "end_turn")
        ()
    ]
  in
  write_jsonl path records;
  match Raw_trace.read_all ~path () with
  | Ok loaded ->
    Alcotest.(check int) "count" 2 (List.length loaded);
    let first = List.hd loaded in
    Alcotest.(check int) "first seq" 1 first.seq;
    let last = List.nth loaded 1 in
    Alcotest.(check int) "last seq" 2 last.seq
  | Error _ -> Alcotest.fail "read_all failed"
;;

let test_read_all_nonexistent_file () =
  match Raw_trace.read_all ~path:"/tmp/nonexistent_oas_test_file.jsonl" () with
  | Ok records -> Alcotest.(check int) "empty for missing file" 0 (List.length records)
  | Error _ -> Alcotest.fail "read_all should return Ok [] for missing file"
;;

let test_read_all_blank_lines () =
  let dir = tmpdir () in
  let path = Filename.concat dir "blanks.jsonl" in
  let r = mk_record ~seq:1 () in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
       output_string oc "\n";
       output_string oc (Yojson.Safe.to_string (Raw_trace.record_to_json r));
       output_char oc '\n';
       output_string oc "  \n");
  match Raw_trace.read_all ~path () with
  | Ok records -> Alcotest.(check int) "filters blank lines" 1 (List.length records)
  | Error _ -> Alcotest.fail "read_all should skip blank lines"
;;

(* ── record_to_json with all option_* helpers ───────────────────── *)

let test_record_json_all_fields_populated () =
  (* Exercises option_string, option_int, option_bool, option_json *)
  let r : Raw_trace.record =
    { trace_version = Raw_trace.trace_version
    ; worker_run_id = "wr-all-fields"
    ; seq = 99
    ; ts = 1.7e9
    ; agent_name = "all_fields_agent"
    ; session_id = Some "s-full"
    ; record_type = Raw_trace.Assistant_block
    ; prompt = Some "test prompt"
    ; model = Some "glm-5.1"
    ; tool_choice =
        Some (Agent_sdk.Types.tool_choice_to_json (Agent_sdk.Types.Tool "complex_tool"))
    ; enable_thinking = Some true
    ; preserve_thinking = Some true
    ; thinking_budget = Some 8192
    ; reasoning_effort = Some "max"
    ; block_index = Some 3
    ; block_kind = Some "thinking"
    ; assistant_block =
        Some (`Assoc [ "type", `String "thinking"; "thinking", `String "hmm" ])
    ; tool_use_id = Some "tu-999"
    ; tool_name = Some "complex_tool"
    ; tool_input = Some (`Assoc [ "x", `Int 42 ])
    ; tool_turn = Some 3
    ; tool_planned_index = Some 4
    ; tool_batch_index = Some 2
    ; tool_batch_size = Some 1
    ; tool_execution_mode = None
    ; tool_result = Some "result text"
    ; tool_error = Some true
    ; hook_name = Some "validator"
    ; hook_decision = Some "reject"
    ; hook_detail = Some "failed validation"
    ; final_text = Some "final output"
    ; stop_reason = Some "max_tokens"
    ; error = Some "overflow"
    }
  in
  let json = Raw_trace.record_to_json r in
  match Raw_trace.record_of_json json with
  | Ok decoded ->
    Alcotest.(check (option string)) "prompt" (Some "test prompt") decoded.prompt;
    Alcotest.(check (option int)) "block_index" (Some 3) decoded.block_index;
    Alcotest.(check (option string)) "block_kind" (Some "thinking") decoded.block_kind;
    Alcotest.(check bool) "assistant_block" true (decoded.assistant_block <> None);
    Alcotest.(check (option string)) "tool_use_id" (Some "tu-999") decoded.tool_use_id;
    Alcotest.(check (option string)) "tool_name" (Some "complex_tool") decoded.tool_name;
    Alcotest.(check bool) "tool_input" true (decoded.tool_input <> None);
    Alcotest.(check (option int)) "tool_turn" (Some 3) decoded.tool_turn;
    Alcotest.(check (option string))
      "tool_result"
      (Some "result text")
      decoded.tool_result;
    Alcotest.(check (option bool)) "tool_error" (Some true) decoded.tool_error;
    Alcotest.(check (option string)) "hook_name" (Some "validator") decoded.hook_name;
    Alcotest.(check (option string)) "hook_decision" (Some "reject") decoded.hook_decision;
    Alcotest.(check (option string))
      "hook_detail"
      (Some "failed validation")
      decoded.hook_detail;
    Alcotest.(check (option string)) "final_text" (Some "final output") decoded.final_text;
    Alcotest.(check (option string)) "stop_reason" (Some "max_tokens") decoded.stop_reason;
    Alcotest.(check (option string)) "error" (Some "overflow") decoded.error
  | Error _ -> Alcotest.fail "all-fields record roundtrip failed"
;;

(* ── record JSON field presence check ───────────────────────────── *)

let test_record_json_none_fields_omitted () =
  let r = mk_record ~record_type:Raw_trace.Run_started ~prompt:(Some "hi") () in
  let json = Raw_trace.record_to_json r in
  let json_str = Yojson.Safe.to_string json in
  (* None fields like tool_name should not appear in the JSON output
     (option_string returns [] for None) *)
  Alcotest.(check bool)
    "no tool_name key when None"
    true
    (not (Util.string_contains ~needle:"tool_name" json_str));
  Alcotest.(check bool)
    "no hook_name key when None"
    true
    (not (Util.string_contains ~needle:"hook_name" json_str));
  (* But prompt should appear *)
  Alcotest.(check bool)
    "prompt present"
    true
    (Util.string_contains ~needle:"prompt" json_str)
;;

(* ── summarize_run via JSONL ────────────────────────────────────── *)

let test_summarize_run () =
  let dir = tmpdir () in
  let path = Filename.concat dir "summarize.jsonl" in
  let records =
    [ mk_record ~seq:1 ~record_type:Raw_trace.Run_started ~prompt:(Some "do it") ()
    ; mk_record
        ~seq:2
        ~record_type:Raw_trace.Assistant_block
        ~prompt:None
        ~block_index:(Some 0)
        ~block_kind:(Some "text")
        ()
    ; mk_record
        ~seq:3
        ~record_type:Raw_trace.Tool_execution_started
        ~prompt:None
        ~tool_use_id:(Some "tu-1")
        ~tool_name:(Some "bash")
        ~tool_input:(Some (`Assoc [ "cmd", `String "ls" ]))
        ~tool_execution_mode:(Some Tool_contract.Concurrent)
        ()
    ; mk_record
        ~seq:4
        ~record_type:Raw_trace.Tool_execution_finished
        ~prompt:None
        ~tool_use_id:(Some "tu-1")
        ~tool_name:(Some "bash")
        ~tool_result:(Some "ok")
        ~tool_error:(Some false)
        ()
    ; mk_record
        ~seq:5
        ~record_type:Raw_trace.Hook_invoked
        ~prompt:None
        ~hook_name:(Some "pre")
        ~hook_decision:(Some "allow")
        ()
    ; mk_record
        ~seq:6
        ~record_type:Raw_trace.Run_finished
        ~prompt:None
        ~final_text:(Some "All done")
        ~stop_reason:(Some "end_turn")
        ()
    ]
  in
  write_jsonl path records;
  let run_ref : Raw_trace.run_ref =
    { worker_run_id = "wr-test-0001"
    ; path
    ; start_seq = 1
    ; end_seq = 6
    ; agent_name = "test_agent"
    ; session_id = Some "s-test-001"
    }
  in
  match Raw_trace_query.summarize_run run_ref with
  | Ok summary ->
    Alcotest.(check int) "record_count" 6 summary.record_count;
    Alcotest.(check int) "assistant_blocks" 1 summary.assistant_block_count;
    Alcotest.(check int) "tool_started" 1 summary.tool_execution_started_count;
    Alcotest.(check int) "tool_finished" 1 summary.tool_execution_finished_count;
    Alcotest.(check int) "hooks" 1 summary.hook_invoked_count;
    Alcotest.(check (option string)) "final_text" (Some "All done") summary.final_text;
    Alcotest.(check (option string)) "stop_reason" (Some "end_turn") summary.stop_reason;
    Alcotest.(check bool) "bash in tool_names" true (List.mem "bash" summary.tool_names);
    Alcotest.(check bool) "pre in hook_names" true (List.mem "pre" summary.hook_names)
  | Error err ->
    Alcotest.fail (Printf.sprintf "summarize_run failed: %s" (Error.to_string err))
;;

(* ── validate_run via JSONL ─────────────────────────────────────── *)

let test_validate_run_pass () =
  let dir = tmpdir () in
  let path = Filename.concat dir "validate_pass.jsonl" in
  let records =
    [ mk_record ~seq:1 ~record_type:Raw_trace.Run_started ~prompt:(Some "go") ()
    ; mk_record
        ~seq:2
        ~record_type:Raw_trace.Tool_execution_started
        ~prompt:None
        ~tool_use_id:(Some "tu-1")
        ~tool_name:(Some "read")
        ~tool_input:(Some `Null)
        ~tool_planned_index:(Some 0)
        ~tool_execution_mode:(Some Tool_contract.Serial)
        ()
    ; mk_record
        ~seq:3
        ~record_type:Raw_trace.Tool_execution_finished
        ~prompt:None
        ~tool_use_id:(Some "tu-1")
        ~tool_name:(Some "read")
        ~tool_result:(Some "content")
        ~tool_error:(Some false)
        (* Historical finish records did not persist the planned index. *)
        ()
    ; mk_record
        ~seq:4
        ~record_type:Raw_trace.Run_finished
        ~prompt:None
        ~final_text:(Some "OK")
        ~stop_reason:(Some "end_turn")
        ()
    ]
  in
  write_jsonl path records;
  let run_ref : Raw_trace.run_ref =
    { worker_run_id = "wr-test-0001"
    ; path
    ; start_seq = 1
    ; end_seq = 4
    ; agent_name = "test_agent"
    ; session_id = Some "s-test-001"
    }
  in
  match Raw_trace_query.validate_run run_ref with
  | Ok validation ->
    Alcotest.(check bool) "ok" true validation.ok;
    Alcotest.(check int) "paired_tool_result_count" 1 validation.paired_tool_result_count;
    List.iter
      (fun (check : Raw_trace.validation_check) ->
         Alcotest.(check bool) (Printf.sprintf "check %s" check.name) true check.passed)
      validation.checks
  | Error err ->
    Alcotest.fail (Printf.sprintf "validate_run failed: %s" (Error.to_string err))
;;

let test_validate_run_no_finished () =
  let dir = tmpdir () in
  let path = Filename.concat dir "validate_nofin.jsonl" in
  let records =
    [ mk_record ~seq:1 ~record_type:Raw_trace.Run_started ~prompt:(Some "go") ()
    ; mk_record
        ~seq:2
        ~record_type:Raw_trace.Assistant_block
        ~prompt:None
        ~block_index:(Some 0)
        ~block_kind:(Some "text")
        ()
    ]
  in
  write_jsonl path records;
  let run_ref : Raw_trace.run_ref =
    { worker_run_id = "wr-test-0001"
    ; path
    ; start_seq = 1
    ; end_seq = 2
    ; agent_name = "test_agent"
    ; session_id = Some "s-test-001"
    }
  in
  match Raw_trace_query.validate_run run_ref with
  | Ok validation ->
    Alcotest.(check bool) "not ok" false validation.ok;
    let run_finished_check =
      List.find
        (fun (c : Raw_trace.validation_check) -> c.name = "run_finished")
        validation.checks
    in
    Alcotest.(check bool) "run_finished failed" false run_finished_check.passed
  | Error err ->
    Alcotest.fail (Printf.sprintf "validate_run error: %s" (Error.to_string err))
;;

let test_validate_run_unmatched_tool_pairs () =
  let dir = tmpdir () in
  let path = Filename.concat dir "validate_unpaired.jsonl" in
  let records =
    [ mk_record ~seq:1 ~record_type:Raw_trace.Run_started ~prompt:(Some "go") ()
    ; mk_record
        ~seq:2
        ~record_type:Raw_trace.Tool_execution_started
        ~prompt:None
        ~tool_use_id:(Some "tu-1")
        ~tool_name:(Some "bash")
        ~tool_input:(Some `Null)
        ~tool_execution_mode:(Some Tool_contract.Serial)
        ()
    ; (* No matching Tool_execution_finished for tu-1 *)
      mk_record
        ~seq:3
        ~record_type:Raw_trace.Run_finished
        ~prompt:None
        ~final_text:(Some "partial")
        ~stop_reason:(Some "error")
        ()
    ]
  in
  write_jsonl path records;
  let run_ref : Raw_trace.run_ref =
    { worker_run_id = "wr-test-0001"
    ; path
    ; start_seq = 1
    ; end_seq = 3
    ; agent_name = "test_agent"
    ; session_id = Some "s-test-001"
    }
  in
  match Raw_trace_query.validate_run run_ref with
  | Ok validation ->
    Alcotest.(check bool) "not ok (unmatched pairs)" false validation.ok;
    let tool_pairs_check =
      List.find
        (fun (c : Raw_trace.validation_check) -> c.name = "tool_pairs")
        validation.checks
    in
    Alcotest.(check bool) "tool_pairs failed" false tool_pairs_check.passed
  | Error err ->
    Alcotest.fail (Printf.sprintf "validate_run error: %s" (Error.to_string err))
;;

let assert_tool_pairs ~label ~filename ~expected records =
  let dir = tmpdir () in
  let path = Filename.concat dir filename in
  write_jsonl path records;
  let end_seq = (List.hd (List.rev records) : Raw_trace.record).seq in
  let run_ref : Raw_trace.run_ref =
    { worker_run_id = "wr-test-0001"
    ; path
    ; start_seq = 1
    ; end_seq
    ; agent_name = "test_agent"
    ; session_id = Some "s-test-001"
    }
  in
  match Raw_trace_query.validate_run run_ref with
  | Ok validation ->
    let tool_pairs =
      List.find
        (fun (check : Raw_trace.validation_check) -> check.name = "tool_pairs")
        validation.checks
    in
    Alcotest.(check bool) label expected tool_pairs.passed
  | Error err -> Alcotest.fail (Error.to_string err)
;;

let test_validate_run_distinguishes_repeated_blank_ids_across_turns () =
  let tool_record ~seq ~record_type ~turn =
    mk_record
      ~seq
      ~record_type
      ~prompt:None
      ~tool_use_id:(Some "")
      ~tool_name:(Some "repeat")
      ~tool_turn:(Some turn)
      ~tool_planned_index:(Some 0)
      ~tool_execution_mode:
        (match record_type with
         | Raw_trace.Tool_execution_started -> Some Tool_contract.Serial
         | _ -> None)
      ()
  in
  let records =
    [ mk_record ~seq:1 ~record_type:Raw_trace.Run_started ~prompt:(Some "go") ()
    ; tool_record ~seq:2 ~record_type:Raw_trace.Tool_execution_started ~turn:0
    ; tool_record ~seq:3 ~record_type:Raw_trace.Tool_execution_started ~turn:1
    ; tool_record ~seq:4 ~record_type:Raw_trace.Tool_execution_finished ~turn:0
    ; tool_record ~seq:5 ~record_type:Raw_trace.Tool_execution_finished ~turn:0
    ; mk_record
        ~seq:6
        ~record_type:Raw_trace.Run_finished
        ~prompt:None
        ~final_text:(Some "done")
        ~stop_reason:(Some "end_turn")
        ()
    ]
  in
  assert_tool_pairs
    ~label:"same id and planned index do not hide cross-turn mismatch"
    ~filename:"validate_exact_occurrence.jsonl"
    ~expected:false
    records
;;

let test_validate_run_rejects_finish_before_start () =
  let tool_record ~seq ~record_type =
    mk_record
      ~seq
      ~record_type
      ~prompt:None
      ~tool_use_id:(Some "ordered")
      ~tool_name:(Some "echo")
      ~tool_turn:(Some 0)
      ~tool_planned_index:(Some 0)
      ~tool_execution_mode:
        (match record_type with
         | Raw_trace.Tool_execution_started -> Some Tool_contract.Serial
         | _ -> None)
      ()
  in
  let records =
    [ mk_record ~seq:1 ~record_type:Raw_trace.Run_started ~prompt:(Some "go") ()
    ; tool_record ~seq:2 ~record_type:Raw_trace.Tool_execution_finished
    ; tool_record ~seq:3 ~record_type:Raw_trace.Tool_execution_started
    ; mk_record ~seq:4 ~record_type:Raw_trace.Run_finished ~prompt:None ()
    ]
  in
  assert_tool_pairs
    ~label:"finish before start is invalid"
    ~filename:"validate_lifecycle_order.jsonl"
    ~expected:false
    records
;;

let test_validate_run_does_not_collapse_mixed_legacy_records () =
  let records =
    [ mk_record ~seq:1 ~record_type:Raw_trace.Run_started ~prompt:(Some "go") ()
    ; mk_record
        ~seq:2
        ~record_type:Raw_trace.Tool_execution_started
        ~prompt:None
        ~tool_use_id:(Some "")
        ~tool_turn:(Some 0)
        ~tool_planned_index:(Some 0)
        ~tool_execution_mode:(Some Tool_contract.Serial)
        ()
    ; mk_record
        ~seq:3
        ~record_type:Raw_trace.Tool_execution_finished
        ~prompt:None
        ~tool_use_id:(Some "")
        ()
    ; mk_record ~seq:4 ~record_type:Raw_trace.Run_finished ~prompt:None ()
    ]
  in
  assert_tool_pairs
    ~label:"one legacy record does not collapse exact occurrences"
    ~filename:"validate_mixed_legacy.jsonl"
    ~expected:false
    records
;;

let test_validate_run_rejects_duplicate_exact_occurrence () =
  let tool_record ~seq ~record_type =
    mk_record
      ~seq
      ~record_type
      ~prompt:None
      ~tool_use_id:(Some "duplicate")
      ~tool_turn:(Some 0)
      ~tool_planned_index:(Some 0)
      ~tool_execution_mode:
        (match record_type with
         | Raw_trace.Tool_execution_started -> Some Tool_contract.Serial
         | _ -> None)
      ()
  in
  let records =
    [ mk_record ~seq:1 ~record_type:Raw_trace.Run_started ~prompt:(Some "go") ()
    ; tool_record ~seq:2 ~record_type:Raw_trace.Tool_execution_started
    ; tool_record ~seq:3 ~record_type:Raw_trace.Tool_execution_started
    ; tool_record ~seq:4 ~record_type:Raw_trace.Tool_execution_finished
    ; tool_record ~seq:5 ~record_type:Raw_trace.Tool_execution_finished
    ; mk_record ~seq:6 ~record_type:Raw_trace.Run_finished ~prompt:None ()
    ]
  in
  assert_tool_pairs
    ~label:"exact occurrence starts once"
    ~filename:"validate_duplicate_exact.jsonl"
    ~expected:false
    records
;;

(* ── read_runs ──────────────────────────────────────────────────── *)

let test_read_runs () =
  let dir = tmpdir () in
  let path = Filename.concat dir "multi_run.jsonl" in
  let records =
    [ { (mk_record ~seq:1 ()) with worker_run_id = "wr-A" }
    ; { (mk_record
           ~seq:2
           ~record_type:Raw_trace.Run_finished
           ~prompt:None
           ~final_text:(Some "a")
           ())
        with
        worker_run_id = "wr-A"
      }
    ; { (mk_record ~seq:3 ()) with worker_run_id = "wr-B" }
    ; { (mk_record
           ~seq:4
           ~record_type:Raw_trace.Run_finished
           ~prompt:None
           ~final_text:(Some "b")
           ())
        with
        worker_run_id = "wr-B"
      }
    ]
  in
  write_jsonl path records;
  match Raw_trace_query.read_runs ~path () with
  | Ok runs ->
    Alcotest.(check int) "2 runs" 2 (List.length runs);
    let first = List.hd runs in
    Alcotest.(check string) "first run is wr-A" "wr-A" first.worker_run_id;
    Alcotest.(check int) "first start_seq" 1 first.start_seq;
    Alcotest.(check int) "first end_seq" 2 first.end_seq
  | Error err ->
    Alcotest.fail (Printf.sprintf "read_runs error: %s" (Error.to_string err))
;;

(* ── Test runner ───────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Raw_trace_deep"
    [ ( "record_type"
      , [ Alcotest.test_case "to_string" `Quick test_record_type_to_string
        ; Alcotest.test_case "of_string valid" `Quick test_record_type_of_string
        ; Alcotest.test_case "of_string unknown" `Quick test_record_type_of_string_unknown
        ] )
    ; "safe_name", [ Alcotest.test_case "sanitization" `Quick test_safe_name ]
    ; ( "parse_json_via_read_all"
      , [ Alcotest.test_case "invalid json" `Quick test_read_all_invalid_json ] )
    ; ( "record_json"
      , [ Alcotest.test_case
            "run_started roundtrip"
            `Quick
            test_record_to_json_roundtrip_run_started
        ; Alcotest.test_case
            "tool_exec roundtrip"
            `Quick
            test_record_to_json_roundtrip_tool_exec
        ; Alcotest.test_case "hook roundtrip" `Quick test_record_to_json_roundtrip_hook
        ; Alcotest.test_case
            "assistant_block roundtrip"
            `Quick
            test_record_to_json_roundtrip_assistant_block
        ; Alcotest.test_case
            "run_finished roundtrip"
            `Quick
            test_record_to_json_roundtrip_run_finished
        ; Alcotest.test_case
            "all None optionals"
            `Quick
            test_record_to_json_all_none_optionals
        ; Alcotest.test_case "bad record_type" `Quick test_record_of_json_bad_type
        ] )
    ; ( "read_all"
      , [ Alcotest.test_case "empty file" `Quick test_read_all_empty_file
        ; Alcotest.test_case "with records" `Quick test_read_all_with_records
        ; Alcotest.test_case "nonexistent file" `Quick test_read_all_nonexistent_file
        ; Alcotest.test_case "blank lines" `Quick test_read_all_blank_lines
        ] )
    ; ( "record_json_edge"
      , [ Alcotest.test_case
            "all fields populated"
            `Quick
            test_record_json_all_fields_populated
        ; Alcotest.test_case
            "None fields omitted"
            `Quick
            test_record_json_none_fields_omitted
        ] )
    ; "summarize_run", [ Alcotest.test_case "full trace" `Quick test_summarize_run ]
    ; ( "validate_run"
      , [ Alcotest.test_case "passing" `Quick test_validate_run_pass
        ; Alcotest.test_case "no run_finished" `Quick test_validate_run_no_finished
        ; Alcotest.test_case
            "unmatched tool pairs"
            `Quick
            test_validate_run_unmatched_tool_pairs
        ; Alcotest.test_case
            "repeated blank ids use turn and planned index"
            `Quick
            test_validate_run_distinguishes_repeated_blank_ids_across_turns
        ; Alcotest.test_case
            "finish before start is rejected"
            `Quick
            test_validate_run_rejects_finish_before_start
        ; Alcotest.test_case
            "mixed legacy records stay separate"
            `Quick
            test_validate_run_does_not_collapse_mixed_legacy_records
        ; Alcotest.test_case
            "duplicate exact occurrences are rejected"
            `Quick
            test_validate_run_rejects_duplicate_exact_occurrence
        ] )
    ; "read_runs", [ Alcotest.test_case "multi-run file" `Quick test_read_runs ]
    ]
;;
