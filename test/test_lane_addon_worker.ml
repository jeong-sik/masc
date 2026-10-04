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
if argv[:2] == ["image", "inspect"]:
    if (root / "daemon-unavailable").exists():
        print("fixture daemon unavailable", file=sys.stderr)
        raise SystemExit(7)
    if argv != ["image", "inspect", "--format", "{{.Id}}", "fixture/image"]:
        raise SystemExit(2)
    print("sha256:" + "a" * 64)
    raise SystemExit(0)
if not argv or argv[0] != "container":
    raise SystemExit(2)
action, args = argv[1], argv[2:]
if (root / "daemon-unavailable").exists():
    print("fixture daemon unavailable", file=sys.stderr)
    raise SystemExit(7)
if (root / "hang-control").exists():
    (root / "control.blocked").write_text(action)
    while True: signal.pause()
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
        if mode == "sampling" and method in ("initialize", "tools/list"):
            output({"jsonrpc":"2.0", "id":"outside-observe", "method":"sampling/createMessage",
                "params":{"messages":[{"role":"user","content":{"type":"text","text":"unauthorized startup"}}],
                    "maxTokens":64}})
            outside_reply = json.loads(sys.stdin.readline())
            assert outside_reply["id"] == "outside-observe", outside_reply
            (root / (cid + ".outside-" + method.replace("/", "-"))).write_text(json.dumps(outside_reply))
        if method == "initialize":
            (root / (cid + ".sampling-capability")).write_text(
                json.dumps("sampling" in request["params"]["capabilities"]))
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
            replay = root / (cid + ".replay-output")
            if mode == "sampling" and replay.exists():
                result = {"structuredContent":json.loads(replay.read_text()), "content":[]}
            elif mode == "sampling":
                output({"jsonrpc":"2.0", "id":"sample-1", "method":"sampling/createMessage",
                    "params":{"messages":[{"role":"user","content":{"type":"text","text":"Compare inputs"}}],
                        "includeContext":"none", "maxTokens":64}})
                reply = json.loads(sys.stdin.readline())
                assert reply["id"] == "sample-1", reply
                (root / (cid + ".sampling-reply")).write_text(json.dumps(reply))
                if "error" in reply:
                    result = {"isError":True, "content":[{"type":"text","text":reply["error"]["message"]}]}
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
  command = [ "observer"; mode ]; directory; skills_directory = None; action_tool = None; outputs = [];
  binding_schema=None;presentation=Masc.Lane_addon_presentation.empty;refresh_policy=Types.Every_hint;
  model_access=Types.Model_disabled;
  resources = { cpus = 0.5; memory_bytes = 67_108_864L;
                pids = 16; max_reply_bytes = 4096 };
}

