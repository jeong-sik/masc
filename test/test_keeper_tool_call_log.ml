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
  Keeper_tool_call_log.init ~base_path:dir;
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f ())

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

(* ── Model field preserved ───────────────────────────── *)

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
    Alcotest.(check bool) "model field present" true
      (Observability_redact.contains_substring ~sub:"glm-4-9b" entry_str))

let test_turn_context_fields_stored () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.set_turn_context
      ~keeper_name:"k"
      ~lane:"tool_required"
      ~tool_choice:"required"
      ~thinking_enabled:false
      ~thinking_budget:1024
      ();
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok"
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
      (Safe_ops.json_int ~default:0 "thinking_budget" entry))

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
    let by_model = Yojson.Safe.Util.member "by_model" summary in
    let by_lane = Yojson.Safe.Util.member "by_lane" summary in
    let by_thinking = Yojson.Safe.Util.member "by_thinking_mode" summary in
    let by_tool_choice = Yojson.Safe.Util.member "by_tool_choice" summary in
    let glm_bucket = find_bucket "glm-5.1" by_model in
    let retry_bucket = find_bucket "retry" by_lane in
    let enabled_bucket = find_bucket "enabled" by_thinking in
    let auto_bucket = find_bucket "auto" by_tool_choice in
    Alcotest.(check int) "glm bucket calls" 1
      (Safe_ops.json_int ~default:0 "calls" glm_bucket);
    Alcotest.(check int) "retry bucket calls" 1
      (Safe_ops.json_int ~default:0 "calls" retry_bucket);
    Alcotest.(check int) "enabled thinking calls" 1
      (Safe_ops.json_int ~default:0 "calls" enabled_bucket);
    Alcotest.(check int) "auto tool_choice calls" 1
      (Safe_ops.json_int ~default:0 "calls" auto_bucket))

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
        ; eio_test "turn context fields stored" test_turn_context_fields_stored
        ; eio_test "dashboard aggregate groups runtime fields"
            test_dashboard_aggregate_groups_runtime_fields
        ] )
    ]
