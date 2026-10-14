(** Public Keeper handlers exercise the real job producer, durable store and
    backend protocol. The Docker CLI transport is synthetic and persisted in a
    fixture-local file: these scenarios do not prove real Docker isolation. *)
open Alcotest
open Yojson.Safe.Util

module Workspace = Masc.Workspace
module Descriptor = Masc.Keeper_tool_descriptor
module Bundle = Masc.Keeper_tools_agent_core_bundle
module Store = Masc.Keeper_owned_job_store
module Invocation = Masc.Keeper_owned_job_invocation
module Call_log = Masc.Keeper_tool_call_log
module Journal = Masc.Keeper_tool_execution_journal

let keeper = "owned-job-feature"
let stdout_bytes = "original job stdout\n"
let stderr_bytes = "original job stderr\n"

let require label = function Ok value -> value | Error _ -> fail label
let store_value label = function
  | Ok value -> value
  | Error error -> failf "%s: %s" label (Store.error_to_string error)
let check_json label expected actual =
  check bool label true (Yojson.Safe.equal (Yojson.Safe.sort expected) (Yojson.Safe.sort actual))
let write path bytes = Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let read path = In_channel.with_open_bin path In_channel.input_all
let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

(* The protocol peer builds inspect receipts from the production create argv.
   It never constructs a Store record or calls a job helper on the test's
   behalf. State remains external to the OCaml process-local transport state. *)
let docker_peer = {|import atexit, csv, hashlib, json, pathlib, sys, time
root = pathlib.Path(__file__).parent
def transport_event(kind):
    with (root / "transport-events.jsonl").open("a") as output:
        output.write(json.dumps({"event": kind, "argv": sys.argv[1:]}) + "\n")
transport_event("entered")
atexit.register(transport_event, "exiting")
state_path = root / "daemon.json"
control_path = root / "control.json"
state = json.loads(state_path.read_text()) if state_path.exists() else {"calls": [], "container": None}
control = json.loads(control_path.read_text()) if control_path.exists() else {}
argv = sys.argv[1:]
state["calls"].append(argv)
def save():
    state_path.write_text(json.dumps(state))
save()
args = list(argv)
while args and args[0] in ("--config", "--host"):
    del args[:2]
if control.get("state") == "exited" and state["container"]:
    state["container"]["State"].update(Status="exited", Running=False, ExitCode=control.get("exit_code", 0))
    save()
if control.get("replacement") and state["container"]:
    state["container"]["Id"] = "c" * 64
    save()
if control.get("restore_identity") and state["container"]:
    state["container"]["Id"] = "a" * 64
    save()
def emit(value):
    print(json.dumps(value))
def option(name, values):
    return values[values.index(name)+1]
def many(name, values):
    return [values[i+1] for i, value in enumerate(values) if value == name]
def require_intent(job_id, phase, expected_container=None):
    owner = root / ".masc" / "keeper_msg_requests" / "owned_jobs" / job_id / "owner.jsonl"
    rows = [json.loads(line) for line in owner.read_text().splitlines() if line.strip()]
    record = rows[-1]
    assert record["job_id"] == job_id and record["phase"]["kind"] == phase
    bindings = [json.loads(path.read_text()) for path in
        (root / ".masc" / "keeper_msg_requests" / "owned_job_invocations").glob("*.json")]
    binding = next(value for value in bindings if value["job_id"] == job_id)
    assert binding["base_path"] == str(root) and binding["keeper_name"] == record["keeper_name"]
    assert binding["source"] == record["source"]
    request = {"argv": record["preparation"]["spec"]["argv"], "inputs": record["inputs"]}
    digest = hashlib.sha256(json.dumps(request, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    assert binding["request_sha256"] == digest
    if expected_container is not None:
        assert record["phase"]["container_id"] == expected_container
image_id = "sha256:" + "b" * 64
container_id = "a" * 64
if args == ["context", "show"]:
    print("owned-job-fixture")
elif args[:2] == ["context", "inspect"]:
    emit([{"Name": "owned-job-fixture", "Endpoints": {"docker": {"Host": "unix:///fixture/docker.sock"}}}])
elif args[:1] == ["info"]:
    emit({"ID": control.get("daemon_id", "fixture-daemon"), "OSType": "linux", "SecurityOptions": ["name=rootless", "name=userns"]})
elif args[:2] == ["image", "inspect"]:
    emit([{"Id": image_id, "Os": "linux", "Config": {"Env": [], "Volumes": {"/tmp/keeper-creds": {}}}}])
elif args[:2] == ["container", "ls"]:
    container = state["container"]
    if container:
        filters = many("--filter", args)
        assert all(value.startswith("label=") for value in filters)
        wanted = dict(value[len("label="):].split("=", 1) for value in filters)
        if all(container["Config"]["Labels"].get(key) == value for key, value in wanted.items()):
            emit(container["Id"])
elif args[:2] == ["container", "create"]:
    labels = dict(value.split("=", 1) for value in many("--label", args))
    require_intent(labels["masc.mcp.owned_job"], "create_requested")
    if control.get("mode") == "create_unknown_absent":
        print("synthetic create transport lost its receipt", file=sys.stderr)
        sys.exit(17)
    assert state["container"] is None
    tmpfs = dict(value.split(":", 1) for value in many("--tmpfs", args))
    mount = dict(value.split("=", 1) for value in next(csv.reader([option("--mount", args)])))
    image_index = args.index(image_id)
    memory = option("--memory", args)
    assert memory == "2g"
    limit = option("--ulimit", args).split("=", 1)[1].split(":")
    state["container"] = {
      "Id": container_id, "Name": "/"+option("--name", args), "Image": image_id,
      "Config": {"Labels": labels, "Image": image_id, "Entrypoint": [option("--entrypoint", args)],
        "Cmd": args[image_index+1:], "WorkingDir": option("--workdir", args), "User": option("--user", args),
        "Env": [], "Volumes": {"/tmp/keeper-creds": {}}},
      "HostConfig": {"NetworkMode": option("--network", args), "ReadonlyRootfs": "--read-only" in args,
        "Privileged": False, "AutoRemove": False, "PublishAllPorts": False,
        "RestartPolicy": {"Name": option("--restart", args), "MaximumRetryCount": 0},
        "CapAdd": None, "CapDrop": many("--cap-drop", args), "Binds": None, "VolumesFrom": None,
        "Devices": None, "DeviceRequests": None, "DeviceCgroupRules": None, "Links": None, "GroupAdd": None,
        "PortBindings": None, "PidMode": "", "UTSMode": "", "UsernsMode": "", "IpcMode": "private",
        "Memory": 2147483648, "PidsLimit": int(option("--pids-limit", args)),
        "Ulimits": [{"Name": "nofile", "Soft": int(limit[0]), "Hard": int(limit[1])}],
        "SecurityOpt": many("--security-opt", args), "Tmpfs": tmpfs},
      "Mounts": [{"Type": "bind", "Source": mount["source"], "Destination": mount["target"],
        "RW": True, "Propagation": mount["bind-propagation"]}]
        + [{"Type": "tmpfs", "Destination": target, "RW": True} for target in tmpfs],
      "State": {"Status": "created", "Running": False, "Paused": False, "Restarting": False, "Dead": False, "ExitCode": 0}}
    save()
    print(container_id)
elif args[:2] == ["container", "inspect"]:
    assert state["container"] is not None and args[2] == state["container"]["Id"]
    container = json.loads(json.dumps(state["container"]))
    if (control.get("mode") == "inspect_blocked"
            and container["Config"]["Labels"]["masc.mcp.owned_job"] == control.get("blocked_job_id")):
        (root / "inspect-entered").write_text(args[2])
        while not (root / "inspect-release").exists():
            time.sleep(0.01)
    if control.get("corrupt") == "mount":
        container["Mounts"][0]["Source"] = "/different/unowned/workspace"
    elif control.get("corrupt") == "label":
        container["Config"]["Labels"]["masc.mcp.owned_job"] = "different-job"
    emit([container])
elif args[:2] == ["container", "start"]:
    assert state["container"] is not None and args[2] == state["container"]["Id"]
    require_intent(state["container"]["Config"]["Labels"]["masc.mcp.owned_job"], "start_requested", args[2])
    if control.get("mode") == "start_unknown_absent":
        state["container"] = None
        save()
        print("synthetic start transport lost its receipt", file=sys.stderr)
        sys.exit(18)
    state["container"]["State"].update(Status="running", Running=True)
    save()
    if control.get("mode") == "start_blocked":
        (root / "start-entered").write_text(args[2])
        while True:
            time.sleep(1)
    print(container_id)
elif args[:2] == ["container", "kill"]:
    assert state["container"] is not None and args[2] == state["container"]["Id"]
    if control.get("mode") == "kill_blocked":
        (root / "kill-entered").write_text(args[2])
        while True:
            time.sleep(1)
    state["container"]["State"].update(Status="exited", Running=False, ExitCode=137)
    save()
    print(container_id)
elif args[:2] == ["container", "logs"]:
    assert state["container"] is not None and args[2] == state["container"]["Id"]
    if control.get("mode") == "logs_unknown":
        print("synthetic output transport refused", file=sys.stderr)
        sys.exit(19)
    if control.get("large_logs"):
        sizes = control["large_logs"]
        head, tail = sizes["head"], sizes["tail"]
        assert head > 0 and tail > 0
        for stream, output, fill, remainder in (("stdout", sys.stdout, "O", "o"), ("stderr", sys.stderr, "E", "e")):
            output.write(stream + " beginning\n")
            output.write(fill * (head + tail))
            output.write(stream.upper() + "_DEEP_MIDDLE\n")
            output.write(remainder * tail)
            output.write(stream.upper() + "_TERMINAL\n")
    elif state["container"]["Id"] == container_id:
        sys.stdout.write("original job stdout\n")
        sys.stderr.write("original job stderr\n")
    else:
        sys.stdout.write("replacement job stdout\n")
        sys.stderr.write("replacement job stderr\n")
else:
    raise AssertionError("unsupported fixture Docker argv: "+repr(args))
|}

type fixture =
  { base_path : string
  ; meta : Masc.Keeper_meta_contract.keeper_meta
  ; cell : Call_log.turn_ctx_cell
  ; control_path : string
  ; daemon_path : string
  ; kill_marker : string
  ; make_bundle : unit -> Masc.Keeper_tools_agent_core.tool_bundle
  }

let frozen_surface_with ~tool_deny ~tool_descriptors ~base_path ~sandbox_profile =
  let config = Skill_source_config.parse_text
      "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n"
      |> require "skill source configuration" in
  let scans = List.map (fun source_config ->
      let source = Skill_source_config.resolve ~base_path ~user_home:None source_config in
      let resolved_path = match source.Skill_source_config.resolution with
        | Resolved path -> path
        | Anchor_unavailable _ | Anchor_invalid _ | Path_rejected _ -> fail "source resolution" in
      { Skill_catalog_snapshot.source
      ; observation = Skill_catalog_snapshot.Source_ready {resolved_path; candidates=0}
      ; candidates=[] }) config.sources in
  let snapshot = Skill_catalog_snapshot.configured ~config scans |> require "frozen empty skills" in
  let global_skill_catalog, diagnostics = Masc.Keeper_skill_catalog.of_snapshot ~descriptors:tool_descriptors snapshot in
  check int "frozen skill catalog has no diagnostics" 0 (List.length diagnostics);
  Masc.Keeper_capability_surface.create_with_descriptors ~tool_deny ~tool_descriptors
    ~sandbox_profile ~skill_names:None ~global_skill_catalog
    ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot ~descriptors:tool_descriptors snapshot) ~task_skills:[]

let frozen_surface ~base_path ~sandbox_profile =
  frozen_surface_with ~tool_deny:[] ~tool_descriptors:(Descriptor.all_descriptors ())
    ~base_path ~sandbox_profile

let with_environment values f =
  let rec loop = function
    | [] -> f ()
    | (name, value) :: rest -> Masc_test_deps.with_process_env name value (fun () -> loop rest)
  in loop values

let stage label = Printf.eprintf "OWNED_JOB_STAGE %s\n%!" label

let with_fixture ?continuation_channel f =
  let base_path = Filename.temp_file "masc-owned-job-feature-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  (* macOS /var is a symlink. The production authority requires one canonical
     absolute spelling, so make the fixture itself use that spelling. *)
  let base_path = Unix.realpath base_path in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock ~sw env;
  Call_log.reset_for_testing ();
  Fun.protect ~finally:Call_log.reset_for_testing @@ fun () ->
  let initialize_transport () =
    Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env)
      ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env) in
  initialize_transport ();
  Fun.protect ~finally:Process_eio.reset_for_testing @@ fun () ->
  let python = Filename.concat base_path "docker-peer.py" in
  let docker = Filename.concat base_path "docker-peer.sh" in
  write python docker_peer;
  write docker ("#!/bin/sh\nexec python3 " ^ Filename.quote python ^ " \"$@\"\n");
  Unix.chmod docker 0o700;
  with_environment
    [ "MASC_TEST_FAKE_DOCKER_PATH", Some docker
    ; "DOCKER_CONTEXT", None; "DOCKER_HOST", None; "DOCKER_TLS_VERIFY", None
    ; "MASC_KEEPER_SANDBOX_RELAX_FS", Some "false"
    ; "MASC_KEEPER_SANDBOX_MEMORY", Some "2g"
    ; "MASC_KEEPER_SANDBOX_PIDS_LIMIT", Some "128"
    ; "MASC_KEEPER_SANDBOX_NOFILE_LIMIT", Some "245760"
    ; "MASC_KEEPER_SANDBOX_TMPFS_SIZE", Some "256m"
    ; "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE", Some ""
    ; "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS", Some "true"
    ; "MASC_KEEPER_SANDBOX_REQUIRE_USERNS", Some "true" ] @@ fun () ->
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:(Some "operator"));
  Fs_compat.mkdir_p (Filename.concat base_path ".agents/skills");
  Masc_test_deps.write_sandbox_image_catalog ~base_path ["base", "masc-sandbox-base:fixture-owned-job"];
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let meta = Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String keeper; "activation_mode", `String "manual"])
      |> require "canonical Keeper metadata" in
  let meta = { meta with sandbox_profile = Masc.Keeper_types_profile.Docker; sandbox_image = Some "base" } in
  ignore (Masc.Keeper_meta_store.replace_snapshot config meta |> require "fixture Keeper persistence");
  ignore (Masc.Keeper_registry.register_offline ~base_path keeper meta);
  let surface = frozen_surface ~base_path ~sandbox_profile:meta.sandbox_profile in
  let cell = Call_log.create_turn_ctx_cell () in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
  let make_bundle () = Bundle.make_tool_bundle_for_capability_surface
      ~config ~meta ~publication_recovery ~capability_surface:surface
      ?continuation_channel
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"owned job fixture")
      ~clock:(Eio.Stdenv.clock env) ~turn_ctx_cell:cell () in
  let fixture = {base_path;meta;cell;make_bundle;
      control_path=Filename.concat base_path "control.json";
      daemon_path=Filename.concat base_path "daemon.json";
      kill_marker=Filename.concat base_path "kill-entered"} in
  Exec_tap.enable ~writer:(fun line -> Printf.eprintf "OWNED_JOB_EXEC %s%!" line);
  Fun.protect ~finally:Exec_tap.disable @@ fun () ->
  Eio.Fiber.first
    (fun () -> f env initialize_transport fixture)
    (fun () ->
      (* Extend the existing fixture-only deadlock guard to every scenario,
         including setup calls made inside [f]. Evidence precedes cancellation;
         the race still joins cleanup and does not claim to force-stop it. *)
      Eio.Time.sleep (Eio.Stdenv.clock env) 15.;
      stage "owned job scenario watchdog expired";
      List.iter (fun path ->
        if Sys.file_exists path then
          Printf.eprintf "OWNED_JOB_EVIDENCE file=%s bytes=%s\n%!" (Filename.basename path) (read path)
        else Printf.eprintf "OWNED_JOB_EVIDENCE missing=%s\n%!" (Filename.basename path))
        [fixture.daemon_path;fixture.control_path;Filename.concat base_path "transport-events.jsonl"];
      fail "public owned job scenario did not finish; see process and transport evidence")

let set_source fixture ~task_id ~turn =
  Call_log.set_turn_context ~cell:fixture.cell ~agent_name:keeper ~task_id
    ~turn ~keeper_turn_id:turn
    ~trace_id:(Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) ()
let control fixture json = write fixture.control_path (Yojson.Safe.to_string json)
let daemon fixture = Yojson.Safe.from_string (read fixture.daemon_path)
let calls fixture = daemon fixture |> member "calls" |> to_list
let effect_count fixture operation =
  List.filter (fun json ->
      let args = json |> to_list |> List.map to_string in
      let rec command = function
        | ("--config" | "--host") :: _ :: rest -> command rest
        | "container" :: actual :: _ -> actual = operation
        | _ -> false in command args) (calls fixture) |> List.length

let result_document ~base_path content =
  let bytes = match Tool_output.decode_from_agent_core content with
    | Tool_output.Not_marker -> content
    | Tool_output.Invalid_marker {detail} -> fail detail
    | Tool_output.Decoded reference ->
        (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:reference.sha256 with
         | Ok (Some bytes) ->
             check int "wire marker names exact durable bytes" reference.bytes (String.length bytes);
             bytes
         | Ok None | Error _ -> fail "public job result artifact unavailable") in
  let json = Yojson.Safe.from_string bytes in
  match Tool_output.artifact_manifest_of_json json with
  | Tool_output.Decoded_artifact_manifest manifest -> manifest.structured_content
  | Tool_output.Invalid_artifact_manifest {detail} -> fail detail
  | Tool_output.Not_artifact_manifest ->
      (match json |> member "structured_content" with `Null -> json | structured -> structured)


let invoke_raw bundle ~tool_use_id ~turn name input =
  let tool = List.find_opt (fun (tool : Agent_core.Tool.t) -> tool.schema.name = name) bundle.Masc.Keeper_tools_agent_core.tools
    |> function Some tool -> tool | None -> failf "public job tool unavailable: %s" name in
  let execution_mode = match Tool_schemas_owned_job.find_definition name with
    | Some {read_only=true;_} -> Agent_core.Tool_contract.Concurrent
    | Some {read_only=false;_} | None -> Agent_core.Tool_contract.Serial in
  check bool "public tool uses its canonical execution mode" true
    (Agent_core.Tool.execution_mode tool ~input = execution_mode);
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id ~turn
      ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  stage (name ^ " execute entered");
  let result = Agent_core.Tool.execute ~invocation tool input in
  stage (name ^ " execute returned");
  result

let validate_job_output ~name ~input data =
  match Tool_schemas_owned_job.find_definition name with
  | None -> ()
  | Some _ ->
    let module Plan = Masc.Keeper_tool_plan in
    let node_id = Plan.Node_id.make "public-job-producer" |> require "output producer identity" in
    let node = Plan.node ~id:node_id ~tool_name:name
        ~input:(Plan.Json_template.literal input) () in
    let plan = match Plan.create ~descriptors:(Descriptor.all_descriptors ()) [node] with
      | Ok plan -> plan
      | Error error -> failf "%s output contract is invalid: %s" name (Plan.error_to_string error) in
    match Plan.validate_output plan ~run_id:(Plan.Run_id.fresh ()) ~node_id data with
    | Ok _ -> ()
    | Error _ -> failf "%s public producer output violates its declared schema: %s"
        name (Yojson.Safe.to_string data)

