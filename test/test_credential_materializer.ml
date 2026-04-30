(** RFC-0019 PR-B Slice 1 — coverage for the deterministic branches of
    {!Credential_materializer.verify_state} and {!ensure}.

    The [Materialized] outcome requires a real [gh] subprocess + a
    populated bundle and is exercised by the end-to-end test added in
    PR-B Slice 3.  Here we pin the three branches that do not depend on
    [gh] being installed:

    1. [None] / empty / missing [gh_config_dir] -> [Unmaterialized].
    2. Path exists but is a file rather than a directory -> [Stale].
    3. [ensure] mutates only the [state] field; every other field on the
       input record is preserved verbatim. *)

open Repo_manager_types

let with_temp_base_path f =
  let dir = Filename.temp_file "rfc0019_materializer" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let masc_dir = Filename.concat dir ".masc" in
  Unix.mkdir masc_dir 0o755;
  Unix.mkdir (Filename.concat masc_dir "config") 0o755;
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

let make_credential ?gh_config_dir id =
  {
    id;
    cred_type = Github;
    username = "user-" ^ id;
    gh_config_dir;
    ssh_key_path = None;
    gpg_key_id = None;
    state = Materialized { last_verified_at = 999L };
    token_sha256_prefix = Some "stale-prefix";
  }

(* --- 1. Unmaterialised branches --- *)

let test_empty_string_is_unmaterialized () =
  match Credential_materializer.verify_state ~gh_config_dir:"" with
  | Unmaterialized -> ()
  | other ->
      Alcotest.failf "expected Unmaterialized for empty path, got %s"
        (show_credential_state other)

let test_missing_path_is_unmaterialized () =
  match
    Credential_materializer.verify_state
      ~gh_config_dir:"/nonexistent/rfc0019/path"
  with
  | Unmaterialized -> ()
  | other ->
      Alcotest.failf "expected Unmaterialized for missing path, got %s"
        (show_credential_state other)

(* --- 2. Stale branch (path is a file, not a dir) --- *)

let test_path_is_file_is_stale () =
  with_temp_base_path (fun base ->
      let file_path = Filename.concat base "not_a_dir" in
      let oc = open_out file_path in
      output_string oc "regular file";
      close_out oc;
      match
        Credential_materializer.verify_state ~gh_config_dir:file_path
      with
      | Stale { reason } ->
          Alcotest.(check bool) "reason mentions directory"
            true
            (try
               ignore
                 (Str.search_forward (Str.regexp "directory") reason 0);
               true
             with Not_found -> false)
      | other ->
          Alcotest.failf "expected Stale, got %s"
            (show_credential_state other))

(* --- 3. ensure mutates only state, preserves other fields --- *)

let test_ensure_preserves_other_fields_and_resets_state_to_unmaterialized () =
  let cred = make_credential "preserved" in
  let updated = Credential_materializer.ensure cred in
  (* gh_config_dir = None -> Unmaterialized *)
  (match updated.state with
   | Unmaterialized -> ()
   | other ->
       Alcotest.failf
         "expected Unmaterialized when gh_config_dir is None, got %s"
         (show_credential_state other));
  Alcotest.(check string) "id preserved" cred.id updated.id;
  Alcotest.(check string) "username preserved" cred.username updated.username;
  Alcotest.(check (option string))
    "gh_config_dir preserved" cred.gh_config_dir updated.gh_config_dir;
  Alcotest.(check (option string))
    "token_sha256_prefix preserved"
    cred.token_sha256_prefix updated.token_sha256_prefix;
  Alcotest.(check bool)
    "ssh_key_path preserved" true
    (cred.ssh_key_path = updated.ssh_key_path);
  Alcotest.(check bool)
    "gpg_key_id preserved" true
    (cred.gpg_key_id = updated.gpg_key_id)

let test_ensure_with_missing_path_yields_unmaterialized () =
  let cred =
    make_credential ~gh_config_dir:"/nonexistent/rfc0019/path" "missing"
  in
  let updated = Credential_materializer.ensure cred in
  match updated.state with
  | Unmaterialized -> ()
  | other ->
      Alcotest.failf "expected Unmaterialized, got %s"
        (show_credential_state other)

(* --- 4. Credential_store.add stamps the state field automatically --- *)

