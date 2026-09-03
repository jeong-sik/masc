module Workspace = Masc.Workspace
module Store = Masc.Keeper_meta_store
module Profile = Masc.Keeper_types_profile
module Keeper_schema = Masc.Keeper_schema
module Status_detail = Masc.Keeper_status_detail
module Status_options_defaults = Masc.Keeper_status_options_defaults
module Turn_setup = Masc.Keeper_turn_setup
module Turn = Masc.Keeper_turn
module Keeper_tool_surface = Masc.Keeper_tool_surface
module Keeper_tool_surface_ops = Masc.Keeper_tool_surface_ops
module Heartbeat_presence = Masc.Keeper_heartbeat_loop_presence
module Turn_up_args = Masc.Keeper_turn_up_args
module Turn_up_config = Masc.Keeper_turn_up_config_persistence
(* [Runtime] (init_default) lives in the unwrapped [masc_runtime] library, so it
   is referenced directly (not via [Masc.]); [Keeper_runtime] (ensure_keeper_meta)
   lives in the main [masc] library. Same pattern as test_keeper_lifecycle_registry_dispatch. *)
module Keeper_runtime = Masc.Keeper_runtime
module Pre_dispatch = Masc.Keeper_unified_turn_pre_dispatch
module Sandbox_control = Masc.Keeper_sandbox_control

let with_owner_inventory config f =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  (match Masc.Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
   | Ok _ -> ()
   | Error error ->
     Alcotest.fail (Masc.Keeper_owner_registry.install_error_to_string error));
  f ()
