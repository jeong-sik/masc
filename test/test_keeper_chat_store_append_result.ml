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

let persisted_path base_dir =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path:base_dir)
       "keeper_chat")
    (keeper_name ^ ".jsonl")

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

let test_append_is_owner_only_and_durable () =
  let base_dir = temp_base_path "keeper-chat-store-private" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let result =
        S.append_assistant_message_result ~base_dir ~keeper_name
          ~content:"private durable row" ()
      in
      Alcotest.(check bool) "durable append succeeds" true (Result.is_ok result);
      let path = persisted_path base_dir in
      Alcotest.(check int)
        "chat history is owner-only"
        0o600
        ((Unix.stat path).Unix.st_perm land 0o777);
      match S.load ~base_dir ~keeper_name with
      | [ row ] ->
        Alcotest.(check string)
          "durable row is readable"
          "private durable row"
          row.content
      | rows ->
        Alcotest.failf "expected one readable row, got %d" (List.length rows))

(* A crash mid-append leaves a last row with no newline. The next append cuts
   it back to the last complete row and commits; the rows before it stay. *)
let test_incomplete_tail_is_cut_before_the_next_append () =
  let base_dir = temp_base_path "keeper-chat-store-incomplete" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let initial =
        S.append_assistant_message_result ~base_dir ~keeper_name
          ~content:"seed" ()
      in
      Alcotest.(check bool) "seed append succeeds" true (Result.is_ok initial);
      let path = persisted_path base_dir in
      let output =
        open_out_gen [ Open_append; Open_wronly; Open_binary ] 0o600 path
      in
      output_string output "{\"role\":\"assistant\"";
      close_out output;
      let result =
        S.append_assistant_message_result ~base_dir ~keeper_name
          ~content:"after the torn row" ()
      in
      Alcotest.(check bool)
        "the append after a torn row commits" true (Result.is_ok result);
      match S.load ~base_dir ~keeper_name with
      | [ seed; after ] ->
        Alcotest.(check string)
          "the complete row before the fragment stays" "seed" seed.content;
        Alcotest.(check string)
          "the new row follows it" "after the torn row" after.content
      | rows ->
        Alcotest.failf "expected the seed row and the new one, got %d"
          (List.length rows))

let () =
  Alcotest.run "keeper_chat_store_append_result"
    [
      ( "append-result",
        [
          Alcotest.test_case "writable dir -> Ok" `Quick test_ok_on_writable_dir;
          Alcotest.test_case "path under a file -> Error" `Quick
            test_error_when_path_under_a_file;
          Alcotest.test_case "owner-only durable append" `Quick
            test_append_is_owner_only_and_durable;
          Alcotest.test_case "incomplete tail is cut before the next append"
            `Quick test_incomplete_tail_is_cut_before_the_next_append;
        ] );
    ]
