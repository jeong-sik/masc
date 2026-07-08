(** Integration tests for tool_search_files read-side containment.

    RFC-0006 Phase B-1.5: extend the host-FS read guard from B-1
    (handle_tool_read_file) to tool_search_files read ops (ls/cat/rg/find/
    head/tail/wc/tree/git_status/git_log/git_diff). Docker keepers are
    always contained to their playground via the same containment
    module. *)

module Workspace = Masc.Workspace
module Keeper_tool_command_runtime = Masc.Keeper_tool_command_runtime
module Keeper_registry = Masc.Keeper_registry
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_sandbox_factory = Masc.Keeper_sandbox_factory
module Keeper_sandbox_repo_path = Masc.Keeper_sandbox_repo_path
module Keeper_tool_execute_path = Masc.Keeper_tool_execute_path
module Keeper_tool_filesystem_runtime = Masc.Keeper_tool_filesystem_runtime
module Keeper_types = Keeper_types
module Keeper_alerting_path = Masc.Keeper_alerting_path
module Keeper_tool_policy = Masc.Keeper_tool_policy
module AQ = Masc.Keeper_approval_queue
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util

open Repo_manager_types

(* ── Helpers ─────────────────────────────────────────────────────── *)

let with_env key value f =
  let prior = try Some (Sys.getenv key) with Not_found -> None in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let temp_dir () =
  let dir = Filename.temp_file "tool_search_files_containment_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let make_config () =
  let tmp = temp_dir () in
  ensure_dir (Filename.concat tmp Common.masc_dirname);
  (tmp, Workspace.default_config tmp)

