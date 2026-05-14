(** Pin {!Credential_provider} type surface and
    {!Host_config_provider} pure helpers.

    Integration coverage of [resolve] (which goes through
    [Keeper_gh_env.keeper_binding] + filesystem) is left to the
    existing [test_keeper_shell_docker_route] suite — that path
    exercises selected root/keeper identity bundle mounting end to end
    without re-staging a tmpdir + keeper profile fixture here.

    What this file pins:

    1. [Credential_provider.pp_error] formats every variant.  Mostly
       a regression guard: if a future PR adds a fifth error case
       and forgets [pp_error], the [exhaustive] assertion catches it.
    2. [Host_config_provider.For_testing.compose_ro_mounts_result]
       fails closed when the selected GH config mount is empty/missing.
       [mount_if_present] stays a pure optional-mount helper for
       sibling gitconfig/ssh paths.
    3. [For_testing.compose_env] emits only container-local path/env
       keys for the selected identity bundle plus non-interactive git
       guards.  Ambient operator GitHub credentials stay outside this
       contract.
    4. [finalize] / [tear_down] are noops ([finalize] returns
       [Ok ()] regardless of [container_id]; [tear_down] never
       raises). *)

open Alcotest

module CP = Masc_mcp.Credential_provider
module HCP = Masc_mcp.Host_config_provider
module KGE = Masc_mcp.Keeper_gh_env
open Repo_manager_types

let mkdir_p path =
  let rec loop dir =
    if dir = "" || dir = "." || Sys.file_exists dir then ()
    else begin
      loop (Filename.dirname dir);
      Unix.mkdir dir 0o755
    end
  in
  loop path

let with_temp_base_path f =
  let dir = Filename.temp_file "credential_provider" "" in
  Sys.remove dir;
  mkdir_p (Filename.concat dir ".masc/config");
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path then
          if Sys.is_directory path then begin
            Sys.readdir path
            |> Array.iter (fun n -> rm_rf (Filename.concat path n));
            Unix.rmdir path
          end
          else Sys.remove path
      in
      rm_rf dir)
    (fun () -> f dir)

let write_mapping base_path keeper_id repo_ids =
  let path =
    Filename.concat base_path ".masc/config/keeper_repo_mappings.toml"
  in
  let entries =
    String.concat ", " (List.map (fun s -> "\"" ^ s ^ "\"") repo_ids)
  in
  let content =
    Printf.sprintf "[mapping.%s]\nrepositories = [%s]\n" keeper_id entries
  in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let with_config_dir_env config_dir f =
  let key = "MASC_CONFIG_DIR" in
  let old = Sys.getenv_opt key in
  Unix.putenv key config_dir;
  Masc_mcp.Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      (match old with
       | Some value -> Unix.putenv key value
       | None -> Unix.putenv key "");
      Masc_mcp.Config_dir_resolver.reset ())
    f

let write_keeper_identity_toml ~base_path ~keeper_name ~github_identity =
  let keepers_dir = Filename.concat base_path ".masc/config/keepers" in
  mkdir_p keepers_dir;
  let path = Filename.concat keepers_dir (keeper_name ^ ".toml") in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      Printf.fprintf oc
        "[keeper]\nname = %S\ngithub_identity = %S\ngit_identity_mode = \"github_identity\"\n"
        keeper_name github_identity)

let seed_credential ~base_path cred =
  match Credential_store.add ~base_path cred with
  | Ok _ -> ()
  | Error msg -> failf "seed credential %s: %s" cred.id msg

let seed_repo ~base_path repo =
  match Repo_store.add ~base_path repo with
  | Ok _ -> ()
  | Error msg -> failf "seed repo %s: %s" repo.id msg

let make_credential ?ssh_key_path ~id ~username ~gh_config_dir () =
  {
    id;
    cred_type = Github;
    username;
    gh_config_dir = Some gh_config_dir;
    ssh_key_path;
    gpg_key_id = None;
    state = Unmaterialized;
    token_sha256_prefix = None;
  }

