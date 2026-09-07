#!/usr/bin/env python3
"""Compare explicit Ollama Cloud context overrides with provider metadata.

Requires OLLAMA_CLOUD_API_KEY and network access. This does not resolve MASC's
provider-scoped AGENT_CORE catalog: a binding without a max-context override
is reported as not measured, not as an undersized runtime window.

Exit 0 means all explicit values were compared and agreed, 1 means a stated
value disagreed, and 2 means some effective values could not be measured.
"""

import json
import os
import subprocess
import sys
import tomllib

SHOW_URL = "https://ollama.com/api/show"
TIMEOUT_S = 25


def stated_context(api_name: str, key: str) -> int | None:
    """Ask the provider for this model's context length, or None."""
    proc = subprocess.run(
        ["curl", "-s", "-m", str(TIMEOUT_S), SHOW_URL,
         "-H", f"Authorization: Bearer {key}",
         "-H", "Content-Type: application/json",
         "-d", json.dumps({"model": api_name})],
        capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    try:
        info = json.loads(proc.stdout).get("model_info", {})
    except json.JSONDecodeError:
        return None
    # The key is namespaced by architecture (llama.context_length,
    # minimax-m3.context_length, ...), so match on the suffix.
    for field, value in info.items():
        if field.endswith(".context_length"):
            return value
    return None


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "config/runtime.toml"
    key = os.environ.get("OLLAMA_CLOUD_API_KEY")
    if not key:
        print("OLLAMA_CLOUD_API_KEY is not set", file=sys.stderr)
        return 2

    with open(path, "rb") as handle:
        config = tomllib.load(handle)
    models = config.get("models", {})
    bindings = [n for n, v in config.get("ollama_cloud", {}).items()
                if isinstance(v, dict)]
    if not bindings:
        print(f"{path} declares no ollama_cloud bindings", file=sys.stderr)
        return 2

    over, under, unreachable, catalog_derived = [], [], [], []
    for name in sorted(bindings):
        entry = models.get(name, {})
        configured = entry.get("max-context")
        stated = stated_context(entry.get("api-name", name), key)
        if stated is None:
            unreachable.append(name)
        elif configured is None:
            catalog_derived.append((name, stated))
        elif configured > stated:
            over.append((name, configured, stated))
        elif configured < stated:
            under.append((name, configured, stated))

    print(f"{len(bindings)} ollama_cloud bindings in {path}")
    for label, rows in (("override above provider statement", over),
                        ("override below provider statement", under)):
        for name, configured, stated in rows:
            print(f"  {label}: {name} configured={configured} stated={stated}")
    for name, stated in catalog_derived:
        print(f"  catalog-derived: {name} effective_context=not_measured stated={stated}")
    for name in unreachable:
        print(f"  unreachable: {name}")

    disagreements = len(over) + len(under)
    if disagreements:
        return 1
    if unreachable or catalog_derived:
        return 2
    print("every explicit context override agrees with the provider statement")
    return 0


if __name__ == "__main__":
    sys.exit(main())
