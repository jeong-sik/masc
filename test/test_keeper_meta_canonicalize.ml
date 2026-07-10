(** Boot-time retired keeper meta key migration
    (Keeper_meta_store.migrate_retired_keeper_meta_keys).

    Reproduces the post-#23929 incident: the continuity purge removed
    [last_continuity_update_ts]/[continuity_summary] from the serializer
    but left them in persisted [.masc/keepers/*.json], so every meta read
    re-warned "has unknown keys" until an unrelated save happened to
    rewrite the file — and dormant keepers never saved. The migration must
    remove only explicitly retired keys exactly once, preserve every surviving
    field value, use an atomic raw-JSON
    rewrite before runtime writers are published, and leave unreadable files
    untouched. *)

open Alcotest
open Masc

let temp_dir () =
  Filename.temp_dir "test_meta_retired_keys_" ""

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  rm dir

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Fun.protect
        ~finally:Fs_compat.clear_fs
        (fun () -> cleanup_dir dir))
    (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "keeper-meta-migration-agent"));
      f config)

let make_meta name : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json fixture failed: " ^ err)

let keeper_file config name = Keeper_types_profile.keeper_meta_path config name

let write_keeper config name =
  match Keeper_meta_store.write_meta config (make_meta name) with
  | Ok () -> ()
  | Error msg -> fail ("write_meta failed: " ^ msg)

(* Re-create the exact on-disk shape #23929 left behind: a valid meta
   snapshot plus retired top-level keys the serializer no longer emits.
   [extra] models parser-consumed TOML-owned keys (config_field_names)
   that a legacy file may still carry — those must survive the pass. *)
let inject_keys ?(extra = []) config name =
  let path = keeper_file config name in
  match Yojson.Safe.from_string (Fs_compat.load_file path) with
  | `Assoc fields ->
    let polluted =
      `Assoc
        (fields
         @ [
             ("last_continuity_update_ts", `Float 1780000000.0);
             ("continuity_summary", `String "legacy continuity prose");
           ]
         @ extra)
    in
    Fs_compat.save_file path (Yojson.Safe.pretty_to_string polluted)
  | _ -> fail "persisted keeper meta is not a JSON object"

let inject_retired_keys config name = inject_keys config name

let assoc_field json key =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let read_version config name =
  match Keeper_meta_store.read_meta config name with
  | Ok (Some meta) -> meta.Keeper_meta_contract.meta_version
  | Ok None -> fail ("keeper meta missing for " ^ name)
  | Error msg -> fail ("read_meta failed: " ^ msg)

let raw_json config name =
  Yojson.Safe.from_string (Fs_compat.load_file (keeper_file config name))

let test_drops_retired_keys_and_preserves_canonical_fields () =
  with_workspace @@ fun config ->
  write_keeper config "stale";
  inject_retired_keys config "stale";
  check bool "retired keys visible before the pass" true
    (Keeper_meta_json.unknown_keeper_meta_keys (raw_json config "stale") <> []);
  let version_before = read_version config "stale" in
  Keeper_meta_store.migrate_retired_keeper_meta_keys config;
  check (list string) "no unknown keys remain on disk" []
    (Keeper_meta_json.unknown_keeper_meta_keys (raw_json config "stale"));
  (match Keeper_meta_store.read_meta config "stale" with
   | Ok (Some meta) ->
     check string "canonical name preserved" "stale"
       meta.Keeper_meta_contract.name;
     check string "canonical agent_name preserved" "keeper-stale-agent"
       meta.Keeper_meta_contract.agent_name;
     check int "raw filter does not bump meta_version"
       version_before
       meta.Keeper_meta_contract.meta_version
   | Ok None -> fail "keeper meta vanished after retired-key migration"
   | Error msg -> fail ("read_meta after retired-key migration failed: " ^ msg))

(* Regressions from verify workflows wf_9a9ec740 / wf_ccff1ece: "unknown
   to the serializer" is not "retired". The parser still consumes keys
   the serializer never emits — TOML-owned config (autoboot_enabled),
   the fail-closed persisted compaction_mode override, and the identity
   key keeper_name (which wins over name). Only the explicitly listed
   continuity keys may be dropped; everything else survives even though
   the unknown-keys warning classifies it as unknown. *)
let test_parser_consumed_keys_survive_the_pass () =
  with_workspace @@ fun config ->
  write_keeper config "dormant";
  inject_keys config "dormant"
    ~extra:
      [
        ("autoboot_enabled", `Bool false);
        ("compaction_mode", `String "llm");
        ("keeper_name", `String "dormant");
      ];
  Keeper_meta_store.migrate_retired_keeper_meta_keys config;
  let json = raw_json config "dormant" in
  check bool "retired continuity keys dropped" true
    (assoc_field json "last_continuity_update_ts" = None
     && assoc_field json "continuity_summary" = None);
  let expect_preserved key expected =
    match assoc_field json key with
    | Some v when v = expected -> ()
    | Some other ->
      fail
        (Printf.sprintf "%s value changed: %s" key (Yojson.Safe.to_string other))
    | None ->
      fail
        (Printf.sprintf
           "%s destroyed by retired-key migration — parser-consumed value lost" key)
  in
  expect_preserved "autoboot_enabled" (`Bool false);
  expect_preserved "compaction_mode" (`String "llm");
  expect_preserved "keeper_name" (`String "dormant")

let test_clean_files_are_not_rewritten () =
  with_workspace @@ fun config ->
  write_keeper config "clean";
  let version_before = read_version config "clean" in
  Keeper_meta_store.migrate_retired_keeper_meta_keys config;
  check int "clean file keeps its meta_version (no rewrite)"
    version_before
    (read_version config "clean")

let test_second_pass_is_a_no_op () =
  with_workspace @@ fun config ->
  write_keeper config "stale";
  inject_retired_keys config "stale";
  Keeper_meta_store.migrate_retired_keeper_meta_keys config;
  (* Byte-level comparison: the raw-filter path never bumps meta_version,
     so a version check could not detect a spurious second rewrite. *)
  let bytes_after_first = Fs_compat.load_file (keeper_file config "stale") in
  Keeper_meta_store.migrate_retired_keeper_meta_keys config;
  check string "second pass leaves the file byte-identical"
    bytes_after_first
    (Fs_compat.load_file (keeper_file config "stale"))

let test_unparsable_file_is_preserved_untouched () =
  with_workspace @@ fun config ->
  write_keeper config "clean";
  let corrupt_path = keeper_file config "corrupt" in
  let corrupt_content = "{not-json" in
  Fs_compat.save_file corrupt_path corrupt_content;
  Keeper_meta_store.migrate_retired_keeper_meta_keys config;
  check string "corrupt file content preserved for operator repair"
    corrupt_content
    (Fs_compat.load_file corrupt_path)

let test_unknown_keys_pure_function () =
  let canonical_only =
    `Assoc
      (List.map
         (fun key -> (key, `Null))
         Keeper_meta_json.canonical_keeper_meta_key_names)
  in
  check (list string) "all-canonical object has no unknown keys" []
    (Keeper_meta_json.unknown_keeper_meta_keys canonical_only);
  check (list string) "retired keys are reported in order"
    [ "last_continuity_update_ts"; "continuity_summary" ]
    (Keeper_meta_json.unknown_keeper_meta_keys
       (`Assoc
         [
           ("name", `String "x");
           ("last_continuity_update_ts", `Float 0.0);
           ("continuity_summary", `String "y");
         ]));
  check (list string) "non-object JSON has no unknown keys" []
    (Keeper_meta_json.unknown_keeper_meta_keys (`String "not an object"))

let () =
  run "keeper_meta_retired_keys_migration"
    [
      ( "migrate_retired_keeper_meta_keys",
        [
          test_case "drops retired keys, preserves canonical fields"
            `Quick test_drops_retired_keys_and_preserves_canonical_fields;
          test_case "parser-consumed keys survive the pass" `Quick
            test_parser_consumed_keys_survive_the_pass;
          test_case "clean files are not rewritten" `Quick
            test_clean_files_are_not_rewritten;
          test_case "second pass is a no-op" `Quick test_second_pass_is_a_no_op;
          test_case "unparsable file is preserved untouched" `Quick
            test_unparsable_file_is_preserved_untouched;
        ] );
      ( "unknown_keeper_meta_keys",
        [
          test_case "pure key-set classification" `Quick
            test_unknown_keys_pure_function;
        ] );
    ]
