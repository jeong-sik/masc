(** Original Curator observer data. Callers first restore the physical capture
    and full acknowledged ancestry under the serialized workspace owner. *)
type registration = private {
  run_id : string;
  actor : string;
  input : Yojson.Safe.t;
  receipt : Lane_addon_request_receipt.receipt;
}
val registration : capture:Workspace_memory_execution_capture.t ->
  original:Lane_addon_tool_request_owner.retained -> observed_at:float ->
  (registration, string) result
val restore_registration : capture:Workspace_memory_execution_capture.t ->
  original:Lane_addon_tool_request_owner.retained ->
  Lane_addon_request_receipt.receipt -> (registration, string) result
(** Reconstruct and compare the entire original versioned payload, captured
    request/destination/digest, deterministic run ID, input and first time.
    No current prompt/configuration or registry state is substituted. *)
type disposition =
  | Confirmed_commit of Lane_addon_request_progress.commit
  | Domain_conflict of Lane_addon_request_progress.commit * Yojson.Safe.t
  | Before_dispatch_refusal of Yojson.Safe.t
  | Execution_refusal of Lane_addon_exact.final
type completion = private {
  registration : registration;
  disposition : disposition;
  selected_slot : string option;
  provider_usage : Lane_addon_exact.usage option;
  receipt : Lane_addon_request_receipt.receipt;
}
val completion : capture:Workspace_memory_execution_capture.t ->
  original:Lane_addon_tool_request_owner.retained -> registration:registration ->
  observed_at:float -> (completion, string) result
val restore_completion : capture:Workspace_memory_execution_capture.t ->
  original:Lane_addon_tool_request_owner.retained -> registration:registration ->
  Lane_addon_request_receipt.receipt -> (completion, string) result
(** Derive only from Finished, Conflicted or an original refusal. Revalidate the
    complete original Answered judgment and before/after plan; conflicts/refusal
    are never success. Conflict evidence is either a complete tagged domain state
    or exactly [state] and an opaque string [reason] wrapping that same state.
    Validate the full Ledger/Briefing state in either shape and retain the
    diagnostic without interpreting it. The same parent's refusal survives
    successor linking.
    Slot/basic usage come only from the actual Answered final. Missing cache,
    cost, provider start/duration remain absent, never inferred as zero.
    Observer wall time is not execution timing. All operations are pure and
    establish neither registry durability nor effect/retry permission. *)