let make_meta ~name ~sandbox =
  (* allowed_paths=["*"] mirrors the production minjae config that lets
     the resolver permit any path under project_root. The B-1.5
     containment fires AFTER the resolver but BEFORE I/O. *)
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "search files containment test");
        ("allowed_paths", `List [ `String "*" ]);
        ( "sandbox_profile",
          `String (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let setup ~keeper_name ~sandbox f =
  with_eio_fs @@ fun () ->
  let base, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_meta ~name:keeper_name ~sandbox in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  f ~base ~config ~meta ~playground

let parse_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_string_option

let parse_bool_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_bool_option

let json_field_present raw field =
  match Yojson.Safe.from_string raw |> Json.member field with
  | `Null -> false
  | _ -> true

let json_list_contains_string json field value =
  Yojson.Safe.from_string json
  |> Json.member field
  |> Json.to_list
  |> List.exists (fun item ->
    match item with
    | `String s -> String.equal s value
    | _ -> false)

let write_malformed_repositories ~base =
  let path = Filename.concat base ".masc/config/repositories.toml" in
  ensure_dir (Filename.dirname path);
  ignore (Fs_compat.save_file_atomic path "[repository.demo\n")

let write_executable path content =
  ignore (Fs_compat.save_file_atomic path content);
  Unix.chmod path 0o755

let normalize_realpath path =
  try Unix.realpath path with
  | _ -> path

let run_git_quiet argv =
  let devnull = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close devnull)
    (fun () ->
       try
         let pid = Unix.create_process "git" argv Unix.stdin devnull devnull in
         match Unix.waitpid [] pid with
         | _, Unix.WEXITED code -> code
         | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> 1
       with
       | Unix.Unix_error _ -> 1)

let git_available () = run_git_quiet [| "git"; "--version" |] = 0

let init_git_repo dir url =
  ensure_dir dir;
  Alcotest.(check int) "git init" 0 (run_git_quiet [| "git"; "init"; "-q"; dir |]);
  Alcotest.(check int)
    "git remote add"
    0
    (run_git_quiet [| "git"; "-C"; dir; "remote"; "add"; "origin"; url |]);
  Alcotest.(check int)
    "git origin HEAD"
    0
    (run_git_quiet
       [| "git"
        ; "-C"
        ; dir
        ; "symbolic-ref"
        ; "refs/remotes/origin/HEAD"
        ; "refs/remotes/origin/main"
       |])

let sample_repo ?base_path ?(aliases = []) id =
  let local_path =
    match base_path with
    | None -> Filename.concat ".masc/repos" id
    | Some base_path -> Filename.concat base_path (Filename.concat ".masc/repos" id)
  in
  { id
  ; name = id
  ; url = "https://github.com/jeong-sik/" ^ id ^ ".git"
  ; local_path
  ; aliases
  ; default_branch = "main"
  ; keepers = []
  ; status = Active
  ; auto_sync = false
  ; sync_interval = 0
  ; created_at = Int64.zero
  ; updated_at = Int64.zero
  }

let save_repositories base_path repos =
  match Repo_store.save_all ~base_path repos with
  | Ok () -> ()
  | Error detail -> Alcotest.fail ("save repositories failed: " ^ detail)

let test_shell_command_available_uses_path_without_shell () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Exec_tap.disable ();
      cleanup_dir dir)
    (fun () ->
       let tool_name = "probe;not-shell" in
       write_executable
         (Filename.concat dir tool_name)
         "#!/bin/sh\nexit 0\n";
       let captured = ref [] in
       Exec_tap.enable ~writer:(fun line -> captured := line :: !captured);
       with_env "PATH" dir @@ fun () ->
       Alcotest.(check bool)
         "probe found on PATH"
         true
         (Keeper_tool_execute_path.shell_command_available tool_name);
       Alcotest.(check int) "no process execution" 0 (List.length !captured))

let test_shell_command_available_rejects_empty_path_segment_cwd () =
  let dir = temp_dir () in
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir cwd;
      cleanup_dir dir)
    (fun () ->
       let tool_name = "cwd-only-probe" in
       write_executable
         (Filename.concat dir tool_name)
         "#!/bin/sh\nexit 0\n";
       Sys.chdir dir;
       with_env "PATH" (String.make 1 Executable_path.search_path_separator) @@ fun () ->
       Alcotest.(check bool)
         "empty PATH entry not cwd"
         false
         (Keeper_tool_execute_path.shell_command_available tool_name))

(* ── Tests ───────────────────────────────────────────────────────── *)

(* Outside-playground but inside-project-root path. The resolver allows
   it (project root scope); only the symmetric_sandbox containment check
   blocks it. This is exactly the leak vector minjae exploited. *)
let outside_in_root ~base name =
  let dir = Filename.concat base "outside_playground" in
  ensure_dir dir;
  let p = Filename.concat dir name in
  ignore (Fs_compat.save_file_atomic p (name ^ " content"));
  p

let blocked_by_symmetric_sandbox raw =
  match parse_field raw "error" with
  | None -> false
  | Some err ->
      let needle = "symmetric_sandbox_blocked" in
      let len = String.length needle in
      String.length err >= len && String.sub err 0 len = needle

(* Docker-keeper boundary enforcement landed in two phases:
   - B-1.5 (early): [symmetric_sandbox_blocked], emitted by
     [Keeper_sandbox_containment.check_read_target] AFTER the resolver
     allowed the host path through.
   - PR-3b (2026-04-28+): the resolver itself rejects out-of-sandbox
     reads with [path_outside_sandbox].
   - PR-3b follow-ups reject caller absolute paths even earlier with
     [path_outside_project_root].

   All three labels observably mean "Docker keeper read blocked by
   playground boundary".  Use this looser predicate for Docker-keeper
   tests so the semantic stays "is it blocked" instead of pinning to the
   1st-stage label.  Legacy [blocked_by_symmetric_sandbox] stays strict so
   [test_legacy_keeper_unaffected] continues to assert "this code path
   didn't fire" rather than the broader "blocked or not". *)
let blocked_by_sandbox_boundary raw =
  match parse_field raw "error" with
  | None -> false
  | Some err ->
      let starts_with prefix s =
        let pl = String.length prefix in
        String.length s >= pl && String.sub s 0 pl = prefix
      in
      starts_with "symmetric_sandbox_blocked" err
      || starts_with "path_outside_sandbox" err
      || starts_with "path_outside_project_root" err

let test_legacy_keeper_unaffected () =
  setup ~keeper_name:"alice" ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside = outside_in_root ~base "secret.txt" in
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String outside) ])
  in
  (* Strict predicate: this test specifically asserts the symmetric
     containment layer doesn't fire for Local keepers.  PR-3b's resolver
     tightening also blocks Local with [path_outside_sandbox], but that
     is the resolver layer, not the symmetric containment layer this
     test was written to characterise. *)
  Alcotest.(check bool) "legacy bypasses symmetric containment" false
    (blocked_by_symmetric_sandbox raw)

let test_docker_keeper_blocks_rg_outside () =
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside_dir = Filename.concat base "outside_playground" in
  ensure_dir outside_dir;
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat outside_dir "leak.txt")
       "secret-token");
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "rg");
            ("pattern", `String "secret");
            ("path", `String outside_dir);
          ])
  in
  Alcotest.(check bool) "rg outside playground blocked" true
    (blocked_by_sandbox_boundary raw)

let test_local_keeper_rg_file_path_uses_parent_workdir () =
  setup ~keeper_name:"garnet" ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~base:_ ~config ~meta ~playground ->
  if not (Keeper_tool_execute_path.shell_command_available "rg") then ()
  else (
    let file_path = Filename.concat playground "demo.ml" in
    ignore (Fs_compat.save_file_atomic file_path "let run_named = true\n");
    let raw =
      Keeper_tool_command_runtime.handle_tool_search_files
        ~turn_sandbox_factory:None
        ~exec_cache:None
        ~config
        ~meta
        ~args:
          (`Assoc
            [
              ("op", `String "rg");
              ("pattern", `String "run_named");
              ("path", `String "demo.ml");
            ])
    in
    (match parse_bool_field raw "ok" with
     | Some true -> ()
     | got -> Alcotest.failf "rg file path succeeds: got %s raw=%s"
                (Yojson.Safe.to_string (`List [ (match got with Some b -> `Bool b | None -> `Null) ]))
                raw);
    Alcotest.(check (option string)) "rg file path does not surface usage error"
      None
      (parse_field raw "error"))

