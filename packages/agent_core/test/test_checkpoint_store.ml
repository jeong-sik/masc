open Agent_sdk

(* ── Helpers ─────────────────────────────────────────────────────── *)

let make_checkpoint ?(session_id = "test-session") ?(created_at = 1000.0) ()
  : Checkpoint.t
  =
  { version = Checkpoint.checkpoint_version
  ; session_id
  ; agent_name = "test-agent"
  ; model = "claude-sonnet-4-6"
  ; system_prompt = Some "test prompt"
  ; messages =
      [ { role = User
        ; content = [ Text "hello" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ]
  ; usage = Types.empty_usage
  ; turn_count = 1
  ; created_at
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Types.Off
  ; thinking_budget = None
  ; reasoning_effort = None
  ; cache_system_prompt = false
  ; context = Context.create_sync ()
  ; mcp_sessions = []
  ; working_context = None
  }
;;

let sample_tool_schema : Types.tool_schema =
  Types.tool_schema_of_params
    ~name:"get_weather"
    ~description:"Get weather"
    ~parameters:
      [ { Types.name = "city"
        ; description = "City name"
        ; param_type = Types.String
        ; required = true
        }
      ]
    ()
;;

let create_ok dir =
  match Checkpoint_store.create dir with
  | Ok s -> s
  | Error e -> Alcotest.fail ("create failed: " ^ Error.to_string e)
;;

let list_ok store =
  match Checkpoint_store.list store with
  | Ok ids -> ids
  | Error e -> Alcotest.fail ("list failed: " ^ Error.to_string e)
;;

let with_tmp_store f =
  Eio_main.run
  @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let suffix = string_of_int (Random.int 999999) in
  let tmp_dir = Eio.Path.(fs / "/tmp" / ("oas-test-" ^ suffix)) in
  let store = create_ok tmp_dir in
  Fun.protect
    ~finally:(fun () ->
      try Eio.Path.rmtree ~missing_ok:true tmp_dir with
      | _ -> ())
    (fun () -> f store tmp_dir)
;;

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_create_store () =
  with_tmp_store (fun _store tmp_dir ->
    Alcotest.(check bool) "dir exists" true (Eio.Path.is_directory tmp_dir))
;;

let test_create_returns_error_on_bad_path () =
  Eio_main.run
  @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let suffix = string_of_int (Random.int 999999) in
  let file_path = Eio.Path.(fs / "/tmp" / ("oas-not-a-dir-" ^ suffix)) in
  Eio.Path.save ~create:(`Or_truncate 0o644) file_path "x";
  let bad_path = Eio.Path.(file_path / "sub") in
  Fun.protect
    ~finally:(fun () ->
      try Eio.Path.unlink file_path with
      | _ -> ())
    (fun () ->
       match Checkpoint_store.create bad_path with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "expected Error for path under a file")
;;

let test_list_returns_error_when_dir_removed () =
  Eio_main.run
  @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let suffix = string_of_int (Random.int 999999) in
  let tmp_dir = Eio.Path.(fs / "/tmp" / ("oas-test-list-err-" ^ suffix)) in
  let store = create_ok tmp_dir in
  Eio.Path.rmtree ~missing_ok:true tmp_dir;
  match Checkpoint_store.list store with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error after removing directory"
;;

let test_create_auto_creates_directory () =
  Eio_main.run
  @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let suffix = string_of_int (Random.int 999999) in
  let tmp_dir = Eio.Path.(fs / "/tmp" / ("oas-test-nested-" ^ suffix) / "sub" / "dir") in
  let parent = Eio.Path.(fs / "/tmp" / ("oas-test-nested-" ^ suffix)) in
  Fun.protect
    ~finally:(fun () ->
      try Eio.Path.rmtree ~missing_ok:true parent with
      | _ -> ())
    (fun () ->
       let _store = create_ok tmp_dir in
       Alcotest.(check bool) "nested dir exists" true (Eio.Path.is_directory tmp_dir))
;;

let test_save_writes_file () =
  with_tmp_store (fun store tmp_dir ->
    let cp = make_checkpoint () in
    let result = Checkpoint_store.save store cp in
    Alcotest.(check bool) "save ok" true (Result.is_ok result);
    let path = Eio.Path.(tmp_dir / "test-session.json") in
    Alcotest.(check bool) "file exists" true (Eio.Path.is_file path))
;;

let test_save_writes_valid_json () =
  with_tmp_store (fun store tmp_dir ->
    let cp = make_checkpoint () in
    let _ = Checkpoint_store.save store cp in
    let data = Eio.Path.load Eio.Path.(tmp_dir / "test-session.json") in
    let json = Yojson.Safe.from_string data in
    let sid = Yojson.Safe.Util.(json |> member "session_id" |> to_string) in
    Alcotest.(check string) "session_id" "test-session" sid)
;;

let test_save_atomic_no_tmp_residue () =
  with_tmp_store (fun store _tmp_dir ->
    let cp = make_checkpoint () in
    let _ = Checkpoint_store.save store cp in
    let ids = list_ok store in
    (* No .tmp files should appear in the listing *)
    Alcotest.(check (list string)) "only json" [ "test-session" ] ids)
;;

let test_save_empty_session_id () =
  with_tmp_store (fun store _tmp_dir ->
    let cp = make_checkpoint ~session_id:"" () in
    let result = Checkpoint_store.save store cp in
    Alcotest.(check bool) "error" true (Result.is_error result);
    match result with
    | Error msg ->
      Alcotest.(check bool) "contains empty" true (String.length (Error.to_string msg) > 0)
    | Ok () -> Alcotest.fail "expected error")
;;

let test_save_slash_in_session_id () =
  with_tmp_store (fun store _tmp_dir ->
    let cp = make_checkpoint ~session_id:"a/b" () in
    let result = Checkpoint_store.save store cp in
    Alcotest.(check bool) "error" true (Result.is_error result))
;;

let test_save_null_byte_in_session_id () =
  with_tmp_store (fun store _tmp_dir ->
    let cp = make_checkpoint ~session_id:"a\000b" () in
    let result = Checkpoint_store.save store cp in
    Alcotest.(check bool) "error" true (Result.is_error result))
;;

let test_save_overwrites_existing () =
  with_tmp_store (fun store _tmp_dir ->
    let cp1 = make_checkpoint ~created_at:1000.0 () in
    let _ = Checkpoint_store.save store cp1 in
    let cp2 = make_checkpoint ~created_at:2000.0 () in
    let _ = Checkpoint_store.save store cp2 in
    match Checkpoint_store.load store "test-session" with
    | Ok loaded ->
      Alcotest.(check (float 0.1)) "updated created_at" 2000.0 loaded.created_at
    | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_load_existing () =
  with_tmp_store (fun store _tmp_dir ->
    let cp = make_checkpoint () in
    let _ = Checkpoint_store.save store cp in
    let result = Checkpoint_store.load store "test-session" in
    Alcotest.(check bool) "load ok" true (Result.is_ok result))
;;

let test_load_missing () =
  with_tmp_store (fun store _tmp_dir ->
    let result = Checkpoint_store.load store "nonexistent" in
    Alcotest.(check bool) "load error" true (Result.is_error result))
;;

let test_load_corrupted () =
  with_tmp_store (fun _store tmp_dir ->
    let path = Eio.Path.(tmp_dir / "corrupted.json") in
    Eio.Path.save ~create:(`Or_truncate 0o644) path "not valid json{{{";
    let store = create_ok tmp_dir in
    let result = Checkpoint_store.load store "corrupted" in
    Alcotest.(check bool) "load error" true (Result.is_error result))
;;

let test_load_invalid_id () =
  with_tmp_store (fun store _tmp_dir ->
    let result = Checkpoint_store.load store "" in
    Alcotest.(check bool) "error" true (Result.is_error result))
;;

let test_roundtrip_preserves_all_fields () =
  with_tmp_store (fun store _tmp_dir ->
    let cp = make_checkpoint ~session_id:"rt1" ~created_at:42.5 () in
    let _ = Checkpoint_store.save store cp in
    match Checkpoint_store.load store "rt1" with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok loaded ->
      Alcotest.(check int) "version" cp.version loaded.version;
      Alcotest.(check string) "session_id" cp.session_id loaded.session_id;
      Alcotest.(check string) "agent_name" cp.agent_name loaded.agent_name;
      Alcotest.(check (float 0.01)) "created_at" cp.created_at loaded.created_at;
      Alcotest.(check int) "turn_count" cp.turn_count loaded.turn_count)
;;

let test_roundtrip_preserves_messages () =
  with_tmp_store (fun store _tmp_dir ->
    let cp =
      { (make_checkpoint ~session_id:"rt-msg" ()) with
        messages =
          [ { role = User
            ; content = [ Text "hello" ]
            ; name = None
            ; tool_call_id = None
            ; metadata = []
            }
          ; { role = Assistant
            ; content = [ Text "world" ]
            ; name = None
            ; tool_call_id = None
            ; metadata = []
            }
          ]
      }
    in
    let _ = Checkpoint_store.save store cp in
    match Checkpoint_store.load store "rt-msg" with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok loaded -> Alcotest.(check int) "msg count" 2 (List.length loaded.messages))
;;

let test_roundtrip_preserves_usage () =
  with_tmp_store (fun store _tmp_dir ->
    let cp =
      { (make_checkpoint ~session_id:"rt-usage" ()) with
        usage =
          { total_input_tokens = 100
          ; total_output_tokens = 200
          ; total_cache_creation_input_tokens = 10
          ; total_cache_read_input_tokens = 20
          ; api_calls = 3
          ; estimated_cost_usd = 0.0
          ; pricing_gap = None
          }
      }
    in
    let _ = Checkpoint_store.save store cp in
    match Checkpoint_store.load store "rt-usage" with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok loaded ->
      Alcotest.(check int) "input_tokens" 100 loaded.usage.total_input_tokens;
      Alcotest.(check int) "output_tokens" 200 loaded.usage.total_output_tokens;
      Alcotest.(check int) "api_calls" 3 loaded.usage.api_calls)
;;

let test_roundtrip_preserves_tools () =
  with_tmp_store (fun store _tmp_dir ->
    let cp =
      { (make_checkpoint ~session_id:"rt-tools" ()) with tools = [ sample_tool_schema ] }
    in
    let _ = Checkpoint_store.save store cp in
    match Checkpoint_store.load store "rt-tools" with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok loaded ->
      Alcotest.(check int) "tools count" 1 (List.length loaded.tools);
      let t = List.hd loaded.tools in
      Alcotest.(check string) "tool name" "get_weather" t.name)
;;

let test_roundtrip_preserves_tool_choice () =
  with_tmp_store (fun store _tmp_dir ->
    let cp =
      { (make_checkpoint ~session_id:"rt-tc" ()) with
        tool_choice = Some (Types.Tool "get_weather")
      }
    in
    let _ = Checkpoint_store.save store cp in
    match Checkpoint_store.load store "rt-tc" with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok loaded ->
      Alcotest.(check bool) "has tool_choice" true (Option.is_some loaded.tool_choice))
;;

let test_list_empty_store () =
  with_tmp_store (fun store _tmp_dir ->
    let ids = list_ok store in
    Alcotest.(check (list string)) "empty" [] ids)
;;

let test_list_returns_all_saved () =
  with_tmp_store (fun store _tmp_dir ->
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"aaa" ()) in
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"bbb" ()) in
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"ccc" ()) in
    let ids = list_ok store in
    Alcotest.(check (list string)) "all three" [ "aaa"; "bbb"; "ccc" ] ids)
