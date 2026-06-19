#!/usr/bin/env python3
"""RFC-0265 — Ollama model capability sync + drift gate.

Keeps the MASC runtime config's declared media-input capabilities
([models.<id>.capabilities].supports-image-input / -audio-input /
-multimodal-inputs) aligned with what Ollama actually reports for each model
via POST /api/show. This is the "generated truth-source + drift-gate" half of
RFC-0265: the runtime stays fully static/deterministic (it reads the TOML), and
this script is the only thing that talks to Ollama.

Why a separate baseline file:
  --refresh needs network + the OLLAMA_CLOUD_API_KEY (operator-run). --check
  must run in CI with no network, so it compares the config against the
  checked-in baseline snapshot (scripts/ollama-caps-baseline.json), never the
  live endpoint. Two levels of drift are therefore covered:
    config  vs baseline  -> --check  (deterministic, CI)
    baseline vs /api/show -> --refresh (operator, surfaces as a baseline diff)

Modes:
  --check    (default) compare config-declared media caps against the baseline.
             Hard-fails (exit 1) on a real mismatch (declared != reality).
             Soft-warns (exit 0) when a config model is absent from the baseline.
  --refresh  probe /api/show for every Ollama-family model in the config and
             (re)write the baseline JSON. Requires network + provider key.
  --emit     print the recommended [models.<id>.capabilities] media lines for
             each Ollama-family model, derived from the baseline. Advisory; the
             operator merges these into the live runtime.toml.
  --self-test  run the pure-mapping assertions and exit (no config/network).

Capability mapping (source: ollama/ollama types/model/capability.go enum,
cross-checked against live POST /api/show on 2026-06-19):
  "vision" or "image" -> supports-image-input  = true
  "audio"             -> supports-audio-input  = true

supports-multimodal-inputs is intentionally NOT derived. MASC maps it to the
"document" modality (runtime_agent.ml: supports_required_modality "document" ->
supports_multimodal_inputs), and Ollama /api/show reports no document/multimodal
capability string — only vision/image/audio. Deriving multimodal from "vision"
would make the capability gate *admit* a document turn to an image-only model
(a fail-open the gate exists to prevent). So document support stays an explicit
operator declaration that this script neither emits nor checks; it manages only
the image and audio input flags that /api/show actually evidences.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ModuleNotFoundError:
        print(
            "error: Python 3.11+ (tomllib) or the tomli package required",
            file=sys.stderr,
        )
        sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = REPO_ROOT / "config" / "runtime.toml"
DEFAULT_BASELINE = REPO_ROOT / "scripts" / "ollama-caps-baseline.json"
BASELINE_SCHEMA_VERSION = 1

# Ollama /api/show capability enum (ollama/ollama types/model/capability.go).
# Kept here as the single documented reference for the string->bool mapping.
OLLAMA_CAPABILITY_ENUM = (
    "completion",
    "tools",
    "insert",
    "vision",
    "embedding",
    "thinking",
    "image",
    "audio",
)

IMAGE_TOKENS = ("vision", "image")
AUDIO_TOKENS = ("audio",)

PROBE_TIMEOUT_S = 20.0


@dataclass(frozen=True)
class MediaFlags:
    """The /api/show-evidenced media-input flags: image and audio only.

    supports-multimodal-inputs (the MASC "document" modality) is excluded by
    design — see the module docstring. Ollama does not report it, so this script
    neither derives nor compares it; document support is operator-declared.
    """

    image: bool
    audio: bool

    @staticmethod
    def from_ollama_capabilities(caps: list[str]) -> "MediaFlags":
        lowered = {c.lower() for c in caps}
        return MediaFlags(
            image=any(t in lowered for t in IMAGE_TOKENS),
            audio=any(t in lowered for t in AUDIO_TOKENS),
        )

    @staticmethod
    def from_declared(capabilities_block: dict[str, Any]) -> "MediaFlags":
        return MediaFlags(
            image=bool(capabilities_block.get("supports-image-input", False)),
            audio=bool(capabilities_block.get("supports-audio-input", False)),
        )

    def declared_lines(self) -> list[str]:
        lines: list[str] = []
        if self.image:
            lines.append("supports-image-input = true")
        if self.audio:
            lines.append("supports-audio-input = true")
        return lines


@dataclass(frozen=True)
class OllamaModel:
    """An Ollama-family model resolved from the runtime config."""

    model_id: str  # [models.<id>] table key (dot-avoidance form)
    api_name: str  # api-name actually sent to /api/show
    provider_id: str
    native_base: str  # /api/show base (provider endpoint minus trailing /v1)
    auth_env: str | None  # env var holding the bearer token, if any
    declared: MediaFlags


def _is_ollama_family(provider: dict[str, Any]) -> bool:
    protocol = str(provider.get("protocol", ""))
    endpoint = str(provider.get("endpoint", ""))
    return protocol == "ollama-http" or "ollama.com" in endpoint or "11434" in endpoint


def _native_base(endpoint: str) -> str:
    base = endpoint.rstrip("/")
    if base.endswith("/v1"):
        base = base[: -len("/v1")]
    return base


def resolve_ollama_models(config: dict[str, Any]) -> list[OllamaModel]:
    providers = config.get("providers", {})
    models = config.get("models", {})
    resolved: list[OllamaModel] = []

    for provider_id, provider in providers.items():
        if not isinstance(provider, dict) or not _is_ollama_family(provider):
            continue
        native_base = _native_base(str(provider.get("endpoint", "")))
        creds = provider.get("credentials")
        auth_env: str | None = None
        if isinstance(creds, dict) and creds.get("type") == "env":
            auth_env = creds.get("key")

        # Bindings live in the top-level [provider_id.model_id] tables, i.e.
        # config[provider_id] is a dict whose keys are model ids.
        bindings = config.get(provider_id, {})
        if not isinstance(bindings, dict):
            continue
        for model_id, binding in bindings.items():
            if not isinstance(binding, dict):
                continue
            model_def = models.get(model_id)
            if not isinstance(model_def, dict):
                # Binding without a [models.<id>] table: cannot resolve api-name.
                print(
                    f"warning: binding {provider_id}.{model_id} has no "
                    f"[models.{model_id}] table; skipped",
                    file=sys.stderr,
                )
                continue
            api_name = str(model_def.get("api-name", model_id))
            cap_block = model_def.get("capabilities", {})
            declared = MediaFlags.from_declared(
                cap_block if isinstance(cap_block, dict) else {}
            )
            resolved.append(
                OllamaModel(
                    model_id=model_id,
                    api_name=api_name,
                    provider_id=provider_id,
                    native_base=native_base,
                    auth_env=auth_env,
                    declared=declared,
                )
            )
    # Deterministic order for stable baselines / diffs.
    resolved.sort(key=lambda m: (m.provider_id, m.model_id))
    return resolved


def load_config(path: Path) -> dict[str, Any]:
    with path.open("rb") as fh:
        return tomllib.load(fh)


def probe_capabilities(model: OllamaModel) -> list[str]:
    """POST {native_base}/api/show {"model": api_name} -> capabilities list."""
    url = f"{model.native_base}/api/show"
    body = json.dumps({"model": model.api_name}).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    if model.auth_env:
        token = os.environ.get(model.auth_env)
        if not token:
            raise RuntimeError(
                f"auth env {model.auth_env} is unset for provider "
                f"{model.provider_id}"
            )
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT_S) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    caps = payload.get("capabilities")
    if not isinstance(caps, list):
        raise RuntimeError(
            f"/api/show for {model.api_name} returned no capabilities array"
        )
    return [str(c) for c in caps]


# ── modes ────────────────────────────────────────────────────────────


def mode_refresh(config_path: Path, baseline_path: Path) -> int:
    config = load_config(config_path)
    models = resolve_ollama_models(config)
    if not models:
        print(f"no Ollama-family models found in {config_path}", file=sys.stderr)
        return 1

    entries: dict[str, dict[str, Any]] = {}
    failures = 0
    for model in models:
        try:
            caps = probe_capabilities(model)
        except (urllib.error.URLError, RuntimeError, ValueError) as exc:
            print(f"probe failed for {model.api_name}: {exc}", file=sys.stderr)
            failures += 1
            continue
        unknown = sorted({c.lower() for c in caps} - set(OLLAMA_CAPABILITY_ENUM))
        if unknown:
            # Ollama added a capability string we do not map yet — surface it so
            # the enum + mapping can be updated rather than silently ignored.
            print(
                f"  note: {model.api_name} reports unmapped capabilities "
                f"{unknown} (update OLLAMA_CAPABILITY_ENUM/mapping)",
                file=sys.stderr,
            )
        entries[model.api_name] = {
            "provider": model.provider_id,
            "capabilities": caps,
        }
        flags = MediaFlags.from_ollama_capabilities(caps)
        print(
            f"  {model.api_name:<24} caps={caps} "
            f"-> image={flags.image} audio={flags.audio}"
        )

    baseline = {
        "_comment": (
            "Ollama model capability baseline (POST /api/show). Regenerate "
            "against the LIVE config (superset of the repo seed) so it covers "
            "both: scripts/masc-sync-ollama-caps.py --refresh --config "
            "~/me/.masc/config/runtime.toml. CI drift gate (no network): --check."
        ),
        "schema_version": BASELINE_SCHEMA_VERSION,
        "source": '{provider.endpoint - /v1}/api/show {"model": <api-name>}',
        "models": dict(sorted(entries.items())),
    }
    baseline_path.write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(entries)} model(s) to {baseline_path}")
    if failures:
        print(f"{failures} probe(s) failed; baseline left partial", file=sys.stderr)
        return 1
    return 0


def load_baseline(baseline_path: Path) -> dict[str, dict[str, Any]]:
    data = json.loads(baseline_path.read_text(encoding="utf-8"))
    if data.get("schema_version") != BASELINE_SCHEMA_VERSION:
        raise RuntimeError(
            f"baseline schema_version {data.get('schema_version')} != "
            f"{BASELINE_SCHEMA_VERSION}"
        )
    models = data.get("models", {})
    if not isinstance(models, dict):
        raise RuntimeError("baseline has no models map")
    return models


def mode_check(config_path: Path, baseline_path: Path, strict: bool) -> int:
    config = load_config(config_path)
    models = resolve_ollama_models(config)
    baseline = load_baseline(baseline_path)

    hard = 0
    soft = 0
    for model in models:
        entry = baseline.get(model.api_name)
        if entry is None:
            print(
                f"::warning::{model.model_id} ({model.api_name}) not in baseline; "
                f"run --refresh to verify",
                file=sys.stderr,
            )
            soft += 1
            continue
        expected = MediaFlags.from_ollama_capabilities(entry["capabilities"])
        declared = model.declared
        if declared != expected:
            under = (expected.image and not declared.image) or (
                expected.audio and not declared.audio
            )
            over = (declared.image and not expected.image) or (
                declared.audio and not expected.audio
            )
            if under and over:
                kind = "MISMATCH (both under- and over-declared)"
            elif under:
                kind = "UNDER-DECLARED (reroute/gate will not see a modality)"
            else:
                kind = "OVER-DECLARED (provider will 400 at dispatch)"
            print(
                f"DRIFT {model.model_id} ({model.api_name}): {kind}\n"
                f"  /api/show caps = {entry['capabilities']}\n"
                f"  expected: image={expected.image} audio={expected.audio}\n"
                f"  declared: image={declared.image} audio={declared.audio}",
                file=sys.stderr,
            )
            hard += 1

    if hard:
        print(f"FAIL: {hard} model(s) drifted from /api/show reality", file=sys.stderr)
        return 1
    if soft and strict:
        print(f"FAIL (strict): {soft} model(s) unverified", file=sys.stderr)
        return 1
    print(
        f"OK: {len(models)} Ollama-family model(s) match baseline "
        f"({soft} unverified)"
    )
    return 0


def mode_emit(config_path: Path, baseline_path: Path) -> int:
    config = load_config(config_path)
    models = resolve_ollama_models(config)
    baseline = load_baseline(baseline_path)

    for model in models:
        entry = baseline.get(model.api_name)
        if entry is None:
            continue
        flags = MediaFlags.from_ollama_capabilities(entry["capabilities"])
        lines = flags.declared_lines()
        if not lines:
            continue
        print(f"# {model.model_id} (api: {model.api_name}) "
              f"-- /api/show caps={entry['capabilities']}")
        print(f"[models.{model.model_id}.capabilities]")
        for line in lines:
            print(line)
        print()
    return 0


def mode_self_test() -> int:
    cases = [
        (["completion", "tools", "thinking", "vision"], MediaFlags(True, False)),
        (["vision", "thinking", "completion", "tools"], MediaFlags(True, False)),
        (["completion", "tools", "thinking"], MediaFlags(False, False)),
        (["completion", "vision", "audio"], MediaFlags(True, True)),
        (["image"], MediaFlags(True, False)),
        ([], MediaFlags(False, False)),
    ]
    for caps, want in cases:
        got = MediaFlags.from_ollama_capabilities(caps)
        assert got == want, f"map({caps}) = {got}, want {want}"
    # declared round-trips through the TOML key names; multimodal is ignored.
    declared = MediaFlags.from_declared(
        {"supports-image-input": True, "supports-multimodal-inputs": True}
    )
    assert declared == MediaFlags(True, False), declared
    print(f"self-test OK ({len(cases)} mapping cases)")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true", help="drift gate (default)")
    group.add_argument("--refresh", action="store_true", help="probe /api/show")
    group.add_argument("--emit", action="store_true", help="print toml cap blocks")
    group.add_argument("--self-test", action="store_true", help="mapping assertions")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument(
        "--strict", action="store_true", help="--check: unverified models fail too"
    )
    args = parser.parse_args(argv)

    if args.self_test:
        return mode_self_test()
    if args.refresh:
        return mode_refresh(args.config, args.baseline)
    if args.emit:
        return mode_emit(args.config, args.baseline)
    return mode_check(args.config, args.baseline, args.strict)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
