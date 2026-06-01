module Workspace = Masc_mcp.Workspace
module Store = Masc_mcp.Keeper_meta_store
module Profile = Masc_mcp.Keeper_types_profile
module Status_detail = Masc_mcp.Keeper_status_detail
module Tool_keeper_ops = Masc_mcp.Tool_keeper_ops

let temp_dir () =
  let path = Filename.temp_file "keeper-effective-meta-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let rm_rf path =
  try Masc_mcp.Fs_compat.remove_tree path with
  | _ -> ()

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop index =
    index + needle_len <= haystack_len
    && (String.sub haystack index needle_len = needle || loop (index + 1))
  in
  needle_len = 0 || loop 0

let json_string_field key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) -> Some value
      | _ -> None)
  | _ -> None

let with_config_dir f =
  let base = temp_dir () in
  let config_dir = Filename.concat base ".masc/config" in
  let keepers_dir = Filename.concat config_dir "keepers" in
  mkdir_p keepers_dir;
  let previous = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" previous;
      Config_dir_resolver.reset ();
      rm_rf base)
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      f ~base ~config_dir ~keepers_dir)

let seed_runtime_meta config name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "effective meta overlay regression");
        ("tool_access", `List [ `String "masc_status" ]);
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Error err -> Alcotest.fail err
  | Ok meta -> (
      match Store.write_meta config meta with
      | Ok () -> meta
  | Error err -> Alcotest.failf "write_meta failed: %s" err)

let write_keeper_toml ~keepers_dir ~name ~sandbox_profile ~goal =
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    (Printf.sprintf
       {|[keeper]
sandbox_profile = "%s"
goal = "%s"
|}
       sandbox_profile
       goal)

let status_goal config name =
  let args = `Assoc [ ("name", `String name); ("fast", `Bool true) ] in
  let result =
    Status_detail.handle_keeper_status_config
      ~config
      ~agent_name:"test-agent"
      args
  in
  if not (Profile.tool_result_success result) then
    Alcotest.failf "status failed: %s" (Profile.tool_result_body result);
  let json = Yojson.Safe.from_string (Profile.tool_result_body result) in
  match json_string_field "goal" json with
  | Some goal -> goal
  | None -> Alcotest.fail "status response missing goal"

let test_toml_overlay_reaches_effective_meta () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "analyst" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
sandbox_profile = "docker"

[keeper.tool_access]
tools = ["tool_execute", "tool_read_file"]
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc_mcp.Keeper_meta_contract.keeper_meta);
  match Store.read_effective_meta config name with
  | Error err -> Alcotest.failf "read_effective_meta failed: %s" err
  | Ok None -> Alcotest.fail "expected seeded keeper meta"
  | Ok (Some meta) ->
      Alcotest.(check string)
        "sandbox_profile overlays from TOML"
        "docker"
        (Profile.sandbox_profile_to_string meta.sandbox_profile);
      Alcotest.(check string)
        "docker default network overlays from TOML profile"
        "none"
        (Profile.network_mode_to_string meta.network_mode);
      Alcotest.(check (list string))
        "tool_access overlays from TOML"
        [ "tool_execute"; "tool_read_file" ]
        meta.tool_access

let test_missing_sandbox_profile_fails_loud_for_profile_source () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "nosandbox" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
goal = "missing sandbox profile"
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc_mcp.Keeper_meta_contract.keeper_meta);
  match Store.read_effective_meta config name with
  | Ok _ -> Alcotest.fail "expected missing sandbox_profile to fail loudly"
  | Error err ->
      Alcotest.(check bool)
        "error names missing sandbox_profile"
        true
        (contains_substring ~needle:"sandbox_profile is required" err)

let test_status_cache_tracks_toml_overlay_changes () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "statuscache" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"local"
    ~goal:"first cache goal";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc_mcp.Keeper_meta_contract.keeper_meta);
  Alcotest.(check string)
    "initial TOML goal reaches status"
    "first cache goal"
    (status_goal config name);
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"local"
    ~goal:"second cache goal after toml edit";
  Alcotest.(check string)
    "TOML edit invalidates cached status"
    "second cache goal after toml edit"
    (status_goal config name)

let test_keeper_list_row_surfaces_effective_meta_errors () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "badprofile" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
goal = "missing sandbox profile"
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc_mcp.Keeper_meta_contract.keeper_meta);
  match Tool_keeper_ops.keeper_list_row_json ~runtime_class:"keeper" config name with
  | None -> Alcotest.fail "expected error row for invalid effective meta"
  | Some row ->
      Alcotest.(check (option string))
        "row status is error"
        (Some "error")
        (json_string_field "status" row);
      (match row with
       | `Assoc fields ->
           Alcotest.(check bool)
             "row includes actionable error"
             true
             (List.mem_assoc "effective_meta_error" fields)
       | _ -> Alcotest.fail "expected object row")

let () =
  Alcotest.run "keeper_effective_meta_overlay"
    [
      ( "effective_meta",
        [
          Alcotest.test_case "TOML sandbox/tool overlay reaches effective meta"
            `Quick test_toml_overlay_reaches_effective_meta;
          Alcotest.test_case
            "profile source without sandbox_profile fails loudly"
            `Quick test_missing_sandbox_profile_fails_loud_for_profile_source;
          Alcotest.test_case "status cache tracks TOML overlay edits" `Quick
            test_status_cache_tracks_toml_overlay_changes;
          Alcotest.test_case "keeper list surfaces effective meta errors"
            `Quick test_keeper_list_row_surfaces_effective_meta_errors;
        ] );
    ]