;;

let test_list_excludes_tmp_files () =
  with_tmp_store (fun store tmp_dir ->
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"good" ()) in
    (* Manually create a .tmp file *)
    Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(tmp_dir / "orphan.json.tmp") "{}";
    let ids = list_ok store in
    Alcotest.(check (list string)) "no tmp" [ "good" ] ids)
;;

let test_list_is_sorted () =
  with_tmp_store (fun store _tmp_dir ->
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"zebra" ()) in
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"alpha" ()) in
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"mid" ()) in
    let ids = list_ok store in
    Alcotest.(check (list string)) "sorted" [ "alpha"; "mid"; "zebra" ] ids)
;;

let test_list_after_delete () =
  with_tmp_store (fun store _tmp_dir ->
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"keep" ()) in
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"remove" ()) in
    let _ = Checkpoint_store.delete store "remove" in
    let ids = list_ok store in
    Alcotest.(check (list string)) "after delete" [ "keep" ] ids)
;;

let test_delete_existing () =
  with_tmp_store (fun store _tmp_dir ->
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"del" ()) in
    let result = Checkpoint_store.delete store "del" in
    Alcotest.(check bool) "delete ok" true (Result.is_ok result);
    Alcotest.(check bool) "gone" false (Checkpoint_store.exists store "del"))
