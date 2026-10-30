#!/usr/bin/env python3
"""Inspect unchanged authorities and execute the actual thinking projection.

The config type is an explicit one-field input port. This does not link the
provider package or execute its complete request builder.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

BASE = "43162710e28f61375ece2d6497de9892705ef691"
FAILED_CANDIDATE = "7501aec032012869d8b979e0d14e1a9a9464ace7"
PREFIX = "packages/agent_core/"
BACKEND = PREFIX + "lib/llm_provider/backend_anthropic.ml"
CONFIG = PREFIX + "lib/llm_provider/provider_config.ml"
CAPABILITIES = PREFIX + "lib/llm_provider/capabilities.ml"
CATALOG = PREFIX + "models.toml"
TEST = PREFIX + "test/test_provider_config.ml"
CONFIG_PORT = "module Provider_config = struct type t = {enable_thinking : bool option} end\n"
PROBE = '''let check label expected wire enable_thinking =
  let actual = thinking_config_for_config wire {Provider_config.enable_thinking} in
  if actual <> expected then failwith label
let () =
  check "unset native override" None
    (Anthropic_control Capabilities.Anthropic_always_adaptive) None;
  check "explicit native always-adaptive" None
    (Anthropic_control Capabilities.Anthropic_always_adaptive) (Some true);
  check "unset proxy override" None Anthropic_no_policy None;
  check "positive adaptive control" (Some (`Assoc ["type", `String "adaptive"]))
    (Anthropic_control Capabilities.Anthropic_adaptive_default) (Some true);
  print_endline "4 actual-source thinking projection checks passed"
'''


def fragment(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


def sha(source):
    return hashlib.sha256(source.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)

    def at(ref, path):
        return subprocess.check_output(["git", "show", f"{ref}:{path}"], cwd=repo).decode()

    sources = {ref: {path: at(ref, path) for path in (BACKEND, CONFIG, CAPABILITIES, CATALOG, TEST)}
               for ref in (BASE, FAILED_CANDIDATE)}
    receipts = {}
    for path in (CONFIG, CATALOG):
        assert sources[BASE][path] == sources[FAILED_CANDIDATE][path]
        assert (repo / path).read_text() == sources[BASE][path]
        receipts[path] = {"base_and_candidate_identical": True, "sha256": sha(sources[BASE][path])}
    test_start = "let test_catalog_policy_native_and_proxy () ="
    base_test = fragment(sources[BASE][TEST], test_start, "\n;;")
    assert base_test == fragment(sources[FAILED_CANDIDATE][TEST], test_start, "\n;;")
    receipts[TEST] = {"before_repair_base_and_failed_candidate_identical": True, "original_test_sha256": sha(base_test)}
    for ref, files in sources.items():
        thinking = fragment(files[BACKEND], "type thinking_wire =", "let validate_thinking_controls")
        caps = fragment(files[CAPABILITIES], "type anthropic_thinking_control =", "let anthropic_thinking_control_of_vocab_value")
        assert thinking == fragment((repo / BACKEND).read_text(), "type thinking_wire =", "let validate_thinking_controls")
        work = out / ref[:12]
        work.mkdir()
        source = "module Capabilities = struct\n" + caps + "end\n" + CONFIG_PORT + thinking + PROBE
        (work / "probe.ml").write_text(source)
        subprocess.run(["ocamlc", "-w", "+4+32+69", "-warn-error", "+a", "probe.ml", "-o", "probe"], cwd=work, check=True)
        result = subprocess.check_output([str(work / "probe")], cwd=work, text=True).strip()
        receipts[ref] = {"thinking_fragment_sha256": sha(thinking), "result": result, "checks_passed": 4}
    report = {"base": BASE, "failed_candidate": FAILED_CANDIDATE, "source_receipts": receipts,
              "config_input_port": CONFIG_PORT,
              "scope": "Actual unchanged thinking projection with typed config input port; no complete request builder, native linking, Dune, CI or live provider execution"}
    (out / "observations.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
