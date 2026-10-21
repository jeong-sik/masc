(** Original Curator admission, worker-result and domain-commit boundaries.
    The existing serialized workspace owner retains the process lease. *)
type error = Unavailable of string | Rejected of string | Uncertain of string
val error_to_string : error -> string
val capture_classification : config:Workspace.config ->
  prompt:Prompt_registry.prompt_resolution -> ledger:Workspace_memory_ledger.t ->
  batch:Workspace_memory_request.batch -> (Workspace_memory_execution_capture.t, error) result
val capture_briefing : config:Workspace.config -> prompt:Prompt_registry.prompt_resolution ->
  batch:Workspace_memory_briefing.batch -> (Workspace_memory_execution_capture.t, error) result
(** Mint once, capture actual live installation provenance and retain before
    any worker RPC. Briefing requires its original prepared state to be saved
    and freshly confirmed first, by the serialized owner. An error may follow
    publication: discover original work before preparing another request.
    No model or domain save runs here. *)
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
    Full terminal/domain validation precedes Judgment_retained. This performs no
    domain save, observer completion or automatic successor/narrowing. Caller
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
    No worker, model, observer completion, successor or scheduler runs here. *)
module For_testing : sig
  val resume : store:Lane_addon_store.t -> base_path:string -> request_id:string ->
    call:(arguments:Yojson.Safe.t -> (Mcp_protocol.Mcp_types.tool_result, error) Stdlib.result) ->
    (result, error) Stdlib.result
  (** Same strict host/worker consumer; only the Runtime call edge is supplied. *)
  val settle : store:Lane_addon_store.t -> base_path:string -> request_id:string ->
    briefing_contract:(unit -> string) ->
    save:(Workspace_memory_execution_capture.expected_commit -> (unit, string) Stdlib.result) ->
    (commit_result, error) Stdlib.result
  (** Same real journal, restore, domain load, freshness and recovery. Only the
      effective briefing contract and domain save edge are supplied. Faults at
      this edge are not evidence of an actual filesystem failure stage. *)
end
