open Tool_repair_loop_types

let plugin_id = "ocaml"

let default_validator_profile = function
  | Snippet -> "snippet_ocamlc"
  | Repo -> "repo_dune_build"

let system_prompt =
  String.concat "\n"
    [
      "You are a precise OCaml 5.4 coding assistant.";
      "Return only compilable OCaml code.";
      "Match the exact requested signature.";
      "Use Stdlib only unless the task explicitly asks otherwise.";
      "Prefer pattern matching and small total functions.";
      "Use `let rec` for self-recursive functions.";
      "Do not add modules, tests, comments, explanations, or Markdown fences.";
      "";
      "Example 1:";
      "Task: Write only OCaml code for map_option : ('a -> 'b) -> 'a option -> 'b option.";
      "Answer:";
      "let map_option f = function";
      "  | None -> None";
      "  | Some x -> Some (f x)";
      "";
      "Example 2:";
      "Task: Write only OCaml code for dedup_sorted : int list -> int list.";
      "Answer:";
      "let rec dedup_sorted = function";
      "  | [] -> []";
      "  | [x] -> [x]";
      "  | x :: (y :: _ as rest) ->";
      "      if x = y then dedup_sorted rest else x :: dedup_sorted rest";
    ]

let build_generate_prompt ~(task_spec : string) =
  String.concat "\n"
    [
      "Write only OCaml code for the following task.";
      "";
      task_spec;
      "";
      "Constraints:";
      "- Return only code.";
      "- If the function calls itself, the definition must start with `let rec`.";
      "- Produce exactly one top-level definition unless the task explicitly requires more.";
    ]

let build_repair_prompt ~(task_spec : string) ~(previous_code : string)
    ~(validator_output : string) =
  String.concat "\n"
    [
      "Write only corrected OCaml code for the following task.";
      "";
      task_spec;
      "";
      "The previous answer failed validation.";
      "";
      "Previous code:";
      previous_code;
      "";
      "Validator output:";
      validator_output;
      "";
      "Fix the code with the minimal necessary changes.";
      "Keep the exact requested signature.";
      "If the function calls itself, the definition must start with `let rec`.";
      "Return only corrected OCaml code.";
    ]

