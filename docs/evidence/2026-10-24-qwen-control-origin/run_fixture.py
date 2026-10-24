"""Execute unchanged production lowerer with isolated fixture dependencies.

No Dune, project build, production serializer or provider request is executed.
Usage: python3 run_fixture.py /path/to/pinned/chat_template.jinja
Requires OCaml/ocamlfind/yojson and Python Jinja2.
"""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from jinja2 import Environment


def main():
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    source = root / "packages/agent_core/lib/llm_provider/message_origin_lowering.ml"
    interface = source.with_suffix(".mli")
    template_source = Path(sys.argv[1]).read_bytes()
    template_hash = hashlib.sha256(template_source).hexdigest()
    if template_hash != "e84f32a23fdda27689f868aa4a1a5621f41133e51a48d7f3efcbea2839574259":
        raise ValueError("Expected pinned official Qwen3.6 template")
    with tempfile.TemporaryDirectory(prefix="masc-origin-fixture-") as directory:
        directory = Path(directory)
        for path in [here / "fixture_support.ml", here / "fixture.ml"]:
            (directory / path.name).write_bytes(path.read_bytes())
        for path in [source, interface]:
            (directory / path.name).write_text("open Fixture_support\n" + path.read_text())
        subprocess.run(["ocamlfind", "ocamlc", "-package", "yojson", "-linkpkg",
                        "fixture_support.ml", "message_origin_lowering.mli",
                        "message_origin_lowering.ml", "fixture.ml", "-o", "fixture"],
                       cwd=directory, check=True)
        wire = json.loads(subprocess.check_output([str(directory / "fixture")], text=True))
    env = Environment()

    def reject(message):
        raise ValueError(message)

    env.globals["raise_exception"] = reject
    template = env.from_string(template_source.decode())

    def render(key, preserve=False):
        return template.render(messages=wire[key], tools=[], add_generation_prompt=True,
                               preserve_thinking=preserve, enable_thinking=True)

    checks = {
        "production_lowerer_fixture_checks": wire["lowerer_checks"],
        "original_tail_controls_lose_current_reasoning": "CURRENT_REASONING" not in render("before"),
        "lowered_controls_keep_current_reasoning": "CURRENT_REASONING" in render("after"),
        "selective_template_drops_old_reasoning": "OLD_REASONING" not in render("after"),
        "real_human_with_reserved_tool_syntax_closes_trajectory": "CURRENT_REASONING" not in render("new_human"),
        "tool_media_after_modality_order_keeps_trajectory": "CURRENT_REASONING" in render("with_media"),
        "full_history_remains_explicit_opt_in":
            "OLD_REASONING" in render("after", True) and "CURRENT_REASONING" in render("after", True),
    }
    print(json.dumps({"production_lowerer_source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                      "template_sha256": template_hash,
                      "scope": "production lowerer with fixture dependencies plus official template",
                      "production_serializer_executed": False, "project_linked": False,
                      "reasoning_projector_executed": False, "provider_called": False,
                      "checks": checks}, indent=2))
    if not all(checks.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