let test_credential_store_add_invokes_ensure () =
  with_temp_base_path (fun base_path ->
      let cred =
        make_credential ~gh_config_dir:"/nonexistent/rfc0019/store-add" "via-store"
      in
      match Credential_store.add ~base_path cred with
      | Error e -> Alcotest.failf "add failed: %s" e
      | Ok stored ->
          (* The materializer should have overwritten the input's stale
             [Materialized {...}] state with [Unmaterialized] because the
             gh_config_dir does not exist. *)
          (match stored.state with
           | Unmaterialized -> ()
           | other ->
               Alcotest.failf
                 "expected Unmaterialized after add (gh_config_dir \
                  missing), got %s"
                 (show_credential_state other));
          (* The stored record should also persist back through load_all. *)
          (match Credential_store.find ~base_path "via-store" with
           | Error e -> Alcotest.failf "round-trip find failed: %s" e
           | Ok loaded ->
               (match loaded.state with
                | Unmaterialized -> ()
                | other ->
                    Alcotest.failf
                      "expected Unmaterialized after roundtrip, got %s"
                      (show_credential_state other))))

(* --- 5. Provisioner: path_safe + invariants --- *)

let test_path_safe_rejects_dot_dot () =
  match Credential_materializer.path_safe "/foo/../bar" with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "expected Error for path with .. segment"

let test_path_safe_accepts_ordinary_paths () =
  match Credential_materializer.path_safe "/tmp/keeper-creds/.config/gh" with
  | Ok () -> ()
  | Error msg -> Alcotest.failf "unexpected Error: %s" msg

(* The provisioner spawns a real `gh` subprocess; this test is best-effort.
   We only assert the *security invariants* that we can verify without
   gh being installed:
     - Empty token is rejected with a clear, token-free message.
     - Path-traversal in gh_config_dir is rejected before any subprocess.
     - The error message never contains the supplied token. *)

let canary_token =
  "canary_token_RFC0019_PRB_a1b2c3d4e5f6_should_NEVER_appear_in_logs"

let test_provision_rejects_empty_token () =
  match
    Credential_materializer.provision_via_with_token
      ~gh_config_dir:"/tmp/keeper-creds-canary" ~token:""
  with
  | Error msg ->
      Alcotest.(check bool) "error mentions non-empty requirement"
        true
        (try
           ignore (Str.search_forward (Str.regexp "non-empty") msg 0);
           true
         with Not_found -> false)
  | Ok _ -> Alcotest.fail "expected Error for empty token"

let test_provision_rejects_path_traversal () =
  match
    Credential_materializer.provision_via_with_token
      ~gh_config_dir:"/tmp/../etc/gh" ~token:canary_token
  with
  | Error msg ->
      Alcotest.(check bool) "error mentions forbidden segment" true
        (try
           ignore (Str.search_forward (Str.regexp "forbidden") msg 0);
           true
         with Not_found -> false);
      (* RFC-0019 §8 R2: token must never appear in the error message. *)
      Alcotest.(check bool)
        "error must not echo token" false
        (try
           ignore (Str.search_forward (Str.regexp_string canary_token) msg 0);
           true
         with Not_found -> false)
  | Ok _ -> Alcotest.fail "expected Error for path with .. segment"

let () =
  Alcotest.run "credential_materializer"
    [
      ( "verify_state",
        [
          Alcotest.test_case "empty path is Unmaterialized" `Quick
            test_empty_string_is_unmaterialized;
          Alcotest.test_case "missing path is Unmaterialized" `Quick
            test_missing_path_is_unmaterialized;
          Alcotest.test_case "file (not dir) is Stale" `Quick
            test_path_is_file_is_stale;
        ] );
      ( "ensure",
        [
          Alcotest.test_case "preserves other fields, resets state" `Quick
            test_ensure_preserves_other_fields_and_resets_state_to_unmaterialized;
          Alcotest.test_case "missing gh_config_dir yields Unmaterialized"
            `Quick
            test_ensure_with_missing_path_yields_unmaterialized;
        ] );
      ( "Credential_store.add wiring",
        [
          Alcotest.test_case "add invokes ensure and roundtrips" `Quick
            test_credential_store_add_invokes_ensure;
        ] );
      ( "provisioner",
        [
          Alcotest.test_case "path_safe rejects .. segments" `Quick
            test_path_safe_rejects_dot_dot;
          Alcotest.test_case "path_safe accepts ordinary paths" `Quick
            test_path_safe_accepts_ordinary_paths;
          Alcotest.test_case "provision rejects empty token" `Quick
            test_provision_rejects_empty_token;
          Alcotest.test_case
            "provision rejects path traversal without echoing token"
            `Quick test_provision_rejects_path_traversal;
        ] );
    ]