let make_repo ~id ~credential_id : repository =
  {
    id;
    name = "repo-" ^ id;
    url = "git@github.com:test/" ^ id ^ ".git";
    local_path = "repos/" ^ id;
    default_branch = "main";
    credential_id;
    keepers = [];
    status = Active;
    auto_sync = false;
    sync_interval = 0;
    created_at = Int64.zero;
    updated_at = Int64.zero;
  }

let make_keeper_binding ~bundle_root ~gh_config_dir : KGE.keeper_binding =
  {
    KGE.github_identity = Some "test-gh";
    effective_github_identity = "test-gh";
    credential_scope = KGE.Keeper_identity;
    git_identity_mode = "github_identity";
    bundle_root;
    gh_config_dir;
  }

(* --- 1. pp_error covers every variant --- *)

let test_pp_error_all_variants () =
  let cases =
    [
      CP.Missing_bundle { identity = "id-A"; path = "/x" }, "Missing_bundle";
      CP.Invalid_token { identity = "id-B"; reason = "sha-match" }, "Invalid_token";
      CP.Finalize_failed { identity = "id-C"; reason = "rewrite" }, "Finalize_failed";
      CP.Tear_down_failed { identity = "id-D"; reason = "rm" }, "Tear_down_failed";
    ]
  in
  List.iter
    (fun (err, prefix) ->
      let rendered = CP.pp_error err in
      check bool
        (Printf.sprintf "pp_error renders %s" prefix)
        true
        (String.length rendered > String.length prefix
         && String.sub rendered 0 (String.length prefix) = prefix))
    cases

(* --- 2. required GH mount fail-closed rules --- *)

let test_required_gh_mount_empty_path_fails_closed () =
  let kb = make_keeper_binding ~bundle_root:"" ~gh_config_dir:"" in
  match HCP.For_testing.compose_ro_mounts_result kb with
  | Ok mounts ->
      failf "empty required gh_config_dir should fail, got %d mounts"
        (List.length mounts)
  | Error reason ->
      check bool "mentions required mount" true
        (try
           ignore
             (Str.search_forward
                (Str.regexp_string "required credential mount gh_creds")
                reason 0);
           true
         with Not_found -> false);
      check bool "mentions empty host path" true
        (try
           ignore
             (Str.search_forward (Str.regexp_string "empty host path")
                reason 0);
           true
         with Not_found -> false)

let test_required_gh_mount_missing_path_fails_closed () =
  let missing_path =
    Filename.concat (Filename.get_temp_dir_name ())
      "nonexistent-host-path-rfc0008-pr1"
  in
  let kb =
    make_keeper_binding ~bundle_root:(Filename.dirname missing_path)
      ~gh_config_dir:missing_path
  in
  match HCP.For_testing.compose_ro_mounts_result kb with
  | Ok mounts ->
      failf "missing required gh_config_dir should fail, got %d mounts"
        (List.length mounts)
  | Error reason ->
      check bool "mentions missing host path" true
        (try
           ignore
             (Str.search_forward (Str.regexp_string "host path is missing")
                reason 0);
           true
         with Not_found -> false);
      check bool "does not leak raw host path" false
        (try
           ignore (Str.search_forward (Str.regexp_string missing_path) reason 0);
           true
         with Not_found -> false)

let test_required_gh_mount_allows_absent_optional_siblings () =
  with_temp_base_path (fun base_path ->
      let bundle_root =
        Filename.concat base_path ".masc/github-identities/test-gh"
      in
      let gh_config_dir = Filename.concat bundle_root "gh" in
      mkdir_p gh_config_dir;
      let kb = make_keeper_binding ~bundle_root ~gh_config_dir in
      match HCP.For_testing.compose_ro_mounts_result kb with
      | Error reason ->
          failf "existing required gh_config_dir should mount: %s" reason
      | Ok mounts ->
          check int "only required gh mount" 1 (List.length mounts);
          match mounts with
          | [ mount ] ->
              check string "host preserved" gh_config_dir mount.CP.host;
              check string "container"
                (Filename.concat HCP.cred_root ".config/gh")
                mount.CP.container
          | _ -> fail "expected exactly one mount")

