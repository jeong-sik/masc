# Native tool images and caller-query boundaries

Ollama native serialization previously projected an image-bearing ToolResult
into a text tool reply followed by a synthetic User media message. That extra
User is a new query to the official Qwen template, which removes current
trajectory reasoning with preserve_thinking=false.

Native Ollama Message has a role-independent images field. Its image tagging
loop processes every message without a role filter:

- [Ollama Message contract](https://github.com/ollama/ollama/blob/675150d6ad2747df1e218ef59de9194bc4a7e538/api/types.go#L184)
- [Ollama image tagging](https://github.com/ollama/ollama/blob/675150d6ad2747df1e218ef59de9194bc4a7e538/server/prompt.go#L87)
- [Official Qwen template](https://huggingface.co/Qwen/Qwen3.6-35B-A3B/blob/995ad96eacd98c81ed38be0c5b274b04031597b0/chat_template.jinja)

The serializer now emits images on their correlated ToolResult occurrence.
Structured non-image blocks stay in scalar content; image-only results retain
their summary. Base64 images retain source order and are not duplicated inside
the content JSON. Tool identity validation and capability admission still run.
Ordinary human input continues to serialize as User. Canonical history is not
rewritten. Other envelopes retain their existing media lowering.

## Executed reference-template reproduction

Download the official template at the pinned revision above, then run:

```sh
python3 docs/evidence/2026-10-24-ollama-tool-media-origin/render_qwen.py /path/to/chat_template.jinja
```

The script checks the source SHA256 before rendering the actual Jinja template.
The recorded result is in `reference-result.json`. Five checks reproduce the
synthetic-User failure, preserve the tool trajectory, discard prior-question
reasoning by default, close the trajectory on a real new human query, and retain
full reasoning history only with the explicit template option.

These are declared protocol fixtures with scalar content and the reference
template's reasoning_content field. They are not backend-captured requests.
They establish the template's role boundary, not native Ollama image forwarding
or execution of the modified OCaml serializer. No model request was made.

## Source fixtures and remaining scope

`test_backend_openai_codec.ml` exercises the production request builder and
serializer in its added/updated test source: parallel result ownership, no
synthetic User, structured text, multiple/nested images, reused tool IDs, actual
later human input, undeclared image capability, unsupported image source and
orphaned result rejection. These OCaml tests were not executed. Parser and
whitespace checks do not establish typecheck or behavior success.

This is a bounded part of #27904. Synthetic context/recovery/instruction lowering,
other provider envelopes, Anthropic signed-prefix preservation, autonomous
episode attribution, OCaml test execution and runtime validation remain open.