(* Regression: a keeper that asks rg for an extension that is not a
   ripgrep type name (e.g. type="mli", a common ask in an OCaml repo)
   makes rg exit 2. Previously the rg result dropped stderr, so the
   keeper saw only the generic "usage_error / Wrong arguments" hint and
   retried the same broken argv until the circuit breaker tripped. The
   fix surfaces rg's own stderr in error_detail. This is a consumer-level
   (transport-aware) assertion: handle_tool_search_files is the function
   keeper_tool_runtime.ml returns verbatim to the keeper, so what we
   assert here is exactly what the keeper receives — no producer-only gap. *)
let test_local_keeper_rg_invalid_type_surfaces_stderr () =
  setup ~keeper_name:"garnet" ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~base:_ ~config ~meta ~playground ->
  if not (Keeper_tool_execute_path.shell_command_available "rg") then ()
  else (
    let file_path = Filename.concat playground "demo.ml" in
    ignore (Fs_compat.save_file_atomic file_path "let run_named = true\n");
    let raw =
      Keeper_tool_command_runtime.handle_tool_search_files
        ~turn_sandbox_factory:None
        ~exec_cache:None
        ~config
        ~meta
        ~args:
          (`Assoc
            [
              ("op", `String "rg");
              ("pattern", `String "run_named");
              ("path", `String "demo.ml");
              ("type", `String "mli");
            ])
    in
    Alcotest.(check (option bool)) "invalid rg type makes the call fail"
      (Some false)
      (parse_bool_field raw "ok");
    match parse_field raw "error_detail" with
    | None ->
        Alcotest.failf
          "error_detail absent: keeper cannot see why rg failed. raw=%s" raw
    | Some detail ->
        Alcotest.(check bool)
          "error_detail surfaces rg's real unrecognized-type stderr"
          true
          (String_util.contains_substring
             (String.lowercase_ascii detail)
             "unrecognized file type"))

let test_grep_unregistered_visible_repo_is_readable () =
  setup ~keeper_name:"base" ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~base ~config ~meta ~playground ->
  if not (Keeper_tool_execute_path.shell_command_available "rg")
  then ()
  else (
    save_repositories base
      [ sample_repo ~base_path:base "masc"; sample_repo ~base_path:base "oas" ];
    let repo_root = Filename.concat playground "repos/masc-mcp" in
    ensure_dir (Filename.concat repo_root ".git");
    ensure_dir (Filename.concat repo_root "lib");
    ignore
      (Fs_compat.save_file_atomic
         (Filename.concat repo_root "lib/demo.ml")
         "let visible_unregistered_repo = true\n");
    let raw =
      Keeper_tool_command_runtime.handle_tool_search_files
        ~turn_sandbox_factory:None
        ~exec_cache:None
        ~config
        ~meta
        ~args:
          (`Assoc
            [ "op", `String "rg"
            ; "pattern", `String "visible_unregistered_repo"
            ; "path", `String "repos/masc-mcp/lib"
            ])
    in
    Alcotest.(check (option bool))
      "unregistered visible repo path succeeds"
      (Some true)
      (parse_bool_field raw "ok");
    Alcotest.(check (option string))
      "unregistered visible repo is not policy blocked"
      None
      (parse_field raw "policy_error");
    Alcotest.(check (option string))
      "unregistered visible repo has no operator action"
      None
      (parse_field raw "operator_action_kind"))

let test_grep_registered_alias_repo_path_is_allowed () =
  setup ~keeper_name:"base" ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~base ~config ~meta ~playground ->
  if not (Keeper_tool_execute_path.shell_command_available "rg")
  then ()
  else (
    save_repositories
      base
      [ sample_repo ~aliases:[ "masc-mcp" ] "masc"; sample_repo "oas" ];
    let repo_root = Filename.concat playground "repos/masc-mcp" in
    ensure_dir (Filename.concat repo_root ".git");
    ensure_dir (Filename.concat repo_root "lib");
    ignore
      (Fs_compat.save_file_atomic
         (Filename.concat repo_root "lib/demo.ml")
         "let alias_registered_path = true\n");
    let raw =
      Keeper_tool_command_runtime.handle_tool_search_files
        ~turn_sandbox_factory:None
        ~exec_cache:None
        ~config
        ~meta
        ~args:
          (`Assoc
            [ "op", `String "rg"
            ; "pattern", `String "alias_registered_path"
            ; "path", `String "repos/masc-mcp/lib"
            ])
    in
    Alcotest.(check (option bool))
      "registered alias repo path succeeds"
      (Some true)
      (parse_bool_field raw "ok");
    Alcotest.(check (option string))
      "registered alias path is not policy blocked"
      None
      (parse_field raw "error"))

let test_grep_repo_catalog_load_error_is_not_empty_repo_hint () =
  setup ~keeper_name:"base" ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~base ~config ~meta ~playground ->
  write_malformed_repositories ~base;
  let repo_root = Filename.concat playground "repos/masc-mcp" in
  ensure_dir (Filename.concat repo_root ".git");
  ensure_dir (Filename.concat repo_root "lib");
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
          [ "op", `String "rg"
          ; "pattern", `String "Keeper_repo_mapping"
          ; "path", `String "repos/masc-mcp/lib"
          ])
  in
  Alcotest.(check (option bool))
    "catalog load error fails closed"
    (Some false)
    (parse_bool_field raw "ok");
  Alcotest.(check bool)
    "visible repo is still surfaced"
    true
    (json_list_contains_string raw "available_repos" "repos/masc-mcp");
  Alcotest.(check bool)
    "registered repo list is omitted when catalog is unreadable"
    false
    (json_field_present raw "registered_repos");
  (match parse_field raw "registered_repos_error" with
   | None -> Alcotest.failf "registered_repos_error absent: raw=%s" raw
   | Some msg ->
     Alcotest.(check bool)
       "registered repo load error is explicit"
       true
       (String.trim msg <> ""));
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool)
    "next action points at catalog repair"
    true
    (Json.member "path_resolution" json
     |> Json.member "next_action"
     |> Json.to_string_option
     |> Option.value ~default:""
     |> fun action -> String_util.contains_substring action "repositories.toml")

(* Validate that malformed ripgrep --type values are rejected without crossing
   the execution boundary. Regex/glob validity is owned by the actual rg
   invocation so Docker keepers do not depend on host rg availability. *)
let test_docker_keeper_invalid_type_rejects_before_docker_spawn () =
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground:_ ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "rg");
            ("pattern", `String "secret");
            ("path", `String ".");
            ("type", `String "ml;cat /etc/passwd");
          ])
  in
  match parse_field raw "error" with
  | None ->
    Alcotest.failf "expected error for invalid type; raw=%s" raw
  | Some err ->
    Alcotest.(check bool)
      "error explains invalid type"
      true
      (String_util.contains_substring err "invalid");
    Alcotest.(check bool)
      "docker image was not pulled"
      false
      (String_util.contains_substring err "docker image is not configured")
let test_docker_keeper_blocks_second_rg_outside () =
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside_dir = Filename.concat base "outside_playground" in
  ensure_dir outside_dir;
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat outside_dir "leak.txt")
       "secret-token");
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "rg");
            ("pattern", `String "secret");
            ("path", `String outside_dir);
          ])
  in
  Alcotest.(check bool) "second rg outside playground blocked" true
    (blocked_by_sandbox_boundary raw)

let test_docker_keeper_allows_inside_playground () =
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  let demo = Filename.concat playground "demo.txt" in
  ignore (Fs_compat.save_file_atomic demo "hello inside playground");
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String "demo.txt") ])
  in
  (* Goal: containment did not block. Whether `cat` succeeds depends on
     /bin/cat availability; we only assert the symmetric_sandbox guard
     is silent. *)
  Alcotest.(check bool) "playground-internal cat not blocked" false
    (blocked_by_sandbox_boundary raw)

let test_docker_relative_repos_path_resolves_inside_playground () =
  setup ~keeper_name:"glm-coding" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  let repos = Filename.concat playground "repos" in
  ensure_dir repos;
  let args = `Assoc [ ("op", `String "ls"); ("path", `String "repos") ] in
  match Keeper_tool_execute_path.resolve_tool_read_path ~config ~meta ~args with
  | Ok path ->
    Alcotest.(check string)
      "bare repos maps to playground repos"
      (normalize_realpath repos)
      (normalize_realpath path)
  | Error e ->
    Alcotest.fail ("bare repos should stay inside playground: " ^ e)

let test_docker_relative_repos_cwd_resolves_inside_playground () =
  setup ~keeper_name:"glm-coding" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  let repo = Filename.concat playground "repos/masc" in
  ensure_dir repo;
  let args = `Assoc [ ("cwd", `String "repos/masc") ] in
  match Keeper_tool_execute_path.resolve_tool_read_cwd ~config ~meta ~args with
  | Ok cwd ->
    Alcotest.(check string)
      "relative repos cwd maps to playground repo"
      (normalize_realpath repo)
      (normalize_realpath cwd)
  | Error e ->
    Alcotest.fail ("relative repos cwd should stay inside playground: " ^ e)

