# Frozen final-request diagnosis

The input is the last real request from the failed candidate 54e8 run, immediately
after its actual 3/3 measurement. These are diagnostic inferences: no returned
tools ran, no Task or Goal changed, and none counts as actual G3 acceptance.
All arms use the same local Qwen3:8b, temperature 0.4 and added seed 20261024.

| Arm | Changes to the frozen actual input | Public outcome |
| --- | --- | --- |
| Baseline | Added seed only | Incorrectly claims completion and approvals |
| Phase receipt | Actual new serializer output replaces only the last Tool receipt | Still incorrectly claims Goal completion/verification |
| Full candidate | New receipt, exact changed Keeper Goal paragraph and canonical new tool description | Names Executing and pending final verification; still abbreviates the completion process and does not demonstrate the human step |

The full candidate's improvement is limited to this one frozen request. It is
not evidence that a real Keeper will execute the remaining work, retain Task
approval authority correctly or report the full Goal lifecycle accurately.
Both negative arms are preserved alongside it.

The `.result.json` files contain public text, tool proposals, termination and
raw request/response hashes. Raw thinking is excluded. The replacement receipt
preserves the actual measurement ID, actor, timestamp, revision and value.
`published-source-binding.json` binds that actual-source serializer output to
published candidate 3014 and its parent; the model did not receive a response
from a running 3014 server in this comparison.
