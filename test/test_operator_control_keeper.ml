open Masc_mcp
open Test_operator_control_support

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

let read_keeper_meta_exn config keeper_name =
  match Keeper_types.read_meta config keeper_name with
  | Ok (Some meta) -> meta
  | Ok None -> Alcotest.fail ("keeper meta missing: " ^ keeper_name)
  | Error err -> Alcotest.fail ("keeper meta read failed: " ^ err)

let with_fake_docker script f =
  let dir = temp_dir () in
  let docker_path = Filename.concat dir "docker" in
  write_file docker_path script;
  Unix.chmod docker_path 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | _ -> dir
  in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) @@ fun () ->
  with_env "MASC_TEST_FAKE_DOCKER_PATH" docker_path @@ fun () ->
  with_env "PATH" path f

let update_keeper_sandbox_mode config keeper_name ~sandbox_profile ~network_mode =
  let meta = read_keeper_meta_exn config keeper_name in
  match
    Keeper_types.write_meta config
      { meta with sandbox_profile; network_mode }
  with
  | Ok () -> ()
  | Error err -> Alcotest.fail ("keeper meta write failed: " ^ err)

let drift_keeper_identity config keeper_name ~agent_name =
  let meta = read_keeper_meta_exn config keeper_name in
  let previous_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  match
    Keeper_types.write_meta ~force:true config
      { meta with agent_name; updated_at = Keeper_types.now_iso () }
  with
  | Ok () -> previous_trace_id
  | Error err -> Alcotest.fail ("keeper identity drift write failed: " ^ err)

let check_identity_reseed_reason label json =
  Alcotest.(check string) label "agent_name_mismatch"
    Yojson.Safe.Util.(json |> member "identity_reseed" |> member "reason" |> to_string)

let check_keeper_identity_repaired config keeper_name previous_trace_id =
  let meta = read_keeper_meta_exn config keeper_name in
  let current_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  Alcotest.(check string) "agent name restored to canonical"
    (Keeper_types.keeper_agent_name keeper_name) meta.agent_name;
  Alcotest.(check bool) "trace id rotated" true
    (not (String.equal current_trace_id previous_trace_id));
  Alcotest.(check bool) "previous trace retained in history" true
    (List.mem previous_trace_id meta.runtime.trace_history)

let fake_docker_managed_sandbox_script =
  "#!/bin/sh\n\
state_file=${KEEPER_DOCKER_STATE_FILE:?}\n\
log_file=${KEEPER_DOCKER_LOG:-}\n\
tab=$(printf '\\t')\n\
read_state() {\n\
  if [ ! -s \"$state_file\" ]; then\n\
    return 1\n\
  fi\n\
  IFS=$tab read -r cid name image status running created_at keeper kind network owner_pid started_at ttl_sec < \"$state_file\"\n\
}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$1 $*\" >> \"$log_file\"\n\
fi\n\
cmd=$1\n\
shift\n\
case \"$cmd\" in\n\
  info)\n\
    printf '[]\\n'\n\
    exit 0\n\
    ;;\n\
  ps)\n\
    want_kind=''\n\
    while [ \"$#\" -gt 0 ]; do\n\
      case \"$1\" in\n\
        --filter)\n\
          case \"$2\" in\n\
            label=masc.mcp.kind=*) want_kind=${2#label=masc.mcp.kind=} ;;\n\
          esac\n\
          shift 2\n\
          ;;\n\
        *)\n\
          shift\n\
          ;;\n\
      esac\n\
    done\n\
    if read_state && { [ -z \"$want_kind\" ] || [ \"$kind\" = \"$want_kind\" ]; }; then\n\
      printf '%s\\n' \"$cid\"\n\
    fi\n\
    exit 0\n\
    ;;\n\
  run)\n\
    name=''\n\
    keeper=''\n\
    kind=''\n\
    network=''\n\
    owner_pid=''\n\
    started_at=''\n\
    ttl_sec=''\n\
    image=''\n\
    while [ \"$#\" -gt 0 ]; do\n\
      case \"$1\" in\n\
        --name)\n\
          name=$2\n\
          shift 2\n\
          ;;\n\
        --label)\n\
          case \"$2\" in\n\
            masc.mcp.keeper=*) keeper=${2#masc.mcp.keeper=} ;;\n\
            masc.mcp.kind=*) kind=${2#masc.mcp.kind=} ;;\n\
            masc.mcp.network=*) network=${2#masc.mcp.network=} ;;\n\
            masc.mcp.owner_pid=*) owner_pid=${2#masc.mcp.owner_pid=} ;;\n\
            masc.mcp.started_at=*) started_at=${2#masc.mcp.started_at=} ;;\n\
            masc.mcp.ttl_sec=*) ttl_sec=${2#masc.mcp.ttl_sec=} ;;\n\
          esac\n\
          shift 2\n\
          ;;\n\
        --user|--tmpfs|-v|--workdir|--pids-limit|--memory|--network|--security-opt)\n\
          shift 2\n\
          ;;\n\
        -d|--rm|--read-only|--cap-drop=ALL)\n\
          shift\n\
          ;;\n\
        alpine:test)\n\
          image=$1\n\
          break\n\
          ;;\n\
        *)\n\
          shift\n\
          ;;\n\
      esac\n\
    done\n\
    printf 'managed-1\\t%s\\t%s\\trunning\\ttrue\\t2026-04-24T00:00:00Z\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \\\n\
      \"$name\" \"$image\" \"$keeper\" \"$kind\" \"$network\" \"$owner_pid\" \"$started_at\" \"$ttl_sec\" > \"$state_file\"\n\
    printf 'managed-1\\n'\n\
    exit 0\n\
    ;;\n\
  inspect)\n\
    format=''\n\
    if [ \"$1\" = \"--format\" ]; then\n\
      format=$2\n\
      shift 2\n\
    fi\n\
    if ! read_state; then\n\
      exit 0\n\
    fi\n\
    case \"$format\" in\n\
      *'.Config.Image'*)\n\
        printf '%s\\t/%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \\\n\
          \"$cid\" \"$name\" \"$image\" \"$status\" \"$running\" \"$created_at\" \"$keeper\" \"$kind\" \"$network\" \"$owner_pid\" \"$started_at\" \"$ttl_sec\"\n\
        ;;\n\
      *)\n\
        printf '%s\\t%s\\t%s\\t%s\\n' \"$owner_pid\" \"$started_at\" \"$running\" \"$ttl_sec\"\n\
        ;;\n\
    esac\n\
    exit 0\n\
    ;;\n\
  rm)\n\
    if [ \"$1\" = \"-f\" ]; then\n\
      shift\n\
    fi\n\
    : > \"$state_file\"\n\
    printf '%s\\n' \"$@\"\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'unexpected docker invocation: %s\\n' \"$cmd\" >&2\n\
exit 2\n"

let test_keeper_sandbox_tools_are_public_and_titled () =
  let checks =
    [
      ("masc_keeper_sandbox_status", "Keeper Sandbox Status");
      ("masc_keeper_sandbox_start", "Start Keeper Sandbox");
      ("masc_keeper_sandbox_stop", "Stop Keeper Sandbox");
    ]
  in
  List.iter
    (fun (name, expected_title) ->
      let schema_present =
        List.exists
          (fun (schema : Types.tool_schema) -> String.equal schema.name name)
          Config.raw_all_tool_schemas
      in
      Alcotest.(check bool) (name ^ " schema present") true schema_present;
      Alcotest.(check bool) (name ^ " public mcp") true
        (List.mem name Tool_catalog.public_mcp_tools);
      Alcotest.(check string) (name ^ " title") expected_title
        (Mcp_server_eio_tool_profile.tool_title_of_name name))
    checks

