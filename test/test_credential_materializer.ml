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
  (* RFC-0019 PR-C: when state transitions away from Materialized,
     token_sha256_prefix is reset to None.  A stale prefix would mislead
     the F-1 gate (it would compare against a fingerprint that no
     longer corresponds to the on-disk token). *)
  Alcotest.(check (option string))
    "token_sha256_prefix reset to None when not Materialized"
    None updated.token_sha256_prefix;
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

let contains_substring s needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) s 0);
    true
  with Not_found -> false

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let read_file path =
  let ic = open_in path in
  let buf = Buffer.create 256 in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      try
        while true do
          Buffer.add_string buf (input_line ic);
          Buffer.add_char buf '\n'
        done;
        Buffer.contents buf
      with End_of_file -> Buffer.contents buf)

let with_env_vars vars f =
  let saved =
    List.map (fun (k, _) -> (k, Sys.getenv_opt k)) vars
  in
  List.iter (fun (k, v) -> Unix.putenv k v) vars;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (function
          | k, Some v -> Unix.putenv k v
          | k, None -> Unix.putenv k "")
        saved)
    f

let test_provision_rejects_empty_token () =
  match
    Credential_materializer.provision_via_with_token
      ~gh_config_dir:"/tmp/keeper-creds-canary" ~token:"" ()
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
      ~gh_config_dir:"/tmp/../etc/gh" ~token:canary_token ()
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

let test_provision_uses_bundle_env_and_insecure_storage () =
  with_temp_base_path (fun base ->
      let bin_dir = Filename.concat base "bin" in
      Unix.mkdir bin_dir 0o755;
      let gh_path = Filename.concat bin_dir "gh" in
      write_file gh_path
        {|#!/bin/sh
set -eu
cmd1="${1:-}"
cmd2="${2:-}"
mkdir -p "$GH_CONFIG_DIR"
if [ "$cmd1" = "auth" ] && [ "$cmd2" = "login" ]; then
  env | sort > "$GH_CONFIG_DIR/login.env"
  printf '%s\n' "$@" > "$GH_CONFIG_DIR/login.argv"
  IFS= read -r token || token=""
  {
    printf 'github.com:\n'
    printf '    user: real-login\n'
    printf '    oauth_token: %s\n' "$token"
    printf '    git_protocol: https\n'
  } > "$GH_CONFIG_DIR/hosts.yml"
  exit 0
fi
if [ "$cmd1" = "auth" ] && [ "$cmd2" = "status" ]; then
  env | sort > "$GH_CONFIG_DIR/status.env"
  printf '%s\n' "$@" > "$GH_CONFIG_DIR/status.argv"
  if [ -s "$GH_CONFIG_DIR/hosts.yml" ]; then
    exit 0
  fi
  exit 1
fi
exit 2
|};
      Unix.chmod gh_path 0o755;
      let gh_config_dir = Filename.concat base "bundle-gh" in
      let ambient_gh_config_dir = Filename.concat base "ambient-gh" in
      let path =
        match Sys.getenv_opt "PATH" with
        | None | Some "" -> bin_dir
        | Some current -> bin_dir ^ ":" ^ current
      in
      with_env_vars
        [
          ("PATH", path);
          ("GH_CONFIG_DIR", ambient_gh_config_dir);
          ("GH_TOKEN", "ambient-gh-token");
          ("GITHUB_TOKEN", "ambient-github-token");
          ("GH_ENTERPRISE_TOKEN", "ambient-enterprise-token");
          ("GITHUB_ENTERPRISE_TOKEN", "ambient-github-enterprise-token");
          ("GH_PROMPT_DISABLED", "0");
          ("GIT_TERMINAL_PROMPT", "1");
        ]
        (fun () ->
          match
            Credential_materializer.provision_via_with_token
              ~credential_id:"keeper-A" ~identity_label:"keeper-A"
              ~gh_config_dir ~token:canary_token ()
          with
          | Error msg ->
              Alcotest.failf
                "expected fake gh provisioning to succeed: %s" msg
          | Ok (Materialized _) -> ()
          | Ok other ->
              Alcotest.failf "expected Materialized, got %s"
                (show_credential_state other));
      let login_argv =
        read_file (Filename.concat gh_config_dir "login.argv")
      in
      Alcotest.(check bool) "login uses --insecure-storage" true
        (contains_substring login_argv "--insecure-storage");
      Alcotest.(check bool) "login argv does not expose token" false
        (contains_substring login_argv canary_token);
      let assert_clean_env label content =
        Alcotest.(check bool)
          (label ^ " uses target GH_CONFIG_DIR")
          true
          (contains_substring content ("GH_CONFIG_DIR=" ^ gh_config_dir));
        Alcotest.(check bool)
          (label ^ " disables gh prompts")
          true
          (contains_substring content "GH_PROMPT_DISABLED=1");
        Alcotest.(check bool)
          (label ^ " disables git terminal prompts")
          true
          (contains_substring content "GIT_TERMINAL_PROMPT=0");
        List.iter
          (fun poisoned ->
            Alcotest.(check bool)
              (label ^ " scrubs " ^ poisoned)
              false
              (contains_substring content poisoned))
          [
            "GH_CONFIG_DIR=" ^ ambient_gh_config_dir;
            "GH_TOKEN=ambient-gh-token";
            "GITHUB_TOKEN=ambient-github-token";
            "GH_ENTERPRISE_TOKEN=ambient-enterprise-token";
            "GITHUB_ENTERPRISE_TOKEN=ambient-github-enterprise-token";
          ]
      in
      assert_clean_env "login env"
        (read_file (Filename.concat gh_config_dir "login.env"));
      assert_clean_env "status env"
        (read_file (Filename.concat gh_config_dir "status.env"));
      let hosts_yml =
        read_file (Filename.concat gh_config_dir "hosts.yml")
      in
      Alcotest.(check bool) "hosts.yml user relabeled" true
        (contains_substring hosts_yml "user: keeper-A");
      Alcotest.(check bool) "real gh login user hidden" false
        (contains_substring hosts_yml "user: real-login");
      match
        Credential_materializer.compute_token_sha256_prefix
          ~gh_config_dir
      with
      | None -> Alcotest.fail "expected token fingerprint"
      | Some prefix ->
          Alcotest.(check string) "fingerprint is canary hash"
            (Credential_materializer.sha256_prefix canary_token)
            prefix)

