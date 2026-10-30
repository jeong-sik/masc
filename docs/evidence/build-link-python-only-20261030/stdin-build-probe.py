#!/usr/bin/env python3
"""Exercise scripts extracted from the working tree, not a MASC binary."""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def extract(source):
    common = re.search(r"let checked_build_input_script consumer =\s*\{py\|(.*?)\|py\}", source, re.S)
    link = re.search(r"let build_link_apply_script =\s*checked_build_input_script\s*\{py\|(.*?)\|py\}", source, re.S)
    mkdir = re.search(r"let build_target_mkdir_request.*?Printf.sprintf \{py\|(.*?)\|py\} build_target_dir_mode", source, re.S)
    wrapper = re.search(r"let build_input_interpreter =\s*\{sh\|(.*?)\|sh\}", source, re.S)
    if not all((common, link, mkdir, wrapper)):
        raise RuntimeError("could not extract all scripts from this source revision")
    return {
        "link": common.group(1) + link.group(1) + "\n",
        "mkdir": common.group(1) + (mkdir.group(1) % "0777") + "\n",
        "wrapper": wrapper.group(1),
        "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
    }


def run_checks(scripts):
    checks = {}
    with tempfile.TemporaryDirectory(prefix="masc-stdin-probe-") as temp:
        root = Path(temp)

        def invoke(kind, data, count, expected=None, size=None, digest=None):
            expected = data if expected is None else expected
            size = len(expected) if size is None else size
            digest = hashlib.sha256(expected).hexdigest() if digest is None else digest
            return subprocess.run(
                ["/bin/sh", "-c", scripts["wrapper"], "masc-build-helper",
                 scripts[kind], "masc-build-" + kind,
                 str(size), digest, str(count)],
                input=data, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )

        checkout = root / "odd\nname\tvalue"
        checkout.mkdir()
        data = os.fsencode(checkout.name) + b"\0/fixture/target\0"
        destination = checkout / "_build"
        for name, invalid in (("short", data[:-1]), ("extra", data + b"x"),
                              ("corrupt", b"X" + data[1:])):
            p = invoke("link", invalid, 2, expected=data)
            assert p.returncode and not destination.is_symlink(), name
            checks[name + "_rejected_before_link"] = True
        for name, invalid, count in (("missing_nul", data[:-1], 2),
                                     ("odd_fields", b"odd\0", 1),
                                     ("empty_field", b"\0/target\0", 2)):
            p = invoke("link", invalid, count)
            assert p.returncode and not destination.is_symlink(), name
            checks[name + "_rejected_before_link"] = True

        (root / "hashlib.py").write_text("open('unexpected-import', 'w').write('bad')\n")
        p = invoke("link", data, 2)
        assert p.returncode == 0, p.stderr.decode(errors="replace")
        assert destination.readlink() == Path("/fixture/target")
        assert not (root / "unexpected-import").exists()
        checks["isolated_import_and_unusual_path"] = True

        collision = root / "collision"
        collision.mkdir()
        (collision / "_build").mkdir()
        (collision / "_build" / "keep").write_text("intact")
        later = root / "-later"
        later.mkdir()
        pair_data = b"collision\0/target\0-later\0/target\0"
        p = invoke("link", pair_data, 4)
        assert p.returncode != 0
        assert (collision / "_build" / "keep").read_text() == "intact"
        assert (later / "_build").readlink() == Path("/target")
        checks["collision_preserved_later_link_created"] = True

        target = root / "build-target"
        target_data = os.fsencode(target) + b"\0"
        p = invoke("mkdir", target_data[:-1], 1, expected=target_data)
        assert p.returncode and not target.exists()
        p = invoke("mkdir", target_data, 1)
        assert p.returncode == 0 and target.is_dir()
        os.chmod(target, 0o700)
        p = invoke("mkdir", target_data, 1)
        assert p.returncode == 0 and (target.stat().st_mode & 0o777) == 0o700
        checks["mkdir_validation_and_existing_mode"] = True

        large = target_data * 50000
        p = invoke("mkdir", large, 50000)
        assert len(large) > 1024 * 1024 and p.returncode == 0, p.stderr.decode(errors="replace")
        checks["large_stdin_bytes"] = len(large)
        p = invoke("link", b"", 0)
        assert p.returncode == 0
        checks["empty_payload"] = True

    selected = subprocess.check_output(["/bin/sh", "-c", scripts["wrapper"],
        "masc-build-helper", "import sys;print(sys.executable)"], text=True).strip()
    return {"scope": "source-extracted wrapper and Python helpers in a synthetic temporary directory",
            "source_sha256": scripts["source_sha256"],
            "harness_python": sys.version.split()[0], "selected_interpreter": selected, "platform": sys.platform,
            "kernel": os.uname().release, "checks": checks}


if __name__ == "__main__":
    if sys.argv[1:] == ["--guest-run"]:
        print(json.dumps(run_checks(json.load(sys.stdin)), ensure_ascii=False))
    elif len(sys.argv) == 2:
        print(json.dumps(run_checks(extract(Path(sys.argv[1]).read_text())), ensure_ascii=False))
    else:
        raise SystemExit("usage: stdin-build-probe.py SOURCE | --guest-run")
