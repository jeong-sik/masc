open Agent_sdk
open Types

let unwrap = function
  | Ok value -> value
  | Error err -> Alcotest.fail (Error.to_string err)
;;

let with_temp_dir f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "oas-raw-trace-%d-%06x" (Unix.getpid ()) (Random.int 0xFFFFFF))
  in
  Unix.mkdir root 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" root)))
    (fun () -> f root)
;;

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len)
;;

let mock_handler _root _conn req body =
  let path = Uri.path (Cohttp.Request.uri req) in
  match path with
  | "/chat/completions" ->
    let body_str = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let json = Yojson.Safe.from_string body_str in
    let open Yojson.Safe.Util in
    let messages = json |> member "messages" |> to_list in
    let last_msg = List.hd (List.rev messages) in
    let response_body =
      match last_msg |> member "role" |> to_string with
      | "user" ->
        {|
            {"id":"raw-1","model":"test-model","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"t_read","type":"function","function":{"name":"file_read","arguments":"{\"path\":\"input.txt\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
            |}
      | "tool" ->
        let tool_use_id = last_msg |> member "tool_call_id" |> to_string in
        if tool_use_id = "t_read"
        then
          Printf.sprintf
            {|{"id":"raw-2","model":"test-model","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"t_verify_before","type":"function","function":{"name":"shell_exec","arguments":%s}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}|}
            (Yojson.Safe.to_string
               (`String
                   (Yojson.Safe.to_string
                      (`Assoc [ "command", `String "test -f input.txt && echo PASS" ]))))
        else if tool_use_id = "t_verify_before"
        then
          Printf.sprintf
            {|{"id":"raw-3","model":"test-model","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"t_write","type":"function","function":{"name":"file_write","arguments":%s}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}|}
            (Yojson.Safe.to_string
               (`String
                   (Yojson.Safe.to_string
                      (`Assoc
                          [ "path", `String "output.txt"
                          ; "content", `String "source text -> copied"
                          ]))))
        else if tool_use_id = "t_write"
        then
          Printf.sprintf
            {|{"id":"raw-4","model":"test-model","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"t_verify_after","type":"function","function":{"name":"shell_exec","arguments":%s}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}|}
            (Yojson.Safe.to_string
               (`String
                   (Yojson.Safe.to_string
                      (`Assoc
                          [ "command", `String "grep -q 'copied' output.txt && echo PASS"
                          ]))))
        else
          {|
              {"id":"raw-5","model":"test-model","choices":[{"message":{"role":"assistant","content":"trace complete"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
              |}
      | other ->
        Printf.sprintf
          {|{"id":"raw-err","model":"test-model","choices":[{"message":{"role":"assistant","content":"unexpected:%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}|}
          other
    in
    Cohttp_eio.Server.respond_string ~status:`OK ~body:response_body ()
  | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"Not found" ()
;;

let tool_names_of_records records record_type =
  records
  |> List.filter_map (fun (record : Raw_trace.record) ->
    if record.record_type = record_type then record.tool_name else None)
;;

let count_records records record_type =
  records
  |> List.filter (fun (record : Raw_trace.record) -> record.record_type = record_type)
  |> List.length
;;

let assert_monotonic_seq records =
  let rec loop expected = function
    | [] -> ()
    | (record : Raw_trace.record) :: rest ->
      Alcotest.(check int) "seq monotonic" expected record.seq;
      loop (expected + 1) rest
  in
  match records with
  | [] -> Alcotest.fail "expected raw trace records"
  | (first : Raw_trace.record) :: _ -> loop first.seq records
;;

let response_text (response : Types.api_response) =
  response.content
  |> List.filter_map (function
    | Types.Text text -> Some text
    | _ -> None)
  |> String.concat "\n"
;;

let test_agent_run_stream_append_only_raw_trace () =
  with_temp_dir
  @@ fun root ->
  let input_path = Filename.concat root "input.txt" in
  write_file input_path "source text";
  let sink =
    unwrap
      (Raw_trace.create_for_session
         ~session_root:root
         ~session_id:"sess-raw"
         ~agent_name:"raw-worker"
         ())
  in
  let trace_path = Raw_trace.file_path sink in
  let file_read_tool =
    Tool.create
      ~name:"file_read"
      ~description:"Read a file"
      ~parameters:
        [ { name = "path"
          ; description = "Relative path"
          ; param_type = String
          ; required = true
          }
        ]
      (fun input ->
         let rel = Yojson.Safe.Util.(input |> member "path" |> to_string) in
         Ok { Types.content = read_file (Filename.concat root rel); _meta = None })
  in
  let file_write_tool =
    Tool.create
      ~descriptor:(Tool.ordinary_descriptor Serial)
      ~name:"file_write"
      ~description:"Write a file"
      ~parameters:
        [ { name = "path"
          ; description = "Relative path"
          ; param_type = String
          ; required = true
          }
        ; { name = "content"
          ; description = "Content"
          ; param_type = String
          ; required = true
          }
        ]
      (fun input ->
         let rel = Yojson.Safe.Util.(input |> member "path" |> to_string) in
         let content = Yojson.Safe.Util.(input |> member "content" |> to_string) in
         write_file (Filename.concat root rel) content;
         Ok { Types.content = Printf.sprintf "wrote:%s" rel; _meta = None })
  in
  let shell_exec_tool =
    Tool.create
      ~descriptor:(Tool.ordinary_descriptor Concurrent)
      ~name:"shell_exec"
      ~description:"Run a verification command"
      ~parameters:
        [ { name = "command"
          ; description = "Command"
          ; param_type = String
          ; required = true
          }
        ]
      (fun input ->
         let command = Yojson.Safe.Util.(input |> member "command" |> to_string) in
         if String.equal command "test -f input.txt && echo PASS"
         then
           Ok
             { Types.content =
                 (if Sys.file_exists (Filename.concat root "input.txt")
                  then "PASS"
                  else "FAIL")
             ; _meta = None
             }
         else if String.equal command "grep -q 'copied' output.txt && echo PASS"
         then
           Ok
             { Types.content =
                 (if
                    Sys.file_exists (Filename.concat root "output.txt")
                    && String.equal
                         (read_file (Filename.concat root "output.txt"))
                         "source text -> copied"
                  then "PASS"
                  else "FAIL")
             ; _meta = None
             }
         else
           Error
             { Types.message = "unexpected command: " ^ command
             ; recoverable = true
             ; error_class = None
             })
  in
  let tools = [ file_read_tool; shell_exec_tool; file_write_tool ] in
  let port = 8094 in
  let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let socket =
      Eio.Net.listen
        env#net
        ~sw
        ~backlog:128
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:(mock_handler root) () in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    let options =
      { Agent.default_options with
        provider_config =
          Some
            (Provider_mock.local_provider_config
               ~base_url
               ~model_id:"test-model"
               ~request_path:"/chat/completions"
               ())
      ; raw_trace = Some sink
      }
    in
    let agent =
      Agent.create
        ~config:(Types.default_config ~model:"test-model")
        ~net:env#net
        ~tools
        ~options
        ()
    in
    let response1 = unwrap (Agent.run ~sw agent "trace chain") in
    let text1 = response_text response1 in
    Alcotest.(check string) "first final text" "trace complete" text1;
    let run1 =
      match Agent.last_raw_trace_run agent with
      | Some run -> run
      | None -> Alcotest.fail "missing first raw trace run ref"
    in
    let checkpoint = Agent.checkpoint ~session_id:"sess-raw" agent in
    let resumed = Agent.resume ~net:env#net ~checkpoint ~tools ~options () in
    let response2 = unwrap (Agent.run ~sw resumed "trace chain again") in
    let text2 = response_text response2 in
    Alcotest.(check string) "second final text" "trace complete" text2;
    let run2 =
      match Agent.last_raw_trace_run resumed with
      | Some run -> run
      | None -> Alcotest.fail "missing second raw trace run ref"
    in
    let run1_records = unwrap (Raw_trace_query.read_run run1) in
    let run2_records = unwrap (Raw_trace_query.read_run run2) in
    let all_records = unwrap (Raw_trace.read_all ~path:trace_path ()) in
    let discovered_runs = unwrap (Raw_trace_query.read_runs ~path:trace_path ()) in
    let session_runs =
      unwrap (Sessions.get_raw_trace_runs ~session_root:root ~session_id:"sess-raw" ())
    in
    let run1_from_session =
      unwrap
        (Sessions.get_raw_trace_run
           ~session_root:root
           ~session_id:"sess-raw"
           ~worker_run_id:run1.worker_run_id
           ())
    in
    let run1_records_from_session =
      unwrap
        (Sessions.get_raw_trace_records
           ~session_root:root
           ~session_id:"sess-raw"
           ~worker_run_id:run1.worker_run_id
           ())
    in
    let run1_summary =
      unwrap
        (Sessions.get_raw_trace_summary
           ~session_root:root
           ~session_id:"sess-raw"
           ~worker_run_id:run1.worker_run_id
           ())
    in
    let run1_validation =
      unwrap
        (Sessions.validate_raw_trace_run
           ~session_root:root
           ~session_id:"sess-raw"
           ~worker_run_id:run1.worker_run_id
           ())
    in
    let latest_run =
      unwrap
        (Sessions.get_latest_raw_trace_run ~session_root:root ~session_id:"sess-raw" ())
    in
    let summaries =
      unwrap
        (Sessions.get_raw_trace_summaries ~session_root:root ~session_id:"sess-raw" ())
    in
    let validations =
      unwrap
        (Sessions.get_raw_trace_validations ~session_root:root ~session_id:"sess-raw" ())
    in
    Alcotest.(check string) "trace path preserved" trace_path run1.path;
    Alcotest.(check bool)
      "run2 starts after run1 ends"
      true
      (run2.start_seq > run1.end_seq);
    Alcotest.(check int) "two discovered runs" 2 (List.length discovered_runs);
    Alcotest.(check int) "two session runs" 2 (List.length session_runs);
    Alcotest.(check bool) "latest run present" true (Option.is_some latest_run);
    Alcotest.(check string)
      "session getter worker run id"
      run1.worker_run_id
      run1_from_session.worker_run_id;
    Alcotest.(check int)
      "append only all records"
      (List.length run1_records + List.length run2_records)
      (List.length all_records);
    Alcotest.(check int)
      "session records match direct records"
      (List.length run1_records)
      (List.length run1_records_from_session);
    assert_monotonic_seq all_records;
    Alcotest.(check int)
      "run_started count"
      1
      (count_records run1_records Raw_trace.Run_started);
    Alcotest.(check int)
      "assistant block count"
      5
      (count_records run1_records Raw_trace.Assistant_block);
    Alcotest.(check int)
      "tool started count"
      4
      (count_records run1_records Raw_trace.Tool_execution_started);
    Alcotest.(check int)
      "tool finished count"
      4
      (count_records run1_records Raw_trace.Tool_execution_finished);
    Alcotest.(check int)
      "run_finished count"
      1
      (count_records run1_records Raw_trace.Run_finished);
    Alcotest.(check (list string))
      "tool start names"
      [ "file_read"; "shell_exec"; "file_write"; "shell_exec" ]
      (tool_names_of_records run1_records Raw_trace.Tool_execution_started);
    Alcotest.(check (list string))
      "tool finish names"
      [ "file_read"; "shell_exec"; "file_write"; "shell_exec" ]
      (tool_names_of_records run1_records Raw_trace.Tool_execution_finished);
    let started_records =
      List.filter
        (fun (record : Raw_trace.record) ->
           record.record_type = Raw_trace.Tool_execution_started)
        run1_records
    in
    Alcotest.(check (list (option int)))
      "planned indices"
      [ Some 0; Some 0; Some 0; Some 0 ]
      (List.map
         (fun (record : Raw_trace.record) -> record.tool_planned_index)
         started_records);
    let finished_records =
      List.filter
        (fun (record : Raw_trace.record) ->
           record.record_type = Raw_trace.Tool_execution_finished)
        run1_records
    in
    let occurrence_key (record : Raw_trace.record) =
      match record.tool_use_id, record.tool_turn, record.tool_planned_index with
      | Some id, Some turn, Some planned_index ->
        Some (Printf.sprintf "%s:%d:%d" id turn planned_index)
      | _ -> None
    in
    let started_occurrences = List.filter_map occurrence_key started_records in
    let finished_occurrences = List.filter_map occurrence_key finished_records in
    Alcotest.(check (list string))
      "finished occurrences match starts"
      started_occurrences
      finished_occurrences;
    Alcotest.(check int)
      "every start has exact occurrence fields"
      (List.length started_records)
      (List.length started_occurrences);
    let hook_occurrences =
      run1_records
      |> List.filter (fun (record : Raw_trace.record) ->
        record.record_type = Raw_trace.Hook_invoked)
      |> List.filter_map occurrence_key
      |> List.sort String.compare
    in
    let expected_hook_occurrences =
      started_occurrences
      |> List.concat_map (fun occurrence -> [ occurrence; occurrence ])
      |> List.sort String.compare
    in
    Alcotest.(check (list string))
      "tool hook records retain exact occurrence"
      expected_hook_occurrences
      hook_occurrences;
    Alcotest.(check (list (option int)))
      "finished planned indices"
      [ Some 0; Some 0; Some 0; Some 0 ]
      (List.map
         (fun (record : Raw_trace.record) -> record.tool_planned_index)
         finished_records);
    Alcotest.(check (list (option int)))
      "batch indices"
      [ Some 0; Some 0; Some 0; Some 0 ]
      (List.map
         (fun (record : Raw_trace.record) -> record.tool_batch_index)
         started_records);
    Alcotest.(check (list (option int)))
      "batch sizes"
      [ Some 1; Some 1; Some 1; Some 1 ]
      (List.map
         (fun (record : Raw_trace.record) -> record.tool_batch_size)
         started_records);
    Alcotest.(check (list (option string)))
      "execution modes"
      [ Some "serial"; Some "concurrent"; Some "serial"; Some "concurrent" ]
      (List.map
         (fun (record : Raw_trace.record) ->
            Option.map
              (fun mode ->
                 Tool_contract.execution_mode_to_yojson mode |> Yojson.Safe.Util.to_string)
              record.tool_execution_mode)
         started_records);
    let first_record = List.hd run1_records in
    Alcotest.(check (option string))
      "prompt stored"
      (Some "trace chain")
      first_record.prompt;
    Alcotest.(check bool)
      "model captured at run start"
      true
      (Option.is_some first_record.model);
    let last_record = List.hd (List.rev run1_records) in
    Alcotest.(check (option string))
      "final text stored"
      (Some "trace complete")
      last_record.final_text;
    Alcotest.(check (option string))
      "session id stored"
      (Some "sess-raw")
      last_record.session_id;
    Alcotest.(check int)
      "summary record count"
      (List.length run1_records)
      run1_summary.record_count;
    Alcotest.(check int)
      "summary tool start count"
      4
      run1_summary.tool_execution_started_count;
    Alcotest.(check int)
      "summary thinking block count"
      0
      run1_summary.thinking_block_count;
    Alcotest.(check int) "summary text block count" 1 run1_summary.text_block_count;
    Alcotest.(check int)
      "summary tool use block count"
      4
      run1_summary.tool_use_block_count;
    Alcotest.(check int)
      "summary tool result block count"
      0
      run1_summary.tool_result_block_count;
    Alcotest.(check (option string))
      "summary first assistant block kind"
      (Some "tool_use")
      run1_summary.first_assistant_block_kind;
    Alcotest.(check string)
      "summary selection outcome"
      "mixed"
      run1_summary.selection_outcome;
    Alcotest.(check bool) "summary saw_tool_use" true run1_summary.saw_tool_use;
    Alcotest.(check bool) "summary saw_thinking" false run1_summary.saw_thinking;
    Alcotest.(check int) "two summaries" 2 (List.length summaries);
    Alcotest.(check int) "two validations" 2 (List.length validations);
    Alcotest.(check bool) "validation ok" true run1_validation.ok;
    Alcotest.(check bool)
      "validation mentions tool pairs"
      true
      (List.exists
         (fun (check : Raw_trace.validation_check) ->
            String.equal check.name "tool_pairs" && check.passed)
         run1_validation.checks);
    Alcotest.(check int)
      "paired tool result count"
      4
      run1_validation.paired_tool_result_count;
    let output_path = Filename.concat root "output.txt" in
    Alcotest.(check string)
      "output file content"
      "source text -> copied"
      (read_file output_path);
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── Pure function tests (no Eio) ────────────────────────────── *)

let test_safe_name () =
  Alcotest.(check string) "normal" "agent" (Raw_trace.safe_name "agent");
  Alcotest.(check string) "spaces" "hello_world" (Raw_trace.safe_name "hello world");
  Alcotest.(check string) "slash" "a_b" (Raw_trace.safe_name "a/b");
  Alcotest.(check string) "empty" "agent" (Raw_trace.safe_name "");
  Alcotest.(check string) "whitespace" "agent" (Raw_trace.safe_name "   ")
;;

let test_record_type_to_string () =
  let cases =
    [ Raw_trace.Run_started, "run_started"
    ; Raw_trace.Assistant_block, "assistant_block"
    ; Raw_trace.Tool_execution_started, "tool_execution_started"
    ; Raw_trace.Tool_execution_finished, "tool_execution_finished"
    ; Raw_trace.Hook_invoked, "hook_invoked"
    ; Raw_trace.Run_finished, "run_finished"
    ]
  in
  List.iter
    (fun (v, expected) ->
       Alcotest.(check string) expected expected (Raw_trace.record_type_to_string v))
    cases
;;

let test_record_type_of_string () =
  let cases =
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
         Alcotest.(check string) ("roundtrip " ^ s) s (Raw_trace.record_type_to_string rt)
       | Error e -> Alcotest.fail (Error.to_string e))
    cases;
  match Raw_trace.record_type_of_string "bogus" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for bogus"
;;

let test_record_to_json_roundtrip () =
  let record : Raw_trace.record =
    { trace_version = Raw_trace.trace_version
    ; worker_run_id = "wr-test"
    ; seq = 1
    ; ts = 1700000000.0
    ; agent_name = "test-agent"
    ; session_id = Some "sess-1"
    ; record_type = Raw_trace.Run_started
    ; prompt = Some "hello"
    ; model = Some "glm-5.1"
    ; tool_choice = Some (Types.tool_choice_to_json Types.Any)
    ; enable_thinking = Some false
    ; preserve_thinking = None
    ; thinking_budget = Some 2048
    ; reasoning_effort = Some "high"
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
  let json = Raw_trace.record_to_json record in
  match Raw_trace.record_of_json json with
  | Ok decoded ->
    Alcotest.(check string) "worker_run_id" "wr-test" decoded.worker_run_id;
    Alcotest.(check int) "seq" 1 decoded.seq;
    Alcotest.(check (option string)) "session_id" (Some "sess-1") decoded.session_id;
    Alcotest.(check (option string)) "prompt" (Some "hello") decoded.prompt;
    Alcotest.(check (option string)) "model" (Some "glm-5.1") decoded.model;
    Alcotest.(check string)
      "tool_choice"
      (Yojson.Safe.to_string (Types.tool_choice_to_json Types.Any))
      (match decoded.tool_choice with
       | Some value -> Yojson.Safe.to_string value
       | None -> "");
    Alcotest.(check (option bool)) "enable_thinking" (Some false) decoded.enable_thinking;
    Alcotest.(check (option int)) "thinking_budget" (Some 2048) decoded.thinking_budget
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let test_record_of_json_rejects_invalid_tool_choice () =
  let json =
    `Assoc
      [ "trace_version", `Int Raw_trace.trace_version
      ; "worker_run_id", `String "wr-invalid"
      ; "seq", `Int 1
      ; "ts", `Float 1700000000.0
      ; "agent_name", `String "test-agent"
      ; "session_id", `Null
      ; "record_type", `String "run_started"
      ; "prompt", `String "hello"
      ; "tool_choice", `Assoc [ "type", `String "bogus" ]
      ]
  in
  Alcotest.(check bool)
    "invalid tool_choice rejected"
    true
    (Result.is_error (Raw_trace.record_of_json json))
;;

let raw_record_json
      ?(trace_version = Raw_trace.trace_version)
      ?(record_type = "run_started")
      fields
  =
  `Assoc
    ([ "trace_version", `Int trace_version
     ; "worker_run_id", `String "wr-json"
     ; "seq", `Int 1
     ; "ts", `Float 1700000000.0
     ; "agent_name", `String "test-agent"
     ; "session_id", `Null
     ; "record_type", `String record_type
     ]
     @ fields)
;;

let test_record_of_json_rejects_version_one () =
  let json = raw_record_json ~trace_version:1 [] in
  (match Raw_trace.record_of_json json with
   | Error (Error.Serialization (VersionMismatch { expected; got })) ->
     Alcotest.(check int) "expected current" Raw_trace.trace_version expected;
     Alcotest.(check int) "got old" 1 got
   | Error error -> Alcotest.fail ("unexpected error: " ^ Error.to_string error)
   | Ok _ -> Alcotest.fail "trace version 1 must be rejected");
  Alcotest.(check bool)
    "public yojson decoder also rejects old version"
    true
    (Result.is_error (Raw_trace.record_of_yojson json))
;;

let test_record_of_json_rejects_removed_descriptor_fields () =
  let assert_rejected field =
    let json = raw_record_json [ field, `String "old" ] in
    (match Raw_trace.record_of_json json with
     | Error (Error.Serialization (JsonParseError { detail })) ->
       Alcotest.(check bool)
         (field ^ " named")
         true
         (Util.string_contains ~needle:field detail)
     | Error error -> Alcotest.fail ("unexpected error: " ^ Error.to_string error)
     | Ok _ -> Alcotest.fail (field ^ " must be rejected"));
    Alcotest.(check bool)
      (field ^ " rejected by public yojson decoder")
      true
      (Result.is_error (Raw_trace.record_of_yojson json))
  in
  assert_rejected "tool_concurrency_class";
  assert_rejected "evidence_role"
;;

let test_record_of_json_requires_started_execution_mode () =
  let json =
    raw_record_json
      ~record_type:"tool_execution_started"
      [ "tool_use_id", `String "tool-1"; "tool_name", `String "lookup" ]
  in
  match Raw_trace.record_of_json json with
  | Error (Error.Serialization (JsonParseError _)) -> ()
  | Error error -> Alcotest.fail ("unexpected error: " ^ Error.to_string error)
  | Ok _ -> Alcotest.fail "tool_execution_started without execution mode must fail"
;;

let test_record_of_json_execution_modes () =
  List.iter
    (fun mode ->
       let json =
         raw_record_json
           ~record_type:"tool_execution_started"
           [ "tool_use_id", `String "tool-1"
           ; "tool_name", `String "lookup"
           ; "tool_execution_mode", Tool_contract.execution_mode_to_yojson mode
           ]
       in
       match Raw_trace.record_of_json json with
       | Ok record ->
         Alcotest.(check string)
           "mode"
           (Tool_contract.show_execution_mode mode)
           (Option.fold
              ~none:"missing"
              ~some:Tool_contract.show_execution_mode
              record.tool_execution_mode)
       | Error error -> Alcotest.fail (Error.to_string error))
    [ Tool_contract.Concurrent; Tool_contract.Serial ]
;;

let test_record_to_json_full () =
  let record : Raw_trace.record =
    { trace_version = Raw_trace.trace_version
    ; worker_run_id = "wr-full"
    ; seq = 5
    ; ts = 1700000005.0
    ; agent_name = "worker"
    ; session_id = Some "sess-2"
    ; record_type = Raw_trace.Tool_execution_finished
    ; prompt = None
    ; model = None
    ; tool_choice = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; thinking_budget = None
    ; reasoning_effort = None
    ; block_index = Some 2
    ; block_kind = Some "tool_use"
    ; assistant_block = Some (`String "block-data")
    ; tool_use_id = Some "tu-1"
    ; tool_name = Some "file_write"
    ; tool_input = Some (`Assoc [ "path", `String "/tmp/x" ])
    ; tool_turn = Some 2
    ; tool_planned_index = Some 0
    ; tool_batch_index = Some 1
    ; tool_batch_size = Some 1
    ; tool_execution_mode = None
    ; tool_result = Some "file content"
    ; tool_error = Some false
    ; hook_name = Some "pre_tool"
    ; hook_decision = Some "allow"
    ; hook_detail = Some "passed"
    ; final_text = Some "done"
    ; stop_reason = Some "end_turn"
    ; error = None
    }
  in
  let json = Raw_trace.record_to_json record in
  match Raw_trace.record_of_json json with
  | Ok decoded ->
    Alcotest.(check (option string)) "tool_name" (Some "file_write") decoded.tool_name;
    Alcotest.(check (option int)) "block_index" (Some 2) decoded.block_index;
    Alcotest.(check (option int)) "tool_turn" (Some 2) decoded.tool_turn;
    Alcotest.(check (option int)) "planned_index" (Some 0) decoded.tool_planned_index;
    Alcotest.(check (option bool)) "tool_error" (Some false) decoded.tool_error;
    Alcotest.(check (option string)) "hook_name" (Some "pre_tool") decoded.hook_name
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let test_run_ref_yojson () =
  let ref_ : Raw_trace.run_ref =
    { worker_run_id = "wr-ref"
    ; path = "/tmp/trace.jsonl"
    ; start_seq = 0
    ; end_seq = 10
    ; agent_name = "agent"
    ; session_id = Some "sess-ref"
    }
  in
  let json = Raw_trace.run_ref_to_yojson ref_ in
  match Raw_trace.run_ref_of_yojson json with
  | Ok decoded ->
    Alcotest.(check string)
      "roundtrip"
      (Raw_trace.show_run_ref ref_)
      (Raw_trace.show_run_ref decoded)
  | Error msg -> Alcotest.fail ("run_ref_of_yojson: " ^ msg)
;;

let test_run_summary_yojson () =
  let ref_ : Raw_trace.run_ref =
    { worker_run_id = "wr-sum"
    ; path = "/tmp/t.jsonl"
    ; start_seq = 0
    ; end_seq = 5
    ; agent_name = "a"
    ; session_id = None
    }
  in
  let summary : Raw_trace.run_summary =
    { run_ref = ref_
    ; record_count = 6
    ; assistant_block_count = 2
    ; tool_execution_started_count = 2
    ; tool_execution_finished_count = 2
    ; hook_invoked_count = 0
    ; hook_names = []
    ; tool_names = [ "read"; "write" ]
    ; model = Some "glm-5.1"
    ; tool_choice = Some (Types.tool_choice_to_json Types.Any)
    ; enable_thinking = Some true
    ; preserve_thinking = None
    ; thinking_budget = Some 4096
    ; reasoning_effort = Some "high"
    ; thinking_block_count = 1
    ; text_block_count = 1
    ; tool_use_block_count = 2
    ; tool_result_block_count = 2
    ; first_assistant_block_kind = Some "thinking"
    ; selection_outcome = "mixed"
    ; saw_tool_use = true
    ; saw_thinking = true
    ; final_text = Some "done"
    ; stop_reason = Some "end_turn"
    ; error = None
    ; started_at = Some 1.7e9
    ; finished_at = Some 1.7e9
    }
  in
  let json = Raw_trace.run_summary_to_yojson summary in
  match Raw_trace.run_summary_of_yojson json with
  | Ok decoded ->
    Alcotest.(check string)
      "roundtrip"
      (Raw_trace.show_run_summary summary)
      (Raw_trace.show_run_summary decoded)
  | Error msg -> Alcotest.fail ("run_summary_of_yojson: " ^ msg)
;;

let test_run_validation_yojson () =
  let ref_ : Raw_trace.run_ref =
    { worker_run_id = "wr-val"
    ; path = "/tmp/v.jsonl"
    ; start_seq = 0
    ; end_seq = 3
    ; agent_name = "v"
    ; session_id = None
    }
  in
  let validation : Raw_trace.run_validation =
    { run_ref = ref_
    ; ok = true
    ; checks = [ { name = "tool_pairs"; passed = true } ]
    ; evidence = [ "evidence1" ]
    ; paired_tool_result_count = 2
    ; final_text = Some "ok"
    ; tool_names = [ "read" ]
    ; stop_reason = Some "end_turn"
    ; failure_reason = None
    }
  in
  let json = Raw_trace.run_validation_to_yojson validation in
  match Raw_trace.run_validation_of_yojson json with
  | Ok decoded ->
    Alcotest.(check string)
      "roundtrip"
      (Raw_trace.show_run_validation validation)
      (Raw_trace.show_run_validation decoded)
  | Error msg -> Alcotest.fail ("run_validation_of_yojson: " ^ msg)
;;

let test_tool_result_assistant_block_summary () =
  Eio_main.run
  @@ fun _env ->
  with_temp_dir
  @@ fun root ->
  let sink =
    unwrap
      (Raw_trace.create_for_session
         ~session_root:root
         ~session_id:"sess-tool-result"
         ~agent_name:"raw-worker"
         ())
  in
  let active =
    unwrap
      (Raw_trace.start_run sink ~agent_name:"raw-worker" ~prompt:"tool result summary" ())
  in
  unwrap
    (Raw_trace.record_assistant_block
       active
       ~block_index:0
       (Types.ToolResult
          { tool_use_id = "tool-1"
          ; content = "ok"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }));
  ignore
    (unwrap
       (Raw_trace.finish_run
          active
          ~final_text:(Some "done")
          ~stop_reason:(Some "EndTurn")
          ~error:None));
  let runs = unwrap (Raw_trace_query.read_runs ~path:(Raw_trace.file_path sink) ()) in
  let summary = unwrap (Raw_trace_query.summarize_run (List.hd runs)) in
  Alcotest.(check int) "assistant blocks" 1 summary.assistant_block_count;
  Alcotest.(check int) "tool_result blocks" 1 summary.tool_result_block_count
;;

let () =
  Random.self_init ();
  Alcotest.run
    "Raw Trace"
    [ ( "agent_run"
      , [ Alcotest.test_case
            "append-only direct agent raw trace"
            `Quick
            test_agent_run_stream_append_only_raw_trace
        ] )
    ; ( "pure_helpers"
      , [ Alcotest.test_case "safe_name" `Quick test_safe_name
        ; Alcotest.test_case "record_type_to_string" `Quick test_record_type_to_string
        ; Alcotest.test_case "record_type_of_string" `Quick test_record_type_of_string
        ] )
    ; ( "record_json"
      , [ Alcotest.test_case "minimal roundtrip" `Quick test_record_to_json_roundtrip
        ; Alcotest.test_case
            "invalid tool_choice rejected"
            `Quick
            test_record_of_json_rejects_invalid_tool_choice
        ; Alcotest.test_case
            "version one rejected"
            `Quick
            test_record_of_json_rejects_version_one
        ; Alcotest.test_case
            "removed descriptor fields rejected"
            `Quick
            test_record_of_json_rejects_removed_descriptor_fields
        ; Alcotest.test_case
            "started mode required"
            `Quick
            test_record_of_json_requires_started_execution_mode
        ; Alcotest.test_case "execution modes" `Quick test_record_of_json_execution_modes
        ; Alcotest.test_case "full roundtrip" `Quick test_record_to_json_full
        ] )
    ; ( "type_yojson"
      , [ Alcotest.test_case "run_ref" `Quick test_run_ref_yojson
        ; Alcotest.test_case "run_summary" `Quick test_run_summary_yojson
        ; Alcotest.test_case "run_validation" `Quick test_run_validation_yojson
        ; Alcotest.test_case
            "tool_result assistant block summary"
            `Quick
            test_tool_result_assistant_block_summary
        ] )
    ]
;;
