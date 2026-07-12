(** Tests for Keeper_tool_call_log — truncation, redaction, and read_recent. *)

open Masc

let eio_test name fn =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    fn ())

let eio_env_test name fn =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    fn env)

let counter = ref 0

let with_tmp_log f =
  incr counter;
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test-keeper-tool-call-log-%d-%d-%d"
       (Unix.getpid ()) !counter
       (int_of_float (Unix.gettimeofday () *. 1000.0))) in
  Fs_compat.mkdir_p dir;
  Keeper_tool_call_log.reset_for_testing ();
  Keeper_tool_call_log.init ~base_path:dir ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      Fs_compat.remove_tree dir)
    (fun () -> f ())

let with_tmp_log_dir f =
  incr counter;
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test-keeper-tool-call-log-%d-%d-%d"
       (Unix.getpid ()) !counter
       (int_of_float (Unix.gettimeofday () *. 1000.0))) in
  Fs_compat.mkdir_p dir;
  Keeper_tool_call_log.reset_for_testing ();
  Keeper_tool_call_log.init ~base_path:dir ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      Fs_compat.remove_tree dir)
    (fun () -> f dir)

let with_tmp_corrupt_tool_call_store f =
  incr counter;
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test-keeper-tool-call-log-corrupt-%d-%d-%d"
       (Unix.getpid ()) !counter
       (int_of_float (Unix.gettimeofday () *. 1000.0))) in
  let masc_root = Filename.concat dir ".masc" in
  Fs_compat.mkdir_p masc_root;
  Fs_compat.save_file (Filename.concat masc_root "tool_calls") "not a directory";
  Keeper_tool_call_log.reset_for_testing ();
  Keeper_tool_call_log.init ~base_path:dir ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      Fs_compat.remove_tree dir)
    (fun () -> f ~dir ~masc_root)

(* ── read_recent edge cases ─────────────────────────── *)

let test_read_recent_n_zero () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_a"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:1.0 ();
    let result = Keeper_tool_call_log.read_recent ~n:0 () in
    Alcotest.(check int) "n=0 returns empty" 0 (List.length result))

let test_read_recent_n_negative () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_a"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:1.0 ();
    let result = Keeper_tool_call_log.read_recent ~n:(-1) () in
    Alcotest.(check int) "n<0 returns empty" 0 (List.length result))

let test_read_recent_keeper_filter () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"alice" ~tool_name:"tool_x"
      ~input:(`Assoc []) ~output_text:"out"
      ~success:true ~duration_ms:5.0 ();
    Keeper_tool_call_log.log_call
      ~keeper_name:"bob" ~tool_name:"tool_y"
      ~input:(`Assoc []) ~output_text:"out"
      ~success:true ~duration_ms:5.0 ();
    let alice_entries = Keeper_tool_call_log.read_recent ~keeper_name:"alice" () in
    let bob_entries = Keeper_tool_call_log.read_recent ~keeper_name:"bob" () in
    let all_entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "alice gets 1 entry" 1 (List.length alice_entries);
    Alcotest.(check int) "bob gets 1 entry" 1 (List.length bob_entries);
    Alcotest.(check int) "all gets 2 entries" 2 (List.length all_entries))

(* ── Redaction: denied tools are skipped ────────────── *)

let test_denied_tool_not_logged () =
  with_tmp_log (fun () ->
    (* tool name containing "_auth" infix is denied by Observability_redact *)
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"mcp_auth_create"
      ~input:(`Assoc [("token", `String "secret123")]) ~output_text:"done"
      ~success:true ~duration_ms:1.0 ();
    let result = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "denied tool not logged" 0 (List.length result))

(* ── Redaction: sensitive fields stripped ────────────── *)

let test_sensitive_input_fields_redacted () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc [
        ("token", `String "sk-proj-abcdefghijklmnop12345678");
        ("content", `String "hello");
      ])
      ~output_text:"done"
      ~success:true ~duration_ms:1.0 ();
    let entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "one entry logged" 1 (List.length entries);
    let entry_str = Yojson.Safe.to_string (List.hd entries) in
    Alcotest.(check bool) "token value redacted" false
      (String_util.contains_substring entry_str "sk-proj-abcdefghijklmnop12345678"))

(* ── Model field redacted ───────────────────────────── *)

let test_model_field_stored () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:2.0
      ~model:"glm-4-9b"
      ~runtime_profile:"local_qwen3_27b_only"
      ();
    let entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    let entry_str = Yojson.Safe.to_string (List.hd entries) in
    Alcotest.(check bool) "raw model absent" false
      (String_util.contains_substring entry_str "glm-4-9b");
    Alcotest.(check (option string)) "model redacted to runtime"
      (Some "runtime")
      (Safe_ops.json_string_opt "model" (List.hd entries));
    Alcotest.(check (option string)) "runtime profile stored"
      (Some "local_qwen3_27b_only")
      (Safe_ops.json_string_opt "runtime_profile" (List.hd entries)))

let test_policy_denied_structured_error_gets_semantic_failure () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_read_file"
      ~input:(`Assoc [("path", `String "blocked.txt")])
      ~output_text:
        {|{"ok":false,"error":"tool_not_allowed","tool":"tool_read_file"}|}
      ~success:true ~duration_ms:1.0 ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    let entry = List.hd entries in
    Alcotest.(check bool) "transport success preserved" true
      (Safe_ops.json_bool ~default:false "success" entry);
    Alcotest.(check bool) "semantic success is false" false
      (Safe_ops.json_bool ~default:true "semantic_success" entry);
    Alcotest.(check (option string)) "semantic outcome"
      (Some "policy_denied")
      (Safe_ops.json_string_opt "semantic_outcome" entry);
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    Alcotest.(check int) "dashboard semantic success count" 0
      (Safe_ops.json_int ~default:(-1) "success" summary);
    Alcotest.(check int) "dashboard semantic failure count" 1
      (Safe_ops.json_int ~default:(-1) "failure" summary);
    let failure_category =
      summary
      |> Yojson.Safe.Util.member "failure_categories"
      |> Yojson.Safe.Util.to_list
      |> List.hd
    in
    Alcotest.(check (option string)) "failure category"
      (Some "policy_denied")
      (Safe_ops.json_string_opt "category" failure_category))

let test_structured_ok_overrides_transport_failure_for_semantic_success () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_execute"
      ~input:(`Assoc [ "cmd", `String "rg missing lib" ])
      ~output_text:
        {|{"ok":true,"semantic_status":"no_match","summary":"Search completed with no matches."}|}
      ~success:false ~duration_ms:1.0 ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    let entry = List.hd entries in
    Alcotest.(check bool) "transport failure preserved" false
      (Safe_ops.json_bool ~default:true "success" entry);
    Alcotest.(check bool) "semantic success follows structured output" true
      (Safe_ops.json_bool ~default:false "semantic_success" entry);
    Alcotest.(check (option string)) "semantic outcome"
      (Some "no_match")
      (Safe_ops.json_string_opt "semantic_outcome" entry))

