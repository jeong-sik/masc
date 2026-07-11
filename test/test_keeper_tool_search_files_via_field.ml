(** Regression test for the [via] discriminator in the tool_search_files
    host-branch JSON. tool_search_files is now the Grep/rg tool only; directory
    listing and file reads live under Execute. *)

module Workspace = Masc.Workspace
module Keeper_tool_command_runtime = Masc.Keeper_tool_command_runtime
module Keeper_registry = Masc.Keeper_registry
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_types = Keeper_types
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util

let save_atomic_fixture path content =
  let report = Fs_compat.save_file_atomic_blocking path content in
  match report.progress with
  | Fs_compat.Durable_mutation.Durable () when report.diagnostics = [] -> ()
  | Fs_compat.Durable_mutation.Durable ()
  | Fs_compat.Durable_mutation.Committed_not_durable _
  | Fs_compat.Durable_mutation.Not_committed _ ->
    Alcotest.fail (Fs_compat.Durable_mutation.report_to_string report)
;;

let temp_dir () =
  let dir = Filename.temp_file "tool_search_files_via_" "" in
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
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e

let setup f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  ensure_dir (Filename.concat base Common.masc_dirname);
  let config = Workspace.default_config base in
  Keeper_registry.clear ();
  let meta = make_meta ~name:"via-keeper" in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  (* Seed a small file inside the playground so read ops have something
     to operate on; pattern is unique enough for [rg] to match exactly
     once. *)
  let sample = Filename.concat playground "sample.txt" in
  ignore
    (save_atomic_fixture sample
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

let assert_error_contains ~needle raw =
  let error = Yojson.Safe.from_string raw |> Json.member "error" |> Json.to_string in
  Alcotest.(check bool)
    ("error contains " ^ needle)
    true
    (String_util.contains_substring error needle)

let invoke ~config ~meta args =
  Keeper_tool_command_runtime.handle_tool_search_files ~turn_sandbox_factory:None
    ~exec_cache:None ~config ~meta ~args

let test_rg_host_includes_via () =
  setup @@ fun ~config ~meta ~playground:_ ~sample:_ ->
  let raw =
    invoke ~config ~meta
      (`Assoc
        [
          ("op", `String "rg");
          ("pattern", `String "via_marker_text");
          ("path", `String ".");
        ])
  in
  assert_via_host ~op:"rg" raw

let test_missing_pattern_rejects_before_host_dispatch () =
  setup @@ fun ~config ~meta ~playground:_ ~sample:_ ->
  let raw = invoke ~config ~meta (`Assoc [ ("path", `String ".") ]) in
  assert_error_contains ~needle:"pattern is required for rg" raw

let () =
  Alcotest.run "Grep via discriminator"
    [
      ( "host-branch",
        [
          Alcotest.test_case "rg includes via=host" `Quick
            test_rg_host_includes_via;
          Alcotest.test_case "missing pattern rejects before host dispatch" `Quick
            test_missing_pattern_rejects_before_host_dispatch;
        ] );
    ]
