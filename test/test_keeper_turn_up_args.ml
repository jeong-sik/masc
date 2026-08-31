open Alcotest
open Masc

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv key (Option.value previous ~default:""))
    f
;;

let test_resolve_mention_targets_uses_fallback_when_absent () =
  check
    (list string)
    "fallback targets"
    [ "existing" ]
    (Keeper_turn_up_args.resolve_mention_targets
       ~mention_targets_opt:None
       ~fallback_targets:[ "existing" ]
       ~name:"keeper-a")

let test_resolve_mention_targets_preserves_explicit_clear () =
  check
    (list string)
    "explicit clear"
    []
    (Keeper_turn_up_args.resolve_mention_targets
       ~mention_targets_opt:(Some [])
       ~fallback_targets:[ "existing" ]
       ~name:"keeper-a")

let test_resolve_mention_targets_normalizes_explicit_values () =
  check
    (list string)
    "deduped explicit targets"
    [ "alpha"; "beta" ]
    (Keeper_turn_up_args.resolve_mention_targets
       ~mention_targets_opt:(Some [ " alpha "; ""; "beta"; "alpha" ])
       ~fallback_targets:[ "existing" ]
       ~name:"keeper-a")

let override_json value = `Assoc [ "max_context_override", value ]

let rec rm_rf path =
  if Sys.is_directory path
  then (
    Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

(* Recursive, not [Unix.rmdir]: once any test in this binary has installed the
   process-global Eio fs (the persist round-trip below), later contexts can
   materialize files under their base, and an empty-dir-only cleanup fails the
   wrong test. *)
let with_test_context f =
  let base = Filename.temp_file "keeper-turn-up-args-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let ctx : _ Keeper_types_profile.context =
        { config = Workspace.default_config base
        ; agent_name = "test-agent"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = None
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      f ctx)

let test_remote_endpoint_validation () =
  with_test_context @@ fun ctx ->
  let preflight_key = "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" in
  let previous_preflight = Sys.getenv_opt preflight_key in
  Unix.putenv preflight_key "false";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv preflight_key (Option.value previous_preflight ~default:""))
  @@ fun () ->
  (* RFC-0121: the resolver reads .masc/config/runtime.toml — the path the
     live layout uses — not the .masc root this fixture used to write to. *)
  let masc_dir = Filename.concat ctx.config.base_path ".masc" in
  Unix.mkdir masc_dir 0o700;
  let config_dir = Filename.concat masc_dir "config" in
  Unix.mkdir config_dir 0o700;
  let runtime_path = Filename.concat config_dir "runtime.toml" in
  let oc = open_out_bin runtime_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      {|[exec.ssh.endpoints.fixture]
host = "fixture.invalid"
user = "masc"
remote_root = "/srv/masc/playground"
|});
  let parse fields =
    Keeper_turn_up_args.parse ctx (`Assoc (("name", `String "remote-new") :: fields))
  in
  (match parse [ "sandbox_profile", `String "remote_ssh" ] with
   | Ok _ -> fail "remote_ssh without endpoint was accepted"
   | Error result ->
     check bool "missing endpoint named" true
       (String.starts_with
          ~prefix:"remote_ssh_endpoint_missing:"
          (Keeper_types_profile.tool_result_body result)));
  (match
     parse
       [ "sandbox_profile", `String "remote_ssh"
       ; "remote_endpoint", `String "ghost"
       ]
   with
   | Ok _ -> fail "unknown endpoint was accepted"
   | Error result ->
     check bool "unknown endpoint named" true
       (String.starts_with
          ~prefix:"remote_ssh_endpoint_unknown:"
          (Keeper_types_profile.tool_result_body result)));
  (match
     parse
       [ "sandbox_profile", `String "remote_ssh"
       ; "remote_endpoint", `String "fixture"
       ]
   with
   | Error result ->
     failf "known endpoint rejected: %s"
       (Keeper_types_profile.tool_result_body result)
   | Ok parsed ->
     check bool "endpoint patch present" true parsed.remote_endpoint_present;
     check (option string) "endpoint carried" (Some "fixture")
       parsed.remote_endpoint_opt);
  (match
     parse
       [ "sandbox_profile", `String "docker"
       ; "remote_endpoint", `String "fixture"
       ]
   with
   | Ok _ -> fail "docker endpoint was accepted"
   | Error result ->
     check bool "endpoint/profile mismatch named" true
       (String.starts_with
          ~prefix:"remote_endpoint_requires_remote_ssh:"
          (Keeper_types_profile.tool_result_body result)))

let test_parse_max_context_override () =
  let check_ok label expected value =
    match Keeper_turn_up_args.parse_max_context_override (override_json value) with
    | Ok actual -> check (pair bool (option int)) label expected actual
    | Error error -> failf "%s: %s" label error
  in
  let check_error label value =
    match Keeper_turn_up_args.parse_max_context_override (override_json value) with
    | Error _ -> ()
    | Ok _ -> failf "%s unexpectedly accepted" label
  in
  check_ok "positive exact" (true, Some 128_001) (`Int 128_001);
  check_ok "zero clears" (true, None) (`Int 0);
  check_ok "null clears" (true, None) `Null;
  check_error "negative" (`Int (-1));
  check_error "fraction" (`Float 3.9);
  check_error "overflow" (`Intlit "999999999999999999999999")

let test_runtime_json_rejects_toml_owned_max_context_override () =
  let parse value =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "override-fixture"; "max_context_override", value ])
  in
  List.iter
    (fun value ->
      match parse value with
      | Error _ -> ()
      | Ok _ -> fail "TOML-owned max_context_override leaked into runtime JSON")
    [ `Int 128_001
    ; `Null
    ; `Int 0
    ; `Int (-1)
    ; `Float 3.9
    ; `Intlit "999999999999999999999999"
    ]

