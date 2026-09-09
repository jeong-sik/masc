# Direct DeepSeek thinking request repair

The isolated c083 Keeper first selected `deepseek.deepseek-v4-pro`, but its
request failed before provider dispatch: the resolved dialect could not encode
`enable_thinking=true` without an effort override. A later Ollama candidate then
failed on quota. The assigned DeepSeek runtime was attempted, not ignored.

The repository runtime seed declared `thinking-control-format = "reasoning-effort"`,
overriding the embedded provider-qualified catalog's correct `thinking_object`.
DeepSeek Chat Completions uses `thinking.type` to enable/disable reasoning and a
separate `reasoning_effort` field for effort, per the
[official thinking-mode guide](https://api-docs.deepseek.com/guides/thinking_mode/)
and [Chat Completions API](https://api-docs.deepseek.com/api/create-chat-completion/).
The seed now declares `thinking-object`; `thinking-support = true` is retained.

The behavioral test loads the actual repository runtime seed and deployment
catalog, resolves the direct provider configuration, and serializes requests
with enabled/default effort, enabled/high effort, and explicit disabled thinking.
It checks the actual wire fields rather than searching configuration text.
CI execution is pending. This change does not edit installed runtime TOML or
prove a successful live DeepSeek request. Agent Core already supports this
dialect and requires no adapter change.

A separate observed Kimi failure comes from omitted `thinking-support` becoming
an explicit false policy in the runtime parser. That absence-versus-disable
problem is not resolved by this DeepSeek dialect correction.