;;

let test_delete_missing () =
  with_tmp_store (fun store _tmp_dir ->
    let result = Checkpoint_store.delete store "nonexistent" in
    Alcotest.(check bool) "delete error" true (Result.is_error result))
;;

let test_delete_invalid_id () =
  with_tmp_store (fun store _tmp_dir ->
    let result = Checkpoint_store.delete store "" in
    Alcotest.(check bool) "error" true (Result.is_error result))
;;

let test_load_after_delete () =
  with_tmp_store (fun store _tmp_dir ->
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"ephemeral" ()) in
    let _ = Checkpoint_store.delete store "ephemeral" in
    let result = Checkpoint_store.load store "ephemeral" in
    Alcotest.(check bool) "load error" true (Result.is_error result))
;;

let test_latest_returns_most_recent () =
  with_tmp_store (fun store _tmp_dir ->
    let _ =
      Checkpoint_store.save store (make_checkpoint ~session_id:"old" ~created_at:100.0 ())
    in
    let _ =
      Checkpoint_store.save store (make_checkpoint ~session_id:"new" ~created_at:300.0 ())
    in
    let _ =
      Checkpoint_store.save store (make_checkpoint ~session_id:"mid" ~created_at:200.0 ())
    in
    match Checkpoint_store.latest store with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok cp -> Alcotest.(check string) "latest session_id" "new" cp.session_id)
