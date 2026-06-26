open Alcotest
open Masc

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

let runtime_toml =
  {|[runtime]
default = "test.local"

[providers.test]
display-name = "Test"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.local]
api-name = "local"
max-context = 4096
tools-support = true
streaming = true

[test.local]
is-default = true
max-concurrent = 1
|}

let with_runtime_default f =
  let path = Filename.temp_file "keeper-runtime-denylist-runtime" ".toml" in
  write_file path runtime_toml;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      match Runtime.init_default ~config_path:path with
      | Ok () -> f ()
      | Error e -> fail ("Runtime.init_default failed: " ^ e))

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

let read_persisted_meta config keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Error e -> fail ("read_meta failed: " ^ e)
  | Ok None -> fail "meta should exist"
  | Ok (Some meta) -> meta

(** Regression test: ensure_keeper_meta must overlay a TOML-owned
    tool_denylist at runtime without writing the TOML-owned value into
    the runtime JSON file on every reconcile tick.

    Steps:
    1. Write a keeper TOML declaring tool_denylist = ["toml-tool-x", "toml-tool-y"]
    2. Write keeper meta with a different stale denylist = ["old-stale-tool"]
    3. Call ensure_keeper_meta
    4. Assert the returned meta has the TOML denylist while persisted JSON
       remains runtime-only. *)
let test_ensure_keeper_meta_overlays_denylist_from_toml () =
  with_runtime_default @@ fun () ->
  with_temp_dir "keeper-runtime-denylist-workspace" @@ fun workspace_dir ->
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
sandbox_profile = "local"
tool_denylist = ["toml-tool-x", "toml-tool-y"]
|};
  (* 2. Write keeper meta with a stale denylist *)
  let config = Workspace.default_config workspace_dir in
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
  (match Keeper_meta_store.write_meta config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  let initial_persisted_version =
    (read_persisted_meta config keeper_name).Keeper_meta_contract.meta_version
  in
  (* 3. Call ensure_keeper_meta — should overlay denylist from TOML *)
  (match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      (* 4a. Returned meta has TOML denylist *)
      check
        (list string)
        "returned meta denylist overlaid from TOML"
        [ "toml-tool-x"; "toml-tool-y" ]
        updated.Keeper_meta_contract.tool_denylist;
      (* 4b. Persisted meta remains runtime-only, so TOML-owned denylist
         does not cause a reconcile write loop. *)
      (match Keeper_meta_store.read_meta config keeper_name with
      | Error e -> fail ("read_meta failed: " ^ e)
      | Ok None -> fail "meta should exist after ensure_keeper_meta"
      | Ok (Some persisted) ->
          check
            (list string)
            "persisted meta does not store TOML denylist"
            []
            persisted.Keeper_meta_contract.tool_denylist;
          check int "no TOML-only write bump" initial_persisted_version
            persisted.Keeper_meta_contract.meta_version))

let test_ensure_keeper_meta_overlays_active_goal_ids_and_persists () =
  with_runtime_default @@ fun () ->
  with_temp_dir "keeper-runtime-active-goal-workspace" @@ fun workspace_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "active-goal-resync-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
goal = "Test active goal resync"
sandbox_profile = "local"
active_goal_ids = ["goal-runtime"]
|};
  let config = Workspace.default_config workspace_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-active-goal-resync");
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_meta_store.write_meta config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  let initial_persisted_version =
    (read_persisted_meta config keeper_name).Keeper_meta_contract.meta_version
  in
  (match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check
        (list string)
        "returned meta active_goal_ids overlaid from TOML"
        [ "goal-runtime" ]
        updated.Keeper_meta_contract.active_goal_ids;
      (match Keeper_meta_store.read_meta config keeper_name with
      | Error e -> fail ("read_meta failed: " ^ e)
      | Ok None -> fail "meta should exist after ensure_keeper_meta"
      | Ok (Some persisted) ->
          check
            (list string)
            "persisted meta stores TOML active_goal_ids"
            [ "goal-runtime" ]
            persisted.Keeper_meta_contract.active_goal_ids;
          check int "TOML-owned active_goal_ids writes once"
            (initial_persisted_version + 1)
            persisted.Keeper_meta_contract.meta_version))

let () =
  run "Keeper_runtime denylist resync"
    [
      ( "ensure_keeper_meta",
        [
          test_case
            "overlays TOML denylist without persisting config fields"
            `Quick
            test_ensure_keeper_meta_overlays_denylist_from_toml;
          test_case
            "overlays active_goal_ids from TOML and persists"
            `Quick
            test_ensure_keeper_meta_overlays_active_goal_ids_and_persists;
        ] );
    ]
