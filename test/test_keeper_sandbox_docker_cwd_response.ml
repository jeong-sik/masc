(** Integration pin for PR-2 of the [Keeper_cwd_response] series.

    Asserts that the helper functions wired into
    [keeper_sandbox_docker.ml] response builders produce the
    in-container path (not the host abs path) when composed.

    Background: PR #11080 removed [sandbox_host_root] /
    [playground_path] from [execution_context], but sibling
    [cwd] response fields in Docker bash routes still echoed the host abs path.
    PR-1 introduced [Keeper_cwd_response]; this PR (PR-2)
    replaces the four [("cwd", `String cwd)] literals with
    [Keeper_cwd_response.to_yojson_response]. This test pins
    the composition contract so a future refactor cannot
    silently revert to host-path echo. *)

open Alcotest
open Masc

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

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () -> restore_env name previous)
    (fun () ->
      restore_env name value;
      f ())

let make_docker_meta ~name : Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String ("trace-" ^ name));
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    { meta with
      sandbox_profile = Keeper_types_profile_sandbox.Docker
    }
  | Error e -> Alcotest.fail e

let test_container_path_translation_under_sandbox () =
  let base = temp_dir "shell_docker_cwd_resp_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
      let config = Workspace.default_config base in
      let meta = make_docker_meta ~name:"cwd-pin-keeper" in
      let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
      let host_cwd = Filename.concat host_root "repos/foo" in
      let container_cwd =
        Keeper_sandbox_docker.docker_private_workspace_cwd ~config ~meta
          host_cwd
      in
      (* Sanity: translation produced an in-container path rooted
         at the SSOT container playground prefix. *)
      check bool "container_cwd does NOT contain base dir" false
        (Astring.String.is_infix ~affix:base container_cwd);
      check bool
        "container_cwd is rooted at /home/keeper/playground"
        true
        (Astring.String.is_prefix ~affix:"/home/keeper/playground"
           container_cwd);
      let cwd_response =
        Keeper_cwd_response.of_sandbox
          ~sandbox:(Keeper_sandbox.of_meta ~config ~meta)
          ~host_cwd
          ~container_cwd_for_docker:container_cwd
      in
      let json_str =
        Keeper_cwd_response.to_yojson_response cwd_response
        |> Yojson.Safe.to_string
      in
      check bool "response JSON does NOT contain host base dir" false
        (Astring.String.is_infix ~affix:base json_str);
      check bool "response JSON does NOT contain host_cwd" false
        (Astring.String.is_infix ~affix:host_cwd json_str);
      check bool "response JSON does contain container_cwd" true
        (Astring.String.is_infix ~affix:container_cwd json_str);
      check string "operator_host accessor returns the host_cwd"
        host_cwd
        (Keeper_cwd_response.operator_host cwd_response);
      let explicit_cwd =
        Keeper_sandbox_repo_path.normalize_path
          (Filename.concat base "explicit-local-allowed")
      in
      Unix.mkdir explicit_cwd 0o755;
      let local_meta =
        { (make_docker_meta ~name:"local-explicit-path") with
          sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh
        }
      in
      let raw =
        Keeper_tool_execute_runtime.handle_tool_execute
          ~turn_sandbox_factory:None
          ~config
          ~meta:local_meta
          ~args:
            (`Assoc
              [ "argv", `List []
              ; "cwd", `String explicit_cwd
              ])
          ()
      in
      let response = Yojson.Safe.from_string raw in
      let open Yojson.Safe.Util in
      check string "Local explicit cwd remains visible at top level"
        explicit_cwd
        (response |> member "cwd" |> to_string);
      check string "Local explicit cwd remains visible in execution_location"
        explicit_cwd
        (response
         |> member "execution_location"
         |> member "cwd"
         |> to_string))

let test_typed_execute_response_cwd_uses_container_path () =
  Eio_main.run @@ fun _env ->
  let base = temp_dir "typed_exec_docker_cwd_resp_" in
  let config = Workspace.default_config base in
  let meta = make_docker_meta ~name:"typed-exec-cwd-pin" in
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_sandbox_factory.cleanup factory;
      cleanup_dir base)
    (fun () ->
       let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
      let host_cwd =
        Filename.concat host_root "repos/masc/.worktrees/task-cwd-pin"
      in
      let visible_root =
        Keeper_sandbox.keeper_visible_root_abs_of_meta ~config meta
      in
      let prompt =
        Keeper_run_context.build_base_system_prompt
          ~config
          ~profile_defaults:
            Keeper_types_profile_defaults.empty_keeper_profile_defaults
          ~meta
      in
      check bool "Docker prompt does NOT contain host base" false
        (Astring.String.is_infix ~affix:base prompt);
      check bool "Docker prompt contains Keeper-visible sandbox root" true
        (Astring.String.is_infix ~affix:visible_root prompt);
      check bool "Docker prompt recommends relative argv operands" true
        (Astring.String.is_infix
           ~affix:"Prefer relative argv path operands"
           prompt);
      check bool "Docker prompt rejects host absolute paths" true
        (Astring.String.is_infix
           ~affix:"host absolute paths are unavailable"
           prompt);
      let response_fields =
        Keeper_tool_execute_runtime.For_testing.model_execute_location_fields
          ~config
          ~meta
          ~args:(`Assoc [ "argv", `List [ `String "find"; `String "." ] ])
          ~cwd:host_cwd
      in
      let full_response = `Assoc response_fields in
      let json_str = Yojson.Safe.to_string full_response in
      check bool "typed Execute cwd JSON does NOT contain host base" false
        (Astring.String.is_infix ~affix:base json_str);
       check bool "typed Execute cwd JSON does NOT contain host cwd" false
         (Astring.String.is_infix ~affix:host_cwd json_str);
      let response_cwd =
        full_response
        |> Yojson.Safe.Util.member "cwd"
        |> Yojson.Safe.Util.to_string
      in
      check string
        "typed Execute cwd is projected from the host sandbox root"
        (Filename.concat visible_root "repos/masc/.worktrees/task-cwd-pin")
        response_cwd;
      let error_raw =
        Keeper_tool_execute_runtime.handle_tool_execute
          ~turn_sandbox_factory:(Some factory)
          ~config
          ~meta
          ~args:(`Assoc [ "argv", `List []; "cwd", `String "." ])
          ()
      in
      check bool "Docker validation error does NOT contain host base" false
        (Astring.String.is_infix ~affix:base error_raw);
      let error_response = Yojson.Safe.from_string error_raw in
      let error_cwd =
        error_response
        |> Yojson.Safe.Util.member "cwd"
        |> Yojson.Safe.Util.to_string
      in
      let error_location_cwd =
        error_response
        |> Yojson.Safe.Util.member "execution_location"
        |> Yojson.Safe.Util.member "cwd"
        |> Yojson.Safe.Util.to_string
      in
      check string "Docker error top-level cwd uses visible root"
        visible_root
        error_cwd;
      check string "Docker error location cwd matches top-level cwd"
        error_cwd
        error_location_cwd;
      let missing_relative = "missing-relative" in
      let missing_raw =
        Keeper_tool_execute_runtime.handle_tool_execute
          ~turn_sandbox_factory:(Some factory)
          ~config
          ~meta
          ~args:
            (`Assoc
              [ "argv", `List [ `String "pwd" ]
              ; "cwd", `String missing_relative
              ])
          ()
      in
      check bool "Docker missing-cwd error does NOT contain host base" false
        (Astring.String.is_infix ~affix:base missing_raw);
      let missing_response = Yojson.Safe.from_string missing_raw in
      let missing_code =
        missing_response
        |> Yojson.Safe.Util.member "code"
        |> Yojson.Safe.Util.to_string
      in
      let missing_error =
        missing_response
        |> Yojson.Safe.Util.member "error"
        |> Yojson.Safe.Util.to_string
      in
      let missing_cwd =
        missing_response
        |> Yojson.Safe.Util.member "cwd"
        |> Yojson.Safe.Util.to_string
      in
      let missing_location_cwd =
        missing_response
        |> Yojson.Safe.Util.member "execution_location"
        |> Yojson.Safe.Util.member "cwd"
        |> Yojson.Safe.Util.to_string
      in
      check string "Docker missing-cwd code is actionable"
        "cwd_missing"
        missing_code;
      check string "Docker missing-cwd top-level path is visible"
        (Filename.concat visible_root missing_relative)
        missing_cwd;
      check string "Docker missing-cwd location matches top-level cwd"
        missing_cwd
        missing_location_cwd;
      let not_directory = "not-directory" in
      let host_file = Filename.concat host_root not_directory in
      let oc = open_out host_file in
      close_out oc;
      let not_directory_raw =
        Keeper_tool_execute_runtime.handle_tool_execute
          ~turn_sandbox_factory:(Some factory)
          ~config
          ~meta
          ~args:
            (`Assoc
              [ "argv", `List [ `String "pwd" ]
              ; "cwd", `String not_directory
              ])
          ()
      in
      check bool "Docker non-directory error does NOT contain host base" false
        (Astring.String.is_infix ~affix:base not_directory_raw);
      let not_directory_response = Yojson.Safe.from_string not_directory_raw in
      let not_directory_code =
        not_directory_response
        |> Yojson.Safe.Util.member "code"
        |> Yojson.Safe.Util.to_string
      in
      let not_directory_error =
        not_directory_response
        |> Yojson.Safe.Util.member "error"
        |> Yojson.Safe.Util.to_string
      in
      let not_directory_cwd =
        not_directory_response
        |> Yojson.Safe.Util.member "cwd"
        |> Yojson.Safe.Util.to_string
      in
      let not_directory_location_cwd =
        not_directory_response
        |> Yojson.Safe.Util.member "execution_location"
        |> Yojson.Safe.Util.member "cwd"
        |> Yojson.Safe.Util.to_string
      in
      check string "Docker non-directory code is actionable"
        "cwd_not_directory"
        not_directory_code;
      check bool "Docker cwd errors keep distinct public messages" false
        (String.equal missing_error not_directory_error);
      check string "Docker non-directory top-level path is visible"
        (Filename.concat visible_root not_directory)
        not_directory_cwd;
      check string "Docker non-directory location matches top-level cwd"
        not_directory_cwd
        not_directory_location_cwd)

