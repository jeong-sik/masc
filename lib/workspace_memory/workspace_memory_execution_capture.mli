(** Trusted host capture for one Curator execution. No worker, provider,
    registry, dispatch or domain commit effects are created here. *)
module Request_id : sig
  type t
  val fresh : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val compare : t -> t -> int
  (** Mint order. The canonical UUIDv7 text starts with its millisecond
      timestamp, and one process mints monotonically within a millisecond
      ({!Random_id.uuid_v7}). *)
  val minted_on : t -> (string, string) result
  (** The UTC date, [YYYY-MM-DD], of the timestamp the ID carries. *)
end
type workspace
val observe_workspace : base_path:string -> (workspace, string) result
(** Blocking descriptor-bound path/device/inode observation. Run the complete
    scope on a system thread in Eio contexts. Missing/replaced roots are errors.
    A successful observation is not a process lease or permission to execute. *)
type destination = {
  installation_id : string;
  package_id : string;
  tool : string;
  source_revision : string;
  configuration_revision : string;
}
type work = private
  | Classification of {
      ledger : Workspace_memory_ledger.t;
      revision : Workspace_memory_revision.ledger;
      batch : Workspace_memory_request.batch;
    }
  | Briefing of Workspace_memory_briefing.batch
type t
val classification : request_id:Request_id.t -> workspace:workspace -> destination:destination ->
  prompt:Prompt_registry.prompt_resolution -> ledger:Workspace_memory_ledger.t ->
  stored_ledger:Workspace_memory_revision.stored_ledger ->
  batch:Workspace_memory_request.batch -> (t, string) result
val briefing : request_id:Request_id.t -> workspace:workspace -> destination:destination ->
  prompt:Prompt_registry.prompt_resolution -> batch:Workspace_memory_briefing.batch -> (t, string) result
(** Check the original whole batch and its rendered prompt against the captured
    template: a restore of the stored snapshot must render the same prompt, so
    the capture stores the input once and only the SHA-256 of the prompt. Briefing
    must have the same original prompt/schema contract as its prepared pass.
    Classification requires a completed revision write in this exact physical
    workspace and for this exact typed ledger. Its body stores only that
    revision reference. Constructors remain pure; the trusted producer writes
    the revision before constructing and publishing the original.
    Destination revisions and prompt resolution must be supplied by the trusted
    host owner; these constructors do not establish their external provenance
    or ownership. *)
val scope : string
val package_id : string
val tool : string
val request_id : t -> Request_id.t
val predecessor : t -> Request_id.t option
(** None identifies an original root capture. A successor keeps its original
    parent ID; [restore] verifies the complete acknowledged ancestry. *)
