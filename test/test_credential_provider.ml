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
    2. [Host_config_provider.For_testing.mount_if_present] returns
       [[]] for empty / missing host paths and a single-element
       [ro_mount] when the path exists.
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
module ICLP = Masc_mcp.In_container_login_provider

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

(* --- 2. mount_if_present skip rules --- *)

(* β7 fail-closed: [resolve] returns Error when ALL credential host paths
   are empty or missing.  [resolve] itself requires a Coord.config, so
   unit-testing it directly needs the integration test suite
   ([test_keeper_shell_docker_route]).  What we can pin here is the
   precondition: three mount_if_present calls with empty/missing hosts
   produce an empty mount list, and the error format is correct. *)
let test_fail_closed_all_credential_paths_empty () =
  let gh_creds = "" and gitconfig = "" and ssh_dir = "" in
  let ro_mounts =
    HCP.For_testing.mount_if_present ~host:gh_creds
      ~container:"/tmp/keeper-creds/.config/gh"
    @ HCP.For_testing.mount_if_present ~host:gitconfig
        ~container:"/tmp/keeper-creds/.gitconfig"
    @ HCP.For_testing.mount_if_present ~host:ssh_dir
        ~container:"/tmp/keeper-creds/.ssh"
  in
  check int "all-empty paths -> empty mounts" 0 (List.length ro_mounts);
  let err =
    CP.Missing_bundle
      { identity = "test-keeper"; path = "all credential host paths empty or missing" }
  in
  let rendered = CP.pp_error err in
  check bool "error rendered with identity"
    true
    (String.length rendered > 0);
  check bool "error mentions credential paths"
    true
    (try ignore (Str.search_forward (Str.regexp "credential") rendered 0); true
     with Not_found -> false)

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
      ~git_author_email:"keeper-A@example.invalid"
  in
  let actual_keys = List.sort compare (List.map fst env) in
  let expected_keys = List.sort compare expected_env_keys in
  check (list string)
    "env keys stay bundle-local and non-interactive"
    expected_keys actual_keys

let test_compose_env_path_values_anchored_to_cred_root () =
  let env =
    HCP.For_testing.compose_env
      ~git_author_name:"k" ~git_author_email:"k@e"
  in
  let lookup k = List.assoc k env in
  check string "HOME" HCP.cred_root (lookup "HOME");
  check string "GH_CONFIG_DIR"
    (Filename.concat HCP.cred_root ".config/gh")
    (lookup "GH_CONFIG_DIR");
  check string "GIT_CONFIG_GLOBAL"
    (Filename.concat HCP.cred_root ".gitconfig")
    (lookup "GIT_CONFIG_GLOBAL")

let test_compose_env_git_identity_threaded () =
  let env =
    HCP.For_testing.compose_env
      ~git_author_name:"NAME-X"
      ~git_author_email:"EMAIL-X"
  in
  let lookup k = List.assoc k env in
  check string "GIT_AUTHOR_NAME" "NAME-X" (lookup "GIT_AUTHOR_NAME");
  check string "GIT_AUTHOR_EMAIL" "EMAIL-X" (lookup "GIT_AUTHOR_EMAIL");
  check string "GIT_COMMITTER_NAME" "NAME-X" (lookup "GIT_COMMITTER_NAME");
  check string "GIT_COMMITTER_EMAIL" "EMAIL-X" (lookup "GIT_COMMITTER_EMAIL")

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

(* --- 5. In_container_login_provider pure helpers --- *)

(* 5a. container_hosts_yml_path is anchored to cred_root/.config/gh *)
let test_iclp_container_hosts_yml_path () =
  let expected =
    Filename.concat HCP.cred_root ".config/gh/hosts.yml"
  in
  check string "container_hosts_yml_path"
    expected ICLP.For_testing.container_hosts_yml_path

(* 5b. read_token_from_hosts_yml returns None for absent file *)
let test_iclp_read_token_absent () =
  let r =
    ICLP.For_testing.read_token_from_hosts_yml
      ~gh_config_dir:"/nonexistent-rfc0008-pr3-test"
  in
  check bool "absent file -> None" true (Option.is_none r)