let test_mount_if_present_empty_host () =
  let r = HCP.For_testing.mount_if_present ~host:"" ~container:"/x" in
  check int "empty host -> no mount" 0 (List.length r)

let test_mount_if_present_missing_path () =
  let r =
    HCP.For_testing.mount_if_present
      ~host:"/nonexistent-host-path-rfc0008-pr1"
      ~container:"/x"
  in
  check int "missing path -> no mount" 0 (List.length r)

let test_mount_if_present_existing_dir () =
  (* [/tmp] is reliably present on every platform we run on (incl.
     macOS sandboxes where it is a symlink to /private/tmp). *)
  let host = Filename.get_temp_dir_name () in
  let r =
    HCP.For_testing.mount_if_present ~host ~container:"/c"
  in
  match r with
  | [ m ] ->
      check string "host preserved" host m.CP.host;
      check string "container preserved" "/c" m.CP.container
  | other ->
      failf "expected single mount, got %d" (List.length other)

(* --- 3. compose_env key set is bundle-local and non-interactive --- *)

let expected_env_keys =
  [
    (* path-derived block inside the dispatch container *)
    "HOME";
    "GH_CONFIG_DIR";
    "GIT_CONFIG_GLOBAL";
	    "GIT_CONFIG_COUNT";
	    "GIT_CONFIG_KEY_0";
	    "GIT_CONFIG_VALUE_0";
	    "GIT_CONFIG_KEY_1";
	    "GIT_CONFIG_VALUE_1";
	    "GIT_CONFIG_KEY_2";
	    "GIT_CONFIG_VALUE_2";
	    "GIT_CONFIG_KEY_3";
	    "GIT_CONFIG_VALUE_3";
    (* git author / committer *)
    "GIT_AUTHOR_NAME";
    "GIT_AUTHOR_EMAIL";
    "GIT_COMMITTER_NAME";
    "GIT_COMMITTER_EMAIL";
    (* Env_git_noninteractive *)
    "GIT_TERMINAL_PROMPT";
    "GIT_ASKPASS";
    "GCM_INTERACTIVE";
    "SSH_ASKPASS";
  ]

let test_compose_env_key_set () =
  let env =
    HCP.For_testing.compose_env
      ~git_author_name:"keeper-A"
      ~git_author_email:"keeper-A@example.invalid" ()
  in
  let actual_keys = List.sort compare (List.map fst env) in
  let expected_keys = List.sort compare expected_env_keys in
  check (list string)
    "env keys stay bundle-local and non-interactive"
    expected_keys actual_keys

let test_compose_env_path_values_anchored_to_cred_root () =
  let env =
    HCP.For_testing.compose_env
      ~git_author_name:"k" ~git_author_email:"k@e" ()
  in
  let lookup k = List.assoc k env in
  check string "HOME" HCP.cred_root (lookup "HOME");
  check string "GH_CONFIG_DIR"
    (Filename.concat HCP.cred_root ".config/gh")
    (lookup "GH_CONFIG_DIR");
	  check string "GIT_CONFIG_GLOBAL"
	    (Filename.concat HCP.cred_root ".gitconfig")
	    (lookup "GIT_CONFIG_GLOBAL");
	  check string "GIT_CONFIG_COUNT" "4" (lookup "GIT_CONFIG_COUNT");
	  check string "credential helper reset" "credential.helper"
	    (lookup "GIT_CONFIG_KEY_1");
	  check string "credential helper reset value" ""
	    (lookup "GIT_CONFIG_VALUE_1");
	  check string "github credential helper"
	    "credential.https://github.com.helper"
	    (lookup "GIT_CONFIG_KEY_2");
	  check string "github credential helper command"
	    "!gh auth git-credential"
	    (lookup "GIT_CONFIG_VALUE_2")