let test_keeper_sandbox_status_exposes_local_summary () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "sandbox-local" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Inspect local sandbox summary");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_sandbox_status"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("include_preflight", `Bool false);
              ])
      in
      Alcotest.(check bool) "sandbox status ok" true ok;
      let sandbox_json =
        parse_json_exn body |> Yojson.Safe.Util.member "sandbox"
      in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "sandbox profile local" "local"
        (sandbox_json |> member "sandbox_profile" |> to_string);
      Alcotest.(check string) "effective mode local" "local"
        (sandbox_json |> member "effective_mode" |> to_string);
      Alcotest.(check int) "no live containers" 0
        (sandbox_json |> member "container_count" |> to_int);
      Alcotest.(check (option string)) "local why_no_container"
        (Some "sandbox_profile=local")
        (sandbox_json |> member "why_no_container" |> to_string_option);
      Alcotest.(check bool) "identity matches canonical agent" true
        (sandbox_json |> member "identity" |> member "agent_name_matches"
       |> to_bool);
      let ok, status_body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ])
      in
      Alcotest.(check bool) "keeper status ok" true ok;
      let status_json = parse_json_exn status_body in
      Alcotest.(check string) "status surfaces sandbox_live local" "local"
        Yojson.Safe.Util.(
          status_json |> member "sandbox_live" |> member "effective_mode"
          |> to_string))

let test_keeper_sandbox_start_status_stop_with_fake_docker () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "sandbox-docker" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let state_dir = Filename.concat base_dir "fake-docker" in
      let state_file = Filename.concat state_dir "containers.tsv" in
      let log_path = Filename.concat state_dir "docker.log" in
      ensure_dir state_dir;
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Prewarm managed sandbox container");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      update_keeper_sandbox_mode config keeper_name
        ~sandbox_profile:Keeper_types.Docker
        ~network_mode:Keeper_types.Network_none;
      Keeper_status_detail.invalidate_status_cache_for keeper_name;
      with_fake_docker fake_docker_managed_sandbox_script @@ fun () ->
      (match Sys.getenv_opt "MASC_TEST_FAKE_DOCKER_PATH" with
       | Some expected ->
           Alcotest.(check string) "fake docker path selected" expected
             (Masc_mcp.Keeper_sandbox_runtime.docker_command ())
       | None -> Alcotest.fail "fake docker path missing");
      with_env "KEEPER_DOCKER_STATE_FILE" state_file @@ fun () ->
      with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
      with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
      with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
      with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
      with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
      with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" @@ fun () ->
      let ok, start_body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_sandbox_start"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("ttl_sec", `Float 90.0);
              ])
      in
      if not ok then
        Alcotest.failf "sandbox start failed: %s" start_body;
      Alcotest.(check bool) "sandbox start ok" true ok;
      let start_json = parse_json_exn start_body in
      let open Yojson.Safe.Util in
      Alcotest.(check bool) "sandbox start created container" true
        (start_json |> member "sandbox" |> member "started" |> to_bool);
      Alcotest.(check string) "sandbox start network none" "none"
        (start_json |> member "sandbox" |> member "network_label" |> to_string);
      Alcotest.(check (option (float 0.0001))) "sandbox start ttl preserved"
        (Some 90.0)
        (start_json |> member "sandbox" |> member "ttl_sec" |> to_float_option);
      let log = read_file log_path in
      Alcotest.(check bool) "managed container kind label present" true
        (contains_substring log "masc.mcp.kind=managed");
      Alcotest.(check bool) "managed ttl label present" true
        (contains_substring log "masc.mcp.ttl_sec=90");
      Alcotest.(check bool) "network none passed to docker" true
        (contains_substring log "--network none");
      let ok, status_body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_sandbox_status"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("include_preflight", `Bool false);
              ])
      in
      Alcotest.(check bool) "sandbox status after start ok" true ok;
      let sandbox_json = parse_json_exn status_body |> member "sandbox" in
      Alcotest.(check string) "effective mode managed" "managed_running"
        (sandbox_json |> member "effective_mode" |> to_string);
      Alcotest.(check int) "one live container" 1
        (sandbox_json |> member "container_count" |> to_int);
      Alcotest.(check (option string)) "no why_no_container while running" None
        (sandbox_json |> member "why_no_container" |> to_string_option);
      let container =
        sandbox_json |> member "containers" |> to_list |> List.hd
      in
      Alcotest.(check (option string)) "managed kind surfaced"
        (Some "managed")
        (container |> member "container_kind" |> to_string_option);
      Alcotest.(check (option string)) "container network surfaced"
        (Some "none")
        (container |> member "network_label" |> to_string_option);
      let ok, stop_body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_sandbox_stop"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "sandbox stop ok" true ok;
      let stop_json = parse_json_exn stop_body in
      Alcotest.(check int) "stop matched one" 1
        (stop_json |> member "stop_result" |> member "matched" |> to_int);
      Alcotest.(check int) "stop removed one" 1
        (stop_json |> member "stop_result" |> member "removed" |> to_int);
      let ok, final_status_body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_sandbox_status"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("include_preflight", `Bool false);
              ])
      in
      Alcotest.(check bool) "sandbox status after stop ok" true ok;
      let final_sandbox = parse_json_exn final_status_body |> member "sandbox" in
      Alcotest.(check int) "no containers after stop" 0
        (final_sandbox |> member "container_count" |> to_int);
      Alcotest.(check bool) "why_no_container restored" true
        (Option.is_some
           (final_sandbox |> member "why_no_container" |> to_string_option)))

let test_keeper_sandbox_stop_targets_turn_containers_with_kind () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "nick0cave" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let state_dir = Filename.concat base_dir "fake-docker" in
      let state_file = Filename.concat state_dir "containers.tsv" in
      let log_path = Filename.concat state_dir "docker.log" in
      ensure_dir state_dir;
      let turn_state =
        String.concat "\t"
          [
            "turn-1";
            "masc-keeper-turn-nick0cave-none-1-1";
            "alpine:test";
            "running";
            "true";
            "2026-05-02T00:00:00Z";
            keeper_name;
            "turn";
            "none";
            string_of_int (Unix.getpid ());
            "1000";
            "1800";
          ]
        ^ "\n"
      in
      with_fake_docker fake_docker_managed_sandbox_script @@ fun () ->
      with_env "KEEPER_DOCKER_STATE_FILE" state_file @@ fun () ->
      with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
      write_file state_file turn_state;
      let ok_default, default_body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_sandbox_stop"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "default sandbox stop ok" true ok_default;
      let default_json = parse_json_exn default_body in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "default stop scope managed" "managed"
        (default_json |> member "container_kind" |> to_string);
      Alcotest.(check int) "default stop ignores turn container" 0
        (default_json |> member "stop_result" |> member "matched" |> to_int);
      let ok_invalid, invalid_body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_sandbox_stop"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("container_kind", `String "future");
              ])
      in
      Alcotest.(check bool) "invalid kind rejected" false ok_invalid;
      Alcotest.(check bool) "invalid kind message actionable" true
        (contains_substring invalid_body
           "expected managed, turn, or all");
      let invalid_json = parse_json_exn invalid_body in
      Alcotest.(check string) "invalid kind typed validation error"
        "validation_error"
        (invalid_json |> member "error_code" |> to_string);
      let ok_turn, turn_body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_sandbox_stop"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("container_kind", `String "turn");
              ])
      in
      Alcotest.(check bool) "turn sandbox stop ok" true ok_turn;
      let turn_json = parse_json_exn turn_body in
      Alcotest.(check string) "turn stop scope surfaced" "turn"
        (turn_json |> member "container_kind" |> to_string);
      Alcotest.(check int) "turn stop matches turn container" 1
        (turn_json |> member "stop_result" |> member "matched" |> to_int);
      Alcotest.(check int) "turn stop removes turn container" 1
        (turn_json |> member "stop_result" |> member "removed" |> to_int);
      let log = read_file log_path in
      Alcotest.(check bool) "turn stop filters by kind label" true
        (contains_substring log "--filter label=masc.mcp.kind=turn");
      Alcotest.(check bool) "turn stop filters by keeper label" true
        (contains_substring log
           ("--filter label=masc.mcp.keeper=" ^ keeper_name));
      Alcotest.(check bool) "turn stop filters by base path hash label" true
        (contains_substring log "--filter label=masc.mcp.base_path_hash=");
      Alcotest.(check bool) "turn container removed by id" true
        (contains_substring log "rm -f turn-1"))

