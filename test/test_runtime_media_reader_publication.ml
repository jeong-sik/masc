(* Runtime publication through the real parser, materializer and config writer.
   No reader executable, provider request or runtime service is started. *)
open Alcotest

let readers = list (testable Runtime_schema.pp_media_reader_decl Runtime_schema.equal_media_reader_decl)

let check_published label expected =
  check (option readers) label expected (Runtime.media_reader_declarations ())

let write path text = Out_channel.with_open_bin path (fun channel -> output_string channel text)
let read path = In_channel.with_open_bin path In_channel.input_all

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
    Unix.unlink path

let model_catalog =
  {|[[models]]
model_id = "sample"
provider_name = "local"
base = "openai_chat"
max_context_tokens = 1024
|}

let runtime_config =
  {|[providers.local]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1/v1"
[models.sample]
api-name = "sample"
max-context = 1024
[local.sample]
[runtime]
default = "local.sample"
|}

let row (reader : Runtime_schema.media_reader_decl) =
  let strings values = String.concat ", " (List.map (Printf.sprintf "%S") values) in
  let kind = match reader.kind with
    | Media_reading_kind.Audio -> "audio"
    | Media_reading_kind.Document -> "document" in
  let adapter = match reader.adapter with Runtime_schema.Markitdown_mcp -> "markitdown_mcp" in
  Printf.sprintf
    "[[media_readers]]\nid = %S\nrevision = %S\nkind = %S\nmedia_types = [%s]\nadapter = %S\ncommand = %S\nargs = [%s]\n"
    reader.id reader.revision kind (strings reader.media_types) adapter
    reader.command (strings reader.args)

let config declarations = String.concat "\n" (List.map row declarations) ^ "\n" ^ runtime_config

let fixture_declarations base =
  let first : Runtime_schema.media_reader_decl =
    { id = "primary"; revision = "r1"; kind = Media_reading_kind.Document
    ; media_types = ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"]
    ; adapter = Markitdown_mcp
    ; command = Filename.concat base "reader-that-does-not-exist"
    ; args = ["--stdio"; ""; "two words"] }
  in
  let second = { first with id = "overlapping"; revision = "backup"; args = ["--other"] } in
  let changed =
    { first with revision = "r2"; kind = Media_reading_kind.Audio
    ; media_types = ["audio/wav"; "audio/mpeg"]
    ; command = Filename.concat base "another-uninstalled-reader"
    ; args = ["--json"; "trailing "; ""] }
  in
  [first; second], [changed]

let with_fixture use =
  let previous_runtime = Runtime.For_testing.snapshot () in
  let previous_startup = Runtime_startup_state.get () in
  let previous_policy = Runtime_typesafeai_policy.current () in
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  let base = Filename.temp_dir "media-reader-publication-" "" in
  Fun.protect ~finally:(fun () ->
    Llm_provider.Catalog_snapshot.publish previous_catalog;
    Runtime.For_testing.restore previous_runtime;
    Runtime_startup_state.set previous_startup;
    Runtime_typesafeai_policy.publish previous_policy;
    remove_tree base) @@ fun () ->
  let state_dir = Filename.concat base ".masc" in
  Unix.mkdir state_dir 0o700;
  let config_dir = Filename.concat state_dir "config" in
  Unix.mkdir config_dir 0o700;
  let path = Filename.concat config_dir "runtime.toml" in
  let catalog_path = Filename.concat base "model-catalog.toml" in
  write catalog_path model_catalog;
  let models = match Llm_provider.Model_catalog.load_file catalog_path with
    | Ok models -> models
    | Error detail -> failf "fixture catalog: %s" detail in
  Llm_provider.Catalog_snapshot.publish
    (Masc_test_deps.admit_catalogs ~models:(Some models) ~providers:None);
  Masc_test_deps.with_process_env Runtime.agent_core_model_catalog_env_var_name None @@ fun () ->
  Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some base) @@ fun () ->
  let a, b = fixture_declarations base in
  use path a b

let initialize path =
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error detail -> failf "runtime publication: %s" detail

let save path text =
  match Runtime.save_config_text ~runtime_config_path:path text with
  | Ok receipt -> receipt
  | Error detail -> failf "runtime save: %s" detail

let revision path text =
  Runtime.config_source_revision_to_string (Runtime.config_observation ~path text).source_revision

let test_load_and_snapshot () =
  with_fixture @@ fun path a b ->
  Runtime.enter_setup_required ~reason:Runtime_startup_state.Config_missing ();
  check_published "unpublished is distinct from empty" None;
  let unpublished = Runtime.For_testing.snapshot () in
  write path runtime_config;
  initialize path;
  check_published "omitted declarations publish an empty list" (Some []);
  write path (config a);
  initialize path;
  check_published "all overlapping declarations retain their order" (Some a);
  let captured_a = Runtime.media_reader_declarations () in
  let snapshot_a = Runtime.For_testing.snapshot () in
  write path (config b);
  initialize path;
  check_published "reload publishes changed command, args, revision, kind and MIME" (Some b);
  check (option readers) "captured A remains immutable after reload" (Some a) captured_a;
  let captured_b = Runtime.media_reader_declarations () in
  Runtime.For_testing.restore snapshot_a;
  check_published "restoring the whole snapshot also restores declarations" (Some a);
  check (option readers) "captured B survives restoration" (Some b) captured_b;
  Runtime.For_testing.restore unpublished;
  check_published "unpublished snapshot restores None" None;
  check string "snapshot restore does not rewrite configuration" (config b) (read path)