let test_docker_container_cwd_maps_to_host_worktree () =
  setup ~keeper_name:"executor" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  let host_worktree =
    Filename.concat playground "repos/masc/.worktrees/task-186"
  in
  ensure_dir host_worktree;
  let container_worktree =
    Filename.concat
      (Keeper_sandbox.container_root meta.name)
      "repos/masc/.worktrees/task-186"
  in
  let args = `Assoc [ ("cwd", `String container_worktree) ] in
  let expect = normalize_realpath host_worktree in
  (match Keeper_tool_execute_path.resolve_tool_read_cwd ~config ~meta ~args with
   | Ok cwd ->
     Alcotest.(check string) "read cwd maps to host" expect
       (normalize_realpath cwd)
  | Error e -> Alcotest.fail ("read cwd should map container path: " ^ e));
  match
    Keeper_tool_execute_path.resolve_tool_execute_cwd
      ~config
      ~meta
      ~write_enabled:true
      ~args
  with
  | Ok cwd ->
    Alcotest.(check string) "write cwd maps to host" expect
      (normalize_realpath cwd)
  | Error e -> Alcotest.fail ("write cwd should map container path: " ^ e)

let test_readonly_execute_omitted_cwd_does_not_create_playground () =
  with_eio_fs @@ fun () ->
  let base, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_meta ~name:"readonly-executor" ~sandbox:Keeper_types_profile_sandbox.Docker in
  let playground = Keeper_sandbox_repo_path.playground_root_no_create ~config ~meta in
  Alcotest.(check bool) "playground starts absent" false (Sys.file_exists playground);
  let args = `Assoc [] in
  (match
     Keeper_tool_execute_path.resolve_tool_execute_cwd
       ~write_enabled:false
       ~config
       ~meta
       ~args
   with
   | Ok cwd ->
     Alcotest.failf "read-only omitted cwd should not create playground: %s" cwd
   | Error e ->
     Alcotest.(check bool)
       "read-only omitted cwd reports missing directory"
       true
       (String_util.contains_substring e "cwd_not_directory"));
  Alcotest.(check bool) "playground remains absent" false (Sys.file_exists playground)

let test_docker_container_file_path_maps_to_host_worktree () =
  setup ~keeper_name:"executor" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  let host_file =
    Filename.concat playground
      "repos/masc/.worktrees/task-186/lib/keeper/keeper_tool_policy.ml"
  in
  ensure_dir (Filename.dirname host_file);
  ignore (Fs_compat.save_file_atomic host_file "let touched = true\n");
  let container_file =
    Filename.concat
      (Keeper_sandbox.container_root meta.name)
      "repos/masc/.worktrees/task-186/lib/keeper/keeper_tool_policy.ml"
  in
  let args =
    `Assoc [ ("op", `String "head"); ("path", `String container_file) ]
  in
  match Keeper_tool_execute_path.resolve_tool_read_path ~config ~meta ~args with
  | Ok path ->
    Alcotest.(check string) "file path maps to host"
      (normalize_realpath host_file) (normalize_realpath path)
  | Error e -> Alcotest.fail ("file path should map container path: " ^ e)

