(** Integration tests for tool_search_files read-side containment.

    RFC-0006 Phase B-1.5: extend the host-FS read guard from B-1
    (handle_tool_read_file) to tool_search_files read ops (ls/cat/rg/find/
    head/tail/wc/tree/git_status/git_log/git_diff). Docker keepers are
    always contained to their playground via the same containment
    module. *)

module Workspace = Masc.Workspace
module Keeper_workspace_ops = Masc.Keeper_workspace_ops
module Keeper_registry = Masc.Keeper_registry
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_sandbox_factory = Masc.Keeper_sandbox_factory
module Keeper_sandbox_repo_path = Masc.Keeper_sandbox_repo_path
module Keeper_tool_execute_path = Masc.Keeper_tool_execute_path
module Keeper_tool_filesystem_runtime = Masc.Keeper_tool_filesystem_runtime
module Keeper_tool_shared_runtime = Masc.Keeper_tool_shared_runtime
module Keeper_types = Keeper_types
module Keeper_alerting_path = Masc.Keeper_alerting_path
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util

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
  (* The resolver permits any path under project_root; the B-1.5 sandbox
     containment fires AFTER the resolver but BEFORE I/O. *)
  let json =
    `Assoc
      [
        ("name", `String name);
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    { meta with Masc.Keeper_meta_contract.sandbox_profile = sandbox }
  | Error e -> Alcotest.fail e

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let setup ~keeper_name ~sandbox f =
  with_eio_fs @@ fun () ->
  let base, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.For_testing.clear ();
  Masc_test_deps.write_sandbox_image_catalog ~base_path:base
    [ "base", Masc_test_deps.live_sandbox_image_tag ];

  let meta =
    { (make_meta ~name:keeper_name ~sandbox) with
      Masc.Keeper_meta_contract.sandbox_image = Some "base" }
  in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  f ~base ~config ~meta ~playground

let parse_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_string_option

let parse_bool_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_bool_option

let normalize_realpath path =
  try Unix.realpath path with
  | _ -> path

(* ── Tests ───────────────────────────────────────────────────────── *)

let blocked_by_sandbox_boundary raw =
  match parse_field raw "error" with
  | None -> false
  | Some err ->
      let starts_with prefix s =
        let pl = String.length prefix in
        String.length s >= pl && String.sub s 0 pl = prefix
      in
      starts_with "path_outside_sandbox" err

let test_docker_keeper_blocks_rg_outside () =
  setup ~keeper_name:"acme-sandbox" ~sandbox:Keeper_types_profile_sandbox.Docker
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
    Keeper_workspace_ops.handle_tool_search_files
      ~turn_sandbox_factory:(Some factory)
      ~config ~meta
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

let test_docker_keeper_rg_file_path_uses_parent_workdir () =
  setup ~keeper_name:"garnet" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  (
    let file_path = Filename.concat playground "demo.ml" in
    ignore (Fs_compat.save_file_atomic file_path "let run_named = true\n");
    let raw =
      Keeper_workspace_ops.handle_tool_search_files
        ~turn_sandbox_factory:None
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
   keeper saw only the generic "usage_error / Wrong arguments" hint. The
   fix surfaces rg's own stderr in error_detail. This is a consumer-level
   (transport-aware) assertion: handle_tool_search_files is the function
   keeper_tool_runtime.ml returns verbatim to the keeper, so what we
   assert here is exactly what the keeper receives — no producer-only gap. *)
