(** RFC-0019 PR-A — bridge resolver coverage for
    {!Keeper_repo_mapping.credentials_for_keeper}.

    This is the load-bearing helper consumed by
    {!Host_config_provider.resolve} when deciding whether to route a
    keeper through the new {!Credential_store} or the legacy
    {!Keeper_gh_env.keeper_binding} path.

    Pinned scenarios:

    1. No mapping for the keeper → [Ok []] (the bridge interprets this
       as "use the legacy resolver"; an [Error] would falsely block
       legacy keepers).
    2. Mapping with exactly one repo → [Ok [credential]].
    3. Mapping with several repos that share one credential → [Ok
       [credential]] (deduplicated; the bridge expects a single
       single-element list to dispatch deterministically).
    4. Mapping with several repos with distinct credentials →
       [Ok [c1; c2]] in mapping order (the bridge surfaces ambiguity
       to the caller as a [Missing_bundle] with an actionable message;
       the helper itself stays total).
    5. Mapping references a non-existent credential → [Error _].
       Infrastructure failure, not absence; bridge should surface
       this rather than silently fall back.
    6. Wildcard ["*"] mapping → returns credentials for every
       registered repository (deduplicated by credential id).

    Integration of [Host_config_provider.resolve] itself with
    [Coord.config] + filesystem bundles is exercised by
    [test_keeper_shell_docker_route]; this file stays pure to avoid
    re-staging that fixture. *)

open Repo_manager_types

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

let with_temp_base_path f =
  let dir = Filename.temp_file "rfc0019_bridge" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let masc_dir = Filename.concat dir ".masc" in
  Unix.mkdir masc_dir 0o755;
  let cfg_dir = Filename.concat masc_dir "config" in
  Unix.mkdir cfg_dir 0o755;
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

let make_credential ~id ~username ~gh_config_dir : credential =
  {
    id;
    cred_type = Github;
    username;
    gh_config_dir = Some gh_config_dir;
    ssh_key_path = None;
    gpg_key_id = None;
    state = Unmaterialized;
    token_sha256_prefix = None;
  }

