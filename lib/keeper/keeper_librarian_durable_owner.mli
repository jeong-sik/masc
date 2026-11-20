(** Submit-once host owner for original completed-history Memory requests.
    Caller holds the workspace process lease and serializes this Keeper owner. *)
type error = Lane_addon_submit_once.error =
  | Unavailable of string | Rejected of string | Uncertain of string
val error_to_string : error -> string
type wait = Lane_addon_submit_once.wait =
  | Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type publication =
  | Publication_pending of string
  | Publication_complete of Lane_addon_tool_request_owner.retained
  | Publication_superseded of Lane_addon_tool_request_owner.retained
type publish = original:Lane_addon_tool_request_owner.retained ->
  request:Keeper_librarian_durable_request.t ->
  proposal:Keeper_librarian_runtime.durable_proposal -> (publication, error) result
(** Root's actual source-locked publication port: recover/persist the complete
    original Gate transcript, commit intent, actual Memory/range receipts and
    source/cursor ACK before Finished. It must be idempotent and validate all
    source/owner/disposition authority itself. Complete is checked against the
    durable original record. Superseded requires a durable known-basis Conflict
    proved by the publication owner and grants no Memory or source ACK. No
    callback acceptance is a completed publication. *)
type call = expected:Keeper_librarian_durable_request.destination ->
  original:Lane_addon_tool_request_owner.Record.t -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, Lane_addon_submit_once.call_error) result
(** Actual Runtime call edge must recheck the original semantic destination and
    physical owner immediately before RPC. Only failures before RPC are Not_sent. *)
type outcome =
  | Publication_waiting of string
  | Refused of Lane_addon_exact.final * Lane_addon_tool_request_owner.retained
  | Finished of Lane_addon_tool_request_owner.retained
  | Basis_superseded of Lane_addon_tool_request_owner.retained
  | Ended_unadmitted of Lane_addon_tool_request_owner.retained
      (** No worker received the original and its declaration was replaced, so
          it was ended before dispatch. Nothing was refused by a host or a
          provider. *)
type resumed =
  | Waited of wait * Lane_addon_tool_request_owner.Record.t
      (** The original waits for its worker. Its body may not have been read. *)
  | Resumed of outcome * Keeper_librarian_durable_request.t
      (** The body was read, and the outcome is of this request. *)
  | Original_replaced of Lane_addon_tool_request_owner.Record.t
      (** This original ended without consuming its source. The Owner has
          requested the next pass once; it must not narrow the unread range. *)
val retain : store:Lane_addon_store.t -> Keeper_librarian_durable_request.t ->
  (Lane_addon_tool_request_owner.retained, error) result
