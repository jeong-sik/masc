# Indexed original delivery membership without changing evidence

Source baseline: `df36e1df5d5ab2d9035b53af28b03778cf1c427f` (#43833).
No TUI, test, benchmark, model or timing trial was executed.

| Boundary | Before | After in source |
| --- | --- | --- |
| Original request identity | Exact request ID, Keeper and message equality | Same relation, shared comparator and opaque immutable membership set |
| Local duplicate / persisted input exclusion | Scan queue/history for each submitted entry | Build separate local identity and confirmed persisted-user ID indexes |
| No inflight entries | No submitted lookups | Bypass submitted indexes and started-log scan |
| Rechecking and priority joins | Repeated scans over waiting/control/receipt lists | Local exact-identity membership indexes |
| Full-mode provisional receipts | Scan priority controls per receipt | One priority identity index per observation |
| Compact receipt confirmation | Search receipts for each waiting original | One receipt fold and successful-original membership checks |
| Queue/POST/rechecking/start authority | Original typed stages and journal evidence | Same stages and evidence; indexes do not send/resume/promote work |
| CPU, input, Loading and useful-work timing | Unmeasured | Unmeasured |

The comparator is the single identity relation used by equality and the set:
request ID, Keeper, full message bytes. There is no normalization, digest or
payload copy. Existing attachment/reference identity semantics are unchanged.
The set supplies membership only; raw waiting lists still supply original
request objects, chronology and multiplicity. No key/body is logged or added
to a wire schema, cache, state slot or worker.

For `I` inflight entries, `L` local entries and `H` loaded rows, local/history
membership changes from up to `O(I*(L+H))` to index construction and logarithmic
lookups. The persisted-user index preserves the original selected loaded-Keeper,
same row Keeper, user role and `Persisted_row` predicate; legacy/session rows
do not establish consumption. Existing execution-start evidence is unchanged.

For `W` waiting originals, `C` priority-control members and `P` receipts, the
compact observation replaces waiting/provisional/all-success nested joins with
set construction and logarithmic membership. In full mode the `P*C` provisional
scan becomes one control index plus receipt membership lookups. Bounds assume
unit key comparisons; full string comparison, tree nodes and setup overhead
remain unmeasured. Small observations are not claimed faster.

Provisional receipts remain excluded. A matching non-provisional error still
precedes pending control, then all-success, partial receipts and queued state.
Conflicting duplicate receipts still retain the error; duplicate successful
receipts cannot confirm a different original. No new delivery correctness bug
or measured speedup is claimed from these source transformations.

One authored, unexecuted compound scenario uses the actual local queue, original
inflight logs, queue handoff and reconnect stage with colliding request IDs but
different message/Keeper identity. It requires distinct original delivery stages
to survive the join. This is protocol/source ownership, not a layout, wording,
row-order, snapshot, PTY, helper-mirror or invocation-count test. It does not prove
server delivery or receipt rendering. Parsing proves syntax only; typing,
scenario/runtime/UI/input/paint/useful-work and measured timing remain unverified.
