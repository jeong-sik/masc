module K = Masc.Keeper_chat_store
module P = Masc.Otel_metric_store

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end

let temp_base_path prefix =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let write_file path content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let drop_value reason =
  P.metric_value_or_zero P.metric_persistence_read_drops
    ~labels:[("surface", "keeper_chat_store"); ("reason", reason)]
    ()

let chat_path ~base_dir ~keeper_name =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path:base_dir)
       "keeper_chat")
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")

let test_load_records_malformed_row_drops () =
  let base_dir = temp_base_path "keeper-chat-store-drops" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-drop" in
      let path = chat_path ~base_dir ~keeper_name in
      let entry_error = Safe_ops.persistence_read_drop_reason_entry_load_error in
      let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
      let before_entry_error = drop_value entry_error in
      let before_invalid_payload = drop_value invalid_payload in
      write_file path
        (String.concat "\n"
           [
             Yojson.Safe.to_string
               (`Assoc
                  [
                    ("role", `String "user");
                    ("content", `String "hello");
                    ("ts", `Float 1.0);
                  ]);
             "{not-json";
             Yojson.Safe.to_string (`Assoc [("role", `String "assistant")]);
             Yojson.Safe.to_string
               (`Assoc
                  [
                    ("role", `String "assistant");
                    ("content", `String "world");
                    ("ts", `Float 2.0);
                  ]);
           ]
        ^ "\n");
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check int) "valid messages survive" 2 (List.length messages);
      Alcotest.(check (list string)) "content order"
        [ "hello"; "world" ]
        (List.map (fun (msg : K.chat_message) -> msg.content) messages);
      Alcotest.(check (float 0.001)) "malformed json increments entry error"
        1.0
        (drop_value entry_error -. before_entry_error);
      Alcotest.(check (float 0.001)) "missing content increments invalid payload"
        1.0
        (drop_value invalid_payload -. before_invalid_payload))

let roles messages = List.map (fun (m : K.chat_message) -> m.role) messages

let test_append_turn_roundtrip () =
  let base_dir = temp_base_path "keeper-chat-store-turn" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-turn" in
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"run the checks"
        ~user_attachments:[]
        ~tool_calls:
          [
            { K.call_id = "toolu_1"; call_name = "Read"; args = {|{"path":"x"}|} };
            (* Empty args normalise to "{}", empty id to a positional one. *)
            { K.call_id = ""; call_name = "masc_status"; args = "  " };
          ]
        ~source:"dashboard"
        ~assistant_content:"all green"
        ();
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check (list string)) "turn line order"
        [ "user"; "tool"; "tool"; "assistant" ]
        (roles messages);
      let tool1 = List.nth messages 1 in
      let tool2 = List.nth messages 2 in
      let asst = List.nth messages 3 in
      Alcotest.(check (option string)) "tool id persisted"
        (Some "toolu_1") tool1.tool_call_id;
      Alcotest.(check (option string)) "tool name persisted"
        (Some "Read") tool1.tool_call_name;
      Alcotest.(check string) "tool args persisted" {|{"path":"x"}|} tool1.content;
      Alcotest.(check (option string)) "empty tool id gets positional fallback"
        (Some "tc-1") tool2.tool_call_id;
      Alcotest.(check string) "empty args normalised" "{}" tool2.content;
      Alcotest.(check (option string)) "source persisted on every line"
        (Some "dashboard") asst.source;
      Alcotest.(check (option string)) "assistant has no tool id"
        None asst.tool_call_id)

let test_legacy_lines_parse_without_new_fields () =
  let base_dir = temp_base_path "keeper-chat-store-legacy" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-legacy" in
      let path = chat_path ~base_dir ~keeper_name in
      write_file path
        ({|{"role":"user","content":"hello","ts":1.0}|} ^ "\n"
        ^ {|{"role":"assistant","content":"world","ts":1.0}|} ^ "\n");
      match K.load ~base_dir ~keeper_name with
      | [ user; assistant ] ->
          Alcotest.(check (option string)) "legacy user has no source" None user.source;
          Alcotest.(check (option string)) "legacy assistant has no tool id"
            None assistant.tool_call_id
      | messages ->
          Alcotest.failf "expected 2 messages, got %d" (List.length messages))

