(** Real subprocess/stdio lifecycle with a hermetic Docker control fixture.
    This verifies host isolation logic, not kernel resource enforcement.
    Actual Docker enforcement remains an integration qualification. *)
open Alcotest
module Worker = Masc.Lane_addon_worker
module Types = Masc.Lane_addon_types

let docker_fixture = {|#!/usr/bin/env python3
import base64, hashlib, json, os, pathlib, signal, sys
root = pathlib.Path(__file__).parent
argv = sys.argv[1:]
if not argv or argv[0] != "container":
    raise SystemExit(2)
action, args = argv[1], argv[2:]
if (root / "daemon-unavailable").exists():
    print("fixture daemon unavailable", file=sys.stderr)
    raise SystemExit(7)
def value(flag):
    return args[args.index(flag) + 1]
def path(cid):
    return root / (cid + ".json")
def load(cid):
    return json.loads(path(cid).read_text())
def output(value):
    print(json.dumps(value), flush=True)
if action == "create":
    name = value("--name")
    cid = hashlib.sha256(name.encode()).hexdigest()
    if path(cid).exists():
        print("container name already exists", file=sys.stderr)
        raise SystemExit(1)
    mode = args[-1]
    config = {"Id": cid, "Name": "/" + name,
        "Config": {"Labels": dict([value("--label").split("=", 1)])},
        "HostConfig": {"NanoCpus": round(float(value("--cpus")) * 1000000000),
            "Memory": int(value("--memory")),
            "MemorySwap": int(value("--memory-swap")),
            "PidsLimit": int(value("--pids-limit"))},
        "mode": mode, "argv": args}
    if mode == "unlimited": config["HostConfig"]["PidsLimit"] = 0
    path(cid).write_text(json.dumps(config))
    if mode == "lost_create_response":
        print("create receipt lost", flush=True)
        raise SystemExit(0)
    print(cid, flush=True)
elif action == "inspect":
    cid = args[-1]
    if load(cid)["mode"] == "hang_inspect":
        (root / (cid + ".blocked")).write_text(action)
        while True: signal.pause()
    output([load(args[-1])])
elif action == "ls":
    condition = value("--filter")
    for file in root.glob("*.json"):
        config = json.loads(file.read_text())
        if (condition == "id=" + config["Id"] or
            condition == "name=^" + config["Name"] + "$"):
            output(config["Id"])
elif action == "rm":
    cid = args[-1]
    if (root / (cid + ".refuse-remove")).exists():
        print("fixture removal refused", file=sys.stderr)
        raise SystemExit(7)
    pidfile = root / (cid + ".pid")
    if pidfile.exists():
        try: os.kill(int(pidfile.read_text()), signal.SIGKILL)
        except ProcessLookupError: pass
        pidfile.unlink()
    if path(cid).exists(): path(cid).unlink()
    print(cid, flush=True)
elif action == "start":
    cid = args[-1]
    mode = load(cid)["mode"]
    (root / (cid + ".pid")).write_text(str(os.getpid()))
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request: continue
        method = request["method"]
        if method == "initialize":
            if mode == "hang_initialize":
                (root / (cid + ".blocked")).write_text(method)
                while True: signal.pause()
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                "serverInfo": {"name": "lane-fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "lane_observe", "description": "fixture",
                "inputSchema": {"type": "object"}, "outputSchema": {"type": "object"}}]}
            if mode == "artifacts":
                def object_schema(properties):
                    return {"type":"object", "properties":properties,
                        "required":list(properties), "additionalProperties":False}
                result["tools"].append({"name":"lane_act", "description":"explicit action",
                    "inputSchema": object_schema({
                        "context":object_schema({"instance_id":{"type":"string"},
                            "incarnation":{"type":"string"}}),
                        "request_id":{"type":"string"},
                        "action":object_schema({"kind":{"type":"string","enum":["increment"]}})})})
        elif method == "tools/call":
            arguments = request["params"]["arguments"]
            request_mode = arguments.get("sources", {}).get("mode", "good")
            if request_mode == "hang":
                (root / (cid + ".blocked")).write_text(method)
                while True: signal.pause()
            if request_mode == "oversize":
                result = {"content": [{"type": "text", "text": "x" * 65536}]}
            elif request_mode == "error":
                result = {"isError": True, "content": [{"type": "text", "text": "fixture failure"}],
                    "structuredContent": {"rows": [], "coverage": []}}
            else:
                result = {"content": [{"type": "text", "text": "not JSON; structuredContent is authoritative"}],
                    "structuredContent": {"rows": [], "coverage": []}}
            if mode == "artifacts":
                (root / (cid + ".arguments")).write_text(json.dumps(arguments))
                blob = bytes([0, 255, 10]) + b"frame-state"
                evidence_id = "missing" if request_mode == "missing" else "frame"
                packet = {"rows":[{"id":"sample", "lane_id":"world", "kind":"event",
                    "title":"Artifact sample", "observed_at":1, "subject_id":"fixture",
                    "clock":None, "actor":None, "fields":{},
                    "evidence":[{"artifact_id":evidence_id}], "related_ids":[]}],
                    "coverage":[], "artifacts":[{"id":"frame", "mime_type":"application/octet-stream",
                        "data_base64":base64.b64encode(blob).decode()}]}
                if request["params"]["name"] == "lane_act":
                    result = {"structuredContent":{"status":"confirmed",
                        "result":{"applied":1}, "output":packet}, "content":[]}
                else:
                    result = {"structuredContent":packet, "content":[]}
        else: result = {}
        output({"jsonrpc": "2.0", "id": request["id"], "result": result})