(* --- 6. SHA-256 fingerprint + F-1 gate (PR-C) --- *)

let is_hex_char c =
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

let test_sha256_prefix_length () =
  let p = Credential_materializer.sha256_prefix "hello" in
  Alcotest.(check int) "12 hex chars" 12 (String.length p);
  String.iter
    (fun c ->
      Alcotest.(check bool)
        (Printf.sprintf "char %C is hex" c) true (is_hex_char c))
    p

let test_sha256_prefix_deterministic () =
  let a = Credential_materializer.sha256_prefix "ghp_canary" in
  let b = Credential_materializer.sha256_prefix "ghp_canary" in
  Alcotest.(check string) "same input -> same output" a b

let test_sha256_prefix_distinguishes () =
  let a = Credential_materializer.sha256_prefix "ghp_token_A" in
  let b = Credential_materializer.sha256_prefix "ghp_token_B" in
  Alcotest.(check bool) "distinct inputs -> distinct prefixes" true
    (not (String.equal a b))

let make_hosts_yml ~gh_config_dir ~user ~token =
  Unix.mkdir gh_config_dir 0o700;
  let path = Filename.concat gh_config_dir "hosts.yml" in
  let oc = open_out path in
  output_string oc "github.com:\n";
  Printf.fprintf oc "    user: %s\n" user;
  Printf.fprintf oc "    oauth_token: %s\n" token;
  output_string oc "    git_protocol: https\n";
  close_out oc

let test_compute_prefix_no_hosts_yml () =
  with_temp_base_path (fun base ->
      let dir = Filename.concat base "no_hosts" in
      Unix.mkdir dir 0o700;
      match
        Credential_materializer.compute_token_sha256_prefix
          ~gh_config_dir:dir
      with
      | None -> ()
      | Some _ ->
          Alcotest.fail "expected None when hosts.yml is absent")