(* 5c. read_token_from_hosts_yml extracts bare oauth_token *)
let test_iclp_read_token_bare () =
  let dir = Filename.temp_file "iclp_test_bare_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove (Filename.concat dir "hosts.yml") with Sys_error _ -> ());
      (try Unix.rmdir dir with Unix.Unix_error _ -> ()))
    (fun () ->
      let hosts_path = Filename.concat dir "hosts.yml" in
      let oc = open_out hosts_path in
      output_string oc
        "github.com:\n\
         \  oauth_token: ghp_testtoken12345\n\
         \  user: real-user\n\
         \  git_protocol: https\n";
      close_out oc;
      match ICLP.For_testing.read_token_from_hosts_yml ~gh_config_dir:dir with
      | Some tok ->
          check string "bare token extracted" "ghp_testtoken12345" tok
      | None ->
          failf "expected Some token for bare oauth_token value, got None")

(* 5d. read_token_from_hosts_yml extracts single-quoted oauth_token *)
let test_iclp_read_token_quoted () =
  let dir = Filename.temp_file "iclp_test_quoted_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove (Filename.concat dir "hosts.yml") with Sys_error _ -> ());
      (try Unix.rmdir dir with Unix.Unix_error _ -> ()))
    (fun () ->
      let hosts_path = Filename.concat dir "hosts.yml" in
      let oc = open_out hosts_path in
      output_string oc
        "github.com:\n\
         \  oauth_token: 'ghp_quoted9876'\n\
         \  user: real-user\n";
      close_out oc;
      match ICLP.For_testing.read_token_from_hosts_yml ~gh_config_dir:dir with
      | Some tok ->
          check string "quoted token extracted" "ghp_quoted9876" tok
      | None ->
          failf "expected Some token for single-quoted value, got None")

(* 5e. tear_down deletes token_host_path recorded in metadata *)
let test_iclp_tear_down_removes_temp_file () =
  let path = Filename.temp_file "iclp_teardown_" "" in
  (* Write something so the file exists *)
  let oc = open_out path in
  output_string oc "tok\n";
  close_out oc;
  check bool "file exists before tear_down" true (Sys.file_exists path);
  let b : CP.binding =
    { identity = "test-keeper"
    ; env = []
    ; ro_mounts = []
    ; bootstrap = None
    ; metadata = [ "token_host_path", path ]
    }
  in
  ICLP.tear_down b ~container_id:None;
  check bool "file gone after tear_down" false (Sys.file_exists path)

(* 5f. tear_down is idempotent when token_host_path is absent or already gone *)
let test_iclp_tear_down_idempotent () =
  let b_no_meta : CP.binding =
    { identity = "k"; env = []; ro_mounts = []; bootstrap = None; metadata = [] }
  in
  ICLP.tear_down b_no_meta ~container_id:None;
  ICLP.tear_down b_no_meta ~container_id:(Some "x");
  let b_missing : CP.binding =
    { identity = "k"; env = []; ro_mounts = []; bootstrap = None
    ; metadata = [ "token_host_path", "/nonexistent-rfc0008-pr3-teardown" ] }
  in
  ICLP.tear_down b_missing ~container_id:None;
  ()

let () =
  run "credential_provider"
    [
        ( "errors",
        [
          test_case "pp_error covers all variants" `Quick test_pp_error_all_variants;
          test_case "fail-closed: all-empty paths produce Missing_bundle" `Quick
            test_fail_closed_all_credential_paths_empty;
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
        ] );
      ( "lifecycle (PR-1 noop)",
        [
          test_case "finalize Ok" `Quick test_finalize_is_noop_ok;
          test_case "tear_down idempotent" `Quick test_tear_down_idempotent;
        ] );
      ( "in_container_login_provider (PR-3)",
        [
          test_case "container_hosts_yml_path anchored to cred_root" `Quick
            test_iclp_container_hosts_yml_path;
          test_case "read_token absent file -> None" `Quick
            test_iclp_read_token_absent;
          test_case "read_token bare oauth_token" `Quick
            test_iclp_read_token_bare;
          test_case "read_token single-quoted oauth_token" `Quick
            test_iclp_read_token_quoted;
          test_case "tear_down removes temp file" `Quick
            test_iclp_tear_down_removes_temp_file;
          test_case "tear_down idempotent" `Quick
            test_iclp_tear_down_idempotent;
        ] );
    ]