else: raise SystemExit(2)
|}

let write path value =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel value)

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let with_fixture f =
  let dir = Filename.temp_file "lane-worker-" ".fixture" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let docker = Filename.concat dir "docker-fixture" in
  write docker docker_fixture;
  Unix.chmod docker 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () ->
    Eio_main.run (fun env ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
        Eio.Switch.run (fun sw -> f env sw dir docker))))

let package directory mode : Types.package = {
  id = "worker-test"; revision = "fixture-1"; title = "Worker test";
  contributions = [ Types.Observe ]; image = "fixture/image";
  command = [ "observer"; mode ]; directory; skills_directory = None; action_tool = None;
  resources = { cpus = 0.5; memory_bytes = 67_108_864L;
                pids = 16; max_reply_bytes = 4096 };
}

let unwrap = function Ok value -> value | Error error -> fail (Worker.error_to_string error)
let sources mode = `Assoc [ "mode", `String mode ]
let observe worker mode = Worker.observe worker ~binding:(`Assoc []) ~sources:(sources mode)
let start ?(instance_id = Random_id.uuid_v7 ()) env sw dir docker mode =
  Worker.start ~sw ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id
    ~package:(package dir mode) ~docker_command:docker ()

let await_marker clock file =
  let rec wait () =
    if Sys.file_exists file then ()
    else (Eio.Time.sleep clock 0.005; wait ())
  in wait ()

let test_structured_observation_and_exact_removal () = with_fixture (fun env sw dir docker ->
  let first = unwrap (start env sw dir docker "good") in
  let second = unwrap (start env sw dir docker "good") in
  let output = unwrap (observe first "good") in
  check int "structured rows decoded despite non-JSON text" 0 (List.length output.rows);
  let config = Yojson.Safe.from_file (Filename.concat dir (Worker.container_id first ^ ".json")) in
  let args = config |> Yojson.Safe.Util.member "argv" |> Yojson.Safe.Util.to_list
    |> List.map Yojson.Safe.Util.to_string in
  check bool "read-only mount requested" true
    (List.mem ("type=bind,src=" ^ dir ^ ",dst=/addon,readonly") args);
  check bool "no host network" true (List.mem "none" args);
  unwrap (Worker.stop first);
  check bool "exact container removed" false
    (Sys.file_exists (Filename.concat dir (Worker.container_id first ^ ".json")));
  ignore (unwrap (observe second "good"));
  unwrap (Worker.stop first);
  unwrap (Worker.stop second))

let test_hanging_observation_is_optional_and_detachable () = with_fixture (fun env sw dir docker ->
  let worker = unwrap (start env sw dir docker "good") in
  let other = unwrap (start env sw dir docker "good") in
  let blocked = Eio.Fiber.fork_promise ~sw (fun () -> observe worker "hang") in
  await_marker (Eio.Stdenv.clock env)
    (Filename.concat dir (Worker.container_id worker ^ ".blocked"));
  (* This independent owner completes before the deliberately blocked call is
     released. No elapsed-time guess is counted as forward progress. *)
  ignore (unwrap (observe other "good"));
  unwrap (Worker.stop worker);
  check bool "blocked observation ends as failure" true
    (Result.is_error (Eio.Promise.await_exn blocked));
  ignore (unwrap (observe other "good"));
  unwrap (Worker.stop other))

let test_initialize_can_be_detached () = with_fixture (fun env sw dir docker ->
  let created, resolver = Eio.Promise.create () in
  let starting = Eio.Fiber.fork_promise ~sw (fun () ->
    Worker.start ~sw ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id:"starting-test"
      ~package:(package dir "hang_initialize") ~docker_command:docker
      ~on_created:(Eio.Promise.resolve resolver) ()) in
  let worker = Eio.Promise.await created in
  await_marker (Eio.Stdenv.clock env)
    (Filename.concat dir (Worker.container_id worker ^ ".blocked"));
  unwrap (Worker.stop worker);
  check bool "unresponsive initialize stops" true
    (Result.is_error (Eio.Promise.await_exn starting)))

let test_resource_refusal_and_bounded_reply () = with_fixture (fun env sw dir docker ->
  check bool "unapplied resource limit refuses attach" true
    (Result.is_error (start env sw dir docker "unlimited"));
  let worker = unwrap (start env sw dir docker "good") in
  check bool "isError is not a successful observation" true
    (Result.is_error (observe worker "error"));
  check bool "oversized MCP reply rejected" true
    (Result.is_error (observe worker "oversize"));
  unwrap (Worker.stop worker);
  check bool "all owned containers removed" false
    (Array.exists (fun name -> Filename.check_suffix name ".json") (Sys.readdir dir)))

let test_cleanup_failure_can_be_retried () = with_fixture (fun env sw dir docker ->
  let worker = unwrap (start env sw dir docker "good") in
  let marker = Filename.concat dir (Worker.container_id worker ^ ".refuse-remove") in
  write marker "blocked";
  check bool "failed cleanup is reported" true (Result.is_error (Worker.stop worker));
  check bool "scope remains usable" true (Eio.Switch.get_error sw = None);
  Sys.remove marker;
  unwrap (Worker.stop worker))

let test_restart_cleanup_requires_exact_owner () = with_fixture (fun env sw dir docker ->
  let worker = unwrap (start ~instance_id:"worker-test" env sw dir docker "good") in
  let recover instance_id = Worker.recover_stop ~mgr:(Eio.Stdenv.process_mgr env)
      ~instance_id ~container_id:(Some (Worker.container_id worker)) ~max_reply_bytes:4096
      ~docker_command:docker () in
  check bool "another binding cannot remove this container" true
    (Result.is_error (recover "different-owner"));
  ignore (unwrap (observe worker "good"));
  unwrap (recover "worker-test");
  unwrap (recover "worker-test");
  unwrap (Worker.stop worker))

let test_restart_without_create_receipt () = with_fixture (fun env sw dir docker ->
  let instance_id = "lost-create-receipt" in
  let worker = unwrap (start ~instance_id env sw dir docker "good") in
  let other = unwrap (start env sw dir docker "good") in
  let recover () = Worker.recover_stop ~mgr:(Eio.Stdenv.process_mgr env)
      ~instance_id ~container_id:None ~max_reply_bytes:4096 ~docker_command:docker () in
  unwrap (recover ());
  check bool "container is found without a retained create response" false
    (Sys.file_exists (Filename.concat dir (Worker.container_id worker ^ ".json")));
  ignore (unwrap (observe other "good"));
  unwrap (recover ());
  unwrap (Worker.stop worker);
  unwrap (Worker.stop other))

let test_name_collision_preserves_foreign_owner () = with_fixture (fun env sw dir docker ->
  let instance_id = "unpersisted-receipt" in
  let worker = unwrap (start ~instance_id env sw dir docker "good") in
  let path = Filename.concat dir (Worker.container_id worker ^ ".json") in
  let original = Yojson.Safe.from_file path in
  let changed = match original with
    | `Assoc fields -> `Assoc (("Config", `Assoc ["Labels",
        `Assoc ["masc.lane.instance", `String "foreign-owner"]])
        :: List.remove_assoc "Config" fields)
    | _ -> fail "expected fixture container object" in
  write path (Yojson.Safe.to_string changed);
  let recover () = Worker.recover_stop ~mgr:(Eio.Stdenv.process_mgr env)
      ~instance_id ~container_id:None ~max_reply_bytes:4096 ~docker_command:docker () in
  check bool "matching name is not sufficient authority" true (Result.is_error (recover ()));
  check bool "foreign owner survives recovery refusal" true (Sys.file_exists path);
  check bool "failed creation does not clean up a foreign name collision" true
    (Result.is_error (start ~instance_id env sw dir docker "good"));
  check bool "foreign container remains after failed start cleanup" true (Sys.file_exists path);
  ignore (unwrap (observe worker "good"));
  write path (Yojson.Safe.to_string original);
  unwrap (Worker.stop worker))

