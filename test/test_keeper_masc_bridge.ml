module Types = Masc_domain

(** Test keeper masc_* tool bridge under explicit tool_access policy. *)

module Workspace = Masc_mcp.Workspace
module KET = Masc_mcp.Keeper_tool_dispatch_runtime

let init_keeper_tool_registry () =
  Masc_test_deps.init_keeper_tool_registry ()

let bridge_test_schemas =
  [
    "masc_status";
    "masc_tasks";
    "masc_claim_next";
    "masc_plan_set_task";
    "masc_transition";
    "masc_add_task";
    "masc_broadcast";
    "masc_messages";
  ]
  |> List.map (fun name ->
         { Masc_domain.name; description = ""; input_schema = `Assoc [] })

let prime_keeper_bridge () =
  init_keeper_tool_registry ();
  ignore (Masc_mcp.Mcp_server_eio.get_clock_opt ());
  Tool_dispatch.register_module_tag
    ~schemas:Masc_mcp.Tool_shard.all_keeper_tool_schemas
    ~tag:Tool_dispatch.Mod_shard;
  KET.inject_masc_schemas (bridge_test_schemas @ Masc_mcp.Config.raw_all_tool_schemas)

let temp_dir () =
  let path = Filename.temp_file "keeper_meta_bridge_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let realpath_or_self path =
  try Unix.realpath path with
  | Unix.Unix_error _ -> path

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let write_text_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let read_text_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> Stdlib.really_input_string ic (in_channel_length ic))

let contains_substring = String_util.contains_substring

let process_exit_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255

let run_process_ok ~cwd prog argv =
  let original_cwd = Sys.getcwd () in
  let dev_null = Unix.openfile Filename.null [ Unix.O_WRONLY ] 0o600 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close dev_null;
      Sys.chdir original_cwd)
    (fun () ->
      Sys.chdir cwd;
      let pid =
        Unix.create_process_env prog argv (Unix.environment ()) Unix.stdin
          dev_null dev_null
      in
      let rec wait () =
        try Unix.waitpid [] pid with
        | Unix.Unix_error (Unix.EINTR, "waitpid", _) -> wait ()
      in
      let _, status = wait () in
      Alcotest.(check int)
        ("process command: " ^ String.concat " " (Array.to_list argv))
        0 (process_exit_code status))

let git_ok ~cwd args =
  run_process_ok ~cwd "git" (Array.of_list ("git" :: args))

let run_with_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let write_json_file path json =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc (Yojson.Safe.pretty_to_string json))

let read_json_file path = Yojson.Safe.from_file path

let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "provider_d-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}
;;

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "keeper_masc_bridge_runtime_" ".toml" in
  write_text_file path runtime_toml;
  match Masc_mcp.Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e
;;

let is_masc_alias_for allowed name =
  List.exists
    (fun base ->
       String.equal name base || String.equal name ("mcp__masc__" ^ base))
    allowed
;;

let register_tool_json_handler ~tool_name handler =
  Tool_dispatch.register ~tool_name ~handler:(fun ~name ~args ->
    let raw = handler ~args in
    Some (Tool_result.ok ~tool_name:name ~start_time:0.0 raw))
;;

let register_patch_handler_for_file file_path =
  register_tool_json_handler ~tool_name:"tool_edit_file" (fun ~args ->
    let new_string =
      Yojson.Safe.Util.member "new_string" args |> Yojson.Safe.Util.to_string
    in
    write_text_file file_path (new_string ^ "\n");
    Yojson.Safe.to_string
      (`Assoc
        [ "ok", `Bool true
        ; "status", `String "ok"
        ; "replacements", `Int 1
        ]))
;;

let make_meta ?(name = "keeper-bridge-test") ?tool_access ?(tool_denylist = [])
    ?(sandbox_profile = Masc_mcp.Keeper_types_profile_sandbox.Local) () =
  let tool_access_field =
    match tool_access with
    | Some access ->
        [
          ( "tool_access",
            Masc_mcp.Keeper_meta_tool_access.tool_access_to_json access );
        ]
    | None -> []
  in
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      ([
        ("name", `String name);
        ("agent_name", `String name);
        ("trace_id", `String (name ^ "-trace"));
        ( "sandbox_profile",
          `String
            (Masc_mcp.Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox_profile)
        );
        ("tool_denylist", `List (List.map (fun s -> `String s) tool_denylist));
      ]
      @ tool_access_field))
  with
  | Ok meta -> meta
  | Error e -> failwith e

let with_registered_keeper ~config (meta : Masc_mcp.Keeper_meta_contract.keeper_meta) f =
  let base_path = config.Workspace.base_path in
  Masc_mcp.Keeper_registry.unregister ~base_path meta.name;
  ignore (Masc_mcp.Keeper_registry.register ~base_path meta.name meta);
  Fun.protect
    ~finally:(fun () -> Masc_mcp.Keeper_registry.unregister ~base_path meta.name)
    f

let allowed_names_of_json json =
  prime_keeper_bridge ();
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> KET.keeper_allowed_tool_names meta
  | Error e -> failwith e

let test_inject_stores_filtered_masc () =
  init_keeper_tool_registry ();
  let schemas : Masc_domain.tool_schema list =
    [
      { name = "masc_status"; description = ""; input_schema = `Assoc [] };
      { name = "masc_broadcast"; description = ""; input_schema = `Assoc [] };
      { name = "masc_messages"; description = ""; input_schema = `Assoc [] };
      { name = "keeper_time_now"; description = ""; input_schema = `Assoc [] };
    ]
  in
  ignore (Masc_mcp.Mcp_server_eio.get_clock_opt ());
  KET.inject_masc_schemas schemas;
  let meta =
    make_meta
      ~tool_access:
        (
           [ "masc_status"; "masc_broadcast"; "masc_messages" ])
      ()
  in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check int) "only keeper-compatible masc tools remain" 1
    (List.length names);
  Alcotest.(check bool) "keeps masc_status" true
    (List.mem "masc_status" names);
  Alcotest.(check bool) "filters masc_broadcast" false
    (List.mem "masc_broadcast" names);
  Alcotest.(check bool) "filters masc_messages" false
    (List.mem "masc_messages" names);
  Alcotest.(check bool) "no keeper_time_now" false
    (List.mem "keeper_time_now" names)

let test_missing_tool_access_exposes_no_masc_tools () =
  prime_keeper_bridge ();
  let meta = make_meta () in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check (list string)) "missing allowlist is empty" [] names

let test_explicit_tool_access_exposes_board () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:([ "keeper_board_post"; "tool_search_files"; "tool_read_file" ])
      ()
  in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check bool) "has keeper_board_post" true
    (List.mem "keeper_board_post" names);
  (* Governance tools are no longer available *)
  Alcotest.(check bool) "no masc_governance_status" false
    (List.mem "masc_governance_status" names);
  Alcotest.(check bool) "has tool_search_files" true
    (List.mem "tool_search_files" names);
  Alcotest.(check bool) "has tool_read_file" true
    (List.mem "tool_read_file" names)

let test_custom_opens_specific_tools_only () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:
        (
           [ "masc_status"; "masc_tasks"; "masc_bind" ])
      ()
  in
  let names = KET.keeper_masc_tool_names meta in
  List.iter
    (fun name ->
       Alcotest.(check bool)
         ("only keeper-compatible tools allowed: " ^ name)
         true
         (is_masc_alias_for [ "masc_status"; "masc_tasks" ] name))
    names;
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_tasks" true
    (List.mem "masc_tasks" names);
  Alcotest.(check bool) "filters masc_bind" false
    (List.mem "masc_bind" names);
  Alcotest.(check bool) "no masc_board_post" false
    (List.mem "masc_board_post" names)

let test_deny_overrides_allow () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:
        (
           [ "masc_status"; "masc_tasks"; "masc_bind" ])
      ~tool_denylist:[ "masc_tasks" ] ()
  in
  let names = KET.keeper_masc_tool_names meta in
  List.iter
    (fun name ->
       Alcotest.(check bool)
         ("only masc_status remains after deny: " ^ name)
         true
         (is_masc_alias_for [ "masc_status" ] name))
    names;
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "no masc_tasks (denied)" false
    (List.mem "masc_tasks" names)

let test_custom_empty_blocks_all () =
  prime_keeper_bridge ();
  let meta =
    make_meta ~tool_access:([]) ()
  in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check int) "no tools" 0 (List.length names)

let test_explicit_allowlist_opens_extra_tool () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:
        (
           [ "keeper_time_now"; "masc_tasks" ])
      ()
  in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check bool) "minimal keeps base tool" true
    (List.mem "keeper_time_now" names);
  Alcotest.(check bool) "explicit allowlist adds tasks" true
    (List.mem "masc_tasks" names);
  Alcotest.(check bool) "minimal omits board post" false
    (List.mem "keeper_board_post" names)

let test_custom_keeps_registered_inline_board_tool () =
  init_keeper_tool_registry ();
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta =
    make_meta
      ~tool_access:
        (
           [ "keeper_board_post"; "masc_broadcast" ])
      ()
  in
  let names = KET.keeper_masc_tool_names meta in
  (* keeper_board_post is a keeper-internal tool, not a masc_ schema;
     it won't appear in masc tool names but will be in the full allowed set *)
  Alcotest.(check bool) "raw masc_board_post filtered out" false
    (List.mem "masc_board_post" names);
  Alcotest.(check bool) "drops unsupported inline tool" false
    (List.mem "masc_broadcast" names)

let with_masc_schema_ref schemas f =
  KET.with_masc_schemas_for_test schemas f

let test_dashboard_tool_count_uses_schema_ssot () =
  let bridge_name = "mcp__masc__masc_status" in
  let schema : Masc_domain.tool_schema =
    { name = bridge_name; description = ""; input_schema = `Assoc [] }
  in
  with_masc_schema_ref [ schema ] (fun () ->
      let meta =
        make_meta
          ~tool_access:
            ([ bridge_name ])
          ()
      in
      let allowed = KET.keeper_allowed_tool_names meta in
      Alcotest.(check bool) "schema bridge is allowed" true
        (List.mem bridge_name allowed);
      let json =
        Masc_mcp.Server_dashboard_http_keeper_api.keeper_tools_response_json meta
      in
      let count =
        Yojson.Safe.Util.(json |> member "active_masc_tool_count" |> to_int)
      in
      Alcotest.(check int) "dashboard counts schema-derived masc tools" 1 count)

let test_tool_access_missing_defaults_standard_policy () =
  let names =
    allowed_names_of_json
      (`Assoc
        [
          ("name", `String "legacy-standard");
          ("agent_name", `String "legacy-standard");
          ("trace_id", `String "legacy-standard-trace");
        ])
  in
  Alcotest.(check bool) "missing allowlist uses default keeper surface" true
    (List.mem "keeper_time_now" names)

let test_typed_and_string_tool_access_rejections_match () =
  let module Access = Masc_mcp.Keeper_meta_contract in
  let check_rejection label json =
    match Access.tool_access_of_meta_json json with
    | Ok _ -> Alcotest.failf "tool_access parser accepted %s" label
    | Error _ -> ()
  in
  check_rejection "missing" (`Assoc []);
  check_rejection "null" (`Assoc [ "tool_access", `Null ])

let test_read_meta_file_rejects_missing_tool_access () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let path = Filename.concat dir "legacy-standard.json" in
      write_json_file path
        (`Assoc
          [
            ("name", `String "legacy-standard");
            ("agent_name", `String "legacy-standard");
            ("trace_id", `String "legacy-standard-trace");
            ("runtime_id", `String "test.runtime");
            ("sandbox_profile", `String "local");
            ("network_mode", `String "inherit");
          ]);
      match Masc_mcp.Keeper_meta_store.read_meta_file_path path with
      | Ok _ -> Alcotest.fail "expected missing tool_access rejection"
      | Error e ->
          Alcotest.(check bool) "mentions tool_access" true
            (contains_substring e "tool_access must be an array"))

let test_read_meta_file_rejects_tool_access_object () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let path = Filename.concat dir "object-tool-access.json" in
      write_json_file path
        (`Assoc
          [
            ("name", `String "object-tool-access");
            ("agent_name", `String "object-tool-access");
            ("trace_id", `String "object-tool-access-trace");
            ("tool_access", `Assoc [ ("value", `String "full") ]);
          ]);
      match Masc_mcp.Keeper_meta_store.read_meta_file_path path with
      | Ok _ -> Alcotest.fail "expected tool_access object rejection"
      | Error e ->
          Alcotest.(check bool) "mentions array" true
            (contains_substring e "tool_access must be an array"))