let invoke fixture bundle ~tool_use_id ~turn name input =
  match invoke_raw bundle ~tool_use_id ~turn name input with
  | Ok output ->
    stage (name ^ " result decode entered");
    let data = result_document ~base_path:fixture.base_path output.content in
    stage (name ^ " result decode returned; schema validation entered");
    validate_job_output ~name ~input data;
    stage (name ^ " schema validation returned");
    data
  | Error error -> failf "public job handler failed: %s" error.Agent_core.Types.message

let job_id json = json |> member "job_id" |> to_string
let argument id = `Assoc ["job_id", `String id]
let load fixture id =
  stage "canonical job load entered";
  let record = Store.Job_id.of_string id |> require "typed job id"
    |> Store.load ~base_path:fixture.base_path ~keeper_name:keeper |> store_value "canonical durable job" in
  stage "canonical job load returned";
  record
let with_bundle fixture f =
  stage "bundle construction entered";
  let bundle = fixture.make_bundle () in
  stage "bundle construction returned";
  Fun.protect ~finally:(fun () ->
      stage "bundle cleanup entered";
      bundle.cleanup ();
      stage "bundle cleanup returned") (fun () -> f bundle)

let start fixture bundle ?(inputs=[]) argv =
  invoke fixture bundle ~tool_use_id:"start-original" ~turn:41 "keeper_job_start"
    (`Assoc ["argv", `List (List.map (fun value -> `String value) argv); "inputs", `List inputs])

let check_original_source fixture json =
  let expected_turn = Ids.Turn_ref.make
      ~trace_id:(Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) ~absolute_turn:41 in
  check_json "original source survives later Task and invocation"
    (`Assoc ["task_id", `String "task-A"; "keeper_turn_id", `Int 41;
             "turn_ref", `String (Ids.Turn_ref.to_string expected_turn);
             "tool_use_id", `String "start-original";
             "trace_id", `String (Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id)])
    (json |> member "source")

let first_create_argv fixture =
  calls fixture |> List.find_map (fun json ->
      let argv = json |> to_list |> List.map to_string in
      let rec command = function
        | ("--config" | "--host") :: _ :: rest -> command rest
        | "container" :: "create" :: _ -> Some argv
        | _ -> None in
      command argv)
  |> function Some argv -> argv | None -> fail "missing fixture create call"

let argv_option name argv =
  let rec find = function
    | key :: value :: _ when key = name -> value
    | _ :: rest -> find rest
    | [] -> failf "missing %s in create argv" name in
  find argv

(* Retarget one verified donor container at a cancelled job: a new identity,
   the cancelled job's name and ownership label, and its private workspace
   bind. Every other field already passes the backend contract. *)
let orphan_container ~job_id ~name ~workspace (container : Yojson.Safe.t) =
  let patch_labels = function
    | `Assoc fields -> `Assoc (List.map (function
        | ("masc.mcp.owned_job", _) -> ("masc.mcp.owned_job", `String job_id)
        | label -> label) fields)
    | json -> json in
  let patch_config = function
    | `Assoc fields -> `Assoc (List.map (function
        | "Labels", labels -> "Labels", patch_labels labels
        | field -> field) fields)
    | json -> json in
  let patch_mounts = function
    | `List mounts -> `List (List.map (function
        | `Assoc fields -> `Assoc (List.map (function
            | ("Source", `String _) -> ("Source", `String workspace)
            | field -> field) fields)
        | mount -> mount) mounts)
    | json -> json in
  let patch_state = function
    | `Assoc _ -> `Assoc ["Status", `String "created"; "Running", `Bool false;
                          "Paused", `Bool false; "Restarting", `Bool false;
                          "Dead", `Bool false; "ExitCode", `Int 0]
    | json -> json in
  match container with
  | `Assoc fields -> `Assoc (List.map (function
      | "Id", _ -> "Id", `String (String.make 64 'c')
      | "Name", _ -> "Name", `String ("/" ^ name)
      | "Config", config -> "Config", patch_config config
      | "Mounts", mounts -> "Mounts", patch_mounts mounts
      | "State", state -> "State", patch_state state
      | field -> field) fields)
  | _ -> fail "fixture container shape changed"

let test_running_restart_exit_and_artifacts () = with_fixture @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let store = Tool_blob_store.create ~base_path:fixture.base_path in
  let input_bytes = "immutable source input\n" in
  let input = Tool_blob_store.put_durable store ~bytes:input_bytes ~mime:"text/plain" in
  let argv = ["fixture-program"; "argument with spaces"; "; literal metacharacter"; "input.txt"] in
  let started = with_bundle fixture (fun bundle -> start fixture bundle
      ~inputs:[`Assoc ["path", `String "input.txt"; "artifact", Tool_output.normalized_artifact_ref_to_json input]] argv) in
  check string "public start observes running job" "running" (started |> member "phase" |> to_string);
  check_original_source fixture started;
  let id = job_id started in
  let record = load fixture id in
  let paths = Store.paths ~base_path:fixture.base_path record.job_id in
  check string "real preparation copied immutable input" input_bytes (read (Filename.concat paths.workspace "input.txt"));
  let container = daemon fixture |> member "container" in
  check_json "argv is structured and never shell-expanded" (`List (List.map (fun x -> `String x) (List.tl argv)))
    (container |> member "Config" |> member "Cmd");
  check string "workspace is private job mount" paths.workspace
    (container |> member "Mounts" |> to_list |> List.hd |> member "Source" |> to_string);
  check string "container network contract is none" "none"
    (container |> member "HostConfig" |> member "NetworkMode" |> to_string);
  check_json "no Keeper or host identity environment injected" (`List [])
    (container |> member "Config" |> member "Env");
  set_source fixture ~task_id:"task-B" ~turn:52;
  Process_eio.reset_for_testing ();
  initialize ();
  let running = with_bundle fixture (fun bundle ->
      invoke fixture bundle ~tool_use_id:"status-later" ~turn:52 "keeper_job_status" (argument id)) in
  check string "original container survives process-local reset" "running" (running |> member "phase" |> to_string);
  check_original_source fixture running;
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "mode", `String "logs_unknown"]);
  let awaiting_outputs = with_bundle fixture (fun bundle ->
      invoke fixture bundle ~tool_use_id:"status-output-unavailable" ~turn:52 "keeper_job_status" (argument id)) in
  check string "original exit persists before output receipt" "exited" (awaiting_outputs |> member "phase" |> to_string);
  check_json "unavailable outputs are not invented" (`List []) (awaiting_outputs |> member "artifacts");
  check int "original output fetch attempted once" 1 (effect_count fixture "logs");
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "replacement", `Bool true]);
  let cloned = with_bundle fixture (fun bundle ->
      invoke fixture bundle ~tool_use_id:"status-exited-clone" ~turn:52 "keeper_job_status" (argument id)) in
  check_json "same-label exited clone cannot supply original artifacts" (`List []) (cloned |> member "artifacts");
  check int "saved identity refuses clone logs before command" 1 (effect_count fixture "logs");
  (match (load fixture id).phase with
   | Store.Exited {container_id;_} -> check string "saved exited identity is immutable" (String.make 64 'a') container_id
   | _ -> fail "original exited phase replaced by clone");
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "restore_identity", `Bool true]);
  let exited = with_bundle fixture (fun bundle ->
      invoke fixture bundle ~tool_use_id:"status-terminal" ~turn:52 "keeper_job_status" (argument id)) in
  check string "original terminal state reconciles" "exited" (exited |> member "phase" |> to_string);
  check int "exact exit code retained" 7 (exited |> member "exit_code" |> to_int);
  check_original_source fixture exited;
  check int "job created exactly once" 1 (effect_count fixture "create");
  check int "job started exactly once" 1 (effect_count fixture "start");
  let outputs = exited |> member "artifacts" |> to_list |> List.map (fun json ->
      match Tool_output.normalized_artifact_ref_of_json json with
      | Tool_output.Decoded_normalized_artifact_ref reference -> reference
      | _ -> fail "output artifact is not a canonical reference") in
  check int "both output streams retained" 2 (List.length outputs);
  List.iter2 (fun reference expected ->
      check (option string) "exact original output bytes"
        (Some expected) (Tool_blob_store.fetch store ~sha256:reference.Tool_output.sha256 |> require "artifact fetch"))
    outputs [stdout_bytes;stderr_bytes];
  write (Filename.concat paths.workspace "output.txt") stdout_bytes;
  Unix.symlink "output.txt" (Filename.concat paths.workspace "latest");
  let dead = Tool_blob_store.put_durable store ~bytes:"unowned fixture artifact" ~mime:"text/plain" in
  let owner_path = Filename.concat paths.job_dir "owner.jsonl" in
  let owner_rows = read owner_path
    |> String.split_on_char '\n' |> List.filter (fun row -> String.trim row <> "")
    |> List.concat_map (fun row -> Yojson.Safe.from_string row |> Tool_output.normalized_artifact_refs_in_json) in
  List.iter (fun reference -> check bool "canonical owner journal retains exact output reference" true
      (List.exists (fun retained -> retained.Tool_output.sha256 = reference.Tool_output.sha256) owner_rows)) outputs;
  let observe () = Tool_blob_maintenance.run ~base_path:fixture.base_path
      ~board_posts_file:Masc_board_handlers.Board_paths.posts_file ~mode:Tool_blob_maintenance.Observe_only
      |> function Ok report -> report | Error error -> fail (Tool_blob_maintenance.error_to_string error) in
  let candidates () = read (Tool_blob_maintenance.candidate_snapshot_path ~base_path:fixture.base_path)
      |> Yojson.Safe.from_string |> member "unreferenced_candidates" |> to_list |> List.map to_string in
  ignore (observe ());
  (* Only observation passes run. Temporarily detaching this terminal owner
     proves no auxiliary bridge artifact silently owns its output references. *)
  let detached_owner = Filename.concat fixture.base_path "detached-job-owner.jsonl" in
  Unix.rename owner_path detached_owner;
  Fun.protect ~finally:(fun () -> Unix.rename detached_owner owner_path) (fun () ->
    ignore (observe ());
    let detached_candidates = candidates () in
    List.iter (fun reference -> check bool "terminal journal is the sole input/output retention owner" true
        (List.mem reference.Tool_output.sha256 detached_candidates)) (input :: outputs));
  let report = observe () in
  check bool "job workspace symlink cannot poison reference scan" true (report.live_references >= 3);
  let candidates = candidates () in
  List.iter (fun reference -> check bool "job owner references never become GC candidates" false
      (List.mem reference.Tool_output.sha256 candidates)) (input :: outputs);
  check bool "unowned artifact is recorded as a candidate" true (List.mem dead.sha256 candidates)

let test_unknown_create_absence_never_replays () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control fixture (`Assoc ["mode", `String "create_unknown_absent"]);
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  check string "create uncertainty preserves durable intent" "create_requested" (started |> member "phase" |> to_string);
  let repeated = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  check string "original source recovers the unknown create handle" id (job_id repeated);
  List.iter (fun turn -> with_bundle fixture (fun bundle ->
      let status = invoke fixture bundle ~tool_use_id:("inspect-create-" ^ string_of_int turn) ~turn
          "keeper_job_status" (argument id) in
      check string "absence does not authorize a create" "create_requested" (status |> member "phase" |> to_string))) [42;43];
  check int "unknown create has one effectful command" 1 (effect_count fixture "create");
  check int "unknown create never starts" 0 (effect_count fixture "start");
  check bool "canonical create intent survives" true ((load fixture id).phase = Store.Create_requested)

let test_unknown_start_absence_never_replays () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control fixture (`Assoc ["mode", `String "start_unknown_absent"]);
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  check string "start uncertainty preserves durable intent" "start_requested" (started |> member "phase" |> to_string);
  let repeated = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  check string "original source recovers the unknown start handle" id (job_id repeated);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"inspect-start" ~turn:42
      "keeper_job_status" (argument id)));
  check int "unknown start never recreates" 1 (effect_count fixture "create");
  check int "unknown start never restarts" 1 (effect_count fixture "start");
  (match (load fixture id).phase with Store.Start_requested _ -> () | _ -> fail "original start intent replaced")

let test_cancelled_unconfirmed_launch_closes_absent_create () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control fixture (`Assoc ["mode", `String "create_unknown_absent"]);
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  check string "unknown create preserves intent" "create_requested" (started |> member "phase" |> to_string);
  let cancelled = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-absent-create" ~turn:42
      "keeper_job_cancel" (argument id)) in
  check string "cancelled absent create closes terminally" "cancelled_unconfirmed_launch"
      (cancelled |> member "phase" |> to_string);
  check bool "terminal retains cancellation request" true (cancelled |> member "cancel_requested" |> to_bool);
  check bool "unconfirmed launch has no container" true
      ((cancelled |> member "container_id") = `Null);
  check int "cancelled absent create never recreates" 1 (effect_count fixture "create");
  check int "cancelled absent create never starts" 0 (effect_count fixture "start");
  check int "cancelled absent create has no kill" 0 (effect_count fixture "kill");
  (match (load fixture id).phase with
   | Store.Cancelled_unconfirmed_launch -> ()
   | _ -> fail "cancelled launch is not durable");
  let again = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"status-after-close" ~turn:43
      "keeper_job_status" (argument id)) in
  check string "terminal survives later status" "cancelled_unconfirmed_launch" (again |> member "phase" |> to_string);
  check int "terminal status never recreates" 1 (effect_count fixture "create");
  check_original_source fixture again

let test_cancelled_unconfirmed_launch_treats_late_container_as_orphan () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control fixture (`Assoc ["mode", `String "start_unknown_absent"]);
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  check string "unknown start preserves intent" "start_requested" (started |> member "phase" |> to_string);
  let cancelled = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-absent-start" ~turn:42
      "keeper_job_cancel" (argument id)) in
  check string "cancelled absent start closes terminally" "cancelled_unconfirmed_launch"
      (cancelled |> member "phase" |> to_string);
  check int "cancelled absent start has no kill" 0 (effect_count fixture "kill");
  (match (load fixture id).phase with
   | Store.Cancelled_unconfirmed_launch -> ()
   | _ -> fail "cancelled start launch is not durable");
  control fixture (`Assoc []);
  set_source fixture ~task_id:"task-B" ~turn:52;
  ignore (with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]));
  let container = daemon fixture |> member "container" in
  let create_argv = first_create_argv fixture in
  let name = argv_option "--name" create_argv in
  let a_job_id = Store.Job_id.of_string id |> require "typed cancelled job id" in
  let workspace = (Store.paths ~base_path:fixture.base_path a_job_id).workspace in
  let orphan = orphan_container ~job_id:id ~name ~workspace container in
  let calls_json = daemon fixture |> member "calls" in
  write fixture.daemon_path (Yojson.Safe.to_string (`Assoc ["calls", calls_json; "container", orphan]));
  let orphan_seen = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"status-orphan" ~turn:53
      "keeper_job_status" (argument id)) in
  check string "late same-label container stays orphan" "cancelled_unconfirmed_launch"
      (orphan_seen |> member "phase" |> to_string);
  check bool "orphan observation leaves cancellation evidence" true
      ((orphan_seen |> member "detail")
       = `String "same-label container after a cancelled launch is an orphan; cancellation evidence is retained");
  check int "orphan never recreates a job" 2 (effect_count fixture "create");
  check int "orphan never kills" 0 (effect_count fixture "kill");
  (match (load fixture id).phase with
   | Store.Cancelled_unconfirmed_launch -> ()
   | _ -> fail "orphan replaced the cancelled launch phase")

let test_cancel_in_flight_retains_exact_intent () = with_fixture @@ fun env _initialize fixture ->
  let clock = Eio.Stdenv.clock env in
        set_source fixture ~task_id:"task-A" ~turn:41;
        let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
        let id = job_id started in
        let before = load fixture id in
        set_source fixture ~task_id:"task-B" ~turn:52;
        control fixture (`Assoc ["mode", `String "kill_blocked"]);
        let interrupted = with_bundle fixture (fun bundle ->
            Eio.Fiber.first
              (fun () -> ignore (invoke fixture bundle ~tool_use_id:"cancel-later" ~turn:52
                  "keeper_job_cancel" (argument id)); false)
              (fun () ->
                let rec wait () = if Sys.file_exists fixture.kill_marker then ()
                  else (Eio.Time.sleep clock 0.01; wait ()) in
                wait ();
                let pending = load fixture id in
                check bool "cancel intent persisted before blocked effect" true pending.cancel_requested;
                check int "cancel committed one exact transition" (before.sequence + 1) pending.sequence;
                true)) in
        check bool "foreground cancel invocation was interrupted" true interrupted;
        let pending = load fixture id in
        check bool "interruption retains cancellation intent" true pending.cancel_requested;
        check_json "interruption cannot change source ownership" (Store.source_to_json before.source) (Store.source_to_json pending.source);
        control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 137]);
        let completed = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"status-cancelled" ~turn:52
            "keeper_job_status" (argument id)) in
        check bool "terminal receipt retains requested cancellation" true (completed |> member "cancel_requested" |> to_bool);
        check string "exact cancelled container terminal observed" "exited" (completed |> member "phase" |> to_string);
        check int "verified terminal avoids another kill" 1 (effect_count fixture "kill");
        check int "cancel never relaunches" 1 (effect_count fixture "start");
        check_original_source fixture completed

let test_changed_mount_cannot_authorize_cancel () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  control fixture (`Assoc ["corrupt", `String "mount"]);
  let refused = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-unowned-mount" ~turn:42
      "keeper_job_cancel" (argument id)) in
  check string "unverified backend preserves original phase" "running" (refused |> member "phase" |> to_string);
  check bool "cancel obligation remains durable" true (refused |> member "cancel_requested" |> to_bool);
  check bool "unverified backend explains uncertainty" true (refused |> member "detail" <> `Null);
  check int "no kill crosses a changed mount authority" 0 (effect_count fixture "kill");
  control fixture (`Assoc ["replacement", `Bool true]);
  let cloned = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-same-label-clone" ~turn:42
      "keeper_job_cancel" (argument id)) in
  check bool "same-label running clone retains cancel obligation" true (cloned |> member "cancel_requested" |> to_bool);
  check int "saved identity refuses clone kill before command" 0 (effect_count fixture "kill");
  (match (load fixture id).phase with
   | Store.Running container_id -> check string "saved running identity is immutable" (String.make 64 'a') container_id
   | _ -> fail "original running phase replaced by clone");
  control fixture (`Assoc ["restore_identity", `Bool true]);
  let recovered = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-restored-owner" ~turn:42
      "keeper_job_status" (argument id)) in
  check string "restored exact authority retires original container" "exited" (recovered |> member "phase" |> to_string);
  check int "one exact owned kill after restore" 1 (effect_count fixture "kill");
  check_original_source fixture recovered

