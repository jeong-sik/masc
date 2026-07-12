module Workspace = Masc.Workspace
module Store = Masc.Keeper_meta_store
module Profile = Masc.Keeper_types_profile
module Status_detail = Masc.Keeper_status_detail
module Turn_setup = Masc.Keeper_turn_setup
module Turn = Masc.Keeper_turn
module Keeper_tool_surface = Masc.Keeper_tool_surface
module Keeper_tool_surface_ops = Masc.Keeper_tool_surface_ops
module Heartbeat_presence = Masc.Keeper_heartbeat_loop_presence
(* [Runtime] (init_default) lives in the unwrapped [masc_runtime] library, so it
   is referenced directly (not via [Masc.]); [Keeper_runtime] (ensure_keeper_meta)
   lives in the main [masc] library. Same pattern as test_keeper_lifecycle_registry_dispatch. *)
module Keeper_runtime = Masc.Keeper_runtime

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

let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
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
  let path = Filename.temp_file "keeper_effective_meta_runtime_" ".toml" in
  write_file path runtime_toml;
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e
;;

let rec rm_rf path =
  try
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  with _ -> ()

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

let json_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let json_bool_field key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Bool value) -> Some value
      | _ -> None)
  | _ -> None

let json_int_field key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Int value) -> Some value
      | _ -> None)
  | _ -> None

let json_assoc_field key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Assoc nested) -> `Assoc nested
      | _ -> `Null)
  | _ -> `Null

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

let status_goal_with ?(agent_name = "test-agent") ?name config =
  let args =
    match name with
    | Some name -> `Assoc [ ("name", `String name); ("fast", `Bool true) ]
    | None -> `Assoc [ ("fast", `Bool true) ]
  in
  let result =
    Status_detail.handle_keeper_status_config
      ~config
      ~agent_name
      args
  in
  if not (Profile.tool_result_success result) then
    Alcotest.failf "status failed: %s" (Profile.tool_result_body result);
  let json = Yojson.Safe.from_string (Profile.tool_result_body result) in
  match json_string_field "goal" json with
  | Some goal -> goal
  | None -> Alcotest.fail "status response missing goal"

let status_goal config name = status_goal_with ~name config

