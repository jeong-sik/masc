#!/usr/bin/env python3
"""Compare each ollama_cloud model's configured max-context against what the
provider states, and report every disagreement.

Not a CI gate. It needs OLLAMA_CLOUD_API_KEY and reaches ollama.com, so it
cannot run on a pull request; make it an operator step when a model is added
or a context value is edited.

Why it exists: [models.*].max-context is hand-typed against release notes,
and 5 of 23 bindings had drifted when this was first run on 2026-09-07.

  ollama-cloud-deepseek-v4-pro   524288 vs 1048576   half the window unused
  minimax-m3                     524288 vs  512000   over by 12,288
  ollama-cloud-minimax-m3        524288 vs  512000   over by 12,288
  deepseek-v4-flash             1000000 vs 1048576   decimal round number
  ollama-cloud-glm-5-2          1000000 vs 1048576   decimal round number

Two shapes produced those. 524288 is 512x1024, written where the provider
means a decimal 512,000 -- and it is also the common default for
max-request-body-bytes right beside it, so it reads as intentional. 1000000
is a decimal round-off of 1048576.

The two directions are not equally bad. Under-stating wastes window: a lane's
turn budget is the minimum across its candidates, so one low row pulls its
whole lane down (keeper_unified_turn_pre_dispatch.ml). Over-stating builds a
turn the provider then rejects. Both are reported; over-stating is marked.
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

    over, under, unreachable = [], [], []
    for name in sorted(bindings):
        entry = models.get(name, {})
        configured = entry.get("max-context")
        stated = stated_context(entry.get("api-name", name), key)
        if stated is None:
            unreachable.append(name)
        elif configured is None:
            under.append((name, configured, stated))
        elif configured > stated:
            over.append((name, configured, stated))
        elif configured < stated:
            under.append((name, configured, stated))

    print(f"{len(bindings)} ollama_cloud bindings in {path}")
    for label, rows in (("OVER (provider will reject)", over),
                        ("under (window unused)", under)):
        for name, configured, stated in rows:
            print(f"  {label}: {name} configured={configured} stated={stated}")
    for name in unreachable:
        print(f"  unreachable: {name}")

    disagreements = len(over) + len(under)
    if disagreements == 0 and not unreachable:
        print("every binding agrees with the provider")
    # Unreachable is not a disagreement: a probe that did not answer says
    # nothing about the value, and failing on it would turn a network blip
    # into a wrong verdict.
    return 1 if disagreements else 0


if __name__ == "__main__":
    sys.exit(main())
