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

let test_tool_call_round_trip () =
  let base_dir = temp_base_path "keeper-chat-store-tool-call" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-tool" in
      K.append_tool_call ~base_dir ~keeper_name ~tool_call_id:"call-1"
        ~name:"keeper_task_claim" ~arguments:"{\"task_id\":\"T-1\"}";
      let messages = K.load ~base_dir ~keeper_name in
      Alcotest.(check int) "one tool call row" 1 (List.length messages);
      match messages with
      | [ msg ] ->
          Alcotest.(check string) "role" "tool_call" msg.K.role;
          Alcotest.(check string) "empty content accepted" "" msg.K.content;
          (match msg.K.tool_calls with
          | Some [ call ] ->
              Alcotest.(check string) "tool call id" "call-1"
                call.K.tool_call_id;
              Alcotest.(check string) "tool name" "keeper_task_claim"
                call.K.name;
              Alcotest.(check string) "arguments" "{\"task_id\":\"T-1\"}"
                call.K.arguments
          | _ -> Alcotest.fail "expected one structured tool call");
          (match K.to_json_array messages with
          | `List [ `Assoc fields ] ->
              Alcotest.(check bool) "json contains tool_calls" true
                (List.mem_assoc "tool_calls" fields)
          | _ -> Alcotest.fail "expected one json row")
      | _ -> Alcotest.fail "expected one message")

let test_append_pair_accepts_ordered_timestamps () =
  let base_dir = temp_base_path "keeper-chat-store-pair-ts" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "keeper-chat-pair-ts" in
      K.append_pair ~base_dir ~keeper_name ~user_content:"run tool"
        ~assistant_content:"done" ~user_attachments:[] ~user_ts:10.0
        ~assistant_ts:30.0 ();
      let messages = K.load ~base_dir ~keeper_name in
      match messages with
      | [ user; assistant ] ->
          Alcotest.(check string) "user role" "user" user.K.role;
          Alcotest.(check (option (float 0.001))) "user ts" (Some 10.0) user.K.ts;
          Alcotest.(check string) "assistant role" "assistant" assistant.K.role;
          Alcotest.(check (option (float 0.001))) "assistant ts" (Some 30.0) assistant.K.ts
      | _ -> Alcotest.fail "expected user and assistant rows")

let () =
  Alcotest.run "keeper_chat_store"
    [
      ( "persistence_read_drops",
        [
          Alcotest.test_case "malformed rows increment drop metrics" `Quick
            test_load_records_malformed_row_drops;
          Alcotest.test_case "tool calls round-trip through jsonl" `Quick
            test_tool_call_round_trip;
          Alcotest.test_case "append_pair accepts ordered timestamps" `Quick
            test_append_pair_accepts_ordered_timestamps;
        ] );
    ]
