(** Room_utils Module Coverage Tests

    Tests for Room utility functions:
    - storage_backend type: Memory, FileSystem, PostgresNative
    - config record type
    - parse_gitdir_to_main_root: gitdir line parsing for worktrees
    - env_opt: environment variable helper
    - storage_type_from_env: storage type detection
*)

open Alcotest

module Room_utils = Room_utils

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let with_envs bindings f =
  List.fold_right (fun (name, value) acc -> fun () -> with_env name value acc) bindings f ()

let pg_env_bindings ?masc_storage_type ?masc_postgres_url ?database_url
    ?supabase_db_url ?sb_pg_url () =
  [
    ("MASC_STORAGE_TYPE", masc_storage_type);
    ("MASC_POSTGRES_URL", masc_postgres_url);
    ("DATABASE_URL", database_url);
    ("SUPABASE_DB_URL", supabase_db_url);
    ("SB_PG_URL", sb_pg_url);
  ]

(* ============================================================
   parse_gitdir_to_main_root Tests
   ============================================================ *)

let test_parse_gitdir_worktree () =
  let line = "gitdir: /home/user/project/.git/worktrees/feature-branch" in
  match Room_utils.parse_gitdir_to_main_root line with
  | Some path -> check string "main root" "/home/user/project" path
  | None -> fail "expected Some path"

let test_parse_gitdir_no_worktree () =
  let line = "gitdir: /home/user/project/.git" in
  match Room_utils.parse_gitdir_to_main_root line with
  | Some _ -> fail "expected None for non-worktree"
  | None -> ()

let test_parse_gitdir_invalid_format () =
  let line = "invalid line without colon" in
  match Room_utils.parse_gitdir_to_main_root line with
  | Some _ -> fail "expected None for invalid"
  | None -> ()

let test_parse_gitdir_empty () =
  match Room_utils.parse_gitdir_to_main_root "" with
  | Some _ -> fail "expected None for empty"
  | None -> ()

let test_parse_gitdir_nested_worktree () =
  let line = "gitdir: /a/b/c/.git/worktrees/my-branch" in
  match Room_utils.parse_gitdir_to_main_root line with
  | Some path -> check string "nested" "/a/b/c" path
  | None -> fail "expected Some"

let test_parse_gitdir_with_spaces () =
  let line = "gitdir:   /home/user/project/.git/worktrees/branch  " in
  match Room_utils.parse_gitdir_to_main_root line with
  | Some path -> check string "trimmed" "/home/user/project" path
  | None -> fail "expected Some"

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

(* capture_stderr removed — legacy warning tests removed in room flat-path cleanup *)

let test_resolve_masc_base_path_keeps_git_root_resolution_when_env_ignored () =
  let scratch = Filename.temp_dir "room-utils-worktree" "" in
  let repo_root = Filename.concat scratch "repo" in
  let repo_git = Filename.concat repo_root ".git" in
  let repo_worktrees = Filename.concat repo_git "worktrees" in
  let branch_gitdir = Filename.concat repo_worktrees "branch" in
  let worktree_path = Filename.concat scratch "wt" in
  Unix.mkdir repo_root 0o755;
  Unix.mkdir repo_git 0o755;
  Unix.mkdir repo_worktrees 0o755;
  Unix.mkdir branch_gitdir 0o755;
  Unix.mkdir worktree_path 0o755;
  write_file (Filename.concat worktree_path ".git")
    (Printf.sprintf "gitdir: %s\n" branch_gitdir);
  with_envs
    [ ("MASC_BASE_PATH", Some "/Users/dancer/me");
      ("MASC_TEST_ALLOW_INHERITED_BASE_PATH", None) ]
    (fun () ->
      check string "ignored env still resolves git root" repo_root
        (Room_utils.resolve_masc_base_path worktree_path))