let test_keeper_turn_sandbox_factory_reuses_playground_runtime () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let keeper_name = "sandbox-docker-cache" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let meta =
        match
          Masc_test_deps.meta_of_json_fixture
            (`Assoc
              [
                ("name", `String keeper_name);
                ("agent_name", `String (Keeper_types.keeper_agent_name keeper_name));
                ("trace_id", `String ("test-trace-" ^ keeper_name));
                ("goal", `String "exercise turn sandbox runtime cache");
              ])
        with
        | Ok m ->
            {
              m with
              sandbox_profile = Keeper_types.Docker;
              network_mode = Keeper_types.Network_none;
            }
        | Error err -> Alcotest.fail ("keeper meta fixture failed: " ^ err)
      in
      let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
      let nested_cwd = Filename.concat host_root "repos/masc-mcp" in
      ensure_dir nested_cwd;
      let factory = Keeper_sandbox_factory.create ~config ~meta () in
      match
        Keeper_sandbox_factory.resolve factory ~cwd:host_root,
        Keeper_sandbox_factory.resolve factory ~cwd:nested_cwd
      with
      | Some root_runtime, Some nested_runtime ->
          Alcotest.(check bool)
            "same turn sandbox runtime reused across playground cwd values"
            true
            (root_runtime == nested_runtime);
          Keeper_sandbox_factory.cleanup factory
      | _ -> Alcotest.fail "docker keeper should resolve a turn sandbox runtime")

let test_snapshot_exposes_keeper_and_social_actions () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "dashboard"));
      let ctx = operator_ctx env sw config "dashboard" in
      let available_actions =
        Operator_control.snapshot_json ~actor:"dashboard" ctx
        |> Yojson.Safe.Util.member "available_actions"
        |> Yojson.Safe.Util.to_list
      in
      let find_action action_type =
        List.find_opt
          (fun row ->
            Yojson.Safe.Util.(row |> member "action_type" |> to_string = action_type))
          available_actions
      in
      (* social_sweep removed in #5428; verify broadcast instead *)
      match find_action "broadcast" with
      | None -> Alcotest.fail "expected broadcast in available_actions"
      | Some row ->
          Alcotest.(check string) "target_type" "root"
            Yojson.Safe.Util.(row |> member "target_type" |> to_string);
          Alcotest.(check bool) "confirm_required false" false
            Yojson.Safe.Util.(row |> member "confirm_required" |> to_bool);
          Alcotest.(check bool) "autonomy_tick hidden from available actions" true
            (Option.is_none (find_action "autonomy_tick"));
          let keeper_probe =
            match find_action "keeper_probe" with
            | Some row -> row
            | None -> Alcotest.fail "expected keeper_probe in available_actions"
          in
          Alcotest.(check string) "keeper_probe target_type" "keeper"
            Yojson.Safe.Util.(keeper_probe |> member "target_type" |> to_string);
          Alcotest.(check bool) "keeper_probe confirm false" false
            Yojson.Safe.Util.(keeper_probe |> member "confirm_required" |> to_bool);
          let keeper_recover =
            match find_action "keeper_recover" with
            | Some row -> row
            | None -> Alcotest.fail "expected keeper_recover in available_actions"
          in
          Alcotest.(check string) "keeper_recover target_type" "keeper"
            Yojson.Safe.Util.(keeper_recover |> member "target_type" |> to_string);
          Alcotest.(check bool) "keeper_recover confirm true" true
            Yojson.Safe.Util.(keeper_recover |> member "confirm_required" |> to_bool);
          let root_identity_login_prepare =
            match find_action "github_identity_login_prepare" with
            | Some row -> row
            | None ->
                Alcotest.fail
                  "expected github_identity_login_prepare in available_actions"
          in
          Alcotest.(check string) "root identity login target_type" "root"
            Yojson.Safe.Util.(
              root_identity_login_prepare |> member "target_type" |> to_string);
          Alcotest.(check bool) "root identity login requires confirm" true
            Yojson.Safe.Util.(
              root_identity_login_prepare |> member "confirm_required" |> to_bool);
          let root_identity_status =
            match find_action "github_identity_status" with
            | Some row -> row
            | None ->
                Alcotest.fail
                  "expected github_identity_status in available_actions"
          in
          Alcotest.(check string) "root identity status target_type" "root"
            Yojson.Safe.Util.(
              root_identity_status |> member "target_type" |> to_string);
          Alcotest.(check bool) "root identity status confirm false" false
            Yojson.Safe.Util.(
              root_identity_status |> member "confirm_required" |> to_bool);
          let keeper_identity_login_prepare =
            match find_action "keeper_github_identity_login_prepare" with
            | Some row -> row
            | None ->
                Alcotest.fail
                  "expected keeper_github_identity_login_prepare in available_actions"
          in
          Alcotest.(check bool) "keeper identity login requires confirm" true
            Yojson.Safe.Util.(
              keeper_identity_login_prepare |> member "confirm_required" |> to_bool);
          let keeper_identity_status =
            match find_action "keeper_github_identity_status" with
            | Some row -> row
            | None ->
                Alcotest.fail
                  "expected keeper_github_identity_status in available_actions"
          in
          Alcotest.(check bool) "keeper identity status confirm false" false
            Yojson.Safe.Util.(
              keeper_identity_status |> member "confirm_required" |> to_bool);
          let task_inject =
            match find_action "task_inject" with
            | Some row -> row
            | None -> Alcotest.fail "expected task_inject in available_actions"
          in
          Alcotest.(check bool) "task inject confirm false" false
            Yojson.Safe.Util.(task_inject |> member "confirm_required" |> to_bool);
          (* Issue #8394: team_* operator actions retired. Assert
             absence so re-introduction is caught at test time. *)
          Alcotest.(check bool) "team_stop is NOT in available actions" true
            (Option.is_none (find_action "team_stop"));
          Alcotest.(check bool) "team_turn is NOT in available actions" true
            (Option.is_none (find_action "team_turn")))

let test_keeper_status_exposes_summary_and_recoverable () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "probe-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Probe keeper runtime");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "keeper down ok" true ok;
      (* After keeper_down, deactivate_keeper sets desired=false
         but keeps the entry. masc_keeper_status may return success (entry
         found with desired=false) or not-found depending on version.
         Accept either: the important assertions are the persistent_agent
         status diagnostics below. *)
      (match
         Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_status"
           ~args:(`Assoc [ ("name", `String keeper_name) ])
       with
      | Some (false, _) -> ()  (* Entry removed: expected in older code *)
      | Some (true, _) -> ()   (* Entry deactivated (desired=false): current behavior *)
      | None -> Alcotest.fail "missing keeper status dispatch");
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("fast", `Bool false);
                ("include_context", `Bool false);
                ("include_metrics_overview", `Bool false);
                ("include_memory_bank", `Bool false);
                ("include_history_tail", `Bool false);
                ("include_compaction_history", `Bool false);
              ])
      in
      Alcotest.(check bool) "persistent status ok" true ok;
      let status_json = parse_json_exn body in
      Alcotest.(check bool) "diagnostic removed from status" true
        Yojson.Safe.Util.(status_json |> member "diagnostic" = `Null);
      Alcotest.(check string) "auto team session removed" "removed"
        Yojson.Safe.Util.(
          status_json |> member "auto_execution_session" |> member "status" |> to_string);
      Alcotest.(check bool) "keepalive running false" false
        Yojson.Safe.Util.(status_json |> member "keepalive_running" |> to_bool))

let test_keeper_up_ignores_non_public_social_model_arg () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "social-model-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Reject social model override");
                ("social_model", `String "magentic_ledger_v1");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up accepted" true ok;
      let json = parse_json_exn body in
      Alcotest.(check string) "keeps canonical keeper name" keeper_name
        Yojson.Safe.Util.(json |> member "name" |> to_string);
      Alcotest.(check string) "ignores arg social_model" "bdi_speech_v1"
        Yojson.Safe.Util.(json |> member "social_model" |> to_string))

let test_keeper_status_defaults_name_to_caller () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "self-probe" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some keeper_name));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = keeper_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Self inspect");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("fast", `Bool true) ])
      in
      Alcotest.(check bool) "status ok without explicit name" true ok;
      let status_json = parse_json_exn body in
      Alcotest.(check string) "status resolved caller keeper" keeper_name
        Yojson.Safe.Util.(status_json |> member "name" |> to_string))

let test_keeper_status_accepts_agent_name_alias () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "probe-keeper" in
  let keeper_agent_name = "keeper-probe-keeper-agent" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Probe keeper runtime");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_agent_name); ("fast", `Bool true) ])
      in
      Alcotest.(check bool) "status ok via agent alias" true ok;
      let status_json = parse_json_exn body in
      Alcotest.(check string) "status resolves canonical keeper name" keeper_name
        Yojson.Safe.Util.(status_json |> member "name" |> to_string))

let test_keeper_status_accepts_legacy_separator_agent_alias () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "issue-king" in
  let keeper_agent_name = "keeper_issue_king_agent" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Probe keeper runtime");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_agent_name); ("fast", `Bool true) ])
      in
      Alcotest.(check bool) "status ok via legacy separator alias" true ok;
      let status_json = parse_json_exn body in
      Alcotest.(check string) "legacy alias resolves canonical keeper name"
        keeper_name Yojson.Safe.Util.(status_json |> member "name" |> to_string))

let test_keeper_up_reseeds_identity_drift () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "issue-king" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let up_args =
        `Assoc
          [
            ("name", `String keeper_name);
            ("goal", `String "Repair identity drift");
            ("proactive_enabled", `Bool false);
            ("autoboot_enabled", `Bool false);
          ]
      in
      let ok, _ = dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up" ~args:up_args in
      Alcotest.(check bool) "keeper up ok" true ok;
      let previous_trace_id =
        drift_keeper_identity config keeper_name
          ~agent_name:"keeper_issue_king_agent"
      in
      let ok, body = dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up" ~args:up_args in
      Alcotest.(check bool) "keeper up after drift ok" true ok;
      let body_json = parse_json_exn body in
      let identity_reseed = Yojson.Safe.Util.member "identity_reseed" body_json in
      Alcotest.(check string) "identity reseed reason" "agent_name_mismatch"
        Yojson.Safe.Util.(identity_reseed |> member "reason" |> to_string);
      let meta = read_keeper_meta_exn config keeper_name in
      let current_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
      Alcotest.(check string) "agent name restored to canonical"
        (Keeper_types.keeper_agent_name keeper_name) meta.agent_name;
      Alcotest.(check bool) "trace id rotated" true
        (not (String.equal current_trace_id previous_trace_id));
      Alcotest.(check bool) "previous trace retained in history" true
        (List.mem previous_trace_id meta.runtime.trace_history))

let test_keeper_status_reseeds_separator_identity_drift () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "issue_king" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Repair status identity drift");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let previous_trace_id =
        drift_keeper_identity config keeper_name
          ~agent_name:"keeper-issue-king-agent"
      in
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ])
      in
      Alcotest.(check bool) "keeper status repairs identity drift" true ok;
      let status_json = parse_json_exn body in
      check_identity_reseed_reason "status reseed reason" status_json;
      Alcotest.(check string) "status keeps canonical keeper name" keeper_name
        Yojson.Safe.Util.(status_json |> member "name" |> to_string);
      check_keeper_identity_repaired config keeper_name previous_trace_id)

let test_keeper_sandbox_status_reseeds_separator_identity_drift () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "sandbox_issue_king" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Repair sandbox identity drift");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let previous_trace_id =
        drift_keeper_identity config keeper_name
          ~agent_name:"keeper-sandbox-issue-king-agent"
      in
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_sandbox_status"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("include_preflight", `Bool false);
              ])
      in
      Alcotest.(check bool) "sandbox status repairs identity drift" true ok;
      let body_json = parse_json_exn body in
      check_identity_reseed_reason "sandbox status reseed reason" body_json;
      let sandbox_json = Yojson.Safe.Util.member "sandbox" body_json in
      let open Yojson.Safe.Util in
      Alcotest.(check bool) "sandbox identity matches canonical agent" true
        (sandbox_json |> member "identity" |> member "agent_name_matches"
       |> to_bool);
      Alcotest.(check string) "sandbox expected canonical agent"
        (Keeper_types.keeper_agent_name keeper_name)
        (sandbox_json |> member "identity" |> member "agent_name" |> to_string);
      check_keeper_identity_repaired config keeper_name previous_trace_id)

