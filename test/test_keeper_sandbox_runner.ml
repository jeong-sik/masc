open Alcotest
open Masc

external unsetenv : string -> unit = "masc_test_unsetenv"

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir path =
  let rec rm p =
    match Unix.lstat p with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter
        (fun name -> rm (Filename.concat p name))
        (Sys.readdir p);
      Unix.rmdir p
    | _ -> Unix.unlink p
    | exception Unix.Unix_error _ -> ()
  in
  rm path

let string_starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.sub value 0 prefix_len = prefix

let make_meta ~sandbox : Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [ "name", `String "runner-test"
      ; "trace_id", `String "runner-test-trace"
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    { meta with Masc.Keeper_meta_contract.sandbox_profile = sandbox }
  | Error e -> Alcotest.fail e

let test_playground_root_uses_config_base_path () =
  let config_base = temp_dir "keeper_sandbox_config_base_" in
  let env_base = temp_dir "keeper_sandbox_env_base_" in
  let previous_masc_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      (match previous_masc_base with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> unsetenv "MASC_BASE_PATH");
      cleanup_dir config_base;
      cleanup_dir env_base)
    (fun () ->
       Unix.putenv "MASC_BASE_PATH" env_base;
       let config = Workspace.default_config config_base in
       let meta = make_meta ~sandbox:Keeper_types_profile_sandbox.Remote_ssh in
       let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       check bool "host root under config base_path" true
         (string_starts_with ~prefix:(config_base ^ "/") host_root);
       check bool "host root ignores ambient MASC_BASE_PATH" false
         (string_starts_with ~prefix:(env_base ^ "/") host_root);
       check string "host root suffix"
         (Filename.concat config_base ".masc/playground/runner-test")
         (Keeper_alerting_path.strip_trailing_slashes host_root))

let () =
  Alcotest.run
    "keeper_sandbox_runner"
    [ ( "playground",
        [ test_case
            "playground root uses config base_path"
            `Quick
            test_playground_root_uses_config_base_path
        ] )
    ]
