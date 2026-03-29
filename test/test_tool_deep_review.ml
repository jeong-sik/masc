open Alcotest

module TDR = Masc_mcp.Tool_deep_review

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
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" base)))
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
          check bool "contains file section" true
            (String.contains prompt '=')
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

let test_build_prompt_rejects_room_task_history_paths () =
  with_temp_dir (fun base ->
      let file = Filename.concat base "memory/room-task-history.jsonl" in
      write_file file "{}\n";
      match
        TDR.build_prompt
          ~target_files:[ "memory/room-task-history.jsonl" ]
          ~question:"Find issues"
          ~base_path:base
      with
      | Error msg ->
          check bool "mentions rejected" true
            (String.length msg > 0)
      | Ok _ -> fail "expected room/task history to be rejected")

let () =
  run "tool_deep_review"
    [
      ( "build_prompt",
        [
          test_case "accept code files" `Quick test_build_prompt_accepts_code_files;
          test_case "reject design docs by full path" `Quick
            test_build_prompt_rejects_design_docs_by_full_path;
          test_case "reject room/task history" `Quick
            test_build_prompt_rejects_room_task_history_paths;
        ] );
    ]