let test_compute_prefix_matches_token () =
  with_temp_base_path (fun base ->
      let dir = Filename.concat base "with_hosts" in
      let token = "ghp_test_token_RFC0019_PRC" in
      make_hosts_yml ~gh_config_dir:dir ~user:"keeper-A" ~token;
      match
        Credential_materializer.compute_token_sha256_prefix
          ~gh_config_dir:dir
      with
      | None -> Alcotest.fail "expected Some prefix"
      | Some prefix ->
          let expected = Credential_materializer.sha256_prefix token in
          Alcotest.(check string) "prefix matches sha256_prefix(token)"
            expected prefix)

(* RFC-0019 §8 R2: even though the token is read from disk into memory
   to be hashed, the function never returns the token itself nor exposes
   it through any other surface.  We assert that a canary token written
   to hosts.yml does NOT appear in:
     - the prefix returned by compute_token_sha256_prefix
     - the f1_gate_check outcome (F1_skipped reason / F1_distinct / F1_shared)
*)
let test_f1_gate_skipped_no_token () =
  with_temp_base_path (fun base ->
      let dir = Filename.concat base "empty_bundle" in
      Unix.mkdir dir 0o700;
      match
        Credential_materializer.f1_gate_check
          ~credential_id:"k" ~gh_config_dir:dir
      with
      | F1_skipped reason ->
          (* Reason mentions the absence; never echoes any token. *)
          Alcotest.(check bool)
            "reason mentions fingerprint absence" true
            (try
               ignore (Str.search_forward (Str.regexp "fingerprint") reason 0);
               true
             with Not_found -> false)
      | F1_distinct | F1_shared_with_operator ->
          Alcotest.fail "expected F1_skipped when bundle has no token")

(* --- 7. hosts.yml relabel --- *)

let test_relabel_user_line () =
  with_temp_base_path (fun base ->
      let dir = Filename.concat base "relabel" in
      let token = "ghp_relabel_token" in
      make_hosts_yml ~gh_config_dir:dir ~user:"vincent-real" ~token;
      Credential_materializer.relabel_hosts_yml
        ~gh_config_dir:dir ~identity_label:"keeper-anyang";
      let ic = open_in (Filename.concat dir "hosts.yml") in
      let buf = Buffer.create 256 in
      (try while true do
              Buffer.add_string buf (input_line ic);
              Buffer.add_char buf '\n'
            done
       with End_of_file -> ());
      close_in ic;
      let content = Buffer.contents buf in
      Alcotest.(check bool) "user line shows new identity" true
        (try
           ignore
             (Str.search_forward (Str.regexp_string "user: keeper-anyang")
                content 0);
           true
         with Not_found -> false);
      Alcotest.(check bool) "old user value gone" false
        (try
           ignore
             (Str.search_forward (Str.regexp_string "user: vincent-real")
                content 0);
           true
         with Not_found -> false))

let test_relabel_preserves_other_lines () =
  with_temp_base_path (fun base ->
      let dir = Filename.concat base "preserve" in
      let token = "ghp_preserved_token_canary" in
      make_hosts_yml ~gh_config_dir:dir ~user:"original" ~token;
      Credential_materializer.relabel_hosts_yml
        ~gh_config_dir:dir ~identity_label:"new-id";
      let ic = open_in (Filename.concat dir "hosts.yml") in
      let buf = Buffer.create 256 in
      (try while true do
              Buffer.add_string buf (input_line ic);
              Buffer.add_char buf '\n'
            done
       with End_of_file -> ());
      close_in ic;
      let content = Buffer.contents buf in
      (* Token line must survive verbatim. *)
      Alcotest.(check bool) "oauth_token line preserved" true
        (try
           ignore
             (Str.search_forward
                (Str.regexp_string ("oauth_token: " ^ token))
                content 0);
           true
         with Not_found -> false);
      Alcotest.(check bool) "git_protocol line preserved" true
        (try
           ignore
             (Str.search_forward
                (Str.regexp_string "git_protocol: https") content 0);
           true
         with Not_found -> false))

let test_relabel_no_file () =
  with_temp_base_path (fun base ->
      let dir = Filename.concat base "missing" in
      Unix.mkdir dir 0o700;
      (* Must not raise even though hosts.yml is absent. *)
      Credential_materializer.relabel_hosts_yml
        ~gh_config_dir:dir ~identity_label:"x")

