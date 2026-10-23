(** Original Curator admission, worker-result and domain-commit boundaries.
    The existing serialized workspace owner retains the process lease. *)
type error = Unavailable of string | Rejected of string | Uncertain of string
val error_to_string : error -> string
val destination : config:Workspace.config -> (Lane_addon_runtime.tool_request_destination, error) result
(** The live Add-on that provides [curate], read through the same fresh
    declaration check a capture uses, with its declared frame. Sizes a batch
    before any capture; it is not authority for an effect. No such Add-on is
    [Unavailable]. *)
val capture_classification : config:Workspace.config ->
  request_id:Workspace_memory_execution_capture.Request_id.t ->
  prompt:Prompt_registry.prompt_resolution -> ledger:Workspace_memory_ledger.t ->
  batch:Workspace_memory_request.batch -> (Workspace_memory_execution_capture.t, error) result
val capture_briefing : config:Workspace.config -> prompt:Prompt_registry.prompt_resolution ->
  batch:Workspace_memory_briefing.batch -> (Workspace_memory_execution_capture.t, error) result
(** Mint once, capture actual live installation provenance and retain before
    any worker RPC. A classification uses the [request_id] its batch was sized
    under and is refused when its [submit] exceeds the destination's frame read
    under the same lock. Briefing mints its own id, and requires its original
    prepared state to be saved and freshly confirmed first, by the serialized
    owner. An error may follow publication: discover original work before
    preparing another request. No model or domain save runs here. *)
type wait = Capacity | Worker_pending | Worker_unknown | Missing_after_dispatch | Journal_recheck
type result =
  | Awaiting of wait * Lane_addon_tool_request_owner.retained
  | Judgment of { capture:Workspace_memory_execution_capture.t;
      record:Lane_addon_tool_request_owner.retained; final:Lane_addon_exact.final;
      expected:Workspace_memory_execution_capture.expected_commit }
  | Terminal of Lane_addon_exact.final * Lane_addon_tool_request_owner.retained
  | Commit_pending of Lane_addon_tool_request_owner.retained
  | Settled of Lane_addon_tool_request_owner.retained
val resume : config:Workspace.config -> request_id:string -> (result, error) Stdlib.result
(** Fresh strict host load and physical workspace restore precede every pass.
    Existing judgments/commit progress need no live worker. Otherwise rebind the
    original installation and read before admission. Submit only after a newly
    published intent and authoritative absence; only an explicit capacity reply
    permits another admission of this same ID. Lost replies, journal uncertainty,
    Already_stored and absence after dispatch never permit another submission.
    Consecutive equal observations reuse the current record without another
    journal write; changed kind/evidence remains a new original fact.
    Full terminal/domain validation precedes Judgment_retained.
    Dispatch_pending first observes the original host Exact record by its
    configured installation and captured request/schema. A strict retained
    terminal needs no live worker/export and can finish while Off. Absent/open
    records still require the normal worker read; a malformed/conflicting host
    record refuses without that fallback. Started/open is never inferred final.
    Captured/Admission_wait still require live export authority before admission.
    This performs no domain save, observer completion or automatic successor/narrowing. Caller
    holds the original workspace lease and serializes this owner. *)
type commit_result = Commit_waiting of Lane_addon_tool_request_owner.retained
  | Committed of Lane_addon_tool_request_owner.retained
  | Commit_conflict of Lane_addon_tool_request_owner.retained
val settle : config:Workspace.config -> request_id:string -> (commit_result, error) Stdlib.result
(** Caller holds the workspace process lease and serializes this entire pass,
    including domain writes, against all other Curator work. Strictly reload
    the original capture and answered judgment; derive and cross-check complete
    before/after states before using commit progress. Fresh after confirms with
    no save. A fresh before plus newly Stored intent/retry permits one save;
    Already_stored/Unconfirmed never do. Recovered intent first records unknown
    and re-observes before retry. Save success still requires a fresh after read.
    Error/cancellation may follow publication; preserve the intent and reload.
    Conflicts never overwrite current state. Classification rechecks readable
    selected facts and vanished ledger members; briefing rechecks current ledger
    sources and prompt contract, preserving additions and partial publication.
    Each needed Briefing eligibility check resolves its current contract on the
    caller Eio fiber before offloading disk reads with that immutable value.
    Classification and an already applied after-state do not resolve a prompt.
    No worker, model, observer completion, successor or scheduler runs here. *)
type successor_result = Indivisible of Lane_addon_tool_request_owner.retained
  | Successor_waiting of Lane_addon_tool_request_owner.retained
  | Successor_ready of { parent:Lane_addon_tool_request_owner.retained;
      child:Lane_addon_tool_request_owner.retained }
val successor_is_current : config:Workspace.config -> capture:Workspace_memory_execution_capture.t ->
  (bool, error) Stdlib.result
(** Observe whether an original candidate belongs to the current continuation
    frontier: fresh live semantic destination, readable selected sources and
    matching current captured Ledger or prepared Briefing state/contract.
    A known mismatch is false; unavailable authority/domain reads remain Error.
    Briefing contract resolution runs on the caller fiber only after destination
    and prepared-state checks match; no live resolver runs in a system thread.
    This neither publishes nor grants a successor. The serialized caller must
    still invoke [narrow], which checks fresh admission before a new intention. *)