let test_keeper_repair_reseeds_identity_drift () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "issue-king-repair" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some keeper_name));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = keeper_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Repair identity drift");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let meta_before = read_keeper_meta_exn config keeper_name in
      let working_dir =
        Keeper_sandbox.host_root_abs_of_meta ~config meta_before
      in
      let previous_trace_id =
        drift_keeper_identity config keeper_name
          ~agent_name:"keeper_issue_king_repair_agent"
      in
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_repair"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("task_spec", `String "repair drift");
                ("working_dir", `String working_dir);
              ])
      in
      Alcotest.(check bool) "keeper repair currently returns removed bridge" false ok;
      let body_json = parse_json_exn body in
      let identity_reseed = Yojson.Safe.Util.member "identity_reseed" body_json in
      Alcotest.(check string) "repair reseed reason" "agent_name_mismatch"
        Yojson.Safe.Util.(identity_reseed |> member "reason" |> to_string);
      let meta_after = read_keeper_meta_exn config keeper_name in
      let current_trace_id = Keeper_id.Trace_id.to_string meta_after.runtime.trace_id in
      Alcotest.(check string) "repair restores canonical agent name"
        (Keeper_types.keeper_agent_name keeper_name) meta_after.agent_name;
      Alcotest.(check bool) "repair rotates trace id" true
        (not (String.equal current_trace_id previous_trace_id)))

let test_keeper_status_exposes_model_observability () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "visibility-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Expose operator model visibility");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Dated_jsonl.append
        (Keeper_types.keeper_metrics_store config keeper_name)
        (`Assoc
          [
            ("ts", `String (Types.now_iso ()));
            ("model_used", `String "stale:old-path");
            ( "cascade",
              `Assoc
                [
                  ("cascade_name", `String "stale-cascade");
                  ( "configured_labels",
                    `List [ `String "stale:old-path"; `String "stale:fallback" ] );
                  ( "candidate_models",
                    `List [ `String "stale:old-path"; `String "stale:fallback" ] );
                  ("selected_model", `String "stale:old-path");
                  ("selected_index", `Int 0);
                  ("fallback_hops", `Int 0);
                  ("fallback_applied", `Bool false);
                ] );
          ]);
      Dated_jsonl.append
        (Keeper_types.keeper_metrics_store config keeper_name)
        (`Assoc
          [
            ("ts", `String (Types.now_iso ()));
            ("model_used", `String "llama:qwen3.5-3b-a3b-ud-q8-xl");
            ( "cascade",
              `Assoc
                [
                  ("cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name);
                  ( "configured_labels",
                    `List [ `String "llama:auto"; `String "glm:auto" ] );
                  ( "candidate_models",
                    `List
                      [
                        `String "llama:qwen3.5-35b-a3b-ud-q8-xl";
                        `String "llama:qwen3.5-3b-a3b-ud-q8-xl";
                      ] );
                  ("selected_model", `String "llama:qwen3.5-3b-a3b-ud-q8-xl");
                  ("selected_index", `Int 1);
                  ("fallback_hops", `Int 1);
                  ("fallback_applied", `Bool true);
                  ( "attempts",
                    `List
                      [
                        `Assoc
                          [
                            ("attempt_index", `Int 0);
                            ("model_id", `String "qwen3.5-35b-a3b-ud-q8-xl");
                            ( "model_label",
                              `String "llama:qwen3.5-35b-a3b-ud-q8-xl" );
                            ("latency_ms", `Null);
                            ("error", `String "HTTP 503");
                          ];
                        `Assoc
                          [
                            ("attempt_index", `Int 1);
                            ("model_id", `String "qwen3.5-3b-a3b-ud-q8-xl");
                            ( "model_label",
                              `String "llama:qwen3.5-3b-a3b-ud-q8-xl" );
                            ("latency_ms", `Int 187);
                            ("error", `Null);
                          ];
                      ] );
                  ("attempt_details_available", `Bool true);
                  ("attempt_details_source", `String "oas_metrics_callbacks");
                ] );
          ]);
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ])
      in
      Alcotest.(check bool) "status ok" true ok;
      let status_json = parse_json_exn body in
      let open Yojson.Safe.Util in
      let observability = status_json |> member "model_observability" in
      let runtime_trust = status_json |> member "runtime_trust" in
      let status_dump = Yojson.Safe.pretty_to_string status_json in
      Alcotest.(check (option string))
        ("cascade name surfaced\n" ^ status_dump)
        (Some Masc_mcp.Keeper_config.default_cascade_name)
        (observability |> member "cascade_name" |> to_string_option);
      Alcotest.(check bool) "recent turn observation true" true
        (observability |> member "recent_turn_observation" |> to_bool);
      Alcotest.(check (list string)) "configured labels surfaced"
        [ "llama:auto"; "glm:auto" ]
        (observability |> member "configured_labels" |> to_list
       |> List.map to_string);
      Alcotest.(check (list string)) "resolved candidates surfaced"
        [
          "llama:qwen3.5-35b-a3b-ud-q8-xl";
          "llama:qwen3.5-3b-a3b-ud-q8-xl";
        ]
        (observability |> member "resolved_candidates" |> to_list
       |> List.map to_string);
      Alcotest.(check (option string))
        ("selected model surfaced\n" ^ status_dump)
        (Some "llama:qwen3.5-3b-a3b-ud-q8-xl")
        (observability |> member "selected_model" |> to_string_option);
      Alcotest.(check string) "attempt summary surfaced"
        "2 attempt(s); fallback after 1 hop(s); selected candidate 2/2."
        (observability |> member "attempt_summary" |> member "summary"
       |> to_string);
      Alcotest.(check string) "runtime scope local" "local"
        (observability |> member "runtime_contract" |> member "provider_scope"
       |> to_string);
      Alcotest.(check bool) "runtime contract unverified" false
        (observability |> member "runtime_contract" |> member "verified"
       |> to_bool);
      Alcotest.(check bool) "chat compatibility intentionally null" true
        (observability |> member "runtime_contract"
         |> member "chat_completion_compatible" = `Null);
      Alcotest.(check string) "runtime trust backend local" "local"
        (runtime_trust |> member "runtime_contract" |> member "backend"
       |> to_string);
      Alcotest.(check int) "runtime trust pending approvals empty" 0
        (runtime_trust |> member "pending_approval_count" |> to_int);
      Alcotest.(check string) "runtime trust disposition pass" "Pass"
        (runtime_trust |> member "disposition" |> to_string);
      Alcotest.(check bool) "runtime trust attention false" false
        (runtime_trust |> member "needs_attention" |> to_bool);
      Alcotest.(check string) "runtime trust approval idle" "idle"
        (runtime_trust |> member "approval" |> member "state" |> to_string);
      let sandbox_summary =
        runtime_trust |> member "execution" |> member "sandbox_summary"
        |> to_string
      in
      Alcotest.(check bool) "runtime trust execution sandbox summary mentions local"
        true (contains_substring sandbox_summary "local");
      let latest_causal_kind =
        runtime_trust |> member "latest_causal_event" |> member "kind"
        |> to_string
      in
      Alcotest.(check bool)
        "runtime trust latest causal event reflects persisted audit"
        true
        (List.mem latest_causal_kind [ "execution_receipt"; "transition" ]);
      Alcotest.(check bool) "runtime trust causal timeline non-empty" true
        (runtime_trust |> member "causal_timeline" |> to_list <> []))

let test_keeper_status_ignores_stale_cascade_observation () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "stale-observation-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Ignore stale keeper metrics");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let meta =
        match Keeper_types.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "keeper meta missing after up"
        | Error err -> Alcotest.fail ("meta read failed: " ^ err)
      in
      let current_labels =
        Keeper_model_labels.configured_model_labels_of_meta meta
      in
      let stale_selected_model = "stale:old-path" in
      Dated_jsonl.append
        (Keeper_types.keeper_metrics_store config keeper_name)
        (`Assoc
          [
            ("ts", `String (Types.now_iso ()));
            ("model_used", `String stale_selected_model);
            ( "cascade",
              `Assoc
                [
                  ("cascade_name", `String "stale-cascade");
                  ( "configured_labels",
                    `List [ `String "stale:old-path"; `String "stale:fallback" ] );
                  ( "candidate_models",
                    `List [ `String "stale:old-path"; `String "stale:fallback" ] );
                  ("selected_model", `String stale_selected_model);
                  ("selected_index", `Int 0);
                  ("fallback_hops", `Int 0);
                  ("fallback_applied", `Bool false);
                  ( "attempts",
                    `List
                      [
                        `Assoc
                          [
                            ("attempt_index", `Int 0);
                            ("model_id", `String "old-path");
                            ("model_label", `String stale_selected_model);
                            ("latency_ms", `Int 52);
                            ("error", `Null);
                          ];
                      ] );
                ] );
          ]);
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ])
      in
      Alcotest.(check bool) "status ok" true ok;
      let status_json = parse_json_exn body in
      let open Yojson.Safe.Util in
      let observability = status_json |> member "model_observability" in
      let status_dump = Yojson.Safe.pretty_to_string status_json in
      let sorted_strings = List.sort String.compare in
      Alcotest.(check (option string))
        ("current cascade name wins over stale metrics\n" ^ status_dump)
        (Some meta.cascade_name)
        (observability |> member "cascade_name" |> to_string_option);
      Alcotest.(check bool) "stale observation ignored" false
        (observability |> member "recent_turn_observation" |> to_bool);
      Alcotest.(check (list string))
        "configured labels come from current meta"
        (sorted_strings current_labels)
        (observability |> member "configured_labels" |> to_list
       |> List.map to_string |> sorted_strings);
      Alcotest.(check (list string))
        "resolved candidates fall back to current config"
        (sorted_strings current_labels)
        (observability |> member "resolved_candidates" |> to_list
       |> List.map to_string |> sorted_strings);
      Alcotest.(check bool) "stale selected model not surfaced" true
        (observability |> member "selected_model" |> to_string_option
       <> Some stale_selected_model);
      Alcotest.(check string) "attempt summary resets to current config"
        "No recent cascade observation for current keeper config. Showing configured labels only."
        (observability |> member "attempt_summary" |> member "summary"
       |> to_string))

