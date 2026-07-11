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

let test_persists_typed_transport_failure () =
  let base_dir = temp_base_path "keeper-chat-store-kind" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let result =
        S.append_assistant_message_result ~base_dir ~keeper_name
          ~content:"upstream request failed"
          ~kind:S.Row_kind.Transport_failure
          ()
      in
      Alcotest.(check bool) "typed append succeeds" true (Result.is_ok result);
      match S.load ~base_dir ~keeper_name with
      | [ message ] ->
          Alcotest.(check bool)
            "assistant-only failure is not persisted as keeper speech" true
            (S.Row_kind.equal message.kind S.Row_kind.Transport_failure)
      | messages ->
          Alcotest.failf "expected one persisted row, got %d"
            (List.length messages))

let () =
  Alcotest.run "keeper_chat_store_append_result"
    [
      ( "append-result",
        [
          Alcotest.test_case "writable dir -> Ok" `Quick test_ok_on_writable_dir;
          Alcotest.test_case "path under a file -> Error" `Quick
            test_error_when_path_under_a_file;
          Alcotest.test_case "typed transport failure" `Quick
            test_persists_typed_transport_failure;
        ] );
    ]