;;

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
        ("trace_id", `String ("trace-" ^ name));
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Error err -> Alcotest.fail err
  | Ok meta -> (
      match Store.replace_snapshot config meta with
      | Ok () -> meta
  | Error err -> Alcotest.failf "write_meta failed: %s" err)

let write_keeper_toml ~keepers_dir ~name ~sandbox_profile ~instructions =
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    (Printf.sprintf
       {|[keeper]
sandbox_profile = "%s"
instructions = %S
|}
       sandbox_profile
       instructions)

let write_keeper_agent ~keepers_dir ~name instructions =
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"docker" ~instructions

let status_instructions_with ?(agent_name = "test-agent") ?name config =
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
  match json_string_field "instructions" json with
  | Some instructions -> instructions
  | None -> Alcotest.fail "status response missing instructions"

let status_instructions config name = status_instructions_with ~name config

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

let status_json_with_args config args =
  let result =
    Status_detail.handle_keeper_status_config
      ~config
      ~agent_name:"test-agent"
      args
  in
  if not (Profile.tool_result_success result) then
    Alcotest.failf "status failed: %s" (Profile.tool_result_body result);
  Yojson.Safe.from_string (Profile.tool_result_body result)

let status_result_with_args config args =
  Status_detail.handle_keeper_status_config
    ~config
    ~agent_name:"test-agent"
    args

let resolved_keeper_name config name =
  match
    Keeper_tool_surface_ops.resolve_keeper_name_config
      ~config
      (`Assoc [ ("name", `String name) ])
  with
  | Ok resolved -> resolved
  | Error err -> Alcotest.failf "resolve_keeper_name_config failed: %s" err

(* RFC-0371 B4: typed existence for the channel-gate routes. Pins that the
   new keeper_exists_config answers through the same candidate spellings as
   the status resolver, and that unknown and invalid names are a typed
   [Ok false] — the answer the removed "keeper not found" substring
   classifier used to reverse-engineer out of a rendered error. *)
let test_keeper_exists_config_answers_typed () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "existsprobe" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"docker"
    ~instructions:"exists probe instructions";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  let exists raw =
    match Status_detail.keeper_exists_config ~config raw with
    | Ok value -> value
    | Error err -> Alcotest.failf "keeper_exists_config failed: %s" err
  in
  Alcotest.(check bool) "canonical name exists" true (exists name);
  Alcotest.(check bool)
    "the wrapper spelling is not the keeper (RFC-0393)"
    false
    (exists "keeper-existsprobe-agent");
  Alcotest.(check bool) "unknown name is Ok false" false (exists "no-such-keeper");
  Alcotest.(check bool)
    "invalid name is Ok false, not an error"
    false
    (exists "not/a valid;name")

(* RFC-0393: the keeper name is the only spelling a status/surface call
   understands — wrapper forms are ordinary (unknown) names. *)
let test_status_reads_the_keeper_name_only () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "aliasprobe" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"docker"
    ~instructions:"alias status instructions";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  Alcotest.(check string)
    "the keeper name reaches its instructions"
    "alias status instructions"
    (status_instructions_with ~name config)

let test_keeper_surface_uses_the_name_verbatim () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "aliasmsg" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"docker"
    ~instructions:"verbatim keeper surface";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  Alcotest.(check string)
    "the keeper name resolves for keeper surface tools"
    name
    (resolved_keeper_name config name)

let test_toml_overlay_reaches_effective_meta () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "delta" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "Analyze carefully."
sandbox_profile = "docker"
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
        (Profile.network_mode_to_string meta.network_mode)

let test_sandbox_log_target_uses_effective_meta () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "microvm-logs" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"microvm"
    ~instructions:"Read the effective log backend.";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  match Sandbox_control.resolve_sandbox_log_target ~config ~keeper_name:name with
  | Error Sandbox_control.Sandbox_logs_keeper_not_found ->
    Alcotest.fail "expected seeded keeper meta"
  | Error (Sandbox_control.Sandbox_logs_meta_read_failed detail)
  | Error (Sandbox_control.Sandbox_logs_backend_failed detail) ->
    Alcotest.failf "sandbox log target resolution failed: %s" detail
  | Ok (Sandbox_control.Local_backend Sandbox_control.Docker_logs, _) ->
    Alcotest.fail "durable meta placeholder selected Docker for a microvm Keeper"
  | Ok (Sandbox_control.No_local_stream reason, _) ->
    Alcotest.failf "microvm Keeper reported no local stream: %s" reason
  | Ok
      ( Sandbox_control.Local_backend Sandbox_control.Apple_container_logs,
        effective_name ) ->
    Alcotest.(check string) "effective keeper name" name effective_name

(* A remote_ssh Keeper owns no container here. That is the profile working as
   declared, so resolution answers a source rather than an error: the route
   that reads it must be able to say 200. *)
let test_sandbox_log_target_reports_no_local_stream_for_remote_ssh () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "remote-logs" in
  (* [write_keeper_toml] writes no [remote_endpoint], and config load rejects a
     remote_ssh keeper without one, so the TOML is written out here. *)
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
sandbox_profile = "remote_ssh"
remote_endpoint = "test-endpoint"
instructions = "Run on the endpoint."
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  match Sandbox_control.resolve_sandbox_log_target ~config ~keeper_name:name with
  | Error Sandbox_control.Sandbox_logs_keeper_not_found ->
    Alcotest.fail "expected seeded keeper meta"
  | Error (Sandbox_control.Sandbox_logs_meta_read_failed detail)
  | Error (Sandbox_control.Sandbox_logs_backend_failed detail) ->
    Alcotest.failf "remote_ssh log target resolution failed: %s" detail
  | Ok (Sandbox_control.Local_backend _, _) ->
    Alcotest.fail "remote_ssh selected a local container backend"
  | Ok (Sandbox_control.No_local_stream reason, effective_name) ->
    Alcotest.(check string) "effective keeper name" name effective_name;
    Alcotest.(check string) "operator is told where the logs are"
      "This Keeper runs on its configured SSH endpoint, so no container log \
       stream exists on this host; read the logs on the endpoint."
      reason

(* The direct-turn path holds profile defaults it loaded once and overlays with
   them, rather than re-reading the profile per use: two reads inside one turn
   could otherwise disagree. That is why the overlay is reachable on its own and
   not only through [effective_meta_result], which loads and applies together.

   Persisted runtime meta omits TOML-owned fields, so a turn reading it raw sees
   the wrong sandbox — the overlay is what makes the turn's meta effective. *)
let test_profile_defaults_overlay_applies_without_reloading () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "overlay-once" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "Analyze carefully."
sandbox_profile = "docker"
|};
  let config = Workspace.default_config base in
  let persisted = seed_runtime_meta config name in
  match Profile.load_keeper_profile_defaults_result_for_base_path ~base_path:base name with
  | Error error ->
    Alcotest.failf
      "profile defaults load failed: %s"
      (Profile.keeper_toml_load_error_to_string error)
  | Ok defaults ->
    (match
       Masc.Keeper_meta_contract.effective_meta_of_profile_defaults defaults persisted
     with
     | Error error -> Alcotest.failf "overlay failed: %s" error
     | Ok effective ->
       Alcotest.(check string)
         "overlay carries the TOML sandbox onto persisted meta"
         "docker"
         (Profile.sandbox_profile_to_string effective.sandbox_profile);
       (* The same defaults applied twice must land on the same meta: the turn
          reuses one load, so the overlay cannot depend on when it runs. *)
       (match
          Masc.Keeper_meta_contract.effective_meta_of_profile_defaults defaults persisted
        with
        | Error error -> Alcotest.failf "second overlay failed: %s" error
        | Ok again ->
          Alcotest.(check string)
            "reapplying the same defaults is stable"
            (Profile.sandbox_profile_to_string effective.sandbox_profile)
            (Profile.sandbox_profile_to_string again.sandbox_profile)))
;;

let test_keeper_instructions_reach_meta_json () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "probe" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "keeper instructions"
sandbox_profile = "docker"
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  match Store.read_effective_meta config name with
  | Error err -> Alcotest.failf "read_effective_meta failed: %s" err
  | Ok None -> Alcotest.fail "expected seeded keeper meta"
  | Ok (Some meta) ->
      Alcotest.(check string)
        "instructions overlay from Keeper AGENT"
        "keeper instructions"
        meta.instructions;
      let json = Masc.Keeper_meta_json.meta_to_json meta in
      Alcotest.(check (option string))
        "meta json keeps instructions snapshot"
        (Some "keeper instructions")
        (json_string_field "instructions" json);
      (match Masc.Keeper_meta_json.meta_of_json json with
       | Error err -> Alcotest.failf "meta json roundtrip failed: %s" err
       | Ok roundtrip ->
         Alcotest.(check string)
           "roundtrip keeps instructions"
           "keeper instructions"
           roundtrip.instructions);
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
        "status keeps instructions snapshot"
        (Some "keeper instructions")
        (json_string_field "instructions" status_json)

let test_ensure_keeper_meta_persists_toml_identity_snapshot () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "omicron-improver" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "Improve MASC autonomously"
sandbox_profile = "docker"
proactive_enabled = true
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
      instructions = "stale instructions";
      proactive = { enabled = false };
    }
  in
  (match Store.replace_snapshot config stale with
   | Ok () -> ()
   | Error err -> Alcotest.failf "write stale meta failed: %s" err);
  let returned =
    with_owner_inventory config (fun () ->
      match Keeper_runtime.ensure_keeper_meta config name with
      | Ok meta -> meta
      | Error err -> Alcotest.failf "ensure_keeper_meta failed: %s" err)
  in
  let disk_json = Yojson.Safe.from_file (Profile.keeper_meta_path config name) in
  let leaked_config_keys =
    match disk_json with
    | `Assoc fields ->
      fields
      |> List.filter_map (fun (key, _) ->
        if List.mem key Masc.Keeper_meta_json.current_field_names
        then None
        else Some key)
    | _ -> Alcotest.fail "expected keeper meta JSON object"
  in
  Alcotest.(check (list string))
    "disk meta contains only current fields"
    []
    leaked_config_keys;
  Alcotest.(check string)
    "returned instructions are TOML canonical"
    "Improve MASC autonomously"
    returned.instructions;
  Alcotest.(check bool)
    "returned proactive enabled is TOML canonical"
    true
    returned.proactive.enabled;
  Alcotest.(check string)
    "returned sandbox_profile is TOML canonical"
    "docker"
    (Profile.sandbox_profile_to_string returned.sandbox_profile);
  ()

let test_ensure_keeper_meta_preserves_live_usage_during_reconcile () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "reconcile-live-usage" in
  write_keeper_agent ~keepers_dir ~name "fresh instructions";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  let persisted =
    match Store.read_meta config name with
    | Ok (Some meta) -> meta
    | Ok None -> Alcotest.fail "expected seeded keeper meta"
    | Error err -> Alcotest.failf "read_meta failed: %s" err
  in
  let stale = { persisted with instructions = "stale instructions" } in
  (match Store.replace_snapshot config stale with
   | Ok () -> ()
   | Error err -> Alcotest.failf "write stale meta failed: %s" err);
  Masc.Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:Masc.Keeper_registry.For_testing.clear
    (fun () ->
      ignore (Masc.Keeper_registry.For_testing.register ~base_path:config.base_path name stale);
      let reconciled =
        with_owner_inventory config (fun () ->
          (match
             Masc.Keeper_owner_registry.apply_meta
               ~base_path:config.base_path
               ~keeper_name:name
               (Masc.Keeper_owner_reducer.Add_usage
                  { turns = 0
                  ; input_tokens = 0
                  ; output_tokens = 0
                  ; total_tokens = 0
                  ; cost_usd = 0.0
                  ; last_turn_ts = stale.runtime.usage.last_turn_ts
                  ; last_input_tokens = 123
                  ; last_output_tokens = 4
                  ; last_total_tokens = 127
                  ; last_usage_reported_at = Some 1_700_000_000.0
                  ; last_latency_ms = stale.runtime.usage.last_latency_ms
                  })
           with
           | Ok (Some _) -> ()
           | Ok None -> Alcotest.fail "owner usage commit removed metadata"
           | Error error ->
             Alcotest.fail
               (Masc.Keeper_owner_registry.command_error_to_string error));
          match Keeper_runtime.ensure_keeper_meta config name with
          | Ok meta -> meta
          | Error err -> Alcotest.failf "ensure_keeper_meta failed: %s" err)
      in
      Alcotest.(check int)
        "reconcile result preserves live observed input"
        123
        reconciled.runtime.usage.last_input_tokens;
      match Masc.Keeper_registry.get ~base_path:config.base_path name with
      | Some entry ->
        Alcotest.(check string)
          "reconcile installs fresh instructions"
          "fresh instructions"
          entry.meta.instructions;
        Alcotest.(check int)
          "reconcile preserves live observed input"
          123
          entry.meta.runtime.usage.last_input_tokens;
        Alcotest.(check (option (float 0.0)))
          "reconcile preserves live observation timestamp"
          (Some 1_700_000_000.0)
          entry.meta.runtime.usage.last_usage_reported_at
      | None -> Alcotest.fail "expected registered keeper after reconcile")

let test_turn_setup_uses_effective_meta () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "turnsetup" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "Prepare the turn."
sandbox_profile = "docker"
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
      publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider;
    }
  in
  match Turn_setup.ensure_keeper_exists ~ctx ~name with
  | Error err -> Alcotest.failf "ensure_keeper_exists failed: %s" err
  | Ok meta ->
      Alcotest.(check string)
        "turn setup sees TOML sandbox overlay"
        "docker"
        (Profile.sandbox_profile_to_string meta.sandbox_profile)

let test_keepalive_meta_selection_overlays_disk_meta () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "fixture-keeper" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "Coordinate the work."
sandbox_profile = "docker"
network_mode = "inherit"
|};
  let config = Workspace.default_config base in
  let raw_meta = seed_runtime_meta config name in
  Alcotest.(check string)
    "fixture raw meta starts from persisted/default sandbox"
    "local"
    (Profile.sandbox_profile_to_string raw_meta.sandbox_profile);
  let observed_meta =
    {
      raw_meta with
      runtime =
        {
          raw_meta.runtime with
          usage =
            {
              raw_meta.runtime.usage with
              last_input_tokens = 123;
              last_output_tokens = 4;
              last_total_tokens = 127;
              last_usage_reported_at = Some 1_700_000_000.0;
            };
        };
    }
  in
  Masc.Keeper_registry.For_testing.clear ();
  ignore
    (Masc.Keeper_registry.For_testing.register
       ~base_path:config.base_path
       name
       observed_meta);
  Fun.protect
    ~finally:Masc.Keeper_registry.For_testing.clear
    (fun () ->
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
        (Profile.network_mode_to_string effective.network_mode);
      Alcotest.(check int)
        "disk refresh preserves process-local observed input"
        123
        effective.runtime.usage.last_input_tokens;
      Alcotest.(check (option (float 0.0)))
        "disk refresh preserves process-local observation timestamp"
        (Some 1_700_000_000.0)
        effective.runtime.usage.last_usage_reported_at)

let test_missing_sandbox_profile_fails_loud_for_profile_source () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "nosandbox" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "Missing sandbox profile"
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  match Store.read_effective_meta config name with
  | Ok _ -> Alcotest.fail "expected missing sandbox_profile to fail loudly"
  | Error err ->
      Alcotest.(check bool)
        "error names missing sandbox_profile"
        true
        (String_util.string_contains_substring ~needle:"sandbox_profile is required" err)

let test_keeper_up_rejects_profile_source_without_sandbox_profile () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "nosandboxup" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "Missing sandbox profile"
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
      publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider;
    }
  in
  let result = Turn.handle_keeper_up ctx (`Assoc [ ("name", `String name) ]) in
  if Profile.tool_result_success result then
    Alcotest.fail "keeper_up should reject TOML profile without sandbox_profile";
  Alcotest.(check bool)
    "keeper_up error names missing sandbox_profile"
    true
    (String_util.string_contains_substring
       ~needle:"sandbox_profile is required"
       (Profile.tool_result_body result))

