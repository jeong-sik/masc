"""CI-only real Docker Observe transport acceptance; no production containers."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid
import zlib

def run(argv, **kwargs):
    result = subprocess.run(argv, text=True, capture_output=True, **kwargs)
    if result.returncode:
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        result.check_returncode()
    return result

def main():
    driver = Path(sys.argv[1]).resolve()
    repo = Path(os.environ["DUNE_SOURCEROOT"]).resolve()
    name = "masc-observe-test-" + uuid.uuid4().hex
    image = name + ":fixture"
    with tempfile.TemporaryDirectory(prefix="masc-docker-observe-") as temporary:
        root = Path(temporary)
        work = root / "work"
        work.mkdir()
        base = root / "base"
        base.mkdir()
        shim = root / "masc-exec-shim"
        # Always build the exact checked-out shim source in CI; no mtime reuse.
        build = run([str(repo / "scripts/build-shim-static.sh"), str(shim)], cwd=repo)
        (root / "shim-build.log").write_text(build.stdout + build.stderr)
        fixture = root / "image"
        fixture.mkdir()
        (fixture / "Dockerfile").write_text(
            "FROM alpine:3.21\n"
            "RUN apk add --no-cache git ripgrep file coreutils\n")
        run(["docker", "build", "--quiet", "--tag", image, str(fixture)])
        config = root / "shim.conf"
        config.write_text("remote_root=/workspace\npath=/usr/local/bin:/usr/bin:/bin\nenv_allowlist=\n")
        (work / "sentinel.txt").write_text("keep\n")
        (work / "probe.magic").write_text("0 string hello sample\n")
        helper = work / "fsmonitor"
        helper.write_text("#!/bin/sh\nprintf 'MASC_FSMONITOR_PROBE\\n' >&2\n"
                          "printf changed > /workspace/sentinel.txt\n"
                          "printf '2\\n/\\n'\n")
        helper.chmod(0o755)
        run(["git", "-c", "init.templateDir=", "init", "-q", str(work)])
        run(["git", "-C", str(work), "add", "sentinel.txt"])
        run(["git", "-C", str(work), "config", "core.fsmonitor", "/workspace/fsmonitor"])
        before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in work.iterdir() if p.is_file()}
        common = ["docker", "run", "-d", "--read-only", "--cap-drop=ALL",
                  "--security-opt", "no-new-privileges", "--network", "none",
                  "--user", f"{os.getuid()}:{os.getgid()}", "--tmpfs", "/tmp:rw,nosuid,nodev",
                  "--volume", f"{work}:/workspace:rw",
                  "--volume", f"{config}:/etc/masc-exec-shim.conf:ro",
                  "--workdir", "/workspace"]
        started = []
        try:
            run(common + ["--name", name, "--volume",
                          f"{shim}:/usr/local/bin/masc-exec-shim:ro", image, "tail", "-f", "/dev/null"])
            started.append(name)
            # Prove this exact container and uid can write through the mount.
            # Otherwise a permissions failure could masquerade as Observe.
            baseline_git = run(["docker", "exec", name, "git", "status", "--porcelain"])
            assert "MASC_FSMONITOR_PROBE" in baseline_git.stderr
            assert (work / "sentinel.txt").read_text() == "changed"
            (work / "sentinel.txt").write_text("keep\n")
            run(["docker", "exec", name, "file", "-C", "-m", "probe.magic"])
            generated = [p for p in work.iterdir() if p.is_file() and p.name not in before]
            assert generated, "unboxed file compilation produced no output"
            baseline_outputs = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in generated}
            for output in generated:
                output.unlink()
            assert {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in work.iterdir() if p.is_file()} == before
            missing = name + "-missing-shim"
            run(common + ["--name", missing, image, "tail", "-f", "/dev/null"])
            started.append(missing)
            receipts = root / "receipts.json"
            result = run([str(driver), str(base), name, missing, str(receipts)])
            print(result.stdout, end="")
            print(result.stderr, end="", file=sys.stderr)
            after = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in work.iterdir() if p.is_file()}
            assert before == after, {"before": before, "after": after}
            assert not (work / "magic.mgc").exists()
            assert not (work / "probe.magic.mgc").exists()
            proof = {
                "schema": "masc.docker_observe_transport_evidence.v1",
                "source_commit": run(["git", "rev-parse", "HEAD"], cwd=repo).stdout.strip(),
                "driver_sha256": hashlib.sha256(driver.read_bytes()).hexdigest(),
                "shim_sha256": hashlib.sha256(shim.read_bytes()).hexdigest(),
                "container_image_id": run(["docker", "image", "inspect", "--format", "{{.Id}}", image]).stdout.strip(),
                "scenarios": json.loads(receipts.read_text()),
                "unboxed_baseline": {"fsmonitor_wrote_sentinel": True,
                                     "compiled_outputs": baseline_outputs},
                "host_files_before": before, "host_files_after": after,
                "scope": "Explicit Docker framed Observe transport and Gate result reuse; persistent Keeper runtime target not wired by this PR.",
            }
            body = json.dumps(proof, ensure_ascii=False, sort_keys=True).encode()
            print("MASC_DOCKER_OBSERVE_RECEIPT " + json.dumps({
                "sha256": hashlib.sha256(body).hexdigest(),
                "zlib_base64": base64.b64encode(zlib.compress(body)).decode()}))
        finally:
            for container in started:
                subprocess.run(["docker", "rm", "-f", container], check=False, capture_output=True)
            subprocess.run(["docker", "image", "rm", image], check=False, capture_output=True)

if __name__ == "__main__":
    main()