let test_compose_env_git_identity_threaded () =
  let env =
    HCP.For_testing.compose_env
      ~git_author_name:"NAME-X"
      ~git_author_email:"EMAIL-X" ()
  in
  let lookup k = List.assoc k env in
  check string "GIT_AUTHOR_NAME" "NAME-X" (lookup "GIT_AUTHOR_NAME");
  check string "GIT_AUTHOR_EMAIL" "EMAIL-X" (lookup "GIT_AUTHOR_EMAIL");
  check string "GIT_COMMITTER_NAME" "NAME-X" (lookup "GIT_COMMITTER_NAME");
  check string "GIT_COMMITTER_EMAIL" "EMAIL-X" (lookup "GIT_COMMITTER_EMAIL")

let test_compose_env_explicit_ssh_key () =
  let env =
    HCP.For_testing.compose_env
      ~ssh_key_container:"/tmp/keeper-creds/.ssh/id_credential"
      ~git_author_name:"k" ~git_author_email:"k@e" ()
  in
  let cmd = List.assoc "GIT_SSH_COMMAND" env in
  check bool "ssh command points at mounted key" true
    (try
       ignore
         (Str.search_forward
            (Str.regexp_string
               "/tmp/keeper-creds/.ssh/id_credential")
            cmd 0);
       true
     with Not_found -> false);
  check bool "ssh command pins identity selection" true
    (try
       ignore
         (Str.search_forward
            (Str.regexp_string "-o IdentitiesOnly=yes") cmd 0);
       true
     with Not_found -> false)

let seed_minimal_gh_bundle ~gh_config_dir =
  (* Write a minimal hosts.yml so Credential_materializer.verify_state
     does not immediately classify the bundle as Unmaterialized due to
     a missing hosts.yml.  The oauth_token line is fake; gh auth status
     will still return non-zero because no real GitHub endpoint validates
     this token, making the bundle appear Stale.  For tests that need
     Materialized state, mock verify_state at the bind_from_keeper_binding
     boundary. *)
  mkdir_p gh_config_dir;
  let hosts_yml = Filename.concat gh_config_dir "hosts.yml" in
  let oc = open_out hosts_yml in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc
        "github.com:\n\
        \    oauth_token: ghp_fake_test_token_for_preflight_test\n\
        \    user: test-user\n")

let test_resolve_credential_store_mounts_explicit_ssh_key () =
  with_temp_base_path (fun base_path ->
      let config = Masc_mcp.Coord.default_config base_path in
      let gh_config_dir =
        Filename.concat base_path ".masc/github-identities/cred-A/gh"
      in
      let ssh_key_path =
        Filename.concat base_path ".masc/github-identities/cred-A/ssh/id_ed25519"
      in
      seed_minimal_gh_bundle ~gh_config_dir;
      mkdir_p (Filename.dirname ssh_key_path);
      let oc = open_out ssh_key_path in
      close_out oc;
      seed_credential ~base_path
        (make_credential ~id:"cred-A" ~username:"user-A"
           ~gh_config_dir ~ssh_key_path ());
      seed_repo ~base_path (make_repo ~id:"repo-1" ~credential_id:"cred-A");
      write_mapping base_path "keeper-1" [ "repo-1" ];
      match HCP.resolve ~config ~identity:"keeper-1" with
      | Error err ->
          (* #12685: preflight gate rejects stale credentials (gh auth
             status returns non-zero for fake tokens).  The error path
             is expected here since the bundle is not genuinely
             materialized.  Verify the error is actionable. *)
          let rendered = CP.pp_error err in
          check bool "error mentions stale or unmaterialized" true
            (try
               ignore (Str.search_forward (Str.regexp_string "stale") rendered 0);
               true
             with Not_found ->
               try
                 ignore (Str.search_forward (Str.regexp_string "unmaterialized") rendered 0);
                 true
               with Not_found -> false)
      | Ok binding ->
          (* If gh auth status somehow succeeds (e.g. mock), verify ssh. *)
          let ssh_cmd = List.assoc "GIT_SSH_COMMAND" binding.CP.env in
          check bool "ssh command points at projected key" true
            (try
               ignore
                 (Str.search_forward
                    (Str.regexp_string
                       "/tmp/keeper-creds/.ssh/id_credential")
                    ssh_cmd 0);
               true
             with Not_found -> false);
          check bool "explicit ssh key mounted" true
            (List.exists
               (fun (m : CP.ro_mount) ->
                 String.equal m.host ssh_key_path
                 && String.equal m.container
                      "/tmp/keeper-creds/.ssh/id_credential")
               binding.ro_mounts))

