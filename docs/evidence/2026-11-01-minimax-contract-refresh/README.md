# MiniMax integration and unresolved endpoint contracts

Observed on 2026-11-01 against main
`dbd032511fea4e3d04687448275c0f41abff56cc`. This is source, REST merge-state
and official-document evidence. No new OCaml execution, vendor request,
installation, UI observation or deployment is claimed.

## Integration

Each PR's REST `merged` value was true, and each merge commit is an ancestor
of the inspected main. These are merged changes, not pending approvals:

| PR | Result | Merge commit |
| --- | --- | --- |
| [#45932](https://github.com/jeong-sik/masc/pull/45932) | Sync full reasoning | `f7e0e07f57c17a6d8e3cce74d78a846db7403a78` |
| [#45950](https://github.com/jeong-sik/masc/pull/45950) | SSE and owned replacement | `a072b619c2cf1bb7b02d109ebafd0dc75d1c21b8` |
| [#45962](https://github.com/jeong-sik/masc/pull/45962) | Connected delivery | `e6a70fb63dc163fa8e4d05c2592c80fd79cac5cd` |
| [#45969](https://github.com/jeong-sik/masc/pull/45969) | Explicit Responses binding | `a0fb7311813d279b94f16395fcc490c913793dae` |
| [#46035](https://github.com/jeong-sik/masc/pull/46035) | Configuration guide | `a079d8f308681c6be40c8b9db56e202e86edad4d` |

Source entrypoints are `packages/agent_core/models.toml`,
`packages/agent_core/test/test_minimax_responses_binding.ml`,
`packages/agent_core/lib/llm_provider/backend_openai_responses.ml`, and the
sync/SSE fixtures linked by the earlier retained evidence. Inspection confirms
the native provider and both model rows are present, not that a live account
can use them. Historical test receipts retain their original source scope.

## Official evidence

Downloaded full schema bytes were hashed, then the request properties were
read directly. Both hashes still match the 2026-10-26 observation:

| Source | Bytes | SHA256 | Observation |
| --- | ---: | --- | --- |
| [Chat OpenAPI](https://platform.minimax.io/docs/api-reference/text/api/openapi-chat-openai.json) | 70206 | `0a51cdac775b071b9c0cae381c990964823ab257298dffa400792d4ddadc3bcc` | Request schema does not declare `tool_choice`. |
| [Responses OpenAPI](https://platform.minimax.io/docs/api-reference/text/api/openapi-responses.json) | 79832 | `a8c51922e4530595537030fd5c0ab16a6faaf263e662bf753c588fe61169e5ea` | Request tool choice declares `auto`; M2.x reasoning is described without exact M2 model identities. |

The vendor also publishes a
[provider verifier at commit 336ccc735f9f13fdfacdacdda8733eb9e2813095](https://github.com/MiniMax-AI/MiniMax-Provider-Verifier/tree/336ccc735f9f13fdfacdacdda8733eb9e2813095/m3_format_check).
Its `m3_text_tests.py` test `test_13_08_tool_choice_values` expects Chat
requests with `none`, `required` and `auto` to succeed. Its
`test_16_14_tool_choice_nonexistent_tool` tolerates either 200 or 400; that
does not prove valid named-function forcing. The `conftest.py` endpoint is
supplied through `M3_BASE_URL` and its model defaults to `MiniMax-M3`.
Consequently this source gives a vendor-owned conformance expectation, not
an observed result on the native endpoint or an M3.1 contract. No capability
row is changed from that inference.

## Remaining acceptance for #27924

- Obtain native Chat tool-choice observations or an explicit endpoint contract,
  including model identity and the required/named distinction. Use the
  provider verifier as a reproduction reference, not as a successful run.
- Establish exact M2 Responses identities before declaring additional rows.
- Keep live HTTP, process restart, installation and UI evidence separate from
  the existing offline codec and binding receipts.

The issue remains open. The completed integration is no longer a pending task.