let unwrap = function Ok value -> value | Error error -> fail (Worker.error_to_string error)
let sources mode = `Assoc [ "mode", `String mode ]
let observe worker mode = Worker.observe worker ~binding:(`Assoc []) ~sources:(sources mode)
let control_timeout_sec = 1.
let start ?(instance_id = Random_id.uuid_v7 ()) env sw dir docker mode =
  Worker.start ~sw ~clock:(Eio.Stdenv.clock env) ~control_timeout_sec
    ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id
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
    Worker.start ~sw ~clock:(Eio.Stdenv.clock env) ~control_timeout_sec
      ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id:"starting-test"
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
  let recover instance_id = Worker.recover_stop ~clock:(Eio.Stdenv.clock env)
      ~control_timeout_sec ~mgr:(Eio.Stdenv.process_mgr env)
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
  let recover () = Worker.recover_stop ~clock:(Eio.Stdenv.clock env)
      ~control_timeout_sec ~mgr:(Eio.Stdenv.process_mgr env)
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
  let recover () = Worker.recover_stop ~clock:(Eio.Stdenv.clock env)
      ~control_timeout_sec ~mgr:(Eio.Stdenv.process_mgr env)
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
  let recover container_id = Worker.recover_stop ~clock:(Eio.Stdenv.clock env)
      ~control_timeout_sec ~mgr:(Eio.Stdenv.process_mgr env)
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

let test_recovery_control_command_times_out () = with_fixture (fun env _sw dir docker ->
  let marker = Filename.concat dir "hang-control" in
  write marker "hang";
  let clock = Eio.Stdenv.clock env in
  let started_at = Eio.Time.now clock in
  let result = Worker.recover_stop ~clock ~control_timeout_sec:0.05
      ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id:"not-created"
      ~container_id:None ~max_reply_bytes:4096 ~docker_command:docker () in
  check bool "hung control command is reported" true (Result.is_error result);
  check bool "timeout names the failed control operation" true
    (match result with
     | Error error ->
         String.ends_with ~suffix:"timed out after 0.05 seconds"
           (Worker.error_to_string error)
     | Ok () -> false);
  check bool "control timeout returns promptly" true
    (Eio.Time.now clock -. started_at < 1.);
  Sys.remove marker;
  (* The post-cleanup recover_stop spawns a fresh fixture python under
     runner load. Cold spawns measured 0-1 ms on an idle 5-core box, but the
     two observed CI failures (run 35991632408, run 36211317914) both landed
     in busy windows, so the second call keeps the suite's own
     control_timeout_sec ceiling instead of inheriting the deliberately
     starved 0.05 one. The hung-command assertions above stay unchanged. *)
  unwrap (Worker.recover_stop ~clock ~control_timeout_sec:1.
    ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id:"not-created"
    ~container_id:None ~max_reply_bytes:4096 ~docker_command:docker ()))

let test_failed_create_receipt_cleans_only_owned_container () = with_fixture (fun env sw dir docker ->
  let other = unwrap (start env sw dir docker "good") in
  let notified = ref false in
  let result = Worker.start ~sw ~clock:(Eio.Stdenv.clock env) ~control_timeout_sec
      ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id:"receipt-lost"
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
      Worker.start ~sw:owner_sw ~clock:(Eio.Stdenv.clock env) ~control_timeout_sec
        ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id:"inspect-test"
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
  let read_only = unwrap (Worker.start ~sw ~clock:(Eio.Stdenv.clock env)
    ~control_timeout_sec ~mgr:(Eio.Stdenv.process_mgr env)
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
  let worker = unwrap (Worker.start ~sw ~clock:(Eio.Stdenv.clock env)
    ~control_timeout_sec ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id
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

let test_image_preview_does_not_create_worker () = with_fixture (fun env _sw dir docker ->
  let inspect () = Worker.inspect_image ~clock:(Eio.Stdenv.clock env)
      ~control_timeout_sec ~mgr:(Eio.Stdenv.process_mgr env)
      ~package:(package dir "good") ~docker_command:docker () in
  check string "image identity is the engine reply" ("sha256:" ^ String.make 64 'a') (unwrap (inspect ()));
  check bool "preview creates no container" false
    (Array.exists (fun path -> Filename.check_suffix path ".json") (Sys.readdir dir));
  write (Filename.concat dir "daemon-unavailable") "offline";
  check bool "daemon failure stays an error rather than absence" true (Result.is_error (inspect ())))

(* Tests deliberately collect their small fixture history; production recovery streams. *)
let sampling_requests store ~instance_id =
  let rows = ref [] in
  match Masc.Lane_addon_store.iter_sampling_requests store ~instance_id ~max_bytes:65536
    ~f:(fun row -> rows := row :: !rows; Ok ()) with
  | Error detail -> Error detail | Ok () -> Ok (List.rev !rows)

let test_declared_sampling_requires_exact_host_callback () = with_fixture (fun env sw dir docker ->
  let calls = ref 0 in
  let rejected = ref false in
  let oversized = ref false in
  let raises = ref false and blank_model = ref false and malformed = ref false in
  let fail_index = ref false and fail_journal = ref false in
  let store = Masc.Lane_addon_store.create ~root:(Filename.concat dir "model-evidence") in
  let index_directory = Filename.concat (Masc.Lane_addon_store.root store)
    (Filename.concat "sampling" Digestif.SHA256.(to_hex (digest_string "sampling-worker"))) in
  let saved_index = index_directory ^ ".saved" in
  let outcome_directory = Filename.concat (Masc.Lane_addon_store.root store)
    (Filename.concat "sampling-outcomes" Digestif.SHA256.(to_hex (digest_string "sampling-worker"))) in
  let saved_outcomes = outcome_directory ^ ".saved" in
  let invoke ~route ~request (_ : Mcp_protocol.Sampling.create_message_params) =
    incr calls;
    check string "host owns the selected logical route" "fixture-route" route;
    let bytes = match Masc.Lane_addon_store.read_blob store request with
      | Ok bytes -> bytes | Error detail -> fail detail in
    check string "request is durable before any model invocation" "model_request"
      (Yojson.Safe.from_string bytes |> Yojson.Safe.Util.member "kind" |> Yojson.Safe.Util.to_string);
    let pending = match sampling_requests store ~instance_id:"sampling-worker" with
      | Ok rows -> rows | Error detail -> fail detail in
    check bool "request is discoverable before host invocation" true
      (List.exists (fun row -> Yojson.Safe.Util.member "state" row = `String "pending"
        && Yojson.Safe.Util.member "request" row = Types.evidence_to_json request) pending);
    if !fail_index then (
      Unix.rename index_directory saved_index;
      write index_directory "fixture blocks terminal index replacement");
    if !fail_journal then (
      Unix.rename outcome_directory saved_outcomes;
      write outcome_directory "fixture blocks terminal journal");
    if !raises then failwith "fixture invocation outcome uncertain"
    else if !rejected then Error "fixture model refusal"
    else Ok {Mcp_protocol.Sampling.role=Assistant;content=Text {type_=(if !malformed then "image" else "text");
      text=(if !oversized then String.make 4096 'x' else "host answer")};
      model=(if !blank_model then "" else "host-fixture");stop_reason=Some "endTurn";
      _meta=Some (`Assoc ["masc.lane_sampling",`String "forged-first";
        "provider_note",`String "fixture";
        "masc.lane_provider",`String "private-provider";
        "masc.lane_host",`String "private-host";
        "masc.lane_sampling",`String "forged-last"])} in
  let sampling_handler = match Masc.Lane_addon_sampling.create ~store
      ~package:{(package dir "sampling") with model_access=Types.Host_sampling}
      ~instance_id:"sampling-worker" ~route:"fixture-route" ~invoke () with
    | Ok handler -> handler | Error detail -> fail detail in
  let start_model model_access sampling_handler =
    Worker.start ~sw ~clock:(Eio.Stdenv.clock env) ~control_timeout_sec
      ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id:"sampling-worker"
      ~package:{(package dir "sampling") with model_access} ~docker_command:docker ?sampling_handler () in
  check bool "required model handler cannot be omitted" true
    (Result.is_error (start_model Types.Host_sampling None));
  check bool "ordinary observer cannot be given model access" true
    (Result.is_error (start_model Types.Model_disabled (Some sampling_handler)));
  check bool "broker for another worker is rejected before container creation" true
    (Result.is_error (Worker.start ~sw ~clock:(Eio.Stdenv.clock env) ~control_timeout_sec
      ~mgr:(Eio.Stdenv.process_mgr env) ~instance_id:"different-worker"
      ~package:{(package dir "sampling") with model_access=Types.Host_sampling}
      ~docker_command:docker ~sampling_handler ()));
  check bool "mismatched access starts no container" false
    (Array.exists (fun path -> Filename.check_suffix path ".json") (Sys.readdir dir));
  let worker = unwrap (start_model Types.Host_sampling (Some sampling_handler)) in
  let cid = Worker.container_id worker in
  check bool "configured model access is advertised to the exact worker" true
    (Yojson.Safe.from_file (Filename.concat dir (cid ^ ".sampling-capability"))=`Bool true);
  List.iter (fun phase ->
    let reply = Yojson.Safe.from_file (Filename.concat dir (cid ^ ".outside-" ^ phase)) in
    check bool (phase ^ " sampling is refused before observation") true
      (Yojson.Safe.Util.member "error" reply <> `Null)) ["initialize";"tools-list"];
  check int "initialization and discovery cannot invoke the provider" 0 !calls;
  check bool "initialization and discovery retain no model requests" true
    (sampling_requests store ~instance_id:"sampling-worker" = Ok []);
  ignore (unwrap (observe worker "good"));
  check int "one package model request calls host once" 1 !calls;
  let reply = Yojson.Safe.from_file (Filename.concat dir (cid ^ ".sampling-reply")) in
  check string "host-selected model response crosses worker transport" "host-fixture"
    (reply |> Yojson.Safe.Util.member "result" |> Yojson.Safe.Util.member "model" |> Yojson.Safe.Util.to_string);
  let metadata = reply |> Yojson.Safe.Util.member "result" |> Yojson.Safe.Util.member "_meta" in
  check bool "callback metadata never crosses package boundary" true
    (metadata |> Yojson.Safe.Util.to_assoc |> List.map fst = ["masc.lane_sampling"]);
  let read_reference reference =
    let reference = match Types.evidence_of_json reference with Ok ref -> ref | Error error -> fail error in
    match Masc.Lane_addon_store.read_blob store reference with
    | Ok bytes -> Yojson.Safe.from_string bytes | Error error -> fail error in
  let fields = Yojson.Safe.Util.to_assoc metadata in
  check int "worker reply exposes exactly one host-owned sampling reference" 1
    (List.length (List.filter (fun (key, _) -> key="masc.lane_sampling") fields));
  let references = Yojson.Safe.Util.member "masc.lane_sampling" metadata in
  let retained_metadata = references |> Yojson.Safe.Util.member "outcome" |> read_reference
    |> Yojson.Safe.Util.member "response" |> Yojson.Safe.Util.member "_meta" in
  check string "host identity remains in private retained evidence" "private-host"
    Yojson.Safe.Util.(retained_metadata |> member "masc.lane_host" |> to_string);
  check string "provider identity remains in private retained evidence" "private-provider"
    Yojson.Safe.Util.(retained_metadata |> member "masc.lane_provider" |> to_string);
  let selected evidence : Types.output = {rows=[{
    id="sample";lane_id="fusion/computation";kind=Types.Value;title="sample";
    observed_at=1.;subject_id="sample";clock=None;actor=None;fields=[];
    evidence;related_ids=[]}];coverage=[]} in
  let reference key = match Types.evidence_of_json (Yojson.Safe.Util.member key references) with
    | Ok value -> value | Error detail -> fail detail in
  let project instance_id output = match Masc.Lane_addon_sampling.retained_receipts
      ~store ~instance_id ~max_bytes:1048576 output with Ok values -> values | Error detail -> fail detail in
  let output = selected [reference "request";reference "outcome"] in
  check int "exact host model request projects one attested receipt" 1
    (List.length (project "sampling-worker" output));
  check bool "projected receipt does not expose callback metadata" true
    (Yojson.Safe.Util.(List.hd (project "sampling-worker" output)
      |> member "terminal" |> member "response" |> member "_meta") = `Null);
  check int "another worker cannot claim the host model receipt" 0
    (List.length (project "other-worker" output));
  let replay_path = Filename.concat dir (cid ^ ".replay-output") in
  write replay_path (Yojson.Safe.to_string (Types.output_to_json output));
  let calls_before_replay = !calls in
  check bool "worker can reuse a model answer for identical host inputs" true
    (Result.is_ok (observe worker "good"));
  check bool "worker cannot replay old model evidence for changed sources" true
    (match observe worker "new-source" with Error (Worker.Invalid_observation _) -> true | _ -> false);
  check bool "worker cannot replay old model evidence for a changed binding" true
    (match Worker.observe worker ~binding:(`Assoc ["task",`String "new-task"])
       ~sources:(sources "good") with Error (Worker.Invalid_observation _) -> true | _ -> false);
  check bool "a rejected replay clears its scope for the next observation" true
    (Result.is_ok (observe worker "good"));
  check int "replay validation does not call the model" calls_before_replay !calls;
  let blob content = match Masc.Lane_addon_store.write_blob store content with
    | Ok value -> value | Error detail -> fail detail in
  let large_a = blob (String.make 2200 'a') and large_b = blob (String.make 2200 'b') in
  let amplified = selected [large_a;large_b] in
  write replay_path (Yojson.Safe.to_string (Types.output_to_json amplified));
  check bool "observation rejects aggregate arbitrary evidence amplification" true
    (match observe worker "good" with Error (Worker.Invalid_observation _) -> true | _ -> false);
  check bool "receipt projection bounds arbitrary non-model evidence reads in aggregate" true
    (Result.is_error (Masc.Lane_addon_sampling.retained_receipts ~store
      ~instance_id:"sampling-worker" ~max_bytes:4096 amplified));
  check bool "duplicate evidence references consume the read envelope once" true
    (Result.is_ok (Masc.Lane_addon_sampling.retained_receipts ~store
      ~instance_id:"sampling-worker" ~max_bytes:4096 (selected [large_a;large_a])));
  let corrupt_budget = Masc.Lane_addon_store.read_budget ~max_bytes:4096 in
  let hash = match large_a.sha256 with Some hash -> hash | None -> fail "missing blob digest" in
  write (Filename.concat (Masc.Lane_addon_store.root store) ("evidence/" ^ hash ^ ".json"))
    (String.make 2200 'c');
  check bool "corrupt evidence is still charged before digest validation" true
    (match Masc.Lane_addon_store.read_blob_bounded ~budget:corrupt_budget store large_a with
     | Error (Masc.Lane_addon_store.Read_failed _) -> true | _ -> false);
  check bool "corrupt reads cannot replenish the aggregate allowance" true
    (match Masc.Lane_addon_store.read_blob_bounded ~budget:corrupt_budget store large_b with
     | Error Masc.Lane_addon_store.Read_limit_exceeded -> true | _ -> false);
  Sys.remove replay_path;
  let fabricated_request = read_reference (Yojson.Safe.Util.member "request" references) in
  let fabricated_request = match fabricated_request with
    | `Assoc fields -> `Assoc (("params",`Assoc []) :: List.remove_assoc "params" fields)
    | _ -> fail "request must be structured" in
  let artifact = match Masc.Lane_addon_store.write_blob store (Yojson.Safe.to_string fabricated_request) with
    | Ok value -> value | Error detail -> fail detail in
  check int "retained artifact with copied request identity is not host sampling" 0
    (List.length (project "sampling-worker" (selected [artifact;reference "outcome"])));
  let retained = read_reference (Yojson.Safe.Util.member "outcome" references) in
  check string "actual model response is retained separately" "host-fixture"
    (retained |> Yojson.Safe.Util.member "response" |> Yojson.Safe.Util.member "model" |> Yojson.Safe.Util.to_string);
  let raw_metadata = retained |> Yojson.Safe.Util.member "response"
    |> Yojson.Safe.Util.member "_meta" |> Yojson.Safe.Util.to_assoc in
  check (list string) "retained actual provider response preserves both untrusted entries"
    ["forged-first";"forged-last"]
    (List.filter_map (fun (key,value) ->
      if key="masc.lane_sampling" then Some (Yojson.Safe.Util.to_string value) else None) raw_metadata);
  check bool "outcome links the original exact request" true
    (Yojson.Safe.Util.member "request" retained=Yojson.Safe.Util.member "request" references);
  let recovered = Masc.Lane_addon_store.create ~root:(Masc.Lane_addon_store.root store) in
  let indexed = match sampling_requests recovered ~instance_id:"sampling-worker" with
    | Ok rows -> rows | Error detail -> fail detail in
  check bool "reopened store discovers terminal request evidence" true
    (List.exists (fun row -> Yojson.Safe.Util.member "state" row = `String "finished"
      && Yojson.Safe.Util.member "outcome" row = Yojson.Safe.Util.member "outcome" references) indexed);
  fail_index := true;
  Fun.protect ~finally:(fun () ->
    fail_index := false;
    if Sys.file_exists saved_index then (
      Unix.unlink index_directory;
      Unix.rename saved_index index_directory)) (fun () ->
    check bool "durable terminal answer survives unavailable primary index" true
      (Result.is_ok (observe worker "good")));
  let successful_reply = Yojson.Safe.from_file (Filename.concat dir (cid ^ ".sampling-reply"))
    |> Yojson.Safe.Util.member "result" in
  check string "primary index loss does not relabel the actual answer" "host-fixture"
    (Yojson.Safe.Util.member "model" successful_reply |> Yojson.Safe.Util.to_string);
  let recovered_references = successful_reply |> Yojson.Safe.Util.member "_meta"
    |> Yojson.Safe.Util.member "masc.lane_sampling" in
  let recovered_outcome = Yojson.Safe.Util.member "outcome" recovered_references |> read_reference in
  check string "index failure keeps the retained actual answer" "host answer"
    (recovered_outcome |> Yojson.Safe.Util.member "response"
      |> Yojson.Safe.Util.member "content" |> Yojson.Safe.Util.member "text"
      |> Yojson.Safe.Util.to_string);
  let interrupted = match sampling_requests recovered ~instance_id:"sampling-worker" with
    | Ok rows -> rows | Error detail -> fail detail in
  check bool "recovery resolves the authoritative terminal journal" true
    (List.exists (fun row -> Yojson.Safe.Util.member "state" row = `String "finished"
      && Yojson.Safe.Util.member "request" row = Yojson.Safe.Util.member "request" recovered_references) interrupted);
  let request_id = recovered_references |> Yojson.Safe.Util.member "request" |> read_reference
    |> Yojson.Safe.Util.member "request_id" |> Yojson.Safe.Util.to_string in
  let pending_intent = Yojson.Safe.from_file
    (Filename.concat index_directory (Masc.Lane_addon_store.digest request_id ^ ".json")) in
  check string "primary index also records the terminal answer" "finished"
    Yojson.Safe.Util.(pending_intent |> member "state" |> to_string);
  let projected_refs = ["request";"outcome"] |> List.map (fun key ->
    match Types.evidence_of_json (Yojson.Safe.Util.member key recovered_references) with
    | Ok value -> value | Error detail -> fail detail) in
  check string "receipt agrees with the returned durable answer" "answered"
    Yojson.Safe.Util.(project "sampling-worker" (selected projected_refs) |> List.hd
      |> member "terminal" |> member "status" |> to_string);
  fail_journal := true;
  Fun.protect ~finally:(fun () ->
    fail_journal := false;
    Unix.unlink outcome_directory;
    Unix.rename saved_outcomes outcome_directory) (fun () ->
    check bool "primary terminal index survives failed outcome journal" true
      (Result.is_ok (observe worker "good")));
  let journal_failure = Yojson.Safe.from_file (Filename.concat dir (cid ^ ".sampling-reply"))
    |> Yojson.Safe.Util.member "result" |> Yojson.Safe.Util.member "_meta"
    |> Yojson.Safe.Util.member "masc.lane_sampling" in
  let request = match Types.evidence_of_json (Yojson.Safe.Util.member "request" journal_failure) with
    | Ok value -> value | Error detail -> fail detail in
  let receipt = project "sampling-worker" (selected [request]) |> List.hd in
  check string "journal failure projects the primary terminal answer" "answered"
    Yojson.Safe.Util.(receipt |> member "terminal" |> member "status" |> to_string);
  rejected := true;
  check bool "model refusal is not a synthetic successful observation" true
    (Result.is_error (observe worker "good"));
  let failure = Yojson.Safe.from_file (Filename.concat dir (cid ^ ".sampling-reply"))
    |> Yojson.Safe.Util.member "error" |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string
    |> Yojson.Safe.from_string in
  let failure_record = failure |> Yojson.Safe.Util.member "evidence"
    |> Yojson.Safe.Util.member "outcome" |> read_reference in
  check string "host errors retain neutral evidence without assuming policy rejection" "host_error"
    (failure_record |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  check string "package sees the host-error state without reading host files" "host_error"
    (failure |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  rejected := false; oversized := true;
  check bool "response retention failure does not report success" true
    (Result.is_error (observe worker "good"));
  let uncertain = Yojson.Safe.from_file (Filename.concat dir (cid ^ ".sampling-reply"))
    |> Yojson.Safe.Util.member "error" |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string
    |> Yojson.Safe.from_string in
  check string "oversized response is rejected before transmission" "invalid_response"
    (uncertain |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  let oversized_record = uncertain |> Yojson.Safe.Util.member "evidence"
    |> Yojson.Safe.Util.member "outcome" |> read_reference in
  check string "bounded terminal preserves callback failure status" "invalid_response"
    Yojson.Safe.Util.(oversized_record |> member "status" |> to_string);
  check string "bounded terminal preserves installation identity" "sampling-worker"
    Yojson.Safe.Util.(oversized_record |> member "instance_id" |> to_string);
  let oversized_request = match Types.evidence_of_json
      Yojson.Safe.Util.(uncertain |> member "evidence" |> member "request") with
    | Ok reference -> reference | Error detail -> fail detail in
  let oversized_receipt = project "sampling-worker" (selected [oversized_request]) |> List.hd in
  check string "oversized failure projects a usable host receipt" "invalid_response"
    Yojson.Safe.Util.(oversized_receipt |> member "terminal" |> member "status" |> to_string);
  let terminal_after_failure = match sampling_requests recovered ~instance_id:"sampling-worker" with
    | Ok rows -> rows | Error detail -> fail detail in
  check bool "retention failure still has terminal recovery evidence" true
    (List.exists (fun row -> Yojson.Safe.Util.member "state" row = `String "finished"
      && Yojson.Safe.Util.member "outcome" row = Yojson.Safe.Util.(uncertain |> member "evidence" |> member "outcome")) terminal_after_failure);
  oversized := false; raises := true;
  check bool "invocation exception reaches the package as an error" true (Result.is_error (observe worker "good"));
  let inline_error () = Yojson.Safe.from_file (Filename.concat dir (cid ^ ".sampling-reply"))
    |> Yojson.Safe.Util.member "error" |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string
    |> Yojson.Safe.from_string in
  check string "package can distinguish uncertain invocation from host error" "outcome_unknown"
    (inline_error () |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  raises := false; blank_model := true;
  check bool "missing model identity is not accepted as an answer" true (Result.is_error (observe worker "good"));
  let invalid = inline_error () in
  check string "invalid response is explicit to the package" "invalid_response"
    (invalid |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  let invalid_record = invalid |> Yojson.Safe.Util.member "evidence"
    |> Yojson.Safe.Util.member "outcome" |> read_reference in
  let retained_answer = match Mcp_protocol.Sampling.create_message_result_of_yojson
      (Yojson.Safe.Util.member "response" invalid_record) with
    | Ok answer -> answer | Error detail -> fail detail in
  check (list string) "inline failure carries only status and evidence"
    ["evidence"; "status"]
    (Yojson.Safe.Util.to_assoc invalid |> List.map fst |> List.sort String.compare);
  let invalid_request = match Types.evidence_of_json
      Yojson.Safe.Util.(invalid |> member "evidence" |> member "request") with
    | Ok reference -> reference | Error detail -> fail detail in
  let invalid_receipt = project "sampling-worker" (selected [invalid_request]) |> List.hd in
  check bool "invalid-response receipt carries the package-safe retained response" true
    (Yojson.Safe.Util.(invalid_receipt |> member "terminal" |> member "response") =
      Mcp_protocol.Sampling.create_message_result_to_yojson
        (Masc.Lane_addon_sampling.package_response retained_answer));
  check string "retained invalid response preserves the missing model identity" ""
    retained_answer.model;
  check bool "invalid-response raw host evidence keeps callback metadata" true
    (Yojson.Safe.Util.member "_meta" (Yojson.Safe.Util.member "response" invalid_record) <> `Null);
  check string "malformed actual answer remains in retained evidence" "host answer"
    (invalid_record |> Yojson.Safe.Util.member "response" |> Yojson.Safe.Util.member "content"
      |> Yojson.Safe.Util.member "text" |> Yojson.Safe.Util.to_string);
  blank_model := false; malformed := true;
  check bool "mismatched content discriminator is rejected" true (Result.is_error (observe worker "good"));
  check string "wire-invalid response is classified before transmission" "invalid_response"
    (inline_error () |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  malformed := false;
  let original_request = references |> Yojson.Safe.Util.member "request" |> read_reference in
  let params = match Mcp_protocol.Sampling.create_message_params_of_yojson
      (Yojson.Safe.Util.member "params" original_request) with
    | Ok params -> params | Error detail -> fail detail in
  let direct_handler = match Masc.Lane_addon_sampling.for_worker sampling_handler
      ~package:{(package dir "sampling") with model_access=Types.Host_sampling}
      ~instance_id:"sampling-worker" with Ok handler -> handler | Error detail -> fail detail in
  let before_outside = !calls in
  let before_records = sampling_requests store ~instance_id:"sampling-worker" in
  check bool "out-of-observation callback is refused" true (Result.is_error (direct_handler params));
  check int "out-of-observation callback never invokes provider" before_outside !calls;
  check bool "out-of-observation callback creates no durable request" true
    (before_records = sampling_requests store ~instance_id:"sampling-worker");
  let tiny_package = {(package dir "sampling") with model_access=Types.Host_sampling;
    resources={(package dir "sampling").resources with max_reply_bytes=1}} in
  let bounded = match Masc.Lane_addon_sampling.create ~store ~package:tiny_package
      ~instance_id:"bounded-model" ~route:"fixture-route" ~invoke () with
    | Ok handler -> handler | Error detail -> fail detail in
  let before = !calls in
  check bool "unretained oversized request is refused before invocation" true
    (Result.is_error (Masc.Lane_addon_sampling.with_observation bounded
      ~binding:(`Assoc []) ~sources:(`List []) ~on_error:Fun.id (fun () ->
      Result.map (fun _ -> {Types.rows=[];coverage=[]}) ((match Masc.Lane_addon_sampling.for_worker bounded
        ~package:tiny_package ~instance_id:"bounded-model" with
        | Ok handler -> handler | Error detail -> fail detail) params))));
  check int "retention is required before the model is called" before !calls;
  let argv = Yojson.Safe.from_file (Filename.concat dir (cid ^ ".json"))
    |> Yojson.Safe.Util.member "argv" |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string in
  check bool "sampling preserves requested network isolation" true (List.mem "none" argv);
  check bool "model callback adds no container environment injection" false (List.mem "--env" argv);
  unwrap (Worker.stop worker))

exception Cancel_after_model
let test_known_sampling_outcome_survives_cancellation () = with_fixture (fun _env _sw dir _docker ->
  let module Sampling = Masc.Lane_addon_sampling in
  let module Store = Masc.Lane_addon_store in
  let module S = Mcp_protocol.Sampling in
  let store = Store.create ~root:(Filename.concat dir "cancelled-model-evidence") in
  let package = {(package dir "sampling") with model_access=Types.Host_sampling} in
  let params = match S.create_message_params_of_yojson (`Assoc [
    "messages",`List [`Assoc ["role",`String "user";"content",`Assoc [
      "type",`String "text";"text",`String "retained input"]]];
    "maxTokens",`Int 8]) with Ok value -> value | Error detail -> fail detail in
  List.iter (fun (instance_id,answer,fail_index) ->
    let index_directory = Filename.concat (Store.root store)
      (Filename.concat "sampling" (Store.digest instance_id)) in
    let saved_index = index_directory ^ ".saved" in
    let cancelled = ref false in
    let observed_broker = ref None in
    (try Eio.Cancel.sub (fun cc ->
      let invoke ~route:_ ~request:_ _ =
        if fail_index then (
          Unix.rename index_directory saved_index;
          write index_directory "terminal index unavailable");
        Eio.Cancel.cancel cc Cancel_after_model;
        answer in
      let broker = match Sampling.create ~store ~package ~instance_id ~route:"fixture-route" ~invoke () with
        | Ok value -> value | Error detail -> fail detail in
      observed_broker := Some broker;
      let handler = match Sampling.for_worker broker ~package ~instance_id with
        | Ok value -> value | Error detail -> fail detail in
      ignore (Sampling.with_observation broker ~binding:(`Assoc []) ~sources:(`List [])
        ~on_error:Fun.id (fun () ->
          match handler params with
          | Ok _ -> Ok {Types.rows=[];coverage=[]} | Error detail -> Error detail));
      fail "known sampling completion swallowed cancellation")
     with Eio.Cancel.Cancelled Cancel_after_model -> cancelled := true);
    check bool "original cancellation is re-raised after retention" true !cancelled;
    let broker = match !observed_broker with Some broker -> broker | None -> fail "missing broker" in
    check bool "cancellation clears the host observation scope" true
      (Result.is_ok (Sampling.with_observation broker ~binding:(`Assoc []) ~sources:(`List [])
        ~on_error:Fun.id (fun () -> Ok {Types.rows=[];coverage=[]})));
    if fail_index then (
      (* Discover the immutable fallback even while the primary index is broken. *)
      let found = ref false in
      let recovered = Store.create ~root:(Store.root store) in
      let result = Store.iter_sampling_requests recovered ~instance_id ~max_bytes:65536
        ~f:(fun row -> found := Yojson.Safe.Util.member "state" row = `String "finished"; Ok ()) in
      check bool "journal recovery visits the known outcome despite broken primary" true !found;
      check bool "unreadable primary prevents complete recovery claim" true (Result.is_error result);
      Unix.unlink index_directory;
      Unix.rename saved_index index_directory);
    let request_record = match sampling_requests store ~instance_id with
      | Ok [value] -> value | Ok _ -> fail "missing exact sampling request" | Error detail -> fail detail in
    check string "cancelled call still has a finished recovery index" "finished"
      Yojson.Safe.Util.(request_record |> member "state" |> to_string);
    let bounded_index = Store.load_sampling_request_bounded
      ~budget:(Store.read_budget ~max_bytes:65536) store ~instance_id
      ~request_id:Yojson.Safe.Util.(request_record |> member "request_id" |> to_string) in
    check bool "bounded projection resolves the same durable terminal as recovery" true
      (bounded_index = Ok (Some request_record));
    let reference = match Types.evidence_of_json (Yojson.Safe.Util.member "outcome" request_record) with
      | Ok value -> value | Error detail -> fail detail in
    let outcome = match Store.read_blob store reference with
      | Ok bytes -> Yojson.Safe.from_string bytes | Error detail -> fail detail in
    check bool "retained outcome links the exact original request" true
      (Yojson.Safe.Util.member "request" outcome = Yojson.Safe.Util.member "request" request_record);
    match answer with
    | Ok expected -> check bool "exact returned answer remains readable" true
        (Yojson.Safe.Util.member "response" outcome = S.create_message_result_to_yojson expected)
    | Error detail -> check string "known host refusal remains readable" detail
        Yojson.Safe.Util.(outcome |> member "error" |> to_string))
    ["answered",Ok {S.role=Assistant;content=Text {type_="text";text="exact answer"};
       model="actual-model";stop_reason=Some "endTurn";_meta=None},false;
     "host-error",Error "actual host refusal",false;
     "cancelled-index-failure",Ok {S.role=Assistant;content=Text {type_="text";text="exact answer"};
       model="actual-model";stop_reason=Some "endTurn";_meta=None},true])

let run_sampling_observation broker handler params =
  let reply = ref None in
  let result = Masc.Lane_addon_sampling.with_observation broker
    ~binding:(`Assoc []) ~sources:(`List []) ~on_error:Fun.id (fun () ->
      reply := Some (handler params);
      Ok {Types.rows=[];coverage=[]}) in
  match result, !reply with
  | Error detail, _ -> Error detail
  | Ok _, Some reply -> reply
  | Ok _, None -> fail "sampling observation did not execute callback"

let test_sampling_response_bound_and_directory_durability () = with_fixture (fun _env _sw dir _docker ->
  let module Store = Masc.Lane_addon_store in
  let module Sampling = Masc.Lane_addon_sampling in
  let module S = Mcp_protocol.Sampling in
  let first_root = Filename.concat dir "root-sync-retry" in
  let first_store = Store.create ~root:first_root in
  let syncs = ref [] in
  let write_root fail_sync = Store.For_testing.write first_store "evidence/root.json" "{}"
    ~sync_parent:(fun path -> syncs := path :: !syncs;
      if fail_sync && path = dir then raise (Unix.Unix_error (Unix.EIO,"fsync",path))) in
  check bool "new root parent sync failure refuses receipt" true (Result.is_error (write_root true));
  check bool "root sync failure does not publish child evidence" false
    (Sys.file_exists (Filename.concat first_root "evidence/root.json"));
  syncs := [];
  (match write_root false with Ok () -> () | Error detail -> fail detail);
  check bool "retry preserves root parent sync obligation" true (List.mem dir !syncs);
  let store = Store.create ~root:(Filename.concat dir "first-use") in
  List.iter (fun relative ->
    let fail_parent = Store.root store in
    let syncs = ref [] in
    let write fail_sync = Store.For_testing.write store relative "{}" ~sync_parent:(fun path ->
      syncs := path :: !syncs;
      if fail_sync && path = fail_parent then raise (Unix.Unix_error (Unix.EIO,"fsync",path))) in
    check bool "first-use ancestor failure refuses persistence" true (Result.is_error (write true));
    check bool "no receipt published before ancestor sync" false
      (Sys.file_exists (Filename.concat (Store.root store) relative));
    syncs := [];
    (match write false with Ok () -> () | Error detail -> fail detail);
    check bool "retry syncs the existing newly-created ancestor" true (List.mem fail_parent !syncs))
    ["evidence/fixture.json";"sampling/worker/fixture.json";"sampling-outcomes/worker/fixture.json"];
  let store = Store.create ~root:(Filename.concat dir "response-limit") in
  let answer : S.create_message_result = {role=Assistant;content=Text {type_="text";text="answer"};
    model="model";stop_reason=Some "endTurn";_meta=None} in
  let p = {(package dir "sampling") with model_access=Types.Host_sampling;
    resources={(package dir "sampling").resources with max_reply_bytes=65536}} in
  let params = match S.create_message_params_of_yojson (`Assoc ["messages",`List [];"maxTokens",`Int 1]) with
    | Ok value -> value | Error detail -> fail detail in
  let run p =
    let broker = match Sampling.create ~store ~package:p ~instance_id:"w" ~route:"r"
      ~invoke:(fun ~route:_ ~request:_ _ -> Ok answer) () with Ok value -> value | Error detail -> fail detail in
    let handler = match Sampling.for_worker broker ~package:p ~instance_id:"w" with
      | Ok value -> value | Error detail -> fail detail in
    run_sampling_observation broker handler params in
  let first = match run p with Ok value -> value | Error detail -> fail detail in
  let size = String.length (Yojson.Safe.to_string (S.create_message_result_to_yojson first)) in
  let bounded = {p with resources={p.resources with max_reply_bytes=size-1}} in
  let result = run bounded in
  check bool "host reply including receipt metadata obeys package envelope" true (Result.is_error result);
  (match result with
   | Error detail ->
       check bool "overflow refusal also fits without echoing receipt metadata" true
         (String.length (Yojson.Safe.to_string (`String detail)) <= bounded.resources.max_reply_bytes);
       let terminal = Yojson.Safe.from_string detail in
       check string "metadata overflow returns an indexed invalid response" "invalid_response"
         Yojson.Safe.Util.(terminal |> member "status" |> to_string);
       let reference = match Types.evidence_of_json
           Yojson.Safe.Util.(terminal |> member "evidence" |> member "outcome") with
         | Ok value -> value | Error message -> fail message in
       let bytes = match Store.read_blob_bounded
           ~budget:(Store.read_budget ~max_bytes:bounded.resources.max_reply_bytes) store reference with
         | Ok bytes -> bytes | Error _ -> fail "metadata overflow outcome unavailable" in
       check string "metadata overflow callback matches retained status" "invalid_response"
         Yojson.Safe.Util.(Yojson.Safe.from_string bytes |> member "status" |> to_string);
       check bool "metadata overflow preserves the original answer when it fits" true
         (Yojson.Safe.Util.member "response" (Yojson.Safe.from_string bytes) =
          S.create_message_result_to_yojson answer)
   | Ok _ -> fail "oversized answer accepted");
  let indexes = match sampling_requests store ~instance_id:"w" with Ok xs -> xs | Error detail -> fail detail in
  check int "both actual outcomes remain durably indexed" 2 (List.length indexes);
  check bool "response-bound refusal preserves known finished result" true
    (List.for_all (fun row -> Yojson.Safe.Util.member "state" row = `String "finished") indexes))

let test_sampling_wire_frame_envelope () =
  List.iter (fun id ->
    List.iter (fun boundary -> with_fixture (fun env sw dir _docker ->
      let module S = Mcp_protocol.Sampling in
      let module J = Mcp_protocol.Jsonrpc in
      let module Store = Masc.Lane_addon_store in
      let module Sampling = Masc.Lane_addon_sampling in
      let answer : S.create_message_result = {role=Assistant;
        content=Text {type_="text";text=String.make 700 'x'};
        model="wire-fixture";stop_reason=None;_meta=None} in
      let placeholder = Types.evidence_to_json (Store.blob_reference "") in
      let refs = `Assoc ["request",placeholder;"outcome",placeholder] in
      let response = {answer with _meta=Some (`Assoc ["masc.lane_sampling",refs])} in
      let success_size = String.length (Yojson.Safe.to_string
        (J.message_to_yojson (J.make_response ~id ~result:(S.create_message_result_to_yojson response)))) + 1 in
      let refusal_size = String.length (Yojson.Safe.to_string (J.message_to_yojson
        (J.make_error ~id ~code:Mcp_protocol.Error_codes.internal_error
          ~message:(Yojson.Safe.to_string (`Assoc ["status",`String "invalid_response";"evidence",refs])) ()))) + 1 in
      let max_bytes = match boundary with
        | `Exact -> success_size | `Overflow -> success_size - 1
        | `Failure_exact -> refusal_size | `Too_small -> refusal_size - 1 in
      let p = {(package dir "sampling") with model_access=Types.Host_sampling;
        resources={(package dir "sampling").resources with max_reply_bytes=max_bytes}} in
      let store = Store.create ~root:(Filename.concat dir "wire-evidence") in
      let calls = ref 0 in
      let broker = match Sampling.create ~store ~package:p ~instance_id:"wire" ~route:"r"
        ~invoke:(fun ~route:_ ~request:_ _ -> incr calls; Ok answer) () with
        | Ok broker -> broker | Error detail -> fail detail in
      let handler = match Sampling.for_worker broker ~package:p ~instance_id:"wire" with
        | Ok handler -> handler | Error detail -> fail detail in
      let script = Filename.concat dir "sampling-wire.py" in
      write script {|import json,sys
id=json.loads(sys.argv[1])
budget=int(sys.argv[2])
def send(value):
    print(json.dumps(value,ensure_ascii=False),flush=True)
for line in sys.stdin:
    request=json.loads(line)
    if request.get("method")=="initialize":
        assert "sampling" in request["params"]["capabilities"]
        send({"jsonrpc":"2.0","id":request["id"],"result":{"protocolVersion":request["params"]["protocolVersion"],"capabilities":{"tools":{}},"serverInfo":{"name":"wire","version":"1"}}})
    elif request.get("method")=="tools/call":
        send({"jsonrpc":"2.0","id":id,"method":"sampling/createMessage","params":{"messages":[],"includeContext":"none","maxTokens":1}})
        raw=sys.stdin.buffer.readline(budget+1)
        assert len(raw)<=budget,(len(raw),budget)
        reply=json.loads(raw)
        assert reply["id"]==id
        summary={"frame_bytes":len(raw),"error":"error" in reply}
        if "error" in reply:
            try:
                failure=json.loads(reply["error"]["message"])
                summary["status"]=failure["status"]
                summary["outcome"]=failure["evidence"]["outcome"]
            except (ValueError,KeyError):
                summary["status"]="refused"
        send({"jsonrpc":"2.0","id":request["id"],"result":{"content":[],"structuredContent":summary,"isError":False}})
|};
      let client = match Agent_core.Mcp.connect ~sw ~mgr:env#process_mgr ~command:"python3"
        ~args:[script;Yojson.Safe.to_string (J.id_to_yojson id);string_of_int max_bytes]
        ~env:[||] ~max_response_bytes:max_bytes ~sampling_handler:handler () with
        | Ok client -> client | Error error -> fail (Agent_core.Error.to_string error) in
      Fun.protect ~finally:(fun () -> Agent_core.Mcp.close client) (fun () ->
        (match Agent_core.Mcp.initialize client with
         | Ok () -> () | Error error -> fail (Agent_core.Error.to_string error));
        let summary = ref `Null in
        let observed = Sampling.with_observation broker ~binding:(`Assoc []) ~sources:(`List [])
          ~on_error:Fun.id (fun () ->
            match Agent_core.Mcp.call_tool_full client ~name:"sample" ~arguments:(`Assoc []) with
            | Error error -> Error (Agent_core.Error.to_string error)
            | Ok result -> summary := Option.get result.structured_content;
                Ok {Types.rows=[];coverage=[]}) in
        check bool "actual sampling wire exchange completes" true (Result.is_ok observed);
        let open Yojson.Safe.Util in
        check bool "complete frame including newline stays in envelope" true
          (member "frame_bytes" !summary |> to_int <= max_bytes);
        match boundary with
        | `Exact ->
            check int "exact boundary is actually emitted" max_bytes (member "frame_bytes" !summary |> to_int);
            check bool "exact boundary retains successful answer" false (member "error" !summary |> to_bool);
            check int "successful wire answer invokes once" 1 !calls
        | `Overflow | `Failure_exact ->
            if boundary = `Failure_exact then
              check int "failure frame exact boundary is emitted" max_bytes
                (member "frame_bytes" !summary |> to_int);
            check int "overflow invokes only once" 1 !calls;
            check string "frame overflow returns indexed failure" "invalid_response"
              (member "status" !summary |> to_string);
            let reference = match Types.evidence_of_json (member "outcome" !summary) with
              | Ok value -> value | Error detail -> fail detail in
            let retained = match Store.read_blob store reference with
              | Ok bytes -> Yojson.Safe.from_string bytes | Error detail -> fail detail in
            check string "wire refusal agrees with durable terminal" "invalid_response"
              (member "status" retained |> to_string)
        | `Too_small -> check int "unrepresentable failure frame never invokes host" 0 !calls)))
      [`Exact;`Overflow;`Failure_exact;`Too_small])
    [Mcp_protocol.Jsonrpc.String (String.make 64 '"' ^ "한글");Mcp_protocol.Jsonrpc.Int max_int]

let test_sampling_refuses_nonfinite_evidence () = with_fixture (fun _env _sw dir _docker ->
  let module S = Mcp_protocol.Sampling in
  let module Sampling = Masc.Lane_addon_sampling in
  let store = Masc.Lane_addon_store.create ~root:(Filename.concat dir "finite-evidence") in
  let package = {(package dir "sampling") with model_access=Types.Host_sampling} in
  let calls = ref 0 and response_meta = ref None in
  let broker = match Sampling.create ~store ~package ~instance_id:"finite" ~route:"r"
    ~invoke:(fun ~route:_ ~request:_ _ -> incr calls; Ok {
      S.role=S.Assistant;content=S.Text {type_="text";text="answer"};model="fixture";
      stop_reason=Some "endTurn";_meta= !response_meta}) () with
    | Ok value -> value | Error detail -> fail detail in
  let handler = match Sampling.for_worker broker ~package ~instance_id:"finite" with
    | Ok value -> value | Error detail -> fail detail in
  let params = match S.create_message_params_of_yojson (`Assoc ["messages",`List [];"maxTokens",`Int 1]) with
    | Ok value -> value | Error detail -> fail detail in
  let result = Sampling.with_observation broker ~binding:(`Assoc []) ~sources:(`List [])
    ~on_error:Fun.id (fun () ->
  List.iter (fun number ->
    let metadata = `Assoc ["extension",`List [`Assoc ["number",`Float number]]] in
    check bool "nonfinite request refused before invocation" true
      (Result.is_error (handler {params with _meta=Some metadata}));
    check int "invalid request invokes no model" 0 !calls) [Float.nan;Float.infinity;Float.neg_infinity];
  List.iter (fun number ->
    response_meta := Some (`Assoc ["nested",`List [`Float number]]);
    check bool "nonfinite response is not accepted" true (Result.is_error (handler params)))
    [Float.nan;Float.infinity;Float.neg_infinity];
  response_meta := Some (`Assoc ["nested",`List [`Float 0.5]]);
  check bool "finite response remains accepted" true (Result.is_ok (handler params));
  check int "only three rejected responses and finite control invoke" 4 !calls;
  Ok {Types.rows=[];coverage=[]}) in
  check bool "finite evidence fixture completes an active observation" true (Result.is_ok result))

let test_sampling_recovery_reports_unreadable_pending_index () = with_fixture (fun _env _sw dir _docker ->
  let module Store = Masc.Lane_addon_store in
  let store = Store.create ~root:(Filename.concat dir "partial-recovery") in
  let instance_id = "partial" in
  let save result = match result with Ok () -> () | Error detail -> fail detail in
  save (Store.save_sampling_request store ~instance_id ~request_id:"pending" (`Assoc ["state",`String "pending"]));
  save (Store.save_sampling_request store ~instance_id ~request_id:"finished" (`Assoc ["state",`String "finished"]));
  save (Store.save_sampling_outcome store ~instance_id ~request_id:"finished"
    (`Assoc ["state",`String "finished"; "instance_id",`String instance_id;
             "request_id",`String "finished"]));
  let parent = Filename.concat (Store.root store) "sampling" in
  let primary = Filename.concat parent (Sys.readdir parent).(0) in
  let backup = primary ^ ".saved" in
  Unix.rename primary backup;
  write primary "unreadable index";
  Fun.protect ~finally:(fun () -> Unix.unlink primary; Unix.rename backup primary) (fun () ->
    let visited = ref 0 in
    let result = Store.iter_sampling_requests (Store.create ~root:(Store.root store))
      ~instance_id ~max_bytes:65536 ~f:(fun row ->
        check string "journal still visits finished record" "finished"
          (Yojson.Safe.Util.member "state" row |> Yojson.Safe.Util.to_string);
        incr visited; Ok ()) in
    check int "available journal visited once" 1 !visited;
    check bool "missing pending index is not full success" true (Result.is_error result));
  let rows = match sampling_requests store ~instance_id with Ok rows -> rows | Error detail -> fail detail in
  check int "restored primary includes pending and finished" 2 (List.length rows))

let test_pending_sampling_recovery_syncs_reopened_root () = with_fixture (fun _env _sw dir _docker ->
  let module Store = Masc.Lane_addon_store in
  let require = function Ok value -> value | Error detail -> fail detail in
  let store = Store.create ~root:(Filename.concat dir "pending-root-recovery") in
  let instance_id = "pending-only" in
  List.iter (fun request_id ->
    require (Store.save_sampling_request store ~instance_id ~request_id
      (`Assoc ["state", `String "pending"; "instance_id", `String instance_id;
               "request_id", `String request_id])))
    ["first"; "second"];
  let reopened = Store.create ~root:(Store.root store) in
  let root_parent = Unix.stat (Filename.dirname (Store.root store)) in
  let syncs = ref 0 and delivered = ref [] in
  let recover ~fail_sync =
    Store.For_testing.iter_sampling_requests reopened ~instance_id ~max_bytes:65536
      ~sync_file:(fun _ -> fail "pending requests must not require a terminal blob")
      ~sync_parent:(fun fd ->
        let actual = Unix.fstat fd in
        check bool "syncs the store root's parent" true
          (actual.Unix.st_dev = root_parent.Unix.st_dev && actual.Unix.st_ino = root_parent.Unix.st_ino);
        incr syncs;
        if fail_sync then raise (Unix.Unix_error (Unix.EIO, "fsync", "pending root parent"));
        Unix.fsync fd)
      ~f:(fun row ->
        check string "pending state survives recovery" "pending"
          Yojson.Safe.Util.(row |> member "state" |> to_string);
        delivered := Yojson.Safe.Util.(row |> member "request_id" |> to_string) :: !delivered;
        Ok ()) in
  check bool "failed root sync refuses pending recovery" true (Result.is_error (recover ~fail_sync:true));
  check int "no pending request delivered before root durability" 0 (List.length !delivered);
  require (recover ~fail_sync:false);
  check (list string) "same handle retry delivers both pending requests" ["first"; "second"]
    (List.sort String.compare !delivered);
  require (recover ~fail_sync:false);
  check int "later recovery still delivers both requests" 4 (List.length !delivered);
  check int "one failed and one successful root sync, no duplicate obligation" 2 !syncs;
  let cold = Store.create ~root:(Store.root store) in
  let cold_syncs = ref 0 in
  let load ~fail_sync = Store.For_testing.load_sampling_request_bounded cold
    ~instance_id ~request_id:"first" ~budget:(Store.read_budget ~max_bytes:65536)
    ~sync_file:Unix.fsync ~sync_parent:(fun fd ->
      let actual = Unix.fstat fd in
      if actual.Unix.st_dev = root_parent.Unix.st_dev && actual.Unix.st_ino = root_parent.Unix.st_ino then (
        incr cold_syncs;
        if fail_sync then raise (Unix.Unix_error (Unix.EIO,"fsync","cold root parent")));
      Unix.fsync fd) in
  check bool "cold read cannot bypass failed root durability" true (Result.is_error (load ~fail_sync:true));
  List.iter (fun () -> check bool "cold read retries the same root obligation" true
    (Result.is_ok (load ~fail_sync:false))) [();()];
  check int "cold root failure remains pending until one successful sync" 2 !cold_syncs)

