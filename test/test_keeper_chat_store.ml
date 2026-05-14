module K = Masc_mcp.Keeper_chat_store
module P = Masc_mcp.Prometheus

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
    (Coord_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")

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

let () =
  Alcotest.run "keeper_chat_store"
    [
      ( "persistence_read_drops",
        [
          Alcotest.test_case "malformed rows increment drop metrics" `Quick
            test_load_records_malformed_row_drops;
        ] );
    ]