let test_keeper_up_materializes_missing_profile_source () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "nosourceup" in
  let config = Workspace.default_config base in
  let runtime_meta = seed_runtime_meta config name in
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
      publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider;
    }
  in
  let args =
    `Assoc
      [ "name", `String name
      ; "instructions", `String "durable direct instructions"
      ; "sandbox_profile", `String "docker"
      ; "mention_targets", `List [ `String "operator" ]
      ; "proactive_enabled", `Bool false
      ; "autoboot_enabled", `Bool false
      ; "max_context_override", `Int 128_001
      ]
  in
  let parsed =
    match Turn_up_args.parse ctx args with
    | Ok parsed -> parsed
    | Error result ->
      Alcotest.failf "keeper_up args failed: %s" (Profile.tool_result_body result)
  in
  let meta =
    { runtime_meta with
      instructions = "durable direct instructions"
    ; sandbox_profile = Profile.Docker
    ; mention_targets = [ "operator" ]
    ; proactive = { enabled = false }
    ; autoboot_enabled = false
    ; max_context_override = Some 128_001
    }
  in
  let expected_revision =
    match Turn_up_config.current_config_revision ~config ~keeper_name:name with
    | Ok revision -> revision
    | Error error ->
      Alcotest.failf "keeper config revision read failed: %s" error
  in
  (match Turn_up_config.persist ~expected_revision ~config ~parsed ~meta () with
   | Ok _ -> ()
   | Error error ->
     Alcotest.failf "keeper config persistence failed: %s"
       (Turn_up_config.error_to_string error));
  let toml_path = Filename.concat keepers_dir (name ^ ".toml") in
  Alcotest.(check bool) "keeper TOML created" true (Sys.file_exists toml_path);
  match Profile.load_keeper_toml toml_path with
  | Error error ->
    Alcotest.failf "created TOML failed to load: %s"
      (Profile.keeper_toml_load_error_to_string error)
  | Ok (_, defaults) ->
    Alcotest.(check (option bool))
      "proactive persisted"
      (Some false)
      defaults.proactive_enabled;
    Alcotest.(check (option bool))
      "autoboot persisted"
      (Some false)
      defaults.autoboot_enabled;
    Alcotest.(check (option int))
      "context override persisted"
      (Some 128_001)
      defaults.max_context_override;
    ()

let test_missing_profile_source_rejects_implicit_local () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir:_ ->
  let name = "nosource" in
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  match Store.read_effective_meta config name with
  | Error err ->
    Alcotest.(check bool)
      "missing declaration cannot silently select the host playground"
      true
      (String_util.string_contains_substring
         ~needle:"local playground is off"
         err)
  | Ok None -> Alcotest.fail "seeded keeper meta disappeared"
  | Ok (Some _) -> Alcotest.fail "missing profile source admitted implicit local"

let test_status_tracks_toml_overlay_changes () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "statuscache" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"docker"
    ~instructions:"first cache instructions";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  Alcotest.(check string)
    "initial TOML instructions reach status"
    "first cache instructions"
    (status_instructions config name);
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"docker"
    ~instructions:"second cache instructions after toml edit";
  Alcotest.(check string)
    "TOML edit invalidates cached status"
    "second cache instructions after toml edit"
    (status_instructions config name)

let test_status_reports_normalized_options () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "status-options-cache" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"docker"
    ~instructions:"normalized status options";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  let common_fields =
    [ "name", `String name
    ; "fast", `Bool false
    ; "include_metrics_overview", `Bool false
    ; "include_history_tail", `Bool false
    ]
  in
  let context_enabled = status_json_with_args config (`Assoc common_fields) in
  let default_options = json_assoc_field "status_options" context_enabled in
  Alcotest.(check (option int))
    "tail turns runtime default"
    (Some Masc.Keeper_status_options_defaults.tail_turns)
    (json_int_field "tail_turns" default_options);
  Alcotest.(check (option int))
    "tail messages runtime default"
    (Some Masc.Keeper_status_options_defaults.tail_messages)
    (json_int_field "tail_messages" default_options);
  Alcotest.(check (option int))
    "tail bytes runtime default"
    (Some Masc.Keeper_status_options_defaults.tail_bytes)
    (json_int_field "tail_bytes" default_options);
  Alcotest.(check (option bool))
    "derived include_context default is true"
    (Some true)
    (json_assoc_field "status_options" context_enabled
     |> json_bool_field "include_context");
  let context_disabled =
    status_json_with_args config
      (`Assoc (("include_context", `Bool false) :: common_fields))
  in
  Alcotest.(check (option bool))
    "explicit include_context false is reported"
    (Some false)
    (json_assoc_field "status_options" context_disabled
     |> json_bool_field "include_context");
  Alcotest.(check (option bool))
    "disabled context is observable"
    (Some true)
    (json_assoc_field "context" context_disabled |> json_bool_field "skipped");
  let first_window =
    status_json_with_args config
      (`Assoc
        [ "name", `String name
        ; "fast", `Bool true
        ; ( "tail_bytes"
          , `Int Masc.Keeper_status_options_defaults.min_tail_bytes )
        ])
  in
  let first_options = json_assoc_field "status_options" first_window in
  Alcotest.(check (option int))
    "minimum tail bytes is preserved"
    (Some Masc.Keeper_status_options_defaults.min_tail_bytes)
    (json_int_field "tail_bytes" first_options);
  let second_window =
    status_json_with_args config
      (`Assoc
        [ "name", `String name
        ; "fast", `Bool true
        ; "tail_bytes", `Int 8_000
        ])
  in
  let second_options = json_assoc_field "status_options" second_window in
  Alcotest.(check (option int))
    "tail byte window is reported"
    (Some 8_000)
    (json_int_field "tail_bytes" second_options)