let test_sampling_recovery_rejects_replaced_root_parent () = with_fixture (fun _env _sw dir _docker ->
  let module Store = Masc.Lane_addon_store in
  let require = function Ok value -> value | Error detail -> fail detail in
  List.iter (fun replace_parent ->
    let parent = Filename.concat dir (if replace_parent then "swapped-parent" else "swapped-root") in
    Unix.mkdir parent 0o700;
    let root = Filename.concat parent "store" in
    let store = Store.create ~root in
    let instance_id = "pending" in
    require (Store.save_sampling_request store ~instance_id ~request_id:"one"
      (`Assoc ["state", `String "pending"]));
    let reopened = Store.create ~root in
    let target = if replace_parent then parent else root in
    let saved = target ^ ".saved" in
    let swapped = ref false and visited = ref 0 and syncs = ref 0 in
    let recover ~swap =
      Store.For_testing.iter_sampling_requests reopened ~instance_id ~max_bytes:65536
        ~sync_file:Unix.fsync ~sync_parent:(fun fd ->
          incr syncs;
          if swap then (
            Unix.rename target saved;
            swapped := true;
            Unix.mkdir target 0o700;
            if replace_parent then Unix.mkdir root 0o700);
          Unix.fsync fd)
        ~f:(fun _ -> incr visited; Ok ()) in
    Fun.protect ~finally:(fun () ->
      if !swapped then (
        if replace_parent then Unix.rmdir root;
        Unix.rmdir target;
        Unix.rename saved target)) (fun () ->
      check bool "directory replacement invalidates root sync" true
        (Result.is_error (recover ~swap:true));
      check int "old root records are not delivered after replacement" 0 !visited);
    require (recover ~swap:false);
    check int "restored root can retry on the same handle" 1 !visited;
    check int "identity failure retains the root sync obligation" 2 !syncs)
    [false; true])

