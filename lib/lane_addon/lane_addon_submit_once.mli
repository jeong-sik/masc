(** Submit-once admission of one restored original host request to its Add-on
    worker. Every original host owner (Workspace Curator, Keeper Librarian)
    drives the same journal through this machine; each supplies only its own
    restore, binding, Runtime call edge and terminal validation. The caller
    holds the workspace process lease and serializes this owner. *)
type error = Unavailable of string | Rejected of string | Uncertain of string
val error_to_string : error -> string

val error_of_runtime : Lane_addon_runtime.tool_call_error -> error

type call_error =
  | Not_sent of error
      (** Nothing of this request left the host: export lookup, destination
          or owner recheck, or a Runtime host refusal refused it first. *)
  | Sent_unknown of string
      (** The request may have reached the worker; its outcome is unknown. *)
type call = arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, call_error) Stdlib.result
(** The consumer's Runtime call edge. Report [Not_sent] only for failures that
    precede the worker RPC. *)

val call_error_of_runtime : Lane_addon_runtime.tool_call_error -> call_error
(** For calls without controller mediation ([call_exported_tool_with_principal],
    [call_captured_tool_request]): Runtime [Unavailable] and host refusals
    happen before the worker RPC, and only [Outcome_unknown] follows it. *)

type wait = Capacity | Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type 'final result =
  | Awaiting of wait * Lane_addon_tool_request_owner.retained
  | Final of 'final
  | Commit_pending of Lane_addon_tool_request_owner.retained
  | Settled of Lane_addon_tool_request_owner.retained

type publication =
  | New of Lane_addon_tool_request_owner.retained
  | Acknowledged of Lane_addon_tool_request_owner.retained
val advance : store:Lane_addon_store.t -> Lane_addon_tool_request_owner.retained ->
  Lane_addon_request_progress.event -> (publication, error) Stdlib.result
(** Blocking store write; offload it in Eio. [Unconfirmed] is [Uncertain]. *)
val record : publication -> Lane_addon_tool_request_owner.retained

val resume : store:Lane_addon_store.t -> label:string ->
  original:Lane_addon_tool_request_owner.retained -> request:Lane_addon_exact.request ->
  schema:Yojson.Safe.t ->
  decode_final:(Yojson.Safe.t -> (Lane_addon_exact.final, string) Stdlib.result) ->
  prepare:(unit -> (unit, error) Stdlib.result) -> call:call ->
  terminal:(Lane_addon_tool_request_owner.retained -> Lane_addon_exact.final ->
    ('final, error) Stdlib.result) ->
  ('final result, error) Stdlib.result
(** Existing judgments, refusals and commit progress need no live worker.
    Dispatch_pending first observes the original host Exact record by its
    configured installation, so a retained terminal can finish while Off.

    Captured and Admission_wait read the worker first. Only authoritative
    absence leads to admission, and [prepare] runs every pre-send check
    before Dispatch_intended is written. An [Unavailable] pre-send check or
    [Not_sent (Unavailable _)] read returns [Awaiting Worker_unreachable] in
    either pre-admission phase without changing the journal or sending a
    submission. A later wake reads and admits only this same original request;
    [Rejected] and [Uncertain] checks remain errors. A newly Stored intent is the only
    permission to submit; Already_stored is a journal recheck. When the submit
    call reports [Not_sent], the intent admitted nothing, so it is declined in
    place and the next pass may submit the same request again. [Sent_unknown],
    a lost or malformed reply and absence after dispatch never permit another
    submission; an explicit capacity reply to the submission is the only
    other admission retry. A [Not_sent] read leaves the journal unchanged:
    an [Unavailable] one is [Awaiting Worker_unreachable], a refused one is
    returned as its error.
    Consecutive equal observations reuse the record without another write.

    [decode_final] interprets worker and retained final JSON for this original.
    A decoder accepting more than the strict schema must establish its original
    host evidence before returning. [terminal] validates a final result before Judgment_retained or Refused is
    written and again on the published record; [label] names this owner in
    refusals. Refusal evidence retains the host's unknown cause. A worker's
    [Outcome_unknown] is accepted only after an authoritative host observation
    confirms [Retained_unknown]; missing/open or contradictory host state is
    rejected. [terminal] still receives the delivered worker-shaped result.
    No domain save, queue ACK, successor or scheduling runs here. *)