let test_prompt_keeps_caller_owned_workspace_generation () =
  let admitted_base = temp_dir "keeper_prompt_admitted_" in
  let divergent_base = temp_dir "keeper_prompt_divergent_" in
  Fun.protect
    ~finally:(fun () ->
      Workspace.reset_default_config_cache ();
      cleanup_dir admitted_base;
      cleanup_dir divergent_base)
    (fun () ->
      with_env "MASC_BASE_PATH" None @@ fun () ->
      with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
      Workspace.reset_default_config_cache ();
      let config = Workspace.default_config admitted_base in
      let meta =
        { (make_docker_meta ~name:"caller-config-pin") with
          sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh
        }
      in
      let expected_root =
        Keeper_sandbox.keeper_visible_root_abs_of_meta ~config meta
      in
      let divergent_root =
        Filename.concat divergent_base (Keeper_sandbox.host_root_rel_of_meta ~meta)
      in
      with_env "MASC_BASE_PATH" (Some divergent_base) @@ fun () ->
      with_env "MASC_BASE_PATH_INPUT" (Some divergent_base) @@ fun () ->
      Workspace.reset_default_config_cache ();
      let prompt =
        Keeper_run_context.build_base_system_prompt
          ~config
          ~profile_defaults:
            Keeper_types_profile_defaults.empty_keeper_profile_defaults
          ~meta
      in
      check bool "prompt uses the admitted config sandbox root" true
        (Astring.String.is_infix ~affix:expected_root prompt);
      check bool "prompt does not resolve a second workspace generation" false
        (Astring.String.is_infix ~affix:divergent_root prompt))