let make_repo ~id ~credential_id : repository =
  {
    id;
    name = "repo-" ^ id;
    url = "https://github.com/test/" ^ id;
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

let seed_credential ~base_path cred =
  match Credential_store.add ~base_path cred with
  | Ok _ -> ()
  | Error msg ->
      Alcotest.failf "seed credential %s: %s" cred.id msg

let seed_repo ~base_path repo =
  match Repo_store.add ~base_path repo with
  | Ok _ -> ()
  | Error msg ->
      Alcotest.failf "seed repo %s: %s" repo.id msg

(* --- 1. No mapping → Ok [] --- *)

let test_no_mapping_yields_empty_list () =
  with_temp_base_path (fun base_path ->
      match
        Keeper_repo_mapping.credentials_for_keeper
          ~base_path ~keeper_id:"unmapped-keeper"
      with
      | Ok creds ->
          Alcotest.(check int)
            "absence-of-mapping is empty list, not error"
            0 (List.length creds)
      | Error msg ->
          Alcotest.failf
            "absence of mapping must surface as Ok []; got Error %S"
            msg)

(* --- 2. Single repo, single credential --- *)

let test_single_repo_single_credential () =
  with_temp_base_path (fun base_path ->
      seed_credential ~base_path
        (make_credential ~id:"cred-A" ~username:"user-A"
           ~gh_config_dir:"/tmp/cred-A/gh");
      seed_repo ~base_path (make_repo ~id:"repo-1" ~credential_id:"cred-A");
      write_mapping base_path "keeper-1" [ "repo-1" ];
      match
        Keeper_repo_mapping.credentials_for_keeper
          ~base_path ~keeper_id:"keeper-1"
      with
      | Ok [ c ] ->
          Alcotest.(check string) "credential id" "cred-A" c.id;
          Alcotest.(check string) "credential username" "user-A" c.username
      | Ok creds ->
          Alcotest.failf "expected exactly one credential, got %d"
            (List.length creds)
      | Error msg -> Alcotest.failf "unexpected error: %s" msg)

(* --- 3. Multiple repos sharing one credential → deduplicated --- *)

let test_two_repos_same_credential_deduped () =
  with_temp_base_path (fun base_path ->
      seed_credential ~base_path
        (make_credential ~id:"cred-A" ~username:"user-A"
           ~gh_config_dir:"/tmp/cred-A/gh");
      seed_repo ~base_path (make_repo ~id:"repo-1" ~credential_id:"cred-A");
      seed_repo ~base_path (make_repo ~id:"repo-2" ~credential_id:"cred-A");
      write_mapping base_path "keeper-1" [ "repo-1"; "repo-2" ];
      match
        Keeper_repo_mapping.credentials_for_keeper
          ~base_path ~keeper_id:"keeper-1"
      with
      | Ok [ c ] -> Alcotest.(check string) "single deduped credential" "cred-A" c.id
      | Ok creds ->
          Alcotest.failf
            "expected dedupe to a single credential, got %d (%s)"
            (List.length creds)
            (String.concat ", "
               (List.map (fun (c : credential) -> c.id) creds))
      | Error msg -> Alcotest.failf "unexpected error: %s" msg)

(* --- 4. Distinct credentials surfaced in mapping order --- *)

let test_distinct_credentials_surfaced () =
  with_temp_base_path (fun base_path ->
      seed_credential ~base_path
        (make_credential ~id:"cred-A" ~username:"user-A"
           ~gh_config_dir:"/tmp/cred-A/gh");
      seed_credential ~base_path
        (make_credential ~id:"cred-B" ~username:"user-B"
           ~gh_config_dir:"/tmp/cred-B/gh");
      seed_repo ~base_path (make_repo ~id:"repo-1" ~credential_id:"cred-A");
      seed_repo ~base_path (make_repo ~id:"repo-2" ~credential_id:"cred-B");
      write_mapping base_path "keeper-1" [ "repo-1"; "repo-2" ];
      match
        Keeper_repo_mapping.credentials_for_keeper
          ~base_path ~keeper_id:"keeper-1"
      with
      | Ok creds ->
          Alcotest.(check int) "two credentials" 2 (List.length creds);
          let ids = List.map (fun (c : credential) -> c.id) creds in
          Alcotest.(check bool) "has cred-A" true (List.mem "cred-A" ids);
          Alcotest.(check bool) "has cred-B" true (List.mem "cred-B" ids)
      | Error msg -> Alcotest.failf "unexpected error: %s" msg)

(* --- 5. Mapping references missing credential --- *)

let test_missing_credential_yields_error () =
  with_temp_base_path (fun base_path ->
      seed_repo ~base_path
        (make_repo ~id:"repo-1" ~credential_id:"cred-MISSING");
      write_mapping base_path "keeper-1" [ "repo-1" ];
      match
        Keeper_repo_mapping.credentials_for_keeper
          ~base_path ~keeper_id:"keeper-1"
      with
      | Ok creds ->
          Alcotest.failf
            "expected Error for missing credential, got Ok with %d \
             credentials"
            (List.length creds)
      | Error msg ->
          Alcotest.(check bool)
            "error mentions credential id"
            true (contains_substring msg "cred-MISSING");
          Alcotest.(check bool)
            "error mentions keeper id"
            true (contains_substring msg "keeper-1"))

(* --- 6. Wildcard mapping resolves every registered repo --- *)

let test_wildcard_mapping_returns_all_credentials () =
  with_temp_base_path (fun base_path ->
      seed_credential ~base_path
        (make_credential ~id:"cred-A" ~username:"user-A"
           ~gh_config_dir:"/tmp/cred-A/gh");
      seed_credential ~base_path
        (make_credential ~id:"cred-B" ~username:"user-B"
           ~gh_config_dir:"/tmp/cred-B/gh");
      seed_repo ~base_path (make_repo ~id:"repo-1" ~credential_id:"cred-A");
      seed_repo ~base_path (make_repo ~id:"repo-2" ~credential_id:"cred-B");
      seed_repo ~base_path (make_repo ~id:"repo-3" ~credential_id:"cred-A");
      write_mapping base_path "keeper-wild" [ "*" ];
      match
        Keeper_repo_mapping.credentials_for_keeper
          ~base_path ~keeper_id:"keeper-wild"
      with
      | Ok creds ->
          Alcotest.(check int)
            "wildcard dedupes to two distinct credentials"
            2 (List.length creds);
          let ids = List.map (fun (c : credential) -> c.id) creds in
          Alcotest.(check bool) "has cred-A" true (List.mem "cred-A" ids);
          Alcotest.(check bool) "has cred-B" true (List.mem "cred-B" ids)
      | Error msg -> Alcotest.failf "unexpected error: %s" msg)

let () =
  Alcotest.run "credential_provider_bridge"
    [
      ( "credentials_for_keeper",
        [
          Alcotest.test_case "no mapping is Ok []" `Quick
            test_no_mapping_yields_empty_list;
          Alcotest.test_case "single repo, single credential" `Quick
            test_single_repo_single_credential;
          Alcotest.test_case "two repos, one credential, deduped" `Quick
            test_two_repos_same_credential_deduped;
          Alcotest.test_case "two repos, distinct credentials" `Quick
            test_distinct_credentials_surfaced;
          Alcotest.test_case "missing credential surfaces Error" `Quick
            test_missing_credential_yields_error;
          Alcotest.test_case "wildcard mapping resolves all" `Quick
            test_wildcard_mapping_returns_all_credentials;
        ] );
    ]
