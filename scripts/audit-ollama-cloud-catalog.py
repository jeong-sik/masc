#!/usr/bin/env python3
"""Audit the MASC Ollama Cloud model catalog against Ollama's public API.

This script is intentionally not wired into CI: it performs live network calls
to ollama.com. Use it when refreshing the runtime seed or proving that the
checked-in OAS catalog still covers the current Ollama Cloud model set.

MASC runtime.toml is not a provider/model capability source. Its model rows
contain runtime bindings and MASC-local context/request policy; provider/model
capabilities are checked only against the OAS catalog projection.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import tomllib


TAGS_URL = "https://ollama.com/api/tags"
SHOW_URL = "https://ollama.com/api/show"


@dataclass(frozen=True)
class OfficialModel:
    name: str
    max_context_tokens: int
    supports_tools: bool
    supports_thinking: bool
    supports_vision: bool
    capabilities: tuple[str, ...]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Audit checked-in MASC/OAS Ollama Cloud catalogs against ollama.com."
    )
    parser.add_argument(
        "--runtime",
        default="config/runtime.toml",
        help="Path to MASC runtime.toml seed (default: config/runtime.toml).",
    )
    parser.add_argument(
        "--oas-models",
        default="oas-models.toml",
        help="Path to MASC-local OAS model catalog (default: oas-models.toml).",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=30.0,
        help="HTTP timeout in seconds for each official API request.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a JSON report instead of the human-readable summary.",
    )
    return parser.parse_args()


def fetch_json(
    url: str, *, payload: dict[str, Any] | None = None, timeout: float
) -> dict[str, Any]:
    data = None
    headers: dict[str, str] = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = json.load(response)
    except urllib.error.URLError as exc:
        raise RuntimeError(f"failed to fetch {url}: {exc}") from exc
    if not isinstance(value, dict):
        raise RuntimeError(f"{url}: expected JSON object")
    return value


def context_length_from_show(model_name: str, show: dict[str, Any]) -> int:
    model_info = show.get("model_info")
    if not isinstance(model_info, dict):
        raise RuntimeError(f"{model_name}: /api/show missing model_info object")
    context_lengths = [
        value
        for key, value in model_info.items()
        if key.endswith(".context_length") and isinstance(value, int)
    ]
    if len(context_lengths) != 1:
        raise RuntimeError(
            f"{model_name}: expected one *.context_length in /api/show, got {context_lengths}"
        )
    return context_lengths[0]


def load_official_models(timeout: float) -> list[OfficialModel]:
    tags = fetch_json(TAGS_URL, timeout=timeout)
    rows = tags.get("models")
    if not isinstance(rows, list):
        raise RuntimeError(f"{TAGS_URL}: expected 'models' array")

    names: list[str] = []
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("name"), str):
            raise RuntimeError(f"{TAGS_URL}: malformed model row {row!r}")
        names.append(row["name"])

    official: list[OfficialModel] = []
    for name in sorted(names):
        show = fetch_json(SHOW_URL, payload={"model": name}, timeout=timeout)
        raw_capabilities = show.get("capabilities", [])
        if not isinstance(raw_capabilities, list) or not all(
            isinstance(item, str) for item in raw_capabilities
        ):
            raise RuntimeError(f"{name}: /api/show capabilities must be a string array")
        capabilities = tuple(sorted(raw_capabilities))
        official.append(
            OfficialModel(
                name=name,
                max_context_tokens=context_length_from_show(name, show),
                supports_tools="tools" in capabilities,
                supports_thinking="thinking" in capabilities,
                supports_vision=bool({"vision", "image"} & set(capabilities)),
                capabilities=capabilities,
            )
        )
    return official


def load_toml(path: str) -> dict[str, Any]:
    with Path(path).open("rb") as handle:
        data = tomllib.load(handle)
    if not isinstance(data, dict):
        raise RuntimeError(f"{path}: expected TOML object")
    return data


def bool_value(table: dict[str, Any], key: str) -> bool:
    value = table.get(key)
    return value if isinstance(value, bool) else False


def int_value(table: dict[str, Any], key: str) -> int | None:
    value = table.get(key)
    return value if isinstance(value, int) else None


def runtime_catalog(
    runtime: dict[str, Any],
) -> tuple[dict[str, str], set[str]]:
    models = runtime.get("models", {})
    bindings = runtime.get("ollama_cloud", {})
    if not isinstance(models, dict):
        raise RuntimeError("runtime.toml: [models.*] must parse as a TOML table")
    if not isinstance(bindings, dict):
        raise RuntimeError("runtime.toml: [ollama_cloud.*] must parse as a TOML table")

    api_name_to_slug: dict[str, str] = {}
    for slug, table in models.items():
        if not isinstance(slug, str) or not slug.startswith("ollama-cloud-"):
            continue
        if not isinstance(table, dict):
            raise RuntimeError(f"runtime.toml: models.{slug} must be a table")
        api_name = table.get("api-name")
        if not isinstance(api_name, str):
            raise RuntimeError(f"runtime.toml: models.{slug}.api-name must be a string")
        api_name_to_slug[api_name] = slug
    return api_name_to_slug, set(bindings)


def oas_catalog(
    oas_models: dict[str, Any],
) -> tuple[dict[str, dict[str, Any]], set[str]]:
    rows = oas_models.get("models", [])
    if not isinstance(rows, list):
        raise RuntimeError("oas-models.toml: [[models]] must parse as an array")

    provider_qualified: dict[str, dict[str, Any]] = {}
    bare_prefixes: set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            raise RuntimeError(f"oas-models.toml: malformed model row {row!r}")
        id_prefix = row.get("id_prefix")
        if not isinstance(id_prefix, str):
            raise RuntimeError("oas-models.toml: every [[models]] row needs id_prefix")
        if id_prefix.startswith("ollama_cloud/"):
            provider_qualified[id_prefix.removeprefix("ollama_cloud/")] = row
        elif "/" not in id_prefix:
            bare_prefixes.add(id_prefix)
    return provider_qualified, bare_prefixes


def check_catalog(
    official: list[OfficialModel],
    runtime: dict[str, Any],
    oas_models: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    official_by_name = {model.name: model for model in official}
    official_names = set(official_by_name)
    runtime_api_to_slug, runtime_bindings = runtime_catalog(runtime)
    oas_provider_qualified, oas_bare_prefixes = oas_catalog(oas_models)

    errors: list[str] = []
    runtime_names = set(runtime_api_to_slug)
    oas_provider_names = set(oas_provider_qualified)

    for name in sorted(official_names - runtime_names):
        errors.append(f"missing runtime seed for official model: {name}")
    for name in sorted(runtime_names - official_names):
        errors.append(f"runtime seed no longer present in official API: {name}")
    for name in sorted(official_names - oas_provider_names):
        errors.append(f"missing OAS provider-qualified model: ollama_cloud/{name}")
    for name in sorted(oas_provider_names - official_names):
        errors.append(
            f"OAS provider-qualified model no longer official: ollama_cloud/{name}"
        )
    # This file is a runtime-binding projection, not the full model catalog.
    # Provider-qualified rows are the dispatch SSOT for MASC's Ollama Cloud
    # bindings; a bare row is optional and must not be required for every live
    # Cloud model. Keep the bare-route count as observability without turning
    # an intentional projection shape into a false failure.
    oas_bare_route_names = {
        name
        for name in official_names
        if any(name.startswith(prefix) for prefix in oas_bare_prefixes)
    }

    for name, model in sorted(official_by_name.items()):
        slug = runtime_api_to_slug.get(name)
        if slug is not None and slug not in runtime_bindings:
            errors.append(f"missing runtime provider binding: [ollama_cloud.{slug}]")

        oas_row = oas_provider_qualified.get(name)
        if isinstance(oas_row, dict):
            if int_value(oas_row, "max_context_tokens") != model.max_context_tokens:
                errors.append(
                    f"OAS model ollama_cloud/{name}: max_context_tokens "
                    f"{int_value(oas_row, 'max_context_tokens')} != official {model.max_context_tokens}"
                )
            if bool_value(oas_row, "supports_tools") != model.supports_tools:
                errors.append(f"OAS model ollama_cloud/{name}: supports_tools mismatch")
            if bool_value(oas_row, "supports_reasoning") != model.supports_thinking:
                errors.append(
                    f"OAS model ollama_cloud/{name}: supports_reasoning mismatch"
                )
            if (
                bool_value(oas_row, "supports_extended_thinking")
                != model.supports_thinking
            ):
                errors.append(
                    f"OAS model ollama_cloud/{name}: supports_extended_thinking mismatch"
                )
            if bool_value(oas_row, "supports_image_input") != model.supports_vision:
                errors.append(
                    f"OAS model ollama_cloud/{name}: supports_image_input mismatch"
                )
            if (
                bool_value(oas_row, "supports_multimodal_inputs")
                != model.supports_vision
            ):
                errors.append(
                    f"OAS model ollama_cloud/{name}: supports_multimodal_inputs mismatch"
                )

    vision_models = sorted(model.name for model in official if model.supports_vision)
    report = {
        "checked_at_kst": datetime.now(ZoneInfo("Asia/Seoul")).isoformat(
            timespec="seconds"
        ),
        "official_source": [TAGS_URL, SHOW_URL],
        "official_count": len(official_names),
        "official_vision_count": len(vision_models),
        "runtime_canonical_count": len(runtime_names),
        "runtime_binding_count": sum(
            1 for slug in runtime_bindings if slug.startswith("ollama-cloud-")
        ),
        "oas_provider_qualified_count": len(oas_provider_names),
        "oas_bare_exact_membership_count": len(official_names & oas_bare_prefixes),
        "oas_bare_route_count": len(oas_bare_route_names),
        "vision_models": vision_models,
    }
    return report, errors


def print_text_report(report: dict[str, Any], errors: list[str]) -> None:
    print(f"checked_at_kst={report['checked_at_kst']}")
    print(f"official_source={','.join(report['official_source'])}")
    print(f"official_count={report['official_count']}")
    print(f"official_vision_count={report['official_vision_count']}")
    print(f"runtime_canonical_count={report['runtime_canonical_count']}")
    print(f"runtime_binding_count={report['runtime_binding_count']}")
    print(f"oas_provider_qualified_count={report['oas_provider_qualified_count']}")
    print(f"oas_bare_exact_membership_count={report['oas_bare_exact_membership_count']}")
    print(f"oas_bare_route_count={report['oas_bare_route_count']}")
    print("vision_models=" + ",".join(report["vision_models"]))
    if errors:
        print("status=FAIL")
        for error in errors:
            print(f"error={error}")
    else:
        print("status=OK")


def main() -> int:
    args = parse_args()
    try:
        official = load_official_models(args.timeout)
        runtime = load_toml(args.runtime)
        oas_models = load_toml(args.oas_models)
        report, errors = check_catalog(official, runtime, oas_models)
    except RuntimeError as exc:
        print(f"error={exc}", file=sys.stderr)
        return 2

    if args.json:
        print(
            json.dumps({"report": report, "errors": errors}, indent=2, sort_keys=True)
        )
    else:
        print_text_report(report, errors)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
