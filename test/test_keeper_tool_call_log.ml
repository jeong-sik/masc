(** Tests for Keeper_tool_call_log — truncation, redaction, and read_recent. *)

open Masc_mcp

let eio_test name fn =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    fn ())

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
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
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
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
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
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
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
      (Observability_redact.contains_substring ~sub:"sk-proj-abcdefghijklmnop12345678" entry_str))

(* ── Model field redacted ───────────────────────────── *)

let test_model_field_stored () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:2.0
      ~model:"glm-4-9b" ();
    let entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    let entry_str = Yojson.Safe.to_string (List.hd entries) in
    Alcotest.(check bool) "raw model absent" false
      (Observability_redact.contains_substring ~sub:"glm-4-9b" entry_str);
    Alcotest.(check (option string)) "model redacted to runtime"
      (Some "runtime")
      (Safe_ops.json_string_opt "model" (List.hd entries)))

let test_policy_denied_structured_error_gets_semantic_failure () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"keeper_fs_read"
      ~input:(`Assoc [("path", `String "blocked.txt")])
      ~output_text:
        {|{"ok":false,"error":"tool_not_allowed","tool":"keeper_fs_read"}|}
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

let test_turn_context_fields_stored () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.set_turn_context
      ~keeper_name:"k"
      ~agent_name:"keeper-k-agent"
      ~lane:"tool_required"
      ~tool_choice:"required"
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
      ~tool_surface_class:"execution"
      ~visible_tool_count:2
      ~required_tools:["keeper_bash"]
      ~missing_required_tools:["keeper_fs_edit"]
      ~cascade_profile:"tool_use_strict"
      ();
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc [("path", `String "/tmp/k-sandbox/status.json")])
      ~output_text:"ok"
      ~success:true ~duration_ms:2.0 ();
    let entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    let entry = List.hd entries in
    Alcotest.(check (option string)) "lane field"
      (Some "tool_required")
      (Safe_ops.json_string_opt "lane" entry);
    Alcotest.(check (option string)) "tool_choice field"
      (Some "required")
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
    Alcotest.(check int) "turn field" 7
      (Safe_ops.json_int ~default:0 "turn" entry);
    Alcotest.(check int) "keeper_turn_id field" 7
      (Safe_ops.json_int ~default:0 "keeper_turn_id" entry);
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
    Alcotest.(check (list string)) "runtime_contract required_tools"
      ["keeper_bash"]
      Yojson.Safe.Util.(
        runtime_contract |> member "required_tools" |> to_list |> List.map to_string);
    Alcotest.(check (list string)) "runtime_contract missing_required_tools"
      ["keeper_fs_edit"]
      Yojson.Safe.Util.(
        runtime_contract |> member "missing_required_tools" |> to_list
        |> List.map to_string);
    let action_radius = Yojson.Safe.Util.member "action_radius" entry in
    Alcotest.(check (option string)) "action_radius tool"
      (Some "masc_status")
      (Safe_ops.json_string_opt "tool_name" action_radius);
    Alcotest.(check (option string)) "action_radius target path"
      (Some "/tmp/k-sandbox/status.json")
      (Safe_ops.json_string_opt "target_path" action_radius);
    Alcotest.(check bool) "action_radius success" true
      (Safe_ops.json_bool ~default:false "success" action_radius))

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
      ~tool_name:"keeper_bash"
      ~input:
        (`Assoc
           [
             ( "cmd",
               `String
                 "git push -u origin keeper/executor-direct-clone-pr-proof-20260506-1039"
             );
             ( "cwd",
               `String "repos/masc-mcp-keeper-direct-proof-20260506-1039" );
           ])
      ~output_text:
        {|{"ok":true,"via":"docker","cwd":"repos/masc-mcp-keeper-direct-proof-20260506-1039","sandbox_profile":"docker","git_creds_enabled":true,"network_mode":"bridge","effective_sandbox_image":"masc-keeper-sandbox:local","status":{"label":"success","kind":"exit","code":0},"output":"branch pushed"}|}
      ~success:true
      ~duration_ms:42.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "tool name"
        (Some "keeper_bash")
        (Safe_ops.json_string_opt "tool_name" evidence);
      Alcotest.(check (option string)) "command captured"
        (Some "git push -u origin [REDACTED]")
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
      Alcotest.(check bool) "git creds captured" true
        (Safe_ops.json_bool ~default:false "git_creds_enabled" evidence);
      Alcotest.(check (option string)) "network mode captured"
        (Some "bridge")
        (Safe_ops.json_string_opt "network_mode" evidence);
      let status = Yojson.Safe.Util.member "status" evidence in
      Alcotest.(check (option string)) "status label"
        (Some "success")
        (Safe_ops.json_string_opt "label" status)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_extracts_pr_url_from_gh_output () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"executor"
      ~tool_name:"keeper_bash"
      ~input:
        (`Assoc
           [
             ( "cmd",
               `String
                 "gh pr create --draft --title proof --body proof --base main"
             );
             ( "cwd",
               `String "repos/masc-mcp-keeper-direct-proof-20260506-1039" );
           ])
      ~output_text:
        "https://github.com/jeong-sik/masc-mcp/pull/13550\n"
      ~success:true
      ~duration_ms:10.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "pr url captured"
        (Some "https://github.com/jeong-sik/masc-mcp/pull/13550")
        (Safe_ops.json_string_opt "pr_url" evidence);
      (match Safe_ops.json_string_opt "command" evidence with
       | Some command ->
         Alcotest.(check bool) "command captured" true
           (String.starts_with ~prefix:"gh pr create" command)
       | None -> Alcotest.fail "expected command evidence")
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_stored_for_blob_backed_git_push () =
  with_tmp_log (fun () ->
    let sentinel =
      Tool_output.encode_for_oas
        (Tool_output.Stored {
          sha256 = String.make 64 'b';
          bytes = 8192;
          mime = "application/json";
          preview =
            {|{"ok":true,"via":"docker","sandbox_profile":"docker","git_creds_enabled":true,"network_mode":"bridge","effective_sandbox_image":"masc-keeper-sandbox:local","status":{"label":"success","kind":"exit","code":0},"output":"branch pushed"}|};
        })
    in
    Keeper_tool_call_log.log_call
      ~keeper_name:"executor"
      ~tool_name:"keeper_bash"
      ~input:
        (`Assoc
           [
             ("cmd", `String "git push -u origin keeper/large-route-proof");
             ("cwd", `String "repos/masc-mcp-keeper-direct-proof");
           ])
      ~output_text:sentinel
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
      Alcotest.(check bool) "git creds captured" true
        (Safe_ops.json_bool ~default:false "git_creds_enabled" evidence);
      let status = Yojson.Safe.Util.member "status" evidence in
      Alcotest.(check (option string)) "status label captured"
        (Some "success")
        (Safe_ops.json_string_opt "label" status);
      Alcotest.(check (option string)) "command captured"
        (Some "git push -u origin [REDACTED]")
        (Safe_ops.json_string_opt "command" evidence)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_skips_unproven_filesystem_calls () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"executor"
      ~tool_name:"keeper_fs_read"
      ~input:(`Assoc [ ("path", `String "README.md") ])
      ~output_text:"file contents"
      ~success:true
      ~duration_ms:4.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      Alcotest.(check bool) "route evidence absent without proof" true
        (match Yojson.Safe.Util.member "route_evidence" entry with
         | `Null -> true
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
      ~model:"glm-5.1" ~lane:"tool_required"
      ~tool_choice:"required"
      ~thinking_enabled:false ~thinking_budget:1024 ();
    Keeper_tool_call_log.log_call
      ~keeper_name:"k2" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"error: {\"ok\":false,\"error\":\"boom\"}"
      ~success:false ~duration_ms:3.0
      ~model:"qwen3.5-27b-unified" ~lane:"retry"
      ~tool_choice:"auto"
      ~thinking_enabled:true ~thinking_budget:4096 ();
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
    let by_lane = Yojson.Safe.Util.member "by_lane" summary in
    let by_thinking = Yojson.Safe.Util.member "by_thinking_mode" summary in
    let by_tool_choice = Yojson.Safe.Util.member "by_tool_choice" summary in
    let runtime_bucket = find_bucket "runtime" by_model in
    let retry_bucket = find_bucket "retry" by_lane in
    let enabled_bucket = find_bucket "enabled" by_thinking in
    let auto_bucket = find_bucket "auto" by_tool_choice in
    Alcotest.(check int) "runtime bucket calls" 2
      (Safe_ops.json_int ~default:0 "calls" runtime_bucket);
    Alcotest.(check int) "retry bucket calls" 1
      (Safe_ops.json_int ~default:0 "calls" retry_bucket);
    Alcotest.(check int) "enabled thinking calls" 1
      (Safe_ops.json_int ~default:0 "calls" enabled_bucket);
    Alcotest.(check int) "auto tool_choice calls" 1
      (Safe_ops.json_int ~default:0 "calls" auto_bucket))

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

(* ── UTF-8 sanitization ────────────────────────────── *)

(* Regression guard: tool output may contain invalid UTF-8 bytes from
   subprocess captures or truncated multi-byte sequences. Without the
   writer-side sanitize, Python / dashboard readers fail to decode the
   entire JSONL file and silently drop rows. *)
let test_output_invalid_utf8_sanitized () =
  with_tmp_log_dir (fun dir ->
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
    Alcotest.(check bool) "persisted file is valid UTF-8" true (scan 0))

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

(* When the tool output is the OCaml [%S]-quoted [masc:blob ...] sentinel
   produced by Tool_output.encode_for_oas, the persisted record must
   normalize it into a structured _blob object so that telemetry readers
   (UI, jq scripts) see a clean JSON shape instead of doubly-escaped
   string fields. *)
let test_output_blob_sentinel_normalized () =
  with_tmp_log (fun () ->
    let sentinel =
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
      ~input:(`Assoc []) ~output_text:sentinel
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
        ; eio_test "turn context fields stored" test_turn_context_fields_stored
        ; eio_test "turn context fields absent without context"
            test_turn_context_fields_absent_without_context
        ; eio_test "route evidence stored for git push"
            test_route_evidence_stored_for_git_push
        ; eio_test "route evidence extracts PR URL"
            test_route_evidence_extracts_pr_url_from_gh_output
        ; eio_test "route evidence reads blob-backed git push preview"
            test_route_evidence_stored_for_blob_backed_git_push
        ; eio_test "route evidence skips unproven filesystem calls"
            test_route_evidence_skips_unproven_filesystem_calls
        ; eio_test "dashboard aggregate groups runtime fields"
            test_dashboard_aggregate_groups_runtime_fields
        ; eio_test "dashboard hourly trend buckets numeric ts"
            test_dashboard_hourly_trend_numeric_ts
        ; eio_test "dashboard aggregate window hours"
            test_dashboard_aggregate_window_hours
        ; eio_test "append failure records coverage gap"
            test_append_failure_records_coverage_gap
        ; eio_test "dashboard aggregate surfaces coverage gap"
            test_dashboard_aggregate_surfaces_coverage_gap
        ] )
    ; ( "utf8_sanitize",
        [ eio_test "invalid UTF-8 bytes scrubbed before persist"
            test_output_invalid_utf8_sanitized
        ; eio_test "valid UTF-8 preserved verbatim"
            test_output_valid_utf8_untouched
        ] )
    ; ( "blob_normalize",
        [ eio_test "blob sentinel persists as structured _blob object"
            test_output_blob_sentinel_normalized
        ; eio_test "inline string output stays a JSON string"
            test_output_inline_string_preserved
        ] )
    ]
