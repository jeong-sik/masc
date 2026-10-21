let source = {|import atexit, csv, fcntl, hashlib, json, os, pathlib, sys, time
root = pathlib.Path(__file__).parent
# Concurrent invocations (worker fibers run docker peers in parallel) read,
# modify and write one shared state file. Serialize that critical section with
# a lock held until exit, except while an invocation deliberately blocks
# waiting for a release file, and publish the state file atomically.
lock_fd = os.open(str(root / "daemon.lock"), os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(lock_fd, fcntl.LOCK_EX)
def transport_event(kind):
    with (root / "transport-events.jsonl").open("a") as output:
        output.write(json.dumps({"event": kind, "argv": sys.argv[1:]}) + "\n")
transport_event("entered")
atexit.register(transport_event, "exiting")
state_path = root / "daemon.json"
control_path = root / "control.json"
state = json.loads(state_path.read_text()) if state_path.exists() else {"calls": [], "containers": {}, "original_ids": {}}
control = json.loads(control_path.read_text()) if control_path.exists() else {"shared": {}, "jobs": {}, "armed": []}
assert set(state) == {"calls", "containers", "original_ids"}
assert set(control) == {"shared", "jobs", "armed"}
shared_control = control["shared"]
for entry in control["armed"]:
    assert set(entry) == {"base_path", "keeper_name", "source", "request_sha256", "fault"}
    assert set(entry["source"]) == {"task_id", "turn_ref", "tool_use_id", "trace_id", "keeper_turn_id"}
    assert all(entry["source"][key] is not None for key in ("turn_ref", "tool_use_id", "trace_id"))
argv = sys.argv[1:]
state["calls"].append(argv)
def save():
    scratch = state_path.with_name("daemon.json.%d" % os.getpid())
    scratch.write_text(json.dumps(state))
    os.replace(scratch, state_path)
save()
args = list(argv)
while args and args[0] in ("--config", "--host"):
    del args[:2]
# Resource mutations name the original job, never every retained container.
for job_id, fault in control["jobs"].items():
    container = state["containers"].get(job_id)
    if container is None:
        continue
    if fault.get("state") == "exited":
        container["State"].update(Status="exited", Running=False, ExitCode=fault.get("exit_code", 0))
    if fault.get("state") == "running":
        container["State"].update(Status="running", Running=True, ExitCode=0)
    if fault.get("replacement"):
        container["Id"] = hashlib.sha256(("replacement:" + state["original_ids"][job_id]).encode()).hexdigest()
    if fault.get("restore_identity"):
        container["Id"] = state["original_ids"][job_id]
save()
def exact_container(container_id):
    matches = [(job_id, value) for job_id, value in state["containers"].items() if value["Id"] == container_id]
    assert len(matches) == 1, "exact container identity is absent or ambiguous"
    return matches[0]
def job_fault(job_id):
    return control["jobs"].get(job_id, {})
def bind_armed(job_id, record, binding):
    matches = [entry for entry in control["armed"] if
        entry["base_path"] == str(root) and entry["keeper_name"] == record["keeper_name"]
        and entry["source"] == record["source"] and entry["request_sha256"] == binding["request_sha256"]]
    assert len(matches) <= 1, "ambiguous armed original invocation"
    if matches:
        assert job_id not in control["jobs"], "resource has two fault authorities"
        entry = matches[0]
        control["jobs"][job_id] = entry["fault"]
        control["armed"].remove(entry)
        scratch = control_path.with_name("control.json.%d" % os.getpid())
        scratch.write_text(json.dumps(control))
        os.replace(scratch, control_path)
    return job_fault(job_id)
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
    matches = [value for value in bindings if value["job_id"] == job_id]
    assert len(matches) == 1
    binding = matches[0]
    assert binding["base_path"] == str(root) and binding["keeper_name"] == record["keeper_name"]
    assert binding["source"] == record["source"]
    request = {"argv": record["preparation"]["spec"]["argv"], "inputs": record["inputs"]}
    digest = hashlib.sha256(json.dumps(request, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    assert binding["request_sha256"] == digest
    if expected_container is not None:
        assert record["phase"]["container_id"] == expected_container
    return record, binding
image_id = "sha256:" + "b" * 64
if args == ["context", "show"]:
    print("owned-job-fixture")
elif args[:2] == ["context", "inspect"]:
    emit([{"Name": "owned-job-fixture", "Endpoints": {"docker": {"Host": "unix:///fixture/docker.sock"}}}])
elif args[:1] == ["info"]:
    emit({"ID": shared_control.get("daemon_id", "fixture-daemon"), "OSType": "linux", "SecurityOptions": ["name=rootless", "name=userns"]})
elif args[:2] == ["image", "inspect"]:
    emit([{"Id": image_id, "Os": "linux", "Config": {"Env": [], "Volumes": {"/tmp/keeper-creds": {}}}}])
elif args[:2] == ["container", "ls"]:
    projection = option("--format", args)
    shared = projection != "{{json .ID}}"
    if shared:
        cli = pathlib.Path(option("--config", argv))
        assert cli.is_dir() and not list(cli.iterdir())
        assert cli.stat().st_mode & 0o777 == 0o700
        if shared_control.get("presence_blocked"):
            (root / "presence-entered").write_text(str(cli))
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            while not (root / "presence-release").exists():
                time.sleep(0.01)
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
    if shared and shared_control.get("presence_unavailable"):
        print("synthetic shared presence transport failure", file=sys.stderr)
        sys.exit(26)
    for job_id, container in state["containers"].items():
        fault = job_fault(job_id)
        filters = many("--filter", args)
        assert all(value.startswith("label=") or value.startswith("id=") for value in filters)
        wanted = dict(value[len("label="):].split("=", 1) for value in filters if value.startswith("label="))
        exact_ids = [value[len("id="):] for value in filters if value.startswith("id=")]
        visible = not (wanted and fault.get("mode") == "hide_owner_inventory")
        if visible and all(container["Config"]["Labels"].get(key) == value for key, value in wanted.items()) and all(value == container["Id"] for value in exact_ids):
            if not shared:
                emit(container["Id"])
            else:
                labels = container["Config"]["Labels"]
                projected = {"container_id": container["Id"],
                    "component": labels["masc.mcp.component"],
                    "kind": labels["masc.mcp.kind"],
                    "base_path_hash": labels["masc.mcp.base_path_hash"],
                    "keeper_name": labels["masc.mcp.keeper"],
                    "job_id": labels["masc.mcp.owned_job"]}
                if shared_control.get("presence_wrong_scope"):
                    projected["base_path_hash"] = "other-workspace"
                padding = None
                padding_rows = 0
                if shared_control.get("presence_padding_bytes"):
                    padding = dict(projected, keeper_name="unrelated-owner", job_id="unrelated-original-job")
                    row_bytes = len(json.dumps(padding).encode()) + 1
                    padding_rows = (shared_control["presence_padding_bytes"] + row_bytes - 1) // row_bytes
                    for _ in range(padding_rows):
                        emit(padding)
                emit(projected)
                if padding:
                    for _ in range(padding_rows):
                        emit(padding)
elif args[:2] == ["container", "create"]:
    labels = dict(value.split("=", 1) for value in many("--label", args))
    job_id = labels["masc.mcp.owned_job"]
    record, binding = require_intent(job_id, "create_requested")
    fault = bind_armed(job_id, record, binding)
    if fault.get("mode") == "create_unknown_absent":
        print("synthetic create transport lost its receipt", file=sys.stderr)
        sys.exit(17)
    assert job_id not in state["original_ids"]
    name = "/" + option("--name", args)
    assert all(value["Name"] != name for value in state["containers"].values())
    container_id = hashlib.sha256(("owned-job:" + job_id + ":" + name).encode()).hexdigest()
    assert all(value["Id"] != container_id for value in state["containers"].values())
    state["original_ids"][job_id] = container_id
    tmpfs = dict(value.split(":", 1) for value in many("--tmpfs", args))
    mount = dict(value.split("=", 1) for value in next(csv.reader([option("--mount", args)])))
    image_index = args.index(image_id)
    memory = option("--memory", args)
    assert memory == "2g"
    limit = option("--ulimit", args).split("=", 1)[1].split(":")
    state["containers"][job_id] = {
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
    if fault.get("mode") == "create_unknown_created":
        print("synthetic create receipt lost after creation", file=sys.stderr)
        sys.exit(24)
    print(container_id)
elif args[:2] == ["container", "inspect"]:
    job_id, selected = exact_container(args[2])
    fault = job_fault(job_id)
    container = json.loads(json.dumps(selected))
    if fault.get("mode") == "inspect_blocked":
        (root / "inspect-entered").write_text(args[2])
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        while not (root / "inspect-release").exists():
            time.sleep(0.01)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
    if fault.get("corrupt") == "mount":
        container["Mounts"][0]["Source"] = "/different/unowned/workspace"
    elif fault.get("corrupt") == "label":
        container["Config"]["Labels"]["masc.mcp.owned_job"] = "different-job"
    emit([container])
elif args[:2] == ["container", "start"]:
    job_id, selected = exact_container(args[2])
    fault = job_fault(job_id)
    require_intent(job_id, "start_requested", args[2])
    if fault.get("mode") == "start_unknown_absent":
        del state["containers"][job_id]
        save()
        print("synthetic start transport lost its receipt", file=sys.stderr)
        sys.exit(18)
    selected["State"].update(Status="running", Running=True)
    save()
    if fault.get("mode") == "start_blocked":
        (root / "start-entered").write_text(args[2])
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        while True:
            time.sleep(1)
    print(args[2])
elif args[:2] == ["container", "rm"]:
    assert len(args) == 3
    job_id, container = exact_container(args[2])
    fault = job_fault(job_id)
    owner = root / ".masc" / "keeper_msg_requests" / "owned_jobs" / container["Config"]["Labels"]["masc.mcp.owned_job"] / "owner.jsonl"
    record = json.loads(owner.read_text().splitlines()[-1])
    assert record["cleanup"] == "container_removal_requested" and record["completion_delivered"] is True
    assert record["phase"]["kind"] in ("exited", "cancelled_before_start") and record["phase"]["container_id"] == args[2]
    assert container["State"]["Status"] in ("created", "exited") and container["State"]["Running"] is False
    del state["containers"][job_id]
    save()
    if fault.get("mode") == "remove_unknown_removed":
        print("synthetic removal transport lost its receipt", file=sys.stderr)
        sys.exit(23)
    print(args[2])
elif args[:2] == ["container", "kill"]:
    job_id, selected = exact_container(args[2])
    fault = job_fault(job_id)
    if fault.get("mode") == "kill_blocked":
        (root / "kill-entered").write_text(args[2])
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        while True:
            time.sleep(1)
    selected["State"].update(Status="exited", Running=False, ExitCode=137)
    save()
    print(args[2])
elif args[:2] == ["container", "logs"]:
    job_id, selected = exact_container(args[2])
    fault = job_fault(job_id)
    if fault.get("mode") == "logs_unknown":
        print("synthetic output transport refused", file=sys.stderr)
        sys.exit(19)
    if fault.get("large_logs"):
        sizes = fault["large_logs"]
        head, tail = sizes["head"], sizes["tail"]
        assert head > 0 and tail > 0
        for stream, output, fill, remainder in (("stdout", sys.stdout, "O", "o"), ("stderr", sys.stderr, "E", "e")):
            output.write(stream + " beginning\n")
            output.write(fill * (head + tail))
            output.write(stream.upper() + "_DEEP_MIDDLE\n")
            output.write(remainder * tail)
            output.write(stream.upper() + "_TERMINAL\n")
    elif selected["Id"] == state["original_ids"][job_id]:
        sys.stdout.write("original job stdout\n")
        sys.stderr.write("original job stderr\n")
    else:
        sys.stdout.write("replacement job stdout\n")
        sys.stderr.write("replacement job stderr\n")
else:
    raise AssertionError("unsupported fixture Docker argv: "+repr(args))
|}