(* Unlike [with_test_context], persist writes the keeper TOML under the
   base, so cleanup must be recursive. *)
let with_persisting_context f =
  let base = Filename.temp_file "keeper-turn-up-persist-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      Eio_main.run @@ fun env ->
      if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      let ctx : _ Keeper_types_profile.context =
        { config = Workspace.default_config base
        ; agent_name = "test-agent"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = None
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      f ctx)

let current_revision_exn config keeper_name =
  match
    Keeper_turn_up_config_persistence.current_config_revision ~config ~keeper_name
  with
  | Ok revision -> revision
  | Error error -> failf "current revision: %s" error

let missing_config_revision :
    Keeper_turn_up_config_persistence.config_revision =
  { manifest = Keeper_turn_up_config_persistence.Missing
  ; runtime_assignment = Runtime.Runtime_config_missing
  }

let config_revision_with_manifest manifest :
    Keeper_turn_up_config_persistence.config_revision =
  { manifest; runtime_assignment = Runtime.Runtime_config_missing }

let test_remote_endpoint_persistence_round_trip () =
  with_persisting_context @@ fun ctx ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "false" @@ fun () ->
  let masc_dir = Filename.concat ctx.config.base_path ".masc" in
  if not (Sys.file_exists masc_dir) then Unix.mkdir masc_dir 0o700;
  (* RFC-0121: the resolver reads .masc/config/runtime.toml. *)
  let config_dir = Filename.concat masc_dir "config" in
  if not (Sys.file_exists config_dir) then Unix.mkdir config_dir 0o700;
  let runtime_oc = open_out_bin (Filename.concat config_dir "runtime.toml") in
  Fun.protect ~finally:(fun () -> close_out runtime_oc) (fun () ->
    output_string runtime_oc
      {|[exec.ssh.endpoints.fixture]
host = "fixture.invalid"
user = "masc"
remote_root = "/srv/masc/playground"
|});
  let name = "remote-persist-fixture" in
  let base_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String name
           ; "instructions", `String "fixture instructions"
           ])
    with
    | Ok meta -> meta
    | Error error -> failf "meta fixture: %s" error
  in
  let parse_or_fail json =
    match Keeper_turn_up_args.parse ctx json with
    | Ok parsed -> parsed
    | Error result -> failf "parse: %s" (Keeper_types_profile.tool_result_body result)
  in
  let persist parsed meta =
    match
      Keeper_turn_up_config_persistence.persist
        ~expected_revision:(current_revision_exn ctx.config name)
        ~config:ctx.config ~parsed ~meta ()
    with
    | Ok _ -> ()
    | Error error ->
      failf "persist: %s"
        (Keeper_turn_up_config_persistence.error_to_string error)
  in
  let read_back () =
    match
      Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
        ~base_path:ctx.config.base_path name
    with
    | Ok defaults -> defaults.Keeper_types_profile.remote_endpoint
    | Error error ->
      failf "read back: %s"
        (Keeper_types_profile.keeper_toml_load_error_to_string error)
  in
  let create =
    parse_or_fail
      (`Assoc
         [ "name", `String name
         ; "instructions", `String "fixture instructions"
         ; "sandbox_profile", `String "remote_ssh"
         ; "remote_endpoint", `String "fixture"
         ])
  in
  persist create
    { base_meta with sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh };
  check (option string) "remote endpoint persisted" (Some "fixture") (read_back ());
  let clear =
    parse_or_fail
      (`Assoc
         [ "name", `String name
         ; "sandbox_profile", `String "docker"
         ; "remote_endpoint", `Null
         ])
  in
  persist clear
    { base_meta with sandbox_profile = Keeper_types_profile_sandbox.Docker };
  check (option string) "remote endpoint null removes key" None (read_back ())
;;