let test_large_streams_publish_complete_original_artifacts () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"; "large output"]) in
  let id = job_id started in
  let head = Common.max_process_capture_head_bytes in
  let tail = Common.max_process_capture_tail_bytes in
  let body stream fill remainder =
    let prefix = stream ^ " beginning\n" in
    let middle = String.uppercase_ascii stream ^ "_DEEP_MIDDLE\n" in
    let terminal = String.uppercase_ascii stream ^ "_TERMINAL\n" in
    let bytes = prefix ^ String.make (head + tail) fill ^ middle
        ^ String.make tail remainder ^ terminal in
    let middle_offset = String.length prefix + head + tail in
    check bool "deep marker lies beyond preview head" true (middle_offset > head);
    check bool "deep marker lies before preview tail" true
      (middle_offset + String.length middle < String.length bytes - tail);
    bytes, middle_offset, middle, terminal
  in
  (* Expected bodies come from this independent producer fixture before the
     public status/capture/publication path; hashes use only these source bytes. *)
  let expected = [body "stdout" 'O' 'o'; body "stderr" 'E' 'e'] in
  set_source fixture ~task_id:"task-B" ~turn:52;
  control fixture (`Assoc
      ["state", `String "exited"; "exit_code", `Int 0;
       "large_logs", `Assoc ["head", `Int head; "tail", `Int tail]]);
  let exited = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"status-large-streams" ~turn:52
      "keeper_job_status" (argument id)) in
  check string "large output job canonically exited" "exited" (exited |> member "phase" |> to_string);
  check_json "complete publication leaves no capture uncertainty" `Null (exited |> member "detail");
  check_original_source fixture exited;
  let references = exited |> member "artifacts" |> to_list |> List.map (fun json ->
      match Tool_output.normalized_artifact_ref_of_json json with
      | Tool_output.Decoded_normalized_artifact_ref reference -> reference
      | _ -> fail "large output artifact reference is not canonical") in
  check int "both complete streams have durable references" 2 (List.length references);
  let blobs = Tool_blob_store.create ~base_path:fixture.base_path in
  List.iter2 (fun reference (expected, middle_offset, middle, terminal) ->
      let expected_bytes = String.length expected in
      check bool "full stream exceeds process preview ceiling" true (expected_bytes > head + tail);
      check int "declared artifact bytes cover the complete stream" expected_bytes reference.Tool_output.bytes;
      let expected_sha = Digestif.SHA256.(to_hex (digest_string expected)) in
      check string "artifact SHA matches independent full source digest" expected_sha reference.sha256;
      let actual = match Tool_blob_store.fetch blobs ~sha256:reference.sha256 with
        | Ok (Some bytes) -> bytes
        | Ok None | Error _ -> fail "complete large stream artifact is unavailable" in
      check int "durable file contains all observed bytes" expected_bytes (String.length actual);
      check bool "artifact is original bytes without a rendered preview or truncation marker" true (String.equal expected actual);
      check string "omitted-preview middle survives in original artifact" middle
        (String.sub actual middle_offset (String.length middle));
      check string "terminal source bytes survive in original artifact" terminal
        (String.sub actual (String.length actual - String.length terminal) (String.length terminal))) references expected;
  check int "large result never recreates job" 1 (effect_count fixture "create");
  check int "large result never restarts job" 1 (effect_count fixture "start");
  check int "one real output capture command" 1 (effect_count fixture "logs")

let original_invocation fixture =
  let trace_id = Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id in
  let source : Store.source =
    {task_id=Some "task-A";keeper_turn_id=Some 41;trace_id=Some trace_id;
     turn_ref=Some (Ids.Turn_ref.make ~trace_id ~absolute_turn:41);
     tool_use_id=Some "start-original"} in
  match Invocation.invocation_of_source source with
  | Ok (Some invocation) -> invocation
  | Ok None | Error _ -> fail "original invocation identity unavailable"

let lookup_original fixture =
  match Invocation.lookup ~base_path:fixture.base_path ~keeper_name:keeper (original_invocation fixture) with
  | Ok (Some reservation) -> reservation
  | Ok None -> fail "original invocation reservation missing"
  | Error error -> fail (Store.error_to_string error.Invocation.cause)

let test_lost_start_reply_recovers_original_job () = with_fixture @@ fun env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control fixture (`Assoc ["mode", `String "start_blocked"]);
  let marker = Filename.concat fixture.base_path "start-entered" in
  (* Fixture deadlock guard only; no timeout is added to the producer. *)
  let interrupted = with_bundle fixture (fun bundle ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
        Eio.Fiber.first
          (fun () -> ignore (start fixture bundle ["fixture-program"]); false)
          (fun () ->
            let rec wait () = if Sys.file_exists marker then ()
              else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; wait ()) in
            wait (); true))) in
  check bool "start reply was interrupted after the actual backend effect" true interrupted;
  let calls_before_lookup = List.length (calls fixture) in
  let reservation = lookup_original fixture in
  let id = Store.Job_id.to_string reservation.job_id in
  check int "source lookup consults no backend or job inventory" calls_before_lookup (List.length (calls fixture));
  (match (load fixture id).phase with Store.Start_requested _ -> ()
    | _ -> fail "lost reply did not retain the original start intention");
  set_source fixture ~task_id:"task-B" ~turn:52;
  let found_again = lookup_original fixture in
  check string "original source lookup survives current Task change" id (Store.Job_id.to_string found_again.job_id);
  check (option string) "source lookup keeps original Task" (Some "task-A") found_again.source.task_id;
  Process_eio.reset_for_testing (); initialize ();
  control fixture (`Assoc []);
  set_source fixture ~task_id:"task-A" ~turn:41;
  let recovered = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  check string "same logical invocation recovers the original handle" id (job_id recovered);
  check string "original already-running backend is reconciled" "running" (recovered |> member "phase" |> to_string);
  check_original_source fixture recovered;
  check int "lost reply recovery never recreates the job" 1 (effect_count fixture "create");
  check int "lost reply recovery never restarts the program" 1 (effect_count fixture "start")

