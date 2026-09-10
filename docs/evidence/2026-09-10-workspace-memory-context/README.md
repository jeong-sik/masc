# Workspace memory curator input

The current librarian lane is per Keeper. Its extraction input and current
snapshot are per Keeper as well. The fleet memory health endpoint reports counts
and errors, not the claims needed for a shared memory curator.

This work adds authenticated GET `/api/v1/dashboard/workspace-memory-context`.
It collects both current ordinary and source-bound snapshots, grouped by the
canonical keeper identity, without discarding conflicting claims or synthesizing
a common revision. Each store is available, missing, or unavailable. Source
bindings are explicitly stored bindings, not a claim that files were revalidated.
The read does not mutate any Keeper memory. The response is an input inventory,
not a synthesized shared memory artifact or a new active LLM lane.

A scenario test writes conflicting facts for two Keepers and a corrupt third
snapshot, then checks owner separation, exact snapshot preservation and explicit
failure. Local builds were not run; CI validation remains pending.

Remaining objective 17 work: independent curator execution, durable shared
claims with provenance and revisions, promotion/retraction, Keeper consumption,
Dashboard/TUI display, and a measured collaboration scenario. Local model choice
must preserve provenance; the earlier qwen3:8b unhinted probe failed structured
source coverage and does not establish suitability.

Prior art: [LangGraph memory overview](https://docs.langchain.com/oss/python/concepts/memory)
separates thread-scoped memory from long-term namespaced memory. This input keeps
Keeper ownership explicit so later shared curation does not erase where claims
came from. MASC's existing stores remain the authority; no second storage engine
is introduced by this read surface.