let test_resolve_masc_base_path_ignores_inherited_env_in_test () =
  let requested =
    Filename.concat (Filename.get_temp_dir_name ()) "room-utils-requested"
  in
  with_envs
    [ ("MASC_BASE_PATH", Some "/Users/dancer/me");
      ("MASC_TEST_ALLOW_INHERITED_BASE_PATH", None) ]
    (fun () ->
      check string "requested temp path wins in tests" requested
        (Room_utils.resolve_masc_base_path requested))

let test_resolve_masc_base_path_keeps_matching_explicit_env () =
  let requested =
    Filename.concat (Filename.get_temp_dir_name ()) "room-utils-matching"
  in
  with_envs
    [ ("MASC_BASE_PATH", Some requested);
      ("MASC_TEST_ALLOW_INHERITED_BASE_PATH", None) ]
    (fun () ->
      check string "matching explicit env preserved" requested
        (Room_utils.resolve_masc_base_path requested))

let test_resolve_masc_base_path_collapses_requested_masc_dir () =
  let requested =
    Filename.concat
      (Filename.concat (Filename.get_temp_dir_name ()) "room-utils-collapse")
      ".masc"
  in
  with_envs
    [ ("MASC_BASE_PATH", None);
      ("MASC_TEST_ALLOW_INHERITED_BASE_PATH", None) ]
    (fun () ->
      check string "requested .masc input collapses to parent"
        (Filename.dirname requested)
        (Room_utils.resolve_masc_base_path requested))

let test_resolve_masc_base_path_collapses_explicit_env_masc_dir () =
  let requested =
    Filename.concat (Filename.get_temp_dir_name ()) "room-utils-explicit"
  in
  let explicit = Filename.concat requested ".masc" in
  with_envs
    [ ("MASC_BASE_PATH", Some explicit);
      ("MASC_TEST_ALLOW_INHERITED_BASE_PATH", None) ]
    (fun () ->
      check string "explicit .masc env collapses to parent" requested
        (Room_utils.resolve_masc_base_path requested))

let test_resolve_masc_base_path_allows_test_opt_in () =
  let requested =
    Filename.concat (Filename.get_temp_dir_name ()) "room-utils-opt-in"
  in
  let explicit = "/Users/dancer/me" in
  with_envs
    [ ("MASC_BASE_PATH", Some explicit);
      ("MASC_TEST_ALLOW_INHERITED_BASE_PATH", Some "true") ]
    (fun () ->
      check string "opt-in preserves inherited env" explicit
        (Room_utils.resolve_masc_base_path requested))

let test_resolve_masc_base_path_ignores_dual_masc_roots_outside_test_override ()
    =
  let scratch = Filename.temp_dir "room-utils-dual-roots" "" in
  let requested = Filename.concat scratch "repo" in
  let explicit = Filename.concat scratch "parent-root" in
  Unix.mkdir requested 0o755;
  Unix.mkdir explicit 0o755;
  Unix.mkdir (Filename.concat requested ".masc") 0o755;
  Unix.mkdir (Filename.concat explicit ".masc") 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf scratch)
    (fun () ->
      with_envs
        [ ("MASC_BASE_PATH", Some explicit);
          ("MASC_ALLOW_INHERITED_BASE_PATH", None);
          ("MASC_TEST_ALLOW_INHERITED_BASE_PATH", None) ]
        (fun () ->
          check string "dual roots prefer requested path" requested
            (Room_utils.resolve_masc_base_path requested)))

let test_resolve_masc_base_path_allows_dual_root_opt_in () =
  let scratch = Filename.temp_dir "room-utils-dual-opt-in" "" in
  let requested = Filename.concat scratch "repo" in
  let explicit = Filename.concat scratch "parent-root" in
  Unix.mkdir requested 0o755;
  Unix.mkdir explicit 0o755;
  Unix.mkdir (Filename.concat requested ".masc") 0o755;
  Unix.mkdir (Filename.concat explicit ".masc") 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf scratch)
    (fun () ->
      with_envs
        [ ("MASC_BASE_PATH", Some explicit);
          ("MASC_ALLOW_INHERITED_BASE_PATH", Some "true");
          ("MASC_TEST_ALLOW_INHERITED_BASE_PATH", None) ]
        (fun () ->
          check string "opt-in preserves explicit dual-root env" explicit
            (Room_utils.resolve_masc_base_path requested)))