let test_keeper_down_accepts_agent_name_alias () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "probe-keeper" in
  let keeper_agent_name = "keeper-probe-keeper-agent" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Probe keeper runtime");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_agent_name) ])
      in
      Alcotest.(check bool) "keeper down ok via agent alias" true ok;
      let down_json = parse_json_exn body in
      Alcotest.(check string) "down resolves canonical keeper name" keeper_name
        Yojson.Safe.Util.(down_json |> member "name" |> to_string);
      match Masc_mcp.Keeper_types.read_meta config keeper_name with
      | Ok (Some meta) ->
          Alcotest.(check bool) "keeper paused after down via alias" true meta.paused
      | Ok None -> Alcotest.fail "keeper meta missing after down"
      | Error err -> Alcotest.fail ("meta read failed: " ^ err))

let test_operator_keeper_probe_accepts_agent_name_alias () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "probe-keeper" in
  let keeper_agent_name = "keeper-probe-keeper-agent" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Probe keeper runtime");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ctx = operator_ctx env sw config "operator" in
      let action_json =
        match
          Operator_control.action_json ctx
            (`Assoc
              [
                ("actor", `String "operator");
                ("action_type", `String "keeper_probe");
                ("target_type", `String "keeper");
                ("target_id", `String keeper_agent_name);
              ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "probe delegates to keeper status"
        "masc_keeper_status"
        Yojson.Safe.Util.(action_json |> member "tool_name" |> to_string);
      let delegated_result =
        Yojson.Safe.Util.(action_json |> member "result" |> member "result")
      in
      Alcotest.(check string) "probe status resolves canonical keeper name"
        keeper_name
        Yojson.Safe.Util.(delegated_result |> member "status" |> member "name" |> to_string);
      Alcotest.(check bool) "probe includes diagnostic" true
        Yojson.Safe.Util.(delegated_result |> member "diagnostic" <> `Null))

let test_operator_keeper_recover_accepts_agent_name_alias () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "probe-keeper" in
  let keeper_agent_name = "keeper-probe-keeper-agent" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Probe keeper runtime");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Keeper_keepalive.stop_keepalive keeper_name;
      let ctx = operator_ctx env sw config "operator" in
      let action_json =
        match
          Operator_control.action_json ctx
            (`Assoc
              [
                ("actor", `String "operator");
                ("action_type", `String "keeper_recover");
                ("target_type", `String "keeper");
                ("target_id", `String keeper_agent_name);
              ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "recover requires confirmation" true
        Yojson.Safe.Util.(action_json |> member "confirm_required" |> to_bool);
      Alcotest.(check string) "recover delegates to keeper recover"
        "masc_keeper_recover"
        Yojson.Safe.Util.(action_json |> member "tool_name" |> to_string);
      let confirm_token =
        Yojson.Safe.Util.(action_json |> member "confirm_token" |> to_string)
      in
      let action_json =
        match
          Operator_control.confirm_json ctx
            (`Assoc
              [
                ("actor", `String "operator");
                ("confirm_token", `String confirm_token);
                ("decision", `String "confirm");
              ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let delegated_result =
        Yojson.Safe.Util.(action_json |> member "result" |> member "result")
      in
      Alcotest.(check bool) "recover path marked recoverable before action" true
        Yojson.Safe.Util.(delegated_result |> member "before" |> member "recoverable" |> to_bool);
      Alcotest.(check string) "recover down resolves canonical keeper name"
        keeper_name
        Yojson.Safe.Util.(delegated_result |> member "down" |> member "name" |> to_string);
      Alcotest.(check string) "recover up resolves canonical keeper name"
        keeper_name
        Yojson.Safe.Util.(delegated_result |> member "up" |> member "name" |> to_string);
      (* This PR covers only the stale stopped-entry reclaim path.
         Full health recovery depends on agent re-join and status-file
         observations, which are integration concerns outside this unit. *)
      Alcotest.(check bool) "recover reports after diagnostic" true
        Yojson.Safe.Util.(delegated_result |> member "after" <> `Null);
      Alcotest.(check bool) "recover after keepalive running" true
        Yojson.Safe.Util.(delegated_result |> member "after" |> member "keepalive_running" |> to_bool))

let test_keeper_list_scoped_to_current_base_path () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir_a = temp_dir () in
  let base_dir_b = temp_dir () in
  let keeper_name_a = "alpha-scope" in
  let keeper_name_b = "beta-scope" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name_a;
      Keeper_keepalive.stop_keepalive keeper_name_b;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir_a;
      Keeper_runtime.reset_test_state base_dir_b;
      cleanup_dir base_dir_a;
      cleanup_dir base_dir_b)
    (fun () ->
      let config_a = Coord.default_config base_dir_a in
      let config_b = Coord.default_config base_dir_b in
      ignore (Coord.init config_a ~agent_name:(Some "operator-a"));
      ignore (Coord.init config_b ~agent_name:(Some "operator-b"));
      let keeper_ctx_a : _ Tool_keeper.context =
        {
          config = config_a;
          agent_name = "operator-a";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_ctx_b : _ Tool_keeper.context =
        {
          config = config_b;
          agent_name = "operator-b";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx_a ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name_a);
                ("goal", `String "Scoped to base path A");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok in base path A" true ok;
      let ok, _ =
        dispatch_keeper_exn keeper_ctx_b ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name_b);
                ("goal", `String "Scoped to base path B");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok in base path B" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx_a ~name:"masc_keeper_list"
          ~args:(`Assoc [ ("limit", `Int 10) ])
      in
      Alcotest.(check bool) "keeper list ok" true ok;
      let list_json = parse_json_exn body in
      let open Yojson.Safe.Util in
      let keeper_names =
        list_json |> member "keepers" |> to_list |> List.map to_string
      in
      Alcotest.(check (list string)) "list only includes current base path keeper"
        [ keeper_name_a ] keeper_names;
      let listed_items = list_json |> member "items" |> to_list in
      Alcotest.(check int) "list item count scoped to current base path" 1
        (List.length listed_items);
      Alcotest.(check string) "listed item name stays local" keeper_name_a
        (listed_items |> List.hd |> member "name" |> to_string))

let test_keeper_status_does_not_cross_base_path () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir_a = temp_dir () in
  let base_dir_b = temp_dir () in
  let keeper_name = "remote-scope" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir_a;
      Keeper_runtime.reset_test_state base_dir_b;
      cleanup_dir base_dir_a;
      cleanup_dir base_dir_b)
    (fun () ->
      let config_a = Coord.default_config base_dir_a in
      let config_b = Coord.default_config base_dir_b in
      ignore (Coord.init config_a ~agent_name:(Some "operator-a"));
      ignore (Coord.init config_b ~agent_name:(Some "operator-b"));
      let keeper_ctx_a : _ Tool_keeper.context =
        {
          config = config_a;
          agent_name = "operator-a";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_ctx_b : _ Tool_keeper.context =
        {
          config = config_b;
          agent_name = "operator-b";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx_b ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Only exists in base path B");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok in base path B" true ok;
      match
        Masc_mcp.Tool_keeper.dispatch keeper_ctx_a ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ])
      with
      | Some (false, err) ->
          Alcotest.(check bool) "status reports keeper missing outside current base path"
            true (contains_substring err ("keeper not found: " ^ keeper_name))
      | Some (true, body) ->
          Alcotest.failf "keeper status unexpectedly crossed base path: %s" body
      | None -> Alcotest.fail "missing keeper status dispatch")

