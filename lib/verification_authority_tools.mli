(** Completion-authority access to one producer's typed read-only filesystem
    descriptors. A Keeper producer receives its metadata-bound Read and Grep;
    a Workspace producer without Keeper runtime metadata receives an
    ownership-root-bound Read. Both receive the shared web-fetch tool so a
    URL left in note evidence (a PR, a CI run) is inspectable by the judge
    itself instead of standing as the producer's claim (masc#28989); its
    boundary guards — http/https only, private-network and localhost targets
    refused, validated redirects, bounded extraction — live in the tool. Descriptor registry drift and unreadable
    producer state reject surface construction. Every dispatched call is
    validated and translated by the same descriptor that was advertised.
    Exact Board/Fusion source reads are also available. Task authority uses
    the actual producer identity; Goal authority permits shared workspace
    records. Direct posts are readable only by their author via Task review,
    because immutable target readership is not available at this boundary.
    Neither surface grants general access to the MASC storage directory.
    Mutating execution is absent: a verifier has no turn continuation that
    could resume an approved Gate effect. *)


type t

type task_review
(** A host-built read-only surface bound to one submitted verification. *)

val create_task_review :
  config:Workspace.config -> verification_id:string -> task_id:string -> producer:string ->
  evidence_access:Workspace_verification_store.submitted_evidence_access ->
  (task_review, string) result
(** Validate the submitted header and freeze the actual descriptors, evidence
    snapshot, workspace, producer and root together. No caller dispatch closure
    can be substituted for this surface. *)

val task_review_binding : task_review -> string
(** Canonical SHA-256 of the complete authority projection, including full tool
    schemas and submitted evidence bytes, rather than only names or layout. *)
val task_review_base_path : task_review -> string
val task_review_root : task_review -> Task.Anti_rationalization.lookup_root
val task_review_tools : task_review -> t
val task_review_subject : task_review -> Workspace_verification_store.request_header
val validate_task_review : task_review -> (unit, string) result
val task_review_lookup : task_review -> Task.Anti_rationalization.lookup_surface
(** Recheck route configuration before execution and each lookup. Actual file
    containment and endpoint dispatch remain owned by the existing backend,
    using the same captured endpoint for path translation, Read, Grep, media
    and layout. Configuration changes cannot redirect an admitted lookup. *)

val create :
  config:Workspace.config -> producer:string ->
  submitted_evidence:Workspace_verification_store.submitted_evidence_item list -> (t, string) result

val create_goal_proof : config:Workspace.config ->
  submitted_evidence:Workspace_verification_store.submitted_evidence_item list -> (t, string) result
(** The Goal proof surface: read and web-fetch rooted at the shared playground
    prefix. A Goal names no producer, so there is no owned tree to bind to and
    no producer set to derive; this root is the same fixed workspace location
    for every Goal. [tool_search_files] is absent — its containment runs
    through a Keeper's sandbox meta, which this surface has none of. *)

val root_layout : t -> (Task.Anti_rationalization.lookup_root, string) result
(** The paths the lookup tools resolve against, listed from disk at review
    time and relative to the ownership root: bounded immediate entries plus
    every checkout returned by the shared checkout-discovery authority. Host
    checkout lines carry their branch, HEAD commit and position against the
    local tracking ref; an uncompared checkout is never described as current.
    The identity probe reads only the local clone: no fetch or working-tree status.
    Endpoint-owned Keepers are observed on their attached endpoint, matching
    Read/Grep; their host bookkeeping directory is never a layout fallback.
    Their checkout identities are not probed on the host.
    Unavailable or partial discovery is [Error], so a caller must defer the
    review instead of turning an incomplete list into absence evidence. A
    workspace producer whose root does not exist is [Producer_root_absent]:
    nothing creates that directory for such a producer, so the fact is
    complete and the review proceeds on the submitted evidence. *)

val goal_proof_root_layout : t -> (string list, string) result
(** {!root_layout} for a {!create_goal_proof} surface: the producer entries
    under the shared root, without the per-producer checkout scan. That scan
    stops on its reported-checkout budget when walked across every producer at
    once, and the stop is an [Error] — running it here deferred every Goal
    review instead of listing anything. *)

val schemas : t -> Types_core.tool_schema list

val image_delivery_note : string
(** The sentence [schemas] appends to the read_file descriptor: this surface
    reads images and inspected PDF/PPTX pages as visual input. Exposed so the schema-parity test asserts
    against the same spelling the surface publishes. *)

val dispatch : t -> name:string -> args:Yojson.Safe.t -> Tool_result.result
(** Observations are UTF-8 text. Read delivers admitted image bytes as canonical
    model content, with path, media type, size and SHA-256 in the text receipt.
    PDFs are inspected from complete captured source bytes using Poppler: source
    identity, parsed page metadata/text and all rendered PNG pages are returned.
    PPTX files additionally expose ordered source slide text and speaker notes,
    with every slide rendered from the captured presentation. Animations and
    embedded audio/video playback remain explicitly uninspected.
    Other binary output is a stated lookup failure, never text or visual proof. *)
