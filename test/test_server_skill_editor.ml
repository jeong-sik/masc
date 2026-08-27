open Alcotest

module Editor = Server_skill_editor
module Service = Skill_catalog_snapshot_service
module Snapshot = Skill_catalog_snapshot

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK ->
    Unix.unlink path
;;

let with_workspace f =
  let base_path = Filename.temp_file "server-skill-editor-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)
;;

let skill_text description body =
  Printf.sprintf
    "---\nname: sample\ndescription: %s\n---\n\n%s\n"
    description
    body
;;

let setup base_path ~access =
  let root = Filename.concat base_path "skills" in
  let package = Filename.concat root "sample" in
  Unix.mkdir root 0o700;
  Unix.mkdir package 0o700;
  let skill_path = Filename.concat package "SKILL.md" in
  let source_text = skill_text "Original description." "# Original" in
  write_file skill_path source_text;
  let config_text =
    Printf.sprintf
      "[skills]\nactivation-lifetime = \"session\"\nprecedence = \"earlier-source-wins\"\nresource-read-max-bytes = 65536\n\n[[skills.sources]]\nid = \"workspace\"\nanchor = \"base-path\"\npath = \"skills\"\naccess = %S\n"
      access
  in
  let workspace =
    match Service.workspace_of_base_path ~base_path with
    | Ok workspace -> workspace
    | Error _ -> fail "workspace fixture was rejected"
  in
  let refresh () =
    Ok
      (Service.refresh
         ~workspace
         ~user_home:None
         ~read_config:(fun () -> Service.Config_text config_text))
  in
  let snapshot =
    match refresh () with
    | Ok (Service.Published snapshot | Unchanged snapshot) -> snapshot
    | Ok Workspace_retired | Error _ -> fail "snapshot fixture was not published"
  in
  let reference =
    match Snapshot.effective_entries snapshot with
    | [ entry ] -> Snapshot.entry_reference entry
    | _ -> fail "expected one effective Skill"
  in
  skill_path, source_text, reference, refresh
;;

let test_load_preview_and_publish () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, refresh =
    setup base_path ~access:"read-write"
  in
  (match Editor.load ~base_path reference with
   | Error error -> fail (Editor.error_to_string error)
   | Ok loaded ->
     check string "exact source" original loaded.source_text;
     check string "write access" "read_write" (Editor.access_to_string loaded.access));
  let edited = skill_text "Edited description." "# Edited" in
  (match Editor.preview ~base_path reference ~source_text:edited with
   | Error error -> fail (Editor.error_to_string error)
   | Ok preview ->
     check string "instruction profile" "instruction" preview.profile.kind;
     check int "body remains deferred" 0 preview.profile.eager_body_bytes;
     check bool "candidate revision changes" false
       (Skill_reference.equal reference preview.reference));
  (match Editor.save ~base_path ~reference ~source_text:edited ~refresh with
   | Error error -> fail (Editor.error_to_string error)
   | Ok (Editor.Saved_and_published { preview; _ }) ->
     check bool "new exact reference" false
       (Skill_reference.equal reference preview.reference)
   | Ok (Unchanged _ | Saved_but_unpublished _) ->
     fail "edited Skill was not saved and published");
  let persisted =
    match Fs_compat.load_owned_regular_file ~ownership_root:(Filename.dirname (Filename.dirname skill_path)) skill_path with
    | Ok (Some text) -> text
    | Ok None | Error _ -> fail "saved SKILL.md could not be read back"
  in
  check string "durable bytes" edited persisted
;;

let test_invalid_candidate_is_never_written () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, refresh =
    setup base_path ~access:"read-write"
  in
  let invalid = "---\nname: sample\n---\nmissing description\n" in
  (match Editor.save ~base_path ~reference ~source_text:invalid ~refresh with
   | Error (Editor.Validation_failed _) -> ()
   | Error error -> fail ("wrong error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "invalid Skill was written");
  let persisted =
    let channel = open_in_bin skill_path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  check string "original survives" original persisted
;;

let test_external_edit_causes_revision_conflict () =
  with_workspace @@ fun base_path ->
  let skill_path, _, reference, refresh = setup base_path ~access:"read-write" in
  let external_text = skill_text "External edit." "# External" in
  write_file skill_path external_text;
  let candidate = skill_text "TUI edit." "# TUI" in
  (match Editor.save ~base_path ~reference ~source_text:candidate ~refresh with
   | Error (Editor.Revision_conflict _) -> ()
   | Error error -> fail ("wrong error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "stale editor overwrote an external edit");
  let persisted =
    let channel = open_in_bin skill_path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  check string "external edit survives" external_text persisted
;;

let test_read_only_source_rejects_save () =
  with_workspace @@ fun base_path ->
  let _, _, reference, refresh = setup base_path ~access:"read-only" in
  let candidate = skill_text "Edited." "# Edited" in
  match Editor.save ~base_path ~reference ~source_text:candidate ~refresh with
  | Error Editor.Source_read_only -> ()
  | Error error -> fail ("wrong error: " ^ Editor.error_to_string error)
  | Ok _ -> fail "read-only source accepted a write"
;;

let test_oversized_candidate_is_never_written () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, refresh =
    setup base_path ~access:"read-write"
  in
  let oversized =
    skill_text "Oversized." (String.make (1_048_576 + 1) 'x')
  in
  (match Editor.save ~base_path ~reference ~source_text:oversized ~refresh with
   | Error (Editor.Source_too_large _) -> ()
   | Error error -> fail ("wrong error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "oversized Skill was written");
  let persisted =
    let channel = open_in_bin skill_path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  check string "original survives" original persisted
;;

let test_saved_but_unpublished_is_explicit () =
  with_workspace @@ fun base_path ->
  let skill_path, _, reference, _ = setup base_path ~access:"read-write" in
  let edited = skill_text "Edited description." "# Edited" in
  let refresh () = Error "injected publication failure" in
  (match Editor.save ~base_path ~reference ~source_text:edited ~refresh with
   | Ok (Editor.Saved_but_unpublished { reason; _ }) ->
     check string "failure is preserved" "injected publication failure" reason
   | Error error -> fail (Editor.error_to_string error)
   | Ok (Unchanged _ | Saved_and_published _) ->
     fail "publication failure was reported as published");
  let persisted =
    let channel = open_in_bin skill_path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  check string "write is not hidden" edited persisted
;;

let () =
  Eio_main.run @@ fun _env ->
  run
    "server Skill editor"
    [ ( "editor"
      , [ test_case "load preview and publish" `Quick test_load_preview_and_publish
        ; test_case "invalid candidate is never written" `Quick test_invalid_candidate_is_never_written
        ; test_case "external edit conflicts" `Quick test_external_edit_causes_revision_conflict
        ; test_case "read-only source rejects save" `Quick test_read_only_source_rejects_save
        ; test_case "oversized candidate is never written" `Quick
            test_oversized_candidate_is_never_written
        ; test_case "saved but unpublished is explicit" `Quick
            test_saved_but_unpublished_is_explicit
        ] )
    ]
;;
