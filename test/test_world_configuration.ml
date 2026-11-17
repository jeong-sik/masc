module Bundle = Masc.World_configuration_bundle
module Capture = Masc.World_configuration_capture

let write path content = Out_channel.with_open_bin path (fun output -> output_string output content)

let rec mkdir path =
  if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path

let with_fixture f = Eio_main.run (fun _env ->
  let base = Filename.temp_file "masc-world-configuration-" "" in
  Unix.unlink base;
  Unix.mkdir base 0o700;
  let keys = ["MASC_CONFIG_DIR"; "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE"] in
  let saved = List.map (fun key -> key, Sys.getenv_opt key) keys in
  Fun.protect ~finally:(fun () ->
    List.iter (fun (key, value) -> match value with
      | None -> Unix.unsetenv key | Some value -> Unix.putenv key value) saved;
    remove base) (fun () ->
    Unix.unsetenv "MASC_CONFIG_DIR";
    Unix.putenv "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true";
    let config = Config_dir_resolver.base_path_config_root ~cwd:base base in
    mkdir (Filename.concat config "keepers");
    f ~base ~config))

let keeper = {|# portable authored declaration
[keeper]
instructions = "Keep the whole configuration. 한글"
board_interests = []
always_allow = false
voice_always_allow = false
telemetry_feedback_enabled = false
[keeper.skills]
names = []
[keeper.tools]
attached_allow = []
deny = []
[keeper.agent_core_env]
PORTABLE_VALUE = "retained"
|}

let runtime = {|# Preserve provider declarations, not only assignments.
[runtime]
default = "portable.model"
[runtime.assignments]
alpha = "portable.model"
[providers.portable]
protocol = "openai-compatible-http"
endpoint = "https://provider.invalid/v1"
[providers.portable.credentials]
env = "PORTABLE_API_KEY"
|}

let capture base = match Capture.capture ~base_path:base with
  | Ok receipt -> receipt.bundle
  | Error error -> Alcotest.fail (Capture.error_to_string error)

let decode text = match Bundle.of_string text with
  | Ok bundle -> bundle
  | Error error -> Alcotest.fail (Bundle.error_to_string error)

let install ~base ~config =
  write (Filename.concat config Config_dir_resolver.runtime_toml_filename) runtime;
  write (Filename.concat config "keepers/alpha.toml") keeper;
  let path = Filename.concat (Config_dir_resolver.masc_root ~base_path:base)
    Prompt_override_persistence.filename in
  let entry : Prompt_override_persistence.entry =
    { key = "keeper"; value = "Authored prompt.";
      authored_against = Prompt_override_persistence.default_revision ~body:"Original default.";
      template_variables = [] } in
  match Prompt_override_persistence.save ~path [entry] with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Prompt_override_persistence.error_to_string error)

let test_full_documents () = with_fixture (fun ~base ~config ->
  install ~base ~config;
  let beta = "[keeper]\ninstructions = \"A second Keeper with omitted tools and skills.\"\n" in
  write (Filename.concat config "keepers/beta.toml") beta;
  let overrides = Fs_compat.load_file
    (Filename.concat (Config_dir_resolver.masc_root ~base_path:base)
      Prompt_override_persistence.filename) in
  let original = capture base in
  let bundle = decode (Bundle.to_string original) in
  Alcotest.(check (option string)) "complete Runtime and credential reference survive"
    (Some runtime) (Option.map (fun (source : Bundle.source) -> source.content) bundle.runtime);
  Alcotest.(check (option string)) "override provenance envelope survives"
    (Some overrides) (Option.map (fun (source : Bundle.source) -> source.content) bundle.overrides);
  Alcotest.(check (list (pair string string))) "whole Keeper TOML survives including empty/false fields"
    ["alpha", keeper; "beta", beta]
    (List.map (fun (keeper : Bundle.keeper) -> keeper.name, keeper.declaration.content) bundle.keepers);
  Alcotest.(check bool) "re-export preserves the complete bundle"
    true (Bundle.to_yojson original = Bundle.to_yojson bundle))

