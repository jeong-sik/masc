(* Fusion_sink.mli contract — Keeper_chat_store.append_assistant_message_result
   must surface a write failure as [Error] instead of swallowing it, so
   Fusion_sink.emit can propagate a chat-lane append failure (a dropped fusion
   conclusion + card) rather than reporting Ok. The unit
   [append_assistant_message] keeps the swallow-and-count behavior for its other
   callers. *)

module S = Masc.Keeper_chat_store

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let keeper_name = "chat-store-append-keeper"

let workspace_config ~cluster_name base_path =
  let config : Masc.Workspace.config = Masc.Workspace.default_config base_path in
  { config with
    backend_config =
      { config.backend_config with
        cluster_name
      }
  }

let test_ok_on_writable_dir () =
  let base_dir = temp_base_path "keeper-chat-store-ok" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let result =
        S.append_assistant_message_result ~base_dir ~keeper_name
          ~content:"hello" ()
      in
      Alcotest.(check bool)
        "append to a writable temp dir is Ok" true (Result.is_ok result))

(* base_dir nested under a regular file: directory creation / file open fails
   (ENOTDIR), so the write raises and must surface as [Error]. *)
let test_error_when_path_under_a_file () =
  let file_path = temp_base_path "keeper-chat-store-file" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove file_path with _ -> ())
    (fun () ->
      let oc = open_out file_path in
      close_out oc;
      let base_dir = Filename.concat file_path "under-a-file" in
      let result =
        S.append_assistant_message_result ~base_dir ~keeper_name
          ~content:"hello" ()
      in
      Alcotest.(check bool)
        "append under a non-directory path is Error" true
        (Result.is_error result))

let test_standalone_failure_marker_keeps_typed_kind () =
  let base_dir = temp_base_path "keeper-chat-store-failure-kind" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let result =
        S.append_assistant_message_result ~base_dir ~keeper_name
          ~content:"cancelled turn"
          ~kind:S.Row_kind.Transport_failure ()
      in
      Alcotest.(check bool) "typed failure append is Ok" true
        (Result.is_ok result);
      match S.load ~base_dir ~keeper_name with
      | [ row ] ->
        Alcotest.(check bool) "standalone row is a transport failure" true
          (S.Row_kind.equal row.kind S.Row_kind.Transport_failure)
      | rows ->
        Alcotest.failf "expected one standalone failure row, got %d"
          (List.length rows))

let test_cluster_configs_isolate_transcript_paths () =
  let base_dir = temp_base_path "keeper-chat-store-cluster" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let first_config = workspace_config ~cluster_name:"first-team" base_dir in
      let second_config = workspace_config ~cluster_name:"second-team" base_dir in
      let append config content =
        S.append_user_message_result ~config ~base_dir ~keeper_name ~content ()
      in
      Alcotest.(check bool) "first cluster append succeeds" true
        (Result.is_ok (append first_config "first cluster prompt"));
      Alcotest.(check bool) "second cluster append succeeds" true
        (Result.is_ok (append second_config "second cluster prompt"));
      let first_rows =
        S.load_configured ~config:first_config ~base_dir ~keeper_name
      in
      let second_rows =
        S.load_configured ~config:second_config ~base_dir ~keeper_name
      in
      (match first_rows, second_rows with
       | [ first ], [ second ] ->
         Alcotest.(check string) "first cluster transcript" "first cluster prompt"
           first.content;
         Alcotest.(check string) "second cluster transcript"
           "second cluster prompt" second.content
       | _ ->
         Alcotest.failf "expected one isolated row per cluster, got %d and %d"
           (List.length first_rows) (List.length second_rows));
      let transcript_path config =
        Filename.concat
          (Filename.concat (Masc.Workspace.masc_root_dir config) "keeper_chat")
          (keeper_name ^ ".jsonl")
      in
      Alcotest.(check bool) "first canonical transcript exists" true
        (Sys.file_exists (transcript_path first_config));
      Alcotest.(check bool) "second canonical transcript exists" true
        (Sys.file_exists (transcript_path second_config));
      Alcotest.(check bool) "cluster transcript paths differ" false
        (String.equal
           (transcript_path first_config)
           (transcript_path second_config)))

let () =
  Alcotest.run "keeper_chat_store_append_result"
    [
      ( "append-result",
        [
          Alcotest.test_case "writable dir -> Ok" `Quick test_ok_on_writable_dir;
          Alcotest.test_case "path under a file -> Error" `Quick
            test_error_when_path_under_a_file;
          Alcotest.test_case "standalone failure keeps typed row kind" `Quick
            test_standalone_failure_marker_keeps_typed_kind;
          Alcotest.test_case "cluster configs isolate transcript paths" `Quick
            test_cluster_configs_isolate_transcript_paths;
        ] );
    ]