let test_tool_row_missing_name_dropped () =
  let base_dir = temp_base_path "keeper-chat-store-toolname" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-toolname" in
      let path = chat_path ~base_dir ~keeper_name in
      let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
      let before = drop_value invalid_payload in
      write_file path
        ({|{"role":"user","content":"hi","ts":1.0}|} ^ "\n"
        ^ {|{"role":"tool","content":"{}","ts":1.0,"tool_call_id":"toolu_9"}|} ^ "\n"
        ^ {|{"role":"assistant","content":"done","ts":1.0}|} ^ "\n");
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check (list string)) "nameless tool row dropped"
        [ "user"; "assistant" ] (roles messages);
      Alcotest.(check (float 0.001)) "drop counted as invalid payload"
        1.0
        (drop_value invalid_payload -. before))

let test_window_keeps_tool_lines_of_retained_turns () =
  let base_dir = temp_base_path "keeper-chat-store-window" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-window" in
      (* 51 turns of (user, tool, assistant) = 102 primaries; the window
         keeps the last 100 primaries (50 full turns) and trims the
         leading turn's orphaned tool line. *)
      for i = 1 to 51 do
        K.append_turn ~base_dir ~keeper_name
          ~user_content:(Printf.sprintf "u%d" i)
          ~user_attachments:[]
          ~tool_calls:
            [ { K.call_id = Printf.sprintf "t%d" i; call_name = "Read"; args = "{}" } ]
          ~assistant_content:(Printf.sprintf "a%d" i)
          ()
      done;
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check int) "50 full turns survive" 150 (List.length messages);
      let primaries =
        List.filter (fun (m : K.chat_message) -> m.role <> "tool") messages
      in
      Alcotest.(check int) "primary window is 100" 100 (List.length primaries);
      match messages with
      | first :: _ ->
          Alcotest.(check string) "window starts at a user line, not an orphan tool"
            "user" first.role;
          Alcotest.(check string) "oldest retained turn is turn 2" "u2" first.content
      | [] -> Alcotest.fail "expected non-empty window")

let test_orphan_leading_tool_lines_trimmed () =
  let base_dir = temp_base_path "keeper-chat-store-orphan" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-orphan" in
      let path = chat_path ~base_dir ~keeper_name in
      write_file path
        ({|{"role":"tool","content":"{}","ts":1.0,"tool_call_id":"t0","tool_call_name":"Read"}|}
         ^ "\n"
        ^ {|{"role":"user","content":"hi","ts":2.0}|} ^ "\n"
        ^ {|{"role":"assistant","content":"yo","ts":2.0}|} ^ "\n");
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check (list string)) "leading orphan tool trimmed"
        [ "user"; "assistant" ] (roles messages))

let () =
  Alcotest.run "keeper_chat_store"
    [
      ( "persistence_read_drops",
        [
          Alcotest.test_case "malformed rows increment drop metrics" `Quick
            test_load_records_malformed_row_drops;
          Alcotest.test_case "tool row without name dropped" `Quick
            test_tool_row_missing_name_dropped;
        ] );
      ( "tool_call_persistence",
        [
          Alcotest.test_case "append_turn roundtrip" `Quick
            test_append_turn_roundtrip;
          Alcotest.test_case "legacy lines parse" `Quick
            test_legacy_lines_parse_without_new_fields;
          Alcotest.test_case "window counts primaries only" `Quick
            test_window_keeps_tool_lines_of_retained_turns;
          Alcotest.test_case "orphan leading tool lines trimmed" `Quick
            test_orphan_leading_tool_lines_trimmed;
        ] );
    ]