let assert_start_rejected fixture argv = with_bundle fixture (fun bundle ->
    match invoke_raw bundle ~tool_use_id:"start-original" ~turn:41 "keeper_job_start"
        (`Assoc ["argv", `List (List.map (fun value -> `String value) argv); "inputs", `List []]) with
    | Error _ -> ()
    | Ok _ -> fail "changed or corrupt invocation authority was accepted")

let test_original_invocation_rejects_rebinding () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let original = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id original in
  let calls_before = List.length (calls fixture) in
  assert_start_rejected fixture ["different-program"];
  check int "changed argv is rejected before any backend call" calls_before (List.length (calls fixture));
  set_source fixture ~task_id:"task-B" ~turn:41;
  assert_start_rejected fixture ["fixture-program"];
  check int "current Task cannot rebind original source" calls_before (List.length (calls fixture));
  let retained = lookup_original fixture in
  check string "conflict keeps the original handle" id (Store.Job_id.to_string retained.job_id);
  check (option string) "conflict keeps original Task authority" (Some "task-A") retained.source.task_id;
  check int "conflict never recreates" 1 (effect_count fixture "create");
  check int "conflict never restarts" 1 (effect_count fixture "start")

let test_corrupt_invocation_binding_cannot_launch () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  ignore (with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]));
  let directory = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:fixture.base_path) "keeper_msg_requests")
      "owned_job_invocations" in
  let names = Sys.readdir directory |> Array.to_list
    |> List.filter (fun name -> Filename.extension name = ".json") in
  let location = match names with [name] -> Filename.concat directory name
    | _ -> fail "expected the original invocation binding" in
  let fields = read location |> Yojson.Safe.from_string |> function
    | `Assoc fields -> fields | _ -> fail "expected binding object" in
  write location (Yojson.Safe.to_string (`Assoc (("version", `Int 1) :: fields)) ^ "\n");
  let calls_before = List.length (calls fixture) in
  assert_start_rejected fixture ["fixture-program"];
  check int "corrupt source authority never touches backend" calls_before (List.length (calls fixture));
  (match Invocation.lookup ~base_path:fixture.base_path ~keeper_name:keeper (original_invocation fixture) with
   | Error {cause=Store.Corrupt _;_} -> ()
   | Ok _ | Error _ -> fail "corrupt authority became an absent or reusable binding");
  check int "corrupt authority never recreates" 1 (effect_count fixture "create");
  check int "corrupt authority never restarts" 1 (effect_count fixture "start")

let test_malformed_source_cannot_publish_binding () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"" ~turn:41;
  assert_start_rejected fixture ["fixture-program"];
  check bool "malformed whole source never calls backend" false (Sys.file_exists fixture.daemon_path);
  let directory = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:fixture.base_path) "keeper_msg_requests")
      "owned_job_invocations" in
  check bool "malformed whole source never prepares a reservation directory" false (Sys.file_exists directory);
  (match Invocation.lookup ~base_path:fixture.base_path ~keeper_name:keeper (original_invocation fixture) with
   | Ok None -> () | Ok (Some _) | Error _ -> fail "malformed source published a binding")

let await_composition env fixture accepted =
  let module Async = Masc.Keeper_msg_async in
  let request_id = accepted |> member "request_id" |> to_string in
  (* A test deadlock guard, not a runtime completion or polling deadline. *)
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
    let rec read_terminal () =
      match Async.load_canonical_durable_terminal ~base_path:fixture.base_path
          ~caller:keeper request_id with
      | Ok proof ->
          let entry = Async.durable_terminal_entry proof in
          (match entry.status with
           | Async.Done {ok;data=Some data;_} -> ok, data, entry
           | Async.Waiting_for_owned_jobs {data=Some data;_} -> false, data, entry
           | Queued | Running | Cancelling _ | Lost _ | Cancelled _
           | Persistence_failed _ | Done {data=None;_}
           | Waiting_for_owned_jobs {data=None;_} -> fail "composition did not settle a result")
      | Error (Async.Canonical_terminal_absent | Canonical_terminal_runtime_active _) ->
          Eio.Fiber.yield (); read_terminal ()
      | Error error -> fail (Async.canonical_terminal_error_to_string error)
    in read_terminal ())

let composition_reference label json =
  match Tool_output.normalized_artifact_ref_of_json json with
  | Tool_output.Decoded_normalized_artifact_ref reference -> reference
  | Tool_output.Not_normalized_artifact_ref ->
      failf "%s is not a canonical artifact reference: %s" label (Yojson.Safe.to_string json)
  | Tool_output.Invalid_normalized_artifact_ref {detail} ->
      failf "%s is invalid: %s; value=%s" label detail (Yojson.Safe.to_string json)

let composition_nodes fixture data =
  let reference = data |> member "execution_artifact" |> composition_reference "execution artifact" in
  let bytes = match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:fixture.base_path) ~sha256:reference.sha256 with
    | Ok (Some bytes) -> bytes | Ok None | Error _ -> fail "complete execution artifact unavailable" in
  check int "execution artifact retains exact bytes" reference.bytes (String.length bytes);
  result_document ~base_path:fixture.base_path bytes |> member "nodes" |> to_list

let composition_node name nodes = List.find (fun row -> row |> member "node_id" |> to_string = name) nodes

let test_public_composition_wait_and_resume () = with_fixture @@ fun env initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"])
    |> job_id in
  let direct_before = List.length (calls fixture) in
  with_bundle fixture (fun bundle ->
    ignore (invoke fixture bundle ~tool_use_id:"direct-result-pending" ~turn:41 "keeper_job_result" (argument id));
    check bool "direct result wait lets the Keeper continue other work" true
      (bundle.terminal_effect_state () = Masc.Keeper_tools_agent_core.Terminal_effect_open));
  check int "direct pending result has no backend operation" direct_before (List.length (calls fixture));
  let sibling = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path)
      ~bytes:"independent retained result\n" ~mime:"text/plain" in
  let literal value = `Assoc ["kind", `String "literal"; "value", value] in
  let node name tool input after = `Assoc ["id", `String name; "tool", `String tool;
      "input", input; "after", `List (List.map (fun name -> `String name) after)] in
  let output = `Assoc ["kind", `String "output"; "node", `String "await";
      "pointer", `String "/artifacts/0/_blob/sha256"] in
  let recipe = `Assoc ["execution", `String "async";
      "branch_failure_policy", `String "continue_independent";
      "nodes", `List
        [node "await" "keeper_job_result" (literal (argument id)) [];
         node "await-also" "keeper_job_result" (literal (argument id)) [];
         node "sibling" "keeper_artifact_read" (literal (`Assoc ["sha256", `String sibling.sha256])) [];
         node "consumer" "keeper_artifact_read"
           (`Assoc ["kind", `String "object"; "fields", `List
             [`Assoc ["name", `String "sha256"; "value", output]]]) ["await"]];
      "exports", `List [`Assoc ["name", `String "job"; "node", `String "await"; "pointer", `String "/job_id"]]] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-wait" ~turn:41 "keeper_composition_prepare" recipe) in
  let draft_reference = prepared |> member "draft" |> composition_reference "prepared draft" in
  let sha256 = draft_reference.sha256 in
  let draft_bytes = Tool_blob_store.fetch (Tool_blob_store.create ~base_path:fixture.base_path) ~sha256
    |> require "actual prepared draft bytes" |> function
    | Some bytes -> bytes | None -> fail "prepared draft artifact is missing" in
  let draft_manifest = Yojson.Safe.from_string draft_bytes in
  (match Tool_output.artifact_manifest_of_json draft_manifest with
   | Tool_output.Decoded_artifact_manifest _ -> ()
   | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ ->
     fail "schema definitions poisoned the prepared artifact manifest");
  let contract_rows = draft_manifest |> member "structured_content" |> member "contracts"
    |> member "tools" |> to_list in
  let await_contract = contract_rows |> List.find (fun row ->
      row |> member "node_id" |> to_string = "await") in
  let frozen_contract = await_contract |> member "contract_json" |> to_string
    |> Yojson.Safe.from_string in
  check_json "literal contract keeps the declared normalized wrapper schema"
    (`String "object")
    (frozen_contract |> member "output_schema" |> member "properties"
     |> member "artifacts" |> member "items" |> member "properties"
     |> member "_blob" |> member "type");
  let calls_before = List.length (calls fixture) in
  let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"run-wait" ~turn:41 "keeper_composition_run" (`Assoc ["sha256", `String sha256])) in
  let ok, first, first_entry = await_composition env fixture accepted in
  check bool "pending job suspends this worker attempt" false ok;
  (match first_entry.status with
   | Masc.Keeper_msg_async.Waiting_for_owned_jobs {job_ids;_} ->
     check (list string) "broker retains typed original job identities" [id]
       (List.map Store.Job_id.to_string job_ids)
   | _ -> fail "owned job wait was flattened into terminal composition failure");
  let module Async = Masc.Keeper_msg_async in
  let module Queue = Masc.Keeper_registry_event_queue in
  let run_id = accepted |> member "composition_run_id" |> to_string in
  let journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
      ~composition_run_id:(Masc.Keeper_tool_plan.Composition_run_id.of_string run_id
        |> require "original run UUID") |> require "original run journal" in
  let continuation () = match Journal.waiting_continuation journal with
    | Ok (Some continuation) -> continuation
    | Ok None -> fail "original run is not canonically waiting"
    | Error error -> fail (Journal.error_to_string error) in
  let original_continuation = continuation () in
  let resume_candidate capability_surface continuation =
    let config = Workspace.default_config fixture.base_path in
    let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
      {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"physical-continuation-intake"
      ~turn:52 ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
    Masc.Keeper_tool_composition_surface.resume_continuation ~capability_surface ~continuation
      ~config ~meta:fixture.meta ~publication_recovery
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"continuation fixture")
      ~turn_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
      ~invocation ~clock:(Eio.Stdenv.clock env) () in
  let current_surface ?(tool_deny=[]) ?(tool_descriptors=Descriptor.all_descriptors ()) () =
    frozen_surface_with ~tool_deny ~tool_descriptors ~base_path:fixture.base_path
      ~sandbox_profile:fixture.meta.sandbox_profile in
  let not_ready = resume_candidate (current_surface ()) original_continuation in
  check bool "typed not-ready intake starts no worker" true (Tool_result.is_deferred not_ready);
  check string "not-ready intake keeps original owner" first_entry.request_id
    (Journal.continuation_request_id (continuation ()));
  check int "not-ready intake never queries the backend" calls_before (List.length (calls fixture));
  let pending () = Journal.pending_continuations ~base_path:fixture.base_path
      |> require "pending continuation discovery" in
  let discovery = pending () in
  check int "saved wait remains discoverable" 1 discovery.waiting;
  check int "running job never dispatches from discovery" 0 (List.length discovery.ready);
  check int "saved wait has valid original authority" 0 (List.length discovery.failures);
  check (list string) "two waiting nodes capture one original job" [id]
    (List.map Store.Job_id.to_string (Journal.continuation_job_ids original_continuation));
  check string "continuation captures original worker" first_entry.request_id
    (Journal.continuation_request_id original_continuation);
  check (option string) "continuation captures original Task" (Some "task-A")
    (Journal.continuation_source original_continuation).source_task_id;
  (match Journal.continuation_readiness original_continuation with
   | Ok Journal.Waiting_for_results -> ()
   | Ok Results_ready | Error _ -> fail "running original job appeared ready");
  let terminal_path = match Async.For_testing.terminal_record_path
      ~base_path:fixture.base_path ~request_id:first_entry.request_id with
    | Some path -> path | None -> fail "original waiting request has no canonical path" in
  let original_wire = read terminal_path in
  let wire = Yojson.Safe.from_string original_wire in
  (match Async.For_testing.load_record ~base_path:fixture.base_path
      ~request_id:first_entry.request_id with
   | Found {status=Async.Waiting_for_owned_jobs {job_ids;_};_} ->
     check (list string) "strict record roundtrip keeps the original wait" [id]
       (List.map Store.Job_id.to_string job_ids)
   | Found _ | Absent | Unreadable _ | Rejected _ ->
     fail "durable waiting outcome cannot roundtrip");
  let invalid_wait ids = match wire with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
        key, if key="job_ids" then `List ids else value) fields)
    | _ -> fail "waiting record is not an object" in
  List.iter (fun ids ->
    Fun.protect ~finally:(fun () -> write terminal_path original_wire) (fun () ->
      write terminal_path (Yojson.Safe.to_string (invalid_wait ids));
      match Async.load_canonical_durable_terminal ~base_path:fixture.base_path
          ~caller:keeper first_entry.request_id with
      | Error (Async.Canonical_terminal_unreadable _) -> ()
      | Error _ | Ok _ -> fail "strict wait decoder accepted missing/duplicate/invalid identity"))
    [[];[`String id;`String id];[`String "unknown-job"]];
  Fun.protect ~finally:(fun () -> write terminal_path original_wire) (fun () ->
    let foreign = Store.Job_id.fresh () |> Store.Job_id.to_string in
    write terminal_path (Yojson.Safe.to_string (invalid_wait [`String foreign]));
    match Journal.waiting_continuation journal with
    | Error (Journal.Invalid_result _) -> ()
    | Ok _ | Error _ -> fail "a different canonical job set authorized continuation");
  let first_job = Store.Job_id.of_string id |> require "original job identity" in
  (match Async.worker_waiting_for_owned_jobs ~job_ids:[first_job]
      (Tool_result.make_ok ~tool_name:"fixture" ~start_time:(Tool_timing.start ()) ()) with
   | Error _ -> () | Ok _ -> fail "a completed result claimed owned-job suspension");
  let reconcile = Masc.Keeper_composition_completion_wake.reconcile
      ~base_path:fixture.base_path |> require "waiting attempt outbox recovery" in
  check int "waiting attempt emits no failed completion" 0 reconcile.delivered;
  let sources = Queue.pending_selections_result ~base_path:fixture.base_path keeper
    |> require "waiting attempt queue" in
  check int "waiting attempt has no false composition terminal notification" 0
    (List.length (List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
      match selection.source.payload with Composition_completed _ -> true | _ -> false) sources));
  check int "waiting for result performs no backend operation" calls_before (List.length (calls fixture));
  let first_nodes = composition_nodes fixture first in
  let awaiting = composition_node "await" first_nodes in
  check_json "producer owns the durable job wait" (`String "owned_job_result_wait") (awaiting |> member "deferred_kind");
  check_json "job read is proven before any command effect" (`String "proven_pre_effect")
    (awaiting |> member "failure_effect_disposition");
  check bool "consumer waits for complete original output" false
    (List.exists (fun row -> row |> member "node_id" |> to_string = "consumer") first_nodes);
  let resume () = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"resume-wait" ~turn:52 "keeper_composition_run"
      (`Assoc ["sha256", `String sha256; "resume_run_id", `String run_id])) in
  set_source fixture ~task_id:"task-B" ~turn:52;
  Process_eio.reset_for_testing (); initialize ();
  let owner_record = load fixture id in
  let owner_path = Filename.concat (Store.paths ~base_path:fixture.base_path owner_record.job_id).job_dir "owner.jsonl" in
  let owner_bytes = read owner_path in
  let before_refusal = List.length (calls fixture) in
  let refused_data = Fun.protect ~finally:(fun () -> write owner_path owner_bytes) (fun () ->
      write owner_path "{temporarily-invalid-owner\n";
      let unreadable = pending () in
      check int "corrupt job authority leaves no ready continuation" 0 (List.length unreadable.ready);
      check int "corrupt job authority is reported and retained" 1 (List.length unreadable.failures);
      (match Journal.continuation_readiness original_continuation with
       | Error (Journal.Invalid_result _) -> ()
       | Ok _ | Error _ -> fail "corrupt original job owner became a ready continuation");
      let refused = resume () in
      let ok, data, _ = await_composition env fixture refused in
      check bool "unreadable original owner refuses result rechecking" false ok;
      data) in
  check int "transient result refusal cannot call the backend" before_refusal (List.length (calls fixture));
  let refused_node = composition_nodes fixture refused_data |> composition_node "await" in
  List.iter (fun field -> check_json ("refusal preserves original occurrence " ^ field)
      (awaiting |> member field) (refused_node |> member field)) ["execution_id";"tool_use_id"];
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "mode", `String "logs_unknown"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-unavailable" ~turn:52 "keeper_job_status" (argument id)));
  let before_resume = List.length (calls fixture) in
  let still_pending = resume () in
  let ok, second, _ = await_composition env fixture still_pending in
  check bool "exit without complete outputs remains waiting" false ok;
  check int "resuming a wait never collects or relaunches" before_resume (List.length (calls fixture));
  let second_nodes = composition_nodes fixture second in
  let ready_continuation = continuation () in
  List.iter (fun field -> check_json ("same waiting occurrence " ^ field)
      (awaiting |> member field) (composition_node "await" second_nodes |> member field)) ["execution_id";"tool_use_id"];
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 7]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-complete" ~turn:52 "keeper_job_status" (argument id)));
  let before_completed_resume = List.length (calls fixture) in
  let discovered = pending () in
  check int "completed result is discovered without another event" 1 (List.length discovered.ready);
  check int "completed result has readable original authority" 0 (List.length discovered.failures);
  let discovered = List.hd discovered.ready in
  check string "discovery keeps the same waiting owner"
    (Journal.continuation_request_id ready_continuation)
    (Journal.continuation_request_id discovered);
  check (option string) "discovery keeps original Task after current Task changed"
    (Some "task-A") (Journal.continuation_source discovered).source_task_id;
  Process_eio.reset_for_testing (); initialize ();
  let restarted_discovery = pending () in
  check int "same ready wait survives transport reinitialization" 1 (List.length restarted_discovery.ready);
  (match Journal.continuation_readiness ready_continuation with
   | Ok Journal.Results_ready -> ()
   | Ok Waiting_for_results | Error _ -> fail "complete original outputs are not ready");
  let changed_surface = current_surface ~tool_deny:["keeper_job_start"] () in
  let module Draft = Masc.Keeper_composition_draft in
  let alias_base = Filename.concat fixture.base_path "." in
  let original_source = Journal.continuation_source discovered in
  let alias_prepared = Journal.prepare ~base_path:alias_base original_source
    |> require "same original journal through an alias base" in
  let alias_loaded = Journal.load ~base_path:(fixture.base_path ^ "/") ~keeper_name:keeper
      ~composition_run_id:original_source.composition_run_id
    |> require "same original journal through a trailing slash" in
  let capture journal = match Journal.waiting_continuation journal with
    | Ok (Some candidate) -> candidate
    | Ok None | Error _ -> fail "alias lost the original waiting continuation" in
  List.iter (fun journal ->
    let candidate = capture journal in
    check string "journal ingress stores canonical workspace authority" fixture.base_path
      (Journal.continuation_base_path candidate);
    ignore (Draft.load_continuation ~base_path:alias_base ~capability_surface:changed_surface candidate
      |> require "same physical workspace admits an alias continuation")) [alias_prepared;alias_loaded];
  let discovered = capture alias_loaded in
  (match Draft.load ~base_path:fixture.base_path ~capability_surface:changed_surface ~keeper_name:keeper ~sha256 with
   | Error Draft.Capability_changed -> ()
   | Ok _ | Error _ -> fail "ordinary draft admission silently adopted a changed whole surface");
  let preserved = Draft.load_continuation ~base_path:fixture.base_path
      ~capability_surface:changed_surface discovered |> require "sealed original continuation contracts" in
  check string "continuation retains original draft" sha256 (Draft.reference preserved).sha256;
  let other_base = Filename.concat fixture.base_path "other-workspace" in
  Unix.mkdir other_base 0o700;
  (match Draft.load_continuation ~base_path:other_base ~capability_surface:changed_surface discovered with
   | Error (Draft.Malformed_draft _) -> ()
   | Ok _ | Error _ -> fail "sealed continuation was loaded in a different workspace");
  let denied = resume_candidate (current_surface ~tool_deny:["keeper_job_result"] ()) discovered in
  check bool "current denial refuses before async acceptance" true (Tool_result.is_failed denied);
  check string "current denial keeps original owner" (Journal.continuation_request_id discovered)
    (Journal.continuation_request_id (continuation ()));
  let lost_worker_calls = ref 0 in
  let lose_after_binding candidate =
    (* A closed target switch makes the real broker fail after durable Queued
       acceptance and Journal binding, before any worker can run. No canonical
       owner or terminal record is manufactured by the fixture. *)
    let stopped_switch = Eio.Switch.run (fun sw -> sw) in
    let lost = Async.submit_worker_with_request_id ?request_context:first_entry.request_context
        ~background_sw:stopped_switch ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
        ~on_accepted:(fun request_id ->
          Journal.bind_continuation candidate ~request_id
          |> Result.map (fun _ -> ()) |> Result.map_error Journal.error_to_string)
        ~f:(fun ~request_id:_ _ ->
          incr lost_worker_calls;
          Async.worker_finished (Tool_result.make_ok ~tool_name:"unstarted-continuation"
            ~start_time:(Tool_timing.start ()) ())) () in
    let request_id = match lost with
      | Error (Async.Background_fork_failed {request_id;_} as error) ->
        check_json "fork refusal does not guess the canonical request status" `Null
          (Async.submit_error_to_json error |> member "status");
        request_id
      | Error _ | Ok _ -> fail "closed worker switch did not publish post-binding Lost" in
    let proof = Async.load_canonical_durable_terminal ~base_path:fixture.base_path
        ~caller:keeper request_id |> require "canonical post-binding Lost" in
    let entry = Async.durable_terminal_entry proof in
    (match entry.status with Lost _ -> () | _ -> fail "unstarted bound worker did not remain Lost");
    check string "Lost successor remains the exact journal owner" request_id
      (Journal.continuation_request_id (continuation ()));
    check int "post-binding loss starts no worker" 0 !lost_worker_calls;
    check int "post-binding loss has no backend operation" before_completed_resume (List.length (calls fixture));
    let report = pending () in
    check int "post-binding Lost remains discoverable" 1 (List.length report.ready);
    check int "post-binding Lost keeps readable original authority" 0 (List.length report.failures);
    List.hd report.ready, entry in
  let after_first_loss, first_lost_entry = lose_after_binding discovered in
  (match Journal.continuation_readiness discovered with
   | Error Journal.Ownership_changed -> ()
   | Ok _ | Error _ -> fail "prior waiting candidate recaptured its Lost successor");
  let after_second_loss, second_lost_entry = lose_after_binding after_first_loss in
  (match Journal.continuation_readiness after_first_loss with
   | Error Journal.Ownership_changed -> ()
   | Ok _ | Error _ -> fail "first Lost candidate recaptured its second successor");
  let first_lost_path = Async.For_testing.terminal_record_path ~base_path:fixture.base_path
      ~request_id:first_lost_entry.request_id
    |> function Some path -> path | None -> fail "first Lost terminal path" in
  let first_lost_bytes = read first_lost_path in
  Fun.protect ~finally:(fun () -> write first_lost_path first_lost_bytes) (fun () ->
    let changed = match Yojson.Safe.from_string first_lost_bytes with
      | `Assoc fields -> `Assoc (("reason",`String "changed predecessor terminal evidence")
          :: List.remove_assoc "reason" fields)
      | _ -> fail "canonical Lost record is not an object" in
    write first_lost_path (Yojson.Safe.to_string changed);
    match Journal.continuation_readiness after_second_loss with
    | Error Journal.Ownership_changed -> ()
    | Ok _ | Error _ -> fail "changed canonical predecessor authorized the sealed continuation");
  (match Journal.continuation_readiness after_second_loss with
   | Ok Journal.Results_ready -> ()
   | Ok Waiting_for_results | Error _ -> fail "restored original wait cannot recover repeated Lost successors");
  let retain_wait_without_dispatch candidate =
    (* Real broker admission binds a successor, then its worker returns the
       original wait before touching any node. This is the journal boundary
       used when activation authority becomes unavailable after acceptance. *)
    let accepted = Async.submit_worker_with_request_id ?request_context:first_entry.request_context
        ~background_sw:(Async.server_background_switch () |> require "original wait successor switch")
        ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
        ~on_accepted:(fun request_id -> Journal.bind_continuation candidate ~request_id
          |> Result.map (fun _ -> ()) |> Result.map_error Journal.error_to_string)
        ~f:(fun ~request_id:_ _ ->
          Async.worker_waiting_for_owned_jobs ~job_ids:(Journal.continuation_job_ids candidate)
            (Tool_result.make_deferred ~tool_name:"original-child-activation-unavailable"
              ~start_time:(Tool_timing.start ()) ~data:(`Assoc ["dispatch_started",`Bool false]) ())
          |> require "original wait before node dispatch") ()
      |> require "actual no-dispatch successor admission" in
    let ok,_,entry = await_composition env fixture (`Assoc ["request_id",`String accepted.request_id]) in
    check bool "no-dispatch successor preserves waiting outcome" false ok;
    let preserved = continuation () in
    check string "canonical waiting successor owns its inherited wait" entry.request_id
      (Journal.continuation_request_id preserved);
    check (list string) "inherited wait retains exact original jobs" [id]
      (List.map Store.Job_id.to_string (Journal.continuation_job_ids preserved));
    check int "inherited wait never queries or relaunches backend" before_completed_resume (List.length (calls fixture));
    (match Journal.continuation_readiness candidate with
     | Error Journal.Ownership_changed -> ()
     | Ok _ | Error _ -> fail "inherited wait reused stale predecessor ownership");
    let report = pending () in
    check int "inherited wait remains discoverable after the worker settles" 1 (List.length report.ready);
    check int "inherited wait retains exact predecessor evidence" 0 (List.length report.failures);
    preserved in
  let recovery_candidate = retain_wait_without_dispatch after_second_loss |> retain_wait_without_dispatch in
  let module Wake = Masc.Keeper_composition_continuation_wake in
  let config = Workspace.default_config fixture.base_path in
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  let write_profile ?(path=declaration) ?declared_name deny =
    let name = match declared_name with None -> "" | Some name -> "name = \"" ^ name ^ "\"\n" in
    let tools = if deny then "\n[keeper.tools]\ndeny = [\"keeper_job_result\"]\n" else "" in
    write path ("[keeper]\n" ^ name ^ "activation_mode = \"manual\"\nsandbox_profile = \"docker\"\n"
      ^ "sandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Original result continuation fixture\"\n" ^ tools) in
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  write runtime_path "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n";
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
      |> require "canonical fixture Skill publication authority" in
  Fun.protect ~finally:(fun () -> Skill_catalog_snapshot_service.retire ~workspace) @@ fun () ->
  (match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path;source_text=read runtime_path}) with
   | Published _ | Unchanged _ -> () | Workspace_retired -> fail "fixture Skill publication retired early");
  let context : _ Masc.Keeper_types_profile.context =
    {config;agent_name="continuation-maintenance-fixture";
     sw=Async.server_background_switch () |> require "continuation maintenance switch";
     clock=Eio.Stdenv.clock env;proc_mgr=Some (Eio.Stdenv.process_mgr env);net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let active_requests () = Async.list_for_keeper ~base_path:fixture.base_path ~caller:keeper
      ~keeper_name:keeper () |> require "active requests at maintenance profile admission"
      |> List.map (fun (entry : Async.entry) -> entry.request_id) |> List.sort String.compare in
  let profile_owner_refusals = ref 0 in
  let assert_profile_owner_refused label =
    let requests_before = active_requests () in
    let refused,notify_refused = Eio.Promise.create () in
    let wake = Wake.create ~context ~on_result:(fun _ outcome -> Eio.Promise.resolve notify_refused outcome) () in
    Wake.pulse ~sw:context.sw wake |> require label;
    (match Eio.Promise.await refused with
     | Error (Wake.Profile_unavailable {kind=Invalid_name;_}) -> incr profile_owner_refusals
     | Error error -> failf "%s: unexpected profile failure: %s" label (Wake.error_to_string error)
     | Ok _ -> failf "%s: invalid declaration owner reached async intake" label);
    check string (label ^ " retains original owner") (Journal.continuation_request_id recovery_candidate)
      (Journal.continuation_request_id (continuation ()));
    check (list string) (label ^ " starts no async worker") requests_before (active_requests ());
    check int (label ^ " performs no backend operation") before_completed_resume (List.length (calls fixture));
    (match Journal.continuation_readiness recovery_candidate with
     | Ok Journal.Results_ready -> ()
     | Ok Waiting_for_results | Error _ -> failf "%s: original wait is no longer ready" label) in
  write_profile ~declared_name:"continuation-foreign" false;
  assert_profile_owner_refused "maintenance rejects filename/declaration owner mismatch";
  write_profile false;
  let duplicate_declaration = Config_dir_resolver.keeper_toml_path_for_base_path
      ~base_path:fixture.base_path "continuation-duplicate" in
  Fun.protect ~finally:(fun () -> Unix.unlink duplicate_declaration) (fun () ->
    write_profile ~path:duplicate_declaration ~declared_name:keeper false;
    assert_profile_owner_refused "maintenance rejects duplicate declaration owner claims");
  write_profile false;
  let accepted,notify_accepted = Eio.Promise.create () in
  let accepted_callbacks = ref 0 and other_intakes = ref [] in
  (* A fresh supervisor proves durable discovery does not depend on the
     previous intake's process-local reservation. This is not an OS restart. *)
  let wake = Wake.create ~context ~on_result:(fun _ outcome -> match outcome with
      | Ok (Tool_result.Completed _ as result) ->
        incr accepted_callbacks; Eio.Promise.resolve notify_accepted result
      | Ok (Tool_result.Deferred _ | Tool_result.Failed _) | Error _ ->
        other_intakes := outcome :: !other_intakes) () in
  let recovery_started = Mtime_clock.counter () in
  Wake.pulse ~sw:context.sw wake |> require "actual provider-free maintenance pulse";
  Wake.pulse ~sw:context.sw wake |> require "repeated pulse while original intake is scheduled";
  let resumed = Eio.Promise.await accepted |> Tool_result.data in
  let ok, completed, completed_entry = await_composition env fixture resumed in
  let recovery_ms = Mtime.Span.to_float_ns (Mtime_clock.count recovery_started) /. 1_000_000. in
  if not ok then
    failf "original completed job resume failed: %s" (Yojson.Safe.to_string completed);
  check bool "original complete job continues the remaining DAG" true ok;
  check int "repeated maintenance pulses accept only one original worker" 1 !accepted_callbacks;
  let deferred_intakes,failed_intakes,unavailable_intakes = List.fold_left
      (fun (deferred,failed,unavailable) -> function
        | Ok (Tool_result.Deferred _) -> deferred+1,failed,unavailable
        | Ok (Tool_result.Failed _) -> deferred,failed+1,unavailable
        | Error _ -> deferred,failed,unavailable+1
        | Ok (Tool_result.Completed _) -> fail "accepted intake was recorded as a refusal")
      (0,0,0) !other_intakes in
  check string "run identity survives resumption" run_id (resumed |> member "composition_run_id" |> to_string);
  check int "completed result read has no backend operation" before_completed_resume (List.length (calls fixture));
  Printf.printf "OWNED_CONTINUATION_RECOVERY %s\n%!" (Yojson.Safe.to_string
    (`Assoc ["post_binding_losses",`Int (List.length [first_lost_entry;second_lost_entry]);
      "no_dispatch_wait_successors",`Int 2;
      "maintenance_pulse_to_continuation_completion_ms",`Float recovery_ms;
      "accepted_intakes",`Int !accepted_callbacks;
      "deferred_intakes",`Int deferred_intakes;
      "failed_intakes",`Int failed_intakes;
      "unavailable_intakes",`Int unavailable_intakes;
      "profile_owner_refusals",`Int !profile_owner_refusals;
      "backend_calls",`Int (List.length (calls fixture) - before_completed_resume);
      "unstarted_worker_calls",`Int !lost_worker_calls;
      "program_creates",`Int (effect_count fixture "create");
      "program_starts",`Int (effect_count fixture "start")]));
  check string "continuation does not rewrite original preparation evidence" draft_bytes
    (Tool_blob_store.fetch (Tool_blob_store.create ~base_path:fixture.base_path) ~sha256
      |> require "original preparation evidence after continuation"
      |> function Some bytes -> bytes | None -> fail "original draft disappeared");
  let completed_nodes = composition_nodes fixture completed in
  let final_wait = composition_node "await" completed_nodes in
  List.iter (fun field -> check_json ("original wait identity " ^ field)
      (awaiting |> member field) (final_wait |> member field)) ["execution_id";"tool_use_id"];
  List.iter (fun field -> check_json ("second wait keeps its own occurrence " ^ field)
      (composition_node "await-also" first_nodes |> member field)
      (composition_node "await-also" completed_nodes |> member field)) ["execution_id";"tool_use_id"];
  let original_sibling = composition_node "sibling" first_nodes
  and final_sibling = composition_node "sibling" completed_nodes in
  List.iter (fun field -> check_json ("completed sibling retains " ^ field)
      (original_sibling |> member field) (final_sibling |> member field)) ["execution_id";"tool_use_id";"result"];
  check_json "completed sibling never dispatches again" (`String "retained_completion")
    (final_sibling |> member "execution_origin");
  let consumer = composition_node "consumer" completed_nodes in
  check_json "consumer reads exact original stdout" (`String stdout_bytes)
    (consumer |> member "result" |> member "data" |> member "content");
  check_json "nonzero program exit remains explicit" (`Int 7)
    (final_wait |> member "result" |> member "data" |> member "exit_code");
  List.iter (fun entry ->
    let context = match entry.Masc.Keeper_msg_async.request_context with Some fields -> `Assoc fields | None -> fail "lost source context" in
    check_json "completion belongs to original Task" (`String "task-A") (context |> member "source_task_id"))
    [first_entry;completed_entry];
  (match Journal.waiting_continuation journal with
   | Ok None -> () | Ok (Some _) | Error _ -> fail "completed run remained a suspended candidate");
  (match Journal.continuation_readiness ready_continuation with
   | Error Journal.Ownership_changed -> ()
   | Ok _ | Error _ -> fail "stale candidate remained ready after its winner completed");
  let stale_worker_calls = ref 0 and stale_admission_error = ref None in
  let background_sw = Async.server_background_switch () |> require "server switch" in
  let stale = Async.submit_worker_with_request_id ?request_context:first_entry.request_context
      ~background_sw ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
      ~on_accepted:(fun request_id ->
        match Journal.bind_continuation ready_continuation ~request_id with
        | Error error -> stale_admission_error := Some error; Error (Journal.error_to_string error)
        | Ok _ -> Ok ())
      ~f:(fun ~request_id:_ _ ->
        incr stale_worker_calls;
        Async.worker_finished (Tool_result.make_ok ~tool_name:"stale-continuation"
          ~start_time:(Tool_timing.start ()) ())) () in
  (match stale,!stale_admission_error with
   | Error (Async.Acceptance_persistence_failed _),Some Journal.Ownership_changed -> ()
   | _ -> fail "stale continuation rebound after the competing worker completed");
  check int "a stale continuation never starts its worker" 0 !stale_worker_calls;
  let retired = pending () in
  check int "completed requests leave no ready continuation" 0 (List.length retired.ready);
  check int "completed request discovery has no unavailable authority" 0 (List.length retired.failures);
  let stable = pending () in
  check int "retirement leaves no pending marker work" 0 stable.inspected;
  check int "composition never recreates original program" 1 (effect_count fixture "create");
  check int "composition never restarts original program" 1 (effect_count fixture "start");
  (* A second prepared run proves a permanent intake refusal ends the run
     instead of re-forking it on every pulse: once the node contract changes,
     the sealed continuation is refused exactly once, the failure terminal is
     settled on the run's last async request and delivered through the
     composition completion outbox, and discovery drops the marker. *)
  let second_daemon_state = daemon fixture |> to_assoc in
  write fixture.daemon_path (Yojson.Safe.to_string (`Assoc
    (List.map (fun (name,value) -> name,(if name="container" then `Null else value))
       second_daemon_state)));
  control fixture (`Assoc ["state", `String "running"]);
  set_source fixture ~task_id:"task-C" ~turn:61;
  let second_id = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"start-second" ~turn:61 "keeper_job_start"
      (`Assoc ["argv", `List [`String "fixture-program-second"]; "inputs", `List []])) |> job_id in
  let second_literal value = `Assoc ["kind", `String "literal"; "value", value] in
  let second_node name tool input after = `Assoc ["id", `String name; "tool", `String tool;
      "input", input; "after", `List (List.map (fun name -> `String name) after)] in
  let second_recipe = `Assoc ["execution", `String "async";
      "nodes", `List [second_node "await-second" "keeper_job_result"
        (second_literal (argument second_id)) []]] in
  let second_prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-wait-second" ~turn:61 "keeper_composition_prepare" second_recipe) in
  let second_draft = second_prepared |> member "draft" |> composition_reference "second prepared draft" in
  let second_accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"run-wait-second" ~turn:61 "keeper_composition_run"
      (`Assoc ["sha256", `String second_draft.sha256])) in
  let second_ok, _, second_entry = await_composition env fixture second_accepted in
  check bool "second run suspends on its original job wait" false second_ok;
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 0]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-second" ~turn:61 "keeper_job_status" (argument second_id)));
  let second_ready = pending () in
  check int "completed second job is discovered without another event" 1 (List.length second_ready.ready);
  check int "second ready wait has readable original authority" 0 (List.length second_ready.failures);
  (* An outbox flush racing after an early obligation write while the record is
     still Waiting_for_owned_jobs retires that pre-settlement obligation, yet
     settle_waiting_request_as_failed re-establishes the obligation inside the
     store transition lock before overwriting the terminal record. *)
  let waiting_proof = Async.load_canonical_durable_terminal ~base_path:fixture.base_path
      ~caller:keeper second_entry.request_id |> require "canonical pre-settlement waiting proof" in
  Keeper_composition_completion_outbox.prepare_terminal ~proof:waiting_proof
    |> Result.map_error Keeper_composition_completion_outbox.error_to_string
    |> require "pre-settlement obligation write while waiting";
  (* Suspend the real acknowledgement between its canonical Waiting read and
     removal. A concurrent maintenance refusal must wait for that same lock;
     it then creates its obligation after the old one has been retired. *)
  write_profile true;
  let before_refusal_calls = List.length (calls fixture) in
  let raced_outcome = Eio.Switch.run (fun race_sw ->
    let waiting_read,notify_waiting_read = Eio.Promise.create () in
    let allow_delete,release_delete = Eio.Promise.create () in
    let acknowledged,notify_acknowledged = Eio.Promise.create () in
    Eio.Fiber.fork ~sw:race_sw (fun () ->
      let result = Keeper_composition_completion_outbox.For_testing.acknowledge_waiting
          ~after_waiting_read:(fun () ->
            Eio.Promise.resolve notify_waiting_read ();
            Eio.Promise.await allow_delete)
          ~base_path:fixture.base_path ~keeper_name:keeper
          ~request_id:second_entry.request_id ~composition_tool:"keeper_composition_run" in
      Eio.Promise.resolve notify_acknowledged result);
    Eio.Promise.await waiting_read;
    let refused,notify_refused = Eio.Promise.create () in
    let intake_completed = ref false in
    let denied_wake = Wake.create ~context ~on_result:(fun _ outcome ->
        intake_completed := true; Eio.Promise.resolve notify_refused outcome) () in
    let intake_started,notify_intake_started = Eio.Promise.create () in
    Eio.Fiber.fork ~sw:race_sw (fun () ->
      Eio.Promise.resolve notify_intake_started ();
      Wake.pulse ~sw:race_sw denied_wake
        |> require "maintenance refusal races the locked waiting acknowledgement");
    let blocked = Fun.protect
        ~finally:(fun () -> Eio.Promise.resolve release_delete ())
        (fun () ->
          Eio.Promise.await intake_started;
          Eio.Fiber.yield ();
          not !intake_completed) in
    check bool "refusal cannot pass the locked waiting read/delete interval" true blocked;
    Eio.Promise.await acknowledged
      |> Result.map_error Keeper_composition_completion_outbox.error_to_string
      |> require "racing waiting acknowledgement retires only its old obligation";
    Eio.Promise.await refused) in
  (match raced_outcome with
   | Ok result -> check bool "maintenance honors current TOML tool denial" true (Tool_result.is_failed result)
   | Error error -> fail (Wake.error_to_string error));
  check int "permanent refusal performs no backend operation" before_refusal_calls (List.length (calls fixture));
  let settled = Async.load_canonical_durable_terminal ~base_path:fixture.base_path
      ~caller:keeper second_entry.request_id |> require "permanent refusal settles the run terminal" in
  (match (Async.durable_terminal_entry settled).status with
   | Async.Done {ok=false; data=Some data; _} ->
     check_json "refusal settles the changed node contract"
       (`String "plan_rejected") (data |> member "kind");
     check_json "refusal names the node whose contract changed"
       (`String "unknown_tool") (data |> member "error" |> member "kind");
     check_json "refusal preserves the changed node identity"
       (`String "await-second") (data |> member "error" |> member "node_id")
   | status -> failf "permanent refusal did not settle a failure terminal: %s"
       (Async.status_to_string status));
  let reconcile = Masc.Keeper_composition_completion_wake.reconcile
      ~base_path:fixture.base_path |> require "permanent refusal completion outbox reconcile" in
  check int "exactly one refusal completion is delivered" 1 reconcile.delivered;
  let sources = Queue.pending_selections_result ~base_path:fixture.base_path keeper
    |> require "permanent refusal completion queue" in
  let failure_completions = List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
      match selection.source.payload with
      | Keeper_event_queue.Composition_completed completion
        when String.equal completion.cc_request_id second_entry.request_id ->
        (match completion.cc_terminal with
         | Keeper_event_queue.Composition_failed _ -> true
         | Keeper_event_queue.Composition_succeeded
         | Keeper_event_queue.Composition_cancelled _ -> false)
      | _ -> false) sources in
  check int "exactly one failure completion reaches the original Keeper" 1 (List.length failure_completions);
  let again = Masc.Keeper_composition_completion_wake.reconcile
      ~base_path:fixture.base_path |> require "permanent refusal completion outbox re-reconcile" in
  check int "a settled refusal delivers exactly once" 0 again.delivered;
  (* Discovery retires the marker, so the next pulse has 0 ready candidates. *)
  let after_refusal = pending () in
  check int "next discovery has no ready continuation" 0 (List.length after_refusal.ready);
  check int "permanently refused marker is retired" 1 after_refusal.retired;
  let quiet_wake = Wake.create ~context () in
  Wake.pulse ~sw:context.sw quiet_wake |> require "pulse after permanent refusal";
  check int "next pulse has 0 ready candidates" 0 (List.length (pending ()).ready);
  write_profile false;
  let restored_wake = Wake.create ~context () in
  Wake.pulse ~sw:context.sw restored_wake |> require "pulse after restoring the profile";
  check int "restored contract cannot resurrect a settled run" 0 (List.length (pending ()).ready);
  check (list string) "permanent refusal never starts an async worker" [] (active_requests ())

let test_historical_output_contract_refuses_current_resume () = with_fixture @@ fun env _initialize fixture ->
  let module Draft = Masc.Keeper_composition_draft in
  let module Plan = Masc.Keeper_tool_plan in
  let module Executor = Masc.Keeper_tool_plan_executor in
  let module Async = Masc.Keeper_msg_async in
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let recipe = `Assoc ["execution",`String "async";"nodes",`List
    [`Assoc ["id",`String "await";"tool",`String "keeper_job_result";
      "input",`Assoc ["kind",`String "literal";"value",argument id]]]] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"prepare-history"
      ~turn:41 "keeper_composition_prepare" recipe) in
  let current_reference = prepared |> member "draft" |> composition_reference "current canonical draft" in
  let surface = frozen_surface ~base_path:fixture.base_path ~sandbox_profile:fixture.meta.sandbox_profile in
  let current_draft = Draft.load ~base_path:fixture.base_path ~capability_surface:surface
      ~keeper_name:keeper ~sha256:current_reference.sha256 |> require "canonical current draft plan" in
  let store = Tool_blob_store.create ~base_path:fixture.base_path in
  let bytes = Tool_blob_store.fetch store ~sha256:current_reference.sha256
      |> require "canonical prepared manifest" |> function Some bytes -> bytes | None -> fail "draft missing" in
  let content,document = match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string bytes) with
    | Tool_output.Decoded_artifact_manifest {content;structured_content;_} -> content,structured_content
    | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ -> fail "invalid draft manifest" in
  let replace name value = function
    | `Assoc fields -> `Assoc ((name,value) :: List.remove_assoc name fields)
    | _ -> fail "historical fixture expected an object" in
  (* Authored historical evidence, not an old-binary execution claim. The
     current descriptor remains registry-owned. Only the previous frozen
     output definition differs, under a fresh durable artifact address. *)
  let rows = document |> member "contracts" |> member "tools" |> to_list in
  let rows = List.map (fun row ->
    let contract = row |> member "contract_json" |> to_string |> Yojson.Safe.from_string in
    let schema = contract |> member "output_schema" in
    let properties = schema |> member "properties" |> to_assoc in
    let schema = replace "properties"
        (`Assoc (("previous_optional_field",`Assoc ["type",`String "string"]) :: properties)) schema in
    let contract = replace "output_schema" schema contract in
    replace "contract_json" (`String (Yojson.Safe.to_string (Yojson.Safe.sort contract))) row) rows in
  let document = replace "contracts" (replace "tools" (`List rows) (document |> member "contracts")) document in
  let persist json = Tool_blob_store.put_durable store
      ~bytes:(Yojson.Safe.to_string (Tool_output.artifact_manifest_to_json ~content ~structured_content:json))
      ~mime:Tool_output.artifact_manifest_mime |> fun reference -> Tool_output.with_preview reference "" in
  let historical_reference = persist document in
  check bool "historical contract owns a different immutable artifact" true
    (historical_reference.sha256 <> current_reference.sha256);
  let composition_run_id = Plan.Composition_run_id.fresh () in
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"original-historical-run" ~turn:41
      ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Concurrent}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  let run_reference = persist (`Assoc
    ["draft",Tool_output.normalized_artifact_ref_to_json historical_reference;
     "nested_calls",document |> member "nested_calls";
     "nested_activation",`Null;
     "composition_run_id",`String (Plan.Composition_run_id.to_string composition_run_id);
     "tool_use_id",`String (Agent_core.Tool_contract.Invocation.tool_use_id invocation);
     "source_turn",`Int (Agent_core.Tool_contract.Invocation.turn invocation)]) in
  let source : Journal.source = {keeper_name=keeper;composition_run_id;
    draft_reference=historical_reference;run_reference;parent_tool_use_id="original-historical-run";
    source_turn=41;source_task_id=Some "task-A"} in
  let journal = Journal.prepare ~base_path:fixture.base_path source |> require "historical source journal" in
  let admitted = ref None in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
  let request_context =
    ["composition_run_id",`String (Plan.Composition_run_id.to_string source.composition_run_id);
     "draft_reference",Tool_output.normalized_artifact_ref_to_json source.draft_reference;
     "run_artifact",Tool_output.normalized_artifact_ref_to_json source.run_reference;
     "parent_tool_use_id",`String source.parent_tool_use_id;
     "source_turn",`Int source.source_turn;
     "source_task_id",`String "task-A"] in
  let accepted = Async.submit_worker_with_request_id ~request_context
      ~background_sw:(Async.server_background_switch () |> require "historical worker switch")
      ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
      ~on_accepted:(fun request_id -> match Journal.bind_request journal ~request_id with
        | Ok worker -> admitted := Some worker; Ok ()
        | Error error -> Error (Journal.error_to_string error))
      ~f:(fun ~request_id:_ request_sw ->
        let worker = match !admitted with Some worker -> worker | None -> fail "historical worker unbound" in
        let actual = Eio_context.with_turn_switch request_sw (fun () ->
          Executor.execute_keeper ~capability_surface:surface ~plan:(Draft.plan current_draft)
            ~run_id:(Plan.Run_id.fresh ()) ~composition_run_id ~parent_invocation:invocation
            ~config:(Workspace.default_config fixture.base_path) ~meta:fixture.meta ~publication_recovery
            ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"historical contract fixture")
            ~keeper_turn_id:(fun () -> Some 41)
            ~source_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
            ~clock:(Eio.Stdenv.clock env) ~journal:worker ()) in
        let node = match actual with
          | Error {cause=Executor.Tool_did_not_complete node;_} -> node
          | Ok _ | Error _ -> fail "actual original producer did not wait" in
        let job_id = match node.deferred_kind with
          | Some (Masc.Keeper_tool_execution.Owned_job_result_wait job_id) -> job_id
          | Some _ | None -> fail "actual original producer did not bind its job wait" in
        check string "historical wait uses the original actual job" id (Store.Job_id.to_string job_id);
        Async.worker_waiting_for_owned_jobs ~job_ids:[job_id] node.result |> require "historical worker wait") ()
      |> require "historical original worker acceptance" in
  ignore (await_composition env fixture (`Assoc ["request_id",`String accepted.request_id]));
  let capture () = match Journal.waiting_continuation journal with
    | Ok (Some candidate) -> candidate
    | Ok None | Error _ -> fail "historical original wait unavailable" in
  let continuation = capture () in
  let before = List.length (calls fixture) in
  let refused = Masc.Keeper_tool_composition_surface.resume_continuation ~capability_surface:surface
      ~continuation ~config:(Workspace.default_config fixture.base_path) ~meta:fixture.meta ~publication_recovery
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"current canonical intake")
      ~turn_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
      ~invocation ~clock:(Eio.Stdenv.clock env) () in
  check bool "changed original output contract refuses before async acceptance" true (Tool_result.is_failed refused);
  check_json "schema drift retains typed contract rejection" (`String "capability_changed")
    (Tool_result.data refused |> member "kind");
  check string "schema drift never recaptures original owner" accepted.request_id
    (Journal.continuation_request_id (capture ()));
  check string "schema drift preserves the historical draft identity" historical_reference.sha256
    (Journal.continuation_source (capture ())).draft_reference.sha256;
  check int "contract refusal has no backend operation" before (List.length (calls fixture));
  check int "contract refusal never relaunches original program" 1 (effect_count fixture "start")

let test_cancelled_continuation_cannot_restart () =
  List.iter (fun mode -> with_fixture @@ fun env _initialize fixture ->
    let module Async = Masc.Keeper_msg_async in
    set_source fixture ~task_id:"task-A" ~turn:41;
    Call_log.init ~base_path:fixture.base_path ();
    let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
    let recipe = `Assoc ["execution",`String "async";
      "nodes",`List [`Assoc ["id",`String "await";"tool",`String "keeper_job_result";
        "input",`Assoc ["kind",`String "literal";"value",argument id];"after",`List []]];
      "exports",`List [`Assoc ["name",`String "job";"node",`String "await";"pointer",`String "/job_id"]]] in
    let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"prepare-cancel"
        ~turn:41 "keeper_composition_prepare" recipe) in
    let sha256 = (prepared |> member "draft" |> composition_reference "cancellable draft").sha256 in
    let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"run-cancel"
        ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String sha256])) in
    let _, _, waiting_entry = await_composition env fixture accepted in
    let run_id = accepted |> member "composition_run_id" |> to_string
      |> Masc.Keeper_tool_plan.Composition_run_id.of_string |> require "cancelled original run UUID" in
    let journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper ~composition_run_id:run_id
      |> require "cancelled original journal" in
    let candidate = match Journal.waiting_continuation journal with
      | Ok (Some candidate) -> candidate
      | Ok None | Error _ -> fail "cancellation fixture has no original job wait" in
    let backend_before = List.length (calls fixture) in
    let worker_calls = ref 0 and intent = ref None in
    let admitted_worker = ref None in
    let entered, notify_entered = Eio.Promise.create () in
    let release, allow_return = Eio.Promise.create () in
    let settled, notify_settled = Eio.Promise.create () in
    let background_sw = match mode with
      | `Fork | `Startup -> Eio.Switch.run (fun sw -> sw)
      | `Signal_failure -> Async.server_background_switch () |> require "live cancelled worker switch" in
    let save_intent request_id =
      match Async.poll ~base_path:fixture.base_path ~caller:keeper request_id with
      | Found {status=Cancelling {reason;cancelled_by};_} -> intent := Some (reason,cancelled_by)
      | Found _ | Absent | Unreadable _ | Rejected _ -> fail "committed cancel intent is unavailable" in
    let submission = Async.submit_worker_with_request_id ?request_context:waiting_entry.request_context
        ~background_sw ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
        ~on_accepted:(fun request_id ->
          match Journal.bind_continuation candidate ~request_id with
          | Error error -> Error (Journal.error_to_string error)
          | Ok worker ->
            admitted_worker := Some worker;
            (match mode with
             | `Signal_failure -> ()
             | `Fork | `Startup ->
               (match Async.cancel ~base_path:fixture.base_path ~caller:keeper request_id with
                | Cancellation_requested Durably_committed -> ()
                | _ -> fail "pre-fork cancellation did not commit its exact intent");
               save_intent request_id);
            (* Explicit fixture process-memory reset leaves the actual durable
               Cancelling record for the exclusive startup recovery path. *)
            (match mode with
             | `Startup -> Async.For_testing.forget ~base_path:fixture.base_path ~caller:keeper ~request_id
             | `Fork | `Signal_failure -> ());
            Ok ())
        ~on_worker_settled:(fun _ -> Eio.Promise.resolve notify_settled ())
        ~f:(fun ~request_id:_ request_sw ->
          incr worker_calls;
          let worker = match !admitted_worker with Some worker -> worker
            | None -> fail "cancelled worker has no actual journal binding" in
          let surface = frozen_surface ~base_path:fixture.base_path ~sandbox_profile:fixture.meta.sandbox_profile in
          let draft = Masc.Keeper_composition_draft.load_continuation ~base_path:fixture.base_path
              ~capability_surface:surface candidate |> require "cancelled worker's original draft" in
          let source = Journal.continuation_source candidate in
          let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:source.parent_tool_use_id
              ~turn:source.source_turn ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Concurrent}
              ~completion:Agent_core.Tool_contract.Continue_after_success in
          let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
            {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
          let module Executor = Masc.Keeper_tool_plan_executor in
          let actual = Eio_context.with_turn_switch request_sw (fun () ->
            Executor.execute_keeper ~capability_surface:surface ~plan:(Masc.Keeper_composition_draft.plan draft)
              ~run_id:(Masc.Keeper_tool_plan.Run_id.fresh ()) ~composition_run_id:run_id ~parent_invocation:invocation
              ~config:(Workspace.default_config fixture.base_path) ~meta:fixture.meta ~publication_recovery
              ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"cancelled continuation fixture")
              ~keeper_turn_id:(fun () -> Some 41)
              ~source_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
              ~clock:(Eio.Stdenv.clock env) ~journal:worker ()) in
          let node = match actual with
            | Error {cause=Executor.Tool_did_not_complete node;_} -> node
            | Ok _ | Error _ -> fail "actual original job result did not produce a durable wait" in
          let job_id = match node.deferred_kind with
            | Some (Masc.Keeper_tool_execution.Owned_job_result_wait job_id) -> job_id
            | Some _ | None -> fail "actual producer did not own the deferred job identity" in
          Eio.Promise.resolve notify_entered ();
          Eio.Promise.await release;
          Async.worker_waiting_for_owned_jobs ~job_ids:[job_id] node.result
            |> require "actual cancelled worker wait") () in
    let request_id = match mode,submission with
      | (`Fork | `Startup), Error (Background_fork_failed {request_id;_} as error) ->
        let wire = Async.submit_error_to_json error in
        check_json "cancelled fork response keeps the exact request identity" (`String request_id)
          (wire |> member "request_id");
        check_json "fork failure transport cannot misreport cancellation as Lost" `Null
          (wire |> member "status");
        request_id
      | `Signal_failure, Ok outcome ->
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () -> Eio.Promise.await entered);
        let request_id = outcome.request_id in
        let ops = Async.For_testing.make_request_ops
            ~signal_cancel:(fun _ _ -> failwith "fixture worker cancellation signal failed") () in
        (match Async.For_testing.cancel ops ~base_path:fixture.base_path ~caller:keeper request_id with
         | Cancel_worker_signal_failed {durability=Durably_committed;_} -> ()
         | _ -> fail "failed cancellation signal did not retain durable operator intent");
        save_intent request_id;
        Eio.Promise.resolve allow_return ();
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () -> Eio.Promise.await settled);
        request_id
      | (`Fork | `Startup | `Signal_failure), (Error _ | Ok _) ->
        fail "cancellation scenario did not exercise its worker settlement boundary" in
    (match mode with
    | `Startup ->
      (match Async.poll ~base_path:fixture.base_path ~caller:keeper request_id with
       | Found {status=Cancelling _;_} -> ()
       | Found _ | Absent | Unreadable _ | Rejected _ -> fail "ordinary polling stole disk-only cancellation");
      let recovered = Async.recover_lost_disk_records ~base_path:fixture.base_path () in
      check int "startup does not turn operator cancellation into Lost" 0 recovered.lost;
      check int "startup finalizes the exact cancellation" 1 recovered.finalized;
      check int "startup cancellation settlement has no persistence failure" 0 recovered.failed
    | `Fork | `Signal_failure -> ());
    let terminal = Async.load_canonical_durable_terminal ~base_path:fixture.base_path ~caller:keeper request_id
      |> require "cancelled continuation canonical terminal" |> Async.durable_terminal_entry in
    (match terminal.status with
     | Cancelled {reason;cancelled_by} ->
       check (option (pair string string)) "terminal preserves exact cancellation reason and actor"
         !intent (Some (reason,cancelled_by))
     | _ -> fail "operator cancellation became a resumable Lost request");
    (match Journal.waiting_continuation journal with
     | Ok None -> () | Ok (Some _) | Error _ -> fail "cancelled original run regained continuation authority");
    let discovery = Journal.pending_continuations ~base_path:fixture.base_path |> require "cancelled pending discovery" in
    check int "cancelled owner dispatches no ready continuation" 0 (List.length discovery.ready);
    check int "cancelled owner retirement retains no unreadable evidence" 0 (List.length discovery.failures);
    check int "cancelled continuation admits only its original live worker"
      (match mode with `Signal_failure -> 1 | `Fork | `Startup -> 0) !worker_calls;
    check int "cancelled continuation has no backend effect" backend_before (List.length (calls fixture));
    check int "cancellation never relaunches the program" 1 (effect_count fixture "start"))
    [`Fork;`Startup;`Signal_failure]