let test_tool_access_object_empty_value_rejected () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [
           ("name", `String "object-json");
           ("agent_name", `String "object-json");
           ("trace_id", `String "object-json-trace");
           ("tool_access", `Assoc [ ("value", `List []) ]);
         ])
  with
  | Ok _ -> Alcotest.fail "expected object tool_access rejection"
  | Error e ->
      Alcotest.(check bool) "mentions array" true
        (contains_substring e "tool_access must be an array")

let test_tool_access_array_empty_json_preserved () =
  let meta =
    match Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String "custom-json");
            ("agent_name", `String "custom-json");
            ("trace_id", `String "custom-json-trace");
            ("tool_access", `List []);
          ])
    with
    | Ok meta -> meta
    | Error e -> failwith e
  in
  let names = meta.Masc_mcp.Keeper_meta_contract.tool_access in
  Alcotest.(check int) "custom empty preserved" 0 (List.length names)

let test_tool_access_non_array_rejected () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String "invalid-tool-access");
        ("agent_name", `String "invalid-tool-access");
        ("trace_id", `String "invalid-tool-access-trace");
        ("tool_access", `String "masc_status");
      ])
  with
  | Ok _ -> Alcotest.fail "expected non-array tool_access rejection"
  | Error e ->
      Alcotest.(check string)
        "non-array tool_access rejected"
        "meta parse error: keeper tool_access must be an array of strings (received string)"
        e

let test_tool_access_object_array_value_rejected () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String "object-tools");
        ("agent_name", `String "object-tools");
        ("trace_id", `String "object-tools-trace");
        ("tool_access", `Assoc [ ("value", `List [ `String "masc_status" ]) ]);
      ])
  with
  | Ok _ -> Alcotest.fail "expected object tool_access rejection"
  | Error e ->
      Alcotest.(check bool) "mentions array" true
        (contains_substring e "tool_access must be an array")