let test_blocked_structured_output_keeps_semantic_category () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_execute"
      ~input:(`Assoc [ "cmd", `String "git log --oneline | head -5" ])
      ~output_text:
        {|{"ok":false,"error":"tool_execute_command_shape_blocked","failure_class":"workflow_rejection","semantic_status":"blocked","shape_block":"pipe_or_redirect"}|}
      ~success:false ~duration_ms:1.0 ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    let entry = List.hd entries in
    Alcotest.(check bool) "semantic success is false" false
      (Safe_ops.json_bool ~default:true "semantic_success" entry);
    Alcotest.(check (option string)) "semantic outcome"
      (Some "blocked")
      (Safe_ops.json_string_opt "semantic_outcome" entry);
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    let failure_category =
      summary
      |> Yojson.Safe.Util.member "failure_categories"
      |> Yojson.Safe.Util.to_list
      |> List.hd
    in
    Alcotest.(check (option string)) "failure category keeps shape tag"
      (Some "shape_block:pipe_or_redirect")
      (Safe_ops.json_string_opt "category" failure_category))

let test_turn_context_fields_stored () =
  with_tmp_log (fun () ->
    (* Mirrors the production reader (keeper_hooks_oas): context is
       written to a per-run cell, read back as a record, and passed
       explicitly to log_call — there is no ambient fallback. *)
    let cell = Keeper_tool_call_log.create_turn_ctx_cell () in
    Keeper_tool_call_log.set_turn_context
      ~cell
      ~agent_name:"keeper-k-agent"
      ~lane:"tool_optional"
      ~tool_choice:"auto"
      ~thinking_enabled:false
      ~thinking_budget:1024
      ~prompt_fingerprint:"prompt-fp-k"
      ~trace_id:"trace-k"
      ~session_id:"trace-k"
      ~generation:3
      ~turn:7
      ~keeper_turn_id:7
      ~task_id:"task-runtime-trust"
      ~goal_ids:["goal-short"; "goal-long"]
      ~sandbox_profile:"docker"
      ~sandbox_root:"/tmp/k-sandbox"
      ~allowed_paths:["/tmp/k-sandbox"; "/tmp/shared"]
      ~network_mode:"inherit"
      ~approval_mode:"manual"
      ~runtime_profile:"tool_use_strict"
      ();
    let tctx : Keeper_tool_call_log_context.turn_context =
      Keeper_tool_call_log_context.get_turn_context_record ~cell ()
    in
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc [("path", `String "/tmp/k-sandbox/status.json")])
      ~output_text:"ok"
      ~success:true ~duration_ms:2.0
      ?agent_name:tctx.agent_name
      ?lane:tctx.lane ?tool_choice:tctx.tool_choice
      ?thinking_enabled:tctx.thinking_enabled
      ?thinking_budget:tctx.thinking_budget
      ?prompt_fingerprint:tctx.prompt_fingerprint
      ?trace_id:tctx.trace_id ?session_id:tctx.session_id
      ?generation:tctx.generation
      ?turn:tctx.turn ?keeper_turn_id:tctx.keeper_turn_id
      ?task_id:tctx.task_id ?goal_ids:tctx.goal_ids
      ?sandbox_profile:tctx.sandbox_profile
      ?sandbox_root:tctx.sandbox_root
      ?allowed_paths:tctx.allowed_paths
      ?network_mode:tctx.network_mode
      ?approval_mode:tctx.approval_mode
      ?runtime_profile:tctx.runtime_profile
      ();
    let entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    let entry = List.hd entries in
    Alcotest.(check (option string)) "lane field"
      (Some "tool_optional")
      (Safe_ops.json_string_opt "lane" entry);
    Alcotest.(check (option string)) "tool_choice field"
      (Some "auto")
      (Safe_ops.json_string_opt "tool_choice" entry);
    Alcotest.(check bool) "thinking_enabled present" true
      (match Yojson.Safe.Util.member "thinking_enabled" entry with
       | `Bool false -> true
       | _ -> false);
    Alcotest.(check int) "thinking_budget field" 1024
      (Safe_ops.json_int ~default:0 "thinking_budget" entry);
    Alcotest.(check (option string)) "prompt_fingerprint field"
      (Some "prompt-fp-k")
      (Safe_ops.json_string_opt "prompt_fingerprint" entry);
    Alcotest.(check (option string)) "trace_id field"
      (Some "trace-k")
      (Safe_ops.json_string_opt "trace_id" entry);
    Alcotest.(check (option string)) "session_id field"
      (Some "trace-k")
      (Safe_ops.json_string_opt "session_id" entry);
    Alcotest.(check int) "generation field" 3
      (Safe_ops.json_int ~default:0 "generation" entry);
    Alcotest.(check int) "turn field" 7
      (Safe_ops.json_int ~default:0 "turn" entry);
    Alcotest.(check int) "keeper_turn_id field" 7
      (Safe_ops.json_int ~default:0 "keeper_turn_id" entry);
    Alcotest.(check (option string)) "runtime_profile field"
      (Some "tool_use_strict")
      (Safe_ops.json_string_opt "runtime_profile" entry);
    Alcotest.(check (option string)) "task_id field"
      (Some "task-runtime-trust")
      (Safe_ops.json_string_opt "task_id" entry);
    Alcotest.(check (list string)) "goal_ids field"
      ["goal-short"; "goal-long"]
      Yojson.Safe.Util.(entry |> member "goal_ids" |> to_list |> List.map to_string);
    Alcotest.(check (option string)) "sandbox_profile field"
      (Some "docker")
      (Safe_ops.json_string_opt "sandbox_profile" entry);
    Alcotest.(check (option string)) "network_mode field"
      (Some "inherit")
      (Safe_ops.json_string_opt "network_mode" entry);
    Alcotest.(check (option string)) "approval_mode field"
      (Some "manual")
      (Safe_ops.json_string_opt "approval_mode" entry);
    let runtime_contract =
      Yojson.Safe.Util.member "runtime_contract" entry
    in
    Alcotest.(check (option string)) "runtime_contract keeper"
      (Some "k")
      (Safe_ops.json_string_opt "keeper_name" runtime_contract);
    Alcotest.(check (option string)) "runtime_contract agent"
      (Some "keeper-k-agent")
      (Safe_ops.json_string_opt "agent_name" runtime_contract);
    Alcotest.(check int) "runtime_contract generation" 3
      (Safe_ops.json_int ~default:0 "generation" runtime_contract);
    Alcotest.(check (list string)) "runtime_contract allowed_paths"
      ["/tmp/k-sandbox"; "/tmp/shared"]
      Yojson.Safe.Util.(
        runtime_contract |> member "allowed_paths" |> to_list |> List.map to_string);
    let path_resolution =
      Yojson.Safe.Util.member "path_resolution" runtime_contract
    in
    Alcotest.(check bool)
      "runtime contract explains Execute repo cwd path basis"
      true
      (String_util.contains_substring
         Yojson.Safe.Util.(member "execute_path_basis" path_resolution |> to_string)
         "do not repeat the repo prefix");
    Alcotest.(check bool)
      "runtime contract points .masc state at task/context tools"
      true
      (String_util.contains_substring
         Yojson.Safe.Util.(member "masc_state_basis" path_resolution |> to_string)
         "Use keeper task/context tools");
    let omits_field name =
      match runtime_contract with
      | `Assoc fields -> not (List.mem_assoc name fields)
      | _ -> false
    in
    Alcotest.(check bool) "runtime_contract omits required_tools" true
      (omits_field "required_tools");
    Alcotest.(check bool) "runtime_contract omits required_tool_candidates" true
      (omits_field "required_tool_candidates");
    Alcotest.(check bool) "runtime_contract omits missing_required_tools" true
      (omits_field "missing_required_tools");
    Alcotest.(check (option string)) "runtime_contract runtime_profile"
      (Some "tool_use_strict")
      (Safe_ops.json_string_opt "runtime_profile" runtime_contract);
    let action_radius = Yojson.Safe.Util.member "action_radius" entry in
    Alcotest.(check (option string)) "action_radius tool"
      (Some "masc_status")
      (Safe_ops.json_string_opt "tool_name" action_radius);
    Alcotest.(check (option string)) "action_radius target path"
      (Some "/tmp/k-sandbox/status.json")
      (Safe_ops.json_string_opt "target_path" action_radius);
    Alcotest.(check bool) "action_radius success" true
      (Safe_ops.json_bool ~default:false "success" action_radius))

(* RFC-0225 §3.3 regression: two runs of the SAME keeper each carry their
   own cell — setting one must not disturb the other. Under the previous
   keeper_name-keyed global the second set overwrote the first and the
   first run's tool calls were logged with the second run's identity. *)
let test_turn_context_cells_do_not_cross_runs () =
  let cell_a = Keeper_tool_call_log.create_turn_ctx_cell () in
  let cell_b = Keeper_tool_call_log.create_turn_ctx_cell () in
  Keeper_tool_call_log.set_turn_context
    ~cell:cell_a ~trace_id:"trace-a" ~keeper_turn_id:1 ();
  Keeper_tool_call_log.set_turn_context
    ~cell:cell_b ~trace_id:"trace-b" ~keeper_turn_id:2 ();
  let ctx_a : Keeper_tool_call_log_context.turn_context =
    Keeper_tool_call_log_context.get_turn_context_record ~cell:cell_a ()
  in
  let ctx_b : Keeper_tool_call_log_context.turn_context =
    Keeper_tool_call_log_context.get_turn_context_record ~cell:cell_b ()
  in
  Alcotest.(check (option string)) "run A keeps its trace_id"
    (Some "trace-a") ctx_a.trace_id;
  Alcotest.(check (option int)) "run A keeps its keeper_turn_id"
    (Some 1) ctx_a.keeper_turn_id;
  Alcotest.(check (option string)) "run B keeps its trace_id"
    (Some "trace-b") ctx_b.trace_id;
  Alcotest.(check (option int)) "run B keeps its keeper_turn_id"
    (Some 2) ctx_b.keeper_turn_id;
  let fresh : Keeper_tool_call_log_context.turn_context =
    Keeper_tool_call_log_context.get_turn_context_record
      ~cell:(Keeper_tool_call_log.create_turn_ctx_cell ()) ()
  in
  Alcotest.(check (option string)) "fresh cell reads empty" None
    fresh.trace_id

let test_turn_context_fields_absent_without_context () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:2.0 ();
    let entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    let entry = List.hd entries in
    Alcotest.(check (option string)) "lane absent"
      None
      (Safe_ops.json_string_opt "lane" entry);
    Alcotest.(check (option string)) "tool_choice absent"
      None
      (Safe_ops.json_string_opt "tool_choice" entry);
    Alcotest.(check bool) "thinking_enabled absent" true
      (match Yojson.Safe.Util.member "thinking_enabled" entry with
       | `Null -> true
       | _ -> false);
    Alcotest.(check bool) "thinking_budget absent" true
      (match Yojson.Safe.Util.member "thinking_budget" entry with
       | `Null -> true
       | _ -> false);
    Alcotest.(check bool) "prompt_fingerprint absent" true
      (match Yojson.Safe.Util.member "prompt_fingerprint" entry with
       | `Null -> true
       | _ -> false);
    Alcotest.(check bool) "trace_id absent" true
      (match Yojson.Safe.Util.member "trace_id" entry with
       | `Null -> true
       | _ -> false);
    Alcotest.(check bool) "session_id absent" true
      (match Yojson.Safe.Util.member "session_id" entry with
       | `Null -> true
       | _ -> false);
    Alcotest.(check bool) "turn absent" true
      (match Yojson.Safe.Util.member "turn" entry with
       | `Null -> true
       | _ -> false))

let test_route_evidence_stored_for_git_push () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"executor"
      ~tool_name:"tool_execute"
      ~input:
        (`Assoc
           [
             ("executable", `String "git");
             ( "argv",
               `List
                 [
                   `String "push";
                   `String "-u";
                   `String "origin";
                   `String "keeper/executor-direct-clone-pr-proof-20260506-1039";
                 ] );
             ( "cwd",
               `String "repos/masc-keeper-direct-proof-20260506-1039" );
           ])
      ~output_text:
        {|{"ok":true,"via":"docker","cwd":"repos/masc-keeper-direct-proof-20260506-1039","sandbox_profile":"docker","network_mode":"bridge","status":{"label":"success","kind":"exit","code":0},"output":"branch pushed"}|}
      ~success:true
      ~duration_ms:42.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "tool name"
        (Some "tool_execute")
        (Safe_ops.json_string_opt "tool_name" evidence);
      Alcotest.(check (option string)) "descriptor id"
        (Some "agent.execute")
        (Safe_ops.json_string_opt "descriptor_id" evidence);
      Alcotest.(check (option string)) "public name"
        (Some "Execute")
        (Safe_ops.json_string_opt "public_name" evidence);
      Alcotest.(check (option string)) "canonical name"
        (Some "tool_execute")
        (Safe_ops.json_string_opt "canonical_name" evidence);
      Alcotest.(check (option string)) "command captured"
        (Some "[REDACTED]")
        (Safe_ops.json_string_opt "command" evidence);
      Alcotest.(check (option string)) "cwd captured"
        (Some "[REDACTED]")
        (Safe_ops.json_string_opt "cwd" evidence);
      Alcotest.(check (option string)) "via captured"
        (Some "docker")
        (Safe_ops.json_string_opt "via" evidence);
      Alcotest.(check (option string)) "sandbox profile captured"
        (Some "docker")
        (Safe_ops.json_string_opt "sandbox_profile" evidence);
      Alcotest.(check (option string)) "network mode captured"
        (Some "bridge")
        (Safe_ops.json_string_opt "network_mode" evidence);
      let status = Yojson.Safe.Util.member "status" evidence in
      Alcotest.(check (option string)) "status label"
        (Some "success")
        (Safe_ops.json_string_opt "label" status)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_stored_for_blob_backed_git_push () =
  with_tmp_log (fun () ->
    let marker =
      Tool_output.encode_for_oas
        (Tool_output.Stored {
          sha256 = String.make 64 'b';
          bytes = 8192;
          mime = "application/json";
          preview =
            {|{"ok":true,"via":"docker","sandbox_profile":"docker","network_mode":"bridge","status":{"label":"success","kind":"exit","code":0},"output":"branch pushed"}|};
        })
    in
    Keeper_tool_call_log.log_call
      ~keeper_name:"executor"
      ~tool_name:"tool_execute"
      ~input:
        (`Assoc
           [
             ("executable", `String "git");
             ( "argv",
               `List
                 [
                   `String "push";
                   `String "-u";
                   `String "origin";
                   `String "keeper/large-route-proof";
                 ] );
             ("cwd", `String "repos/masc-keeper-direct-proof");
           ])
      ~output_text:marker
      ~success:true
      ~duration_ms:42.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "via captured from blob preview"
        (Some "docker")
        (Safe_ops.json_string_opt "via" evidence);
      Alcotest.(check (option string)) "network mode captured"
        (Some "bridge")
        (Safe_ops.json_string_opt "network_mode" evidence);
      let status = Yojson.Safe.Util.member "status" evidence in
      Alcotest.(check (option string)) "status label captured"
        (Some "success")
        (Safe_ops.json_string_opt "label" status);
      Alcotest.(check (option string)) "command captured"
        (Some "[REDACTED]")
        (Safe_ops.json_string_opt "command" evidence)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_redacts_wrapped_git_push () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"executor"
      ~tool_name:"tool_execute"
      ~input:
        (`Assoc
           [
             ( "cmd",
               `String
                 "env FOO=bar git -C repos/private-worktree push origin feature/private-proof"
             );
           ])
      ~output_text:
        {|{"ok":true,"via":"docker","sandbox_profile":"docker","network_mode":"bridge","status":{"label":"success","kind":"exit","code":0},"output":"branch pushed"}|}
      ~success:true
      ~duration_ms:42.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "wrapped command redacted"
        (Some "[REDACTED]")
        (Safe_ops.json_string_opt "command" evidence)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_command_redaction_fails_closed () =
  let commands =
    [
      "git push --repo /Users/dancer/private origin feature/private-proof";
      "git push --repo=/Users/dancer/private origin feature/private-proof";
      "git -c safe.directory=/Users/dancer/private push origin feature/private-proof";
      "env FOO=bar git push origin 'feature/private proof'";
    ]
  in
  List.iter
    (fun command ->
       with_tmp_log (fun () ->
         Keeper_tool_call_log.log_call
           ~keeper_name:"executor"
           ~tool_name:"tool_execute"
           ~input:(`Assoc [ ("cmd", `String command) ])
           ~output_text:
             {|{"ok":true,"via":"docker","sandbox_profile":"docker","network_mode":"bridge","status":{"label":"success","kind":"exit","code":0},"output":"branch pushed"}|}
           ~success:true
           ~duration_ms:42.0
           ();
         match Keeper_tool_call_log.read_recent ~n:1 () with
         | [ entry ] ->
           let evidence = Yojson.Safe.Util.member "route_evidence" entry in
           Alcotest.(check (option string))
             "command is fail-closed"
             (Some "[REDACTED]")
             (Safe_ops.json_string_opt "command" evidence);
           let evidence_text = Yojson.Safe.to_string evidence in
           Alcotest.(check bool)
             "absolute path is absent"
             false
             (String_util.contains_substring evidence_text "/Users/dancer");
           Alcotest.(check bool)
             "private branch marker is absent"
             false
             (String_util.contains_substring evidence_text "private-proof")
           ;
           Alcotest.(check bool)
             "quoted private branch marker is absent"
             false
             (String_util.contains_substring evidence_text "private proof")
         | _ -> Alcotest.fail "expected exactly one entry"))
    commands
;;

let test_route_evidence_records_descriptor_for_filesystem_calls () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"executor"
      ~tool_name:"Read"
      ~input:(`Assoc [ ("file_path", `String "README.md") ])
      ~output_text:"file contents"
      ~success:true
      ~duration_ms:4.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "tool name"
        (Some "Read")
        (Safe_ops.json_string_opt "tool_name" evidence);
      Alcotest.(check (option string)) "descriptor id"
        (Some "agent.read_file")
        (Safe_ops.json_string_opt "descriptor_id" evidence);
      Alcotest.(check (option string)) "public name"
        (Some "Read")
        (Safe_ops.json_string_opt "public_name" evidence);
      Alcotest.(check (option string)) "canonical name"
        (Some "tool_read_file")
        (Safe_ops.json_string_opt "canonical_name" evidence);
      Alcotest.(check (option string)) "executor"
        (Some "filesystem")
        (Safe_ops.json_string_opt "executor" evidence);
      Alcotest.(check (option string)) "backend"
        (Some "sandbox_process")
        (Safe_ops.json_string_opt "backend" evidence);
      Alcotest.(check (option string)) "sandbox"
        (Some "backend_selected")
        (Safe_ops.json_string_opt "sandbox" evidence)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_records_internal_descriptor () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"executor"
      ~tool_name:"keeper_time_now"
      ~input:(`Assoc [])
      ~output_text:
        {|{"ok":true,"iso":"2026-05-26T00:00:00Z","epoch":1780000000}|}
      ~success:true
      ~duration_ms:1.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "tool name"
        (Some "keeper_time_now")
        (Safe_ops.json_string_opt "tool_name" evidence);
      Alcotest.(check (option string)) "descriptor id"
        (Some "keeper.time.now")
        (Safe_ops.json_string_opt "descriptor_id" evidence);
      Alcotest.(check (option string)) "public name"
        (Some "keeper_time_now")
        (Safe_ops.json_string_opt "public_name" evidence);
      Alcotest.(check (option string)) "canonical name"
        (Some "keeper_time_now")
        (Safe_ops.json_string_opt "canonical_name" evidence);
      Alcotest.(check (option string)) "executor"
        (Some "in_process")
        (Safe_ops.json_string_opt "executor" evidence);
      Alcotest.(check (option string)) "backend"
        (Some "ocaml_runtime")
        (Safe_ops.json_string_opt "backend" evidence);
      Alcotest.(check (option string)) "sandbox"
        (Some "none")
        (Safe_ops.json_string_opt "sandbox" evidence);
      Alcotest.(check (option string)) "runtime handler"
        (Some "tool_time_now")
        (Safe_ops.json_string_opt "runtime_handler" evidence)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_records_masc_board_descriptor () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"executor"
      ~tool_name:"mcp__masc__masc_board_post"
      ~input:(`Assoc [ "body", `String "descriptor evidence test" ])
      ~output_text:{|{"ok":true,"post_id":"post-1"}|}
      ~success:true
      ~duration_ms:2.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "tool name"
        (Some "mcp__masc__masc_board_post")
        (Safe_ops.json_string_opt "tool_name" evidence);
      Alcotest.(check (option string)) "descriptor id"
        (Some "masc.board.post")
        (Safe_ops.json_string_opt "descriptor_id" evidence);
      Alcotest.(check (option string)) "public name"
        (Some "masc_board_post")
        (Safe_ops.json_string_opt "public_name" evidence);
      Alcotest.(check (option string)) "canonical name"
        (Some "masc_board_post")
        (Safe_ops.json_string_opt "canonical_name" evidence);
      Alcotest.(check (option string)) "executor"
        (Some "in_process")
        (Safe_ops.json_string_opt "executor" evidence);
      Alcotest.(check (option string)) "effect domain"
        (Some "masc_workspace")
        (Safe_ops.json_string_opt "effect_domain" evidence);
      Alcotest.(check (option string)) "runtime handler"
        (Some "tool_masc_board_dispatch")
        (Safe_ops.json_string_opt "runtime_handler" evidence)
    | _ -> Alcotest.fail "expected exactly one entry")

let route_evidence_for_tool tool_name =
  match
    Keeper_tool_call_log.route_evidence_json_of_tool_io
      ~tool_name
      ~input:(`Assoc [])
      ~output_text:"{}"
  with
  | Some evidence -> evidence
  | None -> Alcotest.failf "missing route evidence for %s" tool_name
;;

let check_eval_tags tool_name expected =
  let evidence = route_evidence_for_tool tool_name in
  Alcotest.(check (list string))
    (tool_name ^ " eval tags")
    expected
    (Safe_ops.json_string_list "eval_tags" evidence)
;;

let test_route_evidence_records_descriptor_eval_tags () =
  check_eval_tags "keeper_tools_list" [ "capability_introspection" ];
  check_eval_tags "keeper_tool_search" [ "capability_introspection" ];
  check_eval_tags "keeper_surface_read" [ "surface_context_read" ];
  check_eval_tags "masc_agent_card" [ "agent_profile_lookup" ];
  check_eval_tags "keeper_time_now" []
;;

let test_non_object_input_still_logs_action_radius () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"executor"
      ~tool_name:"tool_write_file"
      ~input:(`String "raw pre-tool gate payload")
      ~output_text:"approval_required:governance_approval"
      ~success:false
      ~duration_ms:3.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let action_radius = Yojson.Safe.Util.member "action_radius" entry in
      Alcotest.(check (option string)) "action key falls back to tool"
        (Some "tool_write_file")
        (Safe_ops.json_string_opt "action_key" action_radius);
      Alcotest.(check (option string)) "target kind falls back to tool"
        (Some "tool")
        (Safe_ops.json_string_opt "target_kind" action_radius);
      Alcotest.(check bool) "input preserved as string" true
        (match Yojson.Safe.Util.member "input" entry with
         | `String "raw pre-tool gate payload" -> true
         | _ -> false)
    | _ -> Alcotest.fail "expected exactly one entry")

let find_bucket name json =
  json
  |> Yojson.Safe.Util.to_list
  |> List.find (fun item ->
         Safe_ops.json_string_opt "name" item = Some name)

let test_dashboard_aggregate_groups_runtime_fields () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k1" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:2.0
      ~model:"glm-5.1" ~lane:"tool_optional"
      ~tool_choice:"auto"
      ~thinking_enabled:false ~thinking_budget:1024
      ~runtime_profile:"primary" ();
    Keeper_tool_call_log.log_call
      ~keeper_name:"k2" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"error: {\"ok\":false,\"error\":\"boom\"}"
      ~success:false ~duration_ms:3.0
      ~model:"qwen3.5-27b-unified" ~lane:"retry"
      ~tool_choice:"auto"
      ~thinking_enabled:true ~thinking_budget:4096
      ~runtime_profile:"local_qwen3_27b_only" ();
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    Alcotest.(check (option string)) "sampling mode present"
      (Some "recent_n")
      (Safe_ops.json_string_opt "sampling_mode" summary);
    Alcotest.(check int) "sample limit echoed" 10
      (Safe_ops.json_int ~default:0 "sample_limit" summary);
    Alcotest.(check (option string)) "dashboard source"
      (Some "tool_call_io")
      (Safe_ops.json_string_opt "source" summary);
    Alcotest.(check (option string)) "dashboard producer"
      (Some "keeper_hooks_oas|mcp_server_eio_call_tool")
      (Safe_ops.json_string_opt "producer" summary);
    Alcotest.(check (option string)) "dashboard surface"
      (Some "/api/v1/dashboard/tool-quality")
      (Safe_ops.json_string_opt "dashboard_surface" summary);
    Alcotest.(check bool) "dashboard durable store present" true
      (Safe_ops.json_string ~default:"" "durable_store" summary <> "");
    Alcotest.(check int) "source entry count" 2
      (Safe_ops.json_int ~default:0 "entry_count" summary);
    Alcotest.(check bool) "source store exists" true
      (Safe_ops.json_bool ~default:false "exists" summary);
    Alcotest.(check (option string)) "source health ok"
      (Some "ok")
      (Safe_ops.json_string_opt "health" summary);
    Alcotest.(check bool) "latest age present" true
      (Safe_ops.json_float_opt "latest_age_s" summary |> Option.is_some);
    let by_model = Yojson.Safe.Util.member "by_model" summary in
    let by_runtime = Yojson.Safe.Util.member "by_runtime" summary in
    let by_lane = Yojson.Safe.Util.member "by_lane" summary in
    let by_thinking = Yojson.Safe.Util.member "by_thinking_mode" summary in
    let by_tool_choice = Yojson.Safe.Util.member "by_tool_choice" summary in
    let runtime_bucket = find_bucket "runtime" by_model in
    let primary_runtime_bucket = find_bucket "primary" by_runtime in
    let local_runtime_bucket = find_bucket "local_qwen3_27b_only" by_runtime in
    let retry_bucket = find_bucket "retry" by_lane in
    let enabled_bucket = find_bucket "enabled" by_thinking in
    let auto_bucket = find_bucket "auto" by_tool_choice in
    Alcotest.(check int) "runtime bucket calls" 2
      (Safe_ops.json_int ~default:0 "calls" runtime_bucket);
    Alcotest.(check int) "primary runtime bucket calls" 1
      (Safe_ops.json_int ~default:0 "calls" primary_runtime_bucket);
    Alcotest.(check int) "local runtime bucket calls" 1
      (Safe_ops.json_int ~default:0 "calls" local_runtime_bucket);
    Alcotest.(check int) "retry bucket calls" 1
      (Safe_ops.json_int ~default:0 "calls" retry_bucket);
    Alcotest.(check int) "enabled thinking calls" 1
      (Safe_ops.json_int ~default:0 "calls" enabled_bucket);
    Alcotest.(check int) "auto tool_choice calls" 2
      (Safe_ops.json_int ~default:0 "calls" auto_bucket))

let test_dashboard_failure_concentration () =
  with_tmp_log (fun () ->
    let rec log_failures keeper_name remaining =
      if remaining > 0 then begin
        Keeper_tool_call_log.log_call
          ~keeper_name ~tool_name:"masc_status"
          ~input:(`Assoc []) ~output_text:"error: {\"ok\":false,\"error\":\"boom\"}"
          ~success:false ~duration_ms:1.0 ();
        log_failures keeper_name (remaining - 1)
      end
    in
    log_failures "alpha" 6;
    log_failures "beta" 3;
    log_failures "gamma" 1;
    let concentration =
      Dashboard_http_tool_quality.aggregate ~n:10 ()
      |> Yojson.Safe.Util.member "failure_concentration"
    in
    (match Safe_ops.json_float_opt "top2_pct" concentration with
    | Some percentage ->
      Alcotest.(check (float 0.01)) "top two failure percentage" 90.0 percentage
    | None -> Alcotest.fail "missing top two failure percentage");
    Alcotest.(check (list string)) "top two keepers"
      [ "alpha"; "beta" ]
      (Safe_ops.json_string_list "top2_keepers" concentration))

let test_dashboard_aggregate_missing_runtime_profile_is_unknown () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k-missing-runtime"
      ~tool_name:"masc_status"
      ~input:(`Assoc [])
      ~output_text:"ok"
      ~success:true
      ~duration_ms:1.0
      ();
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    let by_runtime = Yojson.Safe.Util.member "by_runtime" summary in
    let unknown_bucket =
      find_bucket Dashboard_http_tool_quality.unknown_runtime_profile_bucket by_runtime
    in
    Alcotest.(check int)
      "missing runtime profile goes to unknown bucket"
      1
      (Safe_ops.json_int ~default:0 "calls" unknown_bucket))

let test_dashboard_hourly_trend_numeric_ts () =
  with_tmp_log_dir (fun dir ->
    let store =
      Dated_jsonl.create
        ~base_dir:(Filename.concat dir ".masc/tool_calls")
        ()
    in
    let ts = 1_710_000_000 in
    Dated_jsonl.append store
      (`Assoc
         [ ("ts", `Int ts)
         ; ("keeper", `String "k")
         ; ("tool", `String "masc_status")
         ; ("input", `Assoc [])
         ; ("output", `String "ok")
         ; ("success", `Bool true)
         ; ("duration_ms", `Float 2.0)
         ]);
    let expected_hour =
      let tm = Unix.gmtime (Float.of_int ts) in
      Printf.sprintf "%04d-%02d-%02dT%02d"
        (tm.Unix.tm_year + 1900)
        (tm.Unix.tm_mon + 1)
        tm.Unix.tm_mday
        tm.Unix.tm_hour
    in
    let hourly =
      Dashboard_http_tool_quality.aggregate ~n:10 ()
      |> Yojson.Safe.Util.member "hourly_trend"
      |> Yojson.Safe.Util.to_list
    in
    let bucket =
      List.find (fun item ->
        Safe_ops.json_string_opt "hour" item = Some expected_hour
      ) hourly
    in
    Alcotest.(check int) "hour bucket calls" 1
      (Safe_ops.json_int ~default:0 "calls" bucket);
    Alcotest.(check int) "hour bucket success" 1
      (Safe_ops.json_int ~default:0 "success" bucket))

let test_dashboard_aggregate_window_hours () =
  with_tmp_log_dir (fun dir ->
    let store =
      Dated_jsonl.create
        ~base_dir:(Filename.concat dir ".masc/tool_calls")
        ()
    in
    let now = Unix.gettimeofday () in
    let inside = now -. (30.0 *. 60.0) in
    let outside = now -. (48.0 *. 3600.0) in
    Dated_jsonl.append store
      (`Assoc
         [ ("ts", `Float inside)
         ; ("keeper", `String "k")
         ; ("tool", `String "masc_status")
         ; ("input", `Assoc [])
         ; ("output", `String "ok")
         ; ("success", `Bool true)
         ; ("duration_ms", `Float 2.0)
         ]);
    Dated_jsonl.append store
      (`Assoc
         [ ("ts", `Float outside)
         ; ("keeper", `String "k")
         ; ("tool", `String "masc_status")
         ; ("input", `Assoc [])
         ; ("output", `String "error: {\"ok\":false,\"error\":\"stale\"}")
         ; ("success", `Bool false)
         ; ("duration_ms", `Float 5.0)
         ]);
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 ~window_hours:24.0 () in
    Alcotest.(check (option string)) "window sampling mode"
      (Some "window_hours")
      (Safe_ops.json_string_opt "sampling_mode" summary);
    Alcotest.(check int) "window total" 1
      (Safe_ops.json_int ~default:0 "total" summary);
    Alcotest.(check (option int)) "sample limit omitted"
      None
      (Safe_ops.json_int_opt "sample_limit" summary);
    Alcotest.(check (option (float 0.0001))) "window echoed"
      (Some 24.0)
      (Safe_ops.json_float_opt "window_hours" summary))

let test_append_failure_records_coverage_gap () =
  with_tmp_corrupt_tool_call_store (fun ~dir:_ ~masc_root ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:2.0
      ~trace_id:"trace-gap" ();
    let gaps = Telemetry_coverage_gap.read_recent ~masc_root ~n:10 in
    Alcotest.(check int) "one coverage gap" 1 (List.length gaps);
    match gaps with
    | [ gap ] ->
      Alcotest.(check (option string)) "coverage source"
        (Some "tool_call_io")
        (Safe_ops.json_string_opt "source" gap);
      Alcotest.(check (option string)) "coverage stale reason"
        (Some "tool_call_io_append_failed")
        (Safe_ops.json_string_opt "stale_reason" gap);
      Alcotest.(check (option string)) "coverage keeper"
        (Some "k")
        (Safe_ops.json_string_opt "keeper_name" gap);
      Alcotest.(check (option string)) "coverage trace"
        (Some "trace-gap")
      (Safe_ops.json_string_opt "trace_id" gap)
    | _ -> Alcotest.fail "expected exactly one coverage gap")

let test_dashboard_aggregate_surfaces_coverage_gap () =
  with_tmp_log_dir (fun dir ->
    let masc_root = Filename.concat dir ".masc" in
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"tool_call_io"
      ~producer:"keeper_hooks_oas"
      ~durable_store:(Filename.concat masc_root "tool_calls")
      ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
      ~stale_reason:"tool_call_io_append_failed"
      ~keeper_name:"k"
      ~trace_id:"trace-gap"
      ();
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    Alcotest.(check (option string)) "coverage gap health"
      (Some "coverage_gap")
      (Safe_ops.json_string_opt "health" summary);
    Alcotest.(check (option string)) "coverage gap stale reason"
      (Some "tool_call_io_append_failed")
      (Safe_ops.json_string_opt "stale_reason" summary);
    Alcotest.(check int) "coverage gap count" 1
      (Safe_ops.json_int ~default:0 "coverage_gap_count" summary))

let test_dashboard_aggregate_ignores_recovered_coverage_gap () =
  with_tmp_log_dir (fun dir ->
    let masc_root = Filename.concat dir ".masc" in
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"tool_call_io"
      ~producer:"keeper_hooks_oas"
      ~durable_store:(Filename.concat masc_root "tool_calls")
      ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
      ~stale_reason:"tool_call_io_append_failed"
      ~keeper_name:"k"
      ~trace_id:"trace-gap"
      ();
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:2.0
      ~trace_id:"trace-recovered" ();
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    Alcotest.(check (option string)) "recovered gap health"
      (Some "ok")
      (Safe_ops.json_string_opt "health" summary);
    Alcotest.(check (option string)) "recovered gap stale reason cleared"
      None
      (Safe_ops.json_string_opt "stale_reason" summary);
    Alcotest.(check int) "historical gap count" 1
      (Safe_ops.json_int ~default:0 "coverage_gap_count" summary);
    Alcotest.(check int) "active gap count" 0
      (Safe_ops.json_int ~default:(-1) "active_coverage_gap_count" summary))

(* ── UTF-8 sanitization ────────────────────────────── *)

(* Regression guard: tool output may contain invalid UTF-8 bytes from
   subprocess captures or truncated multi-byte sequences. Without the
   writer-side sanitize, Python / dashboard readers fail to decode the
   entire JSONL file and silently drop rows. *)
let test_output_invalid_utf8_sanitized () =
  with_tmp_log_dir (fun dir ->
    Safe_ops.reset_persistence_utf8_repair_stats_for_tests ();
    let raw_output = "prefix\xecsuffix" in
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_bin"
      ~input:(`Assoc []) ~output_text:raw_output
      ~success:true ~duration_ms:1.0 ();
    let results = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length results);
    let today =
      let open Unix in
      let tm = gmtime (gettimeofday ()) in
      Printf.sprintf "%04d-%02d/%02d.jsonl"
        (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    in
    let file =
      Filename.concat dir (Filename.concat ".masc/tool_calls" today)
    in
    let contents =
      let ic = open_in_bin file in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        let n = in_channel_length ic in
        really_input_string ic n)
    in
    let len = String.length contents in
    let rec scan i =
      if i >= len then true
      else
        let dec = String.get_utf_8_uchar contents i in
        let dlen = Uchar.utf_decode_length dec in
        if dlen > 0 && Uchar.utf_decode_is_valid dec then scan (i + dlen)
        else false
    in
    Alcotest.(check bool) "persisted file is valid UTF-8" true (scan 0);
    let repair_stats = Safe_ops.persistence_utf8_repair_stats () in
    Alcotest.(check int)
      "writer-side tool output parsing does not emit persistence repair"
      0
      repair_stats.repaired_reads)

let test_output_valid_utf8_untouched () =
  with_tmp_log (fun () ->
    let korean = "한글 메시지" in
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_ok"
      ~input:(`Assoc []) ~output_text:korean
      ~success:true ~duration_ms:1.0 ();
    let results = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length results);
    match results with
    | [ json ] ->
        let output = Safe_ops.json_string ~default:"" "output" json in
        Alcotest.(check string) "valid UTF-8 preserved verbatim" korean output
    | _ -> Alcotest.fail "expected exactly one entry")

(* When the tool output is the OCaml [%S]-quoted [masc:blob ...] marker
   produced by Tool_output.encode_for_oas, the persisted record must
   normalize it into a structured _blob object so that telemetry readers
   (UI, jq scripts) see a clean JSON shape instead of doubly-escaped
   string fields. *)
let test_output_blob_marker_normalized () =
  with_tmp_log (fun () ->
    let marker =
      Tool_output.encode_for_oas
        (Tool_output.Stored {
          sha256 = String.make 64 'a';
          bytes = 6436;
          mime = "text/plain";
          preview = "{\"ok\":true,\"result\":\"42\"}";
        })
    in
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_blob"
      ~input:(`Assoc []) ~output_text:marker
      ~success:true ~duration_ms:1.0 ();
    let results = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length results);
    match results with
    | [ json ] ->
      let output =
        match json with
        | `Assoc fields -> List.assoc_opt "output" fields
        | _ -> None
      in
      (match output with
       | Some (`Assoc [("_blob", `Assoc blob)]) ->
         let sha = Safe_ops.json_string ~default:"" "sha256" (`Assoc blob) in
         let bytes = Safe_ops.json_int ~default:0 "bytes" (`Assoc blob) in
         let mime = Safe_ops.json_string ~default:"" "mime" (`Assoc blob) in
         let preview = Safe_ops.json_string ~default:"" "preview" (`Assoc blob) in
         Alcotest.(check string) "sha256 round-trips" (String.make 64 'a') sha;
         Alcotest.(check int) "bytes round-trips" 6436 bytes;
         Alcotest.(check string) "mime round-trips" "text/plain" mime;
         Alcotest.(check string) "preview round-trips"
           "{\"ok\":true,\"result\":\"42\"}" preview
       | Some (`String s) ->
         Alcotest.failf "expected normalized _blob object, got string: %s" s
       | _ -> Alcotest.fail "missing/unexpected output field")
    | _ -> Alcotest.fail "expected exactly one entry")

(* Inline outputs (below the externalization threshold) must stay as
   plain JSON strings so legacy jq pipelines and the UI's string-render
   path keep working. *)
let test_output_inline_string_preserved () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_inline"
      ~input:(`Assoc []) ~output_text:"small inline result"
      ~success:true ~duration_ms:1.0 ();
    let results = Keeper_tool_call_log.read_recent ~n:1 () in
    match results with
    | [ json ] ->
      let s = Safe_ops.json_string ~default:"" "output" json in
      Alcotest.(check string) "inline output stays a string"
        "small inline result" s
    | _ -> Alcotest.fail "expected exactly one entry")

let test_string_input_keeps_action_radius () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_large_input"
      ~input:(`String "{\"action\":\"write\"}")
      ~output_text:"ok"
      ~success:true ~duration_ms:1.0 ();
    let results = Keeper_tool_call_log.read_recent ~n:1 () in
    match results with
    | [ json ] ->
      let action_radius =
        match json with
        | `Assoc fields ->
          Option.value (List.assoc_opt "action_radius" fields) ~default:`Null
        | _ -> `Null
      in
      let action_key =
        Safe_ops.json_string ~default:"" "action_key" action_radius
      in
      let target_kind =
        Safe_ops.json_string ~default:"" "target_kind" action_radius
      in
      Alcotest.(check string)
        "falls back when input is not a JSON object"
        "tool_large_input"
        action_key;
      Alcotest.(check string) "non-object input has tool target" "tool" target_kind
    | _ -> Alcotest.fail "expected exactly one entry")

let test_async_append_defers_until_flush env =
  with_tmp_log_dir (fun _dir ->
    Eio.Switch.run (fun sw ->
      Keeper_tool_call_log.start_flush_fiber
        ~sw
        ~clock:(Eio.Stdenv.clock env);
      Keeper_tool_call_log.log_call
        ~keeper_name:"async-k"
        ~tool_name:"masc_status"
        ~input:(`Assoc [])
        ~output_text:"ok"
        ~success:true
        ~duration_ms:1.0
        ();
      Alcotest.(check int)
        "record queued before background flush"
        1
        (Keeper_tool_call_log.queued_count_for_testing ());
      Alcotest.(check int)
        "queued record not visible before explicit flush"
        0
        (List.length (Keeper_tool_call_log.read_recent ~n:1 ()));
      Keeper_tool_call_log.flush_now ();
      Alcotest.(check int)
        "queue drained by explicit flush"
        0
        (Keeper_tool_call_log.queued_count_for_testing ());
      let entries = Keeper_tool_call_log.read_recent ~n:1 () in
      Alcotest.(check int) "record persisted after flush" 1 (List.length entries);
      match entries with
      | [ entry ] ->
        Alcotest.(check (option string))
          "keeper persisted"
          (Some "async-k")
          (Safe_ops.json_string_opt "keeper" entry)
      | _ -> Alcotest.fail "expected exactly one entry"))

let () =
  Alcotest.run "keeper_tool_call_log"
    [ ( "read_recent",
        [ eio_test "n=0 returns []" test_read_recent_n_zero
        ; eio_test "n<0 returns []" test_read_recent_n_negative
        ; eio_test "keeper filter" test_read_recent_keeper_filter
        ] )
    ; ( "redaction",
        [ eio_test "denied tool not logged" test_denied_tool_not_logged
        ; eio_test "sensitive input fields redacted" test_sensitive_input_fields_redacted
        ; eio_test "model field stored" test_model_field_stored
        ; eio_test "policy denied is semantic failure"
            test_policy_denied_structured_error_gets_semantic_failure
        ; eio_test "structured ok overrides transport failure"
            test_structured_ok_overrides_transport_failure_for_semantic_success
        ; eio_test "blocked output keeps semantic category"
            test_blocked_structured_output_keeps_semantic_category
        ; eio_test "turn context fields stored" test_turn_context_fields_stored
        ; Alcotest.test_case "turn context cells do not cross runs" `Quick
            test_turn_context_cells_do_not_cross_runs
        ; eio_test "turn context fields absent without context"
            test_turn_context_fields_absent_without_context
        ; eio_test "route evidence stored for git push"
            test_route_evidence_stored_for_git_push
        ; eio_test "route evidence reads blob-backed git push preview"
            test_route_evidence_stored_for_blob_backed_git_push
        ; eio_test "route evidence redacts wrapped git push"
            test_route_evidence_redacts_wrapped_git_push
        ; eio_test "route evidence command redaction fails closed"
            test_route_evidence_command_redaction_fails_closed
        ; eio_test "route evidence records descriptor for filesystem calls"
            test_route_evidence_records_descriptor_for_filesystem_calls
        ; eio_test "route evidence records internal descriptor"
            test_route_evidence_records_internal_descriptor
        ; eio_test "route evidence records masc board descriptor"
            test_route_evidence_records_masc_board_descriptor
        ; Alcotest.test_case
            "route evidence records descriptor eval tags"
            `Quick
            test_route_evidence_records_descriptor_eval_tags
        ; eio_test "non-object input still logs action radius"
            test_non_object_input_still_logs_action_radius
        ; eio_test "dashboard aggregate groups runtime fields"
            test_dashboard_aggregate_groups_runtime_fields
        ; eio_test "dashboard failure concentration"
            test_dashboard_failure_concentration
        ; eio_test "dashboard aggregate marks missing runtime profile unknown"
            test_dashboard_aggregate_missing_runtime_profile_is_unknown
        ; eio_test "dashboard hourly trend buckets numeric ts"
            test_dashboard_hourly_trend_numeric_ts
        ; eio_test "dashboard aggregate window hours"
            test_dashboard_aggregate_window_hours
        ; eio_test "append failure records coverage gap"
            test_append_failure_records_coverage_gap
        ; eio_test "dashboard aggregate surfaces coverage gap"
            test_dashboard_aggregate_surfaces_coverage_gap
        ; eio_test "dashboard aggregate ignores recovered coverage gap"
            test_dashboard_aggregate_ignores_recovered_coverage_gap
        ] )
    ; ( "utf8_sanitize",
        [ eio_test "invalid UTF-8 bytes scrubbed before persist"
            test_output_invalid_utf8_sanitized
        ; eio_test "valid UTF-8 preserved verbatim"
            test_output_valid_utf8_untouched
        ] )
    ; ( "blob_normalize",
        [ eio_test "blob marker persists as structured _blob object"
            test_output_blob_marker_normalized
        ; eio_test "inline string output stays a JSON string"
            test_output_inline_string_preserved
        ] )
    ; ( "action_radius",
        [ eio_test "string input does not break action radius"
            test_string_input_keeps_action_radius
        ] )
    ; ( "async_append",
        [ eio_env_test "append queues until flush when async fiber is active"
            test_async_append_defers_until_flush
        ] )
    ]