let test_job_result_rejects_unavailable_authority () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let record = load fixture id in
  let owner = Filename.concat (Store.paths ~base_path:fixture.base_path record.job_id).job_dir "owner.jsonl" in
  write owner "{invalid-owner\n";
  let before = List.length (calls fixture) in
  with_bundle fixture (fun bundle ->
    match invoke_raw bundle ~tool_use_id:"result-corrupt" ~turn:41 "keeper_job_result" (argument id) with
    | Error _ -> () | Ok _ -> fail "unavailable authority was treated as a pending or complete result");
  check int "result authority failure performs no backend call" before (List.length (calls fixture))

module Completion_wake = Masc.Keeper_owned_job_completion_wake
module Event_registry = Masc.Keeper_registry_event_queue
module Intake = Masc.Keeper_heartbeat_stimulus_intake

let pending_completions fixture =
  Event_registry.pending_selections_result ~base_path:fixture.base_path keeper
  |> require "durable pending selections"
let recover_completions fixture =
  Completion_wake.reconcile ~config:(Workspace.default_config fixture.base_path)
  |> store_value "actual maintenance completion recovery"
let completion_payload (selection : Keeper_event_queue_state.pending_selection) =
  match selection.source.payload with
  | Keeper_event_queue.Owned_job_completed completion -> completion
  | _ -> fail "pending source is not the original job completion"