let test_sampling_recovery_streams_bounded_records () = with_fixture (fun _env _sw dir _docker ->
  let module Store = Masc.Lane_addon_store in
  let store = Store.create ~root:(Filename.concat dir "streaming-recovery") in
  let instance_id = "streaming" in
  for n = 1 to 128 do
    match Store.save_sampling_request store ~instance_id ~request_id:(string_of_int n)
      (`Assoc ["n",`Int n]) with Ok () -> () | Error detail -> fail detail
  done;
  let count = ref 0 in
  let result = Store.iter_sampling_requests store ~instance_id ~max_bytes:64
    ~f:(fun _ -> incr count; if !count = 3 then Error "requested stop" else Ok ()) in
  check bool "callback can stop without reading whole history" true (result = Error "requested stop");
  check int "only requested prefix reaches callback" 3 !count;
  let result = Store.iter_sampling_requests store ~instance_id ~max_bytes:1 ~f:(fun _ -> fail "oversized record decoded") in
  check bool "per-record envelope is enforced before JSON allocation" true (Result.is_error result);
  count := 0;
  (match Store.iter_sampling_requests store ~instance_id ~max_bytes:64
    ~f:(fun _ -> incr count; Ok ()) with Ok () -> () | Error detail -> fail detail);
  check int "complete scan still visits every retained request" 128 !count)

