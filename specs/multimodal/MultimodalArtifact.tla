---- MODULE MultimodalArtifact ----
\* Cycle 24 / Tier B8 catch-up spec.
\*
\* Mirrors the well-formedness invariants over [Multimodal.Artifact],
\* [Multimodal.Payload], and [Multimodal.Provenance_stub] from
\* lib/multimodal/. The runtime artifact carries:
\*   - an opaque Shared_types.Artifact_id.t (UUID v7),
\*   - a phantom-tagged kind in {Code, Image, Audio, Doc},
\*   - a Payload variant in {Lazy_payload, Blob_ref, Streaming},
\*   - a Provenance_stub record carrying origin artifact ids.
\*
\* This spec models a finite ArtifactIds universe and an artifacts
\* function ArtifactIds -> Artifact, where each artifact carries a
\* [present : BOOLEAN] field marking whether it has been realised
\* via CreateArtifact. A separate dag variable carries the directed
\* (from_id, to_id) edges introduced by Tier B9.
\*
\* The [present] field exists for the model only. The runtime
\* counterpart simply does not have an entry until [CreateArtifact]
\* is called; we use a present flag here because TLC cannot
\* fingerprint a state where a function returns heterogeneous types
\* (record vs sentinel). All present=FALSE artifacts are equivalent
\* "not yet created" placeholders.
\*
\* OCaml <-> TLA+ mapping:
\*
\*   variable                 | OCaml site
\*   -------------------------+---------------------------------------------
\*   artifacts[id].present    | (modelling artefact only — runtime
\*                            | tracks via map presence)
\*   artifacts[id].kind       | Multimodal.Artifact.kind_to_tag
\*   artifacts[id].payload_kind
\*                            | Multimodal.Payload.t discriminator
\*   artifacts[id].provenance | Multimodal.Provenance_stub.t
\*   dag                      | Multimodal_hydrator.provenance_dag.edges
\*
\* Out-of-scope (defer to A7 / B9 follow-ups):
\*   - Lazy_payload closure semantics / Blob_ref bytes,
\*   - hydration ordering and concurrency,
\*   - Tool_set integration (Tier A7).

EXTENDS TLC, Naturals, FiniteSets

CONSTANTS
    ArtifactIds,    \* finite universe of artifact ids
    Personas        \* finite universe of creator names

\* The four kind tags exposed by Multimodal.Artifact.kind_tag.
Kinds == {"code", "image", "audio", "doc"}

\* The three payload discriminators exposed by Multimodal.Payload.t.
PayloadKinds == {"lazy", "blob_ref", "streaming"}

Provenance == [
    origin_artifact_ids : SUBSET ArtifactIds,
    created_by : Personas,
    created_at : Nat
]

Artifact == [
    id : ArtifactIds,
    kind : Kinds,
    payload_kind : PayloadKinds,
    provenance : Provenance,
    present : BOOLEAN
]

\* A null-shaped placeholder for ids that have not yet been
\* CreateArtifact-d. Same record shape as a present artifact so
\* TLC fingerprinting stays homogeneous.
DefaultArtifact(i, p, t) == [
    id |-> i,
    kind |-> "code",
    payload_kind |-> "lazy",
    provenance |-> [ origin_artifact_ids |-> {},
                     created_by |-> p,
                     created_at |-> t ],
    present |-> FALSE
]

VARIABLES
    artifacts,
    dag

vars == <<artifacts, dag>>

\* ── Type invariant ───────────────────────────────────────────────
TypeOK ==
    /\ artifacts \in [ArtifactIds -> Artifact]
    /\ dag \subseteq (ArtifactIds \X ArtifactIds)

\* Every present artifact's id field equals its key in [artifacts].
ArtifactIdMatchesKey ==
    \A id \in ArtifactIds :
        ~artifacts[id].present \/ artifacts[id].id = id

\* No DAG edge points to or from a non-realised artifact.
DAGRefIntegrity ==
    \A pair \in dag :
        /\ artifacts[pair[1]].present
        /\ artifacts[pair[2]].present

\* No self-loops — an artifact cannot be its own predecessor.
NoSelfLoops ==
    \A id \in ArtifactIds : <<id, id>> \notin dag