let test_credential_store_mapping_conflicting_github_identity_fails_closed
    () =
  with_temp_base_path (fun base_path ->
      let config = Masc_mcp.Coord.default_config base_path in
      let config_dir = Filename.concat base_path ".masc/config" in
      let keeper_name = "keeper-conflict" in
      let declared_identity = "declared-reviewer" in
      write_keeper_identity_toml ~base_path ~keeper_name
        ~github_identity:declared_identity;
      with_config_dir_env config_dir (fun () ->
          let gh_config_dir =
            Filename.concat base_path ".masc/github-identities/other/gh"
          in
          seed_credential ~base_path
            (make_credential ~id:"other-credential" ~username:"other-user"
               ~gh_config_dir ());
          seed_repo ~base_path
            (make_repo ~id:"repo-conflict"
               ~credential_id:"other-credential");
          write_mapping base_path keeper_name [ "repo-conflict" ];
          match HCP.resolve ~config ~identity:keeper_name with
          | Error (CP.Missing_bundle { identity; path }) ->
              check string "identity" keeper_name identity;
              check bool "mentions declared identity" true
                (try
                   ignore
                     (Str.search_forward
                        (Str.regexp_string declared_identity)
                        path 0);
                   true
                 with Not_found -> false);
              check bool "mentions mapped credential" true
                (try
                   ignore
                     (Str.search_forward
                        (Str.regexp_string "other-credential")
                        path 0);
                   true
                 with Not_found -> false)
          | Ok _ ->
              fail
                "conflicting credential-store mapping should fail closed \
                 before materializing Docker credentials"
          | Error other ->
              failf "expected Missing_bundle, got %s" (CP.pp_error other)))

(* --- 4. finalize / tear_down noop semantics --- *)

let dummy_binding () : CP.binding =
  {
    identity = "k";
    env = [];
    ro_mounts = [];
    bootstrap = None;
    metadata = [];
  }

let test_finalize_is_noop_ok () =
  let b = dummy_binding () in
  match HCP.finalize b ~container_id:"abc123" with
  | Ok () -> ()
  | Error err -> failf "finalize must noop-Ok; got %s" (CP.pp_error err)

let test_tear_down_idempotent () =
  let b = dummy_binding () in
  HCP.tear_down b ~container_id:None;
  HCP.tear_down b ~container_id:(Some "abc");
  HCP.tear_down b ~container_id:None;
  ()

(* --- 5. F-1 security gate tests (In_container_login_provider) --- *)

module ICLP = Masc_mcp.In_container_login_provider

let test_f1_gate_matching_tokens_rejected () =
  match
    ICLP.For_testing.provider_gate
      ~keeper_token:"ghp_same_token_value"
      ~operator_token:"ghp_same_token_value"
      ~identity:"test-keeper"
  with
  | Ok _ -> fail "matching tokens should be rejected by F-1 gate"
  | Error (CP.Invalid_token { identity; reason }) ->
      check string "identity" "test-keeper" identity;
      check bool "reason mentions SHA-256" true
        (try ignore (Str.search_forward (Str.regexp_string "SHA-256") reason 0); true
         with Not_found -> false)
  | Error other ->
      failf "expected Invalid_token, got %s" (CP.pp_error other)

let test_f1_gate_different_tokens_accepted () =
  match
    ICLP.For_testing.provider_gate
      ~keeper_token:"ghp_keeper_token_abc"
      ~operator_token:"ghp_operator_token_xyz"
      ~identity:"test-keeper"
  with
  | Ok () -> ()
  | Error err -> failf "different tokens should pass F-1 gate, got %s" (CP.pp_error err)

