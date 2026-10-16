let source = {|import atexit, csv, hashlib, json, pathlib, sys, time
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
if control.get("state") == "running" and state["container"]:
    state["container"]["State"].update(Status="running", Running=True, ExitCode=0)
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
        assert all(value.startswith("label=") or value.startswith("id=") for value in filters)
        wanted = dict(value[len("label="):].split("=", 1) for value in filters if value.startswith("label="))
        exact_ids = [value[len("id="):] for value in filters if value.startswith("id=")]
        visible = not (wanted and control.get("mode") == "hide_owner_inventory")
        if visible and all(container["Config"]["Labels"].get(key) == value for key, value in wanted.items()) and all(value == container["Id"] for value in exact_ids):
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
    if control.get("mode") == "create_unknown_created":
        print("synthetic create receipt lost after creation", file=sys.stderr)
        sys.exit(24)
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
elif args[:2] == ["container", "rm"]:
    assert len(args) == 3 and state["container"] is not None and args[2] == state["container"]["Id"]
    container = state["container"]
    owner = root / ".masc" / "keeper_msg_requests" / "owned_jobs" / container["Config"]["Labels"]["masc.mcp.owned_job"] / "owner.jsonl"
    record = json.loads(owner.read_text().splitlines()[-1])
    assert record["cleanup"] == "container_removal_requested" and record["completion_delivered"] is True
    assert record["phase"]["kind"] in ("exited", "cancelled_before_start") and record["phase"]["container_id"] == args[2]
    assert container["State"]["Status"] in ("created", "exited") and container["State"]["Running"] is False
    state["container"] = None
    save()
    if control.get("mode") == "remove_unknown_removed":
        print("synthetic removal transport lost its receipt", file=sys.stderr)
        sys.exit(23)
    print(args[2])
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
