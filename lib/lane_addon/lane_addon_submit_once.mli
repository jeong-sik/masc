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
type ('original, 'final) result =
  | Awaiting of wait * 'original
  | Final of 'final
  | Commit_pending of 'original
  | Settled of 'original
(** ['original] is what the caller resumed from: a record for {!resume}, a
    retained original for {!resume_retained}. *)

type publication =
  | New of Lane_addon_tool_request_owner.retained
  | Acknowledged of Lane_addon_tool_request_owner.retained
val advance : store:Lane_addon_store.t -> Lane_addon_tool_request_owner.retained ->
  Lane_addon_request_progress.event -> (publication, error) Stdlib.result
(** Blocking store write; offload it in Eio. [Unconfirmed] is [Uncertain]. *)
val record : publication -> Lane_addon_tool_request_owner.retained

type 'body source = {
  identity : Lane_addon_exact.identity;
      (** The request's ID and digest, as the owner kept them. *)
  load : unit -> ('body, error) Stdlib.result;
      (** Read and validate the original's body. Called at most once per
          {!resume}, on entering a branch that needs it. *)
  request : 'body -> Lane_addon_exact.request;
  schema : 'body -> Yojson.Safe.t;
}

type unadmitted =
  | Admit  (** Read the worker and admit the original, as before. *)
  | End_replaced of Yojson.Safe.t
      (** The declaration the original was captured for was replaced. The
          value is the owner's evidence, retained with the refusal. *)
(** What the owner says about an original no worker has received. *)

val destination_relation : config:Workspace.config -> reserved:string list -> label:string ->
  Lane_addon_captured_destination.t ->
  (Lane_addon_captured_destination.relation * Lane_addon_captured_destination.t, error) Stdlib.result
(** How the destination an original was captured for stands to the one the
    configuration publishes for its tool now, and that destination. A
    conflicting export is [Rejected]; a missing one is [Unavailable]: the
    Add-on is off or not ready. [label] names the owner in those errors. Read
    under the configuration and action serializers. *)

val confirm_destination : config:Workspace.config -> reserved:string list -> label:string ->
  Lane_addon_captured_destination.t -> (unit, error) Stdlib.result
(** {!destination_relation} is [Same]. Any other relation is [Rejected]. The
    completed-history and admission owners' pre-send check is this one
    function. *)

val resume : store:Lane_addon_store.t -> label:string ->
  original:Lane_addon_tool_request_owner.Record.t -> source:'body source ->
  decode_final:('body -> Yojson.Safe.t -> (Lane_addon_exact.final, string) Stdlib.result) ->
  unadmitted:(unit -> (unadmitted, error) Stdlib.result) ->
  prepare:(unit -> (unit, error) Stdlib.result) -> call:call ->
  terminal:('body -> Lane_addon_tool_request_owner.Record.t -> Lane_addon_exact.final ->
    ('final, error) Stdlib.result) ->
  ((Lane_addon_tool_request_owner.Record.t, 'final) result, error) Stdlib.result
(** Existing judgments, refusals and commit progress need no live worker.
    Dispatch_pending first restores a proven terminal publication in the
    original host Exact record by its configured installation. Confirmed
    latest-attempt proof can finish the original even when the worker lost
    its listing or is Off. This recovery invokes no provider or worker RPC;
    absent/unproven execution remains unresolved and never authorizes submit.

    Captured and Admission_wait ask [unadmitted] before anything else.
    [End_replaced evidence] stores [Refused {stage = Before_dispatch; evidence}]
    and returns [Settled]; no worker RPC is made and no intent is written. An
    [Unavailable] answer is [Awaiting Worker_unreachable] with the journal
    unchanged, and a [Rejected] or [Uncertain] answer is returned as the error.
    A dispatched original never asks. On [Admit] they read the worker. Only
    authoritative absence leads to admission, and [prepare] runs every pre-send check
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

(** The machine runs on the record. It reads the body through [source.load]
    in these branches only, once, and before it writes anything for them:
    admission (after [prepare], before Dispatch_intended); a retained
    judgment; a refusal retained at execution; a Dispatch_pending original
    whose host Exact record has a final or an execution link
    ({!Lane_addon_exact.observe_open} answers [Needs_request]); and a worker
    reply that says finished, whose state is read first and whose result is
    read after the body. A failed [load] is returned as the error of this
    call and leaves the journal unchanged. A finished result that does not
    decode is still an observation of unknown outcome.

    A Dispatch_pending original whose host record is open or absent and whose
    worker answers pending or absent, commit progress and settled phases read
    no body. [decode_final] and [terminal] cannot be called without one. *)

val resume_retained : store:Lane_addon_store.t -> label:string ->
  original:Lane_addon_tool_request_owner.retained -> request:Lane_addon_exact.request ->
  schema:Yojson.Safe.t ->
  decode_final:(Yojson.Safe.t -> (Lane_addon_exact.final, string) Stdlib.result) ->
  unadmitted:(unit -> (unadmitted, error) Stdlib.result) ->
  prepare:(unit -> (unit, error) Stdlib.result) -> call:call ->
  terminal:(Lane_addon_tool_request_owner.retained -> Lane_addon_exact.final ->
    ('final, error) Stdlib.result) ->
  ((Lane_addon_tool_request_owner.retained, 'final) result, error) Stdlib.result
(** {!resume} for an owner that already holds the body: nothing is loaded, and
    every record the machine returns is put back beside that body with
    {!Lane_addon_tool_request_owner.rebind}. *)
