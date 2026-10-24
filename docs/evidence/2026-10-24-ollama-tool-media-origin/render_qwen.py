"""Reference-template boundary proof, not an OCaml serializer execution.

Usage: python3 render_qwen.py /path/to/pinned/chat_template.jinja
Requires Jinja2. Does not fetch code or call a model. Scalar tool content models
the query-boundary decision only; native Ollama image forwarding is not tested.
"""

import hashlib
import json
from pathlib import Path
import sys

from jinja2 import Environment


TEMPLATE_COMMIT = "995ad96eacd98c81ed38be0c5b274b04031597b0"
TEMPLATE_SHA256 = "e84f32a23fdda27689f868aa4a1a5621f41133e51a48d7f3efcbea2839574259"


def main():
    source = Path(sys.argv[1]).read_bytes()
    if hashlib.sha256(source).hexdigest() != TEMPLATE_SHA256:
        raise ValueError("Expected the recorded official Qwen template")

    def reject(message):
        raise ValueError(message)

    env = Environment()
    env.globals["raise_exception"] = reject
    template = env.from_string(source.decode())
    # Declared protocol fixtures, not captured backend output. The official
    # template's reasoning_content spelling is used directly.
    prefix = [
        {"role": "user", "content": "Earlier question"},
        {"role": "assistant", "content": "Earlier answer", "reasoning_content": "OLD_REASONING"},
        {"role": "user", "content": "Inspect both artifacts"},
        {"role": "assistant", "content": "", "reasoning_content": "CURRENT_REASONING",
         "tool_calls": [{"function": {"name": "Read", "arguments": {"path": "artifact"}}}]},
        {"role": "tool", "content": "Image result and its text"},
    ]

    def render(messages, preserve=False):
        return template.render(messages=messages, tools=[], add_generation_prompt=True,
                               preserve_thinking=preserve, enable_thinking=True)

    before = render(prefix + [{"role": "user", "content": "Tool result image followup"}])
    after = render(prefix)
    human = render(prefix + [{"role": "user", "content": "A new human question"}])
    preserve = render(prefix, preserve=True)
    checks = {
        "old_synthetic_user_loses_current_reasoning": "CURRENT_REASONING" not in before,
        "tool_role_preserves_current_reasoning": "CURRENT_REASONING" in after,
        "default_discards_prior_question_reasoning": "OLD_REASONING" not in after,
        "real_new_human_closes_current_trajectory": "CURRENT_REASONING" not in human,
        "explicit_preserve_thinking_keeps_full_history":
            "OLD_REASONING" in preserve and "CURRENT_REASONING" in preserve,
    }
    print(json.dumps({"scope": "official reference template on declared fixtures",
                      "serializer_executed": False, "provider_called": False,
                      "template_commit": TEMPLATE_COMMIT, "template_sha256": TEMPLATE_SHA256,
                      "checks": checks}, indent=2))
    if not all(checks.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
