# Local curator configuration preparation

The owned integration workspace already declares the exact target
`ollama.qwen3-8-27b` in its model overlay, matching the model used by the ongoing
standalone run. Its runtime TOML lacks the local provider/model binding and
workspace curator lane. `runtime-additions.toml` contains only those additions,
derived from this source checkout's existing seed provider and model tables.

The additions parse alone and appended to the captured runtime. Parsed existing
default and exact lanes are preserved. This is a reviewable configuration
candidate, not evidence of native model admission or provider execution. The
receipt hashes bind the preflight to the files that were read. Re-read them
before applying; do not blindly append to a changed live configuration.

Installation must use a tested curator-capable artifact and preserve the existing
Chat, LSP and media behavior. The current installed 851f412 binary does not carry
this new lane. No setting was applied and no running model was restarted.
