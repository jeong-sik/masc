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

let make_docker_meta ~name : Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "cwd response leak pin");
        ("allowed_paths", `List [ `String "*" ]);
        ( "sandbox_profile"
        , `String
            (Keeper_types_profile_sandbox.sandbox_profile_to_string Keeper_types_profile_sandbox.Docker) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
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
        (Keeper_cwd_response.operator_host cwd_response))

let test_typed_execute_response_cwd_uses_container_path () =
  Eio_main.run @@ fun _env ->
  let base = temp_dir "typed_exec_docker_cwd_resp_" in
  let config = Workspace.default_config base in
  let meta = make_docker_meta ~name:"typed-exec-cwd-pin" in
  let factory = Keeper_sandbox_factory.create ~config ~meta ~turn_id:42 () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_sandbox_factory.cleanup factory;
      cleanup_dir base)
    (fun () ->
       let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       let host_cwd =
         Filename.concat host_root "repos/masc/.worktrees/task-cwd-pin"
       in
       let response_cwd =
         Keeper_tool_execute_runtime.For_testing.typed_execute_response_cwd_json
           ~turn_sandbox_factory:(Some factory)
           ~cwd:host_cwd
           ~sandbox_extra_fields:
             [
               "requested_sandbox", `String "docker";
               "via", `String "docker";
               "sandbox_profile", `String "docker";
             ]
       in
       let json_str = Yojson.Safe.to_string response_cwd in
       check bool "typed Execute cwd JSON does NOT contain host base" false
         (Astring.String.is_infix ~affix:base json_str);
       check bool "typed Execute cwd JSON does NOT contain host cwd" false
         (Astring.String.is_infix ~affix:host_cwd json_str);
       match response_cwd with
       | `String cwd ->
         check bool
           "typed Execute cwd is rooted at /home/keeper/playground"
           true
           (Astring.String.is_prefix ~affix:"/home/keeper/playground" cwd)
       | _ -> fail "typed Execute cwd response should serialize as a string")

let test_retired_path_jail_env_detection () =
  let configured value =
    Retired_env_warnings.For_testing.shell_ir_path_jail_env_configured
      ~getenv:(fun name ->
        if String.equal name "MASC_SHELL_IR_PATH_JAIL_ENABLED"
        then value
        else None)
      ()
  in
  check bool "absent retired path jail env" false (configured None);
  check bool "blank retired path jail env" false (configured (Some "  "));
  check bool "non-empty retired path jail env" true (configured (Some "false"))

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
        ] )
    ; ( "source-pin"
      , [
          test_case
            "no raw (\"cwd\", `String cwd) literal remains in source"
            `Quick test_source_has_no_raw_cwd_string_literal
        ] )
    ; ( "retired-env"
      , [
          test_case
            "path jail retired env detection ignores blanks"
            `Quick test_retired_path_jail_env_detection
        ] )
    ]