let test_docker_other_container_root_stays_blocked () =
  setup ~keeper_name:"executor" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground:_ ->
  let other_container_cwd =
    Filename.concat
      (Keeper_sandbox.container_root "analyst")
      "repos/masc"
  in
  let args = `Assoc [ ("cwd", `String other_container_cwd) ] in
  match Keeper_tool_execute_path.resolve_tool_read_cwd ~config ~meta ~args with
  | Ok cwd -> Alcotest.fail ("other keeper container cwd should be blocked: " ^ cwd)
  | Error e ->
    Alcotest.(check bool) "outside project root" true
      (String_util.contains_substring e "path_outside_project_root")

let test_readonly_execute_omitted_cwd_does_not_create_write_root () =
  setup ~keeper_name:"readonly-exec" ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~base:_ ~config ~meta ~playground ->
  cleanup_dir playground;
  let args = `Assoc [] in
  match
    Keeper_tool_execute_path.resolve_tool_execute_cwd
      ~config
      ~meta
      ~write_enabled:false
      ~args
  with
  | Ok cwd -> Alcotest.fail ("read-only execute should not create cwd: " ^ cwd)
  | Error e ->
    Alcotest.(check bool)
      "missing cwd reported"
      true
      (String_util.contains_substring e "cwd_not_directory");
    Alcotest.(check bool)
      "read-only execute did not create write root"
      false
      (Sys.file_exists playground)

let test_rg_unregistered_clone_does_not_queue_repository_hitl () =
  if
    (not (git_available ()))
    || not (Keeper_tool_execute_path.shell_command_available "rg")
  then ()
  else (
    AQ.For_testing.reset_audit_store ();
    Fun.protect ~finally:AQ.For_testing.reset_audit_store @@ fun () ->
    setup ~keeper_name:"analyst" ~sandbox:Keeper_types_profile_sandbox.Local
    @@ fun ~base ~config ~meta ~playground ->
    let registered = sample_repo ~base_path:base "masc" in
    save_repositories base [ registered ];
    let repo_root = Filename.concat playground "repos/masc-mcp" in
    init_git_repo repo_root registered.url;
    let raw =
      Keeper_tool_command_runtime.handle_tool_search_files
        ~turn_sandbox_factory:None
        ~exec_cache:None
        ~config
        ~meta
        ~args:
          (`Assoc
            [ "op", `String "rg"
            ; "pattern", `String "Repository"
            ; "path", `String "repos/masc-mcp"
            ])
    in
    Alcotest.(check (option bool))
      "unregistered visible clone grep succeeds"
      (Some true)
      (parse_bool_field raw "ok");
    let entries =
      AQ.list_pending_entries ()
      |> List.filter (fun (entry : AQ.pending_approval) ->
        String.equal entry.keeper_name meta.name)
    in
    Alcotest.(check int)
      "read-side repo access does not queue repository HITL"
      0
      (List.length entries))

let test_read_unregistered_clone_does_not_surface_repository_hitl () =
  if not (git_available ()) then ()
  else (
    AQ.For_testing.reset_audit_store ();
    Fun.protect ~finally:AQ.For_testing.reset_audit_store @@ fun () ->
    setup ~keeper_name:"reader" ~sandbox:Keeper_types_profile_sandbox.Local
    @@ fun ~base ~config ~meta ~playground ->
    ignore (Keeper_registry.register ~base_path:base meta.name meta);
    let registered = sample_repo ~base_path:base "masc" in
    save_repositories base [ registered ];
    let repo_root = Filename.concat playground "repos/masc-mcp" in
    init_git_repo repo_root registered.url;
    ignore (Fs_compat.save_file_atomic (Filename.concat repo_root "README.md") "Repository\n");
    let raw =
      Keeper_tool_filesystem_runtime.handle_read_file
        ~turn_sandbox_factory:None
        ~config
        ~keeper_name:meta.name
        ~args:
          (`Assoc
            [ "path", `String "repos/masc-mcp/README.md"; "max_bytes", `Int 4096 ])
    in
    Alcotest.(check (option bool))
      "unregistered visible clone read succeeds"
      (Some true)
      (parse_bool_field raw "ok");
    let entries =
      AQ.list_pending_entries ()
      |> List.filter (fun (entry : AQ.pending_approval) ->
        String.equal entry.keeper_name meta.name)
    in
    Alcotest.(check int)
      "read-side file access does not queue repository HITL"
      0
      (List.length entries))