let strip_markdown_fences text =
  let trimmed = String.trim text in
  if String.length trimmed < 6 then trimmed
  else if String.sub trimmed 0 3 <> "```" then trimmed
  else
    let lines = String.split_on_char '\n' trimmed in
    match lines with
    | [] -> trimmed
    | _opening :: rest ->
        (* Collect lines until the first closing fence ``` *)
        let rec collect_until_closing acc = function
          | [] -> List.rev acc
          | line :: tl ->
              if String.trim line = "```" then List.rev acc
              else collect_until_closing (line :: acc) tl
        in
        let body = collect_until_closing [] rest in
        if body = [] then trimmed
        else String.concat "\n" body

let validator_output_text (result : validator_result) =
  let stdout = String.trim result.stdout in
  let stderr = String.trim result.stderr in
  match stdout, stderr with
  | "", "" -> Printf.sprintf "exit_code=%d" result.exit_code
  | "", _ -> stderr
  | _, "" -> stdout
  | _ ->
      Printf.sprintf "stdout:\n%s\n\nstderr:\n%s" stdout stderr

let run_validator ?clock ~(cwd : string) ~(timeout_sec : int) argv :
    validator_result =
  let started_at = Time_compat.now () in
  let result =
    match argv with
    | [] ->
        {
          Tool_command_plane_support.exit_code = 127;
          stdout = "";
          stderr = "empty argv";
        }
    | prog :: _ ->
        Tool_command_plane_support.run_process_with_timeout
          ~clock_opt:clock ~timeout_sec ~prog ~argv
          ~env:(Unix.environment ()) ()
  in
  {
    command = argv;
    cwd;
    exit_code = result.exit_code;
    stdout = result.stdout;
    stderr = result.stderr;
    timed_out = result.exit_code = 124;
    duration_sec = Time_compat.now () -. started_at;
  }

let write_attempt_result config loop_id attempt_index code validation =
  ignore
    (Tool_repair_loop_storage.write_attempt_aux config loop_id attempt_index
       "validator.json"
       (Yojson.Safe.pretty_to_string (validator_result_to_json validation)));
  Tool_repair_loop_storage.write_attempt_code config loop_id attempt_index code

let run_snippet_validation (ctx : _ context) (state : state) ~attempt_index
    ~(code : string) =
  let code_path =
    write_attempt_result ctx.config state.loop_id attempt_index code
      {
        command = [];
        cwd = state.working_dir;
        exit_code = 1;
        stdout = "";
        stderr = "";
        timed_out = false;
        duration_sec = 0.0;
      }
  in
  let argv = [ "ocamlc"; "-c"; code_path ] in
  let validation =
    run_validator ?clock:ctx.clock ~cwd:state.working_dir ~timeout_sec:15 argv
  in
  ignore
    (Tool_repair_loop_storage.write_attempt_aux ctx.config state.loop_id
       attempt_index "validator.json"
       (Yojson.Safe.pretty_to_string (validator_result_to_json validation)));
  (code_path, validation)

let absolute_target_path working_dir target_file =
  if Filename.is_relative target_file then Filename.concat working_dir target_file
  else target_file

let run_repo_validation (ctx : _ context) (state : state) ~attempt_index
    ~(target_file : string) ~(code : string) =
  let target_path = absolute_target_path state.working_dir target_file in
  let original = Tool_repair_loop_storage.maybe_read_file target_path in
  let code_path =
    Tool_repair_loop_storage.write_attempt_code ctx.config state.loop_id
      attempt_index code
  in
  Fs_compat.mkdir_p (Filename.dirname target_path);
  Fs_compat.save_file target_path code;
  (* Use --root flag to ensure dune build runs in the correct directory *)
  let argv = [ "dune"; "build"; "--root"; state.working_dir ] in
  let validation =
    Fun.protect
      ~finally:(fun () ->
        Tool_repair_loop_storage.restore_file target_path original)
      (fun () ->
        run_validator ?clock:ctx.clock ~cwd:state.working_dir ~timeout_sec:120
          argv)
  in
  ignore
    (Tool_repair_loop_storage.write_attempt_aux ctx.config state.loop_id
       attempt_index "validator.json"
       (Yojson.Safe.pretty_to_string (validator_result_to_json validation)));
  (code_path, validation)

let validate_candidate (ctx : _ context) (state : state) ~attempt_index
    ~(phase : attempt_phase) ~(code : string) : attempt_record =
  let started_at = Time_compat.now () in
  let normalized = strip_markdown_fences code in
  let code_path, validation =
    match state.validator_profile, state.target_file with
    | "repo_dune_build", Some target_file ->
        run_repo_validation ctx state ~attempt_index ~target_file ~code:normalized
    | _ -> run_snippet_validation ctx state ~attempt_index ~code:normalized
  in
  let finished_at = Time_compat.now () in
  let summary =
    if validation.exit_code = 0 then "validation passed"
    else if validation.timed_out then "validator timed out"
    else Printf.sprintf "validation failed (exit=%d)" validation.exit_code
  in
  {
    attempt_index;
    phase;
    started_at;
    finished_at;
    code_path;
    code_preview = preview normalized;
    validation;
    classification = Attempt_repairable;
    summary;
  }

let classify_attempt (state : state) (attempt : attempt_record) =
  let previous_attempt =
    match List.rev state.attempts with
    | previous :: _ -> Some previous
    | [] -> None
  in
  let previous_error_signature =
    Option.map
      (fun previous -> validator_output_text previous.validation)
      previous_attempt
  in
  let current_error_signature = validator_output_text attempt.validation in
  let same_code_as_previous =
    match previous_attempt with
    | Some previous -> String.equal previous.code_preview attempt.code_preview
    | None -> false
  in
  if attempt.validation.exit_code = 0 then
    (Attempt_passed, Passed, None)
  else if attempt.validation.timed_out then
    (Attempt_timed_out, Timed_out, Some "validator timed out")
  else if attempt.attempt_index >= state.max_attempts then
    ( Attempt_terminal,
      Terminal_failure,
      Some "max attempts reached before validation passed" )
  else if same_code_as_previous then
    (Attempt_terminal, Terminal_failure, Some "identical code produced twice")
  else if
    match previous_error_signature with
    | Some previous -> String.equal current_error_signature previous
    | None -> false
  then
    ( Attempt_terminal,
      Terminal_failure,
      Some "validator returned the same failure twice" )
  else
    (Attempt_repairable, Repairable_failure, Some current_error_signature)
