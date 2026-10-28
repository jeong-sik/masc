# OpenRouter bindings probe, 2026-10-28

Synthetic direct probes with `docs/evidence/task-openrouter-free-models/probe.sh`.
Three non-streaming cases per id: basic (`Reply with exactly: OK`), one
`get_weather` tool call, and `reasoning_effort: "none"`. `status.txt` holds one
line per request. Account limits and request ids are omitted.

| id | basic | tool call | none | result |
|---|---|---|---|---|
| `deepseek/deepseek-v4.1-flash-1017` | 200 OK | `get_weather` | 0 reasoning tokens | row and binding |
| `nvidia/nemotron-3.5-super-vl:free` | 200 OK | `get_weather` | 0 reasoning tokens | row and binding |
| `nvidia/nemotron-3-ultra-550b-a55b:free` | 200 OK | no tool call, `finish=stop` | 0 reasoning tokens | no row |
| `thinkingmachines/inkling:free` | 403 | 403 | 403 | no row |
| `recursive/flint-v1.0:free` | 200 OK | 429 from the provider on the retry | 400, reasoning mandatory | no row |
| `xingchen-agi/xing4.0-29b-a4b:free` | `finish=length` at 64 tokens | `get_weather` | 0 reasoning tokens | no row |

`inkling` answers 403 with "only available on agentic harnesses". The `flint`
tool call is unmeasured, not refused.

`deepseek-v4.1-flash-1017` answered from three providers across the three cases.
`usage.cost` per case, against the cost at the $0.30/$1.20 top-level price:

| case | provider | prompt / completion tokens | `usage.cost` | at top-level price |
|---|---|---|---|---|
| basic | InferenceNet | 9 / 35 | $0.00001997 | $0.0000447 |
| tool call | Ionstream | 303 / 47 | $0.00006942 | $0.0001473 |
| none | Wafer | 16 / 2 | $0.00000212 | $0.0000072 |

The listing carries time-of-day price overrides for this id, so the probe does
not separate a time-of-day price from a per-provider price.

These are single-turn, non-streaming probes. They do not cover multi-turn Keeper
continuity, streaming, or lane fallback. No live lane configuration was changed
by this evidence.
