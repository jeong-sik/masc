(** Pure validation of an authenticated native event interval around one raw
    keyboard call. This module does not run the SDK, settle Input,
    or make raw typing available. Its callers must supply actual CDP responses
    and the two unchanged native [Page.events] arrays from one serialized
    invocation. Application evaluation results are not such a capture.

    A verified interval identifies the SDK's normal awaited tail, not physical
    keyboard freshness, pre-existing key release, or application success. *)

type page = { space_id : int; native : Browser_surface.ego_page }
type expected

val prepare : command_id:string -> generation:string -> step_index:int ->
  source:page -> current:page -> nonce:string -> world_name:string ->
  binding_name:string -> (expected, string) result
(** Host-owned immutable binding data, not a grant. [source] is the original
    command Page; [current] may be its validated popup in the same Space.
    Names/nonces must be fresh invocation-owned values, never model input. *)

type marker = Start | End
val marker_payload : expected -> marker -> string
(** Exact command/generation/step/nonce and canonical source/current Page+Space
    data for a fixed native binding-call expression which calls the
    binding synchronously, then returns that same string. Native evaluate
    replies must carry that exact string. No caller source is evaluated here. *)

type phase = Page_enable | Runtime_enable | Frame_tree | Isolated_world
  | Add_binding | Bootstrap_events | Before_start | Start_marker | End_marker
  | Interval_events

type unconfirmed =
  | Malformed_native of { phase : phase; detail : string }
  | Context_or_session_changed
  | Document_changed
  | Bounds_missing_or_duplicated
  | Bounds_out_of_order
  | Dialog_opened
  | Unexpected_return
  | No_raw_call
  | Native_failure
  | Control_unavailable
  | Transport_unconfirmed
  | Cancelled
  | Page_binding_changed

type bootstrap
val bootstrap : expected:expected -> page_enable:Yojson.Safe.t ->
  runtime_enable:Yojson.Safe.t -> frame_tree:Yojson.Safe.t ->
  isolated_world:Yojson.Safe.t -> add_binding:Yojson.Safe.t ->
  events:Yojson.Safe.t -> before_start_frame_tree:Yojson.Safe.t ->
  (bootstrap, unconfirmed) result
(** Native setup and a separate pre-window drain. The fresh context's unique ID,
    name, frame and session come from its native context-created event, matched
    to [createIsolatedWorld]'s numeric ID. The root frame/document is rechecked
    before start. Numeric context IDs alone cannot establish the binding.
    The producer must address both markers by the returned [unique_context_id]. *)

val unique_context_id : bootstrap -> string

type native_return =
  | Void_return
  | Value_return of Yojson.Safe.t
  | Did_not_return of unconfirmed
  | Not_invoked
(** [Void_return] means actual JavaScript [answer === undefined], never JSON
    null or a fabricated SDK receipt. A direct SDK/control/transport failure or
    cancellation must remain [Did_not_return]. Protocol-only captures with no
    raw call are [Not_invoked] and cannot establish raw completion. *)

type completion
val classify : bootstrap -> current:page -> returned:native_return ->
  start_reply:Yojson.Safe.t -> end_reply:Yojson.Safe.t ->
  events:Yojson.Safe.t -> (completion, unconfirmed) result
(** Validate successful native marker replies and exactly one authentic start
    then end in the one complete interval drain. Relevant dialog/lifecycle
    boundaries inside those bounds refuse completion; unrelated events and
    changes after end do not erase an established tail. Missing/malformed bounds
    remain unknown. No event-count threshold, timeout, replay, reset or inferred
    physical release is used.

    Later nonholding cleanup (including [Runtime.removeBinding]) is deliberately
    outside these premises. Its failure remains a separate partial outcome.
    If the entire producer response is lost, there is no capture to classify. *)

val matches : completion -> expected -> bool
(** Exact command/generation/step/source/current binding, for later Release/Input
    integration. No conversion to the existing receipt proof is provided. *)

val same_completion : completion -> completion -> bool
(** Exact private invocation and capture equality, including nonce/world/binding.
    Does not expose those values. Contradictory duplicates cannot shed binding. *)

type binding = private {
  command_id : string; generation : string; step_index : int;
  source : page; current : page;
}
val binding : completion -> binding
(** Verified binding for the existing Input settlement check; not a grant. *)

val public_summary : completion -> Yojson.Safe.t
(** Explicit allowlist: SDK-tail/void provenance, step index and Page identities.
    Never raw events, headers, nonce/world/binding or command/generation. *)

val public_unconfirmed : index:int -> unconfirmed -> Yojson.Safe.t
(** Closed reason/phase only, omitting arbitrary diagnostic prose and captures. *)

val producer_contract : expected -> Yojson.Safe.t
(** Fixed native marker/Page member order and closed event policy shared with
    the one fixed producer. Internal validation data, never configuration. *)

val observation : completion -> Yojson.Safe.t
(** Original native setup/responses/arrays and explicit void provenance for
    private retained diagnostics. Native Network events may contain cookies or
    authorization headers; callers must select public diagnostic fields rather
    than forwarding this value to a tool or model. This JSON cannot construct a
    [completion]. *)