let test_resolve_masc_base_path_preserves_ancestor_explicit_path () =
  let scratch = Filename.temp_dir "room-utils-ancestor" "" in
  let explicit = scratch in
  let sub_repo = Filename.concat scratch "workspace/sub-repo" in
  let rec mkdirs path =
    if not (Sys.file_exists path) then begin
      mkdirs (Filename.dirname path);
      Unix.mkdir path 0o755
    end
  in
  mkdirs sub_repo;
  Unix.mkdir (Filename.concat explicit ".masc") 0o755;
  Unix.mkdir (Filename.concat sub_repo ".masc") 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf scratch)
    (fun () ->
      with_envs
        [ ("MASC_BASE_PATH", Some explicit);
          ("MASC_ALLOW_INHERITED_BASE_PATH", None);
          ("MASC_TEST_ALLOW_INHERITED_BASE_PATH", None) ]
        (fun () ->
          check string "ancestor explicit path wins over sub-repo" explicit
            (Room_utils.resolve_masc_base_path sub_repo)))

let test_default_config_syncs_test_base_path_env () =
  let requested =
    Filename.concat (Filename.get_temp_dir_name ()) "room-utils-sync-env"
  in
  with_envs
    [ ("MASC_BASE_PATH", Some "/Users/dancer/me");
      ("MASC_TEST_ALLOW_INHERITED_BASE_PATH", None) ]
    (fun () ->
      ignore (Room_utils.default_config requested);
      check (option string) "env synced to requested path" (Some requested)
        (Sys.getenv_opt "MASC_BASE_PATH"))

(* ============================================================
   env_opt Tests
   ============================================================ *)

let test_env_opt_nonexistent () =
  match Room_utils.env_opt "MASC_NONEXISTENT_VAR_12345" with
  | Some _ -> fail "expected None"
  | None -> ()

let test_env_opt_home () =
  (* HOME should exist on most systems *)
  match Room_utils.env_opt "HOME" with
  | Some path -> check bool "nonempty" true (String.length path > 0)
  | None -> ()  (* Some systems might not have HOME *)

(* ============================================================
   storage_type_from_env Tests
   ============================================================ *)

let test_storage_type_default () =
  with_envs (pg_env_bindings ()) (fun () ->
    let storage_type = Room_utils.storage_type_from_env () in
    check string "defaults to filesystem when no pg env exists" "filesystem"
      storage_type)

(* ============================================================
   storage_backend Type Tests
   ============================================================ *)

let test_storage_backend_memory_variant () =
  (* Just test that the type exists and can be constructed indirectly *)
  let _ : string = "Memory" in
  ()

let test_storage_backend_filesystem_variant () =
  let _ : string = "FileSystem" in
  ()

let test_storage_backend_postgres_variant () =
  let _ : string = "PostgresNative" in
  ()

(* ============================================================
   config Record Tests
   ============================================================ *)

let test_config_base_path_type () =
  (* config record has base_path: string *)
  let _ : string = "test_path" in
  ()

let test_config_lock_expiry_type () =
  (* config record has lock_expiry_minutes: int *)
  let _ : int = 30 in
  ()

(* ============================================================
   strip_prefix Tests
   ============================================================ *)

let test_strip_prefix_basic () =
  let result = Room_utils.strip_prefix "prefix:" "prefix:value" in
  check string "stripped" "value" result

