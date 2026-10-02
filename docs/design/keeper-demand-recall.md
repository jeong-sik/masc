# Keeper demand recall

Stored memory and per-turn model context have different lifetimes. A Keeper keeps its complete current memory; it retrieves the facts needed for the current input. Omitting a stored fact from a prompt does not delete it, revoke it, or establish its truth.

## Capability paths

| Runtime surface | First-round prompt work | Memory delivery |
| --- | --- | --- |
| `keeper_memory_search` available | Read current store availability/counts. No source-file reads, complete rendering, blob publication, or artifact retention. | Keeper chooses a query from the admitted input/task; existing search selects current matches and validates source claims at lookup. |
| Artifact reader only | Revalidate sources, build and retain the safe snapshot. | Small reference with paged access; full enumeration is optional. |
| Neither retrieval tool | Read availability/counts only. | Explicit retrieval-unavailable notice. Continue from admitted input; request retrieval capability if prior memory is required. Never inject every fact as a fallback. |

Every notice marks previous Recall blocks and retrieved claims as historical and requires a current lookup before using remembered claims. It grants no instruction or permission. Ordinary/source absence, unreadability, and disabled recall stay explicit. The notice does not claim source bytes were verified. Its size scales with count digits and fixed guidance, not stored claim or source-path lengths. Current snapshot decoding remains proportional to store size; this change does not claim constant-time store reads.

Search continues to use the existing whole-query and SQLite FTS ranking. No new word heuristic, importance score, TTL, top-N auto injection, or cumulative runtime budget is introduced. The model makes the relevance choice through its tool invocation. Standing identity, constraints and role instructions remain in the runtime prompt/configuration; a remembered fact is not promoted to a standing instruction by its category.

## Planned source validation efficiency

The follow-up stack unit will choose query-matching source candidates from stored claims before reading files. Revalidate those exact path/digest identities under the source-store lock. Unselected or concurrently replaced identities remain stored and unverified and cannot become returned claims. Changed/missing selected sources become durable invalidations; transient unreadability withholds the claim without deleting it. Apply the existing search result bound after validation so a stale candidate cannot crowd out a valid successor. Broad queries may select many sources; this is an explicit retrieval request, not work repeated by every turn.

## Evidence boundaries

Regression coverage must prove: first-round recall creates no complete artifact or pin; source mutation is not touched until retrieval; tool-less recall never includes claims; artifact-only retrieval still honors source invalidation and retention; selective lookup leaves unrelated source metadata untouched; selected changed/unreadable and concurrently replaced sources cannot leak stale claims. Parser-only checks and independent source review do not prove runtime latency, provider input bytes, or build success. Compare the same snapshots/queries before and after when executing performance tests.

This supersedes the all-facts fallback and the default per-turn complete-artifact preparation in the source interface. The older Draft RFCs on Recall selection remain proposals, including their separate typed task/goal linking and event-validity work. This implementation adopts demand retrieval without creating that metadata schema or an automatic selector.

Design reference: [Anthropic context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) describes lightweight identifiers with just-in-time retrieval; this change uses the existing Keeper tools to apply that pattern.