let test_save_and_source_conflict () =
  with_fixture @@ fun path a b ->
  let source_a = config a and source_b = config b in
  write path source_a;
  initialize path;
  let receipt = save path source_b in
  check string "save receipt binds exact submitted source" source_b receipt.observation.source_text;
  check string "save replaces the actual configuration" source_b (read path);
  check_published "save publishes B in the active snapshot" (Some b);
  let revision_b = revision path source_b in
  (match Runtime.save_config_text_if_current ~runtime_config_path:path
      ~expected_source_path:path ~expected_source_revision:revision_b source_a with
   | Ok _ -> ()
   | Error (Runtime.Config_source_conflict _) -> fail "a fresh editor conflicted"
   | Error (Runtime.Config_edit_failed detail) -> failf "fresh editor save: %s" detail);
  check_published "fresh compare-and-save publishes A" (Some a);
  (match Runtime.save_config_text_if_current ~runtime_config_path:path
      ~expected_source_path:path ~expected_source_revision:revision_b source_b with
   | Error (Runtime.Config_source_conflict current) ->
     check string "conflict returns the current source" source_a current.source_text
   | Error (Runtime.Config_edit_failed detail) -> failf "expected stale-source conflict: %s" detail
   | Ok _ -> fail "a stale editor overwrote A");
  check string "stale save preserves the exact file" source_a (read path);
  check_published "stale save preserves the active list" (Some a);
  let empty = "media_readers = []\n" ^ runtime_config in
  ignore (save path empty : Runtime.config_commit_receipt);
  check string "explicit empty declarations were committed" empty (read path);
  check_published "explicit empty declarations remain published" (Some [])

let test_invalid_save_and_reload () =
  with_fixture @@ fun path a _b ->
  let valid = config a in
  let invalid = "[[media_readers]]\nid = 'missing-required-fields'\n" ^ runtime_config in
  write path valid;
  initialize path;
  (match Runtime.save_config_text ~runtime_config_path:path invalid with
   | Error _ -> ()
   | Ok _ -> fail "an invalid declaration was saved");
  check string "invalid save leaves file unchanged" valid (read path);
  check_published "invalid save cannot replace the active list" (Some a);
  let other = Filename.concat (Filename.dirname path) "invalid-runtime.toml" in
  write other invalid;
  (match Runtime.init_default ~config_path:other with
   | Error _ -> ()
   | Ok () -> fail "an invalid declaration was loaded");
  check_published "invalid reload retains the last complete snapshot" (Some a);
  check string "failed load does not rewrite its source" invalid (read other);
  check string "failed load does not touch the valid source" valid (read path)

let test_failure_before_rename () =
  with_fixture @@ fun path a b ->
  let source_a = config a and source_b = config b in
  write path source_a;
  initialize path;
  let attempted = ref None in
  let replace_file target content =
    attempted := Some (target, content);
    Error Fs_compat.
      { path = target; stage = Before_rename
      ; exception_ = Unix.Unix_error (Unix.EACCES, "rename", "publication fixture")
      ; backtrace = Printexc.get_callstack 0 }
  in
  (* The existing writer seam is inside the actual durable config lock and
     validation path. It reports the filesystem boundary, not a fake Runtime. *)
  (match Runtime.with_config_lock_observed ~runtime_config_path:path (fun () ->
      Runtime.commit_config_text_locked ~replace_file ~runtime_config_path:path source_b) with
   | Error detail -> failf "configuration lock: %s" detail
   | Ok receipt ->
     (match receipt.value with
      | Error (Runtime.Config_commit_write_failed failure) ->
        check bool "the failed write did not rename" true (failure.stage = Fs_compat.Before_rename)
      | Error (Runtime.Config_commit_refused detail) -> failf "fixture failed before write admission: %s" detail
      | Ok _ -> fail "injected pre-rename failure was committed"));
  check (option (pair string string)) "the actual writer received the exact candidate"
    (Some (path, source_b)) !attempted;
  check string "pre-rename failure preserves file" source_a (read path);
  check_published "pre-rename failure preserves the complete published list" (Some a)

let () =
  run "runtime media reader publication"
    [ "publication",
      [ test_case "load, immutable capture and snapshot restoration" `Quick test_load_and_snapshot
      ; test_case "save, fresh and stale source revisions" `Quick test_save_and_source_conflict
      ; test_case "invalid declaration preserves file and active snapshot" `Quick test_invalid_save_and_reload
      ; test_case "failure before rename cannot publish a candidate" `Quick test_failure_before_rename
      ] ]