val destination : t -> destination
val base_path : t -> string
(** The physically captured workspace path, never today's inferred setting. *)
val work : t -> work
val rendered_prompt : t -> string
val output_schema : t -> Yojson.Safe.t
(** Original capture bytes. Classification serializes [ledger_revision], never
    the complete ledger; a fresh classification requires its write receipt,
    while restore obtains the same state from its verified immutable revision. *)
val to_json : t -> Yojson.Safe.t

(** What a pass reads about an original without restoring it: its
    predecessor, the physical workspace that captured it, and for
    classification the size it was prepared for and the facts it selected,
    for Briefing how many entries it selected and the SHA-256 of the state it
    prepared. The owner record keeps it; every restore refuses a capture
    whose summary differs. *)
module Summary : sig
  val schema : string
  (** [workspace.memory.execution-summary.v1]. A summary naming another
      schema is refused. *)
  type batch =
    | Classification of { up_to : Workspace_memory_request.size; selected : Workspace_memory_ledger.fact_ref list }
    | Briefing of { selected_count : int; prepared_state : string }
  type t = private { predecessor : Request_id.t option; workspace : workspace; batch : batch }
  val output_schema : t -> Yojson.Safe.t
  (** The domain output schema of the original's kind. *)
  val to_json : t -> Yojson.Safe.t
  val of_json : Yojson.Safe.t -> (t, string) result
end
val summary : t -> (Summary.t, string) result
(** A Briefing summary names the state its batch prepared by that state's
    revision ({!Workspace_memory_revision.of_briefing}). *)
val classification_size :
  (Request_id.t * Summary.t * Lane_addon_request_progress.phase) list -> Workspace_memory_request.size
(** The size of the next classification batch
    (RFC-workspace-curator-curates-changed-facts 2.4, "다음 묶음"), from the
    latest-minted classification a provider answered ([Finished] or
    [Conflicted]):
    - A child exists only after a size refusal, so its count fit: [Up_to]
      that count.
    - A root answered without a refusal keeps what it was prepared for:
      [Fill_frame] stays [Fill_frame], the frame being the bound that held.
      [Up_to n] doubles to [Up_to 2n] when the root held [n] facts, and stays
      [Up_to n] when the frame or a short backlog stopped it below [n], since
      that answer says nothing about [n].
    - With no answered classification, [Fill_frame].
    Briefing and every other phase are not evidence. Each pass reads the
    summaries of the originals it keeps, each with its request ID; the summary
    records the size its batch was prepared for. *)
val narrow : request_id:Request_id.t -> final:Lane_addon_exact.final -> t -> (t option, string) result
(** Pure whole-row/whole-entry bisection using the original captured template,
    ledger, physical workspace and destination. Input_capacity, Context_overflow
    and Request_body_refused permit either kind; Output_limit_reached permits
    classification only. Every other terminal is rejected. [Ok None] means one
    indivisible row remains. Does not mint IDs, save state or establish that
    [final] actually belongs to this original request; the host journal does. *)
val restore : workspace:workspace ->
  load:(request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  Lane_addon_tool_request_owner.retained -> (t, string) result
(** Restore only from a strict original-owner read. Match the current observed
    physical workspace, original scope/ID/destination and domain schema; render
    the prompt again with the captured template, never today's prompt override,
    and require the SHA-256 recorded for the prompt that was sent. The caller supplies a fresh observation under its original
    workspace lease/serialization, and still revalidates live authority before
    effects. Strictly load each predecessor; require its matching acknowledged
    child and original typed size refusal, re-derive the entire child capture
    and require the request digest the parent's intent names, and reject
    missing, conflicting, unreadable or cyclic ancestry. A retained
    child whose parent is still Subdividing cannot execute. This is neither
    restart enumeration nor a commit journal. Classification restore reads
    its named revision from the captured workspace and refuses missing,
    damaged or unreadable bytes. It never substitutes today's ledger. *)
val recoverable_successors : workspace:workspace ->
  (Lane_addon_tool_request_owner.Record.t * Summary.t) list -> (string list, string) result
(** Validate the links of the freshly discovered original forest before
    recovery, from records and summaries only: every original was captured in
    [workspace], every predecessor is present and names its child by request
    ID and digest, an acknowledged child exists, and a Subdividing parent has
    no child yet or exactly its initial child with no events. An original of
    another physical workspace, or a duplicate, dangling, cyclic or
    conflicting link, rejects the whole inventory. Captures and each
    whole-batch derivation are checked when an original is restored, not
    here.
    Return only parent IDs with already durable successor intentions. No new
    ID, intent, admission, worker call or domain effect is authorized. Caller
    must re-read each parent under the original lease/serializer and perform
    ordinary full restore after recovering its exact existing intention. *)
type settling = Classifications | Briefings of { state : string }
(** The domain whose chains to settle. Briefing names its current state's
    revision ({!Workspace_memory_revision.briefing_sha256}). *)
val refusal_blocks : Summary.t -> Lane_addon_request_progress.refusal -> (bool, string) result
(** Strictly decode the original refusal. Only a host-confirmed Interrupted
    outcome releases the selected facts or prepared Briefing state. Cut,
    Raised and other refusals block. Missing/unknown cause and Answered
    evidence are errors; before-dispatch refusals remain blocking. *)
val settled_chains : settling ->
  (Lane_addon_tool_request_owner.Record.t * Summary.t) list ->
  ((Request_id.t * Lane_addon_tool_request_owner.Record.t list) list, string) result
(** The chains of the domain that no pass needs again, from the discovered
    forest: each root's ID with the chain's records, leaf first, the order
    they are settled in. A chain is settled when its leaf is Finished,
    Conflicted or rejected with Interrupted, and every original has both observer receipts
    acknowledged. It stays while it holds the latest answered classification,
    which sizes the next batch, or while its Briefing leaf prepared the
    current state, which keeps the same pass from being prepared again. A
    Rejected leaf with any other cause keeps its chain. An Interrupted leaf
    never sizes the next batch and settles even if it prepared the current
    Briefing state. Invalid refusal evidence rejects settlement.
    Records and summaries only. *)
type expected_commit =
  | Classification_commit of Workspace_memory_ledger.t
  | Briefing_commit of Workspace_memory_briefing.t
val validate_output : t -> Yojson.Safe.t -> (expected_commit, string) result
(** Original pure full-domain decision validation and expected state only.
    Does not save, publish, mark an observer complete or authorize a retry. *)
val commit_plan : t -> judgment:Yojson.Safe.t ->
  (expected_commit * Lane_addon_request_progress.change, string) result
(** Strict original Answered final, full domain validation and exact before/after
    plan. Shared by settlement and observation; no current domain read or write. *)