let test_docker_keeper_rg_invalid_type_surfaces_stderr () =
  setup ~keeper_name:"garnet" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  (
    let file_path = Filename.concat playground "demo.ml" in
    ignore (Fs_compat.save_file_atomic file_path "let run_named = true\n");
    let execution =
      Keeper_workspace_ops.handle_tool_search_files_with_outcome
        ~turn_sandbox_factory:None
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
    let raw = execution.raw_output in
    (match execution.disposition with
     | Tool_result.Failed Tool_result.Policy_rejection -> ()
     | _ -> Alcotest.failf "unknown rg type should be caller-correctable: %s" raw);
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

(* Validate that malformed ripgrep --type values are rejected without crossing
   the execution boundary. Regex/glob validity is owned by the actual rg
   invocation so Docker keepers do not depend on host rg availability. *)
let test_docker_keeper_invalid_type_rejects_before_docker_spawn () =
  setup ~keeper_name:"acme-sandbox" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground:_ ->
  let raw =
    Keeper_workspace_ops.handle_tool_search_files
      ~turn_sandbox_factory:None
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
      "sandbox image was never resolved (this keeper has none set)"
      false
      (String_util.contains_substring err "sandbox_image")
let test_docker_keeper_blocks_second_rg_outside () =
  setup ~keeper_name:"acme-sandbox" ~sandbox:Keeper_types_profile_sandbox.Docker
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
    Keeper_workspace_ops.handle_tool_search_files
      ~turn_sandbox_factory:(Some factory)
      ~config ~meta
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
  setup ~keeper_name:"acme-sandbox" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  let demo = Filename.concat playground "demo.txt" in
  ignore (Fs_compat.save_file_atomic demo "hello inside playground");
  let raw =
    Keeper_workspace_ops.handle_tool_search_files ~turn_sandbox_factory:None ~config ~meta
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
    Alcotest.fail ("bare repos should stay inside playground: " ^ e.Keeper_alerting_path.message)

(* #29964: one spelling of a path names one host location, whichever tool
   receives it. The search cwd used to join a relative cwd to the project
   root and refuse it as outside the sandbox, and refused the container path
   Execute hands back, while Read and Execute resolved both into the
   playground. *)
let read_cwd ~config ~meta cwd =
  Keeper_tool_filesystem_runtime.resolve_read_file_cwd ~config ~meta ~cwd:(Some cwd)

let search_cwd ~config ~meta cwd =
  Keeper_tool_execute_path.resolve_tool_read_cwd
    ~config ~meta ~args:(`Assoc [ ("cwd", `String cwd) ])

let execute_cwd ~config ~meta cwd =
  Keeper_tool_execute_path.resolve_tool_execute_cwd_typed
    ~remote_workspace_root:None ~config ~meta ~write_enabled:true
    ~args:(`Assoc [ ("cwd", `String cwd) ])

let test_one_cwd_spelling_names_one_directory_for_every_tool () =
  setup ~keeper_name:"glm-coding" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  let repo = Filename.concat playground "repos/masc" in
  let lib = Filename.concat repo "lib" in
  ensure_dir lib;
  let container = Keeper_sandbox.container_root meta.name in
  List.iter
    (fun (spelling, expected) ->
       let expected = normalize_realpath expected in
       let same tool = function
         | Ok cwd ->
           Alcotest.(check string)
             (Printf.sprintf "%s cwd %S" tool spelling)
             expected
             (normalize_realpath cwd)
         | Error detail ->
           Alcotest.failf "%s refused cwd %S: %s" tool spelling detail
       in
       let message = Result.map_error (fun e -> e.Keeper_alerting_path.message) in
       same "Read" (message (read_cwd ~config ~meta spelling));
       same "Grep" (message (search_cwd ~config ~meta spelling));
       same "Execute"
         (Result.map_error
            Keeper_tool_execute_path.execute_cwd_resolution_error_private_message
            (execute_cwd ~config ~meta spelling)))
    [ "repos/masc", repo
    ; ".", playground
    ; "repos/masc/lib", lib
    ; " repos/masc ", repo
    ; repo, repo
    ; Filename.concat container "repos/masc", repo
    ; container, playground
    ]

let test_one_cwd_spelling_is_refused_by_every_tool () =
  setup ~keeper_name:"omega" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside = Filename.concat base "outside-playground" in
  ensure_dir outside;
  List.iter
    (fun spelling ->
       let refused tool = function
         | Ok cwd -> Alcotest.failf "%s admitted cwd %S as %s" tool spelling cwd
         | Error (e : Keeper_alerting_path.path_refusal) ->
           Alcotest.(check bool)
             (Printf.sprintf "%s names %S as outside the sandbox: %s" tool spelling e.message)
             true
             (String.starts_with ~prefix:"path_outside_sandbox" e.message);
           Alcotest.(check bool)
             (Printf.sprintf "%s leaves %S to the caller" tool spelling)
             true
             (e.failure_class = Tool_result.Policy_rejection)
       in
       refused "Read" (read_cwd ~config ~meta spelling);
       refused "Grep" (search_cwd ~config ~meta spelling);
       match execute_cwd ~config ~meta spelling with
       | Ok cwd -> Alcotest.failf "Execute admitted cwd %S as %s" spelling cwd
       | Error error ->
         Alcotest.(check string)
           (Printf.sprintf "Execute names %S as outside the sandbox" spelling)
           "cwd_outside_sandbox"
           (Keeper_tool_execute_path.execute_cwd_resolution_error_code error);
         Alcotest.(check bool)
           (Printf.sprintf "Execute leaves %S to the caller" spelling)
           true
           (Keeper_tool_execute_path.execute_cwd_resolution_error_class error
            = Tool_result.Policy_rejection))
    [ "../outside-playground"
    ; outside
    ; Filename.concat (Keeper_sandbox.container_root "delta") "repos/masc"
    ]