let test_receipt_projection_reads_shared_outcome_once () = with_fixture (fun _env _sw dir _docker ->
  let module Sampling = Masc.Lane_addon_sampling in
  let module Store = Masc.Lane_addon_store in
  let module S = Mcp_protocol.Sampling in
  let require = function Ok value -> value | Error detail -> fail detail in
  let store = Store.create ~root:(Filename.concat dir "large-model-evidence") in
  let max_bytes = 4 * 1024 * 1024 in
  let package = {(package dir "sampling") with model_access=Types.Host_sampling;
    resources={(package dir "sampling").resources with max_reply_bytes=max_bytes}} in
  let answer : S.create_message_result = {role=Assistant;
    content=Text {type_="text";text=String.make (3 * 1024 * 1024) 'x'};
    model="large-model";stop_reason=None;_meta=None} in
  let broker = require (Sampling.create ~store ~package ~instance_id:"large-worker"
    ~route:"fixture" ~invoke:(fun ~route:_ ~request:_ _ -> Ok answer) ()) in
  let handler = require (Sampling.for_worker broker ~package ~instance_id:"large-worker") in
  let params = require (S.create_message_params_of_yojson (`Assoc [
    "messages",`List [`Assoc ["role",`String "user";"content",`Assoc [
      "type",`String "text";"text",`String "large answer fixture"]]];"maxTokens",`Int 1])) in
  let output = require (Sampling.with_observation broker ~binding:(`Assoc [])
    ~sources:(`List []) ~on_error:Fun.id (fun () ->
      Result.map (fun returned ->
        let refs = Option.get returned.S._meta |> Yojson.Safe.Util.member "masc.lane_sampling" in
        let evidence = List.map (fun key -> require (Types.evidence_of_json
          (Yojson.Safe.Util.member key refs))) ["request";"outcome"] in
        {Types.rows=[{id="answer";lane_id="fusion/computation";kind=Types.Value;
          title="large";observed_at=1.;subject_id="analysis";clock=None;actor=None;
          fields=[];evidence;related_ids=[]}];coverage=[]}) (handler params))) in
  let receipts = require (Sampling.retained_receipts ~store ~instance_id:"large-worker"
    ~max_bytes output) in
  check int "request and row share one terminal read within the 4 MiB envelope" 1 (List.length receipts);
  check bool "projection preserves the complete 3 MiB answer" true
    (Yojson.Safe.Util.(member "terminal" (List.hd receipts) |> member "response")
     = S.create_message_result_to_yojson answer);
  let receipt = List.hd receipts in
  let reference key = require (Types.evidence_of_json (Yojson.Safe.Util.member key receipt)) in
  let request = reference "request" and outcome = reference "outcome" in
  let request_id = require (Store.read_blob store request) |> Yojson.Safe.from_string
    |> Yojson.Safe.Util.member "request_id" |> Yojson.Safe.Util.to_string in
  let record = match Store.load_sampling_request_bounded store ~instance_id:"large-worker"
    ~request_id ~budget:(Store.read_budget ~max_bytes) with
    | Ok (Some (`Assoc fields)) -> fields
    | _ -> fail "missing compact sampling record" in
  let bytes = require (Store.read_blob store outcome) in
  require (Store.save_sampling_outcome store ~instance_id:"large-worker" ~request_id
    (`Assoc (("outcome_bytes",`String bytes) :: record)));
  Unix.unlink (Filename.concat (Store.root store) ("evidence/" ^ Store.digest bytes ^ ".json"));
  let cold = Store.create ~root:(Store.root store) in
  let recovered = require (Sampling.retained_receipts ~store:cold ~instance_id:"large-worker"
    ~max_bytes output) in
  check bool "cold journal supplies the large outcome within the same envelope" true (recovered = receipts);
  let reopened = Store.create ~root:(Store.root store) in
  let repeated = require (Sampling.retained_receipts ~store:reopened ~instance_id:"large-worker"
    ~max_bytes output) in
  check bool "repeated cold read does not reread an inline journal body" true (repeated = receipts);
  require (Store.save_sampling_outcome store ~instance_id:"large-worker" ~request_id
    (`Assoc (("outcome_bytes",`String bytes) :: record)));
  let path = Filename.concat (Store.root store) ("evidence/" ^ Store.digest bytes ^ ".json") in
  let before = Unix.stat path in
  let uncompacted = require (Sampling.retained_receipts
    ~store:(Store.create ~root:(Store.root store)) ~instance_id:"large-worker" ~max_bytes output) in
  check bool "existing 3 MiB outcome is not charged twice with inline journal" true
    (uncompacted = receipts);
  let after = Unix.stat path in
  check bool "inline verification preserves the intact outcome inode" true
    (before.Unix.st_dev = after.Unix.st_dev && before.Unix.st_ino = after.Unix.st_ino))

let test_sampling_receipt_requires_durable_journal () = with_fixture (fun _env _sw dir _docker ->
  let module Store = Masc.Lane_addon_store in
  let require = function Ok value -> value | Error detail -> fail detail in
  let store = Store.create ~root:(Filename.concat dir "receipt-store") in
  let instance_id = "receipt-worker" and request_id = "request-1" in
  let request = require (Store.write_blob store (Yojson.Safe.to_string (`Assoc [
    "kind",`String "model_request";"instance_id",`String instance_id;
    "request_id",`String request_id]))) in
  let outcome = require (Store.write_blob store (Yojson.Safe.to_string (`Assoc [
    "kind",`String "model_outcome";"instance_id",`String instance_id;
    "request",Types.evidence_to_json request;"status",`String "answered"]))) in
  let record state outcome = `Assoc ["instance_id",`String instance_id;
    "request_id",`String request_id;"request",Types.evidence_to_json request;
    "state",`String state;"outcome",outcome] in
  require (Store.save_sampling_request store ~instance_id ~request_id (record "pending" `Null));
  let terminal = record "finished" (Types.evidence_to_json outcome) in
  let directory = Filename.concat (Filename.concat (Store.root store) "sampling-outcomes")
    (Store.digest instance_id) in
  Unix.mkdir (Filename.dirname directory) 0o700;
  Unix.mkdir directory 0o700;
  let path = Filename.concat directory (Store.digest request_id ^ ".json") in
  let bytes = Yojson.Safe.to_string terminal in
  let fail_sync _ = raise (Unix.Unix_error (Unix.EIO,"fsync",path)) in
  let publication = Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
    ~sync_parent:fail_sync path bytes in
  check bool "terminal was renamed but publication durability failed" true
    (match publication with Error {Fs_compat.stage=Fs_compat.After_rename;_} -> true | _ -> false);
  check bool "uncertain terminal bytes are visible" true (Sys.file_exists path);
  let load ~budget ~sync_file ~sync_parent = Store.For_testing.load_sampling_request_bounded
    ~budget ~sync_file ~sync_parent store ~instance_id ~request_id in
  let rejected label = function
    | Error (Store.Read_failed _) -> ()
    | Error Store.Read_limit_exceeded -> fail (label ^ ": unexpected byte limit")
    | Ok _ -> fail (label ^ ": visible terminal authorized without durable verification") in
  let budget = Store.read_budget ~max_bytes:(String.length bytes) in
  rejected "file sync" (load ~budget ~sync_file:fail_sync
    ~sync_parent:(fun _ -> fail "failed file sync must not reach parent sync"));
  check bool "failed verification retains the aggregate read charge" true
    (match load ~budget ~sync_file:Unix.fsync ~sync_parent:Unix.fsync with
     | Error Store.Read_limit_exceeded -> true | _ -> false);
  rejected "parent sync" (load ~budget:(Store.read_budget ~max_bytes:(String.length bytes))
    ~sync_file:Unix.fsync ~sync_parent:fail_sync);
  let repaired = load ~budget:(Store.read_budget ~max_bytes:(String.length bytes))
    ~sync_file:Unix.fsync ~sync_parent:Unix.fsync in
  check bool "successful durable verification exposes the exact terminal" true
    (repaired = Ok (Some terminal));
  check bool "oversized journal fails with the typed limit before syncing" true
    (match load ~budget:(Store.read_budget ~max_bytes:(String.length bytes - 1))
      ~sync_file:(fun _ -> fail "oversized journal must not sync") ~sync_parent:Unix.fsync with
     | Error Store.Read_limit_exceeded -> true | _ -> false);
  let output : Types.output = {rows=[{id="answer";lane_id="analysis";kind=Types.Value;
    title="answer";observed_at=1.;subject_id="answer";clock=None;actor=None;
    fields=[];evidence=[request];related_ids=[]}];coverage=[]} in
  let receipts = require (Masc.Lane_addon_sampling.retained_receipts ~store ~instance_id
    ~max_bytes:1048576 output) in
  check int "durably repaired terminal can project its answer" 1 (List.length receipts);
  check string "projection carries the retained outcome" "answered"
    Yojson.Safe.Util.(List.hd receipts |> member "terminal" |> member "status" |> to_string))

let test_sampling_terminal_recovery_and_host_redaction () = with_fixture (fun _env _sw dir _docker ->
  let module Store = Masc.Lane_addon_store in
  let module Sampling = Masc.Lane_addon_sampling in
  let module S = Mcp_protocol.Sampling in
  let store = Store.create ~root:(Filename.concat dir "terminal-recovery") in
  let p = {(package dir "sampling") with model_access=Types.Host_sampling} in
  let params = match S.create_message_params_of_yojson (`Assoc ["messages",`List [];"maxTokens",`Int 1]) with
    | Ok value -> value | Error detail -> fail detail in
  let invoke instance_id answer =
    let broker = match Sampling.create ~store ~package:p ~instance_id ~route:"r"
      ~invoke:(fun ~route:_ ~request:_ _ -> answer) () with Ok value -> value | Error detail -> fail detail in
    let handler = match Sampling.for_worker broker ~package:p ~instance_id with
      | Ok value -> value | Error detail -> fail detail in
    run_sampling_observation broker handler params in
  let answer meta : S.create_message_result = {role=Assistant;content=Text {type_="text";text="answer"};
    model="model";stop_reason=None;_meta=Some meta} in
  (match invoke "unsafe-json" (Ok (answer (`Intlit "not-json"))) with
   | Ok _ -> fail "invalid serialized JSON accepted" | Error _ -> ());
  let rows = match sampling_requests store ~instance_id:"unsafe-json" with Ok rows -> rows | Error detail -> fail detail in
  check bool "invalid serialization is terminal and recoverable" true
    (List.for_all (fun row -> Yojson.Safe.Util.member "state" row = `String "finished") rows);
  let secret = "https://internal.example/token=host-secret" in
  let host_error_reply = match invoke "host-error" (Error secret) with
    | Ok _ -> fail "host failure accepted"
    | Error reply -> reply in
  let json = Yojson.Safe.from_string host_error_reply in
  check bool "host diagnostics stay out of package response" true
    (Yojson.Safe.Util.member "error" json = `Null);
  check string "error reply status is host_error" "host_error"
    (Yojson.Safe.Util.member "status" json |> Yojson.Safe.Util.to_string);
  let evidence_json = Yojson.Safe.Util.member "evidence" json in
  let outcome_ref = match Types.evidence_of_json (Yojson.Safe.Util.member "outcome" evidence_json) with
    | Ok value -> value | Error detail -> fail detail in
  let blob_content = match Store.read_blob store outcome_ref with
    | Ok bytes -> Yojson.Safe.from_string bytes | Error detail -> fail detail in
  check string "stored outcome preserves host_error status" "host_error"
    (Yojson.Safe.Util.member "status" blob_content |> Yojson.Safe.Util.to_string);
  check string "stored outcome recovers actual host error detail" secret
    (Yojson.Safe.Util.member "error" blob_content |> Yojson.Safe.Util.to_string);
  let host_error_rows = match sampling_requests store ~instance_id:"host-error" with
    | Ok rows -> rows | Error detail -> fail detail in
  check bool "host failure outcome is indexed as finished" true
    (List.for_all (fun row -> Yojson.Safe.Util.member "state" row = `String "finished") host_error_rows);
  let reply_size = String.length host_error_reply in
  let bounded_p = {p with resources={p.resources with max_reply_bytes=reply_size-1}} in
  let invoke_bounded instance_id answer =
    let broker = match Sampling.create ~store ~package:bounded_p ~instance_id ~route:"r"
      ~invoke:(fun ~route:_ ~request:_ _ -> answer) () with Ok value -> value | Error detail -> fail detail in
    let handler = match Sampling.for_worker broker ~package:bounded_p ~instance_id with
      | Ok value -> value | Error detail -> fail detail in
    run_sampling_observation broker handler params in
  let overflow_result = invoke_bounded "overflow-error" (Error secret) in
  check bool "inline error response exceeding envelope is refused" true (Result.is_error overflow_result);
  (match overflow_result with
   | Error refusal ->
       check bool "overflow error refusal obeys package byte envelope" true
         (String.length (Yojson.Safe.to_string (`String refusal)) <= bounded_p.resources.max_reply_bytes);
       check string "overflow error returns compact bounded refusal"
         "sampling failed; outcome retained" refusal
   | Ok _ -> fail "oversized error reply accepted");
  let overflow_rows = match sampling_requests store ~instance_id:"overflow-error" with
    | Ok rows -> rows | Error detail -> fail detail in
  check int "overflow outcome remains indexed" 1 (List.length overflow_rows);
  check bool "overflow outcome remains indexed as finished" true
    (List.for_all (fun row -> Yojson.Safe.Util.member "state" row = `String "finished") overflow_rows);
  let overflow_row = match overflow_rows with [row] -> row | _ -> fail "missing overflow row" in
  let overflow_outcome_ref = match Types.evidence_of_json (Yojson.Safe.Util.member "outcome" overflow_row) with
    | Ok value -> value | Error detail -> fail detail in
  let overflow_blob = match Store.read_blob store overflow_outcome_ref with
    | Ok bytes -> Yojson.Safe.from_string bytes | Error detail -> fail detail in
  check string "overflow outcome recovers actual host error from storage" secret
    (Yojson.Safe.Util.member "error" overflow_blob |> Yojson.Safe.Util.to_string);
  let journal = Filename.concat (Store.root store) "sampling-outcomes" in
  let backup = journal ^ ".saved" in
  Unix.rename journal backup;
  write journal "unavailable journal";
  Fun.protect ~finally:(fun () -> Unix.unlink journal; Unix.rename backup journal) (fun () ->
    check bool "primary terminal index succeeds when journal is unavailable" true
      (Result.is_ok (invoke "journal-failure" (Ok (answer `Null))));
    let recovered = ref [] in
    let result = Store.iter_sampling_requests (Store.create ~root:(Store.root store))
      ~instance_id:"journal-failure" ~max_bytes:65536
      ~f:(fun row -> recovered := row :: !recovered; Ok ()) in
    check int "reopened recovery reads primary while journal stays unavailable" 1
      (List.length !recovered);
    check bool "unreadable journal prevents complete recovery claim" true (Result.is_error result);
    check bool "unavailable journal with absent primary remains an error" true
      (Result.is_error (sampling_requests (Store.create ~root:(Store.root store))
        ~instance_id:"no-primary-fallback")));
  let rows = match sampling_requests store ~instance_id:"journal-failure" with Ok rows -> rows | Error detail -> fail detail in
  let row = match rows with [row] -> row | _ -> fail "missing terminal recovery row" in
  let reference = match Types.evidence_of_json (Yojson.Safe.Util.member "outcome" row) with
    | Ok value -> value | Error detail -> fail detail in
  let hash = match reference.sha256 with Some hash -> hash | None -> fail "missing digest" in
  let bytes = match Store.read_blob store reference with Ok bytes -> bytes | Error detail -> fail detail in
  let request_id = Yojson.Safe.Util.(row |> member "request_id" |> to_string) in
  let first_terminal = match row with `Assoc fields -> `Assoc (("outcome_bytes",`String bytes)::fields)
    | _ -> fail "invalid terminal row" in
  (match Store.save_sampling_request store ~instance_id:"journal-failure" ~request_id first_terminal with
   | Ok () -> () | Error detail -> fail detail);
  Unix.unlink (Filename.concat (Store.root store) ("evidence/" ^ hash ^ ".json"));
  let recovered = Store.create ~root:(Store.root store) in
  (match Store.load_sampling_request_bounded ~budget:(Store.read_budget ~max_bytes:65536)
    recovered ~instance_id:"journal-failure" ~request_id with
   | Ok (Some _) -> ()
   | Ok None -> fail "missing primary terminal record"
   | Error (Store.Read_failed detail) -> fail detail
   | Error Store.Read_limit_exceeded -> fail "terminal exceeded fixture allowance");
  check bool "cold read reconstructs outcome from first durable terminal record" true
    (Result.is_ok (Store.read_blob store reference));
  (* Cold reads compact the restored journal. Recreate the interrupted state
     so the parent's strict existing-blob recovery checks still exercise it. *)
  (match Store.save_sampling_request store ~instance_id:"journal-failure" ~request_id first_terminal with
   | Ok () -> () | Error detail -> fail detail);
  let blob_path = Filename.concat (Store.root store) ("evidence/" ^ hash ^ ".json") in
  let before = Unix.stat blob_path in
  ignore (match sampling_requests store ~instance_id:"journal-failure" with
    | Ok rows -> rows | Error detail -> fail detail);
  let after = Unix.stat blob_path in
  check bool "intact recovery blob is not replaced" true
    (before.Unix.st_dev = after.Unix.st_dev && before.Unix.st_ino = after.Unix.st_ino);
  let recover ?(store=store) ~sync_file ~sync_parent ~visited () =
    Store.For_testing.iter_sampling_requests ~sync_file ~sync_parent store
      ~instance_id:"journal-failure" ~max_bytes:65536
      ~f:(fun _ -> incr visited; Ok ()) in
  let synced = ref [] and visited = ref 0 in
  let sync label fd = synced := !synced @ [label]; Unix.fsync fd in
  (match recover ~sync_file:(sync "file") ~sync_parent:(sync "parent") ~visited () with
   | Ok () -> () | Error detail -> fail detail);
  check (list string) "intact recovery establishes file and parent durability" ["file"; "parent"] !synced;
  check int "only durable evidence reaches recovery callback" 1 !visited;
  List.iter (fun failing ->
    visited := 0;
    let sync label fd =
      if label = failing then raise (Unix.Unix_error (Unix.EIO, "fsync", label))
      else Unix.fsync fd in
    check bool "failed durability is not successful recovery" true
      (Result.is_error (recover ~sync_file:(sync "file") ~sync_parent:(sync "parent") ~visited ()));
    check int "unsynced evidence is not delivered" 0 !visited) ["file"; "parent"];
  let reopened = Store.create ~root:(Store.root store) in
  let root_parent = Unix.stat (Filename.dirname (Store.root store)) in
  let root_syncs = ref 0 in
  let sync_root ~fail_sync fd =
    let stat = Unix.fstat fd in
    if stat.Unix.st_dev = root_parent.Unix.st_dev && stat.Unix.st_ino = root_parent.Unix.st_ino then (
      incr root_syncs;
      if fail_sync then raise (Unix.Unix_error (Unix.EIO, "fsync", "root parent")));
    Unix.fsync fd in
  visited := 0;
  check bool "reopened root sync failure prevents successful recovery" true
    (Result.is_error (recover ~store:reopened ~sync_file:Unix.fsync
      ~sync_parent:(sync_root ~fail_sync:true) ~visited ()));
  check int "unestablished root is not delivered" 0 !visited;
  List.iter (fun () ->
    match recover ~store:reopened ~sync_file:Unix.fsync
      ~sync_parent:(sync_root ~fail_sync:false) ~visited () with
    | Ok () -> () | Error detail -> fail detail) [(); ()];
  check int "failed root sync retries and successful sync clears its obligation" 2 !root_syncs;
  let external_path = Filename.concat dir "external-outcome.json" in
  write external_path bytes;
  let saved_blob = blob_path ^ ".saved" in
  Unix.rename blob_path saved_blob;
  Unix.symlink external_path blob_path;
  Fun.protect ~finally:(fun () -> Unix.unlink blob_path; Unix.rename saved_blob blob_path) (fun () ->
    check bool "matching external symlink is not owned recovery evidence" true
      (Result.is_error (sampling_requests store ~instance_id:"journal-failure")));
  Unix.rename blob_path saved_blob;
  Unix.link external_path blob_path;
  Fun.protect ~finally:(fun () -> Unix.unlink blob_path; Unix.rename saved_blob blob_path) (fun () ->
    check bool "matching external hardlink is not owned recovery evidence" true
      (Result.is_error (sampling_requests store ~instance_id:"journal-failure")));
  let added_link = blob_path ^ ".linked" in
  visited := 0;
  Fun.protect ~finally:(fun () -> Unix.unlink added_link) (fun () ->
    check bool "hardlink created during sync cannot satisfy recovery" true
      (Result.is_error (recover ~visited ~sync_parent:Unix.fsync ~sync_file:(fun fd ->
        Unix.fsync fd; Unix.link blob_path added_link) ()));
    check int "multiply linked evidence is not delivered" 0 !visited);
  visited := 0;
  Fun.protect ~finally:(fun () -> Unix.unlink blob_path; Unix.rename saved_blob blob_path) (fun () ->
    check bool "a symlink swap during file sync cannot satisfy recovery" true
      (Result.is_error (recover ~visited ~sync_parent:Unix.fsync ~sync_file:(fun fd ->
        Unix.fsync fd; Unix.rename blob_path saved_blob; Unix.symlink external_path blob_path) ()));
    check int "swapped evidence is not delivered" 0 !visited);
  Unix.unlink blob_path;
  Unix.mkfifo blob_path 0o600;
  Fun.protect ~finally:(fun () -> Unix.unlink blob_path) (fun () ->
    check bool "FIFO recovery blob is rejected without waiting for a writer" true
      (Result.is_error (sampling_requests store ~instance_id:"journal-failure"))))

let test_sampling_recovery_reports_unreadable_terminal_journal () = with_fixture (fun _env _sw dir _docker ->
  let module Store = Masc.Lane_addon_store in
  let store = Store.create ~root:(Filename.concat dir "stale-primary-recovery") in
  let require = function Ok value -> value | Error detail -> fail detail in
  let instance_id = "journal-only" and request_id = "completed" in
  require (Store.save_sampling_request store ~instance_id ~request_id (`Assoc ["state", `String "pending"]));
  require (Store.save_sampling_outcome store ~instance_id ~request_id
    (`Assoc ["state", `String "finished"; "instance_id", `String instance_id;
             "request_id", `String request_id]));
  let journal = Filename.concat (Store.root store) "sampling-outcomes" in
  let backup = journal ^ ".saved" in
  Unix.rename journal backup;
  write journal "unreadable terminal journal";
  Fun.protect ~finally:(fun () -> Unix.unlink journal; Unix.rename backup journal) (fun () ->
    let visited = ref 0 in
    let result = Store.iter_sampling_requests (Store.create ~root:(Store.root store))
      ~instance_id ~max_bytes:65536 ~f:(fun row ->
        check string "readable primary still exposes its stale state" "pending"
          Yojson.Safe.Util.(row |> member "state" |> to_string);
        incr visited; Ok ()) in
    check int "readable primary is visited" 1 !visited;
    check bool "stale primary is not complete recovery" true (Result.is_error result));
  let rows = require (sampling_requests store ~instance_id) in
  check int "restored journal owns the completed request" 1 (List.length rows);
  check string "terminal journal supersedes stale pending primary" "finished"
    Yojson.Safe.Util.(List.hd rows |> member "state" |> to_string))

let test_sampling_blob_failure_keeps_request_evidence () = List.iter (fun block_recovery ->
  with_fixture (fun _env _sw dir _docker ->
  let module Store = Masc.Lane_addon_store in
  let module Sampling = Masc.Lane_addon_sampling in
  let module S = Mcp_protocol.Sampling in
  let store = Store.create ~root:(Filename.concat dir "blob-publication-failure") in
  let p = {(package dir "sampling") with model_access=Types.Host_sampling} in
  let params = match S.create_message_params_of_yojson
    (`Assoc ["messages",`List [];"maxTokens",`Int 1]) with
    | Ok value -> value | Error detail -> fail detail in
  let evidence_directory = Filename.concat (Store.root store) "evidence" in
  let recovery_directory = Filename.concat (Store.root store) "sampling-evidence" in
  let blocked_paths = ref [] in
  let invocations = ref 0 in
  let broker = match Sampling.create ~store ~package:p ~instance_id:"blob-failure" ~route:"r"
    ~invoke:(fun ~route:_ ~request _ ->
      incr invocations;
      let answer : S.create_message_result = {role=Assistant;
        content=Text {type_="text";text="known answer"};
        model="actual-model";stop_reason=None;_meta=None} in
      let bytes = Yojson.Safe.to_string ~std:true (`Assoc [
        "kind",`String "model_outcome";"instance_id",`String "blob-failure";
        "route",`String "r";"request",Types.evidence_to_json request;
        "status",`String "answered";"response",S.create_message_result_to_yojson answer]) in
      let hash = Store.digest bytes in
      let block directory =
        let path = Filename.concat directory (hash ^ ".json") in
        Unix.mkdir path 0o700;
        blocked_paths := path :: !blocked_paths in
      (* A directory at the exact outcome filename refuses atomic publication
         under both ordinary and root users; the request stays readable. *)
      block evidence_directory;
      if block_recovery then (Unix.mkdir recovery_directory 0o700; block recovery_directory);
      Ok answer) () with
    | Ok value -> value | Error detail -> fail detail in
  let handler = match Sampling.for_worker broker ~package:p ~instance_id:"blob-failure" with
    | Ok value -> value | Error detail -> fail detail in
  let reply = run_sampling_observation broker handler params in
  (* Restore only the canonical destination. An unusable recovery entry must
     not prevent reconstruction from the durable terminal journal. *)
  List.iter (fun path ->
    if Filename.dirname path = evidence_directory then Unix.rmdir path) !blocked_paths;
  check int "publication failure does not reinvoke the model" 1 !invocations;
  check bool "independent blob publication preserves the answer" (not block_recovery) (Result.is_ok reply);
  let refs = match reply with
    | Ok answer -> (match answer.S._meta with
        | Some json -> Yojson.Safe.Util.member "masc.lane_sampling" json
        | None -> fail "answer lost sampling evidence")
    | Error bytes ->
        let json = try Yojson.Safe.from_string bytes with Yojson.Json_error _ ->
          fail "publication failure lost structured request evidence" in
        check string "storage failure is not an invented model failure" "retention_error"
          Yojson.Safe.Util.(json |> member "status" |> to_string);
        check bool "storage error respects the package byte envelope" true
          (String.length (Yojson.Safe.to_string (`String bytes)) <= p.resources.max_reply_bytes);
        Yojson.Safe.Util.member "evidence" json in
  let request = match Types.evidence_of_json (Yojson.Safe.Util.member "request" refs) with
    | Ok value -> value | Error detail -> fail detail in
  check bool "request evidence remains readable" true (Result.is_ok (Store.read_blob store request));
  let outcome = match Types.evidence_of_json (Yojson.Safe.Util.member "outcome" refs) with
    | Ok value -> value | Error detail -> fail detail in
  check bool "dual publication failure leaves no readable outcome before recovery"
    (not block_recovery) (Result.is_ok (Store.read_blob store outcome));
  let output : Types.output = {rows=[{id="answer";lane_id="fusion/computation";
    kind=Types.Value;title="answer";observed_at=1.;subject_id="analysis";clock=None;
    actor=None;fields=[];evidence=[request;outcome];related_ids=[]}];coverage=[]} in
  let recovered = Store.create ~root:(Store.root store) in
  let receipts = match Sampling.retained_receipts ~store:recovered ~instance_id:"blob-failure"
    ~max_bytes:p.resources.max_reply_bytes output with
    | Ok value -> value | Error detail -> fail detail in
  check int "downstream projection resolves the recovered outcome" 1 (List.length receipts);
  check string "receipt keeps actual model identity" "actual-model"
    Yojson.Safe.Util.(List.hd receipts |> member "terminal" |> member "response" |> member "model" |> to_string);
  check int "cold receipt recovery does not reinvoke the model" 1 !invocations;
  let rows = match sampling_requests recovered ~instance_id:"blob-failure" with
    | Ok rows -> rows | Error detail -> fail detail in
  let row = match rows with [row] -> row | _ -> fail "missing terminal record" in
  check string "known result remains finished" "finished"
    Yojson.Safe.Util.(row |> member "state" |> to_string);
  List.iter (fun path ->
    if Filename.dirname path = recovery_directory then (
      check bool "canonical repair preserves the obstructing recovery entry" true
        ((Unix.lstat path).Unix.st_kind = Unix.S_DIR);
      Unix.rmdir path)) !blocked_paths;
  let terminal = match Store.read_blob recovered outcome with
    | Ok bytes -> Yojson.Safe.from_string bytes | Error detail -> fail detail in
  check string "recovery preserves known model result" "answered"
    Yojson.Safe.Util.(terminal |> member "status" |> to_string);
  let saved_recovery = recovery_directory ^ ".saved" in
  Unix.rename recovery_directory saved_recovery;
  write recovery_directory "unavailable recovery directory";
  Fun.protect ~finally:(fun () -> Unix.unlink recovery_directory; Unix.rename saved_recovery recovery_directory)
    (fun () ->
      check bool "broken recovery directory cannot hide a canonical request" true
        (Result.is_ok (Store.read_blob store request));
      check bool "bounded canonical read ignores broken recovery directory" true
        (Result.is_ok (Store.read_blob_bounded
          ~budget:(Store.read_budget ~max_bytes:p.resources.max_reply_bytes) store request))))) [false;true]

let test_sampling_retention_error_uses_encoded_reply_bound () = with_fixture (fun _env _sw dir _docker ->
  let module Store = Masc.Lane_addon_store in
  let module Sampling = Masc.Lane_addon_sampling in
  let module S = Mcp_protocol.Sampling in
  let require = function Ok value -> value | Error detail -> fail detail in
  let store = Store.create ~root:(Filename.concat dir "encoded-retention-error") in
  let reference = Types.evidence_to_json (Store.blob_reference "") in
  let raw_receipt = Yojson.Safe.to_string (`Assoc ["status", `String "retention_error";
    "evidence", `Assoc ["request", reference; "outcome", reference]]) in
  let max_reply_bytes = String.length raw_receipt in
  check bool "fixture distinguishes object bytes from the encoded error string" true
    (String.length (Yojson.Safe.to_string (`String raw_receipt)) > max_reply_bytes);
  let base = package dir "sampling" in
  let p = {base with model_access=Types.Host_sampling;
    resources={base.resources with max_reply_bytes}} in
  let params = require (S.create_message_params_of_yojson
    (`Assoc ["messages", `List []; "maxTokens", `Int 1])) in
  let calls = ref 0 in
  let broker = require (Sampling.create ~store ~package:p ~instance_id:"x" ~route:"r"
    ~invoke:(fun ~route:_ ~request _ ->
      incr calls;
      let bytes = Yojson.Safe.to_string ~std:true (`Assoc [
        "kind", `String "model_outcome"; "instance_id", `String "x";
        "route", `String "r"; "request", Types.evidence_to_json request;
        "status", `String "host_error"; "error", `String "failed"]) in
      check bool "terminal evidence fits independently of the wire error" true
        (String.length bytes <= max_reply_bytes);
      List.iter (fun directory ->
        let directory = Filename.concat (Store.root store) directory in
        if not (Sys.file_exists directory) then Unix.mkdir directory 0o700;
        Unix.mkdir (Filename.concat directory (Store.digest bytes ^ ".json")) 0o700)
        ["evidence"; "sampling-evidence"];
      Error "failed") ()) in
  let handler = require (Sampling.for_worker broker ~package:p ~instance_id:"x") in
  let reply = run_sampling_observation broker handler params in
  check int "storage failure does not reinvoke the model" 1 !calls;
  (match reply with
   | Ok _ -> fail "failed host call cannot report success"
   | Error message ->
       check bool "MCP error string fits the package wire envelope" true
         (String.length (Yojson.Safe.to_string (`String message)) <= max_reply_bytes));
  let journal = Filename.concat (Store.root store)
    (Filename.concat "sampling-outcomes" (Store.digest "x")) in
  let paths = Sys.readdir journal in
  check int "terminal recovery journal retained" 1 (Array.length paths);
  let terminal = Yojson.Safe.from_string (Fs_compat.load_file (Filename.concat journal paths.(0))) in
  check string "bounded refusal leaves the completed result durable" "finished"
    Yojson.Safe.Util.(terminal |> member "state" |> to_string))

