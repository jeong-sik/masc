#!/usr/bin/env python3
"""Ratchet exact provider/model catalog coverage for runtime bindings.

`Model_catalog.lookup_for_provider` is exact-only. A miss falls through to the
provider base before MASC projects runtime capabilities, so it is never a
harmless "no catalog row" case. Compare runtime bindings with the merged
embedded-plus-deployment catalog and make every temporary base fallback named.

The filename is retained because CI already invokes it; this check no longer
models the provider-independent longest-prefix lookup.
"""

from __future__ import annotations

import pathlib
import sys
import tomllib

REPO = pathlib.Path(__file__).resolve().parents[2]
EMBEDDED = REPO / "packages" / "agent_core" / "models.toml"
OVERLAY = REPO / "config" / "agent-core-models-overlay.toml"
RUNTIME = REPO / "config" / "runtime.toml"

Model = tuple[str, str]
KNOWN_PROVIDER_BASE_FALLBACKS: dict[Model, str] = {}


def read_toml(path: pathlib.Path) -> dict[str, object]:
    if not path.exists():
        raise ValueError(f"{path.relative_to(REPO)} is missing")
    return tomllib.loads(path.read_text(encoding="utf-8"))


def catalog_identities() -> set[Model]:
    identities: set[Model] = set()
    for path in (EMBEDDED, OVERLAY):
        rows = read_toml(path).get("models")
        if not isinstance(rows, list):
            raise ValueError(f"{path.relative_to(REPO)} requires [[models]] rows")
        for row in rows:
            if not isinstance(row, dict):
                raise ValueError(f"{path.relative_to(REPO)} model row is malformed")
            provider = row.get("provider_name")
            model = row.get("id_prefix")
            if provider is None:
                continue
            if not isinstance(provider, str) or not isinstance(model, str):
                raise ValueError(
                    f"{path.relative_to(REPO)} scoped row requires string identity"
                )
            identities.add((provider.strip().lower(), model.strip().lower()))
    return identities


def runtime_api_name(model_key: str, row: dict[object, object]) -> str:
    for field in ("api-name", "model-name"):
        value = row.get(field)
        if value is not None:
            if not isinstance(value, str):
                raise ValueError(f"runtime model {model_key!r} has non-string {field}")
            return value
    return model_key


def runtime_models() -> set[Model]:
    data = read_toml(RUNTIME)
    model_rows = data.get("models")
    provider_rows = data.get("providers")
    if not isinstance(model_rows, dict) or not isinstance(provider_rows, dict):
        raise ValueError("runtime requires [models] and [providers] tables")
    models: set[Model] = set()
    for provider in provider_rows:
        if not isinstance(provider, str):
            raise ValueError("runtime provider id must be a string")
        bindings = data.get(provider)
        if bindings is None:
            continue
        if not isinstance(bindings, dict):
            raise ValueError(f"runtime provider table {provider!r} is malformed")
        for model_key in bindings:
            if not isinstance(model_key, str):
                raise ValueError("runtime model binding key must be a string")
            row = model_rows.get(model_key)
            if not isinstance(row, dict):
                continue
            api_name = runtime_api_name(model_key, row)
            models.add((provider.strip().lower(), api_name.strip().lower()))
    return models


def self_test() -> None:
    catalog = {("right", "family"), ("wrong", "family:tag")}
    assert ("right", "family:tag") not in catalog
    assert runtime_api_name("fallback", {}) == "fallback"
    assert runtime_api_name("key", {"model-name": "legacy"}) == "legacy"
    assert runtime_api_name("key", {"api-name": "wire"}) == "wire"


def main() -> int:
    print("=== runtime exact catalog identities ===")
    try:
        self_test()
        catalog = catalog_identities()
        models = runtime_models()
    except (OSError, ValueError, tomllib.TOMLDecodeError) as error:
        print(f"FAIL: {error}")
        return 2
    if not catalog or not models:
        print("FAIL: no identities found; the scan lost its subject")
        return 2

    missing = models - catalog
    known = set(KNOWN_PROVIDER_BASE_FALLBACKS)
    unrecorded = missing - known
    stale = known - missing
    if unrecorded or stale:
        print()
        if unrecorded:
            print("FAIL: runtime identities falling through to provider base:")
            for provider, model in sorted(unrecorded):
                print(f"  {provider}/{model}")
        if stale:
            print("FAIL: exact rows exist; remove stale fallback debt entries:")
            for provider, model in sorted(stale):
                print(f"  {provider}/{model}")
        return 1

    for identity in sorted(missing):
        print(
            f"  DEBT {identity[0]}/{identity[1]} — "
            f"{KNOWN_PROVIDER_BASE_FALLBACKS[identity]}"
        )
    print()
    print(
        f"PASS: {len(models)} runtime provider/model identities; "
        f"{len(models) - len(missing)} exact catalog rows; "
        f"{len(missing)} recorded provider-base fallback."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
