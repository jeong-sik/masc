# Muse completed identity checked before kind dispatch

Base: `ae95ab41527dfd124b6bd147340493047076ba77`.

Independent source review of the parent returned HOLD with P2: a completed agent
ID could be reused as Tool_call or Compaction. The previous guard lived inside
the incoming Agent_message branch and thus did not inspect changed kinds before
publishing their effects.

Both Item_started and Item_completed now check the completed identity before
incoming-kind dispatch. Started reuse rejects regardless of incoming kind.
Completed exact typed snapshot replay remains a no-op; every changed snapshot
rejects before native or compaction publication. First unseen item behavior is
unchanged. This does not add a second source of identity or a text heuristic.

A wire fixture reuses completed m-1 as tool start and tool completion and requires
Protocol_error at the corresponding stage plus zero native events. It has not
been executed. Syntax-only parsing and whitespace checks passed. No Dune build,
CI, formal approval, installed runtime or screenshot evidence is claimed.

Original HOLD retained at /tmp/masc-muse-completed-item-review-20261012/review.json.
Corrected cumulative independent source review requested separately. Other
provider and native identity lifecycle cases remain unverified.
