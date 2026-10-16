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
let docker_peer = {|import csv, hashlib, json, pathlib, sys, time
root = pathlib.Path(__file__).parent
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

let frozen_surface ~base_path ~sandbox_profile =
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
  let global_skill_catalog, diagnostics = Masc.Keeper_skill_catalog.of_snapshot snapshot in
  check int "frozen skill catalog has no diagnostics" 0 (List.length diagnostics);
  Masc.Keeper_capability_surface.create ~tool_deny:[] ~sandbox_profile ~skill_names:None
    ~global_skill_catalog ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot snapshot) ~task_skills:[]

let with_environment values f =
  let rec loop = function
    | [] -> f ()
    | (name, value) :: rest -> Masc_test_deps.with_process_env name value (fun () -> loop rest)
  in loop values

let with_fixture f =
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
  let surface = frozen_surface ~base_path ~sandbox_profile:meta.sandbox_profile in
  let cell = Call_log.create_turn_ctx_cell () in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
  let make_bundle () = Bundle.make_tool_bundle_for_capability_surface
      ~config ~meta ~publication_recovery ~capability_surface:surface
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"owned job fixture")
      ~clock:(Eio.Stdenv.clock env) ~turn_ctx_cell:cell () in
  let fixture = {base_path;meta;cell;make_bundle;
      control_path=Filename.concat base_path "control.json";
      daemon_path=Filename.concat base_path "daemon.json";
      kill_marker=Filename.concat base_path "kill-entered"} in
  f env initialize_transport fixture

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
  check bool "job tool remains ordinary Serial" true
    (Agent_core.Tool.execution_mode tool ~input = Agent_core.Tool_contract.Serial);
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id ~turn
      ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Agent_core.Tool_contract.Serial}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  Agent_core.Tool.execute ~invocation tool input

let invoke fixture bundle ~tool_use_id ~turn name input =
  match invoke_raw bundle ~tool_use_id ~turn name input with
  | Ok output -> result_document ~base_path:fixture.base_path output.content
  | Error error -> failf "public job handler failed: %s" error.Agent_core.Types.message

let job_id json = json |> member "job_id" |> to_string
let argument id = `Assoc ["job_id", `String id]
let load fixture id =
  Store.Job_id.of_string id |> require "typed job id"
  |> Store.load ~base_path:fixture.base_path ~keeper_name:keeper |> store_value "canonical durable job"
let with_bundle fixture f =
  let bundle = fixture.make_bundle () in
  Fun.protect ~finally:bundle.cleanup (fun () -> f bundle)

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
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  let before = load fixture id in
  set_source fixture ~task_id:"task-B" ~turn:52;
  control fixture (`Assoc ["mode", `String "kill_blocked"]);
  let clock = Eio.Stdenv.clock env in
  (* Fixture deadlock guard only: production jobs have no test timer or TTL. *)
  let interrupted = with_bundle fixture (fun bundle -> Eio.Time.with_timeout_exn clock 15. (fun () ->
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
          true))) in
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
      ; test_case "malformed whole source cannot publish a binding" `Quick test_malformed_source_cannot_publish_binding ]]
