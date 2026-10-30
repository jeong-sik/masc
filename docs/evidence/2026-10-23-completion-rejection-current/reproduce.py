#!/usr/bin/env python3
"""Reproduce selected actual codec and Outbox checks without Dune.

Copies complete Types_core and its actual dependency closure. Skill source
configuration is reduced to the actual source_id contract/parser, excluding
TOML effects. Generated aliases reproduce component visibility; Types_auth is
not used. Actual Outbox ML/MLI stays byte-identical. Only storage/lock/lease and
lock-error-rendering boundaries are explicit sibling ports. Queue callbacks are
observations, not a native queue/FS/concurrency/runtime proof.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

MODULES = [
    "lib/string_util/string_util", "lib/shared_types/json_kind",
    "lib/core/json_util", "lib/core/safe_identifier",
    "lib/time_codec/time_codec", "lib/time_compat/time_compat",
    "lib/types/ids", "lib/skill_reference/skill_reference", "lib/types/types_core",
]
ORDER = ["string_util", "json_kind", "shared_types", "json_util", "safe_identifier",
         "skill_source_config", "skill_reference", "time_codec", "time_compat", "ids", "types_core"]
HELPERS = ["expect_backlog_decode_error", "rejection_receipt_json", "rejection_relation_json"]
CASES = ["test_backlog_completion_rejection_relations_roundtrip",
         "test_backlog_optional_rejection_observations",
         "test_backlog_rejects_conflicting_rejection_states",
         "test_backlog_rejects_malformed_delivered_rejection"]
PACKAGES = ("yojson,re,digestif.ocaml,alcotest,ptime,uuidm,mcp_protocol.eio,"
            "ppx_deriving.show,ppx_deriving.eq,ppx_deriving_yojson,ppx_enumerate")

def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def definition(source: str, name: str) -> str:
    start = source.index("let " + name + " ")
    end = source.index("\nlet ", start + 1)
    return source[start:end]

def command(args: list[str], work: Path, log: str) -> None:
    result = subprocess.run(args, cwd=work, text=True, capture_output=True)
    (work / log).write_text(shlex.join(args) + "\n" + result.stdout + result.stderr
                            + "\nexit=" + str(result.returncode) + "\n")
    print(log + ": exit=" + str(result.returncode), flush=True)
    result.check_returncode()

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="Repository source root (read only)")
    parser.add_argument("--tempdir", type=Path, help="Parent for a fresh retained validation directory")
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    assets = Path(__file__).resolve().parent
    if args.tempdir is not None:
        args.tempdir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="masc-rejection-validation-", dir=args.tempdir))
    print("artifacts: " + str(work), flush=True)
    sources: dict[str, str] = {}
    def source(rel: str) -> bytes:
        data = (root / rel).read_bytes()
        sources[rel] = sha(data)
        return data
    for stem in MODULES:
        for ext in (".mli", ".ml"):
            rel = stem + ext
            (work / Path(rel).name).write_bytes(source(rel))
    config = source("lib/skill_config/skill_source_config.ml").decode()
    config_mli = source("lib/skill_config/skill_source_config.mli").decode()
    source_id_type = "type source_id = string"
    private_type = "type source_id = private string"
    assert source_id_type in config and private_type in config_mli
    start = config.index("let source_id_of_string ")
    end = config.index("\nlet top_level_namespace", start)
    (work / "skill_source_config.ml").write_text(source_id_type + "\n"
        + config[config.index("let source_id_to_string "):config.index("\nlet resource_read_max_bytes_to_int")]
        + "\n" + config[start:end])
    required_vals = [line for line in config_mli.splitlines()
                     if line.startswith(("val source_id_to_string :", "val source_id_of_string :"))]
    assert len(required_vals) == 2
    (work / "skill_source_config.mli").write_text(private_type + "\n" + "\n".join(required_vals) + "\n")
    (work / "shared_types.ml").write_text("module Json_kind = Json_kind\n")
    (work / "masc_domain.ml").write_text("include Types_core\n")
    tests = source("test/test_types_coverage.ml").decode()
    definitions = {name: definition(tests, name) for name in HELPERS + CASES}
    test_body = "open Alcotest\n" + "\n".join(definitions.values())
    test_body += "\nlet () = Alcotest.run \"canonical rejection relation codec\" [\"actual codec\",[\n"
    test_body += "".join("test_case " + json.dumps(name) + " `Quick " + name + ";\n" for name in CASES)
    test_body += "]]\n"
    (work / "codec_fixture.ml").write_text(test_body)
    # Every subsequent compile uses real previously compiled dependency modules.
    compile_prefix = ["opam", "exec", "--", "ocamlfind", "ocamlopt", "-thread",
                      "-w", "+4+32+69", "-warn-error", "+a", "-package", PACKAGES, "-linkpkg"]
    module_files = []
    for name in ORDER + ["masc_domain"]:
        module_files.extend(name + ext for ext in (".mli", ".ml") if (work / (name + ext)).exists())
    command(compile_prefix + module_files + ["codec_fixture.ml", "-o", "codec_fixture.exe"], work, "codec-compile.log")
    command([str(work / "codec_fixture.exe"), "--color=never"], work, "codec-run.log")
    port_files = ["workspace_utils_backend_setup.ml", "workspace_utils_ops.ml", "workspace_backlog.ml"]
    for name in port_files:
        shutil.copyfile(assets / "ports" / name, work / name)
    (work / "masc_domain.ml").write_text("include Types_core\n" + (assets / "ports/boundary_renderer.ml").read_text())
    for ext in (".mli", ".ml"):
        rel = "lib/workspace/workspace_task_rejection_outbox" + ext
        (work / Path(rel).name).write_bytes(source(rel))
    shutil.copyfile(assets / "outbox_fixture.ml", work / "outbox_fixture.ml")
    command(compile_prefix + [name + ".cmx" for name in ORDER] + ["masc_domain.ml"] + port_files
            + ["workspace_task_rejection_outbox.mli", "workspace_task_rejection_outbox.ml",
               "outbox_fixture.ml", "-o", "outbox_fixture.exe"], work, "outbox-compile.log")
    command([str(work / "outbox_fixture.exe"), "--color=never"], work, "outbox-run.log")
    current = {rel: sha((root / rel).read_bytes()) == digest for rel, digest in sources.items()}
    manifest = {"actual_sources_sha256": sources,
        "actual_sources_unchanged_during_run": current,
        "codec_definition_sha256": {name: sha(body.encode()) for name, body in definitions.items()},
        "harness_assets_sha256": {str(path.relative_to(assets)): sha(path.read_bytes())
            for path in [Path(__file__).resolve(), assets / "outbox_fixture.ml", *sorted((assets / "ports").glob("*.ml"))]},
        "scope": __doc__, "codec_cases": 4, "outbox_cases": 9,
        "ports": "Sibling Workspace_utils_backend_setup, Workspace_backlog, Workspace_utils_ops and boundary renderer; deterministic sequential interposition, no real queue/filesystem/lease concurrency."}
    (work / "source-identity.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if not all(current.values()):
        raise RuntimeError("actual source changed during validation; inspect source-identity.json")
    print("PASS: actual codec4 + actual Outbox9; scope in source-identity.json", flush=True)

if __name__ == "__main__":
    main()