let test_tools_patch_round_trips_and_rejects_invalid_values () =
  with_persisting_context @@ fun ctx ->
  let name = "tools-persist-fixture" in
  let base_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String name
           ; "instructions", `String "fixture instructions"
           ])
    with
    | Ok meta -> meta
    | Error error -> failf "meta fixture: %s" error
  in
  let parse json = Keeper_turn_up_args.parse ctx json in
  let parse_or_fail json =
    match parse json with
    | Ok parsed -> parsed
    | Error result ->
      failf "parse: %s" (Keeper_types_profile.tool_result_body result)
  in
  let persist parsed (meta : Keeper_meta_contract.keeper_meta) =
    match
      Keeper_turn_up_config_persistence.persist
        ~expected_revision:(current_revision_exn ctx.config meta.name)
        ~config:ctx.config
        ~parsed
        ~meta
        ()
    with
    | Ok { value = (_ : Keeper_turn_up_config_persistence.outcome); _ } -> ()
    | Error error ->
      failf "persist: %s"
        (Keeper_turn_up_config_persistence.error_to_string error)
  in
  let read_back () =
    match
      Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
        ~base_path:ctx.config.base_path
        name
    with
    | Ok defaults -> defaults
    | Error error ->
      failf "read back: %s"
        (Keeper_types_profile.keeper_toml_load_error_to_string error)
  in
  List.iter
    (fun posture ->
       let parsed =
         parse_or_fail
           (`Assoc
              [ "name", `String name
              ; "instructions", `String "fixture instructions"
              ; ( "tools"
                , `Assoc
                    [ "native", `String posture ] )
              ])
       in
       let meta = base_meta in
       persist parsed meta;
       let defaults = read_back () in
       check (option string)
         (Printf.sprintf "native %s round-trip" posture)
         (Some posture)
         (Option.map Runtime_native_tools.to_string
            defaults.native_tool_posture))
    [ "none"; "read"; "full" ];
  let clear =
    parse_or_fail
      (`Assoc
         [ "name", `String name
         ; "tools", `Assoc [ "native", `Null ]
         ])
  in
  persist clear base_meta;
  let cleared = read_back () in
  check (option string) "native null clears" None
    (Option.map Runtime_native_tools.to_string cleared.native_tool_posture);
  List.iter
    (fun (label, tools) ->
       match parse (`Assoc [ "name", `String name; "tools", tools ]) with
       | Error _ -> ()
       | Ok _ -> failf "%s was accepted" label)
    [ "invalid native", `Assoc [ "native", `String "yolo" ]
    ; "unknown group", `Assoc [ "groups", `List [ `String "filesystem" ] ]
    ; "unknown tools field", `Assoc [ "posture", `String "read" ]
    ]
;;

let test_skills_names_patch_round_trips_three_states () =
  with_persisting_context @@ fun ctx ->
  let name = "skills-persist-fixture" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String name
           ; "instructions", `String "fixture instructions"
           ])
    with
    | Ok meta -> meta
    | Error error -> failf "meta fixture: %s" error
  in
  let parse_or_fail json =
    match Keeper_turn_up_args.parse ctx json with
    | Ok parsed -> parsed
    | Error result -> failf "parse: %s" (Keeper_types_profile.tool_result_body result)
  in
  let persist parsed =
    match
      Keeper_turn_up_config_persistence.persist
        ~expected_revision:(current_revision_exn ctx.config meta.name)
        ~config:ctx.config
        ~parsed
        ~meta
        ()
    with
    | Ok { value = (_ : Keeper_turn_up_config_persistence.outcome); _ } -> ()
    | Error error ->
      failf "persist: %s"
        (Keeper_turn_up_config_persistence.error_to_string error)
  in
  let read_back () =
    match
      Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
        ~base_path:ctx.config.base_path
        name
    with
    | Ok defaults -> defaults.skill_names
    | Error error ->
      failf "read back: %s" (Keeper_types_profile.keeper_toml_load_error_to_string error)
  in
  persist
    (parse_or_fail
       (`Assoc
          [ "name", `String name
          ; "instructions", `String "fixture instructions"
          ; ( "skills"
            , `Assoc
                [ "names", `List [ `String "guide"; `String "Guide"; `String "guide" ] ] )
          ]));
  check (option (list string)) "exact names round-trip" (Some [ "guide"; "Guide" ]) (read_back ());
  persist
    (parse_or_fail
       (`Assoc [ "name", `String name; "skills", `Assoc [ "names", `List [] ] ]));
  check (option (list string)) "explicit empty round-trips" (Some []) (read_back ());
  persist
    (parse_or_fail
       (`Assoc [ "name", `String name; "skills", `Assoc [] ]));
  check (option (list string)) "empty skills patch clears to absent" None (read_back ())
;;

let test_manifest_revision_allows_only_one_stale_writer () =
  with_persisting_context @@ fun ctx ->
  let name = "manifest-cas-fixture" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String name
          ; "instructions", `String "fixture instructions"
          ])
    with
    | Ok meta -> meta
    | Error error -> failf "meta fixture: %s" error
  in
  let parse instructions =
    match
      Keeper_turn_up_args.parse ctx
        (`Assoc
          [ "name", `String name
          ; "instructions", `String instructions
          ])
    with
    | Ok parsed -> parsed
    | Error result ->
      failf "parse: %s" (Keeper_types_profile.tool_result_body result)
  in
  let initial =
    match
      Keeper_turn_up_config_persistence.persist
        ~expected_revision:missing_config_revision
        ~config:ctx.config
        ~parsed:(parse "initial")
        ~meta
        ()
    with
    | Ok _ -> current_revision_exn ctx.config name
    | Error error ->
      failf "initial persist: %s"
        (Keeper_turn_up_config_persistence.error_to_string error)
  in
  let first =
    Keeper_turn_up_config_persistence.persist
      ~expected_revision:initial
      ~config:ctx.config
      ~parsed:(parse "first writer")
      ~meta:{ meta with instructions = "first writer" }
      ()
  in
  let first_revision =
    match first with
    | Ok _ -> current_revision_exn ctx.config name
    | Error error ->
      failf "first writer: %s"
        (Keeper_turn_up_config_persistence.error_to_string error)
  in
  (match
     Keeper_turn_up_config_persistence.persist_with_publication
       ~expected_revision:first_revision
       ~config:ctx.config
       ~parsed:(parse "publication rejected")
       ~meta:{ meta with instructions = "publication rejected" }
       ~publish:(fun _runtime_transaction _ ->
         Keeper_turn_up_config_persistence.Rollback `Rejected)
       ()
   with
   | Ok { value = `Rejected; _ } -> ()
   | Ok _ -> fail "unexpected publication result"
   | Error error ->
     failf "publication rollback: %s"
       (Keeper_turn_up_config_persistence.error_to_string error));
  let after_rollback =
    match
      Keeper_turn_up_config_persistence.current_config_revision
        ~config:ctx.config
        ~keeper_name:name
    with
    | Ok revision -> revision
    | Error error -> failf "revision after rollback: %s" error
  in
  check bool "publication rejection restores exact authority bytes" true
    (after_rollback = first_revision);
  (match
     Keeper_turn_up_config_persistence.persist
       ~expected_revision:initial
       ~config:ctx.config
       ~parsed:(parse "stale writer")
       ~meta:{ meta with instructions = "stale writer" }
       ()
   with
   | Error
       (Keeper_turn_up_config_persistence.Revision_conflict
          { expected; observed }) ->
     check bool "loser carries expected revision" true (expected = initial);
     check bool "loser observes winner revision" true (observed = first_revision)
   | Error error ->
     failf "unexpected loser error: %s"
       (Keeper_turn_up_config_persistence.error_to_string error)
   | Ok _ -> fail "stale writer overwrote the winner");
  let path =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:ctx.config.Workspace.base_path
    |> fun dir -> Filename.concat dir (name ^ ".toml")
  in
  let doc =
    match
      Keeper_toml_loader.parse_toml
        (In_channel.with_open_bin path In_channel.input_all)
    with
    | Ok doc -> doc
    | Error error -> fail error
  in
  check (option string) "winner bytes remain authoritative"
    (Some "first writer")
    (Keeper_toml_loader.toml_string_opt doc "keeper.instructions")
;;

let test_rejected_create_publication_removes_manifest () =
  with_persisting_context @@ fun ctx ->
  let name = "manifest-create-rollback-fixture" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String name
          ; "instructions", `String "fixture instructions"
          ])
    with
    | Ok meta -> meta
    | Error error -> failf "meta fixture: %s" error
  in
  let parsed =
    match
      Keeper_turn_up_args.parse ctx
        (`Assoc
          [ "name", `String name
          ; "instructions", `String "fixture instructions"
          ])
    with
    | Ok parsed -> parsed
    | Error result ->
      failf "parse: %s" (Keeper_types_profile.tool_result_body result)
  in
  (match
     Keeper_turn_up_config_persistence.persist_with_publication
       ~expected_revision:missing_config_revision
       ~config:ctx.config
       ~parsed
       ~meta
       ~publish:(fun _runtime_transaction _ ->
         Keeper_turn_up_config_persistence.Rollback ())
       ()
   with
   | Ok { value = (); _ } -> ()
   | Error error ->
     failf "create rollback: %s"
       (Keeper_turn_up_config_persistence.error_to_string error));
  match
    Keeper_turn_up_config_persistence.current_config_revision
      ~config:ctx.config
      ~keeper_name:name
  with
  | Ok { manifest = Keeper_turn_up_config_persistence.Missing; _ } -> ()
  | Ok { manifest = Keeper_turn_up_config_persistence.Sha256 _; _ } ->
    fail "rejected create left a manifest behind"
  | Error error -> failf "revision after create rollback: %s" error
;;

let test_publication_rollback_restores_manifest_and_runtime_bytes () =
  with_persisting_context @@ fun ctx ->
  let name = "composite-rollback-fixture" in
  let runtime_path =
    Config_dir_resolver.runtime_toml_path_for_base_path
      ~base_path:ctx.config.base_path
  in
  Fs_compat.mkdir_p (Filename.dirname runtime_path);
  let runtime_source =
    Fs_compat.load_file (Masc_test_deps.source_path "config/runtime.toml")
  in
  Fs_compat.save_file runtime_path runtime_source;
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String name; "instructions", `String "initial" ])
    with
    | Ok meta -> meta
    | Error error -> fail error
  in
  let parse instructions =
    match
      Keeper_turn_up_args.parse ctx
        (`Assoc [ "name", `String name; "instructions", `String instructions ])
    with
    | Ok parsed -> parsed
    | Error result -> fail (Keeper_types_profile.tool_result_body result)
  in
  let initial_revision = current_revision_exn ctx.config name in
  (match
     Keeper_turn_up_config_persistence.persist
       ~expected_revision:initial_revision
       ~config:ctx.config
       ~parsed:(parse "initial")
       ~meta
       ()
   with
   | Ok _ -> ()
   | Error error ->
     fail (Keeper_turn_up_config_persistence.error_to_string error));
  let manifest_path =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:ctx.config.base_path
    |> fun dir -> Filename.concat dir (name ^ ".toml")
  in
  let manifest_before = Fs_compat.load_file manifest_path in
  let runtime_before = Fs_compat.load_file runtime_path in
  let revision = current_revision_exn ctx.config name in
  (match
     Keeper_turn_up_config_persistence.persist_with_publication
       ~expected_revision:revision
       ~config:ctx.config
       ~parsed:(parse "rejected")
       ~meta:{ meta with instructions = "rejected" }
       ~publish:(fun runtime_transaction _ ->
         match
           Runtime.commit_keeper_assignment runtime_transaction
             ~runtime_id:(Some "ollama_cloud.deepseek-v4-flash")
         with
         | Error detail -> fail detail
         | Ok _ -> Keeper_turn_up_config_persistence.Rollback ())
       ()
   with
   | Ok { value = (); _ } -> ()
   | Error error ->
     fail (Keeper_turn_up_config_persistence.error_to_string error));
  check string "Rollback restores exact manifest bytes"
    manifest_before (Fs_compat.load_file manifest_path);
  check string "Rollback restores exact runtime.toml bytes"
    runtime_before (Fs_compat.load_file runtime_path)
  ;
  let replace_file_with_parent_sync_failure path content =
    Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
      ~sync_parent:(fun _ -> raise (Failure "injected runtime parent sync"))
      path content
  in
  let commit_revision = current_revision_exn ctx.config name in
  let uncertain_commit =
    Keeper_turn_up_config_persistence.persist_with_publication
      ~expected_revision:commit_revision
      ~config:ctx.config
      ~parsed:(parse "uncertain runtime commit")
      ~meta:{ meta with instructions = "uncertain runtime commit" }
      ~publish:(fun runtime_transaction _ ->
        match
          Runtime.Assignment_for_testing.commit_with_replace_file
            ~replace_file:replace_file_with_parent_sync_failure
            runtime_transaction
            ~runtime_id:(Some "ollama_cloud.deepseek-v4-flash")
        with
        | Error detail -> fail detail
        | Ok runtime_write ->
          Keeper_turn_up_config_persistence.Commit_with_warnings
            ( (),
              Keeper_turn_up_config_persistence
              .warnings_of_runtime_assignment_write runtime_write ))
      ()
  in
  (match uncertain_commit with
   | Error error ->
     fail
       ("uncertain runtime commit was not preserved: "
        ^ Keeper_turn_up_config_persistence.error_to_string error)
   | Ok { warnings; _ } ->
     check bool "runtime commit durability warning is visible" true
       (List.exists
          (function
            | Keeper_turn_up_config_persistence
              .Runtime_config_parent_sync_unconfirmed _ -> true
            | _ -> false)
          warnings));
  let manifest_before_uncertain_restore = Fs_compat.load_file manifest_path in
  let runtime_before_uncertain_restore = Fs_compat.load_file runtime_path in
  let restore_revision = current_revision_exn ctx.config name in
  (match
     Keeper_turn_up_config_persistence.For_testing
     .persist_with_runtime_restore_replace_file
       ~replace_file:replace_file_with_parent_sync_failure
       ~expected_revision:restore_revision
       ~config:ctx.config
       ~parsed:(parse "uncertain runtime restore")
       ~meta:{ meta with instructions = "uncertain runtime restore" }
       ~publish:(fun runtime_transaction _ ->
         match
           Runtime.commit_keeper_assignment runtime_transaction ~runtime_id:None
         with
         | Error detail -> fail detail
         | Ok _ -> Keeper_turn_up_config_persistence.Rollback ())
       ()
   with
   | Error
       (Keeper_turn_up_config_persistence.Composite_reconciliation_required
         { manifest = None; runtime_assignment = Some state }) ->
     check bool "runtime restore uncertainty is explicit" true
       (String.length state.detail > 0)
   | Error error ->
     fail
       ("unexpected uncertain restore result: "
        ^ Keeper_turn_up_config_persistence.error_to_string error)
   | Ok _ -> fail "uncertain runtime restore was reported as exact");
  check string "uncertain restore still restores visible manifest bytes"
    manifest_before_uncertain_restore (Fs_compat.load_file manifest_path);
  check string "uncertain restore still restores visible runtime bytes"
    runtime_before_uncertain_restore (Fs_compat.load_file runtime_path)
;;

let run_cas_child base name expected_hex instructions ready_path start_path =
  let ready = Unix.openfile ready_path [ Unix.O_WRONLY ] 0 in
  let start = Unix.openfile start_path [ Unix.O_RDONLY ] 0 in
  ignore (Unix.write_substring ready "r" 0 1);
  let token = Bytes.create 1 in
  ignore (Unix.read start token 0 1);
  Unix.close ready;
  Unix.close start;
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let ctx : _ Keeper_types_profile.context =
    { config = Workspace.default_config base
    ; agent_name = "cas-child"
    ; sw
    ; clock = Eio.Stdenv.clock env
    ; proc_mgr = None
    ; net = None
    ; publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider
    }
  in
  let parsed =
    match
      Keeper_turn_up_args.parse ctx
        (`Assoc
           [ "name", `String name; "instructions", `String instructions ])
    with
    | Ok parsed -> parsed
    | Error _ -> exit 3
  in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String name; "instructions", `String instructions ])
    with
    | Ok meta -> meta
    | Error _ -> exit 3
  in
  match
    Keeper_turn_up_config_persistence.persist
      ~expected_revision:
        (config_revision_with_manifest
           (Keeper_turn_up_config_persistence.Sha256 expected_hex))
      ~config:ctx.config
      ~parsed
      ~meta
      ()
  with
  | Ok _ -> exit 0
  | Error (Keeper_turn_up_config_persistence.Revision_conflict _) -> exit 2
  | Error _ -> exit 3
;;

let test_two_processes_same_revision_have_one_winner () =
  with_persisting_context @@ fun ctx ->
  let name = "manifest-two-process-cas-fixture" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String name; "instructions", `String "initial" ])
    with
    | Ok meta -> meta
    | Error error -> fail error
  in
  let parsed =
    match
      Keeper_turn_up_args.parse ctx
        (`Assoc
           [ "name", `String name; "instructions", `String "initial" ])
    with
    | Ok parsed -> parsed
    | Error result -> fail (Keeper_types_profile.tool_result_body result)
  in
  let expected =
    match
      Keeper_turn_up_config_persistence.persist
        ~expected_revision:missing_config_revision
        ~config:ctx.config
        ~parsed
        ~meta
        ()
    with
    | Ok
        { value =
            { revision = Keeper_turn_up_config_persistence.Sha256 value; _ }
        ; _
        } -> value
    | Ok _ -> fail "initial manifest did not produce a sha256 revision"
    | Error error ->
      fail (Keeper_turn_up_config_persistence.error_to_string error)
  in
  let ready_path = Filename.concat ctx.config.base_path "cas-ready.fifo" in
  let start_path = Filename.concat ctx.config.base_path "cas-start.fifo" in
  Unix.mkfifo ready_path 0o600;
  Unix.mkfifo start_path 0o600;
  let ready = Unix.openfile ready_path [ Unix.O_RDWR ] 0o600 in
  let start = Unix.openfile start_path [ Unix.O_RDWR ] 0o600 in
  let spawn instructions =
    Unix.create_process
      Sys.executable_name
      [| Sys.executable_name
       ; "--keeper-manifest-cas-child"
       ; ctx.config.base_path
       ; name
       ; expected
       ; instructions
       ; ready_path
       ; start_path
      |]
      Unix.stdin
      Unix.stdout
      Unix.stderr
  in
  let read_two_ready_bytes () =
    let bytes = Bytes.create 2 in
    let rec loop offset =
      if offset < 2
      then loop (offset + Unix.read ready bytes offset (2 - offset))
    in
    loop 0
  in
  let first = spawn "first process" in
  let second = spawn "second process" in
  read_two_ready_bytes ();
  ignore (Unix.write_substring start "ss" 0 2);
  Unix.close ready;
  Unix.close start;
  let rec status pid =
    match Unix.waitpid [] pid with
    | _, status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> status pid
  in
  let statuses = [ status first; status second ] in
  check int "one process commits" 1
    (List.length (List.filter (( = ) (Unix.WEXITED 0)) statuses));
  check int "one stale process conflicts" 1
    (List.length (List.filter (( = ) (Unix.WEXITED 2)) statuses))
;;

let test_revision_projection_holds_manifest_lock () =
  with_persisting_context @@ fun ctx ->
  let name = "manifest-projection-lock-fixture" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String name; "instructions", `String "initial" ])
    with
    | Ok meta -> meta
    | Error error -> fail error
  in
  let parse instructions =
    match
      Keeper_turn_up_args.parse ctx
        (`Assoc
           [ "name", `String name; "instructions", `String instructions ])
    with
    | Ok parsed -> parsed
    | Error result -> fail (Keeper_types_profile.tool_result_body result)
  in
  let initial =
    match
      Keeper_turn_up_config_persistence.persist
        ~expected_revision:missing_config_revision
        ~config:ctx.config
        ~parsed:(parse "initial")
        ~meta
        ()
    with
    | Ok _ -> current_revision_exn ctx.config name
    | Error error ->
      fail (Keeper_turn_up_config_persistence.error_to_string error)
  in
  let writer_started, resolve_writer_started = Eio.Promise.create () in
  let writer_done, resolve_writer_done = Eio.Promise.create () in
  let runtime_reader_started, resolve_runtime_reader_started = Eio.Promise.create () in
  let runtime_reader_done, resolve_runtime_reader_done = Eio.Promise.create () in
  let runtime_path =
    Config_dir_resolver.runtime_toml_path_for_base_path
      ~base_path:ctx.config.base_path
  in
  let projected =
    Keeper_turn_up_config_persistence.with_current_config_revision
      ~config:ctx.config
      ~keeper_name:name
      (fun revision ->
        Eio.Fiber.fork ~sw:ctx.sw (fun () ->
          Eio.Promise.resolve resolve_writer_started ();
          let result =
            Keeper_turn_up_config_persistence.persist
              ~expected_revision:revision
              ~config:ctx.config
              ~parsed:(parse "writer")
              ~meta:{ meta with instructions = "writer" }
              ()
          in
          Eio.Promise.resolve resolve_writer_done result);
        Eio.Fiber.fork ~sw:ctx.sw (fun () ->
          Eio.Promise.resolve resolve_runtime_reader_started ();
          let result =
            Runtime.observe_keeper_assignment ~runtime_config_path:runtime_path
              ~keeper_name:name ()
          in
          Eio.Promise.resolve resolve_runtime_reader_done result);
        Eio.Promise.await writer_started;
        Eio.Promise.await runtime_reader_started;
        Eio.Fiber.yield ();
        check bool "writer is fenced during projection" true
          (Option.is_none (Eio.Promise.peek writer_done));
        check bool "runtime projection is fenced during paired GET" true
          (Option.is_none (Eio.Promise.peek runtime_reader_done));
        revision)
  in
  (match projected with
   | Ok { value; _ } ->
     check bool "projection observed initial revision" true (value = initial)
   | Error error -> fail error);
  (match Eio.Promise.await writer_done with
   | Ok _ -> ()
   | Error error ->
     fail (Keeper_turn_up_config_persistence.error_to_string error))
  ;
  (match Eio.Promise.await runtime_reader_done with
   | Ok _ -> ()
   | Error error -> fail error)
;;

let test_release_failure_preserves_committed_receipt () =
  with_persisting_context @@ fun ctx ->
  let name = "manifest-release-receipt-fixture" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String name; "instructions", `String "committed" ])
    with
    | Ok meta -> meta
    | Error error -> fail error
  in
  let parsed =
    match
      Keeper_turn_up_args.parse ctx
        (`Assoc
           [ "name", `String name; "instructions", `String "committed" ])
    with
    | Ok parsed -> parsed
    | Error result -> fail (Keeper_types_profile.tool_result_body result)
  in
  let lock_path =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:ctx.config.Workspace.base_path
    |> fun dir -> Filename.concat dir (name ^ ".toml.lock")
  in
  let release_failure =
    { File_lock_eio.lock_path
    ; phase = File_lock_eio.Release_process_lock
    ; cause =
        { File_lock_eio.error = Unix.EIO
        ; operation = "injected_release_after_commit"
        ; argument = lock_path
        }
    ; cleanup_failure = None
    }
  in
  match
    Keeper_turn_up_config_persistence.For_testing.persist_with_release_failure
      ~release_failure
      ~expected_revision:missing_config_revision
      ~config:ctx.config
      ~parsed
      ~meta
      ()
  with
  | Error error ->
    fail (Keeper_turn_up_config_persistence.error_to_string error)
  | Ok
      { value =
          { revision = Keeper_turn_up_config_persistence.Sha256 _; _ }
      ; warnings
      } ->
    check int "commit returns one typed release warning" 1 (List.length warnings);
    check bool "warning is lock release uncertainty" true
      (match warnings with
       | [ Keeper_turn_up_config_persistence.Lock_release_unconfirmed _ ] -> true
       | _ -> false)
  | Ok _ -> fail "commit receipt did not carry a sha256 revision"
;;

let test_rollback_after_rename_failure_requires_reconciliation () =
  with_persisting_context @@ fun ctx ->
  let name = "manifest-rollback-reconciliation-fixture" in
  let meta instructions =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String name; "instructions", `String instructions ])
    with
    | Ok meta -> meta
    | Error error -> fail error
  in
  let parse instructions =
    match
      Keeper_turn_up_args.parse ctx
        (`Assoc [ "name", `String name; "instructions", `String instructions ])
    with
    | Ok parsed -> parsed
    | Error result -> fail (Keeper_types_profile.tool_result_body result)
  in
  let initial =
    match
      Keeper_turn_up_config_persistence.persist
        ~expected_revision:missing_config_revision
        ~config:ctx.config
        ~parsed:(parse "initial")
        ~meta:(meta "initial")
        ()
    with
    | Ok _ -> current_revision_exn ctx.config name
    | Error error ->
      fail (Keeper_turn_up_config_persistence.error_to_string error)
  in
  (match
     Keeper_turn_up_config_persistence.For_testing.persist_with_rollback_parent_sync_failure
       ~expected_revision:initial
       ~config:ctx.config
       ~parsed:(parse "rejected")
       ~meta:(meta "rejected")
       ()
   with
   | Error
       (Keeper_turn_up_config_persistence.Composite_reconciliation_required
          { manifest = Some state; runtime_assignment = None }) ->
     check bool "observed authority is the restored snapshot" true
       (state.observed
        = Keeper_turn_up_config_persistence.Observed_revision initial.manifest)
   | Error error ->
     fail
       ("unexpected rollback error: "
        ^ Keeper_turn_up_config_persistence.error_to_string error)
   | Ok _ -> fail "after-rename rollback failure was reported as committed");
  check bool "cache-invalidated read sees restored bytes" true
    (current_revision_exn ctx.config name = initial)
;;

let test_publication_exception_restores_missing_manifest () =
  with_persisting_context @@ fun ctx ->
  let name = "manifest-publication-exception-fixture" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String name; "instructions", `String "initial" ])
    with
    | Ok meta -> meta
    | Error error -> fail error
  in
  let parsed =
    match
      Keeper_turn_up_args.parse ctx
        (`Assoc [ "name", `String name; "instructions", `String "initial" ])
    with
    | Ok parsed -> parsed
    | Error result -> fail (Keeper_types_profile.tool_result_body result)
  in
  (match
     Keeper_turn_up_config_persistence.persist_with_publication
       ~expected_revision:missing_config_revision
       ~config:ctx.config
       ~parsed
       ~meta
       ~publish:(fun _runtime_transaction _ ->
         raise (Failure "injected publication exception"))
       ()
   with
   | Error (Keeper_turn_up_config_persistence.Publication_exception _) -> ()
   | Error error ->
     fail
       ("unexpected publication error: "
        ^ Keeper_turn_up_config_persistence.error_to_string error)
   | Ok _ -> fail "raising publication was reported as committed");
  check bool "publication exception leaves no orphan manifest" true
    (current_revision_exn ctx.config name
     = missing_config_revision)
;;

let test_post_write_revision_failure_restores_missing_manifest () =
  with_persisting_context @@ fun ctx ->
  let name = "manifest-post-write-read-fixture" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String name; "instructions", `String "initial" ])
    with
    | Ok meta -> meta
    | Error error -> fail error
  in
  let parsed =
    match
      Keeper_turn_up_args.parse ctx
        (`Assoc [ "name", `String name; "instructions", `String "initial" ])
    with
    | Ok parsed -> parsed
    | Error result -> fail (Keeper_types_profile.tool_result_body result)
  in
  (match
     Keeper_turn_up_config_persistence.For_testing
     .persist_with_post_write_revision_failure
       ~expected_revision:missing_config_revision
       ~config:ctx.config
       ~parsed
       ~meta
       ()
   with
   | Error (Keeper_turn_up_config_persistence.Io_error _) -> ()
   | Error error ->
     fail
       ("unexpected post-write read error: "
        ^ Keeper_turn_up_config_persistence.error_to_string error)
   | Ok _ -> fail "post-write revision failure was reported as committed");
  check bool "post-write revision failure leaves no orphan manifest" true
    (current_revision_exn ctx.config name
     = missing_config_revision)
;;

(* masc#25767: masc_keeper_up described itself as "Create or update a durable keeper"
   while creation required a sandbox_profile readable only from a keeper TOML the tool
   does not write. The argument was parsed and honoured on update but ignored by the
   create gate, so a keeper that did not already exist on disk could not be created —
   the reason the APC run's librarian role was never registered. *)
let test_requested_sandbox_profile_wins_over_the_toml_fallback () =
  let module A = Keeper_turn_up_args in
  check
    bool
    "an explicit request creates without a TOML default"
    true
    (A.resolve_sandbox_profile ~requested:"docker" ~fallback:None ()
     = Some Keeper_types_profile_toml_io.Docker);
  check
    bool
    "an explicit request overrides the TOML default"
    true
    (A.resolve_sandbox_profile
       ~requested:"microvm"
       ~fallback:(Some Keeper_types_profile_toml_io.Docker)
       ()
     = Some Keeper_types_profile_toml_io.Micro_vm);
  check
    bool
    "\"local\" no longer names a profile"
    true
    (A.resolve_sandbox_profile ~requested:"local" ~fallback:None () = None);
  check
    bool
    "no request keeps the TOML default"
    true
    (A.resolve_sandbox_profile
       ~fallback:(Some Keeper_types_profile_toml_io.Docker)
       ()
     = Some Keeper_types_profile_toml_io.Docker);
  (* Unparseable is treated as absent rather than mapped to a profile: the tool gate
     rejects it before this point, and inventing an isolation boundary here would hide
     that rejection if the gate were ever bypassed. *)
  check
    bool
    "an unparseable request falls back rather than choosing a boundary"
    true
    (A.resolve_sandbox_profile
       ~requested:"chroot"
       ~fallback:(Some Keeper_types_profile_toml_io.Docker)
       ()
     = Some Keeper_types_profile_toml_io.Docker);
  (* Nothing stated is not a profile. It used to resolve to [Local], so every
     omission came back as "local is disabled" -- a refusal naming a value the
     caller never wrote. The caller now reports the missing field. *)
  check
    bool
    "neither stated resolves to no profile at all"
    true
    (A.resolve_sandbox_profile ~fallback:None () = None)
;;

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

(* task-895: parse used to read its fields and silently drop the rest — a
   caller sending merge_existing / keep_warm / stash_untracked watched the
   field vanish with no error. The gate must reject every key the parse body
   does not consume, and the known set must stay derived from that body,
   not from a stale schema list. *)
let test_parse_rejects_unknown_keys () =
  with_test_context @@ fun ctx ->
  List.iter
    (fun (label, field) ->
       match
         Keeper_turn_up_args.parse ctx
           (`Assoc [ "name", `String "unknown-args-fixture"; field ])
       with
       | Error result ->
         check bool (label ^ " rejected as unknown") true
           (contains "[turn_up_arg_unknown] unknown keeper_up argument(s):"
              (Keeper_types_profile.tool_result_body result))
       | Ok _ -> failf "%s was silently accepted" label)
    [ "merge_existing", ("merge_existing", `Bool true)
    ; "keep_warm", ("keep_warm", `Bool false)
    ; "stash_untracked", ("stash_untracked", `String "yes")
    ];
  check (list string) "known set is exactly the parse-consumed keys"
    (List.sort String.compare
       [ "name"; "runtime_id"; "autoboot_enabled"; "mention_targets"
       ; "max_context_override"; "proactive_enabled"; "sandbox_profile"
       ; "remote_endpoint"; "network_mode"; "tools"; "skills"; "instructions"
       ])
    (List.sort String.compare Keeper_turn_up_args.known_turn_up_args);
  (match
     Keeper_turn_up_args.parse ctx
       (`Assoc
          [ "name", `String "unknown-args-fixture"
          ; "zzz_late", `Bool true
          ; "aaa_early", `Bool true
          ])
   with
   | Error result ->
     let body = Keeper_types_profile.tool_result_body result in
     check bool "every unknown key is named" true
       (contains "aaa_early" body && contains "zzz_late" body)
   | Ok _ -> fail "multiple unknown keys were silently accepted");
  (match
     Keeper_turn_up_args.parse ctx
       (`Assoc
          [ "name", `String "unknown-args-fixture"
          (* The tool schema defaults this to "docker"; [parse] is called
             directly here, so the fixture states what the schema would. *)
          ; "sandbox_profile", `String "docker"
          ; "instructions", `String "still fine"
          ])
   with
   | Ok _ -> ()
   | Error result ->
     failf "known key rejected: %s"
       (Keeper_types_profile.tool_result_body result))