\* Reachability in the bounded TLC model.  The cfg currently uses two
\* artifact ids; four hops leaves headroom for small follow-up cfgs
\* without introducing a recursive transitive-closure operator.
Reaches1In(edge_set, a, b) == <<a, b>> \in edge_set
Reaches2In(edge_set, a, b) == \E m \in ArtifactIds :
    <<a, m>> \in edge_set /\ <<m, b>> \in edge_set
Reaches3In(edge_set, a, b) == \E m1, m2 \in ArtifactIds :
    <<a, m1>> \in edge_set /\
    <<m1, m2>> \in edge_set /\
    <<m2, b>> \in edge_set
Reaches4In(edge_set, a, b) == \E m1, m2, m3 \in ArtifactIds :
    /\ <<a, m1>> \in edge_set
    /\ <<m1, m2>> \in edge_set
    /\ <<m2, m3>> \in edge_set
    /\ <<m3, b>> \in edge_set

DAGAcyclicIn(edge_set) ==
    \A id \in ArtifactIds :
        /\ ~Reaches1In(edge_set, id, id)
        /\ ~Reaches2In(edge_set, id, id)
        /\ ~Reaches3In(edge_set, id, id)
        /\ ~Reaches4In(edge_set, id, id)

\* The provenance graph is a DAG, not just a graph without self-loops.
DAGAcyclic == DAGAcyclicIn(dag)

\* Provenance origin_artifact_ids must reference present artifacts.
ProvenanceOriginsLive ==
    \A id \in ArtifactIds :
        ~artifacts[id].present \/
        (\A o \in artifacts[id].provenance.origin_artifact_ids :
            artifacts[o].present)

\* ── Init / Next ──────────────────────────────────────────────────
\* Pick an arbitrary persona for the placeholder values; it never
\* matters because [present = FALSE] for every Init artifact.
InitPersona == CHOOSE p \in Personas : TRUE

Init ==
    /\ artifacts = [ id \in ArtifactIds |-> DefaultArtifact(id, InitPersona, 0) ]
    /\ dag = {}

CreateArtifact(id, k, pk, origins, p, t) ==
    /\ ~artifacts[id].present
    /\ origins \subseteq { o \in ArtifactIds : artifacts[o].present }
    /\ artifacts' = [ artifacts EXCEPT ![id] =
                        [ id |-> id,
                          kind |-> k,
                          payload_kind |-> pk,
                          provenance |-> [ origin_artifact_ids |-> origins,
                                           created_by |-> p,
                                           created_at |-> t ],
                          present |-> TRUE ] ]
    /\ UNCHANGED dag

AddEdge(from_id, to_id) ==
    /\ artifacts[from_id].present
    /\ artifacts[to_id].present
    /\ from_id # to_id
    /\ <<from_id, to_id>> \notin dag
    /\ DAGAcyclicIn(dag \cup {<<from_id, to_id>>})
    /\ dag' = dag \cup {<<from_id, to_id>>}
    /\ UNCHANGED artifacts

CanCreateArtifact ==
    \E id \in ArtifactIds : ~artifacts[id].present

CanAddEdge ==
    \E from_id, to_id \in ArtifactIds :
        /\ artifacts[from_id].present
        /\ artifacts[to_id].present
        /\ from_id # to_id
        /\ <<from_id, to_id>> \notin dag
        /\ DAGAcyclicIn(dag \cup {<<from_id, to_id>>})

TerminalStutter ==
    /\ ~CanCreateArtifact
    /\ ~CanAddEdge
    /\ UNCHANGED vars

Next ==
    \/ \E id \in ArtifactIds, k \in Kinds, pk \in PayloadKinds,
          origins \in SUBSET ArtifactIds, p \in Personas, t \in 0..0 :
            CreateArtifact(id, k, pk, origins, p, t)
    \/ \E from_id \in ArtifactIds, to_id \in ArtifactIds :
            AddEdge(from_id, to_id)
    \/ TerminalStutter

Spec == Init /\ [][Next]_vars

THEOREM Spec => []TypeOK
THEOREM Spec => []ArtifactIdMatchesKey
THEOREM Spec => []DAGRefIntegrity
THEOREM Spec => []NoSelfLoops
THEOREM Spec => []DAGAcyclic
THEOREM Spec => []ProvenanceOriginsLive

====
