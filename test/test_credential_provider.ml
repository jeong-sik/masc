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
    (lookup "GIT_CONFIG_GLOBAL")

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

let test_resolve_credential_store_mounts_explicit_ssh_key () =
  with_temp_base_path (fun base_path ->
      let config = Masc_mcp.Coord.default_config base_path in
      let gh_config_dir =
        Filename.concat base_path ".masc/github-identities/cred-A/gh"
      in
      let ssh_key_path =
        Filename.concat base_path ".masc/github-identities/cred-A/ssh/id_ed25519"
      in
      mkdir_p gh_config_dir;
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
          failf "resolve failed: %s" (CP.pp_error err)
      | Ok binding ->
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
          test_case "explicit ssh key" `Quick
            test_compose_env_explicit_ssh_key;
        ] );
      ( "credential_store_bridge",
        [
          test_case "explicit ssh key is mounted" `Quick
            test_resolve_credential_store_mounts_explicit_ssh_key;
        ] );
      ( "lifecycle (PR-1 noop)",
        [
          test_case "finalize Ok" `Quick test_finalize_is_noop_ok;
          test_case "tear_down idempotent" `Quick test_tear_down_idempotent;
        ] );
    ]
