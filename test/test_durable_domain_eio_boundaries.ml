module Blob_store = Tool_blob_store
module Vision_store = Multimodal.Vision_artifact_store

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Sys.rmdir path)
    else Sys.remove path
;;

let with_temp_dir f =
  let path = Filename.temp_dir "durable-domain-eio-" "" in
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let test_tool_blob_store_eio_boundary () =
  with_temp_dir (fun base_path ->
    let store = Blob_store.create ~base_path in
    match Blob_store.put_eio store ~bytes:"typed blob" ~mime:"text/plain" with
    | Tool_output.Stored { sha256; _ } ->
      Alcotest.(check (option string))
        "Eio entry point stores and fetches bytes"
        (Some "typed blob")
        (Blob_store.fetch store ~sha256)
    | Tool_output.Inline _ -> Alcotest.fail "blob was not externalized")
;;

let test_vision_store_eio_boundary () =
  with_temp_dir (fun base_path ->
    let dir = Filename.concat base_path "vision" in
    match Vision_store.store_eio ~dir "image-bytes" with
    | Error detail -> Alcotest.fail detail
    | Ok handle ->
      Alcotest.(check (result string string))
        "Eio entry point stores and loads artifact"
        (Ok "image-bytes")
        (Vision_store.load ~dir handle))
;;

let test_repo_mapping_eio_boundary () =
  with_temp_dir (fun base_path ->
    let mapping =
      Repo_manager_types.make_keeper_repo_mapping
        ~keeper_id:"keeper-a"
        ~repository_ids:[ "repo-a" ]
    in
    (match Keeper_repo_mapping.save_mapping_eio ~base_path mapping with
     | Error detail -> Alcotest.fail detail
     | Ok () -> ());
    match Keeper_repo_mapping.load_all ~base_path with
    | Error detail -> Alcotest.fail detail
    | Ok [ persisted ] ->
      Alcotest.(check string) "keeper id" "keeper-a" persisted.keeper_id;
      Alcotest.(check (list string))
        "repository ids"
        [ "repo-a" ]
        persisted.repository_ids
    | Ok mappings ->
      Alcotest.failf "expected one persisted mapping, got %d" (List.length mappings))
;;

let test_history_migration_eio_boundary () =
  with_temp_dir (fun session_dir ->
    let main_path = Filename.concat session_dir "history.jsonl" in
    let internal_path = Filename.concat session_dir "history.internal.jsonl" in
    let moved =
      {|{"role":"assistant","source":"internal_assistant","content_blocks":[]}|}
    in
    Fs_compat.save_file main_path (moved ^ "\n");
    (match Masc.Keeper_context_core.migrate_session_history_logs_eio ~session_dir with
     | Error error ->
       Alcotest.fail
         (Masc.Keeper_context_core.history_migration_error_to_string error)
     | Ok stats -> Alcotest.(check int) "one line moved" 1 stats.moved_lines);
    Alcotest.(check string) "main history emptied" "" (Fs_compat.load_file main_path);
    Alcotest.(check string)
      "internal history receives line"
      (moved ^ "\n")
      (Fs_compat.load_file internal_path))
;;

let () =
  Eio_main.run @@ fun _env ->
  Alcotest.run
    "durable-domain-eio-boundaries"
    [ ( "boundaries"
      , [ Alcotest.test_case
            "tool blob store"
            `Quick
            test_tool_blob_store_eio_boundary
        ; Alcotest.test_case
            "vision artifact store"
            `Quick
            test_vision_store_eio_boundary
        ; Alcotest.test_case
            "keeper repo mapping"
            `Quick
            test_repo_mapping_eio_boundary
        ; Alcotest.test_case
            "history migration"
            `Quick
            test_history_migration_eio_boundary
        ] )
    ]
;;