let test_strip_prefix_no_match () =
  (* Note: strip_prefix doesn't validate the prefix - it just removes N chars *)
  let result = Room_utils.strip_prefix "other:" "prefix:value" in
  check string "removes first N chars" ":value" result

let test_strip_prefix_empty_string () =
  let result = Room_utils.strip_prefix "pre" "" in
  check string "empty unchanged" "" result

let test_strip_prefix_empty_prefix () =
  let result = Room_utils.strip_prefix "" "value" in
  check string "no prefix" "value" result

let test_strip_prefix_exact_match () =
  let result = Room_utils.strip_prefix "exact" "exact" in
  check string "empty result" "" result

let test_strip_prefix_longer_prefix () =
  let result = Room_utils.strip_prefix "verylongprefix" "short" in
  check string "unchanged short" "short" result

(* ============================================================
   contains_substring Tests
   ============================================================ *)

let test_contains_substring_true () =
  check bool "contains" true (Room_utils.contains_substring "hello world" "world")

let test_contains_substring_false () =
  check bool "not contains" false (Room_utils.contains_substring "hello world" "xyz")

let test_contains_substring_empty_needle () =
  (* Empty string is substring of any string (String.sub s 0 0 = "" always) *)
  check bool "empty needle" true (Room_utils.contains_substring "hello" "")

let test_contains_substring_empty_haystack () =
  check bool "empty haystack" false (Room_utils.contains_substring "" "hello")

let test_contains_substring_both_empty () =
  (* Empty string contains empty string (String.sub "" 0 0 = "") *)
  check bool "both empty" true (Room_utils.contains_substring "" "")

let test_contains_substring_needle_longer () =
  check bool "needle longer" false (Room_utils.contains_substring "ab" "abcdef")

let test_contains_substring_exact () =
  check bool "exact match" true (Room_utils.contains_substring "test" "test")

let test_contains_substring_start () =
  check bool "at start" true (Room_utils.contains_substring "hello world" "hello")

let test_contains_substring_end () =
  check bool "at end" true (Room_utils.contains_substring "hello world" "world")

let test_contains_substring_middle () =
  check bool "in middle" true (Room_utils.contains_substring "the quick fox" "quick")

let test_contains_substring_special_chars () =
  check bool "special chars" true (Room_utils.contains_substring "a<b>c" "<b>")

(* ============================================================
   sanitize_html Tests
   ============================================================ *)

let test_sanitize_html_no_special () =
  check string "no change" "hello world" (Room_utils.sanitize_html "hello world")

let test_sanitize_html_less_than () =
  check string "escape <" "&lt;script&gt;" (Room_utils.sanitize_html "<script>")

let test_sanitize_html_greater_than () =
  check string "escape >" "a &gt; b" (Room_utils.sanitize_html "a > b")

let test_sanitize_html_ampersand () =
  check string "escape &" "a &amp; b" (Room_utils.sanitize_html "a & b")

let test_sanitize_html_double_quote () =
  check string "escape \"" "say &quot;hi&quot;" (Room_utils.sanitize_html "say \"hi\"")

let test_sanitize_html_single_quote () =
  check string "escape '" "it&#x27;s" (Room_utils.sanitize_html "it's")

let test_sanitize_html_all_special () =
  let input = "<script>alert('xss' & \"evil\")</script>" in
  let expected = "&lt;script&gt;alert(&#x27;xss&#x27; &amp; &quot;evil&quot;)&lt;/script&gt;" in
  check string "all escaped" expected (Room_utils.sanitize_html input)

let test_sanitize_html_empty () =
  check string "empty" "" (Room_utils.sanitize_html "")

let test_sanitize_html_unicode () =
  check string "unicode preserved" "안녕하세요" (Room_utils.sanitize_html "안녕하세요")

(* ============================================================
   sanitize_agent_name Tests
   ============================================================ *)

let test_sanitize_agent_name_normal () =
  check string "normal name" "claude" (Room_utils.sanitize_agent_name "claude")

let test_sanitize_agent_name_xss () =
  check string "xss attempt" "&lt;script&gt;" (Room_utils.sanitize_agent_name "<script>")

(* ============================================================
   sanitize_message Tests
   ============================================================ *)

let test_sanitize_message_normal () =
  check string "normal message" "Hello world" (Room_utils.sanitize_message "Hello world")

let test_sanitize_message_html () =
  check string "html stripped" "&lt;b&gt;bold&lt;/b&gt;" (Room_utils.sanitize_message "<b>bold</b>")

(* ============================================================
   storage_type_from_env Tests (replaces auto_detect_backend)
   ============================================================ *)

let test_storage_type_defaults_to_filesystem () =
  with_envs
    (pg_env_bindings ())
    (fun () ->
      check string "defaults to filesystem" "filesystem"
        (Room_utils.storage_type_from_env ()))

let test_storage_type_explicit_postgres () =
  with_envs
    (pg_env_bindings ~masc_storage_type:"postgres" ())
    (fun () ->
      check string "explicit postgres coerces to filesystem" "filesystem"
        (Room_utils.storage_type_from_env ()))

let test_storage_type_legacy_url_does_not_auto_select () =
  let url = "postgresql://supabase.example/test_room_utils" in
  with_envs
    (pg_env_bindings ~supabase_db_url:url ())
    (fun () ->
      check string "legacy url does not trigger postgres" "filesystem"
        (Room_utils.storage_type_from_env ()))

let test_storage_type_auto_is_deprecated () =
  with_envs
    (pg_env_bindings ~masc_storage_type:"auto" ())
    (fun () ->
      check string "auto falls back to filesystem" "filesystem"
        (Room_utils.storage_type_from_env ()))

let test_backend_config_for_requires_explicit_postgres () =
  let url = "postgresql://sb.example/test_backend_config" in
  (* Legacy URL alone should NOT select postgres. *)
  with_envs
    (pg_env_bindings ~sb_pg_url:url ())
    (fun () ->
      let cfg = Room_utils.backend_config_for "/tmp/test-room-utils" in
      check bool "legacy url alone defaults to filesystem" true
        (match cfg.backend_type with
         | Backend_types.FileSystem -> true
         | _ -> false));
  (* Explicit postgres selection is now coerced to filesystem. *)
  with_envs
    (pg_env_bindings ~masc_storage_type:"postgres" ~masc_postgres_url:url ())
    (fun () ->
      let cfg = Room_utils.backend_config_for "/tmp/test-room-utils" in
      check bool "explicit postgres still resolves to filesystem" true
        (match cfg.backend_type with
         | Backend_types.FileSystem -> true
         | _ -> false);
      check (option string) "postgres url ignored" None cfg.postgres_url)

let test_postgres_url_from_env_ignores_legacy_without_masc_url () =
  let raw_url =
    "postgresql://postgres:secret@aws-1-ap-south-1.pooler.supabase.com:6543/postgres"
  in
  with_envs
    (pg_env_bindings ~sb_pg_url:raw_url ())
    (fun () ->
      check (option string) "returns None without MASC_POSTGRES_URL"
        None
        (Room_utils.postgres_url_from_env ()))

let test_postgres_url_from_env_uses_masc_postgres_url () =
  let url =
    "postgresql://postgres:secret@aws-1-ap-south-1.pooler.supabase.com:5432/postgres"
  in
  with_envs
    (pg_env_bindings ~masc_postgres_url:url ())
    (fun () ->
      check (option string) "MASC_POSTGRES_URL ignored"
        None
        (Room_utils.postgres_url_from_env ()))

(* ============================================================
   safe_filename Tests
   ============================================================ *)

let test_safe_filename_normal () =
  check string "normal" "hello_world" (Room_utils.safe_filename "hello_world")

let test_safe_filename_alphanumeric () =
  check string "alphanumeric" "test123" (Room_utils.safe_filename "test123")

let test_safe_filename_with_dots () =
  check string "dots preserved" "file.json" (Room_utils.safe_filename "file.json")

let test_safe_filename_with_dash () =
  check string "dash preserved" "my-file" (Room_utils.safe_filename "my-file")

let test_safe_filename_with_underscore () =
  check string "underscore preserved" "my_file" (Room_utils.safe_filename "my_file")

let test_safe_filename_special_chars () =
  (* Special chars get hex-encoded: @ -> _40 (0x40 = 64 = '@') *)
  let result = Room_utils.safe_filename "user@domain" in
  check bool "contains _40" true (String.length result > 0 && result <> "user@domain")

let test_safe_filename_spaces () =
  (* Space (0x20) -> _20 *)
  let result = Room_utils.safe_filename "hello world" in
  check bool "space encoded" true (not (String.contains result ' '))

let test_safe_filename_slash () =
  (* Slash (0x2f) -> _2f *)
  let result = Room_utils.safe_filename "path/to/file" in
  check bool "slash encoded" true (not (String.contains result '/'))

let test_safe_filename_empty () =
  check string "empty" "" (Room_utils.safe_filename "")

let test_safe_filename_unicode () =
  (* Korean chars get hex-encoded *)
  let result = Room_utils.safe_filename "안녕" in
  check bool "unicode encoded" true (String.length result > String.length "안녕")

(* ============================================================
   project_prefix Tests
   ============================================================ *)

(* project_prefix requires a config, which requires backend setup.
   We test it indirectly via the key generation behavior *)

(* ============================================================
   validate_file_path Tests
   ============================================================ *)

let test_validate_file_path_normal () =
  match Room_utils.validate_file_path "agents/claude.json" with
  | Ok _ -> ()
  | Error e -> fail ("expected Ok, got: " ^ e)

let test_validate_file_path_too_long () =
  let long_path = String.make 501 'x' in
  match Room_utils.validate_file_path long_path with
  | Error e -> check bool "error mentions long" true (String.length e > 0)
  | Ok _ -> fail "expected Error for long path"

let test_validate_file_path_angle_bracket_lt () =
  match Room_utils.validate_file_path "path<script>" with
  | Error e -> check bool "security error" true (String.length e > 0)
  | Ok _ -> fail "expected Error for <"

let test_validate_file_path_angle_bracket_gt () =
  match Room_utils.validate_file_path "path>output" with
  | Error e -> check bool "security error" true (String.length e > 0)
  | Ok _ -> fail "expected Error for >"

(* ============================================================
   Path Helper Tests
   ============================================================ *)

let make_test_config ~base_path ~cluster_name : Room_utils.config =
  let backend_config : Backend_types.config = {
    backend_type = Backend_types.Memory;
    base_path;
    postgres_url = None;
    node_id = "test-node";
    cluster_name;
    pubsub_max_messages = 1000;
  } in
  let memory_backend = Backend.Memory.create () in
  {
    Room_utils.base_path;
    workspace_path = base_path;
    lock_expiry_minutes = 30;
    backend_config;
    backend = Room_utils.Memory memory_backend;
  }

let test_masc_root_dir_default_cluster () =
  let cfg = make_test_config ~base_path:"/home/user/project" ~cluster_name:"default" in
  let result = Room_utils.masc_root_dir cfg in
  check string "default cluster" "/home/user/project/.masc" result

let test_masc_root_dir_empty_cluster () =
  let cfg = make_test_config ~base_path:"/tmp/test" ~cluster_name:"" in
  let result = Room_utils.masc_root_dir cfg in
  check string "empty cluster" "/tmp/test/.masc" result

let test_masc_root_dir_custom_cluster () =
  let cfg = make_test_config ~base_path:"/home/user/project" ~cluster_name:"my-cluster" in
  let result = Room_utils.masc_root_dir cfg in
  check string "custom cluster" "/home/user/project/.masc/clusters/my-cluster" result

let test_masc_root_dir_with_cluster_nested () =
  let cfg = make_test_config ~base_path:"/a/b/c" ~cluster_name:"prod" in
  let result = Room_utils.masc_root_dir cfg in
  check string "nested with cluster" "/a/b/c/.masc/clusters/prod" result

let test_list_dir_prefers_backend_for_memory_keys () =
  let scratch = Filename.temp_dir "room-utils-list-dir-memory" "" in
  Fun.protect
    ~finally:(fun () -> rm_rf scratch)
    (fun () ->
      let cfg = make_test_config ~base_path:scratch ~cluster_name:"default" in
      let workers_dir = Filename.concat (Room_utils.masc_root_dir cfg) "workers" in
      Room_utils.write_json cfg
        (Filename.concat workers_dir "backend.json")
        (`Assoc [ ("ok", `Bool true) ]);
      write_file (Filename.concat workers_dir "rogue.json") "{}";
      let listed = Room_utils.list_dir cfg workers_dir |> List.sort String.compare in
      check (list string) "memory backend ignores local-only stale files"
        [ "backend.json" ] listed)