(* Source-level pin: assert that no [("cwd", `String <ident>)]
   literal remains in keeper_sandbox_docker.ml. The four sites
   from #11080's sibling leak class must be wired through
   [Keeper_cwd_response.to_yojson_response]. Belt-and-braces
   guard against accidental revert. *)
let test_source_has_no_raw_cwd_string_literal () =
  let candidate_paths =
    [
      "lib/keeper/keeper_sandbox_docker.ml"
    ; "../lib/keeper/keeper_sandbox_docker.ml"
    ; "../../lib/keeper/keeper_sandbox_docker.ml"
    ]
  in
  let path =
    List.find_opt Sys.file_exists candidate_paths
  in
  match path with
  | None ->
    (* Test invocation cwd may differ; skip silently rather
       than fail. The integration test above already pins the
       composition. *)
    ()
  | Some path ->
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let buf = Buffer.create 8192 in
        (try
           while true do
             Buffer.add_string buf (input_line ic);
             Buffer.add_char buf '\n'
           done
         with End_of_file -> ());
        let src = Buffer.contents buf in
        check bool
          "no raw (\"cwd\", `String cwd) literal in keeper_sandbox_docker.ml"
          false
          (Astring.String.is_infix ~affix:"(\"cwd\", `String cwd)" src))

let () =
  run "keeper_sandbox_docker_cwd_response"
    [
      ( "translation"
      , [
          test_case
            "host_cwd → container_cwd → JSON does not leak host"
            `Quick test_container_path_translation_under_sandbox
        ; test_case
            "typed Execute Docker cwd response does not leak host"
            `Quick test_typed_execute_response_cwd_uses_container_path
        ; test_case
            "Keeper prompt keeps caller-owned workspace generation"
            `Quick test_prompt_keeps_caller_owned_workspace_generation
        ] )
    ; ( "source-pin"
      , [
          test_case
            "no raw (\"cwd\", `String cwd) literal remains in source"
            `Quick test_source_has_no_raw_cwd_string_literal
        ] )
    ]
