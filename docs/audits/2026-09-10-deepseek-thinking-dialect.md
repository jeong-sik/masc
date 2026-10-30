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

## Isolated dispatch observation

The operator applied the same one-field dialect correction to the isolated c083
runtime. The subsequent operation `kmsg-d38dd9285c0abac2c47c6d0923330e1d`
passed the earlier local encoding rejection and received DeepSeek's
`Payment required: Insufficient Balance` error, followed by the Ollama fallback's
quota error. This is evidence of reaching a different dispatch boundary, not a
successful completion or delivered PDF. Production configuration was untouched.

[`isolated-dispatch.txt`](../evidence/2026-09-10-deepseek-thinking-dialect/isolated-dispatch.txt)
contains exact non-thinking lines 744–745, 891, 894–895, 897 and 907 from
`/tmp/masc-memory-guide-home.server.log`; timestamps are Asia/Seoul (UTC+09:00).
The first pair records the original rejection; the remaining lines record the
post-correction attempt. Logger-truncated error text is preserved as observed.