let test_tool_access_object_scalar_value_rejected () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String "object-no-array");
        ("agent_name", `String "object-no-array");
        ("trace_id", `String "object-no-array-trace");
        ("tool_access", `Assoc [ ("value", `String "full") ]);
      ])
  with
  | Ok _ -> Alcotest.fail "expected object tool_access rejection"
  | Error e ->
      Alcotest.(check bool) "mentions array" true
        (contains_substring e "tool_access must be an array")

let test_tool_access_invalid_tool_member_rejected () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String "invalid-tool-member");
        ("agent_name", `String "invalid-tool-member");
        ("trace_id", `String "invalid-tool-member-trace");
        ("tool_access", `List [ `String "masc_status"; `Int 1 ]);
      ])
  with
  | Ok _ -> Alcotest.fail "expected invalid tool member to fail"
  | Error e ->
      Alcotest.(check string)
        "invalid tool member error"
        "meta parse error: keeper tool_access[1] must be a string (received int)"
        e

let test_allowlist_gates_shard_tools () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:
        (
           [ "masc_status"; "masc_tasks" ])
      ()
  in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_tasks" true
    (List.mem "masc_tasks" names);
  Alcotest.(check bool) "tool_read_file blocked by custom policy" false
    (List.mem "tool_read_file" names)

let test_dispatch_unregistered () =
  let result =
    Tool_dispatch.mint_token ~name:"masc_nonexistent_xyz"
  in
  Alcotest.(check bool) "unregistered mint_token returns Error" true (Result.is_error result)

let test_approval_pending_bridge_uses_keeper_safe_inline_dispatch () =
  prime_keeper_bridge ();
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Workspace.default_config dir in
      let meta =
        make_meta
          ~tool_access:([ "masc_approval_pending" ])
          ()
      in
      with_registered_keeper ~config meta (fun () ->
          let raw =
            Masc_mcp.Keeper_tool_remote_mcp_runtime.handle_masc_tool
              ~config
              ~keeper_name:meta.name
              ~name:"masc_approval_pending"
              ~args:(`Assoc [])
          in
          match Yojson.Safe.from_string raw with
          | `List _ -> ()
          | _ ->
            Alcotest.failf
              "masc_approval_pending should return pending approval list, got: %s"
              raw))

let test_read_only_preflight_accepts_sandbox_relative_repo_path () =
  prime_keeper_bridge ();
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      git_ok ~cwd:dir [ "init"; "--quiet" ];
      let file_path =
        Filename.concat dir
          ".masc/playground/docker/masc-improver/repos/masc-mcp/lib/thompson_sampling.ml"
      in
      ensure_dir (Filename.dirname file_path);
      write_text_file file_path "let alpha = 0.1\nlet beta = 0.2\n";
      run_with_fs (fun () ->
        let config = Workspace.default_config dir in
        ignore (Workspace.init config ~agent_name:(Some "masc-improver"));
        let meta =
          make_meta
            ~name:"masc-improver"
            ~sandbox_profile:Masc_mcp.Keeper_types_profile_sandbox.Docker
            ~tool_access:([ "tool_read_file" ])
            ()
        in
        with_registered_keeper ~config meta (fun () ->
            register_tool_json_handler ~tool_name:"tool_read_file" (fun ~args ->
              let path =
                Yojson.Safe.Util.member "path" args |> Yojson.Safe.Util.to_string
              in
              Yojson.Safe.to_string
                (`Assoc
                  [ "ok", `Bool true
                  ; "path", `String path
                  ; ( "lines"
                    , `List
                        [ `String "let alpha = 0.1"; `String "let beta = 0.2" ]
                    )
                  ]));
            let raw =
              Masc_mcp.Keeper_tool_remote_mcp_runtime.handle_masc_tool
                ~config
                ~keeper_name:meta.name
                ~name:"tool_read_file"
                ~args:
                  (`Assoc
                    [
                      ( "path",
                        `String "repos/masc-mcp/lib/thompson_sampling.ml" );
                      ("offset", `Int 0);
                      ("limit", `Int 2);
                    ])
            in
            let json = Yojson.Safe.from_string raw in
            let path =
              Yojson.Safe.Util.member "path" json |> Yojson.Safe.Util.to_string
            in
            let lines =
              Yojson.Safe.Util.member "lines" json
              |> Yojson.Safe.Util.to_list
              |> List.map Yojson.Safe.Util.to_string
            in
            Alcotest.(check string) "path preserved"
              "repos/masc-mcp/lib/thompson_sampling.ml"
              path;
            Alcotest.(check (list string)) "reads expected lines"
              [ "let alpha = 0.1"; "let beta = 0.2" ]
              lines)))

let test_write_preflight_accepts_docker_container_repo_path () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      git_ok ~cwd:dir [ "init"; "--quiet" ];
      let keeper_toml =
        Filename.concat dir ".masc/config/keepers/sangsu.toml"
      in
      ensure_dir (Filename.dirname keeper_toml);
      write_text_file keeper_toml "[keeper]\nsandbox_profile = \"docker\"\n";
      let file_path =
        Filename.concat dir
          ".masc/playground/docker/sangsu/repos/masc-mcp/.worktrees/keeper-sangsu-agent-task-210/lib/workspace/workspace_orphan_daemon.ml"
      in
      ensure_dir (Filename.dirname file_path);
      write_text_file file_path "let before = 1\n";
      run_with_fs (fun () ->
        prime_keeper_bridge ();
        let config = Workspace.default_config dir in
        ignore (Workspace.init config ~agent_name:(Some "sangsu"));
        let meta =
          make_meta
            ~name:"sangsu"
            ~sandbox_profile:Masc_mcp.Keeper_types_profile_sandbox.Docker
            ~tool_access:([ "tool_edit_file" ])
            ()
        in
        with_registered_keeper ~config meta (fun () ->
          register_patch_handler_for_file file_path;
          let raw =
            Masc_mcp.Keeper_tool_remote_mcp_runtime.handle_masc_tool
              ~config
              ~keeper_name:meta.name
              ~name:"tool_edit_file"
              ~args:
                (`Assoc
                  [
                    ( "path",
                      `String
                        "/home/keeper/playground/sangsu/repos/masc-mcp/.worktrees/keeper-sangsu-agent-task-210/lib/workspace/workspace_orphan_daemon.ml"
                    );
                    ("old_string", `String "let before = 1");
                    ("new_string", `String "let before = 2");
                    ("replace_all", `Bool false);
                  ])
          in
          let json = Yojson.Safe.from_string raw in
          let status =
            Yojson.Safe.Util.member "status" json |> Yojson.Safe.Util.to_string
          in
          let replacements =
            Yojson.Safe.Util.member "replacements" json
            |> Yojson.Safe.Util.to_int
          in
          Alcotest.(check string) "edit status" "ok" status;
          Alcotest.(check int) "single replacement" 1 replacements;
          Alcotest.(check string)
            "file edited through host playground"
            "let before = 2\n"
            (Masc_test_deps.read_file file_path))))

