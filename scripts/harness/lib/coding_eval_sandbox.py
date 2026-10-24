#!/usr/bin/env python3
"""Grade a Docker coding candidate without executing its files on the host.

The coding harness currently creates Docker Keepers only. A future microVM or
SSH harness must supply its own isolated grading runner; copying its output to
the host and invoking a verifier there does not preserve that backend's boundary.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tempfile


class InputRefused(Exception):
    pass


def relative_path(value):
    if not isinstance(value, str) or not value:
        raise InputRefused("expected a nonempty relative input path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in (".", "..") for part in value.split("/")):
        raise InputRefused("input path must stay under its declared root: " + value)
    return path


def copy_regular(source, destination, *, source_dir=None):
    """Capture bytes through a no-follow fd, refusing a changed source."""
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source_dir)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise InputRefused("grading input is not a regular file: " + str(source))
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read()
        after = os.fstat(fd)
        if (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ):
            raise InputRefused("grading input changed while captured: " + str(source))
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.unlink(missing_ok=True)
        destination.write_bytes(data)
        destination.chmod(0o444)
    finally:
        os.close(fd)


def copy_tree(source, destination, *, source_dir=None):
    """Only regular files/directories enter this corpus's grading snapshot.

    In particular an agent-created symlink must never redirect a host-side
    oracle restoration. Unsupported file kinds are a failed capture, not a
    partially copied candidate that could be graded as successful.
    """
    fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=source_dir)
    try:
        before = os.fstat(fd)
        destination.mkdir(parents=True, exist_ok=True)
        for name in sorted(os.listdir(fd)):
            mode = os.stat(name, dir_fd=fd, follow_symlinks=False).st_mode
            if stat.S_ISDIR(mode):
                copy_tree(name, destination / name, source_dir=fd)
            elif stat.S_ISREG(mode):
                copy_regular(name, destination / name, source_dir=fd)
            else:
                raise InputRefused("grading input file kind refused: " + name)
        after = os.fstat(fd)
        if (before.st_mtime_ns, before.st_ctime_ns) != (after.st_mtime_ns, after.st_ctime_ns):
            raise InputRefused("grading input directory changed during capture")
    finally:
        os.close(fd)


def protected_files(case):
    values = case.get("test_files", ["check.sh"])
    if not isinstance(values, list) or not values:
        raise InputRefused("case must declare a nonempty protected test list")
    paths = [relative_path(value) for value in values]
    if len(set(paths)) != len(paths):
        raise InputRefused("duplicate protected test path")
    return paths


def prepare_snapshot(case_dir, workspace, snapshot):
    case = json.loads((case_dir / "case.json").read_text())
    copy_tree(workspace, snapshot / "workspace")
    # Scripts and their support files are trusted corpus inputs. The reference
    # solution is deliberately absent from the grader's input surface.
    (snapshot / "case").mkdir()
    for entry in sorted(case_dir.iterdir()):
        if entry.name in ("workspace", "solution"):
            continue
        if stat.S_ISDIR(entry.lstat().st_mode):
            copy_tree(entry, snapshot / "case" / entry.name)
        else:
            copy_regular(entry, snapshot / "case" / entry.name)
    for relative in protected_files(case):
        source = case_dir / "workspace" / relative
        destination = snapshot / "workspace" / relative
        # Every destination ancestor was created by copy_tree, which refuses
        # links. Replacement happens only in our private snapshot.
        copy_regular(source, destination)
    for directory, _, _ in os.walk(snapshot):
        Path(directory).chmod(0o555)
    return case


def snapshot_identity(snapshot):
    rows = []
    for path in sorted(snapshot.rglob("*")):
        if path.is_file():
            data = path.read_bytes()
            rows.append({"path": str(path.relative_to(snapshot)), "bytes": len(data),
                         "sha256": hashlib.sha256(data).hexdigest()})
    encoded = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
    return {"sha256": hashlib.sha256(encoded).hexdigest(), "files": rows}


def write_receipt(path, value):
    fd, name = tempfile.mkstemp(prefix=".grading-receipt-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(json.dumps(value, sort_keys=True) + "\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def validate_image(image):
    if not image.startswith("sha256:") or len(image) != 71 or any(
        character not in "0123456789abcdef" for character in image[7:]
    ):
        raise InputRefused("grader image must be a captured Docker image id")


def grade_snapshot(snapshot, case, image, stage, captured_inputs, *, receipt=None, log=None):
    script = relative_path(case[stage])
    if not (snapshot / "case" / script).is_file():
        raise InputRefused("declared grading script is absent")
    argv = [
        "docker", "run", "--rm", "--network", "none", "--read-only",
        "--cap-drop=ALL", "--security-opt", "no-new-privileges",
        "--user", "65534:65534", "--tmpfs", "/work:rw,exec,nosuid,mode=1777",
        "--tmpfs", "/tmp:rw,nosuid,mode=1777",
        "--mount", "type=bind,src=" + str(snapshot) + ",dst=/input,readonly",
        "--workdir", "/work", "--env", "HOME=/tmp",
        "--env", "PYTHONDONTWRITEBYTECODE=1", "--entrypoint", "/bin/bash",
        image, "-c",
        'set -euo pipefail; cp -R /input/workspace /work/workspace; '
        'chmod -R u+w /work/workspace; exec bash "$1" /work/workspace',
        "coding-eval-grader", "/input/case/" + str(script),
    ]
    result = subprocess.run(argv, check=False, stdout=log, stderr=subprocess.STDOUT if log else None)
    if receipt is not None:
        write_receipt(receipt, {
            "schema": "masc.coding_eval.grading.v1", "sandbox_profile": "docker",
            "image_id": image, "stage": stage, "exit_code": result.returncode,
            "inputs": captured_inputs,
            "isolation": {"network": "none", "user": "65534:65534",
                          "rootfs": "read_only", "input_mount": "read_only",
                          "host_credentials": "not_forwarded"},
        })
    return result.returncode


def grade(case_dir, workspace, image, stage, *, receipt=None):
    validate_image(image)
    with tempfile.TemporaryDirectory(prefix="masc-coding-grade-") as temporary:
        snapshot = Path(temporary)
        case = prepare_snapshot(case_dir, workspace, snapshot)
        return grade_snapshot(snapshot, case, image, stage, snapshot_identity(snapshot), receipt=receipt)


def grade_stages(case_dir, workspace, image, output):
    """All declared stages judge one captured candidate in fresh containers."""
    validate_image(image)
    with tempfile.TemporaryDirectory(prefix="masc-coding-grade-") as temporary:
        snapshot = Path(temporary)
        case = prepare_snapshot(case_dir, workspace, snapshot)
        captured_inputs = snapshot_identity(snapshot)
        exits = {"verify": None, "regression": None, "build": None}
        for stage in exits:
            if stage != "verify" and not case.get(stage):
                continue
            fd = os.open(output / (stage + ".log"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as log:
                exits[stage] = grade_snapshot(snapshot, case, image, stage, captured_inputs,
                    receipt=output / (stage + "-receipt.json"), log=log)
        write_receipt(output / "grading.json", exits)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", required=True, type=Path)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--image", required=True)
    parser.add_argument("--stage", required=True, choices=("verify", "regression", "build", "probe", "all"))
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.stage == "all":
            if args.output is None:
                raise InputRefused("all stages require an output directory")
            grade_stages(args.case, args.workspace, args.image, args.output)
            return 0
        return grade(args.case, args.workspace, args.image, args.stage, receipt=args.receipt)
    except (InputRefused, OSError, ValueError, KeyError) as error:
        print("coding-eval grading input refused: " + str(error), file=sys.stderr)
        return 125


if __name__ == "__main__":
    sys.exit(main())