;;

let test_latest_empty_store () =
  with_tmp_store (fun store _tmp_dir ->
    let result = Checkpoint_store.latest store in
    Alcotest.(check bool) "error" true (Result.is_error result))
;;

let test_latest_with_single () =
  with_tmp_store (fun store _tmp_dir ->
    let _ =
      Checkpoint_store.save
        store
        (make_checkpoint ~session_id:"only" ~created_at:500.0 ())
    in
    match Checkpoint_store.latest store with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok cp -> Alcotest.(check string) "session_id" "only" cp.session_id)
;;

let test_latest_ignores_corrupted () =
  with_tmp_store (fun store tmp_dir ->
    let _ =
      Checkpoint_store.save
        store
        (make_checkpoint ~session_id:"valid" ~created_at:100.0 ())
    in
    (* Write corrupted file manually *)
    Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(tmp_dir / "bad.json") "not json";
    match Checkpoint_store.latest store with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok cp -> Alcotest.(check string) "session_id" "valid" cp.session_id)
;;

let test_latest_all_corrupted () =
  with_tmp_store (fun _store tmp_dir ->
    Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(tmp_dir / "bad1.json") "not json";
    Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(tmp_dir / "bad2.json") "{broken";
    let store = create_ok tmp_dir in
    match Checkpoint_store.latest store with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "expected Error when all checkpoints are corrupted")
;;

let test_exists_true_for_saved () =
  with_tmp_store (fun store _tmp_dir ->
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"present" ()) in
    Alcotest.(check bool) "exists" true (Checkpoint_store.exists store "present"))
;;

let test_exists_false_for_missing () =
  with_tmp_store (fun store _tmp_dir ->
    Alcotest.(check bool) "not exists" false (Checkpoint_store.exists store "ghost"))
;;

let test_exists_false_after_delete () =
  with_tmp_store (fun store _tmp_dir ->
    let _ = Checkpoint_store.save store (make_checkpoint ~session_id:"temp" ()) in
    let _ = Checkpoint_store.delete store "temp" in
    Alcotest.(check bool) "not exists" false (Checkpoint_store.exists store "temp"))
;;

let test_multiple_save_same_id_overwrites () =
  with_tmp_store (fun store _tmp_dir ->
    let cp1 = { (make_checkpoint ~session_id:"dup" ()) with turn_count = 1 } in
    let _ = Checkpoint_store.save store cp1 in
    let cp2 = { (make_checkpoint ~session_id:"dup" ()) with turn_count = 99 } in
    let _ = Checkpoint_store.save store cp2 in
    match Checkpoint_store.load store "dup" with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok loaded -> Alcotest.(check int) "overwritten turn_count" 99 loaded.turn_count)
;;