let status_json_with ?(agent_name = "test-agent") ?name config =
  let args =
    match name with
    | Some name -> `Assoc [ ("name", `String name); ("fast", `Bool true) ]
    | None -> `Assoc [ ("fast", `Bool true) ]
  in
  let result =
    Status_detail.handle_keeper_status_config ~config ~agent_name args
  in
  if not (Profile.tool_result_success result) then
    Alcotest.failf "status failed: %s" (Profile.tool_result_body result);
  Yojson.Safe.from_string (Profile.tool_result_body result)

let resolved_keeper_name config name =
  match
    Keeper_tool_surface_ops.resolve_keeper_name_config
      ~config
      (`Assoc [ ("name", `String name) ])
  with
  | Ok resolved -> resolved
  | Error err -> Alcotest.failf "resolve_keeper_name_config failed: %s" err

let test_status_resolves_keeper_alias_names () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "aliasprobe" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"local"
    ~goal:"alias status goal";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  Alcotest.(check string)
    "explicit agent alias reaches canonical keeper"
    "alias status goal"
    (status_goal_with ~name:"keeper-aliasprobe-agent" config);
  Alcotest.(check string)
    "prefixed alias reaches canonical keeper"
    "alias status goal"
    (status_goal_with ~name:"keeper-aliasprobe" config);
  Alcotest.(check string)
    "self fallback agent alias reaches canonical keeper"
    "alias status goal"
    (status_goal_with ~agent_name:"keeper-aliasprobe-agent" config)

let test_keeper_surface_resolves_alias_names () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir:_ ->
  let name = "aliasmsg" in
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  Alcotest.(check string)
    "agent alias resolves for keeper surface tools"
    name
    (resolved_keeper_name config "keeper-aliasmsg-agent");
  Alcotest.(check string)
    "prefixed alias resolves for keeper surface tools"
    name
    (resolved_keeper_name config "keeper-aliasmsg")

let test_toml_overlay_reaches_effective_meta () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "analyst" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
sandbox_profile = "docker"
tool_access = ["tool_execute", "tool_read_file"]
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
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

let test_profile_identity_snapshot_reaches_meta_json () =
  with_config_dir @@ fun ~base ~config_dir ~keepers_dir ->
  let name = "probe" in
  let persona_dir = Filename.concat (Filename.concat config_dir "personas") name in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|{
  "persona_name": "probe",
  "display_name": "Probe",
  "keeper": {
    "instructions": "profile instructions"
  }
}
|};
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
persona_name = "probe"
sandbox_profile = "local"
multimodal_policy = "delegate"
tool_access = ["tool_execute"]
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  match Store.read_effective_meta config name with
  | Error err -> Alcotest.failf "read_effective_meta failed: %s" err
  | Ok None -> Alcotest.fail "expected seeded keeper meta"
  | Ok (Some meta) ->
      Alcotest.(check (option string))
        "persona overlays from profile"
        (Some "probe")
        meta.persona;
      Alcotest.(check string)
        "instructions overlays from profile"
        "profile instructions"
        meta.instructions;
      let json = Masc.Keeper_meta_json.meta_to_json meta in
      Alcotest.(check (option string))
        "meta json keeps persona snapshot"
        (Some "probe")
        (json_string_field "persona" json);
      Alcotest.(check (option string))
        "meta json keeps instructions snapshot"
        (Some "profile instructions")
        (json_string_field "instructions" json);
      Alcotest.(check (option string))
        "meta json keeps multimodal policy"
        (Some "delegate")
        (json_string_field "multimodal_policy" json);
      (match Masc.Keeper_meta_json.meta_of_json json with
       | Error err -> Alcotest.failf "meta json roundtrip failed: %s" err
       | Ok roundtrip ->
         Alcotest.(check string)
           "roundtrip keeps multimodal policy"
           "delegate"
           (Profile.multimodal_policy_to_string roundtrip.multimodal_policy));
      let status_result =
        Status_detail.handle_keeper_status_config ~config ~agent_name:"test-agent"
          (`Assoc [ ("name", `String name); ("fast", `Bool true) ])
      in
      if not (Profile.tool_result_success status_result) then
        Alcotest.failf "status failed: %s" (Profile.tool_result_body status_result);
      let status_json =
        Yojson.Safe.from_string (Profile.tool_result_body status_result)
      in
      Alcotest.(check (option string))
        "status keeps persona snapshot"
        (Some "probe")
        (json_string_field "persona" status_json);
      Alcotest.(check (option string))
        "status keeps instructions snapshot"
        (Some "profile instructions")
        (json_string_field "instructions" status_json)

let test_ensure_keeper_meta_persists_toml_identity_snapshot () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "masc-improver" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
persona_name = "masc-improver"
sandbox_profile = "docker"
goal = "Improve MASC autonomously"
proactive_enabled = true
proactive_idle_sec = 77
proactive_cooldown_sec = 88
tool_access = ["tool_execute", "tool_read_file"]
allowed_paths = ["workspace/yousleepwhen/masc"]
active_goal_ids = ["goal-masc-improver"]
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  let persisted =
    match Store.read_meta config name with
    | Ok (Some meta) -> meta
    | Ok None -> Alcotest.fail "expected seeded keeper meta"
    | Error err -> Alcotest.failf "read_meta failed: %s" err
  in
  let stale =
    {
      persisted with
      persona = Some "analyst";
      goal = "stale goal";
      proactive = { enabled = false; idle_sec = 1; cooldown_sec = 2 };
      tool_access = [ "masc_status" ];
      allowed_paths = [ "/tmp/stale-local-path" ];
      active_goal_ids = [ "stale-goal" ];
    }
  in
  (match Store.write_meta config stale with
   | Ok () -> ()
   | Error err -> Alcotest.failf "write stale meta failed: %s" err);
  let returned =
    match Keeper_runtime.ensure_keeper_meta config name with
    | Ok meta -> meta
    | Error err -> Alcotest.failf "ensure_keeper_meta failed: %s" err
  in
  let disk_json = Yojson.Safe.from_file (Profile.keeper_meta_path config name) in
  let leaked_config_keys =
    match disk_json with
    | `Assoc fields ->
      fields
      |> List.filter_map (fun (key, _) ->
        if List.mem key Masc.Keeper_meta_json_scrub.config_field_names
        then Some key
        else None)
    | _ -> Alcotest.fail "expected keeper meta JSON object"
  in
  Alcotest.(check (list string))
    "disk meta excludes TOML-owned config keys"
    []
    leaked_config_keys;
  Alcotest.(check (option string))
    "disk meta keeps persona snapshot"
    (Some "masc-improver")
    (json_string_field "persona" disk_json);
  Alcotest.(check (option string))
    "returned persona is TOML canonical"
    (Some "masc-improver")
    returned.persona;
  Alcotest.(check string)
    "returned goal is TOML canonical"
    "Improve MASC autonomously"
    returned.goal;
  Alcotest.(check bool)
    "returned proactive enabled is TOML canonical"
    true
    returned.proactive.enabled;
  Alcotest.(check int)
    "returned proactive idle is TOML canonical"
    77
    returned.proactive.idle_sec;
  Alcotest.(check int)
    "returned proactive cooldown is TOML canonical"
    88
    returned.proactive.cooldown_sec;
  Alcotest.(check (list string))
    "returned tool_access is TOML canonical"
    [ "tool_execute"; "tool_read_file" ]
    returned.tool_access;
  Alcotest.(check string)
    "returned sandbox_profile is TOML canonical"
    "docker"
    (Profile.sandbox_profile_to_string returned.sandbox_profile);
  Alcotest.(check (list string))
    "returned allowed_paths is TOML canonical"
    [ "workspace/yousleepwhen/masc" ]
    returned.allowed_paths;
  Alcotest.(check (list string))
    "returned active_goal_ids is TOML canonical"
    [ "goal-masc-improver" ]
    returned.active_goal_ids

let test_turn_setup_uses_effective_meta () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "turnsetup" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
sandbox_profile = "docker"
tool_access = ["tool_search_files", "tool_read_file"]
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let ctx : _ Profile.context =
    {
      config;
      agent_name = "test-agent";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = None;
      net = None;
    }
  in
  match Turn_setup.ensure_keeper_exists ~ctx ~name with
  | Error err -> Alcotest.failf "ensure_keeper_exists failed: %s" err
  | Ok meta ->
      Alcotest.(check string)
        "turn setup sees TOML sandbox overlay"
        "docker"
        (Profile.sandbox_profile_to_string meta.sandbox_profile);
      Alcotest.(check (list string))
        "turn setup sees TOML tool overlay"
        [ "tool_search_files"; "tool_read_file" ]
        meta.tool_access

let test_keepalive_meta_selection_overlays_disk_meta () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "taskmaster" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
sandbox_profile = "docker"
network_mode = "inherit"
|};
  let config = Workspace.default_config base in
  let raw_meta = seed_runtime_meta config name in
  Alcotest.(check string)
    "fixture raw meta starts from persisted/default sandbox"
    "local"
    (Profile.sandbox_profile_to_string raw_meta.sandbox_profile);
  let effective =
    Heartbeat_presence.effective_keepalive_meta
      ~base_path:config.base_path
      ~fallback:raw_meta
      ~disk_meta_opt:(Some raw_meta)
  in
  Alcotest.(check string)
    "keepalive disk meta selection applies TOML sandbox overlay"
    "docker"
    (Profile.sandbox_profile_to_string effective.sandbox_profile);
  Alcotest.(check string)
    "keepalive disk meta selection applies TOML network overlay"
    "inherit"
    (Profile.network_mode_to_string effective.network_mode)

let test_missing_sandbox_profile_fails_loud_for_profile_source () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "nosandbox" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
goal = "missing sandbox profile"
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  match Store.read_effective_meta config name with
  | Ok _ -> Alcotest.fail "expected missing sandbox_profile to fail loudly"
  | Error err ->
      Alcotest.(check bool)
        "error names missing sandbox_profile"
        true
        (contains_substring ~needle:"sandbox_profile is required" err)

let test_keeper_up_rejects_profile_source_without_sandbox_profile () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "nosandboxup" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
goal = "missing sandbox profile"
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let ctx : _ Profile.context =
    {
      config;
      agent_name = "test-agent";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = None;
      net = None;
    }
  in
  let result = Turn.handle_keeper_up ctx (`Assoc [ ("name", `String name) ]) in
  if Profile.tool_result_success result then
    Alcotest.fail "keeper_up should reject TOML profile without sandbox_profile";
  Alcotest.(check bool)
    "keeper_up error names missing sandbox_profile"
    true
    (contains_substring
       ~needle:"sandbox_profile is required"
       (Profile.tool_result_body result))

let test_keeper_up_rejects_missing_profile_source () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir:_ ->
  let name = "nosourceup" in
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let ctx : _ Profile.context =
    {
      config;
      agent_name = "test-agent";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = None;
      net = None;
    }
  in
  let result = Turn.handle_keeper_up ctx (`Assoc [ ("name", `String name) ]) in
  if Profile.tool_result_success result then
    Alcotest.fail "keeper_up should reject missing TOML/persona source";
  Alcotest.(check bool)
    "keeper_up missing source error names sandbox_profile"
    true
    (contains_substring
       ~needle:"sandbox_profile is required"
       (Profile.tool_result_body result))

let test_missing_profile_source_fails_loud () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir:_ ->
  let name = "nosource" in
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  match Store.read_effective_meta config name with
  | Ok _ -> Alcotest.fail "expected absent TOML/persona source to fail loudly"
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
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
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

let test_status_surfaces_chat_queue_runtime () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "chatqueue-status" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"local" ~goal:"chat queue status";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  Eio_main.run @@ fun _env ->
  (* Mirror production: the status handler runs under [Eio_main.run] with the
     guard enabled (bin/main_eio.ml), so the durable queue snapshot is read.
     Disable on exit so other (non-Eio) cases keep reporting [`Null]. *)
  Eio_guard.enable ();
  Masc.Keeper_chat_queue.For_testing.reset ();
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_chat_queue.For_testing.reset ();
      Eio_guard.disable ())
    (fun () ->
      let report =
        Masc.Keeper_chat_queue.configure_persistence ~config
      in
      Alcotest.(check int)
        "queue persistence config has no load errors"
        0
        (List.length report.load_errors);
      (match
         Masc.Keeper_chat_queue.enqueue
           ~keeper_name:name
           {
             Masc.Keeper_chat_queue.content = "queued status probe";
             user_blocks = [];
             attachments = [];
             timestamp = 1.0;
             source = Masc.Keeper_chat_queue.Dashboard;
             transcript_context = None;
             transcript_ownership = Masc.Keeper_chat_queue.Queue_owned;
           }
       with
       | Ok _receipt -> ()
       | Error err ->
           Alcotest.failf "queue enqueue failed: %s"
             (Masc.Keeper_chat_queue.mutation_error_to_string err));
      let status_json = status_json_with ~name config in
      let chat_queue = json_assoc_field "chat_queue" status_json in
      Alcotest.(check (option int))
        "status exposes pending chat queue depth"
        (Some 1)
        (json_int_field "pending_messages" chat_queue);
      Alcotest.(check (option bool))
        "status exposes durable chat queue replay flag"
        (Some true)
        (json_bool_field "durable_replay_enabled" chat_queue))

let test_keeper_list_row_surfaces_effective_meta_errors () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "badprofile" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
goal = "missing sandbox profile"
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  match Keeper_tool_surface_ops.keeper_list_row_json ~runtime_class:"keeper" config name with
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

let test_keeper_list_error_row_preserves_keepalive_state () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "badprofile-running" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
goal = "missing sandbox profile"
|};
  let config = Workspace.default_config base in
  let meta = seed_runtime_meta config name in
  Masc.Keeper_registry.clear ();
  ignore (Masc.Keeper_registry.register ~base_path:config.base_path meta.name meta);
  Fun.protect
    ~finally:Masc.Keeper_registry.clear
    (fun () ->
      match Keeper_tool_surface_ops.keeper_list_row_json ~runtime_class:"keeper" config name with
      | None -> Alcotest.fail "expected error row for invalid effective meta"
      | Some row ->
          Alcotest.(check (option bool))
            "error row keeps live keepalive state"
            (Some true)
            (json_bool_field "keepalive_running" row))

let test_sandbox_status_fleet_surfaces_effective_meta_errors () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "badfleet-running" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
goal = "missing sandbox profile"
|};
  let config = Workspace.default_config base in
  let meta = seed_runtime_meta config name in
  Masc.Keeper_registry.clear ();
  ignore (Masc.Keeper_registry.register ~base_path:config.base_path meta.name meta);
  Fun.protect
    ~finally:Masc.Keeper_registry.clear
    (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let ctx : _ Keeper_tool_surface.context =
        {
          config;
          agent_name = "test-agent";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = None;
          net = None;
        }
      in
      match
        Keeper_tool_surface.dispatch ctx ~name:"masc_keeper_sandbox_status" ~args:(`Assoc [])
      with
      | None -> Alcotest.fail "sandbox status tool was not dispatched"
      | Some result ->
          if not (Profile.tool_result_success result) then
            Alcotest.failf "sandbox status failed: %s" (Profile.tool_result_body result);
          let json = Yojson.Safe.from_string (Profile.tool_result_body result) in
          let items =
            match json_field "items" json with
            | Some (`List items) -> items
            | _ -> Alcotest.fail "sandbox status response missing items"
          in
          let row =
            match
              List.find_opt
                (fun item -> json_string_field "keeper" item = Some name)
                items
            with
            | Some row -> row
            | None -> Alcotest.fail "expected bad keeper error row in fleet items"
          in
          Alcotest.(check (option string))
            "fleet row status is error"
            (Some "error")
            (json_string_field "status" row);
          Alcotest.(check (option bool))
            "fleet error row keeps live keepalive state"
            (Some true)
            (json_bool_field "keepalive_running" row);
          match json_field "effective_meta_error" row with
          | Some (`Assoc _) -> ()
          | _ -> Alcotest.fail "fleet error row missing effective_meta_error")

let () =
  init_runtime_default_for_tests ();
  Alcotest.run "keeper_effective_meta_overlay"
    [
      ( "effective_meta",
        [
          Alcotest.test_case "TOML sandbox/tool overlay reaches effective meta"
            `Quick test_toml_overlay_reaches_effective_meta;
          Alcotest.test_case
            "profile identity snapshot reaches meta JSON"
            `Quick test_profile_identity_snapshot_reaches_meta_json;
          Alcotest.test_case
            "ensure keeper meta persists TOML identity snapshot"
            `Quick test_ensure_keeper_meta_persists_toml_identity_snapshot;
          Alcotest.test_case "status resolves keeper alias names" `Quick
            test_status_resolves_keeper_alias_names;
          Alcotest.test_case "keeper surface resolves alias names" `Quick
            test_keeper_surface_resolves_alias_names;
          Alcotest.test_case "turn setup uses effective meta" `Quick
            test_turn_setup_uses_effective_meta;
          Alcotest.test_case
            "keepalive meta selection overlays disk meta"
            `Quick test_keepalive_meta_selection_overlays_disk_meta;
          Alcotest.test_case
            "profile source without sandbox_profile fails loudly"
            `Quick test_missing_sandbox_profile_fails_loud_for_profile_source;
          Alcotest.test_case
            "keeper_up rejects profile source without sandbox_profile"
            `Quick test_keeper_up_rejects_profile_source_without_sandbox_profile;
          Alcotest.test_case "keeper_up rejects missing profile source" `Quick
            test_keeper_up_rejects_missing_profile_source;
          Alcotest.test_case
            "missing profile source fails loudly"
            `Quick test_missing_profile_source_fails_loud;
          Alcotest.test_case "status cache tracks TOML overlay edits" `Quick
            test_status_cache_tracks_toml_overlay_changes;
          Alcotest.test_case "status surfaces chat queue runtime" `Quick
            test_status_surfaces_chat_queue_runtime;
          Alcotest.test_case "keeper list surfaces effective meta errors"
            `Quick test_keeper_list_row_surfaces_effective_meta_errors;
          Alcotest.test_case
            "keeper list error row preserves keepalive state"
            `Quick test_keeper_list_error_row_preserves_keepalive_state;
          Alcotest.test_case
            "sandbox status fleet surfaces effective meta errors"
            `Quick test_sandbox_status_fleet_surfaces_effective_meta_errors;
        ] );
    ]