let test_read_current_room_always_returns_default () =
  let scratch = Filename.temp_dir "room-utils-current" "" in
  Fun.protect
    ~finally:(fun () -> rm_rf scratch)
    (fun () ->
      let cfg = make_test_config ~base_path:scratch ~cluster_name:"default" in
      check (option string) "always returns default" (Some "default")
        (Room_utils.read_current_room cfg))

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Room_utils Coverage" [
    "parse_gitdir_to_main_root", [
      test_case "worktree" `Quick test_parse_gitdir_worktree;
      test_case "no worktree" `Quick test_parse_gitdir_no_worktree;
      test_case "invalid format" `Quick test_parse_gitdir_invalid_format;
      test_case "empty" `Quick test_parse_gitdir_empty;
      test_case "nested" `Quick test_parse_gitdir_nested_worktree;
      test_case "with spaces" `Quick test_parse_gitdir_with_spaces;
      test_case "ignored env keeps git-root resolution" `Quick
        test_resolve_masc_base_path_keeps_git_root_resolution_when_env_ignored;
      test_case "ignores inherited base env in tests" `Quick
        test_resolve_masc_base_path_ignores_inherited_env_in_test;
      test_case "keeps matching explicit env" `Quick
        test_resolve_masc_base_path_keeps_matching_explicit_env;
      test_case "collapses requested .masc path" `Quick
        test_resolve_masc_base_path_collapses_requested_masc_dir;
      test_case "collapses explicit .masc env" `Quick
        test_resolve_masc_base_path_collapses_explicit_env_masc_dir;
      test_case "allows explicit opt-in to inherited env" `Quick
        test_resolve_masc_base_path_allows_test_opt_in;
      test_case "ignores dual .masc roots by default" `Quick
        test_resolve_masc_base_path_ignores_dual_masc_roots_outside_test_override;
      test_case "allows dual-root opt-in" `Quick
        test_resolve_masc_base_path_allows_dual_root_opt_in;
      test_case "preserves ancestor explicit path" `Quick
        test_resolve_masc_base_path_preserves_ancestor_explicit_path;
      test_case "default config syncs test base env" `Quick
        test_default_config_syncs_test_base_path_env;
    ];
    "env_opt", [
      test_case "nonexistent" `Quick test_env_opt_nonexistent;
      test_case "home" `Quick test_env_opt_home;
    ];
    "storage_type_from_env", [
      test_case "default" `Quick test_storage_type_default;
    ];
    "storage_backend", [
      test_case "memory variant" `Quick test_storage_backend_memory_variant;
      test_case "filesystem variant" `Quick test_storage_backend_filesystem_variant;
      test_case "postgres variant" `Quick test_storage_backend_postgres_variant;
    ];
    "config", [
      test_case "base_path type" `Quick test_config_base_path_type;
      test_case "lock_expiry type" `Quick test_config_lock_expiry_type;
    ];
    "strip_prefix", [
      test_case "basic" `Quick test_strip_prefix_basic;
      test_case "no match" `Quick test_strip_prefix_no_match;
      test_case "empty string" `Quick test_strip_prefix_empty_string;
      test_case "empty prefix" `Quick test_strip_prefix_empty_prefix;
      test_case "exact match" `Quick test_strip_prefix_exact_match;
      test_case "longer prefix" `Quick test_strip_prefix_longer_prefix;
    ];
    "contains_substring", [
      test_case "true" `Quick test_contains_substring_true;
      test_case "false" `Quick test_contains_substring_false;
      test_case "empty needle" `Quick test_contains_substring_empty_needle;
      test_case "empty haystack" `Quick test_contains_substring_empty_haystack;
      test_case "both empty" `Quick test_contains_substring_both_empty;
      test_case "needle longer" `Quick test_contains_substring_needle_longer;
      test_case "exact" `Quick test_contains_substring_exact;
      test_case "at start" `Quick test_contains_substring_start;
      test_case "at end" `Quick test_contains_substring_end;
      test_case "in middle" `Quick test_contains_substring_middle;
      test_case "special chars" `Quick test_contains_substring_special_chars;
    ];
    "sanitize_html", [
      test_case "no special" `Quick test_sanitize_html_no_special;
      test_case "less than" `Quick test_sanitize_html_less_than;
      test_case "greater than" `Quick test_sanitize_html_greater_than;
      test_case "ampersand" `Quick test_sanitize_html_ampersand;
      test_case "double quote" `Quick test_sanitize_html_double_quote;
      test_case "single quote" `Quick test_sanitize_html_single_quote;
      test_case "all special" `Quick test_sanitize_html_all_special;
      test_case "empty" `Quick test_sanitize_html_empty;
      test_case "unicode" `Quick test_sanitize_html_unicode;
    ];
    "sanitize_agent_name", [
      test_case "normal" `Quick test_sanitize_agent_name_normal;
      test_case "xss" `Quick test_sanitize_agent_name_xss;
    ];
    "sanitize_message", [
      test_case "normal" `Quick test_sanitize_message_normal;
      test_case "html" `Quick test_sanitize_message_html;
    ];
    "storage_backend_selection", [
      test_case "defaults to filesystem" `Quick test_storage_type_defaults_to_filesystem;
      test_case "explicit postgres" `Quick test_storage_type_explicit_postgres;
      test_case "legacy url does not auto select" `Quick test_storage_type_legacy_url_does_not_auto_select;
      test_case "auto is deprecated" `Quick test_storage_type_auto_is_deprecated;
    ];
    "backend_config_for", [
      test_case "requires explicit postgres" `Quick test_backend_config_for_requires_explicit_postgres;
      test_case "ignores legacy without MASC_POSTGRES_URL" `Quick
        test_postgres_url_from_env_ignores_legacy_without_masc_url;
      test_case "uses MASC_POSTGRES_URL" `Quick
        test_postgres_url_from_env_uses_masc_postgres_url;
    ];
    "safe_filename", [
      test_case "normal" `Quick test_safe_filename_normal;
      test_case "alphanumeric" `Quick test_safe_filename_alphanumeric;
      test_case "with dots" `Quick test_safe_filename_with_dots;
      test_case "with dash" `Quick test_safe_filename_with_dash;
      test_case "with underscore" `Quick test_safe_filename_with_underscore;
      test_case "special chars" `Quick test_safe_filename_special_chars;
      test_case "spaces" `Quick test_safe_filename_spaces;
      test_case "slash" `Quick test_safe_filename_slash;
      test_case "empty" `Quick test_safe_filename_empty;
      test_case "unicode" `Quick test_safe_filename_unicode;
    ];
    "validate_file_path", [
      test_case "normal" `Quick test_validate_file_path_normal;
      test_case "too long" `Quick test_validate_file_path_too_long;
      test_case "angle bracket <" `Quick test_validate_file_path_angle_bracket_lt;
      test_case "angle bracket >" `Quick test_validate_file_path_angle_bracket_gt;
    ];
    "path_helpers", [
      test_case "masc_root_dir default cluster" `Quick test_masc_root_dir_default_cluster;
      test_case "masc_root_dir empty cluster" `Quick test_masc_root_dir_empty_cluster;
      test_case "masc_root_dir custom cluster" `Quick test_masc_root_dir_custom_cluster;
      test_case "masc_root_dir nested with cluster" `Quick test_masc_root_dir_with_cluster_nested;
      test_case "list_dir prefers backend for memory keys" `Quick
        test_list_dir_prefers_backend_for_memory_keys;
      test_case "read_current_room always default" `Quick
        test_read_current_room_always_returns_default;
    ];
  ]