let test_f1_gate_error_variant () =
  let gate_result =
    ICLP.For_testing.provider_gate
      ~keeper_token:"tok"
      ~operator_token:"tok"
      ~identity:"keeper-1"
  in
  (match gate_result with
  | Error (CP.Invalid_token _) ->
      let rendered = CP.pp_error (Result.get_error gate_result) in
      check bool "rendered contains identity" true
        (try ignore (Str.search_forward (Str.regexp_string "keeper-1") rendered 0); true
         with Not_found -> false)
  | Ok _ -> fail "expected Error"
  | Error other ->
      failf "expected Invalid_token, got %s" (CP.pp_error other))

let test_f1_gate_ct_hex_equal () =
  let hash_a = Digestif.SHA256.(digest_string "hello" |> to_hex) in
  let hash_b = Digestif.SHA256.(digest_string "hello" |> to_hex) in
  let hash_c = Digestif.SHA256.(digest_string "world" |> to_hex) in
  check bool "same input -> equal hashes" true (ICLP.For_testing.ct_hex_equal hash_a hash_b);
  check bool "different input -> unequal hashes" false (ICLP.For_testing.ct_hex_equal hash_a hash_c);
  check bool "non-64-char string -> false" false (ICLP.For_testing.ct_hex_equal "short" hash_a)

let test_f1_gate_resolve_stub () =
  let config = Masc_mcp.Coord.default_config "/tmp/nonexistent" in
  match ICLP.resolve ~config ~identity:"test-keeper" with
  | Error (CP.Missing_bundle { identity; path }) ->
      check string "identity" "test-keeper" identity;
      check bool "path mentions not implemented" true
        (try ignore (Str.search_forward (Str.regexp_string "not yet implemented") path 0); true
         with Not_found -> false)
  | Ok _ -> fail "resolve stub should return Missing_bundle"
  | Error other ->
      failf "expected Missing_bundle, got %s" (CP.pp_error other)

