(** Regression test for the [via] discriminator in keeper_shell host-branch
    JSON. Before the helper-and-sweep fix in #11080's sibling sweep, the
    host branches of [ls/cat/rg/find/head/tail/tree/wc] hand-rolled JSON
    without [via], so dashboards and downstream LLMs could not tell host
    execution from a docker-sandboxed run. The bug class is the same as
    the [sandbox_host_root] / [playground_path] leak that #11080 closed
    in [keeper_status_detail.ml]. *)

module Coord = Masc_mcp.Coord
module Keeper_exec_shell = Masc_mcp.Keeper_exec_shell
module Keeper_registry = Masc_mcp.Keeper_registry
module Keeper_sandbox = Masc_mcp.Keeper_sandbox
module Keeper_types = Masc_mcp.Keeper_types
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util

let temp_dir () =
  let dir = Filename.temp_file "keeper_shell_via_" "" in
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

let make_meta ~name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "via discriminator regression");
        ("allowed_paths", `List [ `String "*" ]);
        ("sandbox_profile", `String "local");
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e

let setup f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  ensure_dir (Filename.concat base Common.masc_dirname);
  let config = Coord.default_config base in
  Keeper_registry.clear ();
  let meta = make_meta ~name:"via-keeper" in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  (* Seed a small file inside the playground so read ops have something
     to operate on; pattern is unique enough for [rg] to match exactly
     once. *)
  let sample = Filename.concat playground "sample.txt" in
  ignore
    (Fs_compat.save_file_atomic sample
       "alpha via_marker_text\nbeta\ngamma\n");
  f ~config ~meta ~playground ~sample

let parse_via_field raw =
  Yojson.Safe.from_string raw |> Json.member "via" |> Json.to_string_option

let assert_via_host ~op raw =
  match parse_via_field raw with
  | Some "host" -> ()
  | Some other ->
      Alcotest.failf "op=%s expected via=\"host\", got via=%S; raw=%s" op other raw
  | None ->
      Alcotest.failf
        "op=%s missing [via] discriminator in host-branch JSON; raw=%s" op raw

let invoke ~config ~meta args =
  Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_runtime:None
    ~exec_cache:None ~config ~meta ~args

let test_ls_host_includes_via () =
  setup @@ fun ~config ~meta ~playground ~sample:_ ->
  let raw =
    invoke ~config ~meta
      (`Assoc [ ("op", `String "ls"); ("path", `String playground) ])
  in
  assert_via_host ~op:"ls" raw

let test_cat_host_includes_via () =
  setup @@ fun ~config ~meta ~playground:_ ~sample ->
  let raw =
    invoke ~config ~meta
      (`Assoc [ ("op", `String "cat"); ("path", `String sample) ])
  in
  assert_via_host ~op:"cat" raw

let test_rg_host_includes_via () =
  setup @@ fun ~config ~meta ~playground ~sample:_ ->
  let raw =
    invoke ~config ~meta
      (`Assoc
        [
          ("op", `String "rg");
          ("pattern", `String "via_marker_text");
          ("path", `String playground);
        ])
  in
  assert_via_host ~op:"rg" raw

let test_find_host_includes_via () =
  setup @@ fun ~config ~meta ~playground ~sample:_ ->
  let raw =
    invoke ~config ~meta
      (`Assoc
        [
          ("op", `String "find");
          ("pattern", `String "*.txt");
          ("path", `String playground);
        ])
  in
  assert_via_host ~op:"find" raw

let test_head_host_includes_via () =
  setup @@ fun ~config ~meta ~playground:_ ~sample ->
  let raw =
    invoke ~config ~meta
      (`Assoc [ ("op", `String "head"); ("path", `String sample) ])
  in
  assert_via_host ~op:"head" raw

let test_tail_host_includes_via () =
  setup @@ fun ~config ~meta ~playground:_ ~sample ->
  let raw =
    invoke ~config ~meta
      (`Assoc [ ("op", `String "tail"); ("path", `String sample) ])
  in
  assert_via_host ~op:"tail" raw

let test_tree_host_includes_via () =
  setup @@ fun ~config ~meta ~playground ~sample:_ ->
  let raw =
    invoke ~config ~meta
      (`Assoc [ ("op", `String "tree"); ("path", `String playground) ])
  in
  assert_via_host ~op:"tree" raw

let test_wc_host_includes_via () =
  setup @@ fun ~config ~meta ~playground:_ ~sample ->
  let raw =
    invoke ~config ~meta
      (`Assoc [ ("op", `String "wc"); ("path", `String sample) ])
  in
  assert_via_host ~op:"wc" raw

let () =
  Alcotest.run "Keeper_shell via discriminator"
    [
      ( "host-branch",
        [
          Alcotest.test_case "ls includes via=host" `Quick
            test_ls_host_includes_via;
          Alcotest.test_case "cat includes via=host" `Quick
            test_cat_host_includes_via;
          Alcotest.test_case "rg includes via=host" `Quick
            test_rg_host_includes_via;
          Alcotest.test_case "find includes via=host" `Quick
            test_find_host_includes_via;
          Alcotest.test_case "head includes via=host" `Quick
            test_head_host_includes_via;
          Alcotest.test_case "tail includes via=host" `Quick
            test_tail_host_includes_via;
          Alcotest.test_case "tree includes via=host" `Quick
            test_tree_host_includes_via;
          Alcotest.test_case "wc includes via=host" `Quick
            test_wc_host_includes_via;
        ] );
    ]