let () =
  Alcotest.run "Keeper_tool_search_files_containment"
    [
      ( "containment",
        [
          Alcotest.test_case "shell command probe uses PATH without shell"
            `Quick test_shell_command_available_uses_path_without_shell;
          Alcotest.test_case "shell command probe skips empty PATH cwd"
            `Quick test_shell_command_available_rejects_empty_path_segment_cwd;
          Alcotest.test_case "legacy keeper unaffected" `Quick
            test_legacy_keeper_unaffected;
          Alcotest.test_case "docker keeper blocks rg outside" `Quick
            test_docker_keeper_blocks_rg_outside;
          Alcotest.test_case "local keeper rg file path uses parent workdir"
            `Quick test_local_keeper_rg_file_path_uses_parent_workdir;
          Alcotest.test_case
            "local keeper rg invalid type surfaces stderr to keeper"
            `Quick test_local_keeper_rg_invalid_type_surfaces_stderr;
          Alcotest.test_case
            "Grep unregistered visible repo is readable"
            `Quick
            test_grep_unregistered_visible_repo_is_readable;
          Alcotest.test_case
            "Grep registered alias repo path is allowed"
            `Quick
            test_grep_registered_alias_repo_path_is_allowed;
          Alcotest.test_case
            "Grep repo catalog load error is not empty repo hint"
            `Quick
            test_grep_repo_catalog_load_error_is_not_empty_repo_hint;
          Alcotest.test_case "docker keeper invalid type rejects before docker spawn"
            `Quick test_docker_keeper_invalid_type_rejects_before_docker_spawn;
          Alcotest.test_case "docker keeper blocks second rg outside" `Quick
            test_docker_keeper_blocks_second_rg_outside;
          Alcotest.test_case "docker keeper allows inside playground"
            `Quick test_docker_keeper_allows_inside_playground;
          Alcotest.test_case "docker relative repos path resolves inside playground"
            `Quick test_docker_relative_repos_path_resolves_inside_playground;
          Alcotest.test_case "docker relative repos cwd resolves inside playground"
            `Quick test_docker_relative_repos_cwd_resolves_inside_playground;
          Alcotest.test_case "docker container cwd maps to host worktree"
            `Quick test_docker_container_cwd_maps_to_host_worktree;
          Alcotest.test_case
            "read-only omitted cwd does not create playground"
            `Quick test_readonly_execute_omitted_cwd_does_not_create_playground;
          Alcotest.test_case "docker container file path maps to host worktree"
            `Quick test_docker_container_file_path_maps_to_host_worktree;
          Alcotest.test_case "docker other container root stays blocked"
            `Quick test_docker_other_container_root_stays_blocked;
          Alcotest.test_case
            "read-only Execute omitted cwd does not create write root"
            `Quick
            test_readonly_execute_omitted_cwd_does_not_create_write_root;
          Alcotest.test_case
            "rg unregistered clone does not queue repository HITL"
            `Quick
            test_rg_unregistered_clone_does_not_queue_repository_hitl;
          Alcotest.test_case
            "Read unregistered clone does not surface repository HITL"
            `Quick
            test_read_unregistered_clone_does_not_surface_repository_hitl;
        ] );
    ]
