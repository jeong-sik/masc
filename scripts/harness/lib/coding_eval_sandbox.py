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
import signal
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


def _declared_wait_bound(case):
    """Stage wait bound in seconds, taken from the case's own declared policy.

    No new policy value is invented here: the harness already declares
    ``timeout_sec`` per case (scripts/harness_coding_eval.sh reads the same
    field for its episode poll deadline). A missing or invalid declaration
    refuses input instead of waiting forever (CR 5644102211)."""
    raw = case.get("timeout_sec") if isinstance(case, dict) else None
    if isinstance(raw, str) and raw.isdigit():
        raw = int(raw)
    if not isinstance(raw, int) or isinstance(raw, bool) or raw <= 0:
        raise InputRefused(
            "stage wait bound must be declared as timeout_sec in case.json; "
            "refusing to wait without a bound")
    return int(raw)


def _cid_file(output):
    """Private identity file for the container of one grading invocation."""
    fd, name = tempfile.mkstemp(prefix="masc-coding-grade-cid-")
    os.close(fd)
    path = Path(name)
    path.unlink(missing_ok=True)          # docker --cidfile needs it absent
    return path


def _reclaim(path):
    """Stop and remove exactly the recorded container, then classify.

    Returns ``(cid, status)``. ``cid`` is the recorded original identity —
    preserved verbatim even when cleanup fails, so a later operator can
    still address that exact container. ``status`` is one of:

    - ``"no_container"``: no identity was ever recorded (empty/absent file).
    - ``"confirmed_removed"``: the daemon's structured listing
      (``ps -a --filter id=… --format {{.ID}}``) answered successfully and
      the identity is absent (no matching row).
    - ``"container_still_present"``: the structured listing answered and the
      identity still exists (a matching row).
    - ``"uncertain"``: identity recorded, but the daemon could not answer
      a structured query about it (read failure, stop/rm/inspect spawn or
      daemon error, unparsable answer). Absence is never inferred from a
      failure to read or to ask.

    Classification uses only successful structured responses from
    ``docker inspect --format {{json .Id}}``; no stderr substring
    heuristics. Nothing may be claimed from ``docker rm`` alone. This
    function never raises: cleanup errors are classified and returned,
    preserving the caller's original grading outcome and receipts."""
    try:
        cid = path.read_text().strip()
    except FileNotFoundError:
        cid = ""
    except OSError as error:
        print("grading sandbox could not read the recorded container "
              "identity: " + str(error), file=sys.stderr)
        return ("", "uncertain")
    if not cid:
        _discard_cid_file(path)
        return ("", "no_container")
    for step in ("stop", "rm"):
        try:
            subprocess.run(["docker", step, cid], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=60)
        except (OSError, subprocess.SubprocessError) as error:
            print("grading sandbox cleanup step failed (" + step + "): "
                  + str(error), file=sys.stderr)
            return (cid, "uncertain")
    try:
        listing = subprocess.run(
            ["docker", "ps", "-a", "--filter", "id=" + cid,
             "--format", "{{.ID}}"],
            check=False, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as error:
        print("grading sandbox cleanup query failed: " + str(error),
              file=sys.stderr)
        return (cid, "uncertain")
    if listing.returncode != 0:
        # The daemon could not answer a structured query about this exact
        # identity. That is uncertainty, not proven absence.
        return (cid, "uncertain")
    rows = [line for line in (listing.stdout or "").splitlines()
            if line.strip()]
    if rows:
        # A successful listing that still returns a row for this exact
        # identity means stop/rm did not take effect.
        return (cid, "container_still_present")
    # Successful structured listing with zero rows for this identity: the
    # daemon reports no such container — the only confirmed-removal
    # evidence we accept. No stderr parsing is involved.
    _discard_cid_file(path)
    return (cid, "confirmed_removed")


def _discard_cid_file(path):
    """Best-effort removal of the recorded identity file.

    Kept only after a confirmed removal (or when no identity was ever
    recorded). Never allowed to raise over an in-flight grading outcome."""
    try:
        path.unlink(missing_ok=True)
    except OSError as error:
        print("grading sandbox could not remove the recorded container "
              "identity file: " + str(error), file=sys.stderr)


def _write_failure_receipt(receipt, snapshot, case, image, stage,
                           captured_inputs, wait_bound, cleanup, failure,
                           message):
    """Failure receipts preserve the captured input identity, the declared
    bound, the original container identity, and the actual cleanup
    classification. A missing/failed receipt must never erase the fact
    that a stage failed. ``cleanup`` is ``(cid, status)`` from _reclaim;
    the recorded identity is written verbatim even when cleanup stayed
    uncertain, so the exact container remains addressable afterwards."""
    if receipt is None:
        return
    cleanup_cid, cleanup_status = cleanup
    try:
        write_receipt(receipt, {
            "schema": "masc.coding_eval.grading.v1", "sandbox_profile": "docker",
            "image_id": image, "stage": stage, "failed": True,
            "failure": failure, "failure_message": message,
            "wait_bound_seconds": wait_bound,
            "cleanup_status": cleanup_status,
            "cleanup_container_id": cleanup_cid,
            "inputs": captured_inputs,
        })
    except OSError:
        print("grading sandbox could not write failure receipt: "
              + str(receipt), file=sys.stderr)


def grade_snapshot(snapshot, case, image, stage, captured_inputs, *, receipt=None, log=None):
    script = relative_path(case[stage])
    if not (snapshot / "case" / script).is_file():
        raise InputRefused("declared grading script is absent")
    wait_bound = _declared_wait_bound(case)
    isolation = {"network": "none", "user": "65534:65534",
                 "rootfs": "read_only", "input_mount": "read_only",
                 "host_credentials": "not_forwarded"}
    cid = _cid_file(snapshot)
    argv = [
        "docker", "run", "--rm", "--network", "none", "--read-only",
        "--cap-drop=ALL", "--security-opt", "no-new-privileges",
        "--user", "65534:65534", "--tmpfs", "/work:rw,exec,nosuid,mode=1777",
        "--tmpfs", "/tmp:rw,nosuid,mode=1777",
        "--mount", "type=bind,src=" + str(snapshot) + ",dst=/input,readonly",
        "--workdir", "/work", "--env", "HOME=/tmp",
        "--env", "PYTHONDONTWRITEBYTECODE=1", "--entrypoint", "/bin/bash",
        "--cidfile", str(cid),
        image, "-c",
        'set -euo pipefail; cp -R /input/workspace /work/workspace; '
        'chmod -R u+w /work/workspace; exec bash "$1" /work/workspace',
        "coding-eval-grader", "/input/case/" + str(script),
    ]
    stage_error = None
    result = None
    try:
        result = subprocess.run(argv, check=False, stdout=log,
                                stderr=subprocess.STDOUT if log else None,
                                timeout=wait_bound)
    except subprocess.TimeoutExpired as error:
        stage_error = ("stage_timeout",
                       stage + " stage exceeded the declared wait bound ("
                       + str(wait_bound) + "s)")
        raise InputRefused(stage_error[1])
    except (KeyboardInterrupt, SystemExit) as error:
        # SIGINT/SIGTERM delivered after the container started. The CLI
        # maps SIGTERM to SystemExit via a signal handler registered in
        # main(); KeyboardInterrupt is Python's SIGINT default. Either way
        # the original error is re-raised unchanged after cleanup.
        stage_error = ("cancelled", "grading was cancelled by signal")
        raise
    except OSError as error:
        # The docker CLI invocation itself failed (spawn error, broken
        # pipe, ...). The original error is re-raised unchanged after
        # cleanup; the failure receipt records it alongside the identity.
        stage_error = ("grader_invocation_failed",
                       "docker invocation failed: " + repr(error))
        raise
    finally:
        # Exactly one reclaim per stage attempt, covering every exit path
        # (success, timeout, cancellation, unexpected exception). The
        # recorded identity and its cleanup classification always reach
        # the receipt; the original error, if any, is never replaced.
        cleanup_cid, cleanup_status = _reclaim(cid)
        receipt_recorded = False
        try:
            if stage_error is not None:
                # Covers timeout, cancellation, and unexpected OSError:
                # each path sets stage_error, so one branch records every
                # failure receipt (cancelled sets it to "cancelled").
                _write_failure_receipt(receipt, snapshot, case, image, stage,
                                       captured_inputs, wait_bound,
                                       (cleanup_cid, cleanup_status),
                                       stage_error[0], stage_error[1])
                receipt_recorded = True
        except Exception as receipt_error:  # pragma: no cover - defensive
            print("grading sandbox failed while recording the failure "
                  "receipt: " + str(receipt_error), file=sys.stderr)
    if receipt is not None and not receipt_recorded:
        write_receipt(receipt, {
            "schema": "masc.coding_eval.grading.v1", "sandbox_profile": "docker",
            "image_id": image, "stage": stage, "exit_code": result.returncode,
            "wait_bound_seconds": wait_bound,
            "inputs": captured_inputs, "isolation": isolation,
            "cleanup_status": cleanup_status,
            "cleanup_container_id": cleanup_cid,
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
                try:
                    exits[stage] = grade_snapshot(snapshot, case, image, stage,
                        captured_inputs,
                        receipt=output / (stage + "-receipt.json"), log=log)
                except InputRefused as refusal:
                    # A refused stage is a failed stage: the failure receipt has
                    # already been written by grade_snapshot; grade_stages keeps
                    # grading other stages and reports the refusal as 125.
                    print("coding-eval grading input refused: " + str(refusal),
                          file=sys.stderr)
                    exits[stage] = 125
        write_receipt(output / "grading.json", exits)
        if any(code == 125 for code in exits.values()):
            return 125
        return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", required=True, type=Path)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--image", required=True)
    parser.add_argument("--stage", required=True, choices=("verify", "regression", "build", "probe", "all"))
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    # SIGTERM maps to SystemExit so the cancel path (receipt + reclaim of
    # the recorded container) runs inside grade_snapshot's finally block.
    # SIGINT keeps Python's KeyboardInterrupt default. Both are then the
    # explicit cancel signals of this CLI.
    def _sigterm(signum, _frame):
        raise SystemExit(128 + signum)
    try:
        signal.signal(signal.SIGTERM, _sigterm)
    except (ValueError, OSError):  # pragma: no cover - non-main thread
        pass
    try:
        if args.stage == "all":
            if args.output is None:
                raise InputRefused("all stages require an output directory")
            return grade_stages(args.case, args.workspace, args.image,
                                args.output)
        return grade(args.case, args.workspace, args.image, args.stage,
                     receipt=args.receipt)
    except (InputRefused, OSError, ValueError, KeyError) as error:
        print("coding-eval grading input refused: " + str(error), file=sys.stderr)
        return 125


if __name__ == "__main__":
    sys.exit(main())