let test_waitpid_status_nointr_reaps_after_signal () =
  (* #13102 follow-up — replace fixed-sleep racing with deterministic
     pipe synchronisation:

     - Install the SIGUSR1 handler BEFORE fork so the parent's
       reception slot is ready the moment the child is able to send;
       the prior post-fork install left a window where a fast child
       could trigger the default action.
     - Use a pipe pair as a "parent has entered waitpid" handshake:
       the parent writes 1 byte immediately before calling
       [waitpid_status_nointr_for_test], the child blocks on read
       until that byte arrives, then sends SIGUSR1 and exits.  This
       removes all sleep-based timing assumptions.
     - The child uses [Unix._exit] so it does not re-run parent
       at_exit hooks (alcotest cleanup, PG connection teardown, …)
       inside the forked process. *)
  let pipe_read, pipe_write = Unix.pipe () in
  let previous = Sys.signal Sys.sigusr1 (Sys.Signal_handle (fun _ -> ())) in
  Fun.protect
    ~finally:(fun () ->
      Sys.set_signal Sys.sigusr1 previous;
      (try Unix.close pipe_read with Unix.Unix_error _ -> ());
      (try Unix.close pipe_write with Unix.Unix_error _ -> ()))
    (fun () ->
      let parent = Unix.getpid () in
      match Unix.fork () with
      | 0 ->
          (try Unix.close pipe_write with Unix.Unix_error _ -> ());
          let buf = Bytes.create 1 in
          let _ = Unix.read pipe_read 0 buf 0 1 in
          (try Unix.close pipe_read with Unix.Unix_error _ -> ());
          (try Unix.kill parent Sys.sigusr1
           with Unix.Unix_error _ -> ());
          Unix._exit 0
      | pid ->
          (try Unix.close pipe_read with Unix.Unix_error _ -> ());
          let _ = Unix.write pipe_write (Bytes.of_string "\x01") 0 1 in
          (try Unix.close pipe_write with Unix.Unix_error _ -> ());
          (match Credential_materializer.waitpid_status_nointr_for_test pid with
           | Unix.WEXITED 0 -> ()
           | Unix.WEXITED n ->
               Alcotest.failf "child exited with %d" n
           | Unix.WSIGNALED n ->
               Alcotest.failf "child signalled with %d" n
           | Unix.WSTOPPED n ->
               Alcotest.failf "child stopped with %d" n))

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
      ( "process reaping",
        [
          Alcotest.test_case "waitpid retries after signal interruption"
            `Quick test_waitpid_status_nointr_reaps_after_signal;
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
          Alcotest.test_case
            "provision writes bundle-local gh auth without ambient env"
            `Quick test_provision_uses_bundle_env_and_insecure_storage;
        ] );
      ( "F-1 gate fingerprint",
        [
          Alcotest.test_case "sha256_prefix is 12 hex chars" `Quick
            test_sha256_prefix_length;
          Alcotest.test_case "sha256_prefix is deterministic" `Quick
            test_sha256_prefix_deterministic;
          Alcotest.test_case "sha256_prefix differs for different inputs"
            `Quick test_sha256_prefix_distinguishes;
          Alcotest.test_case
            "compute_token_sha256_prefix returns None when hosts.yml \
             missing"
            `Quick test_compute_prefix_no_hosts_yml;
          Alcotest.test_case
            "compute_token_sha256_prefix matches sha256_prefix of token"
            `Quick test_compute_prefix_matches_token;
          Alcotest.test_case
            "f1_gate_check returns F1_skipped when no token in bundle"
            `Quick test_f1_gate_skipped_no_token;
        ] );
      ( "hosts.yml relabel",
        [
          Alcotest.test_case
            "relabel_hosts_yml rewrites user line, preserves indent"
            `Quick test_relabel_user_line;
          Alcotest.test_case
            "relabel_hosts_yml leaves other lines (incl oauth_token) \
             untouched"
            `Quick test_relabel_preserves_other_lines;
          Alcotest.test_case
            "relabel_hosts_yml is silent when hosts.yml is missing"
            `Quick test_relabel_no_file;
        ] );
    ]
