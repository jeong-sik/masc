module P = Masc.Keeper_turn_up_config_persistence

let write path content =
  Out_channel.with_open_bin path (fun channel -> output_string channel content)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun entry -> remove (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
    Unix.unlink path

let with_receiver f =
  let base = Filename.temp_file "masc-declaration-import-" "" in
  Unix.unlink base;
  Unix.mkdir base 0o700;
  let keys = ["MASC_CONFIG_DIR"; "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE"] in
  let saved = List.map (fun key -> key, Sys.getenv_opt key) keys in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (key, value) -> match value with
        | Some value -> Unix.putenv key value
        | None -> Unix.unsetenv key) saved;
      remove base)
    (fun () ->
      Unix.unsetenv "MASC_CONFIG_DIR";
      Unix.putenv "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true";
      Eio_main.run (fun env ->
        if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
        let config = Masc.Workspace.default_config base in
        f config))

let manifest config name =
  Config_dir_resolver.keeper_toml_path_for_base_path
    ~base_path:config.Masc.Workspace.base_path name

let runtime_path config =
  Config_dir_resolver.runtime_toml_path_for_base_path
    ~base_path:config.Masc.Workspace.base_path

let journal config =
  Keeper_config_journal.journal_path_for_base_path
    ~base_path:config.Masc.Workspace.base_path

let observe config keeper_name =
  match P.current_config_revision ~config ~keeper_name with
  | Ok revision -> revision
  | Error detail -> Alcotest.fail detail

let load config keeper_name =
  match Masc.Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
      ~base_path:config.Masc.Workspace.base_path keeper_name with
  | Ok defaults -> defaults
  | Error error ->
    Alcotest.fail (Masc.Keeper_types_profile.keeper_toml_load_error_to_string error)

let commit ~config ~keeper_name ~expected_revision ~content ~publish =
  match P.commit_declaration ~config ~keeper_name ~expected_revision ~content ~publish () with
  | Ok receipt -> receipt.value
  | Error error -> Alcotest.fail (P.declaration_error_to_string error)

let complete = {|# Preserve authored formatting and explicit empty selections.
[keeper]
instructions = "Full authored configuration. 한글"
sandbox_profile = "docker"
sandbox_image = "base"
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

let omitted = {|[keeper]
instructions = "Old authored instructions."
sandbox_profile = "docker"
sandbox_image = "base"
|}

let runtime = {|# This complete source must not be rewritten by a declaration import.
[runtime]
default = "portable.model"
[runtime.assignments]
alpha = "portable.model"
beta = "other.model"
|}

let test_create_preserves_complete_source () = with_receiver (fun config ->
  let expected_revision = observe config "alpha" in
  let published = ref false in
  let revision = commit ~config ~keeper_name:"alpha" ~expected_revision ~content:complete
      ~publish:(fun outcome revision ->
        Alcotest.(check bool) "new declaration" true outcome.P.created;
        Alcotest.(check string) "committed bytes visible to publication" complete
          (Fs_compat.load_file outcome.path);
        Alcotest.(check bool) "recovery authority retired before publication" false
          (Sys.file_exists (journal config));
        published := true;
        revision) in
  Alcotest.(check bool) "publication occurred" true !published;
  Alcotest.(check bool) "new revision identifies committed configuration" true
    (observe config "alpha" = revision);
  Alcotest.(check bool) "no Runtime or assignment is invented" false
    (Sys.file_exists (runtime_path config));
  let loaded = load config "alpha" in
  Alcotest.(check (option (list string))) "explicit empty skills" (Some []) loaded.skill_names;
  Alcotest.(check (option (list string))) "explicit empty attached tools" (Some [])
    loaded.attached_tool_allow;
  Alcotest.(check (option bool)) "false remains authored false" (Some false) loaded.always_allow;
  Alcotest.(check (list (pair string string))) "complete environment survives"
    ["PORTABLE_VALUE", "retained"] loaded.agent_core_env)

let test_replace_preserves_receiver_runtime_and_pause () = with_receiver (fun config ->
  ignore (observe config "alpha");
  write (runtime_path config) runtime;
  write (manifest config "alpha") omitted;
  write (manifest config "beta") complete;
  let held_meta = match Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String "alpha"; "instructions", `String "old meta";
               "paused", `Bool true]) with
    | Ok meta -> meta
    | Error detail -> Alcotest.fail detail in
  let expected_revision = observe config "alpha" in
  ignore (commit ~config ~keeper_name:"alpha" ~expected_revision ~content:complete
    ~publish:(fun _ revision -> revision));
  Alcotest.(check string) "Runtime source and both assignments unchanged" runtime
    (Fs_compat.load_file (runtime_path config));
  Alcotest.(check string) "other Keeper unchanged" complete
    (Fs_compat.load_file (manifest config "beta"));
  match Masc.Keeper_meta_contract.effective_meta_result
      ~base_path:config.Masc.Workspace.base_path held_meta with
  | Error detail -> Alcotest.fail detail
  | Ok effective ->
    Alcotest.(check bool) "existing owner remains paused" true effective.paused;
    Alcotest.(check string) "fresh read uses imported instructions"
      "Full authored configuration. 한글" effective.instructions)

