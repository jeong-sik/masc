open Alcotest
open Masc_mcp

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let with_config_dir f =
  with_temp_dir "keeper-runtime-denylist-config" @@ fun config_dir ->
  let original = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (* OCaml stdlib trim_opt treats "" as absent; Config_dir_resolver.reset
         ensures the cleared value takes effect. This matches the pattern used
         throughout the test suite for restoring env vars. *)
      (match original with
      | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
      | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      f config_dir)

(** Regression test: ensure_keeper_meta must overwrite a stale persisted
    tool_denylist with the value from config/keepers/<name>.toml on bootstrap.

    Steps:
    1. Write a keeper TOML declaring tool_denylist = ["toml-tool-x", "toml-tool-y"]
    2. Write keeper meta with a different stale denylist = ["old-stale-tool"]
    3. Call ensure_keeper_meta
    4. Assert the returned (and persisted) denylist matches the TOML *)
let test_ensure_keeper_meta_resyncs_denylist_from_toml () =
  with_temp_dir "keeper-runtime-denylist-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "denylist-resync-test" in
  (* 1. Write TOML config with tool_denylist *)
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
goal = "Test denylist resync"
tool_denylist = ["toml-tool-x", "toml-tool-y"]
|};
  (* 2. Write keeper meta with a stale denylist *)
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-denylist-resync");
            ( "tool_denylist",
              `List [ `String "old-stale-tool" ] );
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  (* 3. Call ensure_keeper_meta — should resync denylist from TOML *)
  (match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      (* 4a. Returned meta has TOML denylist *)
      check
        (list string)
        "returned meta denylist resynced from TOML"
        [ "toml-tool-x"; "toml-tool-y" ]
        updated.Keeper_types.tool_denylist;
      (* 4b. Persisted meta also has TOML denylist *)
      (match Keeper_types.read_meta config keeper_name with
      | Error e -> fail ("read_meta failed: " ^ e)
      | Ok None -> fail "meta should exist after ensure_keeper_meta"
      | Ok (Some persisted) ->
          check
            (list string)
            "persisted meta denylist resynced from TOML"
            [ "toml-tool-x"; "toml-tool-y" ]
            persisted.Keeper_types.tool_denylist))

let () =
  run "Keeper_runtime denylist resync"
    [
      ( "ensure_keeper_meta",
        [
          test_case
            "resyncs stale persisted denylist from TOML on bootstrap"
            `Quick
            test_ensure_keeper_meta_resyncs_denylist_from_toml;
        ] );
    ]