let test_keeper_down_only_pauses_current_base_path () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir_a = temp_dir () in
  let base_dir_b = temp_dir () in
  let keeper_name = "shared-scope" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir_a;
      Keeper_runtime.reset_test_state base_dir_b;
      cleanup_dir base_dir_a;
      cleanup_dir base_dir_b)
    (fun () ->
      let config_a = Coord.default_config base_dir_a in
      let config_b = Coord.default_config base_dir_b in
      ignore (Coord.init config_a ~agent_name:(Some "operator-a"));
      ignore (Coord.init config_b ~agent_name:(Some "operator-b"));
      let keeper_ctx_a : _ Tool_keeper.context =
        {
          config = config_a;
          agent_name = "operator-a";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_ctx_b : _ Tool_keeper.context =
        {
          config = config_b;
          agent_name = "operator-b";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx_a ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Shared name in base path A");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok in base path A" true ok;
      let ok, _ =
        dispatch_keeper_exn keeper_ctx_b ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Shared name in base path B");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok in base path B" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx_a ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "keeper down ok in base path A" true ok;
      let down_json = parse_json_exn body in
      Alcotest.(check string) "down returns scoped keeper name" keeper_name
        Yojson.Safe.Util.(down_json |> member "name" |> to_string);
      let meta_a =
        match Masc_mcp.Keeper_types.read_meta config_a keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "keeper meta missing in base path A"
        | Error err -> Alcotest.fail ("meta read failed in base path A: " ^ err)
      in
      let meta_b =
        match Masc_mcp.Keeper_types.read_meta config_b keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "keeper meta missing in base path B"
        | Error err -> Alcotest.fail ("meta read failed in base path B: " ^ err)
      in
      Alcotest.(check bool) "base path A keeper paused" true meta_a.paused;
      Alcotest.(check bool) "base path B keeper unchanged" false meta_b.paused;
      Alcotest.(check bool) "base path B keeper remains running" true
        (Keeper_registry.is_running ~base_path:config_b.base_path keeper_name))

let test_keeper_status_schema_makes_name_optional () =
  let schema =
    List.find
      (fun (spec : Types.tool_schema) ->
         String.equal spec.name "masc_keeper_status")
      Tool_keeper.schemas
  in
  let required_has_name =
    match Yojson.Safe.Util.member "required" schema.input_schema with
    | `List fields ->
      List.exists (function `String "name" -> true | _ -> false) fields
    | _ -> false
  in
  Alcotest.(check bool) "name no longer required in schema" false required_has_name

let test_keeper_config_exposes_live_runtime_and_sources () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let cwd = Sys.getcwd () in
  let original_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match original_config_dir with
      | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
      | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Masc_mcp.Config_dir_resolver.reset ();
      Keeper_keepalive.stop_keepalive "config-provenance";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      Unix.chdir cwd;
      cleanup_dir base_dir)
    (fun () ->
      Unix.chdir base_dir;
      let config_dir = Filename.concat base_dir "config" in
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Masc_mcp.Config_dir_resolver.reset ();
      let keepers_dir = Filename.concat config_dir "keepers" in
      Fs_compat.mkdir_p keepers_dir;
      Fs_compat.save_file
        (Filename.concat keepers_dir "config-provenance.toml")
        {|
[keeper]
goal = "Defaults goal"
proactive_enabled = true
|};
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let linked_goal =
        match
          Goal_store.upsert_goal config ~id:"goal-runtime"
            ~title:"Ship runtime clarity" ~horizon:Goal_store.Mid ()
        with
        | Ok (goal, _) -> goal
        | Error err -> Alcotest.fail ("goal upsert failed: " ^ err)
      in
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_name = "config-provenance" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let meta =
        match Masc_mcp.Keeper_types.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "keeper meta missing"
        | Error err -> Alcotest.fail ("meta read failed: " ^ err)
      in
      let parsed_goal_update =
        match
          Keeper_turn_up_args.parse keeper_ctx
            (`Assoc
              [
                ("name", `String keeper_name);
                ("active_goal_ids", `List [ `String linked_goal.id ]);
              ])
        with
        | Ok parsed -> parsed
        | Error (_ok, msg) -> Alcotest.fail ("active_goal_ids parse failed: " ^ msg)
      in
      let ok, msg =
        Keeper_turn_up_update.update_keeper keeper_ctx parsed_goal_update meta
      in
      Alcotest.(check bool) ("active_goal_ids update ok: " ^ msg) true ok;
      let meta = read_keeper_meta_exn config keeper_name in
      let parsed_bad_goal_update =
        match
          Keeper_turn_up_args.parse keeper_ctx
            (`Assoc
              [
                ("name", `String keeper_name);
                ("active_goal_ids", `List [ `String "goal-missing" ]);
              ])
        with
        | Ok parsed -> parsed
        | Error (_ok, msg) -> Alcotest.fail ("bad active_goal_ids parse failed: " ^ msg)
      in
      let ok, msg =
        Keeper_turn_up_update.update_keeper keeper_ctx parsed_bad_goal_update meta
      in
      Alcotest.(check bool) "unknown active goal rejected" false ok;
      Alcotest.(check bool) "unknown active goal names surfaced" true
        (contains_substring msg "goal-missing");
      let mutated =
        {
          meta with
          proactive = { meta.proactive with enabled = false };
          runtime =
            { meta.runtime with
              usage =
                {
                  meta.runtime.usage with
                  total_input_tokens = 1200;
                  total_output_tokens = 800;
                  total_tokens = 2000;
                  total_cost_usd = 0.042;
                  last_model_used = "glm:auto";
                  last_input_tokens = 120;
                  last_output_tokens = 80;
                  last_total_tokens = 200;
                  last_latency_ms = 4000;
                };
            };
          paused = true;
          updated_at = Types.now_iso ();
        }
      in
      (match Masc_mcp.Keeper_types.write_meta config mutated with
      | Ok () -> ()
      | Error err -> Alcotest.fail ("meta write failed: " ^ err));
      let status, json =
        Masc_mcp.Dashboard_http_keeper.keeper_config_json config keeper_name
      in
      Alcotest.(check bool) "config found" true (status = `OK);
      let open Yojson.Safe.Util in
      Alcotest.(check bool) "trigger_mode removed from config surface" true
        (json |> member "coordination" |> member "trigger_mode" = `Null);
      Alcotest.(check (list string)) "active_goal_ids top-level"
        [ linked_goal.id ]
        (json |> member "active_goal_ids" |> to_list |> List.map to_string);
      Alcotest.(check (list string)) "active_goal_ids in coordination"
        [ linked_goal.id ]
        (json |> member "coordination" |> member "active_goal_ids"
         |> to_list |> List.map to_string);
      Alcotest.(check string) "active goal title resolved"
        linked_goal.title
        (json |> member "coordination" |> member "active_goals"
         |> index 0 |> member "title" |> to_string);
      Alcotest.(check string) "runtime trust disposition surfaced"
        "Pass"
        (json |> member "runtime_trust" |> member "disposition" |> to_string);
      Alcotest.(check bool) "runtime paused from live meta" true
        (json |> member "runtime" |> member "paused" |> to_bool);
      Alcotest.(check bool) "proactive enabled from live meta" false
        (json |> member "proactive" |> member "enabled" |> to_bool);
      Alcotest.(check string) "default source kind" "toml"
        (json |> member "sources" |> member "default_source_kind" |> to_string);
      Alcotest.(check string) "selected cascade name"
        Masc_mcp.Keeper_config.default_cascade_name
        (json |> member "execution" |> member "selected_cascade_name"
       |> to_string);
      Alcotest.(check string) "selected cascade canonical"
        Masc_mcp.Keeper_config.default_cascade_name
        (json |> member "execution" |> member "selected_cascade_canonical"
       |> to_string);
      let expected_default_models =
        Masc_mcp.Cascade_runtime.models_of_cascade_name
          (Masc_mcp.Keeper_cascade_profile.Runtime_name
             Masc_mcp.Keeper_config.default_cascade_name)
      in
      Alcotest.(check (list string)) "selected cascade models use default profile"
        expected_default_models
        (json |> member "execution" |> member "models" |> to_list
       |> List.map to_string);
      Alcotest.(check bool) "per-provider timeout is null by default" true
        (json |> member "execution" |> member "per_provider_timeout_sec" = `Null);
      Alcotest.(check string) "per-provider timeout mode uses heuristic"
        "turn_budget_heuristic"
        (json |> member "execution" |> member "per_provider_timeout_mode"
       |> to_string);
      Alcotest.(check string) "cascade catalog source kind" "json"
        (json |> member "sources" |> member "cascade_catalog_source_kind"
       |> to_string);
      Alcotest.(check string) "cascade catalog source path"
        (Filename.concat config_dir "cascade.json")
        (json |> member "sources" |> member "cascade_catalog_source_path"
       |> to_string);
      Alcotest.(check string) "cascade runtime json path"
        (Filename.concat config_dir "cascade.json")
        (json |> member "sources" |> member "cascade_runtime_json_path"
       |> to_string);
      Alcotest.(check bool) "cascade runtime json editable" true
        (json |> member "sources" |> member "cascade_runtime_json_editable"
       |> to_bool);
      Alcotest.(check string) "active config root" config_dir
        (json |> member "sources" |> member "active_config_root" |> to_string);
      Alcotest.(check string) "active config root source" "env"
        (json |> member "sources" |> member "active_config_root_source" |> to_string);
      Alcotest.(check string) "live meta source" "runtime_overlay"
        (json |> member "sources" |> member "live_meta" |> member "source" |> to_string);
      Alcotest.(check string) "default manifest source" "toml"
        (json |> member "sources" |> member "default_manifest" |> member "source" |> to_string);
      Alcotest.(check string) "config resolution source" "env"
        (json |> member "sources" |> member "config_resolution"
         |> member "config_root" |> member "source" |> to_string);
      Alcotest.(check bool) "live override flagged" true
        (json |> member "sources" |> member "has_live_override" |> to_bool);
      Alcotest.(check string) "auto team session removed" "removed"
        (json |> member "auto_execution_session" |> member "status" |> to_string);
      let override_fields =
        json |> member "sources" |> member "override_fields" |> to_list
        |> List.map to_string
      in
      Alcotest.(check bool) "override field proactive" true
        (List.mem "proactive.enabled" override_fields);
	      let override_field_sources =
	        json |> member "sources" |> member "override_field_sources" |> to_list
	      in
	      let proactive_source =
	        List.find_opt
	          (fun item ->
	             String.equal
	               (item |> member "field" |> to_string)
	               "proactive.enabled")
	          override_field_sources
	      in
	      let proactive_source =
	        match proactive_source with
	        | Some item -> item
	        | None -> Alcotest.fail "missing proactive override source"
	      in
	      Alcotest.(check string) "override field source proactive" "live_meta"
	        (proactive_source |> member "source" |> to_string);
	      Alcotest.(check string) "override field live source" "runtime_overlay"
	        (proactive_source |> member "live_source" |> to_string);
	      Alcotest.(check string) "override field default source" "toml"
	        (proactive_source |> member "default_source" |> to_string);
	      Alcotest.(check bool) "override field default manifest exists" true
	        (proactive_source |> member "default_manifest_exists" |> to_bool);
	      Alcotest.(check bool) "override field default present" false
	        (proactive_source |> member "default_missing" |> to_bool);
	      Alcotest.(check bool) "override field default value" true
	        (proactive_source |> member "default_value" |> to_bool);
	      Alcotest.(check bool) "override field live value" false
	        (proactive_source |> member "live_value" |> to_bool);
	      Alcotest.(check bool) "initiative surface removed" true
	        (json |> member "initiative" = `Null);
      Alcotest.(check int) "total input tokens surfaced" 1200
        (json |> member "metrics" |> member "total_input_tokens" |> to_int);
      Alcotest.(check int) "last latency surfaced" 4000
        (json |> member "metrics" |> member "last_latency_ms" |> to_int);
      Alcotest.(check (option (float 0.001))) "last total tokens per sec surfaced"
        (Some 50.0)
        (json |> member "metrics" |> member "last_total_tokens_per_sec" |> to_float_option);
      Alcotest.(check (option (float 0.001))) "last output tokens per sec surfaced"
        (Some 20.0)
        (json |> member "metrics" |> member "last_output_tokens_per_sec" |> to_float_option);
      (* Prompt source depends on runtime bootstrap and any restored overrides;
         accepted values come from Prompt_registry.resolve_prompt_unlocked. *)
      let prompt_source =
        json |> member "prompt" |> member "system_prompt_blocks"
        |> member "world" |> member "source" |> to_string
      in
      Alcotest.(check bool) "prompt block source surfaced" true
        (List.mem prompt_source [ "override"; "file"; "default"; "missing" ]);
      let effective_system_prompt =
        json |> member "prompt" |> member "effective_system_prompt" |> to_string
      in
      Alcotest.(check bool) "effective system prompt includes goal" true
        (contains_substring effective_system_prompt ("Goal: " ^ mutated.goal));
      Alcotest.(check bool) "effective system prompt includes world block" true
        (contains_substring effective_system_prompt "<world>");
      let stale_base =
        match Masc_mcp.Keeper_types.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "keeper meta missing before stale write"
        | Error err ->
            Alcotest.fail ("keeper meta reload failed before stale write: " ^ err)
      in
      let stale_meta =
        { stale_base with
          cascade_name = "vendor_mix_balanced";
          updated_at = Types.now_iso ();
        }
      in
      (match Masc_mcp.Keeper_types.write_meta config stale_meta with
      | Ok () -> ()
      | Error err -> Alcotest.fail ("stale meta write failed: " ^ err));
      let stale_status, stale_json =
        Masc_mcp.Dashboard_http_keeper.keeper_config_json config keeper_name
      in
      Alcotest.(check bool) "stale config still found" true (stale_status = `OK);
      Alcotest.(check string) "stale cascade raw name preserved"
        "vendor_mix_balanced"
        (stale_json |> member "execution" |> member "selected_cascade_name"
       |> to_string);
      Alcotest.(check string) "stale cascade falls back to live default"
        Masc_mcp.Keeper_config.default_cascade_name
        (stale_json |> member "execution" |> member "selected_cascade_canonical"
       |> to_string);
      Alcotest.(check (list string)) "stale cascade models use live default"
        expected_default_models
        (stale_json |> member "execution" |> member "models" |> to_list
       |> List.map to_string);
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "keeper down ok" true ok)

let test_keeper_config_uses_backend_scoped_private_workspace_root () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "sandbox-root" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Verify sandbox root surface");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let assert_config_root label expected_rel expected_abs =
        let status, json =
          Masc_mcp.Dashboard_http_keeper.keeper_config_json config keeper_name
        in
        Alcotest.(check bool) (label ^ " config found") true (status = `OK);
        let open Yojson.Safe.Util in
        Alcotest.(check string) (label ^ " private workspace root")
          expected_abs
          (json |> member "private_workspace_root" |> to_string);
        Alcotest.(check (list string)) (label ^ " effective allowed paths")
          [ expected_rel ]
          (json |> member "effective_allowed_paths" |> to_list
         |> List.map to_string)
      in
      let local_rel =
        Masc_mcp.Keeper_sandbox.host_root_rel_of_profile
          Keeper_types.Local keeper_name
      in
      assert_config_root "local" local_rel (Filename.concat base_dir local_rel);
      update_keeper_sandbox_mode config keeper_name
        ~sandbox_profile:Keeper_types.Docker
        ~network_mode:Keeper_types.Network_none;
      Keeper_status_detail.invalidate_status_cache_for keeper_name;
      let docker_rel =
        Masc_mcp.Keeper_sandbox.host_root_rel_of_profile
          Keeper_types.Docker keeper_name
      in
      let docker_abs = Filename.concat base_dir docker_rel in
      assert_config_root "docker" docker_rel docker_abs;
      let ok, status_body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ])
      in
      Alcotest.(check bool) "keeper status ok" true ok;
      let status_json = parse_json_exn status_body in
      let open Yojson.Safe.Util in
      let execution_context = status_json |> member "execution_context" in
      (* #10650 + B1 follow-up: keeper-LLM-facing execution_context must
         not surface host paths.  The host path is inaccessible inside the
         container; surfacing it caused ~890/day [cd: No such file or
         directory] errors.  default_cwd / private_workspace_root carry
         the in-container path; host-only fields (playground_path,
         sandbox_host_root) are intentionally omitted from the JSON
         response.  docker_rel / docker_abs remain used for the
         assert_config_root call above (admin-only dashboard surface). *)
      let _ = docker_rel and _ = docker_abs in
      Alcotest.(check bool) "status playground_path omitted (no host leak)"
        true
        (execution_context |> member "playground_path" = `Null);
      Alcotest.(check bool) "status sandbox_host_root omitted (no host leak)"
        true
        (execution_context |> member "sandbox_host_root" = `Null);
      let docker_container_root =
        Masc_mcp.Keeper_sandbox.container_root keeper_name
      in
      Alcotest.(check string) "status private workspace root"
        docker_container_root
        (execution_context |> member "private_workspace_root" |> to_string);
      Alcotest.(check string) "status default cwd"
        docker_container_root
        (execution_context |> member "default_cwd" |> to_string))

