# OpenRouter free model admission

The 2026-09-26 synthetic provider probe tried the 16 tool-capable IDs in the
saved gateway snapshot. `probe-results.json` records sanitized final replies;
account identifiers, API keys, request IDs, and private quota readings are omitted.

Three IDs returned a basic answer (trimmed `OK`) and the requested `get_weather`
call: `cohere/north-mini-code:free`, `dots-studio/dots-3-note-preview:free`, and
`liquid/lfm-2.5-2.6b:free`. Only these receive catalog rows and runtime bindings.
Cohere and Dots explicitly reported zero reasoning tokens with effort `none`.
Liquid rejected disabled reasoning, so its effort ladder excludes `none`.

The other 13 are not admitted by this run: some returned upstream 429, some
exhausted the probe output limit or returned no tool call, and two returned 403
requiring an agentic harness. This is not a permanent claim that those models
lack tools. Their rows can be regenerated after new evidence admits them.

`gen_rows.py` joins the original gateway metadata with the recorded admission
results. `probe.sh` also works with macOS Bash, recognizes the observed upstream
`provider_error_code` metadata, and stops with `unknown_429` rather than claiming
an account limit when origin metadata is absent.

These are non-streaming direct provider probes. They do not demonstrate
multi-turn Keeper continuity, streaming, or actual lane fallback. No live lane
configuration or deployment was changed.
