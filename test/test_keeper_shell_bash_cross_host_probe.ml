(** P0-X Layer A scaffold: proves the [cross_host_probe_result] emitter fires
    when [handle_keeper_bash] sees an absolute /home or /Users path probe, and
    does NOT fire when the same shape uses a relative path (which should fall
    through to the existing shape-detection or sandbox-normalization paths).

    Pattern source: [test_keeper_bash_safety.ml] —
    - [with_eio_fs] / [make_config] / [make_readonly_meta] / [ensure_dir]
    - [parse_error_field] and explicit Yojson member walks for [extra] fields
    - [Keeper_exec_shell.handle_keeper_bash] direct call, no factories.

    The three signature tests pin:
    1. Test 1: [find /home/user/repos -type d -name "*task*"] → emits
       [error="keeper_bash_cross_host_probe_redirect"] with
       [required_next_tool="keeper_context_status"] and
       [recovery_rule_id="keeper_bash_cross_host_probe_redirect"].
    2. Test 2: [find /Users/dancer/repos -maxdepth 4] → same emitter
       (different absolute root prefix).
    3. Test 3: [find repos/foo -type d] → does NOT trigger this emitter.
       (May still hit a different shape block like [repo_wide_scan]; this
       test only proves the *Layer A* short-circuit did not fire.) *)

module Coord = Masc_mcp.Coord
module Keeper_exec_shell = Masc_mcp.Keeper_exec_shell
module Keeper_registry = Masc_mcp.Keeper_registry
module Json = Yojson.Safe.Util

let playground_path_of = Masc_mcp.Keeper_alerting_path.playground_path_of_keeper

let temp_dir () =
  let dir = Filename.temp_file "keeper_bash_cross_host_probe_" "" in
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
  (tmp, Coord.default_config tmp)

let make_readonly_meta name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "cross-host probe scaffold");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_readonly_meta failed: " ^ err)

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let parse_string_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_string_option

let run_keeper_bash ~name ~cmd =
  let base_path, config = make_config () in
  let cleanup () = cleanup_dir base_path in
  Fun.protect ~finally:cleanup @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta name in
  let playground =
    Filename.concat base_path (playground_path_of meta.name)
  in
  ensure_dir playground;
  Keeper_exec_shell.handle_keeper_bash
    ~turn_sandbox_factory:None
    ~turn_sandbox_factory_git:None
    ~exec_cache:None
    ~config
    ~meta
    ~args:
      (`Assoc
         [ ("cmd", `String cmd)
         ; ("cwd", `String playground)
         ])
    ()

(* Tests 1 & 2: absolute host-path probes must hit Layer A short-circuit. *)

let assert_cross_host_probe_emitted ~label raw =
  Alcotest.(check (option string))
    (label ^ ": error field is cross_host_probe_redirect")
    (Some "keeper_bash_cross_host_probe_redirect")
    (parse_string_field raw "error");
  let json = Yojson.Safe.from_string raw in
  let next_tool =
    json |> Json.member "required_next_tool" |> Json.to_string_option
  in
  Alcotest.(check (option string))
    (label ^ ": required_next_tool is keeper_context_status")
    (Some "keeper_context_status")
    next_tool;
  let rule_id =
    json |> Json.member "recovery_rule_id" |> Json.to_string_option
  in
  Alcotest.(check (option string))
    (label ^ ": recovery_rule_id matches emitter")
    (Some "keeper_bash_cross_host_probe_redirect")
    rule_id

let test_cross_host_probe_home_path () =
  with_eio_fs @@ fun () ->
  let raw =
    run_keeper_bash
      ~name:"probe-home"
      ~cmd:{|find /home/user/repos -type d -name "*task*"|}
  in
  assert_cross_host_probe_emitted ~label:"find /home/...:" raw

let test_cross_host_probe_users_path () =
  with_eio_fs @@ fun () ->
  let raw =
    run_keeper_bash
      ~name:"probe-users"
      ~cmd:"find /Users/dancer/repos -maxdepth 4"
  in
  assert_cross_host_probe_emitted ~label:"find /Users/...:" raw

(* Test 3: relative path must NOT hit Layer A (it may still be blocked by a
   different shape, but the error code must not be the cross_host_probe one). *)

let test_relative_path_does_not_trigger_cross_host_probe () =
  with_eio_fs @@ fun () ->
  let raw =
    run_keeper_bash
      ~name:"relative-find"
      ~cmd:"find repos/foo -type d"
  in
  let err = parse_string_field raw "error" in
  Alcotest.(check bool)
    "relative find did not hit cross_host_probe emitter"
    true
    (err <> Some "keeper_bash_cross_host_probe_redirect");
  let rule_id =
    Yojson.Safe.from_string raw
    |> Json.member "recovery_rule_id"
    |> Json.to_string_option
  in
  Alcotest.(check bool)
    "relative find did not stamp cross_host_probe rule_id"
    true
    (rule_id <> Some "keeper_bash_cross_host_probe_redirect")

let () =
  Alcotest.run
    "keeper_shell_bash_cross_host_probe"
    [
      ( "cross_host_probe Layer A short-circuit",
        [
          Alcotest.test_case
            "find /home/... emits cross_host_probe_result"
            `Quick
            test_cross_host_probe_home_path;
          Alcotest.test_case
            "find /Users/... emits cross_host_probe_result"
            `Quick
            test_cross_host_probe_users_path;
          Alcotest.test_case
            "find repos/foo (relative) does not trigger Layer A"
            `Quick
            test_relative_path_does_not_trigger_cross_host_probe;
        ] );
    ]