let test_absence_requires_available_daemon () = with_fixture (fun env _sw dir docker ->
  let recover container_id = Worker.recover_stop ~mgr:(Eio.Stdenv.process_mgr env)
      ~instance_id:"not-created" ~container_id ~max_reply_bytes:4096 ~docker_command:docker () in
  unwrap (recover None);
  let marker = Filename.concat dir "daemon-unavailable" in
  write marker "unavailable";
  check bool "lost receipt plus unavailable daemon is not absence" true
    (Result.is_error (recover None));
  check bool "known ID plus unavailable daemon is not absence" true
    (Result.is_error (recover (Some (String.make 64 'a'))));
  Sys.remove marker;
  unwrap (recover None))

let test_failed_create_receipt_cleans_only_owned_container () = with_fixture (fun env sw dir docker ->
  let other = unwrap (start env sw dir docker "good") in
  let notified = ref false in
  let result = Worker.start ~sw ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id:"receipt-lost"
      ~package:(package dir "lost_create_response") ~docker_command:docker
      ~on_created:(fun _ -> notified := true) () in
  check bool "invalid create receipt is reported" true (Result.is_error result);
  check bool "identity callback has not run" false !notified;
  check int "only unrelated container remains" 1
    (Array.fold_left (fun count name ->
      if Filename.check_suffix name ".json" then count + 1 else count) 0 (Sys.readdir dir));
  ignore (unwrap (observe other "good"));
  unwrap (Worker.stop other))

