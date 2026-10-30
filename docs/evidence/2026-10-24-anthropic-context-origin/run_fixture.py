"""Execute production lowerer and extracted production prefix/header code.
No project build, serializer, source classifier, provider signature auth or HTTP.
Requires ocamlfind, yojson and digestif.ocaml. All compilation is in a temp dir.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def between(text, start, end):
    return text[text.index(start):text.index(end)]


def main():
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    lib = root / "packages/agent_core/lib/llm_provider"
    sources = {name: (lib / name).read_text() for name in [
        "message_origin_lowering.ml", "message_origin_lowering.mli",
        "reasoning_history_projection.ml", "types.ml", "backend_anthropic.ml"]}
    decoder = between(sources["types.ml"], "module Reasoning_prefix = struct", "(** A single message in the conversation.")
    projection = sources["reasoning_history_projection.ml"]
    prefix = "open Fixture_support\nopen Types\n" + between(projection,
        "let content_has_reasoning =", "let content_has_tool_use =") + between(projection,
        "let filter_content keep content =", "let content_has_generic_reasoning =") + between(projection,
        "type prefix_drop_cause =", "(* Tag-corruption causes")
    backend = sources["backend_anthropic.ml"]
    headers = between(backend, 'let binding_controls_beta =', '(* Measurement switch') + between(
        backend, 'let request_headers ~body headers =', 'let observe_input_transformations json =')
    with tempfile.TemporaryDirectory(prefix="masc-native-context-") as folder:
        folder = Path(folder)
        support = (here / "fixture_support.ml").read_text().replace("(* PRODUCTION_PREFIX_DECODER *)", decoder)
        (folder / "fixture_support.ml").write_text(support)
        (folder / "prefix_slice.ml").write_text(prefix)
        (folder / "header_slice.ml").write_text(headers)
        for name in ["message_origin_lowering.ml", "message_origin_lowering.mli"]:
            (folder / name).write_text("open Fixture_support\n" + sources[name])
        (folder / "fixture.ml").write_bytes((here / "fixture.ml").read_bytes())
        subprocess.run(["ocamlfind", "ocamlc", "-package", "yojson,digestif.ocaml", "-linkpkg",
            "fixture_support.ml", "message_origin_lowering.mli", "message_origin_lowering.ml",
            "prefix_slice.ml", "header_slice.ml", "fixture.ml", "-o", "fixture"], cwd=folder, check=True)
        checks = json.loads(subprocess.check_output([str(folder / "fixture")], text=True))
    report = {
        "scope": "production lowerer and extracted production prefix verifier, decoder and beta header code with fixture dependencies",
        "production_source_sha256": {name: hashlib.sha256(text.encode()).hexdigest() for name,text in sources.items()},
        "extracted_source_sha256": {"prefix_slice": hashlib.sha256(prefix.encode()).hexdigest(),
            "prefix_decoder": hashlib.sha256(decoder.encode()).hexdigest(), "header_slice": hashlib.sha256(headers.encode()).hexdigest()},
        "project_linked": False, "production_serializer_executed": False,
        "source_compatibility_classifier_executed": False, "provider_signature_authenticated": False,
        "provider_called": False, "checks": checks}
    print(json.dumps(report, indent=2))
    if not all(checks.values()):
        raise SystemExit(1)

if __name__ == "__main__":
    main()
