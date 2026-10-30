---- MODULE MultimodalHydrator ----
\* Cycle 27 / Tier B9 catch-up spec.
\*
\* Models the provenance DAG built by the hydrator's [add_edge]
\* operation, as implemented in lib/multimodal/multimodal_hydrator.{mli,ml}.
\*
\* Key safety properties:
\*   - No self-loop (an artifact cannot be its own ancestor).
\*   - No cycle (the provenance graph is a DAG).
\*   - add_edge dedupe (edges is a set, so add is idempotent).
\*
\* The hydrator's API:
\*   add_edge ws ~from_id ~to_id : t  — append edge,
\*     no-op if either endpoint missing or edge already present.
\*
\* This spec abstracts the workspace's artifact set as Nodes and
\* models edges as a relation on Nodes. The cycle-freedom check
\* uses bounded transitive closure since TLC cannot evaluate
\* unbounded fixed points.

EXTENDS TLC, Naturals, Sequences, FiniteSets

CONSTANTS
    Nodes,         \* finite set of artifact ids in the workspace
    MaxEdges       \* state-space bound on edge count

VARIABLES
    edges          \* set of <<from, to>> pairs

vars == <<edges>>

\* ── Type invariant ───────────────────────────────────────────────
TypeOK ==
    /\ edges \subseteq (Nodes \X Nodes)

\* No self-loop.
NoSelfLoop ==
    \A e \in edges : e[1] /= e[2]

\* Reachability via 1, 2, 3, ... step paths.
Reaches1In(edge_set, a, b) == <<a, b>> \in edge_set
Reaches2In(edge_set, a, b) == \E m \in Nodes :
    <<a, m>> \in edge_set /\ <<m, b>> \in edge_set
Reaches3In(edge_set, a, b) == \E m1, m2 \in Nodes :
    <<a, m1>> \in edge_set /\
    <<m1, m2>> \in edge_set /\
    <<m2, b>> \in edge_set
Reaches4In(edge_set, a, b) == \E m1, m2, m3 \in Nodes :
    /\ <<a, m1>> \in edge_set
    /\ <<m1, m2>> \in edge_set
    /\ <<m2, m3>> \in edge_set
    /\ <<m3, b>> \in edge_set

\* No path from a back to itself within the bounded depth. With
\* MaxEdges <= 3 and Cardinality(Nodes) <= 4 we cover all cycles
\* expressible in the state space.
NoCycleIn(edge_set) ==
    \A a \in Nodes :
        /\ ~Reaches1In(edge_set, a, a)
        /\ ~Reaches2In(edge_set, a, a)
        /\ ~Reaches3In(edge_set, a, a)
        /\ ~Reaches4In(edge_set, a, a)

NoCycleBounded == NoCycleIn(edges)

\* The DAG dedupe property: adding an existing edge is a no-op.
\* edges is a set, so this is automatic in the model.
DedupeIdempotent ==
    \A e1, e2 \in edges :
        (e1[1] = e2[1] /\ e1[2] = e2[2]) => e1 = e2

\* ── Init / Next ──────────────────────────────────────────────────
Init ==
    /\ edges = {}

\* Add an edge from->to. Refuses self-loops to enforce NoSelfLoop.
\* The hydrator's actual add_edge is more permissive (it would
\* accept a self-loop if both endpoints exist), but the spec
\* forbids them as an invariant — production code must reject.
EdgeAllowed(edge_set, from_id, to_id) ==
    /\ from_id /= to_id
    /\ <<from_id, to_id>> \notin edge_set
    /\ Cardinality(edge_set) < MaxEdges
    /\ NoCycleIn(edge_set \cup { <<from_id, to_id>> })

AddEdge(from_id, to_id) ==
    /\ EdgeAllowed(edges, from_id, to_id)
    /\ edges' = edges \cup { <<from_id, to_id>> }

CanAddEdge ==
    \E from_id, to_id \in Nodes : EdgeAllowed(edges, from_id, to_id)

TerminalStutter ==
    /\ ~CanAddEdge
    /\ UNCHANGED edges

Next ==
    \/ \E from_id, to_id \in Nodes : AddEdge(from_id, to_id)
    \/ TerminalStutter

Spec == Init /\ [][Next]_vars

BoundedEdges == Cardinality(edges) <= MaxEdges

\* ── Bug model (RFC-Q2-5) ────────────────────────────────────────
\*
\* Models the bug class where the hydrator's add_edge precondition
\* check on from_id /= to_id is bypassed (the spec header notes
\* the runtime is more permissive than the spec forbids; a
\* refactor that loses the production-side guard reproduces the
\* bug). NoSelfLoop catches this on the first reflexive edge.

AddSelfLoop(node) ==
    /\ <<node, node>> \notin edges
    /\ Cardinality(edges) < MaxEdges
    \* deliberately omitted: from_id /= to_id check
    /\ edges' = edges \cup { <<node, node>> }

NextBuggy ==
    \/ Next
    \/ \E node \in Nodes : AddSelfLoop(node)

SpecBuggy == Init /\ [][NextBuggy]_vars

THEOREM Spec => []TypeOK
THEOREM Spec => []NoSelfLoop
THEOREM Spec => []NoCycleBounded
THEOREM Spec => []DedupeIdempotent

====
