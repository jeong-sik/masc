"""Explicit local Docker package qualification; model and port metadata are fixtures.

Does not build native MASC, install declarations, publish or call a provider.
Images must already exist; container limits come from checked-in manifests.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import tomllib
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "addons/tests"))
from test_fusion_compute import Host, call, source
from test_fusion_report import upstream
from stdio_fixture import run_stdio


def validate_plan(plan):
    if not isinstance(plan, dict) or not isinstance(plan.get("run_id"), str) or not plan["run_id"].strip():
        raise ValueError("Qualification requires a nonempty run_id")
    declarations = plan.get("declarations")
    if not isinstance(declarations, list) or not declarations:
        raise ValueError("Qualification requires panel, judge and report declarations")
    completed_roles = {}
    for declaration in declarations:
        name = declaration["installation_id"]
        if not isinstance(name, str) or not name or name in (".", "..") or any(c in name for c in ("/", "\\", "\0")):
            raise ValueError("Installation IDs must be safe individual output filenames")
        if name in completed_roles:
            raise ValueError("Qualification installation IDs must be unique")
        binding = declaration["binding"]
        role = binding.get("role")
        if role not in (None, "panel", "judge"):
            raise ValueError("Unsupported computation role")
        sources = binding.get("sources")
        if not isinstance(sources, list) or not sources:
            raise ValueError("Every qualified worker requires declared input sources")
        upstream_roles = set()
        for declared_source in sources:
            if declared_source["kind"] == "snapshot_file":
                if role != "panel":
                    raise ValueError("Judges and reports require upstream worker results")
            elif declared_source["kind"] == "lane_output":
                producer = declared_source["installation_id"]
                if role == "panel" or producer not in completed_roles or declared_source["output_id"] != "result":
                    raise ValueError("Qualification sources must reference earlier worker results")
                upstream_roles.add(completed_roles[producer])
            else:
                raise ValueError("Unsupported qualification source kind")
        if role == "judge" and not upstream_roles.intersection({"panel", "judge"}):
            raise ValueError("A qualified judge must consume computation results")
        if role is None and "judge" not in upstream_roles:
            raise ValueError("A qualified report must consume a judge result")
        completed_roles[name] = role
    if set(completed_roles.values()) != {"panel", "judge", None}:
        raise ValueError("Qualification requires panel, judge and report declarations")
    return completed_roles


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--compute-image", required=True)
    parser.add_argument("--report-image", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    output = Path(args.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    plan = json.loads(Path(args.plan).read_text())
    expected_roles = validate_plan(plan)
    docker = shutil.which("docker")
    assert docker, "Docker CLI is required"

    context = subprocess.check_output([docker, "context", "show"], text=True, timeout=30).strip()
    cli = [docker, "--context", context]

    def command(*parts):
        return subprocess.check_output([*cli, *parts], text=True, timeout=30).strip()

    owner = str(uuid.uuid4())
    containers, completed, calls, model_references, prepared = [], {}, [], [], []
    images = {"fusion-compute": args.compute_image, "fusion-report": args.report_image}
    image_info = {package: json.loads(command("image", "inspect", image))[0]
                  for package, image in images.items()}
    summary = {"scope": "Real Docker package stdio with fixture model responses and native-shaped port metadata",
               "native_masc_runtime": False, "native_port_resolution": False,
               "live_provider": False, "broadcast": False, "keeper_read": False,
               "native_parallel_scheduling": False, "status": "running", "docker_context": context,
               "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
               "containers": [], "cleanup_errors": []}
    try:
        for index, declaration in enumerate(plan["declarations"]):
            binding = declaration["binding"]
            role = binding.get("role")
            assert role in (None, "panel", "judge"), "Unsupported computation role"
            package = "fusion-report" if role is None else "fusion-compute"
            manifest = tomllib.loads((ROOT / "addons" / package / "lane.toml").read_text())
            resources = manifest["resources"]
            name = "masc-package-proof-" + owner + "-" + str(index)
            containers.append(name)  # Recover this exact owned name if create's response is lost.
            identity = command("container", "create", "-i", "--pull", "never", "--name", name,
                "--label", "masc.proof.owner=" + owner,
                "--network", "none", "--read-only", "--cap-drop", "ALL",
                "--security-opt", "no-new-privileges", "--log-driver", "none",
                "--cpus", str(resources["cpus"]), "--memory", str(resources["memory_bytes"]),
                "--memory-swap", str(resources["memory_bytes"]), "--pids-limit", str(resources["pids"]),
                image_info[package]["Id"], *manifest["command"])
            inspected = json.loads(command("container", "inspect", identity))[0]
            config, host = inspected["Config"], inspected["HostConfig"]
            assert config["Labels"]["masc.proof.owner"] == owner
            assert host["NetworkMode"] == "none" and host["ReadonlyRootfs"]
            assert not host["Privileged"]
            assert host["CapDrop"] == ["ALL"] and "no-new-privileges" in host["SecurityOpt"]
            assert config["User"] == "65534:65534" and not inspected["Mounts"]
            assert config["Env"] == image_info[package]["Config"]["Env"]
            assert host["Memory"] == resources["memory_bytes"] and host["PidsLimit"] == resources["pids"]
            assert host["NanoCpus"] == int(resources["cpus"] * 1_000_000_000)
            hashes = {}
            image_sources = [("/protocol.py", ROOT / "addons/protocol.py"),
                             ("/fusion_sampling.py", ROOT / "addons/fusion_sampling.py"),
                             ("/addon/server.py", ROOT / "addons" / package / "server.py"),
                             ("/addon/lane.toml", ROOT / "addons" / package / "lane.toml")]
            for image_path, checked_in in image_sources:
                captured = output / (declaration["installation_id"] + "-" + checked_in.name)
                command("container", "cp", identity + ":" + image_path, str(captured))
                digest = hashlib.sha256(captured.read_bytes()).hexdigest()
                assert digest == hashlib.sha256(checked_in.read_bytes()).hexdigest()
                hashes[image_path] = digest
            record = {"installation_id": declaration["installation_id"], "container_id": identity,
                      "image_id": inspected["Image"], "package": package, "source_sha256": hashes,
                      "isolation": {"network": "none", "read_only": True, "capabilities_dropped": "ALL",
                                    "no_new_privileges": True, "user": config["User"], "mounts": [],
                                    "environment_matches_image": True, "resources_match_manifest": True}}
            summary["containers"].append(record)
            prepared.append((declaration, binding, role, identity, record))

        def execute(item, host_type=Host):
            declaration, binding, role, identity, record = item
            inputs = []
            for declared in binding["sources"]:
                if declared["kind"] == "snapshot_file":
                    captured = source()
                    captured["source_id"] = declared["source_id"]
                else:
                    assert declared["kind"] == "lane_output" and declared["output_id"] == "result"
                    producer, previous = completed[declared["installation_id"]]
                    captured = upstream(previous, installation_id=declared["installation_id"], instance_id=producer)
                    captured["source_id"] = declared["source_id"]
                    captured["observations"][0]["producer"].update(run_id=plan["run_id"], output_id="result")
                inputs.append(captured)
            transport = cli + ["container", "start", "-a", "-i", identity]
            if role is not None:
                host_fixture = host_type(output, text="Fixture " + role + " answer from " + declaration["installation_id"],
                                    instance_id=identity)
                result = call(host_fixture, inputs, binding, command=transport,
                              command_env={"HOME": str(Path.home()), "PATH": os.environ.get("PATH", "/usr/bin:/bin")},
                              transport_timeout=30)
                assert len(host_fixture.calls) == 1
                assert host_fixture.calls[0]["params"]["maxTokens"] == binding["max_tokens"]
                calls.extend(host_fixture.calls)
                assert not result["isError"]
                references = result["structuredContent"]["rows"][0]["fields"]["model_evidence"]
                for reference in references.values():
                    retained = output / (reference["sha256"] + ".json")
                    assert hashlib.sha256(retained.read_bytes()).hexdigest() == reference["sha256"]
                    model_references.append(reference)
            else:
                requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize"},
                            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                             "params": {"name": "lane_observe", "arguments": {"binding": binding, "sources": inputs}}}]
                process = run_stdio(transport, input="".join(json.dumps(request) + "\n" for request in requests))
                assert not process.stderr
                result = json.loads(process.stdout.splitlines()[-1])["result"]
                report_rows = [row for row in result["structuredContent"]["rows"] if row["lane_id"] == "fusion/report"]
                assert len(report_rows) == 1
                report_row = report_rows[0]
                contexts = [row for row in result["structuredContent"]["rows"] if row["id"] in report_row["related_ids"]]
                assert len(contexts) == 1 and contexts[0]["lane_id"] == "fusion/report-context"
                assert "Fixture judge answer" in report_row["fields"]["body"]
                assert report_row["fields"]["delivery_status"] == "not_attempted"
                assert all(reference in contexts[0]["evidence"] or reference in report_row["evidence"] for reference in model_references)
            assert not result["isError"]
            state = json.loads(command("container", "inspect", identity))[0]["State"]
            assert state["Status"] == "exited" and state["ExitCode"] == 0
            record["exit_code"] = state["ExitCode"]
            completed[declaration["installation_id"]] = identity, result["structuredContent"]
            (output / (declaration["installation_id"] + "-output.json")).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")

        panel_items = [item for item in prepared if item[2] == "panel"]
        if len(panel_items) > 1:
            assert all(source["kind"] == "snapshot_file" for item in panel_items for source in item[1]["sources"])
            arrived = threading.Barrier(len(panel_items), timeout=30)
            release = threading.Barrier(len(panel_items), timeout=30)
            waiting_requests = {}

            class ParallelPanelHost(Host):
                def answer(self, request):
                    waiting_requests[self.instance_id] = request
                    leader = arrived.wait()
                    if leader == 0:
                        waiting = []
                        for item in panel_items:
                            inspected = json.loads(command("container", "inspect", item[3]))[0]
                            assert inspected["State"]["Running"]
                            assert inspected["Config"]["Labels"]["masc.proof.owner"] == owner
                            waiting.append({"installation_id": item[0]["installation_id"],
                                            "container_id": item[3], "running": True,
                                            "sampling_request": waiting_requests[item[3]]})
                        summary["parallel_panels_waiting_before_responses"] = waiting
                    release.wait()
                    return super().answer(request)

            with ThreadPoolExecutor(max_workers=len(panel_items)) as pool:
                futures = [pool.submit(execute, item, ParallelPanelHost) for item in panel_items]
                for future in futures:
                    future.result()
            summary["package_parallel_sampling"] = True
        else:
            for item in panel_items:
                execute(item)
            summary["package_parallel_sampling"] = False
        for item in prepared:
            if item[2] != "panel":
                execute(item)
        if set(completed) != set(expected_roles):
            raise AssertionError("Not every declared worker produced a retained result")
        if len(calls) != sum(role is not None for role in expected_roles.values()):
            raise AssertionError("Missing panel or judge sampling observation")
        summary["sampling_calls"] = len(calls)
        summary["model_references_retained_and_carried_to_report"] = model_references
        summary["status"] = "passed"
    except Exception as error:
        summary["status"] = "failed"
        summary["error"] = str(error)
        raise
    finally:
        for name in containers:
            try:
                inspected = json.loads(command("container", "inspect", name))[0]
                assert inspected["Config"]["Labels"].get("masc.proof.owner") == owner, "Cleanup owner mismatch"
                command("container", "rm", "-f", inspected["Id"])
            except Exception as error:
                summary["cleanup_errors"].append(str(error))
        if summary["cleanup_errors"]:
            summary["status"] = "failed"
        (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    assert not summary["cleanup_errors"], summary["cleanup_errors"]
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
