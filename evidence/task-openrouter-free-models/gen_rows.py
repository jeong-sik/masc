#!/usr/bin/env python3
"""Derive the free-model catalog rows and runtime bindings from the gateway
snapshot, so every value in the two TOML blocks has one source.

Usage: python3 gen_rows.py > rows.txt   (prints both blocks)

Rules, the same ones the 2026-09-10 OpenRouter rows follow
(packages/agent_core/models.toml, "OpenRouter Models"):
  - Window and output ceiling are the gateway's context_length and
    top_provider.max_completion_tokens.
  - Parameter support follows supported_parameters in both directions: a
    parameter the base claims but the gateway does not forward is lowered.
  - Input modalities only go down: image input is lowered when the gateway
    lists no image input, never raised.
  - The effort ladder is the router's (Capabilities.openrouter_capabilities):
    "none" is included only where probe-results.json records zero reasoning
    tokens in an accepted nonthinking request.
  - Only ids admitted in probe-results.json get a row. Metadata alone does
    not demonstrate the endpoint can actually call tools.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SNAPSHOT = os.path.join(HERE, "models-snapshot.json")
RESULTS = os.path.join(HERE, "probe-results.json")
PROBES = {row["id"]: row for row in json.load(open(RESULTS))["models"]}

# base claim (openai_chat_extended) -> gateway parameter that must be listed
PARAM_FLAGS = [
    ("supports_tool_choice", "tool_choice"),
    ("supports_required_tool_choice", "tool_choice"),
    ("supports_named_tool_choice", "tool_choice"),
    ("supports_parallel_tool_calls", "parallel_tool_calls"),
    ("supports_response_format_json", "response_format"),
    ("supports_structured_output", "structured_outputs"),
    ("supports_top_k", "top_k"),
    ("supports_min_p", "min_p"),
]
LADDER = ["minimal", "low", "medium", "high", "xhigh", "max"]


def runtime_name(model_id):
    base = model_id.removesuffix(":free").split("/", 1)[1]
    return "openrouter-free-" + base.replace(".", "-").replace("_", "-")


def catalog_row(m):
    params = set(m["supported_parameters"])
    inputs = set(m["architecture"]["input_modalities"])
    efforts = ["none"] + LADDER if PROBES[m["id"]]["none_verified"] else LADDER
    lines = [
        "[[models]]",
        f'id_prefix = "{m["id"]}"',
        'provider_name = "openrouter"',
        'base = "openai_chat_extended"',
        f'max_context_tokens = {m["context_length"]}',
        f'max_output_tokens = {m["top_provider"]["max_completion_tokens"]}',
        "input_per_million = 0.0",
        "output_per_million = 0.0",
        'reasoning_output_format = "split_reasoning_fields"',
        'reasoning_streaming_format = "delta_details:reasoning"',
        'reasoning_replay = "drop_without_tool"',
        "accepted_reasoning_efforts = [" + ", ".join(f'"{r}"' for r in efforts) + "]",
        'thinking_control_format = "reasoning_effort"',
        f'supports_seed = {"true" if "seed" in params else "false"}',
    ]
    for flag, param in PARAM_FLAGS:
        if param not in params:
            lines.append(f"{flag} = false")
    if "image" not in inputs:
        lines.append("supports_multimodal_inputs = false")
        lines.append("supports_image_input = false")
    return "\n".join(lines)


def runtime_entry(m):
    name = runtime_name(m["id"])
    return "\n".join(
        [
            f"[models.{name}]",
            f'api-name = "{m["id"]}"',
            "tools-support = true",
            "thinking-support = true",
            "streaming = true",
            'reasoning-effort = "high"',
            "",
            f"[openrouter.{name}]",
        ]
    )


def main():
    models = json.load(open(SNAPSHOT))
    usable = [m for m in models if PROBES.get(m["id"], {}).get("admitted", False)]
    skipped = [m["id"] for m in models if m not in usable]
    print(f"# catalog rows ({len(usable)}); not admitted by probes: {', '.join(skipped)}")
    print("\n\n".join(catalog_row(m) for m in usable))
    print("\n# ---- runtime.toml ----\n")
    print("\n\n".join(runtime_entry(m) for m in usable))
    return 0


if __name__ == "__main__":
    sys.exit(main())