(* ── Runner ──────────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Checkpoint_store"
    [ ( "create"
      , [ Alcotest.test_case "create store" `Quick test_create_store
        ; Alcotest.test_case
            "create auto creates directory"
            `Quick
            test_create_auto_creates_directory
        ; Alcotest.test_case
            "create returns error on bad path"
            `Quick
            test_create_returns_error_on_bad_path
        ] )
    ; ( "list"
      , [ Alcotest.test_case "list empty store" `Quick test_list_empty_store
        ; Alcotest.test_case "list returns all saved" `Quick test_list_returns_all_saved
        ; Alcotest.test_case
            "list excludes .tmp files"
            `Quick
            test_list_excludes_tmp_files
        ; Alcotest.test_case "list is sorted" `Quick test_list_is_sorted
        ; Alcotest.test_case "list after delete" `Quick test_list_after_delete
        ; Alcotest.test_case
            "list returns error when dir removed"
            `Quick
            test_list_returns_error_when_dir_removed
        ] )
    ; ( "save"
      , [ Alcotest.test_case "save writes file" `Quick test_save_writes_file
        ; Alcotest.test_case "save writes valid JSON" `Quick test_save_writes_valid_json
        ; Alcotest.test_case
            "save atomic - no .tmp residue"
            `Quick
            test_save_atomic_no_tmp_residue
        ; Alcotest.test_case
            "save empty session_id error"
            `Quick
            test_save_empty_session_id
        ; Alcotest.test_case
            "save slash in session_id error"
            `Quick
            test_save_slash_in_session_id
        ; Alcotest.test_case
            "save null byte in session_id error"
            `Quick
            test_save_null_byte_in_session_id
        ; Alcotest.test_case
            "save overwrites existing"
            `Quick
            test_save_overwrites_existing
        ] )
    ; ( "load"
      , [ Alcotest.test_case "load existing checkpoint" `Quick test_load_existing
        ; Alcotest.test_case "load missing returns error" `Quick test_load_missing
        ; Alcotest.test_case "load corrupted returns error" `Quick test_load_corrupted
        ; Alcotest.test_case "load invalid id returns error" `Quick test_load_invalid_id
        ] )
    ; ( "roundtrip"
      , [ Alcotest.test_case
            "roundtrip preserves all fields"
            `Quick
            test_roundtrip_preserves_all_fields
        ; Alcotest.test_case
            "roundtrip preserves messages"
            `Quick
            test_roundtrip_preserves_messages
        ; Alcotest.test_case
            "roundtrip preserves usage"
            `Quick
            test_roundtrip_preserves_usage
        ; Alcotest.test_case
            "roundtrip preserves tools"
            `Quick
            test_roundtrip_preserves_tools
        ; Alcotest.test_case
            "roundtrip preserves tool_choice"
            `Quick
            test_roundtrip_preserves_tool_choice
        ] )
    ; ( "delete"
      , [ Alcotest.test_case "delete existing" `Quick test_delete_existing
        ; Alcotest.test_case "delete missing returns error" `Quick test_delete_missing
        ; Alcotest.test_case
            "delete invalid id returns error"
            `Quick
            test_delete_invalid_id
        ; Alcotest.test_case
            "load after delete returns error"
            `Quick
            test_load_after_delete
        ] )
    ; ( "latest"
      , [ Alcotest.test_case
            "latest returns most recent by created_at"
            `Quick
            test_latest_returns_most_recent
        ; Alcotest.test_case "latest empty store error" `Quick test_latest_empty_store
        ; Alcotest.test_case
            "latest with single checkpoint"
            `Quick
            test_latest_with_single
        ; Alcotest.test_case
            "latest ignores corrupted files"
            `Quick
            test_latest_ignores_corrupted
        ; Alcotest.test_case
            "latest all corrupted returns error"
            `Quick
            test_latest_all_corrupted
        ] )
    ; ( "exists"
      , [ Alcotest.test_case
            "exists returns true for saved"
            `Quick
            test_exists_true_for_saved
        ; Alcotest.test_case
            "exists returns false for missing"
            `Quick
            test_exists_false_for_missing
        ; Alcotest.test_case
            "exists returns false after delete"
            `Quick
            test_exists_false_after_delete
        ] )
    ; ( "overwrite"
      , [ Alcotest.test_case
            "multiple save same id overwrites"
            `Quick
            test_multiple_save_same_id_overwrites
        ] )
    ]
;;