exception Owner_detached

let test_created_identity_precedes_blocked_inspection () = with_fixture (fun env sw dir docker ->
  let allocated, resolver = Eio.Promise.create () in
  let starting = Eio.Fiber.fork_promise ~sw (fun () ->
    try Eio.Switch.run (fun owner_sw ->
      Worker.start ~sw:owner_sw ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id:"inspect-test"
        ~package:(package dir "hang_inspect") ~docker_command:docker
        ~on_created:(fun worker -> Eio.Promise.resolve resolver (worker, owner_sw)) ())
    with Owner_detached -> Error Worker.Stopped) in
  let worker, owner_sw = Eio.Promise.await allocated in
  await_marker (Eio.Stdenv.clock env)
    (Filename.concat dir (Worker.container_id worker ^ ".blocked"));
  unwrap (Worker.stop worker);
  check bool "created container removed without waiting for inspect" false
    (Sys.file_exists (Filename.concat dir (Worker.container_id worker ^ ".json")));
  (* The binding owner retires its control CLI only after cleanup is proven. *)
  Eio.Switch.fail owner_sw Owner_detached;
  check bool "only binding startup is cancelled" true
    (Result.is_error (Eio.Promise.await_exn starting));
  check bool "primary switch remains active" true (Eio.Switch.get_error sw = None))