let only_selection fixture = match pending_completions fixture with
  | [selection] -> selection | _ -> fail "expected one durable original completion"
let owner_path fixture id =
  let paths = Store.paths ~base_path:fixture.base_path (load fixture id).job_id in
  Filename.concat paths.job_dir "owner.jsonl"
let check_no_completion fixture =
  check int "no terminal result is delivered prematurely" 0 (List.length (pending_completions fixture))
let check_artifact_bytes fixture expected json =
  match Tool_output.normalized_artifact_ref_of_json json with
  | Tool_output.Decoded_normalized_artifact_ref reference ->
    (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:fixture.base_path) ~sha256:reference.sha256 with
     | Ok (Some bytes) -> check string "complete original output remains retrievable" expected bytes
     | Ok None | Error _ -> fail "completed original output artifact is missing")
  | Tool_output.Not_normalized_artifact_ref | Tool_output.Invalid_normalized_artifact_ref _ ->
    fail "completion output is not a canonical artifact reference"

let test_completion_delivery_failure_and_restart () =
  let channel = Keeper_continuation_channel.dashboard ~thread_id:"original-task-thread"
    |> require "original submission channel" in
  with_fixture ~continuation_channel:channel @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  let original = load fixture id in
  check_json "owner captures the originating channel"
    (Keeper_continuation_channel.to_yojson channel)
    (Keeper_continuation_channel.to_yojson original.completion_channel);
  let running = recover_completions fixture in
  check int "running job remains pending" 1 running.waiting;
  check_no_completion fixture;
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "mode", `String "logs_unknown"]);
  let unavailable = recover_completions fixture in
  check int "exit without complete output keeps its obligation" 1 unavailable.waiting;
  check bool "exit alone is not a result" false (Store.result_ready (load fixture id));
  check_no_completion fixture;
  (* A real durable snapshot failure happens after the backend has delivered
     complete output. No producer callback or fabricated owner is substituted. *)
  let queue_path = Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path:fixture.base_path) keeper)
      Keeper_event_queue_schema.snapshot_filename in
  Fs_compat.mkdir_p (Filename.dirname queue_path);
  let prior = if Sys.file_exists queue_path then Some (read queue_path) else None in
  (match prior with Some _ -> Unix.unlink queue_path | None -> ());
  Unix.mkdir queue_path 0o700;
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 7]);
  let failed = recover_completions fixture in
  check int "failed enqueue is visible" 1 (List.length failed.failures);
  check bool "complete result committed before enqueue" true (Store.result_ready (load fixture id));
  check bool "failed delivery is not acknowledged" false (load fixture id).completion_delivered;
  let discovery = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "pending discovery" in
  check int "failed delivery stays discoverable" 1 (List.length discovery.entries);
  Unix.rmdir queue_path;
  (match prior with Some bytes -> write queue_path bytes | None -> ());
  Process_eio.reset_for_testing (); initialize ();
  set_source fixture ~task_id:"task-B" ~turn:52;
  let before = List.length (calls fixture) in
  let begin_recovery = Unix.gettimeofday () in
  let delivered = recover_completions fixture in
  let recovery_ms = (Unix.gettimeofday () -. begin_recovery) *. 1000. in
  check int "restart delivers the original complete result" 1 delivered.delivered;
  check int "durable result recovery needs no backend call" before (List.length (calls fixture));
  check bool "canonical owner acknowledges durable delivery" true (load fixture id).completion_delivered;
  let selection = only_selection fixture in
  let completion = completion_payload selection in
  check string "completion names original job" id (Store.Job_id.to_string completion.oj_job_id);
  check_json "completion retains original source" (Store.source_to_json original.source)
    (Keeper_owned_job_identity.source_to_json completion.oj_source);
  check_json "queue continuation routes to original conversation" (Keeper_continuation_channel.to_yojson channel)
    (Keeper_continuation_channel.to_yojson completion.oj_channel);
  check bool "the wake carries original routing" true
    (Keeper_event_queue.continuation_channel_of_payload selection.source.payload = Some channel);
  check bool "actual single-source turn defaults route to the original conversation" true
    (Masc.Keeper_unified_turn.continuation_channel_of_wake
       (Masc.Keeper_registry.Woken [selection.source.payload]) = Some channel);
  let decoded = Keeper_event_queue.stimulus_of_yojson (Keeper_event_queue.stimulus_to_yojson selection.source)
    |> require "strict durable completion round trip" in
  check bool "typed completion survives the queue wire" true
    (Keeper_event_queue.stimulus_identity_equal selection.source decoded);
  let inspect () = Intake.pending_board_events_of_stimulus_result
      ~base_path:fixture.base_path ~meta_after_triage:fixture.meta selection.source in
  let event = match inspect () with
    | Intake.Stimulus_consumed [event] -> event
    | _ -> fail "complete original result was not admitted to the next prompt" in
  (match event.Masc.Keeper_world_observation.event_kind with
   | Owned_job_completed carried ->
     check_json "model observation has the typed original source" (Store.source_to_json original.source)
       (Keeper_owned_job_identity.source_to_json carried.oj_source)
   | _ -> fail "model observation lost typed completion identity");
  let preview = Yojson.Safe.from_string event.preview in
  check bool "admitted result is available" true (preview |> member "result_available" |> to_bool);
  check int "nonzero exit remains exact observed result" 7 (preview |> member "result" |> member "exit_code" |> to_int);
  let outputs = preview |> member "result" |> member "artifacts" |> to_list in
  (match outputs with [stdout;stderr] ->
     check_artifact_bytes fixture stdout_bytes stdout;
     check_artifact_bytes fixture stderr_bytes stderr
   | _ -> fail "complete result did not retain both original output references");
  let path = owner_path fixture id in
  let owner_bytes = read path in
  write path "not a canonical owner journal\n";
  (match inspect () with
   | Intake.Stimulus_job_unavailable (job_id,_) ->
     check string "unavailable intake retains original identity" id (Store.Job_id.to_string job_id)
   | _ -> fail "unavailable owner was consumed as an empty Board row");
  check int "unreadable result remains durably pending" 1 (List.length (pending_completions fixture));
  write path owner_bytes;
  (match inspect () with Intake.Stimulus_consumed [_] -> () | _ -> fail "restored original owner cannot resume intake");
  let forged = {completion with oj_source={completion.oj_source with task_id=Some "task-B"}} in
  let forged_source = {selection.source with payload=Owned_job_completed forged} in
  (match Intake.pending_board_events_of_stimulus_result ~base_path:fixture.base_path
     ~meta_after_triage:fixture.meta forged_source with
   | Intake.Stimulus_job_unavailable _ -> () | _ -> fail "a different Task authorized the original result");
  Event_registry.ack_pending_result ~base_path:fixture.base_path keeper ~selection
    |> require "actual completion queue consumption";
  let again = recover_completions fixture in
  check int "acknowledged jobs leave the pending discovery partition" 0 again.inspected;
  check_no_completion fixture;
  check int "original command is created once" 1 (effect_count fixture "create");
  check int "original command is started once" 1 (effect_count fixture "start");
  Printf.printf "owned_job_completion_measurement=%s\n%!"
    (Yojson.Safe.to_string (`Assoc ["scope", `String "synthetic CLI public job, completed-output enqueue failure and restart recovery";
      "durable_result_recovery_ms", `Float recovery_ms; "backend_calls_on_delivery_recovery", `Int 0;
      "creates", `Int 1; "starts", `Int 1; "completion_notifications", `Int 1]))

let test_completion_consumed_before_producer_ack () = with_fixture @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 0]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"collect-original" ~turn:42
      "keeper_job_status" (argument id)));
  let record = load fixture id in
  check bool "complete result is durable at interruption boundary" true (Store.result_ready record);
  check bool "producer has not acknowledged delivery" false record.completion_delivered;
  (* Seed the actual durable enqueue at the interruption boundary. Consumption
     can finish before the producer CAS; recovery must consult queue evidence. *)
  let completion : Keeper_event_queue.owned_job_completion =
    {oj_job_id=record.job_id;oj_source=record.source;oj_channel=record.completion_channel} in
  let stimulus : Keeper_event_queue.stimulus =
    {post_id=Keeper_event_queue.owned_job_completion_post_id completion;urgency=Immediate;
     arrived_at=Unix.gettimeofday ();payload=Owned_job_completed completion} in
  (match Event_registry.enqueue_stimulus_once_durable_result ~base_path:fixture.base_path keeper stimulus with
   | Stimulus_enqueued -> () | _ -> fail "actual interruption-boundary enqueue failed");
  let selection = only_selection fixture in
  (match Event_registry.terminalize_pending_turn_completed_result
      ~base_path:fixture.base_path keeper ~applied_at:(Unix.gettimeofday ()) ~selection with
   | Ok (Event_registry.Turn_source_acked _) -> ()
   | Ok Event_registry.Turn_selection_withdrawn -> fail "original completion selection was withdrawn"
   | Error detail -> fail ("consumer terminalization failed: " ^ detail));
  let path = owner_path fixture id in
  let complete_prefix = read path in
  write path (complete_prefix ^ "{\"completion_delivered\":tr");
  (match Store.load ~base_path:fixture.base_path ~keeper_name:keeper record.job_id with
   | Error (Store.Corrupt _) -> () | _ -> fail "strict result read accepted a torn owner ACK");
  Process_eio.reset_for_testing (); initialize ();
  let before = List.length (calls fixture) in
  let report = recover_completions fixture in
  check int "consumed delivery closes its original producer obligation" 1 report.delivered;
  check_no_completion fixture;
  check bool "producer ACK follows existing durable consumer evidence" true (load fixture id).completion_delivered;
  check int "producer ACK recovery makes no backend command" before (List.length (calls fixture));
  check int "no original launch replay" 1 (effect_count fixture "start");
  let discovery = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "retired discovery" in
  check int "acknowledged marker is retired" 0 (List.length discovery.entries)