let test_status_rejects_tail_order_outside_schema () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "status-tail-order" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"docker"
    ~instructions:"strict tail order";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  let result =
    status_result_with_args config
      (`Assoc
        [ "name", `String name
        ; "fast", `Bool true
        ; "tail_order", `String "desc"
        ])
  in
  Alcotest.(check bool)
    "unadvertised alias is rejected"
    false
    (Profile.tool_result_success result);
  Alcotest.(check bool)
    "error names exact allowed values"
    true
    (String_util.string_contains_substring
       ~needle:"allowed: oldest_first, newest_first"
       (Profile.tool_result_body result))

let test_status_rejects_malformed_options () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "status-malformed-options" in
  write_keeper_toml
    ~keepers_dir
    ~name
    ~sandbox_profile:"docker"
    ~instructions:"strict status options";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  let check_rejected label args needle =
    let result = status_result_with_args config args in
    Alcotest.(check bool)
      (label ^ " fails")
      false
      (Profile.tool_result_success result);
    Alcotest.(check bool)
      (label ^ " explains the rejected field")
      true
      (String_util.string_contains_substring ~needle (Profile.tool_result_body result))
  in
  check_rejected
    "tail bytes below schema minimum"
    (`Assoc
      [ "name", `String name
      ; ( "tail_bytes"
        , `Int (Masc.Keeper_status_options_defaults.min_tail_bytes - 1) )
      ])
    "tail_bytes\" must be at least";
  check_rejected
    "negative tail turns"
    (`Assoc [ "name", `String name; "tail_turns", `Int (-1) ])
    "tail_turns\" must be at least";
  check_rejected
    "tail turns above schema maximum"
    (`Assoc
      [ "name", `String name
      ; ( "tail_turns"
        , `Int (Masc.Keeper_status_options_defaults.max_tail_turns + 1) )
      ])
    "tail_turns\" must be at most";
  check_rejected
    "tail bytes above schema maximum"
    (`Assoc
      [ "name", `String name
      ; ( "tail_bytes"
        , `Int (Masc.Keeper_status_options_defaults.max_tail_bytes + 1) )
      ])
    "tail_bytes\" must be at most";
  check_rejected
    "string tail messages"
    (`Assoc [ "name", `String name; "tail_messages", `String "10" ])
    "tail_messages\" must be an integer";
  check_rejected
    "integer fast flag"
    (`Assoc [ "name", `String name; "fast", `Int 1 ])
    "fast\" must be a boolean";
  check_rejected
    "non-string tail order"
    (`Assoc [ "name", `String name; "tail_order", `Bool true ])
    "tail_order\" must be a string";
  check_rejected
    "non-string keeper name"
    (`Assoc [ "name", `Int 7 ])
    "name\" must be a string";
  check_rejected
    "non-object arguments"
    (`List [])
    "must be a JSON object";
  check_rejected
    "unknown argument"
    (`Assoc [ "name", `String name; "mystery", `Bool true ])
    "unknown keeper_status argument \"mystery\"";
  check_rejected
    "duplicate known argument"
    (`Assoc
      [ "name", `String name
      ; "fast", `Bool true
      ; "fast", `Bool false
      ])
    "argument \"fast\" must occur at most once";
  check_rejected
    "blank keeper name"
    (`Assoc [ "name", `String " " ])
    "argument \"name\" must not be blank";
  check_rejected
    "blank tail order"
    (`Assoc
      [ "name", `String name
      ; "tail_order", `String " "
      ])
    "invalid tail_order";
  check_rejected
    "padded tail order"
    (`Assoc
      [ "name", `String name
      ; "tail_order", `String " oldest_first "
      ])
    "invalid tail_order"

let test_status_schema_tracks_argument_contract () =
  let schema =
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) ->
        String.equal schema.name "masc_keeper_status")
      Keeper_schema.schemas
    |> Option.get
  in
  let properties =
    match json_field "properties" schema.input_schema with
    | Some (`Assoc fields) -> List.map fst fields
    | _ -> Alcotest.fail "keeper_status schema has no object properties"
  in
  Alcotest.(check (list string))
    "schema properties use the runtime argument SSOT"
    (List.sort String.compare Status_options_defaults.Argument.all)
    (List.sort String.compare properties);
  Alcotest.(check (option bool))
    "schema rejects unknown properties"
    (Some false)
    (json_bool_field "additionalProperties" schema.input_schema);
  let tail_order_values =
    match
      List.assoc_opt
        Status_options_defaults.Argument.tail_order
        (match json_field "properties" schema.input_schema with
         | Some (`Assoc fields) -> fields
         | _ -> [])
    with
    | Some (`Assoc fields) ->
        (match List.assoc_opt "enum" fields with
         | Some (`List values) ->
             List.filter_map
               (function
                 | `String value -> Some value
                 | _ -> None)
               values
         | _ -> [])
    | _ -> []
  in
  Alcotest.(check (list string))
    "tail order schema follows the typed variants"
    Status_detail.valid_tail_order_strings
    tail_order_values;
  let properties =
    match json_field "properties" schema.input_schema with
    | Some (`Assoc fields) -> fields
    | _ -> []
  in
  let schema_maximum argument =
    match List.assoc_opt argument properties with
    | Some (`Assoc fields) ->
        (match List.assoc_opt "maximum" fields with
         | Some (`Int value) -> Some value
         | _ -> None)
    | _ -> None
  in
  Alcotest.(check (option int))
    "tail turns schema maximum follows runtime SSOT"
    (Some Status_options_defaults.max_tail_turns)
    (schema_maximum Status_options_defaults.Argument.tail_turns);
  Alcotest.(check (option int))
    "tail bytes schema maximum follows runtime SSOT"
    (Some Status_options_defaults.max_tail_bytes)
    (schema_maximum Status_options_defaults.Argument.tail_bytes)

let test_status_tracks_persisted_meta_without_updated_at () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "status-persisted-meta-cache" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"docker"
    ~instructions:"persisted meta cache";
  let config = Workspace.default_config base in
  let meta = seed_runtime_meta config name in
  let initial = status_json_with ~name config in
  Alcotest.(check (option bool))
    "initial status is active"
    (Some false)
    (json_assoc_field "meta" initial |> json_bool_field "paused");
  let paused = { meta with paused = true } in
  write_file
    (Profile.keeper_meta_path config name)
    (Masc.Keeper_meta_json.meta_to_json paused |> Yojson.Safe.to_string);
  let refreshed = status_json_with ~name config in
  Alcotest.(check (option bool))
    "persisted paused change is observed without updated_at change"
    (Some true)
    (json_assoc_field "meta" refreshed |> json_bool_field "paused")

let test_status_reads_live_registry_each_call () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "status-live-registry" in
  write_keeper_toml
    ~keepers_dir
    ~name
    ~sandbox_profile:"docker"
    ~instructions:"live registry observation";
  let config = Workspace.default_config base in
  let meta = seed_runtime_meta config name in
  Masc.Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:Masc.Keeper_registry.For_testing.clear
    (fun () ->
      ignore
        (Masc.Keeper_registry.For_testing.register
           ~base_path:config.base_path
           name
           meta);
      let status () =
        status_json_with_args config
          (`Assoc [ "name", `String name; "fast", `Bool true ])
      in
      Masc.Keeper_registry.set_last_error_entry
        ~base_path:config.base_path
        ~name
        "first live error";
      Alcotest.(check (option string))
        "first registry observation"
        (Some "first live error")
        (json_string_field "keeper_last_error" (status ()));
      Masc.Keeper_registry.set_last_error_entry
        ~base_path:config.base_path
        ~name
        "second live error";
      Alcotest.(check (option string))
        "second registry observation is not frozen by a response cache"
        (Some "second live error")
        (json_string_field "keeper_last_error" (status ())))

let test_status_surfaces_chat_operation_runtime () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "chat-operation-status" in
  write_keeper_toml ~keepers_dir ~name ~sandbox_profile:"docker"
    ~instructions:"chat operation status";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  Eio_main.run @@ fun _env ->
  Eio_guard.enable ();
  Fun.protect
    ~finally:Eio_guard.disable
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      (match
         Masc.Keeper_owner_registry.install_from_store
           ~sw
           ~operation_runner:None
           ~on_turn_slot_released:None
           config
       with
       | Ok 1 -> ()
       | Ok count -> Alcotest.failf "expected one owner, got %d" count
       | Error error ->
         Alcotest.fail
           (Masc.Keeper_owner_registry.install_error_to_string error));
      let operation_id =
        match
          Masc.Keeper_owner.Chat_operation.Operation_id.of_string
            "kmsg-status-probe"
        with
        | Ok operation_id -> operation_id
        | Error detail -> Alcotest.fail detail
      in
      (match
         Masc.Keeper_owner_registry.submit_operation
           ~base_path:config.base_path
           ~keeper_name:name
           ~operation_id
           ~source:(`Assoc [ "kind", `String "dashboard" ])
           ~input:(`Assoc [ "message", `String "queued status probe" ])
       with
       | Ok acceptance ->
         Alcotest.(check string)
           "operation remains queued without an executor"
           "queued"
           (Masc.Keeper_owner.Chat_operation.state_to_string
              acceptance.operation.state)
       | Error error ->
         Alcotest.fail
           (Masc.Keeper_owner_registry.command_error_to_string error));
      let status_json = status_json_with ~name config in
      let chat_operations = json_assoc_field "chat_operations" status_json in
      Alcotest.(check (option int))
        "status exposes queued operation depth"
        (Some 1)
        (json_int_field "queued_count" chat_operations);
      Alcotest.(check (option bool))
        "status exposes owner projection availability"
        (Some true)
        (json_bool_field "snapshot_available" chat_operations))
let test_keeper_list_row_surfaces_effective_meta_errors () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "badprofile" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "Missing sandbox profile"
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

let test_config_snapshot_does_not_fallback_to_raw_meta () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "bad-config-snapshot" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "Missing sandbox profile"
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  match Dashboard_http_keeper_snapshot.keeper_config_json config name with
  | `Not_found, _ -> Alcotest.fail "expected a typed unavailable config snapshot"
  | `OK, json ->
    Alcotest.(check (option string))
      "snapshot preserves the raw keeper identity"
      (Some name)
      (json_string_field "name" json);
    Alcotest.(check bool)
      "effective config is explicitly unavailable"
      true
      (json_field "effective_config" json = Some `Null);
    Alcotest.(check bool)
      "raw sandbox defaults are not projected as effective"
      true
      (json_field "sandbox_profile" json = None);
    Alcotest.(check bool)
      "typed config error remains visible"
      true
      (match json_field "config_error" json with
       | Some (`Assoc _) -> true
       | Some _ | None -> false);
    Alcotest.(check bool)
      "raw source provenance remains visible"
      true
    (match json_field "sources" json with
     | Some (`Assoc _) -> true
     | Some _ | None -> false)

(* The effective-prompt render inside [keeper_config_json] walks board
   observation collection, which performs Eio effects — outside an Eio
   main loop it dies with [Effect.Unhandled (Cancel.Get_context)] instead
   of reaching the assertions. *)
let within_eio f =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let test_config_snapshot_prompt_is_nested_only () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  within_eio @@ fun () ->
  let name = "nested-prompt" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "nested instructions"
sandbox_profile = "docker"
|};
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  match Dashboard_http_keeper_snapshot.keeper_config_json config name with
  | `Not_found, _ -> Alcotest.fail "expected a keeper config snapshot"
  | `OK, json ->
    Alcotest.(check bool)
      "flat instructions are retired"
      true
      (json_field "instructions" json = None);
    Alcotest.(check bool)
      "flat effective prompt is retired"
      true
      (json_field "effective_system_prompt" json = None);
    (match json_field "prompt" json with
     | Some prompt ->
       Alcotest.(check (option string))
         "prompt owns instructions"
         (Some "nested instructions")
         (json_string_field "instructions" prompt);
       Alcotest.(check bool)
         "prompt owns effective system prompt"
         true
         (Option.is_some (json_string_field "effective_system_prompt" prompt))
     | None -> Alcotest.fail "config snapshot omitted prompt")

let test_keeper_list_error_row_preserves_keepalive_state () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "badprofile-running" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "Missing sandbox profile"
|};
  let config = Workspace.default_config base in
  let meta = seed_runtime_meta config name in
  Masc.Keeper_registry.For_testing.clear ();
  ignore (Masc.Keeper_registry.For_testing.register ~base_path:config.base_path meta.name meta);
  Fun.protect
    ~finally:Masc.Keeper_registry.For_testing.clear
    (fun () ->
      match Keeper_tool_surface_ops.keeper_list_row_json ~runtime_class:"keeper" config name with
      | None -> Alcotest.fail "expected error row for invalid effective meta"
      | Some row ->
          Alcotest.(check (option bool))
            "error row keeps live keepalive state"
            (Some true)
            (json_bool_field "keepalive_running" row))

(* The turn path's own entry point. Durable keeper JSON carries no config
   fields, so the raw store read below is [Local] no matter what the TOML says
   -- the assertion is that one call gets both the snapshot and a meta that
   already has it applied. Loading the snapshot without applying it ran every
   heartbeat turn's [Execute] on the host against a [docker] declaration
   (#30982). *)
let test_turn_profile_and_meta_applies_the_declared_profile () =
  with_config_dir @@ fun ~base ~config_dir:_ ~keepers_dir ->
  let name = "containment" in
  write_keeper_toml
    ~keepers_dir
    ~name
    ~sandbox_profile:"docker"
    ~instructions:"Stay in the container.";
  let config = Workspace.default_config base in
  ignore (seed_runtime_meta config name : Masc.Keeper_meta_contract.keeper_meta);
  let entry_meta =
    match Store.read_meta config name with
    | Ok (Some meta) -> meta
    | Ok None -> Alcotest.fail "expected seeded keeper meta"
    | Error err -> Alcotest.failf "read_meta failed: %s" err
  in
  Alcotest.(check string)
    "durable meta carries the decoder placeholder, not the declaration"
    "local"
    (Profile.sandbox_profile_to_string entry_meta.sandbox_profile);
  match
    Pre_dispatch.turn_profile_and_meta
      ~base_path:config.Workspace.base_path
      ~entry_meta
  with
  | Error err ->
    Alcotest.failf "turn_profile_and_meta failed: %s" (Agent_core.Error.to_string err)
  | Ok (defaults, meta) ->
    Alcotest.(check string)
      "the meta a turn runs with carries the declared profile"
      "docker"
      (Profile.sandbox_profile_to_string meta.sandbox_profile);
    Alcotest.(check (option string))
      "the snapshot returned alongside it declares the same profile"
      (Some "docker")
      (Option.map Profile.sandbox_profile_to_string defaults.sandbox_profile)
;;

let () =
  init_runtime_default_for_tests ();
  Alcotest.run "keeper_effective_meta_overlay"
    [
      ( "effective_meta",
        [
          Alcotest.test_case "TOML sandbox overlay reaches effective meta"
            `Quick test_toml_overlay_reaches_effective_meta;
          Alcotest.test_case
            "sandbox logs use the effective TOML profile"
            `Quick test_sandbox_log_target_uses_effective_meta;
          Alcotest.test_case
            "remote_ssh sandbox logs answer no local stream"
            `Quick test_sandbox_log_target_reports_no_local_stream_for_remote_ssh;
          Alcotest.test_case
            "turn_profile_and_meta applies the declared sandbox profile"
            `Quick test_turn_profile_and_meta_applies_the_declared_profile;
          Alcotest.test_case
            "profile-defaults overlay applies without reloading the profile"
            `Quick test_profile_defaults_overlay_applies_without_reloading;
          Alcotest.test_case "keeper_exists_config answers existence typed"
            `Quick test_keeper_exists_config_answers_typed;
          Alcotest.test_case
            "profile identity snapshot reaches meta JSON"
            `Quick test_keeper_instructions_reach_meta_json;
          Alcotest.test_case
            "ensure keeper meta persists TOML identity snapshot"
            `Quick test_ensure_keeper_meta_persists_toml_identity_snapshot;
          Alcotest.test_case
            "ensure keeper meta preserves live usage during reconcile"
            `Quick
            test_ensure_keeper_meta_preserves_live_usage_during_reconcile;
          Alcotest.test_case "status resolves keeper alias names" `Quick
            test_status_reads_the_keeper_name_only;
          Alcotest.test_case "keeper surface resolves alias names" `Quick
            test_keeper_surface_uses_the_name_verbatim;
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
          Alcotest.test_case "keeper_up materializes missing profile source" `Quick
            test_keeper_up_materializes_missing_profile_source;
          Alcotest.test_case
            "missing profile source rejects implicit local"
            `Quick test_missing_profile_source_rejects_implicit_local;
          Alcotest.test_case "status tracks TOML overlay edits" `Quick
            test_status_tracks_toml_overlay_changes;
          Alcotest.test_case "status reports normalized options"
            `Quick test_status_reports_normalized_options;
          Alcotest.test_case "status rejects tail order outside schema" `Quick
            test_status_rejects_tail_order_outside_schema;
          Alcotest.test_case "status rejects malformed options" `Quick
            test_status_rejects_malformed_options;
          Alcotest.test_case "status schema tracks argument contract" `Quick
            test_status_schema_tracks_argument_contract;
          Alcotest.test_case "status tracks persisted meta without updated_at"
            `Quick test_status_tracks_persisted_meta_without_updated_at;
          Alcotest.test_case "status reads live registry each call" `Quick
            test_status_reads_live_registry_each_call;
          Alcotest.test_case "status surfaces chat operation runtime" `Quick
            test_status_surfaces_chat_operation_runtime;
          Alcotest.test_case "keeper list surfaces effective meta errors"
            `Quick test_keeper_list_row_surfaces_effective_meta_errors;
          Alcotest.test_case
            "config snapshot never falls back to raw effective fields"
            `Quick test_config_snapshot_does_not_fallback_to_raw_meta;
          Alcotest.test_case
            "config snapshot prompt is nested only"
            `Quick test_config_snapshot_prompt_is_nested_only;
          Alcotest.test_case
            "keeper list error row preserves keepalive state"
            `Quick test_keeper_list_error_row_preserves_keepalive_state;
        ] );
    ]
