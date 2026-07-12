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

let rec mkdir_p path =
  if path = "" || path = "." || path = Filename.dir_sep || Sys.file_exists path
  then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700
  end

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

let test_inbound_identity_is_idempotent_and_fsynced_private () =
  let base_dir = temp_base_path "keeper-chat-store-idempotent" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let config = workspace_config ~cluster_name:"default" base_dir in
      let surface =
        Masc.Surface_ref.Slack
          { team_id = Some "T-1"
          ; channel_id = "C-1"
          ; thread_ts = Some "171.1"
          }
      in
      let append content =
        S.append_user_message_once_result ~config ~base_dir ~keeper_name
          ~content ~surface ~external_message_id:"slack-message-1" ()
      in
      Alcotest.(check bool) "first identity appends" true
        (match append "first copy" with Ok S.Appended -> true | _ -> false);
      Alcotest.(check bool) "replay returns already-present" true
        (match append "duplicate copy" with
         | Ok S.Already_present -> true
         | _ -> false);
      let rows = S.load_configured ~config ~base_dir ~keeper_name in
      Alcotest.(check int) "only one user row persists" 1 (List.length rows);
      (match rows with
       | [ row ] -> Alcotest.(check string) "original content wins" "first copy" row.content
       | _ -> ());
      let path =
        Filename.concat
          (Filename.concat (Masc.Workspace.masc_root_dir config) "keeper_chat")
          (keeper_name ^ ".jsonl")
      in
      Alcotest.(check int) "chat file is private" 0o600
        ((Unix.stat path).Unix.st_perm land 0o777))

let test_incomplete_tail_fails_closed_without_rewrite () =
  let base_dir = temp_base_path "keeper-chat-store-incomplete" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let config = workspace_config ~cluster_name:"default" base_dir in
      let dir =
        Filename.concat (Masc.Workspace.masc_root_dir config) "keeper_chat"
      in
      mkdir_p dir;
      let path = Filename.concat dir (keeper_name ^ ".jsonl") in
      let corrupt = "{\"role\":\"user\"" in
      let oc = open_out_bin path in
      output_string oc corrupt;
      close_out oc;
      let result =
        S.append_assistant_message_result ~config ~base_dir ~keeper_name
          ~content:"must not append" ()
      in
      Alcotest.(check bool) "incomplete tail rejects append" true
        (Result.is_error result);
      let ic = open_in_bin path in
      let persisted = really_input_string ic (in_channel_length ic) in
      close_in ic;
      Alcotest.(check string) "incomplete bytes remain untouched" corrupt persisted)

let test_queued_batch_persists_receipt_join_ids () =
  let base_dir = temp_base_path "keeper-chat-store-receipt-join" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let user_message : S.user_message_input =
        { content = "queued prompt"
        ; attachments = []
        ; timestamp = 10.0
        ; queue_receipt_id = Some "chatq_00000000-0000-4000-8000-000000000901"
        ; surface = Some (Masc.Surface_ref.Dashboard { session_id = None })
        ; conversation_id = None
        ; external_message_id = None
        ; speaker = None
        ; extra_mentions = []
        }
      in
      let result =
        S.append_user_messages_and_assistant_result ~base_dir ~keeper_name
          ~user_messages:[ user_message ] ~assistant_content:"queued reply" ()
      in
      Alcotest.(check bool) "queued batch append succeeds" true
        (Result.is_ok result);
      match S.load ~base_dir ~keeper_name with
      | [ user; assistant ] ->
        Alcotest.(check (list string)) "user joins one receipt"
          [ "chatq_00000000-0000-4000-8000-000000000901" ]
          user.queue_receipt_ids;
        Alcotest.(check (list string)) "terminal joins whole receipt batch"
          [ "chatq_00000000-0000-4000-8000-000000000901" ]
          assistant.queue_receipt_ids
      | rows ->
        Alcotest.failf "expected user+assistant receipt rows, got %d"
          (List.length rows))

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
          Alcotest.test_case "inbound identity is durable and idempotent" `Quick
            test_inbound_identity_is_idempotent_and_fsynced_private;
          Alcotest.test_case "incomplete tail fails closed" `Quick
            test_incomplete_tail_fails_closed_without_rewrite;
          Alcotest.test_case "queued batch persists receipt join ids" `Quick
            test_queued_batch_persists_receipt_join_ids;
        ] );
    ]