let test_completion_retains_unknown_launch_and_owner () = with_fixture @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control fixture (`Assoc ["mode", `String "create_unknown_absent"]);
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  Process_eio.reset_for_testing (); initialize ();
  set_source fixture ~task_id:"task-B" ~turn:52;
  let pending = recover_completions fixture in
  check int "unknown launch remains pending" 1 pending.waiting;
  check_no_completion fixture;
  check int "unknown create is not replayed by completion recovery" 1 (effect_count fixture "create");
  check int "unconfirmed original job is never started" 0 (effect_count fixture "start");
  let path = owner_path fixture id in
  let original = read path in
  let held = path ^ ".held" in
  Unix.rename path held;
  let missing = recover_completions fixture in
  check int "missing original authority remains visible" 1 (List.length missing.failures);
  check bool "recovery never creates a missing owner" false (Sys.file_exists path);
  Unix.rename held path;
  write path "corrupt original owner\n";
  let before = List.length (calls fixture) in
  let corrupt = recover_completions fixture in
  check int "unreadable original owner stays visible" 1 (List.length corrupt.failures);
  check int "corrupt authority authorizes no backend operation" before (List.length (calls fixture));
  check_no_completion fixture;
  let discovery = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "retained owner discovery" in
  check int "uncertain owner is not retired" 1 (List.length discovery.entries);
  write path original;
  ignore (recover_completions fixture);
  check int "restored owner still cannot repeat original create" 1 (effect_count fixture "create");
  check int "restored owner still cannot authorize an absent start" 0 (effect_count fixture "start")


