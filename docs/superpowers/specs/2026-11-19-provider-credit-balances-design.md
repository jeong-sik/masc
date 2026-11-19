# Provider Credit Balances Design

## Intent

The operator wants the API-backed runtime providers configured under `~/me/.masc` to show how much credit remains, wherever their existing usage response exposes it. The existing Usage surfaces show window utilization, but discard Ollama and Kimi balances and do not read OpenRouter's account-credit endpoint.

## Goals

- Keep every existing usage window and add the remaining credit that the provider actually reports.
- OpenRouter: retain `GET /api/v1/key` and add the official `GET /api/v1/credits` read for the same credential.
- Ollama: decode both documented balance shapes, including `included.balance_usd`, `included.allowance_usd`, `included.period.until`, and `purchased.balance_usd`.
- Kimi Coding: decode the real `booster_wallet` shape, including fixed-point `amount`/`amountLeft` and currency selection used by the official client.
- Codex: decode the official `CreditsSnapshot` from rate-limit reads/updates, retaining finite balances and the explicit unlimited state.
- Show remaining credit first in the native TUI and dashboard. Preserve it in durable history and the runtime-resolved API.
- Make zero balances visible. Never turn an absent report into zero.

## Non-goals

- No provider credit APIs beyond the existing `usage-read` providers and Codex's existing app-server rate-limit reads.
- No Claude Code or OpenAI API-key balance numbers: their public APIs do not expose an account-credit balance. Codex app-server credits are a different, explicitly supported contract.
- No model turns, purchases, top-ups, credential changes, or live runtime config rewrite from the development session.
- No new availability gate based on OpenRouter's auxiliary account-credit read or Kimi's wallet display.
- No monthly-spend/charge-limit display for Kimi; the requested deliverable is remaining credit.
- No local Dune build or full CI watch from this external coding session.

## Contract

Introduce a utilization variant with this semantic shape:

```ocaml
Credit_balance of {
  currency : string;
  total : float option;
  remaining : float;
}
```

`total` is the face amount of the same credit bucket when the provider states it. It is `None` for Ollama purchased credit, whose response states only unexpired remaining credit. A meter is allowed only for a positive stated total; its used share is `(total - remaining) / total`. Remaining is always rendered directly and is never reconstructed from a meter.

Provider mappings:

- OpenRouter `/credits`: currency `USD`, total `total_credits`, remaining `total_credits - total_usage`; validate both inputs and their range. This auxiliary report is observation-only.
- Ollama credit plan: included credit has total `allowance_usd`, remaining `balance_usd`, reset `period.until`. Purchased credit has no total and remaining `purchased.balance_usd`. Included credit pays before purchased credit, so included windows stop gating model calls while purchased credit is positive, matching the existing legacy-plan rule.
- Ollama legacy plan: retain session/weekly windows and add the purchased balance row under the same rule.
- Kimi: currency comes from `monthlyChargeLimit.currency`, then `monthlyUsed.currency`, then the official client's `USD` fallback. `amount` and `amountLeft` are decimal fixed-point values in units of `10^-6` cents, so divide by `100_000_000` for major currency units. Missing `amountLeft` means zero, as in the official client. Empty or non-BOOSTER wallet objects contribute no credit row.
- Codex: `credits.unlimited = true` yields `credit_unlimited`. Otherwise `hasCredits = true` with a non-null JSON decimal `balance` yields a finite balance in `credits` units with no total. `hasCredits = false` or `balance = null` writes a `credit_retracted` tombstone shared by both Codex read/update sources, not a fabricated zero, so stale balances cannot survive sparse updates or restart. Existing Codex sources remain sparse and do not gain routing behavior.

Credit rows use `Counts_other_use` when they cannot independently establish that every model call is refused. Ollama included credit retains the existing purchased-balance-dependent gating behavior. No routing decision reads the new OpenRouter source. Kimi plan-window behavior is unchanged by this display-only addition.

## Configuration

OpenRouter keeps its current `[providers.openrouter.usage-read]`. An optional nested `[providers.openrouter.usage-read.credit]` declares only `url`; it uses the same credential and refresh period. The loader restricts it to `shape = "openrouter-key"`, enforces HTTPS and the provider endpoint host, and reads primary and credit endpoints independently so one failure does not suppress the other report.

## Sources

- OpenRouter official Credits reference: https://openrouter.ai/docs/api-reference/get-credits
- Ollama official Balance reference: https://docs.ollama.com/api/balance
- Kimi official client `managed-usage.ts`: https://raw.githubusercontent.com/MoonshotAI/kimi-code/main/packages/oauth/src/managed-usage.ts
- Kimi live response evidence in upstream issue: https://github.com/MoonshotAI/kimi-code/issues/3836
- Codex official `CreditsSnapshot`: https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/typescript/v2/CreditsSnapshot.ts
- Claude Code balance API request showing no public endpoint: https://github.com/anthropics/claude-code/issues/47574

## Verification

Use captured real response shapes to test decoding, validation, API/history round trips, and TUI/dashboard rendering. Run focused dashboard typecheck/tests and browser observation. Follow the constitution for OCaml verification: do not run local Dune builds in this session; identify the focused OCaml suites required for independent/CI execution and report any unexecuted checks explicitly.
