"""Download and verify the exact output of linux-x64-probe.yml, without building."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

BINARIES = {"main_eio.exe", "masc_tui.exe", "masc_browser_host.exe",
            "deployment_preflight_helper.exe"}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(root, *, source, run_id, artifact_id, repository_id):
    meta = json.loads((root / "artifact.json").read_text())
    run = json.loads((root / "run.json").read_text())
    require(re.fullmatch(r"[0-9a-f]{40}", source), "expected full source SHA")
    require(run["id"] == run_id and run["head_sha"] == source, "run/source mismatch")
    require(run["status"] == "completed" and run["conclusion"] == "success",
            "probe build has not succeeded")
    require(run["repository"]["id"] == repository_id, "run repository mismatch")
    require(run["path"] == ".github/workflows/linux-x64-probe.yml"
            and run["event"] == "workflow_dispatch", "unexpected build workflow")
    origin = meta["workflow_run"]
    require(origin["id"] == run_id and origin["head_sha"] == source
            and origin["repository_id"] == origin["head_repository_id"] == repository_id,
            "artifact source mismatch")
    require(meta["id"] == artifact_id and meta["expired"] is False,
            "artifact ID or expiry mismatch")
    require(meta["name"] == f"linux-x64-probe-{source}-attempt-{run['run_attempt']}",
            "artifact name/attempt mismatch")
    archive = root / "artifact.zip"
    require(archive.stat().st_size == meta["size_in_bytes"]
            and "sha256:" + digest(archive) == meta["digest"], "ZIP digest/size mismatch")
    with zipfile.ZipFile(archive) as zipped:
        members = zipped.infolist()
        require(len(members) == 5 and {x.filename for x in members} == BINARIES | {"SHA256SUMS"},
                "unexpected or duplicate ZIP member")
        require(all(not x.is_dir() and (x.external_attr >> 16) & 0o170000 != 0o120000
                    for x in members), "ZIP contains a directory or symlink")
        sums = {}
        for line in zipped.read("SHA256SUMS").decode("ascii").splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  ([a-z_]+\.exe)", line)
            require(match is not None, "invalid SHA256SUMS row")
            value, name = match.groups()
            require(name in BINARIES and name not in sums, "duplicate/unknown checksum")
            sums[name] = value
        require(set(sums) == BINARIES, "incomplete SHA256SUMS")
        for name in sorted(BINARIES):
            content = zipped.read(name)
            require(hashlib.sha256(content).hexdigest() == sums[name], "binary digest mismatch: " + name)
            require(content[:6] == b"\x7fELF\x02\x01" and content[18:20] == b"\x3e\x00",
                    "not an ELF64 little-endian x86-64 binary: " + name)
            target = root / name
            require(not target.is_symlink(), "output is a symlink")
            target.write_bytes(content)
            target.chmod(0o700)
        (root / "SHA256SUMS").write_bytes(zipped.read("SHA256SUMS"))
    identity = {"source": source, "artifact": meta, "run_id": run_id,
                "sha256": sums, "build_workflow": run["path"],
                "scope": "CI probe output; not release, deployment or performance acceptance"}
    (root / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
    return identity


def fetch(root, *, repository, repository_id, source, run_id, artifact_id):
    root.mkdir(parents=True, exist_ok=False)
    for name, suffix in [("artifact.json", f"artifacts/{artifact_id}"),
                         ("run.json", f"runs/{run_id}")]:
        (root / name).write_bytes(subprocess.check_output(
            ["gh", "api", f"repos/{repository}/actions/{suffix}"]))
    with (root / "artifact.zip").open("wb") as output:
        subprocess.run(["gh", "api", f"repos/{repository}/actions/artifacts/{artifact_id}/zip"],
                       stdout=output, check=True)
    return verify(root, source=source, run_id=run_id, artifact_id=artifact_id,
                  repository_id=repository_id)