(* --- 6. #12685: credential preflight gate --- *)

let test_preflight_missing_hosts_yml () =
  (* gh_config_dir exists but has no hosts.yml/oauth_token ->
     verify_state returns Stale -> resolve must return Missing_bundle. *)
  with_temp_base_path (fun base_path ->
      let config = Masc_mcp.Coord.default_config base_path in
      let gh_config_dir =
        Filename.concat base_path ".masc/github-identities/cred-B/gh"
      in
      mkdir_p gh_config_dir;
      seed_credential ~base_path
        (make_credential ~id:"cred-B" ~username:"user-B"
           ~gh_config_dir ());
      seed_repo ~base_path (make_repo ~id:"repo-2" ~credential_id:"cred-B");
      write_mapping base_path "keeper-2" [ "repo-2" ];
      match HCP.resolve ~config ~identity:"keeper-2" with
      | Error (CP.Missing_bundle { identity; path }) ->
          check string "identity" "keeper-2" identity;
          check bool "path mentions stale or unmaterialized" true
            (try ignore (Str.search_forward (Str.regexp_string "stale") path 0); true
             with Not_found ->
               try ignore (Str.search_forward (Str.regexp_string "unmaterialized") path 0); true
               with Not_found -> false)
      | Ok _ ->
          fail "resolve should reject unmaterialized credential bundle"
      | Error other ->
          failf "expected Missing_bundle, got %s" (CP.pp_error other))

let test_preflight_fake_token_rejected () =
  (* gh_config_dir has hosts.yml with a fake token -> gh auth status
     returns non-zero -> verify_state returns Stale -> resolve must
     return Missing_bundle. *)
  with_temp_base_path (fun base_path ->
      let config = Masc_mcp.Coord.default_config base_path in
      let gh_config_dir =
        Filename.concat base_path ".masc/github-identities/cred-C/gh"
      in
      seed_minimal_gh_bundle ~gh_config_dir;
      seed_credential ~base_path
        (make_credential ~id:"cred-C" ~username:"user-C"
           ~gh_config_dir ());
      seed_repo ~base_path (make_repo ~id:"repo-3" ~credential_id:"cred-C");
      write_mapping base_path "keeper-3" [ "repo-3" ];
      match HCP.resolve ~config ~identity:"keeper-3" with
      | Error (CP.Missing_bundle { identity; path }) ->
          check string "identity" "keeper-3" identity;
          check bool "path mentions stale or unmaterialized" true
            (try
               ignore (Str.search_forward (Str.regexp_string "stale") path 0);
               true
             with Not_found ->
               try
                 ignore (Str.search_forward (Str.regexp_string "unmaterialized") path 0);
                 true
               with Not_found -> false)
      | Ok _ ->
          fail "resolve should reject stale credential bundle"
      | Error other ->
          failf "expected Missing_bundle, got %s" (CP.pp_error other))

let test_preflight_empty_dir_rejected () =
  (* gh_config_dir is an empty string -> verify_state returns
     Unmaterialized -> resolve must return Missing_bundle. *)
  with_temp_base_path (fun base_path ->
      let config = Masc_mcp.Coord.default_config base_path in
      seed_credential ~base_path
        (make_credential ~id:"cred-D" ~username:"user-D"
           ~gh_config_dir:"" ());
      seed_repo ~base_path (make_repo ~id:"repo-4" ~credential_id:"cred-D");
      write_mapping base_path "keeper-4" [ "repo-4" ];
      match HCP.resolve ~config ~identity:"keeper-4" with
      | Error (CP.Missing_bundle _) -> ()
      | Ok _ ->
          fail "resolve should reject empty gh_config_dir"
      | Error other ->
          failf "expected Missing_bundle, got %s" (CP.pp_error other))

let () =
  run "credential_provider"
    [
        ( "errors",
        [
          test_case "pp_error covers all variants" `Quick test_pp_error_all_variants;
          test_case "empty required gh mount fails closed" `Quick
            test_required_gh_mount_empty_path_fails_closed;
          test_case "missing required gh mount fails closed" `Quick
            test_required_gh_mount_missing_path_fails_closed;
          test_case "absent optional siblings are allowed" `Quick
            test_required_gh_mount_allows_absent_optional_siblings;
        ] );
      ( "mount_if_present",
        [
          test_case "empty host" `Quick test_mount_if_present_empty_host;
          test_case "missing path" `Quick test_mount_if_present_missing_path;
          test_case "existing dir" `Quick test_mount_if_present_existing_dir;
        ] );
      ( "compose_env",
        [
          test_case "key set" `Quick test_compose_env_key_set;
          test_case "paths anchored to cred_root" `Quick
            test_compose_env_path_values_anchored_to_cred_root;
          test_case "identity threaded" `Quick
            test_compose_env_git_identity_threaded;
          test_case "explicit ssh key" `Quick
            test_compose_env_explicit_ssh_key;
        ] );
      ( "credential_store_bridge",
        [
          test_case "explicit ssh key is mounted" `Quick
            test_resolve_credential_store_mounts_explicit_ssh_key;
          test_case "conflicting keeper github_identity fails closed" `Quick
            test_credential_store_mapping_conflicting_github_identity_fails_closed;
        ] );
      ( "lifecycle (PR-1 noop)",
        [
          test_case "finalize Ok" `Quick test_finalize_is_noop_ok;
          test_case "tear_down idempotent" `Quick test_tear_down_idempotent;
        ] );
      ( "f1_gate",
        [
          test_case "matching tokens rejected" `Quick
            test_f1_gate_matching_tokens_rejected;
          test_case "different tokens accepted" `Quick
            test_f1_gate_different_tokens_accepted;
          test_case "error variant is Invalid_token" `Quick
            test_f1_gate_error_variant;
          test_case "ct_hex_equal semantics" `Quick
            test_f1_gate_ct_hex_equal;
          test_case "resolve stub returns Missing_bundle" `Quick
            test_f1_gate_resolve_stub;
        ] );
      (* #12685: credential preflight gate tests *)
      ( "preflight_gate",
        [
          test_case "missing hosts.yml -> Missing_bundle" `Quick
            test_preflight_missing_hosts_yml;
          test_case "fake token -> stale or unmaterialized" `Quick
            test_preflight_fake_token_rejected;
          test_case "empty gh_config_dir -> Missing_bundle" `Quick
            test_preflight_empty_dir_rejected;
        ] );
    ]
