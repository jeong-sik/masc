# Track9 Quota Tier Contract

MASC owns the product/operator quota contract for agent work. OAS stays
provider-neutral and should not inherit product tier names.

## Default Tier Budget

The default operator budget is `1000 req/min`:

| Tier | Label | Workload | Share | Default |
| --- | --- | --- | --- | --- |
| P0 | P0 Critical | Architecture and deploy work | 40% | 400 req/min |
| P1 | P1 Standard | Feature and test work | 40% | 400 req/min |
| P2 | P2 Background | Monitoring, cleanup, and docs | 20% | 200 req/min |

The source contract is `Rate_limit.agent_quota_tier_contracts`.
`Rate_limit.compute_agent_quota_allocations` computes deterministic
integer allocations for other positive totals and preserves the exact
sum by assigning rounding remainder in P0, P1, P2 order.

## Control Labels

Track9 control concepts are exposed as labels only:

- `lease-expiry`
- `backpressure`
- `adaptive-rate`

This slice does not introduce Redis, Valkey, cloud deployment, or pricing
logic. Runtime infrastructure can consume these labels later without
changing the typed tier contract.