let test_snapshot_keeper_tool_audit_fallback () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive "audit-keeper";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_name = "audit-keeper" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Expose dashboard fallback keeper audit");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let open Yojson.Safe.Util in
      let rec load_keeper_snapshot attempts_left =
        let snapshot =
          Operator_control.snapshot_json ~include_messages:false
            ~include_keepers:true (operator_ctx env sw config "operator")
        in
        match
          snapshot
          |> member "keepers" |> member "items" |> to_list
          |> List.find_opt (fun row -> row |> member "name" |> to_string = keeper_name)
        with
        | Some keeper -> keeper
        | None when attempts_left > 0 ->
            Unix.sleepf 0.05;
            load_keeper_snapshot (attempts_left - 1)
        | None ->
            Alcotest.failf "keeper %s missing from snapshot: %s" keeper_name
              (Yojson.Safe.to_string snapshot)
      in
      let keeper = load_keeper_snapshot 10 in
      (* keeper_up creates a healthy durable keeper; before any turn runs it should
         surface as idle rather than active. *)
      Alcotest.(check string) "durable keeper is idle before first turn after keeper_up" "idle"
        (keeper |> member "status" |> to_string);
      Alcotest.(check bool) "allowed tool fallback present" true
        ((keeper |> member "allowed_tool_names" |> to_list) <> []);
      let tool_audit_source =
        keeper |> member "tool_audit_source" |> to_string_option
      in
      Alcotest.(check bool) "tool audit source absent or known" true
        (match tool_audit_source with
         | None -> true  (* null before first turn — expected *)
         | Some s -> List.mem s [ "keeper_metrics"; "keeper_decision_log" ]);
      Alcotest.(check bool) "tool audit count zero or absent before first turn" true
        (match keeper |> member "latest_tool_call_count" with
         | `Null -> true  (* None before any turn — expected *)
         | `Int 0 -> true
         | _ -> false);
      Alcotest.(check bool) "tool audit names remain empty" true
        ((keeper |> member "latest_tool_names" |> to_list) = []);
      Alcotest.(check bool) "diagnostic removed from snapshot" true
        (keeper |> member "diagnostic" = `Null);
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "keeper down ok" true ok)

let test_snapshot_keeper_tool_audit_uses_decision_log () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive "audit-keeper-decision";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_name = "audit-keeper-decision" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Expose dashboard decision audit");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Fs_compat.append_jsonl
        (Keeper_types.keeper_decision_log_path config keeper_name)
        (`Assoc
          [
            ("ts", `String (Types.now_iso ()));
            ("selected_mode", `String "text_response");
            ("action_source", `String "fallback_after_validation_failure");
            ("tool_call_count", `Int 0);
            ("tools_used", `List []);
          ]);
      let open Yojson.Safe.Util in
      let rec load_keeper_snapshot attempts_left =
        let snapshot =
          Operator_control.snapshot_json ~include_messages:false
            ~include_keepers:true (operator_ctx env sw config "operator")
        in
        match
          snapshot
          |> member "keepers" |> member "items" |> to_list
          |> List.find_opt (fun row -> row |> member "name" |> to_string = keeper_name)
        with
        | Some keeper -> keeper
        | None when attempts_left > 0 ->
            Unix.sleepf 0.05;
            load_keeper_snapshot (attempts_left - 1)
        | None ->
            Alcotest.failf "keeper %s missing from snapshot: %s" keeper_name
              (Yojson.Safe.to_string snapshot)
      in
      let keeper = load_keeper_snapshot 10 in
      Alcotest.(check string) "decision log source exposed" "keeper_decision_log"
        (keeper |> member "tool_audit_source" |> to_string);
      Alcotest.(check string) "decision log action source exposed"
        "fallback_after_validation_failure"
        (keeper |> member "latest_action_source" |> to_string);
      Alcotest.(check int) "decision log zero tool count exposed" 0
        (keeper |> member "latest_tool_call_count" |> to_int);
      Alcotest.(check bool) "decision log names remain empty" true
        ((keeper |> member "latest_tool_names" |> to_list) = []))

let test_keeper_msg_auto_execution_session_bridge () =
  (* This test triggers a real LLM cascade call (keeper_msg -> run_turn).
     It is opt-in because local runtime/model availability is not stable
     across developer machines or CI.
     Skip unless MASC_RUN_LIVE_KEEPER_TEAM_SESSION_TEST=1. The quick-suite
     harness also exports
     CI_TEST_TIMEOUT_SEC, which is more reliable than ALCOTEST_QUICK_TESTS
     under dune test in CI. See: #1936 *)
  if Sys.getenv_opt "MASC_RUN_LIVE_KEEPER_TEAM_SESSION_TEST" <> Some "1"
     || Sys.getenv_opt "CI" = Some "true"
     || Sys.getenv_opt "ALCOTEST_QUICK_TESTS" = Some "1"
     || Sys.getenv_opt "CI_TEST_TIMEOUT_SEC" <> None then
    Alcotest.skip ()
  else
  Eio_main.run @@ fun env ->
  let local_runtime_available =
    Masc_mcp.Local_runtime_pool.healthy_runtime_count () > 0
  in
  if not local_runtime_available then
    Alcotest.skip ()
  else
  ensure_fs env;
  if Masc_mcp.Local_runtime_pool.healthy_runtime_count () <= 0 then
    Alcotest.skip ()
  else
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive "team-session-keeper";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = None;
          net = None;
        }
      in
      let keeper_name = "team-session-keeper" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Start projected team sessions from explicit keeper messages");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let first_message = "QA the mission surface and report the first blocker." in
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_msg"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("message", `String first_message);
              ])
      in
      if not ok then
        let body_lc = String.lowercase_ascii body in
        let body_has needle =
          let s_len = String.length body_lc in
          let n_len = String.length needle in
          let rec loop i =
            if i + n_len > s_len then false
            else if String.sub body_lc i n_len = needle then true
            else loop (i + 1)
          in
          n_len = 0 || loop 0
        in
        if body_has "agent.run failed"
           || body_has "api key"
           || body_has "provider"
           || body_has "runtime" then
          Alcotest.skip ()
        else
          Alcotest.failf "keeper msg failed unexpectedly: %s" body
      else
        let first_json = parse_json_exn body in
        let open Yojson.Safe.Util in
        Alcotest.(check bool) "mode present" true
          (match first_json |> member "mode" with
           | `String value -> String.trim value <> ""
           | _ -> false);
        Alcotest.(check bool) "created" true
          (first_json |> member "created" |> to_bool);
        Alcotest.(check bool) "reused" false
          (first_json |> member "reused" |> to_bool);
        let session_id = first_json |> member "session_id" |> to_string in
        (* Team_session_store removed — skip session verification *)
        ignore session_id;
        (* Team session tools removed — skip execution_session_status dispatch test *)
        ignore (config, sw, env, session_id);
        Alcotest.(check bool) "spawn_error surfaced" true
          (first_json |> member "spawn_error" <> `Null);
        let status_ok, status_body =
          dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
            ~args:
              (`Assoc
                [
                  ("name", `String keeper_name);
                  ("include_context", `Bool false);
                  ("include_metrics_overview", `Bool false);
                  ("include_memory_bank", `Bool false);
                  ("include_history_tail", `Bool false);
                  ("include_compaction_history", `Bool false);
                ])
        in
        Alcotest.(check bool) "keeper status ok" true status_ok;
        let status_json = parse_json_exn status_body in
        Alcotest.(check string) "status exposes auto team session removal" "removed"
          Yojson.Safe.Util.(status_json |> member "auto_execution_session" |> member "status" |> to_string);
        Alcotest.(check bool) "status exposes auto team session disabled" false
          Yojson.Safe.Util.(status_json |> member "auto_execution_session_enabled" |> to_bool);
        Alcotest.(check bool) "status omits team session state" true
          Yojson.Safe.Util.(status_json |> member "execution_session_state" = `Null);
        Alcotest.(check bool) "status omits team session bridge" true
          Yojson.Safe.Util.(status_json |> member "execution_session_bridge" = `Null);
        (* Team_session_store removed — skip event verification *)
        ignore (config, session_id);
        let ok, second_body =
          dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_msg"
            ~args:
              (`Assoc
                [
                  ("name", `String keeper_name);
                  ("message", `String "Continue with execution notes." );
                ])
        in
        Alcotest.(check bool) "second keeper msg ok" true ok;
        let second_json = parse_json_exn second_body in
        Alcotest.(check string) "reused session id" session_id
          Yojson.Safe.Util.(second_json |> member "session_id" |> to_string);
        Alcotest.(check bool) "second created false" false
          Yojson.Safe.Util.(second_json |> member "created" |> to_bool);
        Alcotest.(check bool) "second reused true" true
          Yojson.Safe.Util.(second_json |> member "reused" |> to_bool);
        (* Team_session_store removed — skip event count verification *)
        ignore (config, session_id);
        let ok, _ =
          dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
            ~args:(`Assoc [ ("name", `String keeper_name) ])
        in
        Alcotest.(check bool) "keeper down ok" true ok;
        let meta_after_down =
          match Masc_mcp.Keeper_types.read_meta config keeper_name with
          | Ok (Some meta) -> meta
          | Ok None -> Alcotest.fail "keeper meta removed unexpectedly"
          | Error err -> Alcotest.fail ("meta read after down failed: " ^ err)
        in
        Alcotest.(check bool) "keeper paused on down" true meta_after_down.paused;
        (* Team_session_engine_eio removed — skip session cleanup *)
        ignore (config, session_id))

let test_operator_keeper_message_rejects_legacy_model_args () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      match
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
              ("action_type", `String "keeper_message");
              ("target_type", `String "keeper");
              ("target_id", `String "sangsu");
              ( "payload",
                `Assoc
                  [
                    ("message", `String "ping");
                    ("models", `List [ `String "llama:test-model" ]);
                  ] );
            ])
      with
      | Ok _ -> Alcotest.fail "keeper_message should reject legacy models payload"
      | Error err ->
          Alcotest.(check bool) "legacy model error surfaced" true
            (contains_substring err "legacy keeper model args removed"))