val narrow : config:Workspace.config -> request_id:string -> (successor_result, error) Stdlib.result
(** The serialized workspace owner may replace a positively size-refused
    original batch with one whole-prefix child. Persist the child's ID and
    complete immutable capture in its parent before retaining the child; read
    the actual child back and acknowledge it in the parent before returning it.
    Recovered intent always reuses that ID. Unconfirmed publication is not
    permission to mint another child. No worker RPC, domain write or automatic
    scheduling runs here. New intentions require a currently live configured
    installation with matching package/tool and semantic configuration revision,
    under Runtime's fresh configuration/action publication boundary. Raw source
    bytes remain original provenance, so formatting and Off/On do not rewrite
    the child. Existing Subdividing/Subdivided recovery remains local while Off.
    Briefing preserves its original prepared state.
    Caller holds the workspace process lease throughout, including retries. *)
type original = private {
  capture : Workspace_memory_execution_capture.t;
  record : Lane_addon_tool_request_owner.retained;
}
val discover : config:Workspace.config -> (original list, error) Stdlib.result
(** Strict complete original discovery and physical/ancestry validation precede
    every recovery write. Recover only already durable Subdividing intentions,
    including child-retained-before-parent-ACK. Without a recoverable intention,
    restore the already validated inventory from this pass. After any recovery,
    freshly discover and fully restore every original. A missing acknowledged
    child, malformed member or incomplete publication rejects the inventory;
    no partial list is complete.
    Works locally while Off, minting no ID or new successor intention. It does
    not dispatch, settle domains, prepare observers or schedule new roots.
    Caller holds the workspace process lease and serializes the entire pass;
    the result is an observation, not a grant to bypass fresh effect checks. *)
type observation = {
  original : Lane_addon_tool_request_owner.retained;
  registration : Workspace_memory_observation_receipt.registration;
  completion : Workspace_memory_observation_receipt.completion option;
}
val prepare_observation : config:Workspace.config -> request_id:string ->
  (observation, error) Stdlib.result
(** Fresh physical capture/ancestry restore precedes immutable observer intent
    preparation. Reuse and revalidate existing pending/acknowledged receipts;
    obtain time only for a new intent. Existing domain progress can finish
    while observer registration remains pending. No registry read/write, model,
    worker, domain save, successor, live admission or scheduler runs here.
    Available while Off for an existing owner; it cannot create a new request.
    Uncertain publication requires fresh reload. Caller holds the original
    workspace process lease and serializes the complete operation. *)
type observation_error =
  | Original_observation_failed of error
  | Registry_delivery_failed of Exact_lane_run_registry.reconciliation_error
val observation_error_to_string : observation_error -> string
val deliver_observation : config:Workspace.config -> request_id:string ->
  (observation, observation_error) Stdlib.result
(** Prepare/revalidate the original immutable receipts, conditionally publish
    pending facts into the real exact registry, then release registry locks and
    freshly restore the same physical original and receipt digests before ACK.
    Registration ACK precedes completion ACK. Already acknowledged facts do not
    repopulate evicted registry history. A failed/lost ACK retries this observer
    path, never primary work. [Registry_delivery_failed] preserves retry demand
    without blocking new primary work. [Original_observation_failed] includes
    prepare, invalid original registry input, fresh ACK validation and final
    restore failures; these still block
    new primary work because original journal integrity is unconfirmed.
    Caller holds the original workspace lease and
    serializes the entire pass. Available while Off; no model/worker/domain save. *)
module For_testing : sig
  val deliver_observation : store:Lane_addon_store.t -> base_path:string ->
    registry:Exact_lane_run_registry.t -> request_id:string -> now:(unit -> float) ->
    (observation, observation_error) Stdlib.result
  val resume : store:Lane_addon_store.t -> base_path:string -> request_id:string ->
    call:(arguments:Yojson.Safe.t -> (Mcp_protocol.Mcp_types.tool_result, error) Stdlib.result) ->
    (result, error) Stdlib.result
  (** Same strict host/worker consumer; only the Runtime call edge is supplied. *)
  val settle : store:Lane_addon_store.t -> base_path:string -> request_id:string ->
    briefing_contract:(unit -> string) ->
    save:(Workspace_memory_execution_capture.expected_commit -> (unit, string) Stdlib.result) ->
    (commit_result, error) Stdlib.result
  (** Same real journal, restore, domain load, freshness and recovery. Only the
      effective briefing contract and domain save edge are supplied. The contract
      callback runs on the caller fiber at each required Briefing eligibility
      check, including recovery; it is not called for Classification or an
      already applied domain after-state. The save edge remains offloaded. Faults at
      this edge are not evidence of an actual filesystem failure stage. *)
  val narrow : store:Lane_addon_store.t -> base_path:string -> request_id:string ->
    (successor_result, error) Stdlib.result
  (** Same actual strict parent/child journal and ancestry; no substituted
      publication edge or worker. *)
  val discover : store:Lane_addon_store.t -> base_path:string ->
    (original list, error) Stdlib.result
  (** Same actual complete discovery, physical forest validation and existing
      successor recovery. Only the store root/workspace is supplied. *)
  val discover_observed : store:Lane_addon_store.t -> base_path:string ->
    after_inventory:(unit -> unit) -> (original list, error) Stdlib.result
  (** Same discovery, with a callback after each actual strict [Owner.discover]
      return (including errors), before workspace/forest validation. The callback
      runs in the inventory system thread, outside the store's inventory lock;
      it neither supplies nor replaces the read result. This fixture edge can
      observe reads and arrange a physical change before recovery/revalidation. *)
  val prepare_observation : store:Lane_addon_store.t -> base_path:string ->
    request_id:string -> now:(unit -> float) -> (observation, error) Stdlib.result
  (** Same real journal and strict restore; only the first observer clock edge
      is supplied. This is not registry delivery or measured provider time. *)
end
