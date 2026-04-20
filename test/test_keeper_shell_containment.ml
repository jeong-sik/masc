(** Integration tests for keeper_shell read-side containment.

    RFC-0006 Phase B-1.5: extend the host-FS read guard from B-1
    (handle_keeper_fs_read) to keeper_shell read ops (ls/cat/rg/find/
    head/tail/wc/tree/git_status/git_log/git_diff). Same env flag
    [MASC_KEEPER_SYMMETRIC_SANDBOX], same containment module. *)

module Coord = Masc_mcp.Coord
module Keeper_exec_shell = Masc_mcp.Keeper_exec_shell
module Keeper_registry = Masc_mcp.Keeper_registry
module Keeper_types = Masc_mcp.Keeper_types
module Keeper_alerting_path = Masc_mcp.Keeper_alerting_path
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
  let dir = Filename.temp_file "keeper_shell_containment_" "" in
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
  ensure_dir (Filename.concat tmp ".masc");
  (tmp, Coord.default_config tmp)

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
        ("goal", `String "shell containment test");
        ("allowed_paths", `List [ `String "*" ]);
        ( "sandbox_profile",
          `String (Keeper_types.sandbox_profile_to_string sandbox) );
      ]
  in
  match Keeper_types.meta_of_json json with
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
  let playground =
    Filename.concat base
      (Keeper_alerting_path.playground_path_of_keeper meta.name)
  in
  ensure_dir playground;
  f ~base ~config ~meta ~playground

let parse_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_string_option

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

let test_legacy_keeper_unaffected () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  setup ~keeper_name:"alice" ~sandbox:Keeper_types.Legacy_local
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside = outside_in_root ~base "secret.txt" in
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String outside) ])
  in
  Alcotest.(check bool) "legacy bypasses symmetric containment" false
    (blocked_by_symmetric_sandbox raw)

let test_hardened_flag_off_passthrough () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "false" @@ fun () ->
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Docker_hardened
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside = outside_in_root ~base "secret.txt" in
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String outside) ])
  in
  Alcotest.(check bool) "flag off → containment passthrough" false
    (blocked_by_symmetric_sandbox raw)

let test_hardened_flag_on_blocks_ls_outside () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Docker_hardened
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside_dir = Filename.concat base "outside_playground" in
  ensure_dir outside_dir;
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:
        (`Assoc [ ("op", `String "ls"); ("path", `String outside_dir) ])
  in
  Alcotest.(check bool) "ls outside playground blocked" true
    (blocked_by_symmetric_sandbox raw)

let test_hardened_flag_on_blocks_cat_outside () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Docker_hardened
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside = outside_in_root ~base "host_secret.txt" in
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String outside) ])
  in
  Alcotest.(check bool) "cat outside playground blocked" true
    (blocked_by_symmetric_sandbox raw)

let test_hardened_flag_on_blocks_rg_outside () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Docker_hardened
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside_dir = Filename.concat base "outside_playground" in
  ensure_dir outside_dir;
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat outside_dir "leak.txt")
       "secret-token");
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "rg");
            ("pattern", `String "secret");
            ("path", `String outside_dir);
          ])
  in
  Alcotest.(check bool) "rg outside playground blocked" true
    (blocked_by_symmetric_sandbox raw)

let test_hardened_flag_on_blocks_find_outside () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Docker_hardened
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside_dir = Filename.concat base "outside_playground" in
  ensure_dir outside_dir;
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "find");
            ("pattern", `String "*.txt");
            ("path", `String outside_dir);
          ])
  in
  Alcotest.(check bool) "find outside playground blocked" true
    (blocked_by_symmetric_sandbox raw)

let test_hardened_flag_on_allows_inside_playground () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Docker_hardened
  @@ fun ~base:_ ~config ~meta ~playground ->
  let demo = Filename.concat playground "demo.txt" in
  ignore (Fs_compat.save_file_atomic demo "hello inside playground");
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String demo) ])
  in
  (* Goal: containment did not block. Whether `cat` succeeds depends on
     /bin/cat availability; we only assert the symmetric_sandbox guard
     is silent. *)
  Alcotest.(check bool) "playground-internal cat not blocked" false
    (blocked_by_symmetric_sandbox raw)

let test_docker_with_git_also_contained () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  setup ~keeper_name:"poe" ~sandbox:Keeper_types.Docker_with_git
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside = outside_in_root ~base "git_secret.txt" in
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String outside) ])
  in
  Alcotest.(check bool) "docker_with_git also contained" true
    (blocked_by_symmetric_sandbox raw)

let () =
  Alcotest.run "Keeper_shell_containment"
    [
      ( "containment",
        [
          Alcotest.test_case "legacy keeper unaffected" `Quick
            test_legacy_keeper_unaffected;
          Alcotest.test_case "hardened flag off passthrough" `Quick
            test_hardened_flag_off_passthrough;
          Alcotest.test_case "hardened flag on blocks ls outside" `Quick
            test_hardened_flag_on_blocks_ls_outside;
          Alcotest.test_case "hardened flag on blocks cat outside" `Quick
            test_hardened_flag_on_blocks_cat_outside;
          Alcotest.test_case "hardened flag on blocks rg outside" `Quick
            test_hardened_flag_on_blocks_rg_outside;
          Alcotest.test_case "hardened flag on blocks find outside" `Quick
            test_hardened_flag_on_blocks_find_outside;
          Alcotest.test_case "hardened flag on allows inside playground"
            `Quick test_hardened_flag_on_allows_inside_playground;
          Alcotest.test_case "docker_with_git also contained" `Quick
            test_docker_with_git_also_contained;
        ] );
    ]
