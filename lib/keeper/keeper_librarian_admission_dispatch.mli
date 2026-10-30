(** Dispatch and resume one already restored original host request. The caller
    holds the workspace process lease, serializes this owner, and has freshly
    restored its physical capture, revisions and original partition ancestry. *)
type error = Lane_addon_submit_once.error =
  | Unavailable of string | Rejected of string | Uncertain of string
val error_to_string : error -> string

type wait = Lane_addon_submit_once.wait = Capacity | Worker_pending | Worker_unknown
  | Worker_unreachable | Missing_after_dispatch | Journal_recheck
type result =
  | Pending of wait * Lane_addon_tool_request_owner.retained
  | Answered of Lane_addon_exact.final * Lane_addon_tool_request_owner.retained
  | Refused of Lane_addon_exact.final * Lane_addon_tool_request_owner.retained
  | Commit_pending of Lane_addon_tool_request_owner.retained
  | Settled of Lane_addon_tool_request_owner.retained

type call =
  expected:Keeper_librarian_admission_capture.destination ->
  original:Lane_addon_tool_request_owner.retained ->
  arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, Lane_addon_submit_once.call_error) Stdlib.result
(** Actual Runtime worker-call edge. It must freshly validate the original
    configured installation, package/tool and semantic configuration revision
    under the live Runtime effect boundary immediately before dispatch, and
    report a failure of that validation as [Not_sent]. The
    original source byte revision remains provenance, not an equality gate. No
    fallback, manual installation or invented revision may satisfy this port.
    Cancellation propagates; uncertain admission never permits resubmission. *)

val resume : store:Lane_addon_store.t -> config:Workspace.config ->
  reserved:string list -> destination:Keeper_librarian_admission_capture.destination ->
  original:Lane_addon_tool_request_owner.retained -> capture:Keeper_librarian_admission_capture.t ->
  exact:Lane_addon_exact.request ->
  schema:Yojson.Safe.t -> validate_answer:(Yojson.Safe.t -> (unit, string) Stdlib.result) ->
  call:call -> (result, error) Stdlib.result
(** Read original host terminal state before consulting a live worker, allowing
    retained completion while Off. Otherwise validate the fresh Runtime export
    and its exact original destination before read/admission. Strict worker
    replies are bound to this request and its original schema. A full pure
    answer validation and mandatory original host terminal/latest execution
    confirmation precede Judgment_retained, including restored judgments.
    A worker-supplied Finished reply alone is never host execution evidence.

    The shared {!Lane_addon_submit_once.resume} owns the journal: the fresh
    destination check runs before Dispatch_intended, only a newly Stored intent
    and authoritative pre-admission absence can submit, and Already_stored,
    Unconfirmed, a lost reply or absence after dispatch cannot. A submission
    capacity refusal or a submit refused before sending declines the intent
    and permits a later admission. Equal
    execution observations reuse the retained record. This helper performs no
    Memory mutation, queue ACK, domain commit, successor or scheduler action. *)