let test_invalid_keeper_is_not_dropped () = with_fixture (fun ~base ~config ->
  install ~base ~config;
  write (Filename.concat config "keepers/broken.toml")
    "[keeper]\ninstructions = \"Valid text\"\ninvented_setting = true\n";
  match Capture.capture ~base_path:base with
  | Error (Capture.Invalid_bundle (Bundle.Invalid_document {document = Keeper "broken"; _})) -> ()
  | Error error -> Alcotest.fail (Capture.error_to_string error)
  | Ok _ -> Alcotest.fail "an invalid member must not become a smaller complete fleet")

let test_keeper_identity_must_match () = with_fixture (fun ~base ~config ->
  install ~base ~config;
  write (Filename.concat config "keepers/broken.toml")
    "[keeper]\nname = \"another\"\ninstructions = \"A different identity\"\n";
  match Capture.capture ~base_path:base with
  | Error (Capture.Invalid_bundle (Bundle.Invalid_document {document = Keeper "broken"; _})) -> ()
  | Error error -> Alcotest.fail (Capture.error_to_string error)
  | Ok _ -> Alcotest.fail "a filename and declaration identity mismatch must be refused")

let test_symlink_is_not_followed () = with_fixture (fun ~base ~config ->
  install ~base ~config;
  let outside = Filename.concat base "outside.toml" in
  write outside keeper;
  Unix.symlink outside (Filename.concat config "keepers/escape.toml");
  match Capture.capture ~base_path:base with
  | Error (Capture.Read_failed _) -> ()
  | Error error -> Alcotest.fail (Capture.error_to_string error)
  | Ok _ -> Alcotest.fail "export must not follow a declaration outside its owned root")

let test_changed_payload_digest () = with_fixture (fun ~base ~config ->
  install ~base ~config;
  let json = Bundle.to_yojson (capture base) in
  let changed = match json with
    | `Assoc fields ->
      let runtime = match List.assoc "runtime" fields with
        | `Assoc source -> `Assoc (("content", `String "[changed]\n") :: List.remove_assoc "content" source)
        | _ -> Alcotest.fail "fixture Runtime missing" in
      `Assoc (("runtime", runtime) :: List.remove_assoc "runtime" fields)
    | _ -> Alcotest.fail "fixture bundle missing" in
  match Bundle.of_yojson changed with
  | Error (Bundle.Digest_mismatch Runtime) -> ()
  | Error error -> Alcotest.fail (Bundle.error_to_string error)
  | Ok _ -> Alcotest.fail "changed payload must not retain the old source identity")

let test_absence_is_preserved () = with_fixture (fun ~base ~config:_ ->
  let bundle = decode (Bundle.to_string (capture base)) in
  Alcotest.(check bool) "missing Runtime is absent, not an invented configuration" true (bundle.runtime = None);
  Alcotest.(check bool) "missing overrides stay absent" true (bundle.overrides = None);
  Alcotest.(check int) "empty readable Keeper directory" 0 (List.length bundle.keepers))

let test_resolved_root_alias () = with_fixture (fun ~base ~config ->
  install ~base ~config;
  let other_base = Filename.concat base "other-world" in
  mkdir (Config_dir_resolver.masc_root ~base_path:other_base);
  Unix.putenv "MASC_CONFIG_DIR" config;
  let bundle = capture other_base in
  Alcotest.(check string) "actual shared config root is recorded" config bundle.origin.config_root;
  Alcotest.(check string) "explicit workspace identity is retained" other_base bundle.origin.base_path;
  Alcotest.(check int) "the aliased root's Keeper is exported" 1 (List.length bundle.keepers);
  Alcotest.(check bool) "overrides belong to the explicit workspace, not the aliased config root"
    true (bundle.overrides = None))

let () = Alcotest.run "World_configuration"
  ["documents", [
    Alcotest.test_case "full authored documents survive export and decode" `Quick test_full_documents;
    Alcotest.test_case "invalid Keeper is not silently omitted" `Quick test_invalid_keeper_is_not_dropped;
    Alcotest.test_case "Keeper identity matches its filename" `Quick test_keeper_identity_must_match;
    Alcotest.test_case "declaration symlink stays outside the export" `Quick test_symlink_is_not_followed;
    Alcotest.test_case "changed payload cannot retain its digest" `Quick test_changed_payload_digest;
    Alcotest.test_case "missing documents preserve absence" `Quick test_absence_is_preserved;
    Alcotest.test_case "BasePaths can alias the resolved config root" `Quick test_resolved_root_alias;
  ]]