(** Persist the full original before any dispatch, retaining its existing journal.
    The caller must retain new work under Runtime's fresh configured-destination
    serializer; this port alone grants no live configuration authority. A write
    failure never proves absence or permits a replacement request ID. A linked
    replacement must match its predecessor's complete publication intent. *)
type listed = Lane_addon_tool_request_owner.Record.t * Keeper_librarian_durable_request.index
type terminal_ending_recovery =
  | No_ending
  | Ending_retained of Lane_addon_tool_request_owner.Record.t
val recover_terminal_ending : store:Lane_addon_store.t -> config:Workspace.config -> reserved:string list ->
  original:listed -> (terminal_ending_recovery, error) result
(** Retain only an actual host [Replaced_declaration] or [Interrupted] ending
    for a dispatch-pending original. The caller first validates the complete
    scope inventory and supplies a waiting original with no Gate or replacement
    publication. This port validates the immutable body, current physical
    owner, acknowledged predecessor, absence of a fence and strict host proofs
    before the original's refusal CAS and readback. Other host states return
    [No_ending], without worker/provider calls, Memory publication, source ACK or a
    replacement ID. For open/absent host state, only a ready same-owner replaced
    declaration enters the trusted runner-free Exact claim and execution guard
    to reconcile a no-send ending. An unproved Started stays unresolved; no
    missing-record observation alone grants refusal. Other destinations need
    no body read. [Ending_retained]
    is a lifecycle observation, never Finished or Memory completion. The caller
    wakes the same serialized lane and ends its current unit; a fresh inventory
    decides settlement and which source remains to be read. Uncertain writes
    and changed observations grant no settlement or continued use of old counts. *)
val discover : store:Lane_addon_store.t -> base_path:string -> keepers_dir:string ->
  keeper_id:string -> (listed list, error) result
(** Every original of the physical scope as its record and the index in that
    record's summary, before a fresh source selector. No body is read. Any
    record whose summary is not its index, or whose owner, epoch or source
    root is not the live one, refuses the inventory. Finished originals
    remain observations; only active originals should block or drive new work. *)
val load : store:Lane_addon_store.t -> listed ->
  (Lane_addon_tool_request_owner.retained * Keeper_librarian_durable_request.t, error) result
(** Read and strictly restore one discovered original's body. The record read
    with the body must still hold the discovered index, and
    [Keeper_librarian_durable_request.restore] binds that index to the body. *)
val load_many : store:Lane_addon_store.t -> listed list ->
  ((Lane_addon_tool_request_owner.retained * Keeper_librarian_durable_request.t) list, error) result
(** Read the selected originals in order, stopping at the first failure. Every
    record and body is read and validated afresh. Within this one call, equal
    captured owners and complete source text may share an already validated
    immutable source. Each request's preparation, binding, index and physical
    source root are still checked. The source-digest index selects a possible
    previous source only; it is discarded before returning the restored list. *)
type held =
  | Listed of listed
      (** Its record and index. Its fence and predecessor are checked on them,
          and {!load} reads the body only in the branches of
          [Lane_addon_submit_once.resume] that need it, and for commit and
          settled phases. A pre-admission declaration replacement is checked
          and recorded before any body read. *)
  | Read of (Lane_addon_tool_request_owner.retained * Keeper_librarian_durable_request.t)
      (** Already read with its body, which is checked before anything else. *)
val resume : store:Lane_addon_store.t -> config:Workspace.config -> reserved:string list ->
  original:held -> call:call -> publish:publish -> wake:(unit -> unit) -> (resumed, error) result
(** Host retained/latest proof and complete raw domain validation precede any
    publication callback, including recovery while Off. An actual host terminal
    [Outcome_unknown] returns [Waited (Worker_unknown, original)] after its
    immutable refusal is verified and retained. It grants no submission of that
    original. A history's host-confirmed [cut] may retain a separate replacement
    disposition after a ready new declaration is observed; that disposition
    permits a fresh request without consuming input, including after rollback.
    Linked work preserves its source and acknowledged predecessor lineage.
    An
    [interrupted] cause also calls [wake]: inventory validation reads that
    refusal as settled, so the next pass moves the original and selects its
    range again. Other unknown causes and [cut] without the bound
    disposition stay pending. A dispatch-pending original whose declaration
    changed first uses the runner-free trusted Exact reconciliation port. Only
    its real claim, bound input/proofs and fresh execution guard may retain a
    no-send ending; the normal submit-once path then rereads that terminal.
    Busy, unavailable and unresolved execution remain waits, without worker
    RPC, source ACK or invented refusal. The same declaration keeps its lazy
    waiting-body path. Only shared submit-once pre-admission/Not_sent
    rules retry the same original. New admission and every
    unfinished publication require the frozen prompt to cover its counterpart
    input. A receipt alone cannot authorize a new ACK of observations an old
    question omitted. Pending/unknown observation and structural restoration
    remain available without rewriting that question.
    Linked work cannot dispatch before its predecessor confirms publication of
    this exact full child request. Missing or changed parent intent refuses.
    Existing Finished is strictly restored but not republished against today's
    moving range receipt. Existing Conflict is delegated to strict publication
    validation rather than granting retry authority. Wake submits to the same
    Memory lane after observed declaration-replacement disposition, newly
    observed Finished or known-basis supersession;
    an already conflicted original never repeats that wake. Scheduling acceptance
    is not execution success. *)
