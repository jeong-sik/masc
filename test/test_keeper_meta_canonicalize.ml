(** Boot-time keeper meta canonicalization
    (Keeper_meta_store.canonicalize_persisted_meta_files).

    Reproduces the post-#23929 incident: the continuity purge removed
    [last_continuity_update_ts]/[continuity_summary] from the serializer
    but left them in persisted [.masc/keepers/*.json], so every meta read
    re-warned "has unknown keys" until an unrelated save happened to
    rewrite the file — and dormant keepers never saved. The canonicalize
    pass must converge every persisted file onto the canonical key set
    exactly once, preserve canonical field values, go through the CAS
    write path, and leave unreadable files untouched. *)

open Alcotest
open Masc

let temp_dir () =
  (* PID in the name isolates leftovers from a killed previous run —
     unseeded Random repeats the same sequence every process start. *)
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_meta_canonicalize_%d_%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  (* Swallow cleanup failures: Fun.protect would otherwise wrap them in
     Finally_raised and mask the assertion that actually failed. *)
  try rm dir with _ -> ()

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "keeper-canonicalize-agent"));
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
  Keeper_meta_store.canonicalize_persisted_meta_files config;
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
   | Ok None -> fail "keeper meta vanished after canonicalize"
   | Error msg -> fail ("read_meta after canonicalize failed: " ^ msg))

(* P2 regression (verify workflow wf_9a9ec740): "unknown to the serializer"
   is not "retired" — the parser still consumes TOML-owned keys the
   serializer never emits. A legacy file carrying autoboot_enabled=false
   plus retired continuity keys must lose ONLY the continuity keys. *)
let test_parser_consumed_config_keys_survive_the_pass () =
  with_workspace @@ fun config ->
  write_keeper config "dormant";
  inject_keys config "dormant" ~extra:[ ("autoboot_enabled", `Bool false) ];
  Keeper_meta_store.canonicalize_persisted_meta_files config;
  let json = raw_json config "dormant" in
  check bool "retired continuity keys dropped" true
    (assoc_field json "last_continuity_update_ts" = None
     && assoc_field json "continuity_summary" = None);
  (match assoc_field json "autoboot_enabled" with
   | Some (`Bool false) -> ()
   | Some other ->
     fail
       ("autoboot_enabled value changed: " ^ Yojson.Safe.to_string other)
   | None ->
     fail
       "autoboot_enabled destroyed by canonicalize — dormant keeper would \
        autoboot on next boot")

let test_clean_files_are_not_rewritten () =
  with_workspace @@ fun config ->
  write_keeper config "clean";
  let version_before = read_version config "clean" in
  Keeper_meta_store.canonicalize_persisted_meta_files config;
  check int "clean file keeps its meta_version (no rewrite)"
    version_before
    (read_version config "clean")

let test_second_pass_is_a_no_op () =
  with_workspace @@ fun config ->
  write_keeper config "stale";
  inject_retired_keys config "stale";
  Keeper_meta_store.canonicalize_persisted_meta_files config;
  let version_after_first = read_version config "stale" in
  Keeper_meta_store.canonicalize_persisted_meta_files config;
  check int "second pass does not rewrite again"
    version_after_first
    (read_version config "stale")

let test_unparsable_file_is_preserved_untouched () =
  with_workspace @@ fun config ->
  write_keeper config "clean";
  let corrupt_path = keeper_file config "corrupt" in
  let corrupt_content = "{not-json" in
  Fs_compat.save_file corrupt_path corrupt_content;
  Keeper_meta_store.canonicalize_persisted_meta_files config;
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
  run "keeper_meta_canonicalize"
    [
      ( "canonicalize_persisted_meta_files",
        [
          test_case "drops retired keys, preserves canonical fields"
            `Quick test_drops_retired_keys_and_preserves_canonical_fields;
          test_case "parser-consumed config keys survive the pass" `Quick
            test_parser_consumed_config_keys_survive_the_pass;
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
