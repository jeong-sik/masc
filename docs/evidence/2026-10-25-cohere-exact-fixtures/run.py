#!/usr/bin/env python3
"""Execute the actual Cohere fixture helpers against selected production parsers."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


MODULES = (
    "reasoning_effort",
    "model_identifiers",
    "serving_constraint",
    "provider_kind",
    "capability_vocab",
    "model_provider_catalog",
    "serving_constraint_catalog",
    "capability_manifest",
    "model_catalog",
)
PACKAGES = (
    "yojson",
    "otoml",
    "ppx_deriving.show",
    "ppx_deriving.eq",
    "ppx_deriving_yojson.runtime",
)
PROVIDER_ROOT = "packages/agent_core/lib/llm_provider"
MODELS = "packages/agent_core/models.toml"
FIXTURE = "packages/agent_core/test/test_cohere_schema_wire.ml"


class ProbeFailure(Exception):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def command(argv: list[str], *, cwd: Path, env: dict[str, str]) -> subprocess.CompletedProcess:
    result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True)
    if result.returncode:
        detail = result.stderr.decode(errors="replace").strip()
        raise ProbeFailure(f"{argv[0]} failed (exit {result.returncode}): {detail}")
    return result


def execute(args: argparse.Namespace) -> dict:
    for executable in ("git", "ocamlc", "ocamlfind"):
        if shutil.which(executable) is None:
            raise ProbeFailure(f"required tool unavailable: {executable}")
    env = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")
    selected = Path(args.repo).expanduser().resolve() if args.repo else Path.cwd()
    root = Path(command(
        ["git", "-C", str(selected), "rev-parse", "--show-toplevel"], cwd=selected, env=env
    ).stdout.decode().strip())
    flags = ["git", "--no-replace-objects"]
    supports_no_lazy = subprocess.run(
        ["git", "--no-lazy-fetch", "version"], capture_output=True, env=env
    ).returncode == 0
    if supports_no_lazy:
        flags.append("--no-lazy-fetch")
    flags += ["-C", str(root)]

    def git(*argv: str) -> bytes:
        return command([*flags, *argv], cwd=root, env=env).stdout

    def resolve(ref: str) -> str:
        return git("rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()

    before, after = resolve(args.before_ref), resolve(args.after_ref)
    support = Path(__file__).resolve().parent
    inputs = []
    preprocess = []
    compile_steps = []
    versions = {
        "python": sys.version.split()[0],
        "ocaml": command(["ocamlc", "-version"], cwd=root, env=env).stdout.decode().strip(),
        "git": command(["git", "--version"], cwd=root, env=env).stdout.decode().strip(),
        "packages": {
            package: command(["ocamlfind", "query", "-format", "%v", package], cwd=root, env=env)
            .stdout.decode().strip()
            for package in PACKAGES
        },
    }
    support_hashes = {name: sha256((support / name).read_bytes()) for name in ("prepare_parser.ml", "probe.ml")}

    with tempfile.TemporaryDirectory(prefix="masc-cohere-parser-") as directory:
        work = Path(directory)
        source = work / "source"
        source.mkdir()
        shutil.copyfile(support / "prepare_parser.ml", work / "prepare_parser.ml")
        shutil.copyfile(support / "probe.ml", work / "probe.ml")

        def retain(ref: str, relative: str, local: str) -> bytes:
            raw = git("show", ref + ":" + relative)
            (source / local).write_bytes(raw)
            inputs.append({
                "ref": ref,
                "path": relative,
                "blob": git("rev-parse", "--verify", "--end-of-options", ref + ":" + relative).decode().strip(),
                "sha256": sha256(raw),
            })
            return raw

        for module in MODULES:
            for extension in ("ml", "mli"):
                name = module + "." + extension
                retain(after, PROVIDER_ROOT + "/" + name, name)
        models = retain(after, MODELS, "models.toml")
        retain(before, FIXTURE, "before_fixture.ml")
        retain(after, FIXTURE, "after_fixture.ml")

        command(["ocamlc", "-I", "+compiler-libs", "ocamlcommon.cma", "prepare_parser.ml", "-o", "prepare_parser"], cwd=work, env=env)

        def prepare(mode: str, name: str) -> bytes:
            result = command(["./prepare_parser", mode, "source/" + name], cwd=work, env=env)
            if result.stderr:
                preprocess.append(result.stderr.decode().strip())
            return result.stdout

        for module in MODULES:
            (work / (module + ".ml")).write_bytes(prepare("strip", module + ".ml"))
            shutil.copyfile(source / (module + ".mli"), work / (module + ".mli"))
        tag = b"masc_parser_embedded"
        while b"|" + tag + b"}" in models:
            tag += b"_"
        (work / "model_catalog_embedded.ml").write_bytes(b"let contents = {" + tag + b"|" + models + b"|" + tag + b"}\n")
        extracted = {}
        for label in ("before", "after"):
            for mode in ("helpers", "exact"):
                raw = prepare(mode, label + "_fixture.ml")
                (work / (label + "_" + mode + ".ml")).write_bytes(raw)
                extracted[label + "_" + mode] = raw
        exact_unchanged = extracted["before_exact"] == extracted["after_exact"]

        order = [*MODULES[:-1], "model_catalog_embedded", MODULES[-1], "before_helpers", "after_helpers"]
        packages = ",".join(PACKAGES)
        for module in order:
            for extension in ("mli", "ml"):
                name = module + "." + extension
                if (work / name).exists():
                    argv = ["ocamlfind", "ocamlc", "-package", packages, "-c", name]
                    result = command(argv, cwd=work, env=env)
                    compile_steps.append({"argv": argv, "stdout": result.stdout.decode(), "stderr": result.stderr.decode()})
        argv = ["ocamlfind", "ocamlc", "-package", packages, "-linkpkg", *[module + ".cmo" for module in order], "probe.ml", "-o", "probe"]
        result = command(argv, cwd=work, env=env)
        compile_steps.append({"argv": argv, "stdout": result.stdout.decode(), "stderr": result.stderr.decode()})
        result = command(["./probe"], cwd=work, env=env)
        stdout, stderr = result.stdout.decode(), result.stderr.decode()
        lines = stdout.splitlines()
        if not lines:
            raise ProbeFailure("probe returned without output")
        terminal = lines[-1].split()
        if len(terminal) != 3 or terminal[0] != "COMPONENT_PROBES" or terminal[2] != "PASS":
            raise ProbeFailure("probe returned without its explicit component receipt")
        count = int(terminal[1])

    return {
        "schema": "masc.cohere-parser-component.v1",
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "verdict": "PASS",
        "before_ref": before,
        "after_ref": after,
        "toolchain": versions,
        "inputs": inputs,
        "support_sha256": support_hashes,
        "runner_sha256": sha256(Path(__file__).read_bytes()),
        "extracted_AST_sha256": {name: sha256(raw) for name, raw in extracted.items()},
        "exact_frozen_function_AST_unchanged": exact_unchanged,
        "preprocessing": preprocess,
        "compilation": compile_steps,
        "observed": {"probe_count": count, "exit": result.returncode, "stdout": stdout, "stderr": stderr},
        "scope": "Actual selected production parser component and existing fixture helper ASTs. Whole Cohere suite, Exact_output execution, Provider_catalog runtime parsing, full project build/typecheck, Dune, CI, installation and runtime unexecuted.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", help="checkout to read; defaults to git rev-parse from the current directory")
    parser.add_argument("--before-ref", required=True)
    parser.add_argument("--after-ref", required=True)
    parser.add_argument("--receipt", type=Path, help="create this new JSON receipt file; existing files are refused")
    args = parser.parse_args()
    try:
        if args.receipt and args.receipt.exists():
            raise ProbeFailure("receipt file already exists")
        receipt = execute(args)
        encoded = json.dumps(receipt, ensure_ascii=False, indent=2) + "\n"
        if args.receipt:
            with args.receipt.open("x", encoding="utf-8") as destination:
                destination.write(encoded)
            sys.stdout.write(receipt["observed"]["stdout"])
        else:
            sys.stdout.write(encoded)
        return 0
    except (ProbeFailure, OSError, ValueError) as error:
        print(f"parser component failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