let test_sampling_blob_read_preserves_canonical_failure () = with_fixture (fun _env _sw dir _docker ->
  let module Store = Masc.Lane_addon_store in
  let require = function Ok value -> value | Error detail -> fail detail in
  let store = Store.create ~root:(Filename.concat dir "canonical-read") in
  let bytes = "retained sampling outcome" in
  let reference = require (Store.write_blob store bytes) in
  let canonical = Filename.concat (Store.root store)
    (Filename.concat "evidence" (Store.digest bytes ^ ".json")) in
  Unix.unlink canonical;
  Unix.mkdir canonical 0o700;
  ignore (require (Store.write_sampling_blob store bytes));
  check string "directory obstruction permits recovery" bytes (require (Store.read_blob store reference));
  Unix.rmdir canonical;
  check string "missing canonical permits recovery" bytes (require (Store.read_blob store reference));
  write canonical (String.make (String.length bytes) 'x');
  check (result string string) "present corrupt canonical is not hidden" (Error "evidence digest mismatch")
    (Store.read_blob store reference);
  let budget = Store.read_budget ~max_bytes:(String.length bytes) in
  (match Store.read_blob_bounded ~budget store reference with
   | Error (Store.Read_failed "evidence digest mismatch") -> ()
   | _ -> fail "bounded read must report the canonical digest failure");
  Unix.unlink canonical;
  check bool "failed canonical bytes remain charged" true
    (Store.read_blob_bounded ~budget store reference = Error Store.Read_limit_exceeded);
  let recovery = Filename.concat (Store.root store)
    (Filename.concat "sampling-evidence" (Store.digest bytes ^ ".json")) in
  Unix.symlink recovery canonical;
  check bool "symlink cannot authorize recovery" true (Result.is_error (Store.read_blob store reference));
  Unix.unlink canonical;
  Unix.mkfifo canonical 0o600;
  check bool "FIFO cannot authorize recovery" true (Result.is_error (Store.read_blob store reference));
  Unix.unlink canonical;
  write canonical bytes;
  check string "valid canonical remains readable" bytes (require (Store.read_blob store reference));
  let directory = Filename.dirname canonical in
  let saved = directory ^ ".saved" in
  Unix.rename directory saved;
  Unix.symlink directory directory;
  Fun.protect ~finally:(fun () -> Unix.unlink directory; Unix.rename saved directory) (fun () ->
    check bool "unreadable canonical parent returns an error without recovery" true
      (Result.is_error (Store.read_blob store reference))))

