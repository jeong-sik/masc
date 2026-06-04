open Alcotest

module TDR = Masc.Tool_deep_review

let contains_substring text pattern =
  let pat_len = String.length pattern in
  let text_len = String.length text in
  let rec loop i =
    if i + pat_len > text_len then false
    else if String.sub text i pat_len = pattern then true
    else loop (i + 1)
  in
  pat_len > 0 && loop 0

let rec mkdir_p path =
  if path = "" || path = "." || Sys.file_exists path then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)

let with_temp_dir f =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tool_deep_review_%d_%f" (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  mkdir_p base;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base)
    (fun () -> f base)

let write_file path content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc content;
  close_out oc

let test_build_prompt_accepts_code_files () =
  with_temp_dir (fun base ->
      let file = Filename.concat base "lib/foo.ml" in
      write_file file "let answer = 42\n";
      match
        TDR.build_prompt
          ~target_files:[ "lib/foo.ml" ]
          ~question:"Is this safe?"
          ~base_path:base
      with
      | Ok prompt ->
          check bool "contains file path" true
            (contains_substring prompt "lib/foo.ml")
      | Error e -> failf "expected Ok, got Error: %s" e)

let test_build_prompt_accepts_governance_source_files () =
  with_temp_dir (fun base ->
      let file = Filename.concat base "lib/governance_pipeline.ml" in
      write_file file "let governance_level = \"development\"\n";
      match
        TDR.build_prompt
          ~target_files:[ "lib/governance_pipeline.ml" ]
          ~question:"Find correctness issues"
          ~base_path:base
      with
      | Ok prompt ->
          check bool "contains governance source path" true
            (contains_substring prompt "lib/governance_pipeline.ml")
      | Error e -> failf "expected Ok, got Error: %s" e)

let test_build_prompt_rejects_design_docs_by_full_path () =
  with_temp_dir (fun base ->
      let file = Filename.concat base "docs/design/contract-driven-agent-loop-rfc.md" in
      write_file file "# RFC\n";
      match
        TDR.build_prompt
          ~target_files:[ "docs/design/contract-driven-agent-loop-rfc.md" ]
          ~question:"Find bugs"
          ~base_path:base
      with
      | Error msg ->
          check bool "mentions rejected" true
            (String.length msg > 0)
      | Ok _ -> fail "expected design doc to be rejected")

let test_build_prompt_rejects_rfc_docs_outside_docs_dir () =
  with_temp_dir (fun base ->
      let file = Filename.concat base "tmp/contract-driven-agent-loop-rfc.md" in
      write_file file "# RFC\n";
      match
        TDR.build_prompt
          ~target_files:[ "tmp/contract-driven-agent-loop-rfc.md" ]
          ~question:"Find bugs"
          ~base_path:base
      with
      | Error msg ->
          check bool "mentions rejected" true
            (String.length msg > 0)
      | Ok _ -> fail "expected RFC doc to be rejected")

let test_build_prompt_rejects_task_state_history_paths () =
  with_temp_dir (fun base ->
      let file = Filename.concat base "memory/task-state-history.jsonl" in
      write_file file "{}\n";
      match
        TDR.build_prompt
          ~target_files:[ "memory/task-state-history.jsonl" ]
          ~question:"Find issues"
          ~base_path:base
      with
      | Error msg ->
          check bool "mentions rejected" true
            (String.length msg > 0)
      | Ok _ -> fail "expected workspace/task history to be rejected")

let make_run_result text : Masc.Runtime_agent.run_result =
  let response : Agent_sdk.Types.api_response =
    { id = "fake-review"
    ; model = "unit-test"
    ; stop_reason = Agent_sdk.Types.EndTurn
    ; content = [ Agent_sdk.Types.Text text ]
    ; usage = None
    ; telemetry = None
    }
  in
  { response
  ; checkpoint = None
  ; session_id = "fake-session"
  ; turns = 1
  ; trace_ref = None
  ; run_validation = None
  ; runtime_observation = None
  ; stop_reason = Masc.Runtime_agent.Completed
  }

let test_handle_deep_review_uses_injected_runner () =
  with_temp_dir (fun base ->
      let file = Filename.concat base "lib/foo.ml" in
      write_file file "let answer = 42\n";
      let config = Masc.Workspace.default_config base in
      let seen_prompt = ref None in
      let run_review ~prompt =
        seen_prompt := Some prompt;
        Ok (make_run_result "NO_ISSUES_FOUND")
      in
      let args =
        `Assoc
          [ "target_files", `List [ `String "lib/foo.ml" ]
          ; "question", `String "Is this safe?"
          ]
      in
      let result =
        TDR.handle_deep_review
          ~tool_name:"masc_deep_review"
          ~start_time:0.0
          config
          ~run_review
          args
      in
      check bool "success" true (Tool_result.is_success result);
      check bool "prompt contains file" true
        (match !seen_prompt with
         | Some prompt -> contains_substring prompt "lib/foo.ml"
         | None -> false);
      match Tool_result.data result with
      | `Assoc fields ->
          check (option string) "verdict" (Some "no_issues")
            (match List.assoc_opt "verdict" fields with
             | Some (`String verdict) -> Some verdict
             | _ -> None)
      | _ -> fail "expected structured result data")

let () =
  run "tool_deep_review"
    [
      ( "build_prompt",
        [
          test_case "accept code files" `Quick test_build_prompt_accepts_code_files;
          test_case "accept governance source files" `Quick
            test_build_prompt_accepts_governance_source_files;
          test_case "reject design docs by full path" `Quick
            test_build_prompt_rejects_design_docs_by_full_path;
          test_case "reject rfc docs outside docs dir" `Quick
            test_build_prompt_rejects_rfc_docs_outside_docs_dir;
            test_case "reject task state history" `Quick
              test_build_prompt_rejects_task_state_history_paths;
        ] );
      ( "handle_deep_review",
        [
          test_case "uses injected runner" `Quick
            test_handle_deep_review_uses_injected_runner;
        ] );
    ]
