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

(* Every case below is about some other argument, and [parse] refuses a call
   that states no [sandbox_profile], so the fixture states one rather than
   leaving it out. That the argument is required at all is pinned once, by
   [test_parse_requires_a_sandbox_profile], instead of being restated in each
   case. *)
(* This suite runs on hosts without a Docker daemon, and the profile the
   fixture states is [docker], so [parse] would otherwise shell out to
   [docker info] on every case. [None] is what the real probe answers when
   the preflight master switch is off. The cases that pin the probe itself
   pass their own. *)
let no_daemon_in_this_suite ?image:_ ~timeout_sec:_ () = None

let parse_stating_a_profile ctx json =
  let json =
    match json with
    | `Assoc fields when not (List.mem_assoc "sandbox_profile" fields) ->
      `Assoc (fields @ [ "sandbox_profile", `String "docker" ])
    | other -> other
  in
  Keeper_turn_up_args.parse ~docker_preflight:no_daemon_in_this_suite ctx json
;;
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
    parse_stating_a_profile ctx (`Assoc (("name", `String "remote-new") :: fields))
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
    match parse_stating_a_profile ctx json with
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
  let parse json = parse_stating_a_profile ctx json in
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
    match parse_stating_a_profile ctx json with
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
      parse_stating_a_profile ctx
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
      parse_stating_a_profile ctx
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
      parse_stating_a_profile ctx
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
      parse_stating_a_profile ctx
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
      parse_stating_a_profile ctx
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
      parse_stating_a_profile ctx
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
      parse_stating_a_profile ctx
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
      parse_stating_a_profile ctx
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
      parse_stating_a_profile ctx
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
      parse_stating_a_profile ctx
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

(* The form an operator edits and the parse that answers it drifted: the stem
   named two fields while [parse] required a third, so every keeper created
   through the TUI came back rejected and nothing failed until a human tried
   it. Running the stem through [parse] moves that cost here. *)
let test_the_creation_stem_is_a_declaration_parse_accepts () =
  with_test_context
  @@ fun ctx ->
  let json =
    match Yojson.Safe.from_string Keeper_turn_up_args.creation_stem with
    | json -> json
    | exception Yojson.Json_error message ->
      failf "the stem must be JSON: %s" message
  in
  match
    Keeper_turn_up_args.parse ~docker_preflight:no_daemon_in_this_suite ctx json
  with
  | Ok _ -> ()
  | Error result ->
    failf
      "the stem the form offers must be a declaration parse accepts: %s"
      (Keeper_types_profile.tool_result_body result)
;;

(* [network_mode] was resolved twice, and the two answers disagreed: update
   read the caller's argument, create computed one from [profile_defaults] and
   dropped the caller's. A keeper created for web search landed on "none" and
   its operator edited the TOML by hand. The four cases below hold the shared
   resolver to what both branches now need. *)
let test_a_requested_network_mode_survives_the_fallback () =
  let module A = Keeper_turn_up_args in
  check
    bool
    "the caller's inherit wins over a declared none"
    true
    (A.resolve_requested_network_mode
       ~requested:(Some "inherit")
       ~sandbox_profile:Keeper_types_profile_sandbox.Docker
       ~fallback:(Some Keeper_types_profile_sandbox.Network_none)
     = Ok Keeper_types_profile_sandbox.Network_inherit)
;;

let test_an_absent_network_mode_takes_the_declared_fallback () =
  let module A = Keeper_turn_up_args in
  check
    bool
    "no argument takes the TOML declaration"
    true
    (A.resolve_requested_network_mode
       ~requested:None
       ~sandbox_profile:Keeper_types_profile_sandbox.Docker
       ~fallback:(Some Keeper_types_profile_sandbox.Network_inherit)
     = Ok Keeper_types_profile_sandbox.Network_inherit);
  check
    bool
    "no argument and no declaration takes the docker default"
    true
    (A.resolve_requested_network_mode
       ~requested:None
       ~sandbox_profile:Keeper_types_profile_sandbox.Docker
       ~fallback:None
     = Ok Keeper_types_profile_sandbox.Network_none)
;;

let test_a_network_mode_rejection_names_every_accepted_spelling () =
  let module A = Keeper_turn_up_args in
  match
    A.resolve_requested_network_mode
      ~requested:(Some "lan")
      ~sandbox_profile:Keeper_types_profile_sandbox.Docker
      ~fallback:None
  with
  | Ok _ -> failf "an unparseable network_mode must not resolve"
  | Error message ->
    List.iter
      (fun spelling ->
         check
           bool
           (Printf.sprintf "the rejection names %s" spelling)
           true
           (contains spelling message))
      Keeper_types_profile_sandbox.valid_network_mode_strings
;;

(* The pair that a create wrote and the next config load refused. [remote_ssh]
   is transport-only, so it cannot cut the guest off from the network; the
   keeper TOML parser has always said so, and the resolver did not, which let
   a create write a file that the loader would not read back. The resolver
   answers now, before the meta is built. *)
(* Every profile against every mode, from the module's own enumerations.

   The pairs used to be hand-picked here, and a hand-picked set is one a new
   variant walks past: [Network_policy] arrived in #33085 while
   [network_mode_rejection] was being written in #33092, each PR green against
   a base without the other, and main merged with three pairs undecided. The
   function's comment had promised that exactly this could not happen -- "a
   new profile or a new mode fails to compile here until someone decides its
   answer" -- and it was right about the compiler and silent about two green
   PRs landing minutes apart.

   So the table is walked rather than sampled. A new profile or mode fails
   here until its answer is written down, whichever order the PRs land in. *)
let test_every_profile_and_mode_pair_has_a_decided_answer () =
  let module S = Keeper_types_profile_sandbox in
  let expected profile mode =
    match profile, mode with
    (* microVM is the backend policy mode was built for. *)
    | S.Micro_vm, _ -> `Accepted
    | S.Docker, (S.Network_none | S.Network_inherit) -> `Accepted
    (* RFC-0415: the Docker egress boundary is unmeasured. *)
    | S.Docker, S.Network_policy -> `Refused
    | S.Remote_ssh, S.Network_inherit -> `Accepted
    (* Phase 1 is transport-only and holds no network knob. *)
    | S.Remote_ssh, (S.Network_none | S.Network_policy) -> `Refused
  in
  List.iter
    (fun profile ->
       List.iter
         (fun mode ->
            let label =
              Printf.sprintf
                "%s + %s"
                (S.sandbox_profile_to_string profile)
                (S.network_mode_to_string mode)
            in
            match S.network_mode_rejection profile mode, expected profile mode with
            | None, `Accepted -> ()
            | Some _, `Refused -> ()
            | Some message, `Accepted ->
              failf "%s must be accepted, and was refused: %s" label message
            | None, `Refused -> failf "%s must be refused, and was accepted" label)
         S.all_network_modes)
    S.all_sandbox_profiles
;;

(* A refusal an operator cannot act on is one they file a bug about, so each
   names the profile, the mode, and what to do instead. *)
let test_every_refusal_names_the_pair_it_refuses () =
  let module S = Keeper_types_profile_sandbox in
  List.iter
    (fun profile ->
       List.iter
         (fun mode ->
            match S.network_mode_rejection profile mode with
            | None -> ()
            | Some message ->
              let names needle =
                check
                  bool
                  (Printf.sprintf
                     "the refusal of %s + %s names %S"
                     (S.sandbox_profile_to_string profile)
                     (S.network_mode_to_string mode)
                     needle)
                  true
                  (contains needle message)
              in
              names (S.sandbox_profile_to_string profile);
              names (S.network_mode_to_string mode))
         S.all_network_modes)
    S.all_sandbox_profiles
;;

let test_remote_ssh_refuses_a_network_mode_it_cannot_hold () =
  let module A = Keeper_turn_up_args in
  (match
     A.resolve_requested_network_mode
       ~requested:(Some "none")
       ~sandbox_profile:Keeper_types_profile_sandbox.Remote_ssh
       ~fallback:None
   with
   | Ok _ ->
     failf "remote_ssh with network_mode none must not resolve: the loader refuses it"
   | Error message ->
     check
       bool
       "the refusal carries the config loader's own code"
       true
       (contains "remote_ssh_no_network_mode" message));
  (* The pair remote_ssh does hold, and the docker pairs, still resolve: the
     check refuses one combination, not the field. *)
  check
    bool
    "remote_ssh with inherit resolves"
    true
    (A.resolve_requested_network_mode
       ~requested:(Some "inherit")
       ~sandbox_profile:Keeper_types_profile_sandbox.Remote_ssh
       ~fallback:None
     = Ok Keeper_types_profile_sandbox.Network_inherit);
  check
    bool
    "docker with none resolves"
    true
    (A.resolve_requested_network_mode
       ~requested:(Some "none")
       ~sandbox_profile:Keeper_types_profile_sandbox.Docker
       ~fallback:None
     = Ok Keeper_types_profile_sandbox.Network_none)
;;

(* The stem carries an empty string for this one field on purpose: "none"
   blocks the guest's network and "inherit" opens it, and a form that suggests
   either decides for an operator who is not reading it. A value that parses
   would restore exactly the trap the form exists to close. *)
let test_the_creation_stem_network_mode_is_not_a_mode () =
  let declared =
    match Yojson.Safe.from_string Keeper_turn_up_args.creation_stem with
    | `Assoc fields ->
      (match List.assoc_opt "network_mode" fields with
       | Some (`String raw) -> raw
       | Some _ | None -> failf "the stem must carry a network_mode string")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      failf "the stem must be a JSON object"
  in
  check
    bool
    "the stem's network_mode is not a mode any parse accepts"
    true
    (Option.is_none (Keeper_types_profile_sandbox.network_mode_of_string declared))
;;

let preflight_fixture ~ok : Keeper_sandbox_runtime.docker_preflight =
  { ok
  ; image = "masc-keeper-sandbox:local"
  ; docker_runtime_ok = ok
  ; docker_runtime_error =
      (if ok
       then None
       else
         Some
           "docker info failed while validating sandbox runtime: failed to connect to \
            the docker API at unix:///fixture/docker.sock")
  ; hardening_ok = true
  ; hardening_error = None
  ; image_present = true
  ; image_error = None
  ; failure_classes = (if ok then [] else [ "docker_runtime_error" ])
  ; next_actions =
      (if ok
       then []
       else [ "Ensure Docker is installed and the daemon is reachable from this shell." ])
  }
;;

let docker_args ~profile =
  `Assoc [ "name", `String "preflight-fixture"; "sandbox_profile", `String profile ]
;;

(* new-keeper, 2026-09-02: admitted from the TUI in 33 ms on a host with no
   daemon, then every Execute failed on docker_container_probe_failed until
   it was purged eleven minutes later. The refusal belongs at admission. *)
let test_docker_profile_is_refused_when_its_preflight_fails () =
  with_test_context
  @@ fun ctx ->
  let probes = ref 0 in
  let docker_preflight ?image:_ ~timeout_sec:_ () =
    incr probes;
    Some (preflight_fixture ~ok:false)
  in
  match Keeper_turn_up_args.parse ~docker_preflight ctx (docker_args ~profile:"docker") with
  | Ok _ -> fail "a docker keeper whose daemon the preflight cannot reach was admitted"
  | Error result ->
    let body = Keeper_types_profile.tool_result_body result in
    check bool "named under the shared label" true
      (String.starts_with
         ~prefix:(Keeper_sandbox_runtime.docker_preflight_failed_label ^ ":")
         body);
    check bool "carries the probe error" true
      (contains "failed to connect to the docker API" body);
    check bool "carries the next action" true
      (contains "Ensure Docker is installed" body);
    check int "probed once" 1 !probes
;;

let test_docker_profile_is_admitted_when_its_preflight_passes () =
  with_test_context
  @@ fun ctx ->
  let probes = ref 0 in
  let docker_preflight ?image:_ ~timeout_sec:_ () =
    incr probes;
    Some (preflight_fixture ~ok:true)
  in
  (match Keeper_turn_up_args.parse ~docker_preflight ctx (docker_args ~profile:"docker") with
   | Ok _ -> ()
   | Error result ->
     failf
       "a docker keeper with a passing preflight was refused: %s"
       (Keeper_types_profile.tool_result_body result));
  check int "probed once" 1 !probes
;;

let test_docker_profile_preflights_sandbox_image_override () =
  with_test_context
  @@ fun ctx ->
  let name = "docker-image-override-keeper" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:ctx.config.Workspace.base_path
  in
  Fs_compat.mkdir_p keepers_dir;
  let toml_path = Filename.concat keepers_dir (name ^ ".toml") in
  let toml_content =
    {|[keeper]
instructions = "test instructions"
sandbox_profile = "docker"
sandbox_image = "masc-keeper-sandbox:local"
|}
  in
  let oc = open_out_bin toml_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc toml_content);
  let checked_image = ref None in
  let docker_preflight ?image ~timeout_sec:_ () =
    checked_image := image;
    Some (preflight_fixture ~ok:true)
  in
  (match
     Keeper_turn_up_args.parse
       ~docker_preflight
       ctx
       (`Assoc [ "name", `String name ])
   with
   | Ok _ -> ()
   | Error result ->
     failf
       "keeper with sandbox_image override should be admitted: %s"
       (Keeper_types_profile.tool_result_body result));
  check
    (option string)
    "docker preflight received sandbox_image override from toml"
    (Some "masc-keeper-sandbox:local")
    !checked_image
;;

let test_docker_profile_preflights_default_image_when_override_absent () =
  with_test_context
  @@ fun ctx ->
  let name = "docker-default-image-keeper" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:ctx.config.Workspace.base_path
  in
  Fs_compat.mkdir_p keepers_dir;
  let toml_path = Filename.concat keepers_dir (name ^ ".toml") in
  let toml_content =
    {|[keeper]
instructions = "test instructions"
sandbox_profile = "docker"
|}
  in
  let oc = open_out_bin toml_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc toml_content);
  let checked_image = ref (Some "initial") in
  let docker_preflight ?image ~timeout_sec:_ () =
    checked_image := image;
    Some (preflight_fixture ~ok:true)
  in
  (match
     Keeper_turn_up_args.parse
       ~docker_preflight
       ctx
       (`Assoc [ "name", `String name ])
   with
   | Ok _ -> ()
   | Error result ->
     failf
       "keeper without sandbox_image override should be admitted: %s"
       (Keeper_types_profile.tool_result_body result));
  check
    (option string)
    "docker preflight received None when sandbox_image absent"
    None
    !checked_image
;;

(* The master switch off ([None]) admits without a verdict, and no other
   profile consults the docker probe at all. *)
let test_docker_preflight_is_consulted_only_for_the_docker_profile () =
  with_test_context
  @@ fun ctx ->
  let probes = ref 0 in
  let switched_off ?image:_ ~timeout_sec:_ () =
    incr probes;
    None
  in
  (match Keeper_turn_up_args.parse ~docker_preflight:switched_off ctx (docker_args ~profile:"docker") with
   | Ok _ -> ()
   | Error result ->
     failf
       "docker with the preflight switched off must be admitted: %s"
       (Keeper_types_profile.tool_result_body result));
  check int "docker consulted the probe" 1 !probes;
  let failing ?image:_ ~timeout_sec:_ () =
    incr probes;
    Some (preflight_fixture ~ok:false)
  in
  (match Keeper_turn_up_args.parse ~docker_preflight:failing ctx (docker_args ~profile:"microvm") with
   | Ok _ -> ()
   | Error result ->
     failf
       "microvm must not be judged by the docker preflight: %s"
       (Keeper_types_profile.tool_result_body result));
  check int "microvm never consulted the probe" 1 !probes
;;

(* The schema the model reads and the parse that answers it have to say the
   same thing about [sandbox_profile]. They did not: the schema advertised
   [default = "docker"] -- nothing in masc applies it, it is a statement to
   the caller that omitting the field is safe -- while [parse] rejects the
   omission and the same param's own description says "Pass explicitly".
   #32078 settled which one is right: absence is an error, because "execution
   outside a boundary is not a profile the fleet offers".

   Pinned from both sides so removing either half fails: the schema must not
   offer a default, and the parse must still refuse the omission. A later
   change that re-adds the default has to delete this test to do it. *)
let test_the_schema_does_not_promise_a_default_parse_refuses () =
  let schema =
    match
      List.find_opt
        (fun (schema : Masc_domain.tool_schema) ->
           String.equal schema.name "masc_keeper_up")
        Masc.Keeper_schema.schemas
    with
    | Some schema -> schema.input_schema
    | None -> fail "masc_keeper_up must have a schema"
  in
  let advertised_default =
    Yojson.Safe.Util.(
      schema
      |> member "properties"
      |> member "sandbox_profile"
      |> member "default")
  in
  check
    bool
    "the schema offers no default for sandbox_profile"
    true
    (advertised_default = `Null);
  with_test_context
  @@ fun ctx ->
  match
    Keeper_turn_up_args.parse ctx (`Assoc [ "name", `String "no-default-fixture" ])
  with
  | Error _ -> ()
  | Ok _ -> fail "omitting sandbox_profile must stay an error"
;;

let test_parse_requires_a_sandbox_profile () =
  with_test_context @@ fun ctx ->
  match
    Keeper_turn_up_args.parse ctx (`Assoc [ "name", `String "no-profile-fixture" ])
  with
  | Error result ->
    check
      bool
      "the rejection names the three profiles"
      true
      (contains
         "docker, microvm, remote_ssh"
         (Keeper_types_profile.tool_result_body result))
  | Ok _ ->
    fail "a keeper_up call that states no sandbox_profile must be rejected"
;;

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
         parse_stating_a_profile ctx
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
       ; "remote_endpoint"; "network_mode"; "egress_allow"; "tools"; "skills"
       ; "instructions"
       ])
    (List.sort String.compare Keeper_turn_up_args.known_turn_up_args);
  (match
     parse_stating_a_profile ctx
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
     parse_stating_a_profile ctx
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
            "a call that states no sandbox_profile is rejected"
            `Quick
            test_parse_requires_a_sandbox_profile
        ; test_case
            "the creation stem is a declaration parse accepts"
            `Quick
            test_the_creation_stem_is_a_declaration_parse_accepts
        ; test_case
            "the schema does not promise a default parse refuses"
            `Quick
            test_the_schema_does_not_promise_a_default_parse_refuses
        ; test_case
            "remote endpoint required and registry-resolved"
            `Quick
            test_remote_endpoint_validation
        ; test_case
            "docker profile is refused when its preflight fails"
            `Quick
            test_docker_profile_is_refused_when_its_preflight_fails
        ; test_case
            "docker profile is admitted when its preflight passes"
            `Quick
            test_docker_profile_is_admitted_when_its_preflight_passes
        ; test_case
            "docker profile preflights sandbox_image override"
            `Quick
            test_docker_profile_preflights_sandbox_image_override
        ; test_case
            "docker profile preflights default image when override absent"
            `Quick
            test_docker_profile_preflights_default_image_when_override_absent
        ; test_case
            "docker preflight is consulted only for the docker profile"
            `Quick
            test_docker_preflight_is_consulted_only_for_the_docker_profile
        ; test_case
            "remote endpoint persists and null clears"
            `Quick
            test_remote_endpoint_persistence_round_trip
        ] )
    ; ( "network_mode"
      , [ test_case
            "a requested mode survives the fallback"
            `Quick
            test_a_requested_network_mode_survives_the_fallback
        ; test_case
            "an absent mode takes the declared fallback"
            `Quick
            test_an_absent_network_mode_takes_the_declared_fallback
        ; test_case
            "a rejection names every accepted spelling"
            `Quick
            test_a_network_mode_rejection_names_every_accepted_spelling
        ; test_case
            "every profile and mode pair has a decided answer"
            `Quick
            test_every_profile_and_mode_pair_has_a_decided_answer
        ; test_case
            "every refusal names the pair it refuses"
            `Quick
            test_every_refusal_names_the_pair_it_refuses
        ; test_case
            "remote_ssh refuses a mode it cannot hold"
            `Quick
            test_remote_ssh_refuses_a_network_mode_it_cannot_hold
        ; test_case
            "the creation stem's network_mode is not a mode"
            `Quick
            test_the_creation_stem_network_mode_is_not_a_mode
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