let test_world_action_artifact_ingress () = with_fixture (fun env sw dir docker ->
  let store = Masc.Lane_addon_store.create ~root:(Filename.concat dir "evidence-store") in
  let read_only = unwrap (Worker.start ~sw ~mgr:(Eio.Stdenv.process_mgr env)
    ~instance_id:"artifact-observer" ~package:(package dir "artifacts")
    ~artifact_store:store ~docker_command:docker ()) in
  check bool "observation artifacts do not require an action port" false (Option.is_some (Worker.action_schema read_only));
  check int "read-only observer retains artifact evidence" 1
    (List.length (unwrap (observe read_only "good")).rows);
  let invocation = Yojson.Safe.from_file (Filename.concat dir (Worker.container_id read_only ^ ".arguments")) in
  check bool "read-only observation arguments retain their existing shape" true
    (Yojson.Safe.Util.member "context" invocation = `Null);
  unwrap (Worker.stop read_only);
  let no_store = unwrap (start env sw dir docker "artifacts") in
  check bool "artifact bytes without a host store are refused explicitly" true
    (Result.is_error (observe no_store "good"));
  unwrap (Worker.stop no_store);
  let instance_id = "artifact-instance" in
  let package = { (package dir "artifacts") with action_tool = Some "lane_act";
    contributions = [Types.Observe; Types.Act] } in
  let worker = unwrap (Worker.start ~sw ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id
    ~package ~artifact_store:store ~docker_command:docker ()) in
  check bool "actual MCP action schema is discoverable" true (Option.is_some (Worker.action_schema worker));
  let output = unwrap (observe worker "good") in
  let reference = match output.rows with
    | [{Types.evidence=[reference];_}] -> reference | _ -> fail "expected one retained artifact reference" in
  let bytes = "\000\255\nframe-state" in
  let expected = Masc.Lane_addon_store.digest bytes in
  check (option string) "host hashes the decoded bytes" (Some expected) reference.sha256;
  check string "host assigns content-addressed URI" ("lane-evidence:" ^ expected) reference.uri;
  let retained = match Masc.Lane_addon_store.read_blob store reference with
    | Ok bytes -> bytes | Error message -> fail message in
  check string "original binary artifact is retained exactly" bytes retained;
  let invocation = Yojson.Safe.from_file (Filename.concat dir (Worker.container_id worker ^ ".arguments")) in
  check string "opt-in observe receives host incarnation" instance_id
    (invocation |> Yojson.Safe.Util.member "context" |> Yojson.Safe.Util.member "incarnation" |> Yojson.Safe.Util.to_string);
  check bool "dangling artifact evidence rejects observation" true (Result.is_error (observe worker "missing"));
  let args kind = Masc.Lane_addon_action.arguments ~instance_id ~request_id:"request-1"
    ~action:(`Assoc ["kind", `String kind]) in
  check bool "advertised enum is enforced before dispatch" true (Result.is_error (Worker.act worker ~arguments:(args "different")));
  let result = unwrap (Worker.act worker ~arguments:(args "increment")) in
  check bool "package confirmation remains explicit" true
    (result.status = Masc.Lane_addon_action.Package_confirmed);
  check int "action result retains its artifact row" 1 (List.length result.output.rows);
  unwrap (Worker.stop worker);
  check bool "detach preserves retained artifact bytes" true
    (Masc.Lane_addon_store.read_blob store reference = Ok bytes))

let () = run "Lane Add-on worker" [ "lifecycle", [
  test_case "world action and binary artifact ingress" `Quick test_world_action_artifact_ingress;
  test_case "structured observation and exact removal" `Quick test_structured_observation_and_exact_removal;
  test_case "blocked observation preserves other owner" `Quick test_hanging_observation_is_optional_and_detachable;
  test_case "blocked initialization can detach" `Quick test_initialize_can_be_detached;
  test_case "resource refusal and bounded response" `Quick test_resource_refusal_and_bounded_reply;
  test_case "cleanup failure remains retryable" `Quick test_cleanup_failure_can_be_retried;
  test_case "restart cleanup verifies exact owner" `Quick test_restart_cleanup_requires_exact_owner;
  test_case "restart recovers without a create receipt" `Quick test_restart_without_create_receipt;
  test_case "deterministic name cannot authorize foreign cleanup" `Quick test_name_collision_preserves_foreign_owner;
  test_case "absence requires a successful Docker query" `Quick test_absence_requires_available_daemon;
  test_case "lost create response preserves unrelated containers" `Quick test_failed_create_receipt_cleans_only_owned_container;
  test_case "created identity precedes blocked inspect" `Quick test_created_identity_precedes_blocked_inspection;
]]
