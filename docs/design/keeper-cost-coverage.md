# Cumulative reported cost and pricing coverage

Issue #38003 requires a known sum and its pricing coverage together. A reported
zero, a reading without a price, unresolved usage and an attempt without any
reading are different facts. Token volume and a numeric zero cannot establish
pricing coverage.

`Keeper_cost_coverage` is the pure accumulator for those facts. It counts
resolved spend readings, using the identities already maintained by
`Keeper_turn_spend`; it does not count HTTP frames or deduplicate events itself.
No started attempt contributes no observation. A started attempt with no reading
contributes `Attempt_unobserved`. A synthetic usage resolution for a winner
without readings must not invent a provider reading.

The accumulator keeps the reported sum, priced/unpriced/unresolved reading
counts, unobserved attempts and historical coverage. `Some 0` becomes a priced
reading. An explicit unobserved historical baseline keeps its known sum without
inventing priced readings or declaring its zero fully priced. Further priced
readings preserve that historical uncertainty.

`difference` and `add` carry additive evidence between snapshots so a stale
owner commit can preserve another commit's cost and coverage. They refuse
regressed counters/amounts, erased unknown history and numeric overflow. Owner
identity, CAS and exactly-once reading consumption remain caller responsibilities.
Nothing here controls whether a Keeper may run.

The initial library and its focused tests establish these accumulator
transitions. Production success/failure spend producers, owner commits, durable
meta, wire views and TUI/Dashboard consumers still need to carry the accumulator.
Current metadata remains unchanged. A new mandatory field alone would make
existing strict meta unreadable and risk declaration rematerialization; the
durable transition must preserve existing records and explicit unknown coverage,
without automatic reset or purge. No deployment or existing-meta conversion is
performed by this library.

The current cost wire value has two canonical semantic arms. A number means a
known sum with unobserved history and no captured readings; reading and writing
it preserve that meaning even when the number is zero. An exact object carries
`known_cost_usd`, `priced_readings`, `unpriced_readings`, `unresolved_readings`,
`unobserved_attempts` and `history` (`complete` or `unobserved`). Complete empty
and fully priced zero always use the object arm. New readings on an unobserved
baseline retain its history and use the object arm. A malformed object is
rejected, never reduced to its numeric sum. Complete coverage cannot have a
positive sum without a priced reading; inconsistent snapshot differences are
refused as well. The codec does not itself read or rewrite Keeper metadata.

The terminal success and non-success commit paths capture this evidence from
all actual `Keeper_turn_spend` readings, after the existing resolver. Token
metric updaters do not separately add costs. A resolved price is counted even
when zero. A reading whose provider omitted a price is unpriced; a reported
cumulative price without a usable price baseline is unresolved. Started empty
attempts contribute uncertainty; a synthetic winner resolution contributes no
provider reading. Cost and coverage enter the same Owner snapshot delta and
checked additive commit, retaining concurrent observations and unknown history.
The cumulative OpenTelemetry gauge is the provider-reported known subtotal.

Keeper meta keeps the same root key set and schema version. `total_cost_usd`
contains the canonical union above; it is a typed coverage value in the domain,
not a separate numeric authority. Fresh Keeper state begins with complete empty
coverage. Numeric persisted records remain readable as unobserved history, even
through ordinary pause/profile saves. No store reset, purge or automatic cut is
introduced. HTTP config and roster views emit that same value. TUI activity and
fleet aggregates carry it rather than adding plain floats. Dashboard lifetime
cost reads the same evidence and visibly qualifies missing, partial and unknown
pricing. The evaluation harness reports an exact numeric total only for complete
priced coverage; other readings remain unavailable in that scalar-only result.
