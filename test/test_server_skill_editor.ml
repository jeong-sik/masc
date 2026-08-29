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

let named_skill_text name description body =
  Printf.sprintf
    "---\nname: %s\ndescription: %s\n---\n\n%s\n"
    name
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
      "[skills]\nresource-read-max-bytes = 65536\n\n[[skills.sources]]\nid = \"workspace\"\nanchor = \"base-path\"\npath = \"skills\"\naccess = %S\n"
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
       (Skill_reference.equal reference preview.profile.reference));
  (match Editor.save ~base_path ~reference ~source_text:edited ~refresh with
   | Error error -> fail (Editor.error_to_string error)
   | Ok (Editor.Saved_and_published { preview; _ }) ->
     check bool "new exact reference" false
       (Skill_reference.equal reference preview.profile.reference)
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
  let too_long = String.make 1025 'x' in
  let invalid_sources =
    [ ( "missing name"
      , "---\ndescription: Missing the required name.\n---\nBody\n" )
    ; ( "name mismatch"
      , "---\nname: another-name\ndescription: The names disagree.\n---\nBody\n" )
    ; ( "description too long"
      , Printf.sprintf
          "---\nname: sample\ndescription: %s\n---\nBody\n"
          too_long )
    ; ( "unknown top-level field"
      , "---\nname: sample\ndescription: Reject unknown policy.\ndisable-model-invocation: true\n---\nBody\n" )
    ; ( "Unicode whitespace-only description"
      , "---\nname: sample\ndescription: \xc2\xa0\n---\nBody\n" )
    ]
  in
  List.iter
    (fun (label, invalid) ->
       (match Editor.preview ~base_path reference ~source_text:invalid with
        | Error (Editor.Validation_failed _) -> ()
        | Error error -> fail (label ^ ": wrong preview error: " ^ Editor.error_to_string error)
        | Ok _ -> fail (label ^ ": invalid Skill passed preview"));
       (match Editor.save ~base_path ~reference ~source_text:invalid ~refresh with
        | Error (Editor.Validation_failed _) -> ()
        | Error error -> fail (label ^ ": wrong save error: " ^ Editor.error_to_string error)
        | Ok _ -> fail (label ^ ": invalid Skill was written"));
       let channel = open_in_bin skill_path in
       let persisted =
         Fun.protect
           ~finally:(fun () -> close_in_noerr channel)
           (fun () -> really_input_string channel (in_channel_length channel))
       in
       check string (label ^ ": original survives") original persisted)
    invalid_sources
;;

let test_invalid_new_skill_is_never_created () =
  with_workspace @@ fun base_path ->
  let _, _, _, refresh = setup base_path ~access:"read-write" in
  let source_id =
    match Skill_source_config.source_id_of_string "workspace" with
    | Ok value -> value
    | Error detail -> fail detail
  in
  let source_text =
    "---\nname: different-name\ndescription: The package and name disagree.\n---\nBody\n"
  in
  (match
     Editor.create
       ~base_path
       ~source_id
       ~package_id:"not-created"
       ~source_text
       ~refresh
   with
   | Error (Editor.Validation_failed _) -> ()
   | Error error -> fail ("wrong create error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "invalid new Skill was created");
  check
    bool
    "package directory remains absent"
    false
    (Sys.file_exists (Filename.concat base_path "skills/not-created"))
  ;
  let whitespace_package = "alpha " in
  (match
     Editor.create
       ~base_path
       ~source_id
       ~package_id:whitespace_package
       ~source_text:
         "---\nname: alpha\ndescription: The raw directory must match.\n---\nBody\n"
       ~refresh
   with
   | Error (Editor.Validation_failed _) -> ()
   | Error error -> fail ("wrong whitespace create error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "trimmed package directory was created");
  check
    bool
    "whitespace package directory remains absent"
    false
    (Sys.file_exists (Filename.concat base_path ("skills/" ^ whitespace_package)))
;;

let test_composition_preview_exposes_validated_flow () =
  with_workspace @@ fun base_path ->
  let _, _, reference, _ = setup base_path ~access:"read-write" in
  let source_text =
    {|---
name: sample
description: Read the exact clock through a validated composition.
---

```toml composition
[[compositions]]
name = "sample"
description = "Read the exact clock through a validated composition."
execution = "inline"

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
```
|}
  in
  match Editor.preview ~base_path reference ~source_text with
  | Error error -> fail (Editor.error_to_string error)
  | Ok preview ->
    (match preview.profile.flow with
     | Some { nodes = [ node ]; batches = [ batch ] } ->
       check string "flow node" "keeper_time_now" node.tool_name;
       check string "flow batch" "concurrent" batch.execution_mode
     | _ -> fail "composition preview did not expose its validated flow")
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

let test_create_publishes_without_host_path_input () =
  with_workspace @@ fun base_path ->
  let _, _, _, refresh = setup base_path ~access:"read-write" in
  let source_id =
    match Skill_source_config.source_id_of_string "workspace" with
    | Ok value -> value
    | Error detail -> fail detail
  in
  let source_text =
    named_skill_text "generated" "Generated from Skill Studio." "# Generated"
  in
  (match Editor.writable_sources ~base_path with
   | Ok [ source ] ->
     check
       string
       "source identity only"
       "workspace"
       (Skill_source_config.source_id_to_string source.source_id)
   | Ok _ -> fail "expected one writable source"
   | Error error -> fail (Editor.error_to_string error));
  (match
     Editor.create
       ~base_path
       ~source_id
       ~package_id:"generated"
       ~source_text
       ~refresh
   with
   | Ok (Editor.Created_and_published { preview; _ }) ->
     check string "generated profile" "instruction" preview.profile.kind
   | Ok (Created_but_unpublished _) -> fail "generated Skill was not published"
   | Error error -> fail (Editor.error_to_string error));
  let persisted = Filename.concat base_path "skills/generated/SKILL.md" in
  check bool "created package" true (Sys.file_exists persisted);
  (match
     Editor.create
       ~base_path
       ~source_id
       ~package_id:"generated"
       ~source_text:(named_skill_text "generated" "Replacement." "# Replacement")
       ~refresh
   with
   | Error Editor.Package_already_exists -> ()
   | Error error -> fail ("wrong duplicate error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "create-only path overwrote an existing package")
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let test_delete_exact_reference_and_publish () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, refresh = setup base_path ~access:"read-write" in
  let recovery_id =
    match Editor.delete ~base_path ~reference ~confirmed:true ~refresh with
    | Ok
        (Editor.Deleted_and_published
           { reference = deleted
           ; recovery_id
           ; disposition = Quarantine_retained
           ; _
           }) ->
      check bool "deleted exact reference" true (Skill_reference.equal reference deleted);
      recovery_id
    | Ok (Deleted_and_published _) -> fail "successful delete did not retain recovery"
    | Ok (Deleted_but_unpublished _) -> fail "deleted Skill was not published"
    | Error error -> fail (Editor.error_to_string error)
  in
  check bool "SKILL.md removed" false (Sys.file_exists skill_path);
  let source_root = Filename.dirname (Filename.dirname skill_path) in
  let recovery_path = Editor.For_testing.recovery_file_path ~source_root ~recovery_id in
  check string "exact bytes retained" original (read_file recovery_path);
  (match Editor.load ~base_path reference with
   | Error Editor.Reference_not_current -> ()
   | Error error -> fail ("wrong post-delete error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "published snapshot retained the deleted reference")
;;

let test_delete_stale_revision_does_not_mutate () =
  with_workspace @@ fun base_path ->
  let skill_path, _, reference, refresh = setup base_path ~access:"read-write" in
  let external_text = skill_text "External edit." "# External" in
  write_file skill_path external_text;
  (match Editor.delete ~base_path ~reference ~confirmed:true ~refresh with
   | Error (Editor.Revision_conflict _) -> ()
   | Error error -> fail ("wrong stale error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "stale reference deleted the externally edited Skill");
  check string "external edit survives" external_text (read_file skill_path)
;;

let test_delete_stale_published_revision_does_not_mutate () =
  with_workspace @@ fun base_path ->
  let skill_path, _, reference, refresh = setup base_path ~access:"read-write" in
  let replacement = skill_text "Published replacement." "# Replacement" in
  (match Editor.save ~base_path ~reference ~source_text:replacement ~refresh with
   | Ok (Editor.Saved_and_published _) -> ()
   | Error error -> fail (Editor.error_to_string error)
   | Ok (Unchanged _ | Saved_but_unpublished _) ->
     fail "replacement revision was not published");
  (match Editor.delete ~base_path ~reference ~confirmed:true ~refresh with
   | Error (Editor.Revision_conflict { actual }) ->
     check
       string
       "published actual revision"
       (Skill_reference.content_revision_of_source_text replacement
        |> Skill_reference.content_revision_to_string)
       (Skill_reference.content_revision_to_string actual)
   | Error error -> fail ("wrong published stale error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "stale published reference deleted the replacement Skill");
  check string "published replacement survives" replacement (read_file skill_path)
;;

let replace_file_atomically path source_text =
  let replacement_path = path ^ ".external-replacement" in
  write_file replacement_path source_text;
  Unix.rename replacement_path path
;;

let test_delete_quarantines_then_restores_pre_mutation_replacement () =
  with_workspace @@ fun base_path ->
  let skill_path, _, reference, refresh = setup base_path ~access:"read-write" in
  let replacement = skill_text "Concurrent replacement." "# Replacement" in
  let refresh_called = ref false in
  let observed_refresh () =
    refresh_called := true;
    refresh ()
  in
  (match
     Editor.For_testing.delete
       ~before_quarantine:(fun () -> replace_file_atomically skill_path replacement)
       ~after_move:(fun () -> ())
       ~after_quarantine:(fun () -> ())
       ~after_verification:(fun () -> ())
       ~base_path
       ~reference
       ~confirmed:true
       ~refresh:observed_refresh
   with
   | Error
       (Editor.Delete_revision_conflict
          { actual; disposition = Original_restored; _ }) ->
     check
       string
       "replacement revision"
       (Skill_reference.content_revision_of_source_text replacement
        |> Skill_reference.content_revision_to_string)
       (Skill_reference.content_revision_to_string actual)
   | Error error -> fail ("wrong quarantine race error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "pre-mutation replacement was reported as deleted");
  check bool "mismatch never publishes" false !refresh_called;
  check string "newer bytes restored" replacement (read_file skill_path)
;;

let test_delete_retains_quarantine_when_original_reappears () =
  with_workspace @@ fun base_path ->
  let skill_path, _, reference, refresh = setup base_path ~access:"read-write" in
  let quarantined_replacement =
    skill_text "Replacement moved to recovery." "# Quarantined"
  in
  let concurrent_original =
    skill_text "Replacement recreated at source." "# Current"
  in
  let refresh_called = ref false in
  let observed_refresh () =
    refresh_called := true;
    refresh ()
  in
  let recovery_id =
    match
      Editor.For_testing.delete
        ~before_quarantine:(fun () ->
          replace_file_atomically skill_path quarantined_replacement)
        ~after_move:(fun () -> ())
        ~after_quarantine:(fun () -> write_file skill_path concurrent_original)
        ~after_verification:(fun () -> ())
        ~base_path
        ~reference
        ~confirmed:true
        ~refresh:observed_refresh
    with
    | Error
        (Editor.Recovery_required
           { observed = Some actual
           ; recovery_id
           ; disposition = Quarantine_retained
           ; _
           }) ->
      check
        string
        "quarantined revision"
        (Skill_reference.content_revision_of_source_text quarantined_replacement
         |> Skill_reference.content_revision_to_string)
        (Skill_reference.content_revision_to_string actual);
      recovery_id
    | Error error -> fail ("wrong retained quarantine error: " ^ Editor.error_to_string error)
    | Ok _ -> fail "two-version race was reported as deleted"
  in
  check bool "recovery-required never publishes" false !refresh_called;
  check string "current source survives" concurrent_original (read_file skill_path);
  let source_root = Filename.dirname (Filename.dirname skill_path) in
  let recovery_path = Editor.For_testing.recovery_file_path ~source_root ~recovery_id in
  check
    string
    "quarantined replacement survives"
    quarantined_replacement
    (read_file recovery_path)
;;

let write_all fd source_text =
  let rec loop offset =
    if offset < String.length source_text
    then
      let written =
        Unix.write_substring fd source_text offset (String.length source_text - offset)
      in
      loop (offset + written)
  in
  loop 0
;;

let test_delete_retains_open_fd_write_after_verification () =
  with_workspace @@ fun base_path ->
  let skill_path, _, reference, refresh = setup base_path ~access:"read-write" in
  let later_bytes = skill_text "Open descriptor update." "# Later" in
  let fd = Unix.openfile skill_path [ Unix.O_WRONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
       let recovery_id =
         match
           Editor.For_testing.delete
             ~before_quarantine:(fun () -> ())
             ~after_move:(fun () -> ())
             ~after_quarantine:(fun () -> ())
             ~after_verification:(fun () ->
               Unix.ftruncate fd 0;
               write_all fd later_bytes;
               Unix.fsync fd)
             ~base_path
             ~reference
             ~confirmed:true
             ~refresh
         with
         | Ok
             (Editor.Deleted_and_published
                { recovery_id; disposition = Quarantine_retained; _ }) ->
           recovery_id
         | Ok (Deleted_and_published _) ->
           fail "open-fd delete did not retain recovery"
         | Ok (Deleted_but_unpublished _) -> fail "open-fd delete was not published"
         | Error error -> fail (Editor.error_to_string error)
       in
       check bool "source name remains absent" false (Sys.file_exists skill_path);
       let source_root = Filename.dirname (Filename.dirname skill_path) in
       let recovery_path =
         Editor.For_testing.recovery_file_path ~source_root ~recovery_id
       in
       check string "post-verification bytes retained" later_bytes (read_file recovery_path))
;;

let recovery_path skill_path recovery_id =
  let source_root = Filename.dirname (Filename.dirname skill_path) in
  Editor.For_testing.recovery_file_path ~source_root ~recovery_id
;;

let test_delete_cancellation_immediately_after_move_is_typed () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, refresh = setup base_path ~access:"read-write" in
  let refresh_called = ref false in
  let recovery_id, error =
    match
      Editor.For_testing.delete
        ~before_quarantine:(fun () -> ())
        ~after_move:(fun () ->
          raise (Eio.Cancel.Cancelled (Failure "cancel after move")))
        ~after_quarantine:(fun () -> ())
        ~after_verification:(fun () -> ())
        ~base_path
        ~reference
        ~confirmed:true
        ~refresh:(fun () -> refresh_called := true; refresh ())
    with
    | Error
        (Editor.Quarantine_failed
           ({ candidate_moved = true
            ; recovery_id = Some recovery_id
            ; disposition = Some Quarantine_retained
            ; cause = Recovery_cancelled Quarantine_settlement
            } as error)) ->
      recovery_id, Editor.Quarantine_failed error
    | Error error -> fail (Editor.error_to_string error)
    | Ok _ -> fail "post-move cancellation escaped as success"
  in
  check bool "cancelled move never refreshes" false !refresh_called;
  check bool "source moved" false (Sys.file_exists skill_path);
  check string "cancelled candidate retained" original (read_file (recovery_path skill_path recovery_id));
  (match Editor.error_recovery error with
   | Some (observed_id, Quarantine_retained) ->
     check string "audit recovery id" recovery_id observed_id
   | _ -> fail "moved quarantine error omitted audit recovery");
  let json = Editor.error_to_yojson error in
  check
    string
    "serialized disposition"
    "quarantine_retained"
    Yojson.Safe.Util.(json |> member "recovery_disposition" |> to_string);
  check
    string
    "serialized cancellation stage"
    "quarantine_settlement"
    Yojson.Safe.Util.(json |> member "cause" |> member "stage" |> to_string)
;;

let test_delete_parent_cancellation_while_waiting_for_path_lock () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, refresh = setup base_path ~access:"read-write" in
  let refresh_called = ref false in
  let observed_refresh () =
    refresh_called := true;
    refresh ()
  in
  let lock = Masc.Keeper_fs.acquire_path_lock skill_path in
  Fun.protect
    ~finally:(fun () -> Masc.Keeper_fs.release_path_lock skill_path lock)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let holder_entered, resolve_holder_entered = Eio.Promise.create () in
       let release_holder, resolve_release_holder = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         Eio.Mutex.use_rw
           ~protect:true
           (Masc.Keeper_fs.path_lock_mutex lock)
           (fun () ->
              Eio.Promise.resolve resolve_holder_entered ();
              Eio.Promise.await release_holder));
       Eio.Promise.await holder_entered;
       let cancellation_context, resolve_cancellation_context = Eio.Promise.create () in
       let child_result, resolve_child_result = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         let result =
           try
             Eio.Cancel.sub (fun cancellation ->
               Eio.Promise.resolve resolve_cancellation_context cancellation;
               ignore
                 (Editor.delete
                    ~base_path
                    ~reference
                    ~confirmed:true
                    ~refresh:observed_refresh));
             `Returned
           with
           | Eio.Cancel.Cancelled _ -> `Cancelled
         in
         Eio.Promise.resolve resolve_child_result result);
       let cancellation = Eio.Promise.await cancellation_context in
       Eio.Cancel.cancel cancellation (Failure "cancel path-lock waiter");
       Eio.Promise.resolve resolve_release_holder ();
       (match Eio.Promise.await child_result with
        | `Cancelled -> ()
        | `Returned -> fail "path-lock cancellation was protected"));
  check bool "cancelled waiter never refreshes" false !refresh_called;
  check string "cancelled waiter leaves SKILL.md unchanged" original (read_file skill_path);
  let source_root = Filename.dirname (Filename.dirname skill_path) in
  check
    (list string)
    "cancelled waiter creates no recovery candidate"
    [ "sample" ]
    (Sys.readdir source_root |> Array.to_list |> List.sort String.compare)
;;

let test_delete_cancellation_after_verification_is_typed () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, refresh = setup base_path ~access:"read-write" in
  let recovery_id =
    match
      Editor.For_testing.delete
        ~before_quarantine:(fun () -> ())
        ~after_move:(fun () -> ())
        ~after_quarantine:(fun () -> ())
        ~after_verification:(fun () ->
          raise (Eio.Cancel.Cancelled (Failure "cancel after verification")))
        ~base_path
        ~reference
        ~confirmed:true
        ~refresh
    with
    | Error
        (Editor.Recovery_required
           { recovery_id
           ; disposition = Quarantine_retained
           ; cause = Recovery_cancelled After_verification
           ; _
           }) ->
      recovery_id
    | Error error -> fail (Editor.error_to_string error)
    | Ok _ -> fail "post-verification cancellation escaped as success"
  in
  check string "verified candidate retained" original (read_file (recovery_path skill_path recovery_id))
;;

let test_delete_cancellation_after_quarantine_is_typed () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, refresh = setup base_path ~access:"read-write" in
  let recovery_id =
    match
      Editor.For_testing.delete
        ~before_quarantine:(fun () -> ())
        ~after_move:(fun () -> ())
        ~after_quarantine:(fun () ->
          raise (Eio.Cancel.Cancelled (Failure "cancel after quarantine")))
        ~after_verification:(fun () -> ())
        ~base_path
        ~reference
        ~confirmed:true
        ~refresh
    with
    | Error
        (Editor.Recovery_required
           ({ recovery_id
            ; disposition = Quarantine_retained
            ; cause = Recovery_cancelled After_quarantine
            ; _
            } as recovery)) ->
      (match Editor.error_recovery (Editor.Recovery_required recovery) with
       | Some (observed_id, Quarantine_retained) ->
         check string "audit recovery id" recovery_id observed_id
       | _ -> fail "after-quarantine cancellation omitted audit recovery");
      recovery_id
    | Error error -> fail (Editor.error_to_string error)
    | Ok _ -> fail "after-quarantine cancellation escaped as success"
  in
  check string "quarantine-cancelled candidate retained" original (read_file (recovery_path skill_path recovery_id))
;;

let test_delete_refresh_cancellation_is_unpublished () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, _ = setup base_path ~access:"read-write" in
  let recovery_id =
    match
      Editor.delete
        ~base_path
        ~reference
        ~confirmed:true
        ~refresh:(fun () ->
          raise (Eio.Cancel.Cancelled (Failure "cancel refresh")))
    with
    | Ok
        (Editor.Deleted_but_unpublished
           ({ reason = Publication_cancelled
            ; recovery_id
            ; disposition = Quarantine_retained
            ; _
            } as outcome)) ->
      let json = Editor.delete_outcome_to_yojson (Editor.Deleted_but_unpublished outcome) in
      check
        string
        "serialized refresh cancellation"
        "snapshot refresh cancelled"
        Yojson.Safe.Util.(json |> member "reason" |> to_string);
      recovery_id
    | Ok _ -> fail "refresh cancellation was reported as published"
    | Error error -> fail (Editor.error_to_string error)
  in
  check string "refresh-cancelled candidate retained" original (read_file (recovery_path skill_path recovery_id))
;;

let test_delete_moved_settlement_failure_is_typed () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, refresh = setup base_path ~access:"read-write" in
  let recovery_id =
    match
      Editor.For_testing.delete
        ~before_quarantine:(fun () -> ())
        ~after_move:(fun () -> failwith "injected fsync boundary failure")
        ~after_quarantine:(fun () -> ())
        ~after_verification:(fun () -> ())
        ~base_path
        ~reference
        ~confirmed:true
        ~refresh
    with
    | Error
        (Editor.Quarantine_failed
           { candidate_moved = true
           ; recovery_id = Some recovery_id
           ; disposition = Some Quarantine_retained
           ; cause = Recovery_operation_failed _
           }) ->
      recovery_id
    | Error error -> fail (Editor.error_to_string error)
    | Ok _ -> fail "moved settlement failure escaped as success"
  in
  check string "settlement failure retained candidate" original (read_file (recovery_path skill_path recovery_id))
;;

let test_delete_requires_confirmation () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, refresh =
    setup base_path ~access:"read-write"
  in
  (match Editor.delete ~base_path ~reference ~confirmed:false ~refresh with
   | Error Editor.Confirmation_required -> ()
   | Error error -> fail ("wrong confirmation error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "unconfirmed delete mutated the Skill");
  check string "unconfirmed Skill survives" original (read_file skill_path)
;;

let test_delete_read_only_source_does_not_mutate () =
  with_workspace @@ fun base_path ->
  let skill_path, original, reference, refresh = setup base_path ~access:"read-only" in
  (match Editor.delete ~base_path ~reference ~confirmed:true ~refresh with
   | Error Editor.Source_read_only -> ()
   | Error error -> fail ("wrong read-only error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "read-only source accepted deletion");
  check string "read-only Skill survives" original (read_file skill_path)
;;

let test_delete_missing_file_is_not_found_without_mutation () =
  with_workspace @@ fun base_path ->
  let skill_path, _, reference, refresh = setup base_path ~access:"read-write" in
  Unix.unlink skill_path;
  match Editor.delete ~base_path ~reference ~confirmed:true ~refresh with
  | Error Editor.Source_file_missing -> ()
  | Error error -> fail ("wrong missing-file error: " ^ Editor.error_to_string error)
  | Ok _ -> fail "missing file was reported as deleted"
;;

let test_delete_rejects_symlink_leaf () =
  with_workspace @@ fun base_path ->
  let skill_path, _, reference, refresh = setup base_path ~access:"read-write" in
  let outside_path = Filename.concat base_path "outside-skill.md" in
  let outside_text = skill_text "Outside." "# Outside" in
  write_file outside_path outside_text;
  Unix.unlink skill_path;
  Unix.symlink outside_path skill_path;
  (match Editor.delete ~base_path ~reference ~confirmed:true ~refresh with
   | Error (Editor.Source_path_rejected _) -> ()
   | Error error -> fail ("wrong symlink error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "symlink leaf was accepted for deletion");
  check string "symlink target survives" outside_text (read_file outside_path);
  check bool "symlink leaf survives" true (Sys.file_exists skill_path)
;;

let test_delete_rejects_symlink_directory_escape () =
  with_workspace @@ fun base_path ->
  let skill_path, _, reference, refresh = setup base_path ~access:"read-write" in
  let package_dir = Filename.dirname skill_path in
  let outside_dir = Filename.concat base_path "outside-package" in
  let outside_path = Filename.concat outside_dir "SKILL.md" in
  Unix.mkdir outside_dir 0o700;
  let outside_text = skill_text "Outside package." "# Outside" in
  write_file outside_path outside_text;
  Unix.unlink skill_path;
  Unix.rmdir package_dir;
  Unix.symlink outside_dir package_dir;
  (match Editor.delete ~base_path ~reference ~confirmed:true ~refresh with
   | Error (Editor.Source_path_rejected _) -> ()
   | Error error -> fail ("wrong directory escape error: " ^ Editor.error_to_string error)
   | Ok _ -> fail "symlink directory escape was accepted for deletion");
  check string "escaped target survives" outside_text (read_file outside_path)
;;

let test_deleted_but_unpublished_is_explicit () =
  with_workspace @@ fun base_path ->
  let skill_path, _, reference, _ = setup base_path ~access:"read-write" in
  let refresh () = Error "injected publication failure" in
  (match Editor.delete ~base_path ~reference ~confirmed:true ~refresh with
   | Ok (Editor.Deleted_but_unpublished { reason; _ }) ->
     check
       string
       "failure is preserved"
       "injected publication failure"
       (Editor.delete_unpublished_reason_to_string reason)
   | Error error -> fail (Editor.error_to_string error)
   | Ok (Deleted_and_published _) ->
     fail "publication failure was reported as published");
  check bool "durable deletion is not hidden" false (Sys.file_exists skill_path)
;;

let () =
  Eio_main.run @@ fun _env ->
  run
    "server Skill editor"
    [ ( "editor"
      , [ test_case "load preview and publish" `Quick test_load_preview_and_publish
        ; test_case "invalid candidate is never written" `Quick test_invalid_candidate_is_never_written
        ; test_case "invalid new Skill is never created" `Quick
            test_invalid_new_skill_is_never_created
        ; test_case "composition preview exposes validated flow" `Quick
            test_composition_preview_exposes_validated_flow
        ; test_case "external edit conflicts" `Quick test_external_edit_causes_revision_conflict
        ; test_case "read-only source rejects save" `Quick test_read_only_source_rejects_save
        ; test_case "oversized candidate is never written" `Quick
            test_oversized_candidate_is_never_written
        ; test_case "saved but unpublished is explicit" `Quick
            test_saved_but_unpublished_is_explicit
        ; test_case "create publishes without host path input" `Quick
            test_create_publishes_without_host_path_input
        ; test_case "delete exact reference and publish" `Quick
            test_delete_exact_reference_and_publish
        ; test_case "delete stale revision does not mutate" `Quick
            test_delete_stale_revision_does_not_mutate
        ; test_case "delete stale published revision does not mutate" `Quick
            test_delete_stale_published_revision_does_not_mutate
        ; test_case "delete restores pre-mutation replacement" `Quick
            test_delete_quarantines_then_restores_pre_mutation_replacement
        ; test_case "delete retains quarantine when original reappears" `Quick
            test_delete_retains_quarantine_when_original_reappears
        ; test_case "delete retains open-fd write after verification" `Quick
            test_delete_retains_open_fd_write_after_verification
        ; test_case "delete cancellation after move is typed" `Quick
            test_delete_cancellation_immediately_after_move_is_typed
        ; test_case "delete parent cancellation while waiting for path lock" `Quick
            test_delete_parent_cancellation_while_waiting_for_path_lock
        ; test_case "delete cancellation after verification is typed" `Quick
            test_delete_cancellation_after_verification_is_typed
        ; test_case "delete cancellation after quarantine is typed" `Quick
            test_delete_cancellation_after_quarantine_is_typed
        ; test_case "delete refresh cancellation is unpublished" `Quick
            test_delete_refresh_cancellation_is_unpublished
        ; test_case "delete moved settlement failure is typed" `Quick
            test_delete_moved_settlement_failure_is_typed
        ; test_case "delete requires confirmation" `Quick
            test_delete_requires_confirmation
        ; test_case "delete read-only source does not mutate" `Quick
            test_delete_read_only_source_does_not_mutate
        ; test_case "delete missing file is not found" `Quick
            test_delete_missing_file_is_not_found_without_mutation
        ; test_case "delete rejects symlink leaf" `Quick test_delete_rejects_symlink_leaf
        ; test_case "delete rejects symlink directory escape" `Quick
            test_delete_rejects_symlink_directory_escape
        ; test_case "deleted but unpublished is explicit" `Quick
            test_deleted_but_unpublished_is_explicit
        ] )
    ]
;;