let test_write_preflight_accepts_sandbox_relative_repo_path () =
  prime_keeper_bridge ();
  let dir = temp_dir () |> realpath_or_self in
  let keeper_name = "nick0cave" in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_registry.unregister ~base_path:dir keeper_name;
      cleanup_dir dir)
    (fun () ->
      git_ok ~cwd:dir [ "init"; "--quiet" ];
      let rel_path =
        "repos/masc-mcp/.worktrees/keeper-nick0cave-agent-task-240/lib/foo.ml"
      in
      let file_path =
        Filename.concat
          dir
          (Filename.concat ".masc/playground/docker/nick0cave" rel_path)
      in
      let keeper_config =
        Filename.concat dir ".masc/config/keepers/nick0cave.toml"
      in
      ensure_dir (Filename.dirname keeper_config);
      write_text_file keeper_config "[keeper]\nsandbox_profile = \"docker\"\n";
      ensure_dir (Filename.dirname file_path);
      write_text_file file_path "let x = 1\n";
      run_with_fs (fun () ->
        let config = Workspace.default_config dir in
        let meta =
          make_meta
            ~name:keeper_name
            ~sandbox_profile:Masc_mcp.Keeper_types_profile_sandbox.Docker
            ~tool_access:([ "tool_edit_file" ])
            ()
        in
        ignore (Masc_mcp.Keeper_registry.register ~base_path:dir keeper_name meta);
        register_patch_handler_for_file file_path;
        let raw =
          Masc_mcp.Keeper_tool_remote_mcp_runtime.handle_masc_tool
            ~config
            ~keeper_name
            ~name:"tool_edit_file"
            ~args:
              (`Assoc
                [ "path", `String rel_path
                ; "old_string", `String "let x = 1"
                ; "new_string", `String "let x = 2"
                ; "replace_all", `Bool false
                ])
        in
        let json = Yojson.Safe.from_string raw in
        (match Yojson.Safe.Util.member "error" json with
         | `Null -> ()
         | `String err ->
           Alcotest.failf "tool_edit_file should pass write preflight, got: %s" err
         | other ->
           Alcotest.failf
             "unexpected error shape: %s"
             (Yojson.Safe.to_string other));
        Alcotest.(check string)
          "file edited"
          "let x = 2\n"
          (read_text_file file_path)))

let test_schemas_match_names () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:
        (
           [ "masc_status"; "masc_bind"; "masc_tasks" ])
      ()
  in
  let names = KET.keeper_masc_tool_names meta in
  let schemas = KET.keeper_masc_tool_schemas meta in
  Alcotest.(check int) "count matches"
    (List.length names) (List.length schemas);
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      Alcotest.(check bool) (s.name ^ " in names") true
        (List.mem s.name names))
    schemas

let test_is_keeper_denied () =
  (* RFC-0182: keeper_denied surface is [masc_reset] after masc_spawn removal. *)
  Alcotest.(check bool) "masc_reset is denied" true
    (KET.is_keeper_denied "masc_reset");
  Alcotest.(check bool) "masc_status is not denied" false
    (KET.is_keeper_denied "masc_status");
  Alcotest.(check bool) "keeper_time_now is not denied" false
    (KET.is_keeper_denied "keeper_time_now")

let () =
  let base_path = Masc_test_deps.find_project_root () in
  init_runtime_default_for_tests ();
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  ignore (Result.get_ok (KET.init_policy_config ~base_path));
  Alcotest.run "Keeper masc bridge"
    [
      ( "injection",
        [
          Alcotest.test_case "stores filtered masc_* schemas" `Quick
            test_inject_stores_filtered_masc;
        ] );
      ( "tool_access_policy",
        [
          Alcotest.test_case "missing tool_access exposes no masc tools" `Quick
            test_missing_tool_access_exposes_no_masc_tools;
          Alcotest.test_case "explicit tool_access exposes board" `Quick
            test_explicit_tool_access_exposes_board;
          Alcotest.test_case "explicit allowlist opens extra tool" `Quick
            test_explicit_allowlist_opens_extra_tool;
          Alcotest.test_case "custom filters board tools with keeper wrappers" `Quick
            test_custom_keeps_registered_inline_board_tool;
          Alcotest.test_case "dashboard count uses schema SSOT" `Quick
            test_dashboard_tool_count_uses_schema_ssot;
        ] );
      ( "custom_policy",
        [
          Alcotest.test_case "opens specific tools" `Quick
            test_custom_opens_specific_tools_only;
          Alcotest.test_case "deny overrides allow" `Quick
            test_deny_overrides_allow;
          Alcotest.test_case "custom empty blocks all" `Quick
            test_custom_empty_blocks_all;
          Alcotest.test_case "gates shard tools too" `Quick
            test_allowlist_gates_shard_tools;
        ] );
      ( "meta_json",
        [
          Alcotest.test_case "missing tool_access uses standard policy" `Quick
            test_tool_access_missing_defaults_standard_policy;
          Alcotest.test_case "typed/string rejections match" `Quick
            test_typed_and_string_tool_access_rejections_match;
          Alcotest.test_case "read_meta rejects missing tool_access" `Quick
            test_read_meta_file_rejects_missing_tool_access;
          Alcotest.test_case "read_meta rejects tool_access object" `Quick
            test_read_meta_file_rejects_tool_access_object;
          Alcotest.test_case "tool_access object empty value rejected" `Quick
            test_tool_access_object_empty_value_rejected;
          Alcotest.test_case "array empty json preserved" `Quick
            test_tool_access_array_empty_json_preserved;
          Alcotest.test_case "non-array tool_access rejected" `Quick
            test_tool_access_non_array_rejected;
          Alcotest.test_case "tool_access object array value rejected" `Quick
            test_tool_access_object_array_value_rejected;
          Alcotest.test_case "tool_access object scalar value rejected" `Quick
            test_tool_access_object_scalar_value_rejected;
          Alcotest.test_case "invalid tool member rejected" `Quick
            test_tool_access_invalid_tool_member_rejected;
        ] );
      ( "dispatch",
        [
          Alcotest.test_case "unregistered returns None" `Quick
            test_dispatch_unregistered;
          Alcotest.test_case "approval pending uses keeper-safe inline dispatch"
            `Quick test_approval_pending_bridge_uses_keeper_safe_inline_dispatch;
          Alcotest.test_case
            "read preflight accepts sandbox-relative repo path" `Quick
            test_read_only_preflight_accepts_sandbox_relative_repo_path;
          Alcotest.test_case
            "write preflight accepts sandbox-relative repo path" `Quick
            test_write_preflight_accepts_sandbox_relative_repo_path;
          Alcotest.test_case
            "write preflight accepts Docker container repo path" `Quick
            test_write_preflight_accepts_docker_container_repo_path;
          Alcotest.test_case
            "write preflight accepts sandbox-relative repo path" `Quick
            test_write_preflight_accepts_sandbox_relative_repo_path;
        ] );
      ( "consistency",
        [
          Alcotest.test_case "schemas match names" `Quick test_schemas_match_names;
        ] );
      ( "keeper_denied",
        [
          Alcotest.test_case "is_keeper_denied correctness" `Quick
            test_is_keeper_denied;
        ] );
    ]