let sampling_require = function Ok value -> value | Error detail -> fail detail

let sampling_retry_case store ~instance_id ~request_id answer =
  let module Store = Masc.Lane_addon_store in
  let request = sampling_require (Store.write_blob store ("request:" ^ request_id)) in
  let bytes = Yojson.Safe.to_string (`Assoc [
    "kind", `String "model_outcome"; "instance_id", `String instance_id;
    "request", Types.evidence_to_json request; "status", `String "answered";
    "response", `Assoc ["role", `String "assistant"; "model", `String "retained";
      "content", `Assoc ["type", `String "text"; "text", `String answer]]]) in
  let outcome = Store.blob_reference bytes in
  let fields = ["instance_id", `String instance_id; "request_id", `String request_id;
    "state", `String "finished"; "request", Types.evidence_to_json request;
    "outcome", Types.evidence_to_json outcome] in
  `Assoc (("outcome_bytes", `String bytes)::fields), `Assoc fields, outcome, bytes

let sampling_retry_path store instance_id request_id =
  let module Store = Masc.Lane_addon_store in
  Filename.concat (Store.root store)
    ("sampling-recovery/" ^ Store.digest instance_id ^ "/" ^ Store.digest request_id ^ ".json")

let test_sampling_retry_two_stores_and_concurrent_writer () = with_fixture (fun _ sw dir _ ->
  let module Store = Masc.Lane_addon_store in
  let store = Store.create ~root:(Filename.concat dir "retry-store") in
  let second = Store.create ~root:(Store.root store) in
  let instance_id = "shared-instance" in
  let old, _, _, _ = sampling_retry_case store ~instance_id ~request_id:"old" "completed history" in
  sampling_require (Store.save_sampling_request store ~instance_id ~request_id:"old" old);
  sampling_require (Store.recover_sampling_requests store ~instance_id ~max_reply_bytes:65536);
  let reads = ref [] in
  let retry () = Store.For_testing.retry_sampling_requests
    ~on_read:(fun path -> reads := path :: !reads) store ~instance_id ~max_reply_bytes:65536 in
  sampling_require (retry ());
  check int "steady retry does not read completed history" 0 (List.length !reads);
  let terminal, _, outcome, bytes = sampling_retry_case second ~instance_id ~request_id:"new" "concurrent result" in
  let marked, marked_u = Eio.Promise.create () in
  let release, release_u = Eio.Promise.create () in
  let writer = Eio.Fiber.fork_promise ~sw (fun () ->
    Store.For_testing.save_sampling_request second ~instance_id ~request_id:"new" terminal
      ~after_marker:(fun () -> Eio.Promise.resolve marked_u (); Eio.Promise.await release)) in
  Eio.Promise.await marked;
  let retry_started, retry_started_u = Eio.Promise.create () in
  let recovery = Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Promise.resolve retry_started_u (); retry ()) in
  Eio.Promise.await retry_started;
  Eio.Fiber.yield ();
  check bool "recovery waits for the same request writer lock" true
    (Option.is_none (Eio.Promise.peek recovery));
  Eio.Promise.resolve release_u ();
  sampling_require (Eio.Promise.await_exn writer);
  sampling_require (Eio.Promise.await_exn recovery);
  check string "another Store's complete result survives" bytes (sampling_require (Store.read_blob store outcome));
  check bool "recovery never reads unrelated completed request" false
    (List.exists (fun path -> Filename.basename path = Store.digest "old" ^ ".json") !reads);
  check bool "completed marker retired" false
    (Sys.file_exists (sampling_retry_path store instance_id "new")))

let test_sampling_retry_crash_and_failed_write_orphans () = with_fixture (fun _ _ dir _ ->
  let module Store = Masc.Lane_addon_store in
  let store = Store.create ~root:(Filename.concat dir "orphan-store") in
  let instance_id = "orphan-instance" in
  let terminal, _, _, _ = sampling_retry_case store ~instance_id ~request_id:"crash" "never journaled" in
  check bool "interruption after durable marker is explicit" true (Result.is_error
    (Store.For_testing.save_sampling_request ~after_marker:(fun () -> raise (Sys_error "interrupted before journal"))
      store ~instance_id ~request_id:"crash" terminal));
  check bool "crash leaves a durable marker" true
    (Sys.file_exists (sampling_retry_path store instance_id "crash"));
  sampling_require (Store.retry_sampling_requests (Store.create ~root:(Store.root store))
    ~instance_id ~max_reply_bytes:65536);
  check bool "known absent journals retire orphan" false
    (Sys.file_exists (sampling_retry_path store instance_id "crash"));
  let primary = Filename.concat (Store.root store) "sampling" in
  write primary "blocked namespace";
  check bool "failed journal write retains marker" true (Result.is_error
    (Store.save_sampling_request store ~instance_id ~request_id:"failed" terminal));
  check bool "unread namespace cannot authorize orphan removal" true (Result.is_error
    (Store.retry_sampling_requests store ~instance_id ~max_reply_bytes:65536));
  check bool "uncertain orphan remains" true
    (Sys.file_exists (sampling_retry_path store instance_id "failed"));
  Unix.unlink primary;
  sampling_require (Store.retry_sampling_requests store ~instance_id ~max_reply_bytes:65536);
  check bool "repaired absent namespace permits cleanup" false
    (Sys.file_exists (sampling_retry_path store instance_id "failed")))

let test_sampling_retry_preserves_other_namespace_and_unread_records () = with_fixture (fun _ _ dir _ ->
  let module Store = Masc.Lane_addon_store in
  let store = Store.create ~root:(Filename.concat dir "both-store") in
  let instance_id = "both-instance" and request_id = "both" in
  let terminal, _, outcome, bytes = sampling_retry_case store ~instance_id ~request_id "original result" in
  sampling_require (Store.save_sampling_request store ~instance_id ~request_id terminal);
  sampling_require (Store.save_sampling_outcome store ~instance_id ~request_id terminal);
  ignore (sampling_require (Store.load_sampling_request_bounded ~budget:(Store.read_budget ~max_bytes:65536)
    store ~instance_id ~request_id |> Result.map_error (function Store.Read_failed e -> e | Store.Read_limit_exceeded -> "limit")));
  check bool "cold compaction does not retire the other namespace" true
    (Sys.file_exists (sampling_retry_path store instance_id request_id));
  let primary = Filename.concat (Store.root store)
    ("sampling/" ^ Store.digest instance_id ^ "/" ^ Store.digest request_id ^ ".json") in
  let original = Fs_compat.load_file primary in
  Unix.unlink primary; Unix.mkdir primary 0o700;
  check bool "unread primary remains explicit despite compact outcome" true
    (Result.is_error (Store.retry_sampling_requests store ~instance_id ~max_reply_bytes:65536));
  check bool "unread primary retains marker" true
    (Sys.file_exists (sampling_retry_path store instance_id request_id));
  Unix.rmdir primary; write primary original;
  sampling_require (Store.retry_sampling_requests (Store.create ~root:(Store.root store)) ~instance_id ~max_reply_bytes:65536);
  check bool "both namespaces compacted before marker removal" true
    (Yojson.Safe.Util.member "outcome_bytes" (Yojson.Safe.from_file primary) = `Null);
  check string "recovery preserves exact original bytes" bytes (sampling_require (Store.read_blob store outcome));
  check bool "marker removed only after both complete" false
    (Sys.file_exists (sampling_retry_path store instance_id request_id)))

let test_sampling_discovery_separates_record_error_and_enumeration () = with_fixture (fun _ _ dir _ ->
  let module Store = Masc.Lane_addon_store in
  let store = Store.create ~root:(Filename.concat dir "discovery-store") in
  let instance_id = "discovery-instance" in
  let good, _, _, _ = sampling_retry_case store ~instance_id ~request_id:"good" "healthy" in
  sampling_require (Store.save_sampling_request store ~instance_id ~request_id:"good" good);
  sampling_require (Store.save_sampling_request store ~instance_id ~request_id:"broken" `Null);
  let report = Store.discover_sampling_requests store ~instance_id ~max_reply_bytes:65536 in
  check bool "record failure does not undo completed enumeration" true report.discovery_complete;
  check bool "broken record remains explicit" true (Result.is_error report.outcome);
  let reads = ref [] in
  ignore (Store.For_testing.retry_sampling_requests ~on_read:(fun path -> reads := path :: !reads)
    store ~instance_id ~max_reply_bytes:65536);
  check bool "retry skips healthy completed history even with a broken sibling" false
    (List.exists (fun p -> Filename.basename p = Store.digest "good" ^ ".json") !reads);
  let marker = sampling_retry_path store instance_id "broken" in
  write marker "malformed marker";
  check bool "malformed marker refuses retry" true (Result.is_error
    (Store.retry_sampling_requests store ~instance_id ~max_reply_bytes:65536));
  check string "malformed marker is preserved" "malformed marker" (Fs_compat.load_file marker);
  let report = Store.discover_sampling_requests store ~instance_id ~max_reply_bytes:65536 in
  check bool "failed marker seed keeps discovery pending" false report.discovery_complete;
  check string "discovery does not overwrite malformed marker" "malformed marker" (Fs_compat.load_file marker))

let test_sampling_pending_discovery_resumes_after_namespace_repair () = with_fixture (fun _ _ dir _ ->
  let module Store = Masc.Lane_addon_store in
  let store = Store.create ~root:(Filename.concat dir "unfinished-discovery") in
  let instance_id = "legacy-instance" and request_id = "legacy" in
  let terminal, _, outcome, bytes = sampling_retry_case store ~instance_id ~request_id "legacy result" in
  sampling_require (Store.save_sampling_request store ~instance_id ~request_id terminal);
  (* Model a pre-index journal: startup discovery must find it without a marker. *)
  Unix.unlink (sampling_retry_path store instance_id request_id);
  let namespace = Filename.concat (Store.root store) ("sampling/" ^ Store.digest instance_id) in
  let saved = namespace ^ ".saved" in
  Unix.rename namespace saved; write namespace "temporarily unreadable namespace";
  let report = Store.discover_sampling_requests store ~instance_id ~max_reply_bytes:65536 in
  check bool "incomplete enumeration remains pending" false report.discovery_complete;
  check bool "enumeration failure is explicit" true (Result.is_error report.outcome);
  Unix.unlink namespace; Unix.rename saved namespace;
  sampling_require (Store.retry_sampling_requests (Store.create ~root:(Store.root store))
    ~instance_id ~max_reply_bytes:65536);
  check string "pending-only entry resumes interrupted legacy discovery" bytes
    (sampling_require (Store.read_blob store outcome));
  let marker_dir = Filename.dirname (sampling_retry_path store instance_id request_id) in
  check bool "completed discovery sentinel is retired" false
    (Sys.file_exists (Filename.concat marker_dir ".discovery"));
  let next, _, next_outcome, next_bytes = sampling_retry_case store ~instance_id ~request_id:"next" "known pending result" in
  sampling_require (Store.save_sampling_request store ~instance_id ~request_id:"next" next);
  write (Filename.concat marker_dir ".discovery") "invalid discovery marker";
  check bool "malformed discovery stays an error" true (Result.is_error
    (Store.retry_sampling_requests store ~instance_id ~max_reply_bytes:65536));
  check string "malformed discovery does not starve known pending work" next_bytes
    (sampling_require (Store.read_blob store next_outcome));
  check string "malformed discovery evidence preserved" "invalid discovery marker"
    (Fs_compat.load_file (Filename.concat marker_dir ".discovery")))

let test_sampling_cold_read_keeps_optional_compaction () = with_fixture (fun _ _ dir _ ->
  let module Store = Masc.Lane_addon_store in
  let store = Store.create ~root:(Filename.concat dir "optional-compaction") in
  let instance_id = "cold-instance" and request_id = "cold" in
  let terminal, _, outcome, bytes = sampling_retry_case store ~instance_id ~request_id "verified answer" in
  sampling_require (Store.save_sampling_request store ~instance_id ~request_id terminal);
  let retry_dir = Filename.dirname (sampling_retry_path store instance_id request_id) in
  let saved = retry_dir ^ ".saved" in
  Unix.rename retry_dir saved; write retry_dir "unwritable retry namespace";
  Fun.protect ~finally:(fun () -> Unix.unlink retry_dir; Unix.rename saved retry_dir) (fun () ->
    let before = Yojson.Safe.to_string terminal in
    let result = Store.load_sampling_request_bounded ~budget:(Store.read_budget ~max_bytes:65536)
      store ~instance_id ~request_id in
    check bool "verified cold result remains available when optional compaction cannot mark" true
      (Result.is_ok result);
    check string "verified answer is retained" bytes (sampling_require (Store.read_blob store outcome));
    let primary = Filename.concat (Store.root store)
      ("sampling/" ^ Store.digest instance_id ^ "/" ^ Store.digest request_id ^ ".json") in
    check string "failed marker publication cannot mutate the journal" before (Fs_compat.load_file primary)))

let test_sampling_publication_requires_readable_address () = with_fixture (fun _ _ dir _ ->
  let module Store = Masc.Lane_addon_store in
  let store = Store.create ~root:(Filename.concat dir "publication-address") in
  let require = function Ok value -> value | Error detail -> fail detail in
  ignore (require (Store.write_blob store "retained request"));
  let canonical_directory = Filename.concat (Store.root store) "evidence" in
  let saved = canonical_directory ^ ".saved" in
  Unix.rename canonical_directory saved;
  write canonical_directory "not a directory";
  Fun.protect ~finally:(fun () -> Unix.unlink canonical_directory; Unix.rename saved canonical_directory)
    (fun () ->
      let result = Store.write_sampling_blob store "known model outcome" in
      check bool "publication refuses an address whose canonical boundary prevents recovery reads" true
        (Result.is_error result)))

let test_sampling_publication_rejects_symlink_parent boundary () =
  with_fixture (fun _ _ dir _ ->
    let module Store = Masc.Lane_addon_store in
    let root = Filename.concat dir "publication-owned-root" in
    let external_dir = Filename.concat dir "external-directory" in
    Unix.mkdir external_dir 0o700;
    let bytes = "known outcome stays inside the owned store" in
    let digest_name = Store.digest bytes ^ ".json" in
    let link, external_blob = match boundary with
      | `Root -> root, Filename.concat external_dir ("evidence/" ^ digest_name)
      | `Canonical ->
          Unix.mkdir root 0o700;
          Filename.concat root "evidence", Filename.concat external_dir digest_name
      | `Recovery ->
          Unix.mkdir root 0o700;
          let evidence = Filename.concat root "evidence" in
          Unix.mkdir evidence 0o700;
          Unix.mkdir (Filename.concat evidence digest_name) 0o700;
          Filename.concat root "sampling-evidence", Filename.concat external_dir digest_name in
    Unix.symlink external_dir link;
    Fun.protect ~finally:(fun () -> Unix.unlink link) (fun () ->
      let result = Store.write_sampling_blob (Store.create ~root) bytes in
      check bool "publication never writes through an external parent" false
        (Sys.file_exists external_blob);
      check bool "publication refuses a symlinked ownership boundary" true
        (Result.is_error result)))

let test_sampling_fallback_rejects_external_links name link () =
  List.iter (fun blocked -> with_fixture (fun _ _ dir _ ->
    let module Store = Masc.Lane_addon_store in
    let store = Store.create ~root:(Filename.concat dir (name ^ "-recovery")) in
    let bytes = "matching external outcome" in
    let require = function Ok value -> value | Error detail -> fail detail in
    let reference = require (Store.write_blob store bytes) in
    let canonical = Filename.concat (Store.root store) ("evidence/" ^ Store.digest bytes ^ ".json") in
    Unix.unlink canonical;
    if blocked then Unix.mkdir canonical 0o700;
    let recovery = Filename.concat (Store.root store) "sampling-evidence" in
    Unix.mkdir recovery 0o700;
    let external_path = Filename.concat dir "external.json" in
    write external_path bytes;
    let recovery_path = Filename.concat recovery (Store.digest bytes ^ ".json") in
    link external_path recovery_path;
    Fun.protect ~finally:(fun () -> Unix.unlink recovery_path) (fun () ->
      check bool "ordinary read refuses external recovery inode" true
        (Result.is_error (Store.read_blob store reference));
      check bool "bounded read refuses external recovery inode" true
        (Result.is_error (Store.read_blob_bounded ~budget:(Store.read_budget ~max_bytes:4096) store reference)))))
    [false; true]

let test_sampling_bounded_root_loop_is_error () = with_fixture (fun _ _ dir _ ->
  let module Store = Masc.Lane_addon_store in
  let link = Filename.concat dir "bounded-root-loop" in
  Unix.symlink "bounded-root-loop" link;
  Fun.protect ~finally:(fun () -> Unix.unlink link) (fun () ->
    let store = Store.create ~root:(Filename.concat link "retained") in
    match Store.load_sampling_request_bounded ~budget:(Store.read_budget ~max_bytes:4096)
        store ~instance_id:"loop-instance" ~request_id:"loop-request" with
    | Error (Store.Read_failed _) -> ()
    | Error Store.Read_limit_exceeded | Ok _ -> fail "root loop must return a bounded read error"))

let () = run "Lane Add-on worker" [ "lifecycle", [
  test_case "bounded sampling root loop returns error" `Quick test_sampling_bounded_root_loop_is_error;
  test_case "cold read preserves optional marked compaction" `Quick test_sampling_cold_read_keeps_optional_compaction;
  test_case "pending discovery resumes after namespace repair" `Quick test_sampling_pending_discovery_resumes_after_namespace_repair;
  test_case "pending recovery sees two Stores and concurrent writer" `Quick test_sampling_retry_two_stores_and_concurrent_writer;
  test_case "pending recovery handles crash and failed write orphans" `Quick test_sampling_retry_crash_and_failed_write_orphans;
  test_case "pending recovery preserves other namespace and unread records" `Quick test_sampling_retry_preserves_other_namespace_and_unread_records;
  test_case "pending discovery separates record and enumeration errors" `Quick test_sampling_discovery_separates_record_error_and_enumeration;
  test_case "sampling publication rejects canonical parent symlink" `Quick
    (test_sampling_publication_rejects_symlink_parent `Canonical);
  test_case "sampling publication rejects recovery parent symlink" `Quick
    (test_sampling_publication_rejects_symlink_parent `Recovery);
  test_case "sampling publication rejects root symlink" `Quick
    (test_sampling_publication_rejects_symlink_parent `Root);
  test_case "sampling publication requires readable address" `Quick test_sampling_publication_requires_readable_address;
  test_case "sampling fallback rejects external symlinks" `Quick
    (test_sampling_fallback_rejects_external_links "symlink" (fun target path -> Unix.symlink target path));
  test_case "sampling fallback rejects external hardlinks" `Quick
    (test_sampling_fallback_rejects_external_links "hardlink" (fun target path -> Unix.link target path));
  test_case "sampling reads preserve canonical failures" `Quick test_sampling_blob_read_preserves_canonical_failure;
  test_case "sampling retention error uses encoded wire bound" `Quick test_sampling_retention_error_uses_encoded_reply_bound;
  test_case "sampling blob failure keeps request evidence" `Quick test_sampling_blob_failure_keeps_request_evidence;
  test_case "sampling recovery reports unreadable terminal journal" `Quick test_sampling_recovery_reports_unreadable_terminal_journal;
  test_case "sampling receipt requires durable journal" `Quick test_sampling_receipt_requires_durable_journal;
  test_case "receipt projection reads shared outcome once" `Quick test_receipt_projection_reads_shared_outcome_once;
  test_case "sampling terminal recovery and host redaction" `Quick test_sampling_terminal_recovery_and_host_redaction;
  test_case "sampling reply bound and ancestor durability" `Quick test_sampling_response_bound_and_directory_durability;
  test_case "sampling bounds actual wire frames" `Quick test_sampling_wire_frame_envelope;
  test_case "sampling refuses nonfinite retained evidence" `Quick test_sampling_refuses_nonfinite_evidence;
  test_case "sampling recovery reports unreadable pending index" `Quick test_sampling_recovery_reports_unreadable_pending_index;
  test_case "pending sampling recovery syncs reopened root" `Quick test_pending_sampling_recovery_syncs_reopened_root;
  test_case "sampling recovery rejects replaced root and parent" `Quick test_sampling_recovery_rejects_replaced_root_parent;
  test_case "sampling recovery streams bounded records" `Quick test_sampling_recovery_streams_bounded_records;
  test_case "known sampling outcomes survive cancellation" `Quick test_known_sampling_outcome_survives_cancellation;
  test_case "declared sampling requires the exact host callback" `Quick test_declared_sampling_requires_exact_host_callback;
  test_case "image preview is read only and preserves engine failures" `Quick test_image_preview_does_not_create_worker;
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
  test_case "recovery bounds an unresponsive Docker control command" `Quick test_recovery_control_command_times_out;
  test_case "lost create response preserves unrelated containers" `Quick test_failed_create_receipt_cleans_only_owned_container;
  test_case "created identity precedes blocked inspect" `Quick test_created_identity_precedes_blocked_inspection;
]]