let test_finished_without_outputs_absent_inventory_notified_once () = with_fixture @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  (* Confirmed exit first; output capture fails while the container exists. *)
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "mode", `String "logs_unknown"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"status-exited" ~turn:42
      "keeper_job_status" (argument id)));
  check bool "exit without outputs is not yet a result" false (Store.result_ready (load fixture id));
  check int "output capture attempted once" 1 (effect_count fixture "logs");
  (* The exact owned container is then removed externally. *)
  let state = daemon fixture |> to_assoc in
  write fixture.daemon_path (Yojson.Safe.to_string (`Assoc
      (List.map (fun (name, value) -> name, (if name = "container" then `Null else value)) state)));
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 7]);
  let delivered = recover_completions fixture in
  check int "absent inventory closes the finished job exactly once" 1 delivered.delivered;
  check int "closed job leaves the waiting set" 0 delivered.waiting;
  let record = load fixture id in
  check bool "closed terminal is a ready result" true (Store.result_ready record);
  (match record.outputs with
   | Some (Store.Outputs_unavailable {evidence}) ->
       check bool "closure carries exact absence evidence" true (String.length evidence > 0)
   | _ -> fail "finished job without outputs was not closed as unavailable");
  check bool "canonical owner acknowledged the one delivery" true record.completion_delivered;
  let discovery = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "retired discovery" in
  check int "delivery marker is retired by the one notification" 0 (List.length discovery.entries);
  check int "absence closure collects no further output commands" 1 (effect_count fixture "logs");
  let selection = only_selection fixture in
  let completion = completion_payload selection in
  check string "the one completion names the original job" id (Store.Job_id.to_string completion.oj_job_id);
  (* A later pulse sees no pending marker, so nothing is reinspected or redelivered. *)
  Process_eio.reset_for_testing (); initialize ();
  let again = recover_completions fixture in
  check int "retired job is not reinspected" 0 again.inspected;
  check int "completion is not duplicated" 1 (List.length (pending_completions fixture));
  Event_registry.ack_pending_result ~base_path:fixture.base_path keeper ~selection
    |> require "actual completion queue consumption";
  let after_ack = recover_completions fixture in
  check int "acknowledged closure stays retired" 0 after_ack.inspected;
  check_no_completion fixture;
  check int "closed job never relaunches" 1 (effect_count fixture "create");
  check int "closed job never restarts" 1 (effect_count fixture "start")

let test_running_absent_inventory_notified_once () = with_fixture @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  let initial = load fixture id in
  let container_id = match initial.phase with
    | Store.Running cid -> cid
    | _ -> fail "expected confirmed Running phase after start" in
  (* The exact owned container is removed externally while in Running phase (e.g. daemon reset). *)
  let state = daemon fixture |> to_assoc in
  write fixture.daemon_path (Yojson.Safe.to_string (`Assoc
      (List.map (fun (name, value) -> name, (if name = "container" then `Null else value)) state)));
  let delivered = recover_completions fixture in
  check int "absent inventory closes the running job exactly once" 1 delivered.delivered;
  check int "closed running job leaves the waiting set" 0 delivered.waiting;
  let record = load fixture id in
  check bool "closed running job is a ready result" true (Store.result_ready record);
  (match record.outputs with
   | Some (Store.Outputs_unavailable {evidence}) ->
       check bool "closure evidence names the absent container" true
         (String.length evidence > 0 && Astring.String.is_infix ~affix:container_id evidence)
   | _ -> fail "running job with absent inventory was not closed as unavailable");
  check bool "canonical owner acknowledged the one delivery" true record.completion_delivered;
  let discovery = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "retired discovery" in
  check int "delivery marker is retired by the one notification" 0 (List.length discovery.entries);
  let result_doc = with_bundle fixture (fun bundle ->
      invoke fixture bundle ~tool_use_id:"read-closed-running" ~turn:42 "keeper_job_result" (argument id)) in
  check string "keeper_job_result returns unavailable status" "unavailable"
    (result_doc |> member "status" |> to_string);
  Process_eio.reset_for_testing (); initialize ();
  let again = recover_completions fixture in
  check int "retired running job is not reinspected" 0 again.inspected;
  check int "completion is not duplicated" 1 (List.length (pending_completions fixture));
  check int "closed running job never relaunches" 1 (effect_count fixture "create");
  check int "closed running job never restarts" 1 (effect_count fixture "start")


let test_completion_hint_resumes_original_dag () = with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  let module Wake = Masc.Keeper_composition_continuation_wake in
  let module Async = Masc.Keeper_msg_async in
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let recipe = `Assoc ["execution",`String "async";"nodes",`List
      [`Assoc ["id",`String "await";"tool",`String "keeper_job_result";
         "input",`Assoc ["kind",`String "literal";"value",argument id]];
       `Assoc ["id",`String "consume";"tool",`String "keeper_artifact_read";
         "after",`List [`String "await"];
         "input",`Assoc ["kind",`String "object";"fields",`List
           [`Assoc ["name",`String "sha256";"value",`Assoc
             ["kind",`String "output";"node",`String "await";
              "pointer",`String "/artifacts/0/_blob/sha256"]]]]]]] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-hint" ~turn:41 "keeper_composition_prepare" recipe) in
  let reference = prepared |> member "draft" |> composition_reference "actual completion hint draft" in
  let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"run-hint" ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String reference.sha256])) in
  let ok,waiting,waiting_entry = await_composition env fixture accepted in
  check bool "original DAG is suspended before completion" false ok;
  (match waiting_entry.status with
   | Async.Waiting_for_owned_jobs {job_ids;_} ->
     check (list string) "completion hint has the original job wait" [id] (List.map Store.Job_id.to_string job_ids)
   | _ -> fail "original DAG was not canonically waiting for the job");
  let config = Workspace.default_config fixture.base_path in
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  write declaration "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Original completion hint fixture\"\n";
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  write runtime_path "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n";
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
      |> require "completion hint Skill publication authority" in
  Fun.protect ~finally:(fun () -> Skill_catalog_snapshot_service.retire ~workspace) @@ fun () ->
  (match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path;source_text=read runtime_path}) with
   | Published _ | Unchanged _ -> () | Workspace_retired -> fail "completion hint publication retired early");
  let context : _ Masc.Keeper_types_profile.context =
    {config;agent_name="completion-hint-fixture";
     sw=Async.server_background_switch () |> require "completion hint background switch";
     clock=Eio.Stdenv.clock env;proc_mgr=Some (Eio.Stdenv.process_mgr env);net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let resumed,notify_resumed = Eio.Promise.create () in
  let accepted_intakes = ref 0 and other_intakes = ref [] in
  let continuations = Wake.create ~context ~on_result:(fun _ outcome -> match outcome with
      | Ok (Tool_result.Completed _ as result) ->
        incr accepted_intakes; Eio.Promise.resolve notify_resumed result
      | Ok (Tool_result.Deferred _ | Tool_result.Failed _) | Error _ ->
        other_intakes := outcome :: !other_intakes) () in
  let hints = ref [] in
  let jobs = Completion_wake.create ~config ~on_result_ready:(fun (record : Store.record) ->
      hints := (record,Store.result_ready record,pending_completions fixture,List.length (calls fixture)) :: !hints;
      Wake.pulse ~sw:context.sw continuations |> require "actual durable completion hints original DAG") () in
  (* Change the current turn before the original job completes. No direct
     composition resume or independent continuation pulse follows this point. *)
  set_source fixture ~task_id:"task-B" ~turn:52;
  control fixture (`Assoc ["state",`String "exited";"exit_code",`Int 7]);
  let backend_before = List.length (calls fixture) in
  let completion_started = Mtime_clock.counter () in
  Completion_wake.pulse ~sw:context.sw jobs |> store_value "actual owned completion maintenance pulse";
  let resumed = Eio.Promise.await resumed |> Tool_result.data in
  let ok,completed,completed_entry = await_composition env fixture resumed in
  let completion_ms = Mtime.Span.to_float_ns (Mtime_clock.count completion_started) /. 1_000_000. in
  check bool "durable completion hint finishes the original DAG" true ok;
  check int "durable completion hint accepts one original worker" 1 !accepted_intakes;
  let record,ready,queued,backend_at_ready = match !hints with
    | [hint] -> hint | _ -> fail "expected exactly one original durable result hint" in
  check bool "hint follows full durable output" true ready;
  check string "hint identifies the original job" id (Store.Job_id.to_string record.job_id);
  check (option string) "hint keeps the original Task" (Some "task-A") record.source.task_id;
  let job_notifications = List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
      match selection.source.payload with
      | Keeper_event_queue.Owned_job_completed completion ->
        Store.Job_id.to_string completion.oj_job_id = id
      | _ -> false) queued in
  check int "original notification is durable before hint" 1 (List.length job_notifications);
  let rec await_original_ack () =
    if (load fixture id).completion_delivered then ()
    else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; await_original_ack ()) in
  await_original_ack ();
  check bool "ordinary completion ACK is retained" true (load fixture id).completion_delivered;
  check int "continuation does not query the backend after complete output" backend_at_ready (List.length (calls fixture));
  check string "completion keeps the original run" (accepted |> member "composition_run_id" |> to_string)
    (resumed |> member "composition_run_id" |> to_string);
  let waiting_nodes = waiting |> member "settled" |> to_list
  and completed_nodes = completed |> member "actions" |> to_list in
  let waiting_node = composition_node "await" waiting_nodes
  and completed_node = composition_node "await" completed_nodes in
  List.iter (fun field -> check_json ("completion hint keeps original occurrence " ^ field)
      (waiting_node |> member field) (completed_node |> member field)) ["execution_id";"tool_use_id"];
  check_json "hint consumer receives complete original stdout" (`String stdout_bytes)
    (composition_node "consume" completed_nodes |> member "result"
     |> member "data" |> member "content");
  let request_context = match completed_entry.request_context with
    | Some fields -> `Assoc fields | None -> fail "original hint completion has no source context" in
  check_json "hint completion belongs to original Task" (`String "task-A") (request_context |> member "source_task_id");
  check int "completion never recreates the original program" 1 (effect_count fixture "create");
  check int "completion never restarts the original program" 1 (effect_count fixture "start");
  Printf.printf "OWNED_COMPLETION_HINT_CONTINUATION %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["scope",`String "synthetic CLI public start/prepare/run and actual durable completion supervisor hint";
     "completion_pulse_to_original_dag_completion_ms",`Float completion_ms;
     "backend_calls_to_complete_original_job",`Int (backend_at_ready-backend_before);
     "backend_calls_after_result_ready",`Int (List.length (calls fixture)-backend_at_ready);
     "accepted_intakes",`Int !accepted_intakes;"other_intakes",`Int (List.length !other_intakes);
     "durable_job_notifications_before_hint",`Int (List.length job_notifications);
     "program_creates",`Int (effect_count fixture "create");"program_starts",`Int (effect_count fixture "start")]))


let test_prepared_job_launch_and_continuation () = with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  let module Wake = Masc.Keeper_composition_continuation_wake in
  let module Async = Masc.Keeper_msg_async in
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let recipe = `Assoc ["execution",`String "async";"nodes",`List
      [`Assoc ["id",`String "launch";"tool",`String "keeper_job_start";
         "input",`Assoc ["kind",`String "literal";"value",`Assoc
           ["argv",`List [`String "fixture-program"]]]];
       `Assoc ["id",`String "await";"tool",`String "keeper_job_result";
         "input",`Assoc ["kind",`String "object";"fields",`List
           [`Assoc ["name",`String "job_id";"value",`Assoc
             ["kind",`String "output";"node",`String "launch";"pointer",`String "/job_id"]]]]];
       `Assoc ["id",`String "consume";"tool",`String "keeper_artifact_read";
         "after",`List [`String "await"];
         "input",`Assoc ["kind",`String "object";"fields",`List
           [`Assoc ["name",`String "sha256";"value",`Assoc
             ["kind",`String "output";"node",`String "await";
              "pointer",`String "/artifacts/0/_blob/sha256"]]]]]]] in
  let prepare_started = Mtime_clock.counter () in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-hint" ~turn:41 "keeper_composition_prepare" recipe) in
  check bool "preparing a launch plan performs no backend operation" false (Sys.file_exists fixture.daemon_path);
  let reference = prepared |> member "draft" |> composition_reference "actual completion hint draft" in
  let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"run-hint" ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String reference.sha256])) in
  let ok,waiting,waiting_entry = await_composition env fixture accepted in
  let prepare_to_wait_ms = Mtime.Span.to_float_ns (Mtime_clock.count prepare_started) /. 1_000_000. in
  check bool "original DAG is suspended before completion" false ok;
  let id = match waiting_entry.status with
    | Async.Waiting_for_owned_jobs {job_ids=[id];_} -> Store.Job_id.to_string id
    | _ -> fail "prepared launch did not produce one canonical original job wait" in
  let waiting_nodes = waiting |> member "settled" |> to_list in
  let original_launch = composition_node "launch" waiting_nodes in
  check string "prepared launch result is the exact awaited job" id
    (original_launch |> member "result" |> member "data" |> member "job_id" |> to_string);
  let original_job = load fixture id in
  check (option string) "prepared launch belongs to the original Task" (Some "task-A") original_job.source.task_id;
  check (option string) "durable launch belongs to its exact node occurrence"
    (Some (original_launch |> member "tool_use_id" |> to_string)) original_job.source.tool_use_id;
  let before_refused_preparation = List.length (calls fixture) in
  let denied_job_id = Store.Job_id.fresh () |> Store.Job_id.to_string in
  List.iter (fun tool ->
    let unsupported = `Assoc ["execution",`String "async";"nodes",`List
      [`Assoc ["id",`String "unsupported";"tool",`String tool;
        "input",`Assoc ["kind",`String "literal";"value",argument denied_job_id]]]] in
    with_bundle fixture (fun bundle ->
      match invoke_raw bundle ~tool_use_id:("unsupported-" ^ tool) ~turn:41 "keeper_composition_prepare" unsupported with
      | Error _ -> () | Ok _ -> failf "prepared launch admission also admitted %s" tool))
    ["keeper_job_status";"keeper_job_cancel"];
  check int "refused status/cancel preparation performs no backend operation" before_refused_preparation (List.length (calls fixture));
  let config = Workspace.default_config fixture.base_path in
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  write declaration "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Original completion hint fixture\"\n";
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  write runtime_path "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n";
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
      |> require "completion hint Skill publication authority" in
  Fun.protect ~finally:(fun () -> Skill_catalog_snapshot_service.retire ~workspace) @@ fun () ->
  (match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path;source_text=read runtime_path}) with
   | Published _ | Unchanged _ -> () | Workspace_retired -> fail "completion hint publication retired early");
  let context : _ Masc.Keeper_types_profile.context =
    {config;agent_name="completion-hint-fixture";
     sw=Async.server_background_switch () |> require "completion hint background switch";
     clock=Eio.Stdenv.clock env;proc_mgr=Some (Eio.Stdenv.process_mgr env);net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let resumed,notify_resumed = Eio.Promise.create () in
  let accepted_intakes = ref 0 and other_intakes = ref [] in
  let continuations = Wake.create ~context ~on_result:(fun _ outcome -> match outcome with
      | Ok (Tool_result.Completed _ as result) ->
        incr accepted_intakes; Eio.Promise.resolve notify_resumed result
      | Ok (Tool_result.Deferred _ | Tool_result.Failed _) | Error _ ->
        other_intakes := outcome :: !other_intakes) () in
  let hints = ref [] in
  let jobs = Completion_wake.create ~config ~on_result_ready:(fun (record : Store.record) ->
      hints := (record,Store.result_ready record,pending_completions fixture,List.length (calls fixture)) :: !hints;
      Wake.pulse ~sw:context.sw continuations |> require "actual durable completion hints original DAG") () in
  (* Change the current turn before the original job completes. No direct
     composition resume or independent continuation pulse follows this point. *)
  set_source fixture ~task_id:"task-B" ~turn:52;
  control fixture (`Assoc ["state",`String "exited";"exit_code",`Int 7]);
  let backend_before = List.length (calls fixture) in
  let completion_started = Mtime_clock.counter () in
  Completion_wake.pulse ~sw:context.sw jobs |> store_value "actual owned completion maintenance pulse";
  let resumed = Eio.Promise.await resumed |> Tool_result.data in
  let ok,completed,completed_entry = await_composition env fixture resumed in
  let completion_ms = Mtime.Span.to_float_ns (Mtime_clock.count completion_started) /. 1_000_000. in
  check bool "durable completion hint finishes the original DAG" true ok;
  check int "durable completion hint accepts one original worker" 1 !accepted_intakes;
  let record,ready,queued,backend_at_ready = match !hints with
    | [hint] -> hint | _ -> fail "expected exactly one original durable result hint" in
  check bool "hint follows full durable output" true ready;
  check string "hint identifies the original job" id (Store.Job_id.to_string record.job_id);
  check (option string) "hint keeps the original Task" (Some "task-A") record.source.task_id;
  let job_notifications = List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
      match selection.source.payload with
      | Keeper_event_queue.Owned_job_completed completion ->
        Store.Job_id.to_string completion.oj_job_id = id
      | _ -> false) queued in
  check int "original notification is durable before hint" 1 (List.length job_notifications);
  let rec await_original_ack () =
    if (load fixture id).completion_delivered then ()
    else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; await_original_ack ()) in
  await_original_ack ();
  check bool "ordinary completion ACK is retained" true (load fixture id).completion_delivered;
  check int "continuation does not query the backend after complete output" backend_at_ready (List.length (calls fixture));
  check string "completion keeps the original run" (accepted |> member "composition_run_id" |> to_string)
    (resumed |> member "composition_run_id" |> to_string);
  let completed_nodes = completed |> member "actions" |> to_list in
  let waiting_node = composition_node "await" waiting_nodes
  and completed_node = composition_node "await" completed_nodes in
  List.iter (fun field -> check_json ("completion hint keeps original occurrence " ^ field)
      (waiting_node |> member field) (completed_node |> member field)) ["execution_id";"tool_use_id"];
  let retained_launch = composition_node "launch" completed_nodes in
  List.iter (fun field -> check_json ("completed launch retains original " ^ field)
      (original_launch |> member field) (retained_launch |> member field)) ["execution_id";"tool_use_id";"result"];
  check_json "completed effectful launch is reused without dispatch" (`String "retained_completion")
    (retained_launch |> member "execution_origin");
  check_json "hint consumer receives complete original stdout" (`String stdout_bytes)
    (composition_node "consume" completed_nodes |> member "result"
     |> member "data" |> member "content");
  let request_context = match completed_entry.request_context with
    | Some fields -> `Assoc fields | None -> fail "original hint completion has no source context" in
  check_json "hint completion belongs to original Task" (`String "task-A") (request_context |> member "source_task_id");
  check int "completion never recreates the original program" 1 (effect_count fixture "create");
  check int "completion never restarts the original program" 1 (effect_count fixture "start");
  Printf.printf "OWNED_PREPARED_JOB_LAUNCH_CONTINUATION %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["scope",`String "synthetic CLI public prepare/run launching an owned job within the original DAG";
     "prepare_and_launch_to_saved_job_wait_ms",`Float prepare_to_wait_ms;
     "completion_pulse_to_original_dag_completion_ms",`Float completion_ms;
     "backend_calls_to_complete_original_job",`Int (backend_at_ready-backend_before);
     "backend_calls_after_result_ready",`Int (List.length (calls fixture)-backend_at_ready);
     "accepted_intakes",`Int !accepted_intakes;"other_intakes",`Int (List.length !other_intakes);
     "durable_job_notifications_before_hint",`Int (List.length job_notifications);
     "program_creates",`Int (effect_count fixture "create");"program_starts",`Int (effect_count fixture "start")]))

let invocation_binding_job_ids fixture =
  let directory = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:fixture.base_path)
         "keeper_msg_requests") "owned_job_invocations" in
  Array.to_list (Sys.readdir directory)
  |> List.filter (fun name -> Filename.check_suffix name ".json")
  |> List.map (fun name ->
      Yojson.Safe.from_file (Filename.concat directory name) |> member "job_id" |> to_string)

let test_interrupted_prepared_launch_resumes_the_same_job () = with_fixture @@ fun env initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  let module Async = Masc.Keeper_msg_async in
  let module Draft = Masc.Keeper_composition_draft in
  let module Plan = Masc.Keeper_tool_plan in
  let module Executor = Masc.Keeper_tool_plan_executor in
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  control fixture (`Assoc ["mode", `String "start_blocked"]);
  let recipe = `Assoc
    [ "execution", `String "async"
    ; "nodes", `List
        [ `Assoc
            [ "id", `String "launch"
            ; "tool", `String "keeper_job_start"
            ; "input", `Assoc
                [ "kind", `String "literal"
                ; "value", `Assoc ["argv", `List [`String "fixture-program"]] ] ] ] ] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-interrupted" ~turn:41 "keeper_composition_prepare" recipe) in
  let reference = prepared |> member "draft" |> composition_reference "interrupted launch draft" in
  let capability_surface = frozen_surface ~base_path:fixture.base_path ~sandbox_profile:fixture.meta.sandbox_profile in
  let draft = Draft.load ~base_path:fixture.base_path ~capability_surface ~keeper_name:keeper
      ~sha256:reference.sha256 |> require "interrupted launch draft" in
  let composition_run_id = Plan.Composition_run_id.fresh () in
  let parent_invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"run-interrupted"
      ~turn:41 ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Agent_core.Tool_contract.Serial}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  let run_reference = Draft.record_invocation ~base_path:fixture.base_path ~composition_run_id
      ~invocation:parent_invocation draft |> require "interrupted launch run artifact" in
  let source : Journal.source =
    { keeper_name = keeper; composition_run_id
    ; draft_reference = Draft.reference draft; run_reference
    ; parent_tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation
    ; source_turn = 41; source_task_id = Some "task-A" } in
  let journal = Journal.prepare ~base_path:fixture.base_path source |> require "interrupted launch journal" in
  let request_context = Some
      [ "composition_tool", `String Draft.run_tool_name
      ; "parent_tool_use_id", `String source.parent_tool_use_id
      ; "source_turn", `Int 41
      ; "composition_run_id", `String (Plan.Composition_run_id.to_string composition_run_id)
      ; "draft_reference", Tool_output.normalized_artifact_ref_to_json source.draft_reference
      ; "run_artifact", Tool_output.normalized_artifact_ref_to_json source.run_reference
      ; "source_task_id", `String "task-A" ] in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
  let config = Workspace.default_config fixture.base_path in
  let execute worker request_sw =
    Eio_context.with_turn_switch request_sw (fun () ->
      Executor.execute_keeper ~capability_surface ~plan:(Draft.plan draft)
        ~run_id:(Plan.Run_id.fresh ()) ~composition_run_id ~parent_invocation
        ~config ~meta:fixture.meta ~publication_recovery
        ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"interrupted launch fixture")
        ~keeper_turn_id:(fun () -> Some 41)
        ~source_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
        ~clock:(Eio.Stdenv.clock env) ~journal:worker ()) in
  (* The first worker reaches the launch effect; the synthetic transport keeps
     the start reply, and the abandoned worker leaves the launch leaf
     Attempting between begin_attempt and settle_attempt. *)
  let worker1 = ref None in
  let settled1, notify_settled1 = Eio.Promise.create () in
  let first = Async.submit_worker_with_request_id ?request_context
      ~background_sw:(Async.server_background_switch () |> require "interrupted worker switch")
      ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
      ~on_accepted:(fun request_id ->
        match Journal.bind_request journal ~request_id with
        | Ok worker -> worker1 := Some worker; Ok ()
        | Error error -> Error (Journal.error_to_string error))
      ~on_worker_settled:(Eio.Promise.resolve notify_settled1)
      ~f:(fun ~request_id:_ request_sw ->
        let worker = match !worker1 with Some worker -> worker | None -> fail "unbound interrupted worker" in
        let rec await_start () =
          if Sys.file_exists (Filename.concat fixture.base_path "start-entered") then ()
          else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.005; await_start ()) in
        let interrupted = Eio.Fiber.first
            (fun () -> ignore (execute worker request_sw); false)
            (fun () -> await_start (); true) in
        check bool "start reply interrupted after the launch effect" true interrupted;
        Async.worker_finished (Tool_result.make_err ~tool_name:Draft.run_tool_name
          ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Effect_outcome_unknown
          ~start_time:(Tool_timing.start ()) "interrupted launch worker")) () in
  ignore first;
  ignore (Eio.Promise.await settled1);
  let bound_ids = invocation_binding_job_ids fixture in
  check int "interrupted launch reserved exactly one job" 1 (List.length bound_ids);
  let id = List.hd bound_ids in
  (match (load fixture id).phase with
   | Store.Start_requested _ -> ()
   | _ -> fail "interrupted launch did not retain its exact start intent");
  check int "interrupted launch created the job exactly once" 1 (effect_count fixture "create");
  check int "interrupted launch started the program exactly once" 1 (effect_count fixture "start");
  (match Journal.lookup (Option.get !worker1) ~node_id:(Plan.Node_id.make "launch" |> require "launch node")
        ~tool_name:"keeper_job_start" ~input:(`Assoc ["argv", `List [`String "fixture-program"]]) with
   | Ok (Journal.Recheck_launch replay) ->
     check string "interrupted launch replay preserves its recorded trace"
       (Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) replay.Journal.invocation.trace_id;
     check int "interrupted launch replay preserves its recorded turn" 41
       (Ids.Turn_ref.absolute_turn replay.Journal.invocation.turn_ref)
   | Ok _ -> fail "interrupted launch leaf did not authorize a launch replay"
   | Error error -> fail (Journal.error_to_string error));
  Process_eio.reset_for_testing (); initialize ();
  (* A later turn resumes the run. The ambient identity differs from the
     recorded one; replay must still reach the same owned job. *)
  set_source fixture ~task_id:"task-A" ~turn:52;
  let worker2 = ref None and executed2 = ref None in
  let settled2, notify_settled2 = Eio.Promise.create () in
  let second = Async.submit_worker_with_request_id ?request_context
      ~background_sw:(Async.server_background_switch () |> require "resuming worker switch")
      ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
      ~on_accepted:(fun request_id ->
        match Journal.bind_request journal ~request_id with
        | Ok worker -> worker2 := Some worker; Ok ()
        | Error error -> Error (Journal.error_to_string error))
      ~on_worker_settled:(Eio.Promise.resolve notify_settled2)
      ~f:(fun ~request_id:_ request_sw ->
        let worker = match !worker2 with Some worker -> worker | None -> fail "unbound resuming worker" in
        let result = execute worker request_sw in
        executed2 := Some result;
        match result with
        | Ok _rows ->
          Async.worker_finished (Masc.Keeper_types_profile.tool_result_ok_data
            ~tool_name:Draft.run_tool_name (`Assoc ["composition_run_id",
              `String (Plan.Composition_run_id.to_string composition_run_id)]))
        | Error _failure ->
          Async.worker_finished (Masc.Keeper_types_profile.tool_result_error_data
            ~tool_name:Draft.run_tool_name ~class_:Tool_result.Runtime_failure
            ~effect_disposition:Tool_result.Effect_outcome_unknown
            (`Assoc ["composition_run_id", `String (Plan.Composition_run_id.to_string composition_run_id)])))
      () in
  ignore second;
  ignore (Eio.Promise.await settled2);
  let rows = match !executed2 with
    | Some (Ok rows) -> rows
    | Some (Error _) | None -> fail "resumed launch run did not complete" in
  let resumed_launch = List.find
      (fun (row : Executor.node_result) ->
         Plan.Node_id.equal row.Executor.node_id (Plan.Node_id.make "launch" |> require "launch node"))
      rows in
  check bool "resumed launch settles fresh" true
    (resumed_launch.execution_origin = Executor.Fresh_dispatch);
  let job = load fixture id in
  check string "resumed launch returns the same job" id (Store.Job_id.to_string job.job_id);
  check int "resume never recreates the original program" 1 (effect_count fixture "create");
  check int "resume never restarts the original program" 1 (effect_count fixture "start");
  let terminal = Async.load_canonical_durable_terminal ~base_path:fixture.base_path ~caller:keeper
      (match second with Ok outcome -> outcome.request_id | Error _ -> fail "resume not accepted")
    |> require "resumed canonical terminal" |> Async.durable_terminal_entry in
  (match terminal.status with
   | Async.Done {ok=true;_} -> ()
   | _ -> fail "resumed launch run did not settle successfully");
  Printf.printf "OWNED_INTERRUPTED_LAUNCH_RESUME job=%s phase=%s\n%!" id
    (match job.phase with Store.Running _ -> "running" | _ -> "other")

exception Fixture_result_observer_failed

let test_completion_pulse_does_not_join_blocked_backend () = with_fixture @@ fun env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let running = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let blocked_id = job_id running in
  let config = Workspace.default_config fixture.base_path in
  let failed_observers = ref [] in
  let supervisor = Completion_wake.create ~config ~on_result_ready:(fun (record : Store.record) ->
      failed_observers := record.job_id :: !failed_observers;
      raise Fixture_result_observer_failed) () in
  let entered = Filename.concat fixture.base_path "inspect-entered" in
  let release = Filename.concat fixture.base_path "inspect-release" in
  control fixture (`Assoc ["mode", `String "inspect_blocked"; "blocked_job_id", `String blocked_id]);
  (* Fixture deadlock guard only. The production pulse has no deadline. *)
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. @@ fun () ->
  Eio.Switch.run @@ fun job_sw ->
  Completion_wake.pulse ~sw:job_sw supervisor |> store_value "actual nonblocking maintenance pulse";
  let rec await_condition condition =
    if condition () then () else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; await_condition condition) in
  await_condition (fun () -> Sys.file_exists entered);
  check bool "shared maintenance control returned while backend remains blocked" false (Sys.file_exists release);
  (* The peer retains the blocked inspection's old container snapshot. Open a
     separate original job while that process waits; durable completed output
     recovery of this new job must not join the older inspection. *)
  let state = daemon fixture |> to_assoc in
  write fixture.daemon_path (Yojson.Safe.to_string (`Assoc
    (List.map (fun (name,value) -> name,(if name="container" then `Null else value)) state)));
  set_source fixture ~task_id:"task-B" ~turn:52;
  let later = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"start-independent" ~turn:52 "keeper_job_start"
      (`Assoc ["argv", `List [`String "fixture-program"]])) in
  let later_id = job_id later in
  check bool "independent work owns a distinct original job" true (later_id <> blocked_id);
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 0;
      "mode", `String "inspect_blocked"; "blocked_job_id", `String blocked_id]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-independent" ~turn:53 "keeper_job_status" (argument later_id)));
  let calls_before = List.length (calls fixture) in
  Completion_wake.pulse ~sw:job_sw supervisor |> store_value "next pulse admits independent recovery";
  await_condition (fun () -> List.length (pending_completions fixture) = 1
      && (load fixture later_id).completion_delivered);
  let completion = only_selection fixture |> completion_payload in
  check string "new completed job delivers while older backend is blocked" later_id
    (Store.Job_id.to_string completion.oj_job_id);
  check int "active blocked worker is not duplicated by another pulse" calls_before (List.length (calls fixture));
  check (list string) "failed observer cannot block the independent result ACK" [later_id]
    (List.map Store.Job_id.to_string !failed_observers);
  check bool "pending first job has not been misclassified completed" false (load fixture blocked_id).completion_delivered;
  write release "continue the original inspection\n";
  Printf.printf "owned_job_completion_supervisor_measurement=%s\n%!"
    (Yojson.Safe.to_string (`Assoc ["scope", `String "synthetic CLI actual maintenance supervisor";
      "pulse_returned_before_backend_release", `Bool true;
      "new_job_delivered_before_backend_release", `Bool true;
      "failed_result_observers", `Int (List.length !failed_observers);
      "duplicate_blocked_worker_backend_calls", `Int 0]))


let test_completion_recovery_preserves_refused_owner_bytes () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let first_id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let first_path = owner_path fixture first_id in
  let original_first = read first_path in
  let state = daemon fixture |> to_assoc in
  write fixture.daemon_path (Yojson.Safe.to_string (`Assoc
    (List.map (fun (name,value) -> name,(if name="container" then `Null else value)) state)));
  set_source fixture ~task_id:"task-B" ~turn:52;
  let foreign_id = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"start-foreign" ~turn:52 "keeper_job_start"
      (`Assoc ["argv", `List [`String "fixture-program"]])) |> job_id in
  control fixture (`Assoc ["state", `String "exited"; "exit_code", `Int 0]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-foreign" ~turn:53 "keeper_job_status" (argument foreign_id)));
  let foreign_prefix = read (owner_path fixture foreign_id) in
  let foreign_bytes = foreign_prefix ^ "{\"completion_delivered\":tr" in
  write first_path foreign_bytes;
  let before = List.length (calls fixture) in
  let refused = recover_completions fixture in
  check int "foreign complete prefix is refused before tail repair" 1 (List.length refused.failures);
  check string "foreign owner and torn suffix retain all original evidence" foreign_bytes (read first_path);
  check int "foreign authority authorizes no backend call" before (List.length (calls fixture));
  check string "valid independent original result still delivers" foreign_id
    (Store.Job_id.to_string (only_selection fixture |> completion_payload).oj_job_id);
  let corrupt_bytes = "complete malformed owner row\n{\"partial\":" in
  write first_path corrupt_bytes;
  let corrupt = recover_completions fixture in
  check int "complete malformed prefix stays refused" 1 (List.length corrupt.failures);
  check string "complete corruption and incomplete suffix remain byte-identical" corrupt_bytes (read first_path);
  check int "corrupt authority authorizes no backend call" before (List.length (calls fixture));
  write first_path original_first;
  check bool "original authority remains recoverable after restoration" false (load fixture first_id).completion_delivered


let () =
  Printf.printf "owned_job_feature_transport=synthetic_docker_cli actual_public_handler=true actual_docker_execution=false\n%!";
  run "Keeper owned jobs"
    ["public lifecycle",
      [ test_case "structured launch, original source, restart and artifact ownership" `Quick test_running_restart_exit_and_artifacts
      ; test_case "unknown create absence cannot relaunch" `Quick test_unknown_create_absence_never_replays
      ; test_case "unknown start absence cannot restart" `Quick test_unknown_start_absence_never_replays
      ; test_case "cancelled absent create closes terminally" `Quick test_cancelled_unconfirmed_launch_closes_absent_create
      ; test_case "late same-label container stays an orphan" `Quick test_cancelled_unconfirmed_launch_treats_late_container_as_orphan
      ; test_case "interrupted cancellation retains exact intent" `Quick test_cancel_in_flight_retains_exact_intent
      ; test_case "changed mount or cloned identity cannot authorize a kill" `Quick test_changed_mount_cannot_authorize_cancel
      ; test_case "large stdout and stderr preserve complete original artifacts" `Quick test_large_streams_publish_complete_original_artifacts
      ; test_case "lost start reply recovers the original job" `Quick test_lost_start_reply_recovers_original_job
      ; test_case "original invocation rejects request and source rebinding" `Quick test_original_invocation_rejects_rebinding
      ; test_case "corrupt invocation authority cannot launch" `Quick test_corrupt_invocation_binding_cannot_launch
      ; test_case "malformed whole source cannot publish a binding" `Quick test_malformed_source_cannot_publish_binding
      ; test_case "public Composition waits and resumes the original job result" `Quick test_public_composition_wait_and_resume
      ; test_case "historical output contract refuses current canonical resume" `Quick test_historical_output_contract_refuses_current_resume
      ; test_case "cancelled continuation preserves intent at fork, startup and signal failure" `Quick test_cancelled_continuation_cannot_restart
      ; test_case "job result rejects unavailable owner authority" `Quick test_job_result_rejects_unavailable_authority
      ; test_case "completion enqueue failure recovers original result after restart" `Quick test_completion_delivery_failure_and_restart
      ; test_case "consumed notification survives missing producer ACK" `Quick test_completion_consumed_before_producer_ack
      ; test_case "completion recovery retains unknown launch and corrupt owner" `Quick test_completion_retains_unknown_launch_and_owner
      ; test_case "finished without outputs and absent inventory is notified once and leaves waiting" `Quick test_finished_without_outputs_absent_inventory_notified_once
      ; test_case "running with absent inventory is notified once and leaves waiting" `Quick test_running_absent_inventory_notified_once
      ; test_case "durable completion hint resumes original DAG without a provider turn" `Quick test_completion_hint_resumes_original_dag
      ; test_case "prepared DAG launches an owned job and resumes its original result" `Quick test_prepared_job_launch_and_continuation
      ; test_case "interrupted prepared launch resumes the same job without recreating it" `Quick test_interrupted_prepared_launch_resumes_the_same_job
      ; test_case "maintenance admits new job recovery while another backend is blocked" `Quick test_completion_pulse_does_not_join_blocked_backend
      ; test_case "recovery keeps refused foreign and corrupt owner bytes intact" `Quick test_completion_recovery_preserves_refused_owner_bytes ]]