let test_stale_source_refuses_without_publication () =
  List.iter (fun change_runtime -> with_receiver (fun config ->
    ignore (observe config "alpha");
    write (runtime_path config) runtime;
    write (manifest config "alpha") omitted;
    let expected_revision = observe config "alpha" in
    let winner_path = if change_runtime then runtime_path config else manifest config "alpha" in
    let winner = Fs_compat.load_file winner_path ^ "\n# A later operator edit.\n" in
    write winner_path winner;
    let published = ref false in
    (match P.commit_declaration ~config ~keeper_name:"alpha" ~expected_revision
        ~content:complete ~publish:(fun _ _ -> published := true) () with
     | Error (P.Configuration_error (P.Revision_conflict _)) -> ()
     | Error error -> Alcotest.fail (P.declaration_error_to_string error)
     | Ok _ -> Alcotest.fail "stale source overwrote the later operator edit");
    Alcotest.(check bool) "conflicting candidate was not published" false !published;
    Alcotest.(check string) "winning edit retained" winner (Fs_compat.load_file winner_path);
    Alcotest.(check string) "rejected candidate did not change declaration"
      (if change_runtime then omitted else winner)
      (Fs_compat.load_file (manifest config "alpha"));
    Alcotest.(check bool) "conflict stages no recovery authority" false
      (Sys.file_exists (journal config)))) [false; true]

let test_invalid_source_writes_nothing () = with_receiver (fun config ->
  let expected_revision = observe config "alpha" in
  let published = ref false in
  List.iter (fun content ->
    match P.commit_declaration ~config ~keeper_name:"alpha" ~expected_revision ~content
        ~publish:(fun _ _ -> published := true) () with
    | Error (P.Invalid_declaration _) -> ()
    | Error error -> Alcotest.fail (P.declaration_error_to_string error)
    | Ok _ -> Alcotest.fail "invalid authored declaration was committed")
    [ "[keeper]\ninstructions = \"valid\"\ninvented_setting = true\n"
    ; "[keeper]\nname = \"another\"\ninstructions = \"valid\"\n"
    ; "[keeper]\ninstructions = \"\"\n" ];
  (match P.commit_declaration ~config ~keeper_name:"../escape" ~expected_revision
      ~content:complete ~publish:(fun _ _ -> published := true) () with
   | Error (P.Invalid_keeper_name _) -> ()
   | Error error -> Alcotest.fail (P.declaration_error_to_string error)
   | Ok _ -> Alcotest.fail "invalid Keeper name was admitted");
  Alcotest.(check bool) "no invalid candidate published" false !published;
  Alcotest.(check bool) "no invalid declaration created" false
    (Sys.file_exists (manifest config "alpha"));
  Alcotest.(check bool) "no recovery journal staged" false (Sys.file_exists (journal config)))

let test_later_owner_refusal_retains_committed_source () = with_receiver (fun config ->
  let expected_revision = observe config "alpha" in
  let result, revision = commit ~config ~keeper_name:"alpha" ~expected_revision
      ~content:complete ~publish:(fun _ revision -> Error "owner busy", revision) in
  Alcotest.(check (result unit string)) "owner result is separate" (Error "owner busy") result;
  Alcotest.(check bool) "committed revision remains current" true
    (observe config "alpha" = revision);
  Alcotest.(check string) "owner refusal did not roll back source" complete
    (Fs_compat.load_file (manifest config "alpha"));
  Alcotest.(check bool) "no stale before-image can overwrite a later edit" false
    (Sys.file_exists (journal config)))

let () = Alcotest.run "Keeper declaration import"
  [ "receiver configuration", [
      Alcotest.test_case "create complete authored declaration" `Quick test_create_preserves_complete_source;
      Alcotest.test_case "replace without resuming or rerouting" `Quick test_replace_preserves_receiver_runtime_and_pause;
      Alcotest.test_case "reject stale manifest and Runtime revisions" `Quick test_stale_source_refuses_without_publication;
      Alcotest.test_case "refuse invalid declaration before effects" `Quick test_invalid_source_writes_nothing;
      Alcotest.test_case "retain commit after owner refusal" `Quick test_later_owner_refusal_retains_committed_source
    ] ]