let () =
  match Array.to_list Sys.argv with
  | [ _
    ; "--keeper-manifest-cas-child"
    ; base
    ; name
    ; expected
    ; instructions
    ; ready_path
    ; start_path
    ] ->
    run_cas_child base name expected instructions ready_path start_path
  | _ ->
  run
    "keeper_turn_up_args"
    [ ( "mention_targets"
      , [ test_case
            "absent mention_targets uses fallback"
            `Quick
            test_resolve_mention_targets_uses_fallback_when_absent
        ; test_case
            "explicit empty mention_targets clears"
            `Quick
            test_resolve_mention_targets_preserves_explicit_clear
        ; test_case
            "explicit mention_targets normalize and dedupe"
            `Quick
            test_resolve_mention_targets_normalizes_explicit_values
        ] )
    ; ( "unknown_keys"
      , [ test_case
            "unknown arguments are rejected, not silently dropped"
            `Quick
            test_parse_rejects_unknown_keys
        ] )
    ; ( "sandbox_profile"
      , [ test_case
            "requested profile wins over the TOML fallback"
            `Quick
            test_requested_sandbox_profile_wins_over_the_toml_fallback
        ; test_case
            "remote endpoint required and registry-resolved"
            `Quick
            test_remote_endpoint_validation
        ; test_case
            "remote endpoint persists and null clears"
            `Quick
            test_remote_endpoint_persistence_round_trip
        ] )
    ; ( "max_context_override"
      , [ test_case "request values are exact or rejected" `Quick test_parse_max_context_override
        ; test_case "runtime JSON rejects TOML-owned field" `Quick
            test_runtime_json_rejects_toml_owned_max_context_override
        ] )
    ; ( "tools"
      , [ test_case
            "groups/native round-trip, clear, and invalid rejection"
            `Quick
            test_tools_patch_round_trips_and_rejects_invalid_values
        ] )
    ; ( "skills"
      , [ test_case
            "names round-trip absent, empty, and exact values"
            `Quick
            test_skills_names_patch_round_trips_three_states
        ; test_case
            "one expected revision commits exactly one writer"
            `Quick
            test_manifest_revision_allows_only_one_stale_writer
        ; test_case
            "rejected create publication leaves manifest missing"
            `Quick
            test_rejected_create_publication_removes_manifest
        ; test_case
            "publication rollback restores both config authorities"
            `Quick
            test_publication_rollback_restores_manifest_and_runtime_bytes
        ; test_case
            "two processes with one revision produce one winner"
            `Quick
            test_two_processes_same_revision_have_one_winner
        ; test_case
            "revision projection and meta read share the manifest lock"
            `Quick
            test_revision_projection_holds_manifest_lock
        ; test_case
            "release failure preserves committed receipt"
            `Quick
            test_release_failure_preserves_committed_receipt
        ; test_case
            "rollback after rename failure requires reconciliation"
            `Quick
            test_rollback_after_rename_failure_requires_reconciliation
        ; test_case
            "publication exception restores missing manifest"
            `Quick
            test_publication_exception_restores_missing_manifest
        ; test_case
            "post-write revision failure restores missing manifest"
            `Quick
            test_post_write_revision_failure_restores_missing_manifest
        ] )
    ]
;;
