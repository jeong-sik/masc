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
        ] )
    ]