(* The same holds for a file: the search path, the write path and the read
   path of one spelling are one host file, with and without a cwd. *)
let test_one_file_spelling_names_one_file_for_every_tool () =
  setup ~keeper_name:"omega" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  let repo = Filename.concat playground "repos/masc" in
  let file = Filename.concat repo "lib/a.ml" in
  ensure_dir (Filename.dirname file);
  ignore (Fs_compat.save_file_atomic file "let a = 1\n");
  let container = Keeper_sandbox.container_root meta.name in
  let expected = normalize_realpath file in
  let same label = function
    | Ok path -> Alcotest.(check string) label expected (normalize_realpath path)
    | Error (e : Keeper_alerting_path.path_refusal) ->
      Alcotest.failf "%s refused: %s" label e.message
  in
  List.iter
    (fun spelling ->
       same
         (Printf.sprintf "Grep path %S" spelling)
         (Keeper_tool_execute_path.resolve_tool_read_path
            ~config ~meta ~args:(`Assoc [ ("path", `String spelling) ]));
       same
         (Printf.sprintf "read path %S" spelling)
         (Keeper_tool_shared_runtime.resolve_keeper_read_path
            ~config ~meta ~raw_path:spelling);
       same
         (Printf.sprintf "write path %S" spelling)
         (Keeper_tool_shared_runtime.resolve_keeper_confined_write_path
            ~config ~meta ~endpoint:Keeper_alerting_path.Lexical_entry
            ~raw_path:spelling
          |> Result.map Keeper_alerting_path.confined_host_path))
    [ "repos/masc/lib/a.ml"; file; Filename.concat container "repos/masc/lib/a.ml" ];
  List.iter
    (fun (cwd, path) ->
       same
         (Printf.sprintf "Grep cwd %S path %S" cwd path)
         (Keeper_tool_execute_path.resolve_tool_read_path
            ~config ~meta
            ~args:(`Assoc [ ("cwd", `String cwd); ("path", `String path) ]));
       match read_cwd ~config ~meta cwd with
       | Error e -> Alcotest.failf "Read refused cwd %S: %s" cwd e.message
       | Ok host_cwd ->
         same
           (Printf.sprintf "Read cwd %S path %S" cwd path)
           (Keeper_tool_shared_runtime.resolve_keeper_read_path_in_cwd
              ~config ~meta ~host_cwd ~raw_path:path))
    [ "repos/masc", "lib/a.ml"
    ; Filename.concat container "repos/masc", "lib/a.ml"
    ; "repos/masc", Filename.concat container "repos/masc/lib/a.ml"
    ; "repos/masc", file
    ]

let test_execute_own_container_cwd_preserves_containment () =
  setup ~keeper_name:"omega" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base ~config ~meta ~playground ->
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
  (* Execute accepts the exact cwd a previous guest call returned, and so
     does the search cwd (#29964). *)
  (match Keeper_tool_execute_path.resolve_tool_read_cwd ~config ~meta ~args with
   | Ok cwd ->
     Alcotest.(check string) "own guest cwd maps to the same host directory for search"
       (normalize_realpath host_worktree) (normalize_realpath cwd)
   | Error error ->
     Alcotest.fail ("own guest search cwd rejected: " ^ error.Keeper_alerting_path.message));
  List.iter
    (fun write_enabled ->
      match Keeper_tool_execute_path.resolve_tool_execute_cwd ~remote_workspace_root:None
        ~config ~meta ~write_enabled ~args with
      | Ok cwd ->
        Alcotest.(check string) "own guest cwd maps to the admitted host directory"
          (normalize_realpath host_worktree) (normalize_realpath cwd)
      | Error error -> Alcotest.fail ("own guest cwd rejected: " ^ error))
    [false; true];
  let outside = Filename.concat base "outside-playground" in
  ensure_dir outside;
  Unix.symlink outside (Filename.concat host_worktree "escape");
  let args = `Assoc ["cwd", `String (Filename.concat container_worktree "escape")] in
  (match Keeper_tool_execute_path.resolve_tool_read_cwd ~config ~meta ~args with
   | Ok cwd -> Alcotest.fail ("own guest search alias followed an escaping symlink: " ^ cwd)
   | Error error ->
     Alcotest.(check bool) "search alias still enforces the canonical boundary" true
       (String.starts_with ~prefix:"path_outside_sandbox" error.Keeper_alerting_path.message));
  List.iter
    (fun write_enabled ->
      match Keeper_tool_execute_path.resolve_tool_execute_cwd_typed ~remote_workspace_root:None
        ~config ~meta ~write_enabled ~args with
      | Ok cwd -> Alcotest.fail ("own guest alias followed an escaping symlink: " ^ cwd)
      | Error error ->
        Alcotest.(check string) "guest alias still enforces the canonical boundary"
          "cwd_outside_sandbox"
          (Keeper_tool_execute_path.execute_cwd_resolution_error_code error))
    [false; true]

let test_readonly_execute_omitted_cwd_does_not_create_playground () =
  with_eio_fs @@ fun () ->
  let base, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.For_testing.clear ();
  let meta = make_meta ~name:"readonly-executor" ~sandbox:Keeper_types_profile_sandbox.Docker in
  let playground = Keeper_sandbox_repo_path.playground_root_no_create ~config ~meta in
  Alcotest.(check bool) "playground starts absent" false (Sys.file_exists playground);
  let args = `Assoc [] in
  (match
     Keeper_tool_execute_path.resolve_tool_execute_cwd ~remote_workspace_root:None
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

let test_container_file_path_names_the_host_file () =
  setup ~keeper_name:"omega" ~sandbox:Keeper_types_profile_sandbox.Docker
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
    Alcotest.(check string)
      "own guest file path maps to the host file"
      (normalize_realpath host_file)
      (normalize_realpath path)
  | Error error ->
    Alcotest.fail ("own guest file path rejected: " ^ error.Keeper_alerting_path.message)

let test_docker_other_container_root_stays_blocked () =
  setup ~keeper_name:"omega" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground:_ ->
  let other_container_cwd =
    Filename.concat
      (Keeper_sandbox.container_root "delta")
      "repos/masc"
  in
  let args = `Assoc [ ("cwd", `String other_container_cwd) ] in
  (match Keeper_tool_execute_path.resolve_tool_read_cwd ~config ~meta ~args with
  | Ok cwd -> Alcotest.fail ("other keeper container cwd should be blocked: " ^ cwd)
  | Error e ->
    Alcotest.(check bool) "outside allowed roots" true
      (String_util.contains_substring e.Keeper_alerting_path.message "path_outside_sandbox"));
  List.iter
    (fun write_enabled ->
      match Keeper_tool_execute_path.resolve_tool_execute_cwd_typed ~remote_workspace_root:None
        ~config ~meta ~write_enabled ~args with
      | Ok cwd -> Alcotest.fail ("foreign guest cwd was admitted: " ^ cwd)
      | Error error ->
        Alcotest.(check string) "foreign guest root remains outside the sandbox"
          "cwd_outside_sandbox"
          (Keeper_tool_execute_path.execute_cwd_resolution_error_code error))
    [false; true]

(* A remote_ssh keeper's tree is on the endpoint, so its omitted cwd resolves
   to the root in host form without the host being asked whether that
   directory exists, and without creating it (RFC-0427 A-1). *)
let test_readonly_execute_omitted_cwd_does_not_create_write_root () =
  setup ~keeper_name:"readonly-exec" ~sandbox:Keeper_types_profile_sandbox.Remote_ssh
  @@ fun ~base:_ ~config ~meta ~playground ->
  cleanup_dir playground;
  let args = `Assoc [] in
  match
    Keeper_tool_execute_path.resolve_tool_execute_cwd ~remote_workspace_root:(Some "/srv/fixture/readonly-exec")
      ~config
      ~meta
      ~write_enabled:false
      ~args
  with
  | Error e -> Alcotest.fail ("an endpoint-owned tree's root was refused on the host: " ^ e)
  | Ok cwd ->
    Alcotest.(check string) "the root in host form" playground cwd;
    Alcotest.(check bool)
      "read-only execute did not create write root"
      false
      (Sys.file_exists playground)

(* The polisher case of 2026-09-05: a microvm keeper names a worktree that
   exists only in its guest volume. The host has no such directory (its
   playground holds the bookkeeping bundle), and that used to be refused 38
   times a day as cwd_not_directory. The resolver now returns the confined
   host-form path for the remote lane to map, and a docker keeper -- whose
   tree really is this host's -- still hears that the directory is missing. *)
let test_a_guest_only_cwd_is_the_endpoints_to_check () =
  (setup ~keeper_name:"polisher" ~sandbox:Keeper_types_profile_sandbox.Micro_vm
   @@ fun ~base:_ ~config ~meta ~playground ->
   let guest_only = Filename.concat playground "masc-t1348" in
   Alcotest.(check bool) "absent on the host" false (Sys.file_exists guest_only);
   let args = `Assoc [ ("cwd", `String "masc-t1348") ] in
   match
     Keeper_tool_execute_path.resolve_tool_execute_cwd ~remote_workspace_root:None ~config ~meta ~write_enabled:true ~args
   with
   | Error e -> Alcotest.fail ("guest-only cwd refused on the host: " ^ e)
   | Ok cwd ->
     Alcotest.(check string) "host-form path for the remote lane" guest_only cwd;
     Alcotest.(check bool) "nothing was created" false (Sys.file_exists guest_only));
  setup ~keeper_name:"omega" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground:_ ->
  let args = `Assoc [ ("cwd", `String "masc-t1348") ] in
  match
    Keeper_tool_execute_path.resolve_tool_execute_cwd ~remote_workspace_root:None ~config ~meta ~write_enabled:true ~args
  with
  | Ok cwd -> Alcotest.fail ("a shared-mount tree's missing cwd resolved: " ^ cwd)
  | Error e ->
    Alcotest.(check bool) "the host still answers for its own tree" true
      (String_util.contains_substring e "cwd_not_directory")


(* The rule Execute follows, asked directly. The host answers for a tree it
   holds; for a tree the endpoint owns it is not asked at all, whatever the
   host happens to have at that path. *)
let test_cwd_existence_asks_whoever_holds_the_tree () =
  setup ~keeper_name:"omega" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config:_ ~meta ~playground ->
  let file = Filename.concat playground "notes.txt" in
  ignore (Fs_compat.save_file_atomic file "notes\n");
  let missing = Filename.concat playground "masc" in
  let check label meta path expected =
    Alcotest.(check bool) label true
      (Keeper_tool_shared_runtime.cwd_existence ~meta path = expected)
  in
  check "docker: a directory" meta playground Keeper_tool_shared_runtime.Host_directory;
  check "docker: a file" meta file Keeper_tool_shared_runtime.Host_file;
  check "docker: missing" meta missing Keeper_tool_shared_runtime.Host_missing;
  List.iter
    (fun (label, profile) ->
       let meta = { meta with Masc.Keeper_meta_contract.sandbox_profile = profile } in
       List.iter
         (fun path ->
            check (label ^ ": the endpoint decides") meta path
              Keeper_tool_shared_runtime.Endpoint_decides)
         [ playground; file; missing ])
    [ "microvm", Keeper_types_profile_sandbox.Micro_vm
    ; "remote_ssh", Keeper_types_profile_sandbox.Remote_ssh
    ]

(* Read and the search tools checked their cwd on the host whatever the
   profile. A microvm keeper's Read with cwd="masc" was refused 101 times in
   the week to 2026-09-24, told that "no repository is materialized" -- the
   host playground scan answering for a checkout that existed in the guest.
   A docker keeper, whose tree is this host's, still hears the checkouts
   that exist. *)
let test_read_cwds_follow_the_tree () =
  let search_cwd playground =
    `Assoc [ ("cwd", `String (Filename.concat playground "masc")) ]
  in
  (setup ~keeper_name:"glossary-maniac" ~sandbox:Keeper_types_profile_sandbox.Micro_vm
   @@ fun ~base:_ ~config ~meta ~playground ->
   let guest_only = Filename.concat playground "masc" in
   let names_the_guest_checkout label cwd =
     Alcotest.(check bool) label true
       (String.ends_with ~suffix:(Filename.concat "glossary-maniac" "masc") cwd)
   in
   (match Keeper_tool_filesystem_runtime.resolve_read_file_cwd ~config ~meta ~cwd:(Some "masc") with
    | Error e ->
      Alcotest.fail
        ("Read refused a guest-only cwd on the host: " ^ e.Keeper_alerting_path.message)
    | Ok cwd -> names_the_guest_checkout "Read keeps the path for the endpoint" cwd);
   (match
      Keeper_tool_execute_path.resolve_tool_read_cwd ~config ~meta ~args:(search_cwd playground)
    with
    | Error e ->
      Alcotest.fail
        ("search refused a guest-only cwd on the host: " ^ e.Keeper_alerting_path.message)
    | Ok cwd -> names_the_guest_checkout "search keeps the path for the endpoint" cwd);
   Alcotest.(check bool) "nothing was created" false (Sys.file_exists guest_only));
  setup ~keeper_name:"omega" ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  (match Keeper_tool_filesystem_runtime.resolve_read_file_cwd ~config ~meta ~cwd:(Some "masc") with
   | Ok cwd -> Alcotest.fail ("a shared-mount tree's missing Read cwd resolved: " ^ cwd)
   | Error e ->
     Alcotest.(check bool) "Read still says nothing is materialized" true
       (String_util.contains_substring
          e.Keeper_alerting_path.message
          "no repository is materialized");
     Alcotest.(check bool) "the caller named the missing cwd" true
       (e.Keeper_alerting_path.failure_class = Tool_result.Policy_rejection));
  match
    Keeper_tool_execute_path.resolve_tool_read_cwd ~config ~meta ~args:(search_cwd playground)
  with
  | Ok cwd -> Alcotest.fail ("a shared-mount tree's missing search cwd resolved: " ^ cwd)
  | Error e ->
    Alcotest.(check bool) "search still hears the directory is missing" true
      (String_util.contains_substring e.Keeper_alerting_path.message "cwd_not_directory");
    Alcotest.(check bool) "the caller named the missing search cwd" true
      (e.Keeper_alerting_path.failure_class = Tool_result.Policy_rejection)

let () =
  Alcotest.run "Keeper_tool_search_files_containment"
    [
      ( "containment",
        [
          Alcotest.test_case "docker keeper blocks rg outside" `Quick
            test_docker_keeper_blocks_rg_outside;
          Alcotest.test_case "docker keeper rg file path uses parent workdir"
            `Quick test_docker_keeper_rg_file_path_uses_parent_workdir;
          Alcotest.test_case
            "docker keeper rg invalid type surfaces stderr to keeper"
            `Quick test_docker_keeper_rg_invalid_type_surfaces_stderr;
          Alcotest.test_case "docker keeper invalid type rejects before docker spawn"
            `Quick test_docker_keeper_invalid_type_rejects_before_docker_spawn;
          Alcotest.test_case "docker keeper blocks second rg outside" `Quick
            test_docker_keeper_blocks_second_rg_outside;
          Alcotest.test_case "docker keeper allows inside playground"
            `Quick test_docker_keeper_allows_inside_playground;
          Alcotest.test_case "docker relative repos path resolves inside playground"
            `Quick test_docker_relative_repos_path_resolves_inside_playground;
          Alcotest.test_case "one cwd spelling names one directory for every tool"
            `Quick test_one_cwd_spelling_names_one_directory_for_every_tool;
          Alcotest.test_case "one cwd spelling is refused by every tool"
            `Quick test_one_cwd_spelling_is_refused_by_every_tool;
          Alcotest.test_case "one file spelling names one file for every tool"
            `Quick test_one_file_spelling_names_one_file_for_every_tool;
          Alcotest.test_case "Execute own container cwd preserves containment"
            `Quick test_execute_own_container_cwd_preserves_containment;
          Alcotest.test_case
            "read-only omitted cwd does not create playground"
            `Quick test_readonly_execute_omitted_cwd_does_not_create_playground;
          Alcotest.test_case "container file path names the host file"
            `Quick test_container_file_path_names_the_host_file;
          Alcotest.test_case "docker other container root stays blocked"
            `Quick test_docker_other_container_root_stays_blocked;
          Alcotest.test_case
            "read-only Execute omitted cwd does not create write root"
            `Quick
            test_readonly_execute_omitted_cwd_does_not_create_write_root;
          Alcotest.test_case
            "a guest-only cwd is the endpoint's to check"
            `Quick test_a_guest_only_cwd_is_the_endpoints_to_check;
          Alcotest.test_case
            "cwd existence asks whoever holds the tree"
            `Quick test_cwd_existence_asks_whoever_holds_the_tree;
          Alcotest.test_case
            "Read and search cwds follow the tree"
            `Quick test_read_cwds_follow_the_tree;
        ] );
    ]
