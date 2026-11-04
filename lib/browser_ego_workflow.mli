(** Fixed SDK call loop used only with a decoded native workflow. Caller Page
    source is data for Ego's browser expression channel; the Node/host process
    never executes it. Ego owns locator/actionability/waits. *)
val script : string

val native_error_script : string
(** Fixed pure [nativeErrorObservation(error)] procedure shared by ordinary
    native typing and workflows. It projects only recognized SDK diagnostics;
    caller data and error messages never become native diagnostic authority. *)

type evaluation_timeout = {
  timeout_ms : float;
  execution_stopped : bool;
  may_have_late_effects : bool;
  page_responsive : bool;
}
type navigation_wait = Commit | Dom_content_loaded | Load | Network_idle
type navigation_timeout = {
  timeout_ms : float;
  committed : bool;
  url : string option;
  ready_state : string option;
  wait_until : navigation_wait;
}
(** [url] and [ready_state] are absent when the SDK supplied no observation;
    absence is never replaced by an empty string or inferred page state. *)
type popup_event_error = { name : string option; code : string option; timeout_ms : float option }
type native_dialog = {
  kind : Browser_surface.dialog_kind;
  message : string;
  default_prompt : string option;
  url : string option;
  frame_id : string option;
  has_browser_handler : bool option;
}
type dialog_error = { method_ : string; session_id : string; dialog : native_dialog }
type native_error = Evaluation_timed_out of evaluation_timeout
  | Navigation_timed_out of navigation_timeout | Popup_event_failed of popup_event_error
  | Page_dialog_opened of dialog_error
(** Native SDK diagnostics, preserved as observations. Stopped execution may
    still have late effects, and committed navigation may not have reached the
    requested lifecycle. These fields never authorize replay, release held
    input, or replace workflow progress with an inferred completion. *)

val validate_native_error : Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Validate one recognized SDK diagnostic through the same strict parser used
    by [decode]. Success retains its exact JSON fields; it supplies no execution,
    completion or input-release proof. Popup event observations are separate. *)

type page_identity = { space_id : int; label : string; target_id : string;
  opened_by : Browser_surface.ego_page_origin }
type transition = { index : int; source : page_identity; popup : page_identity; selected : bool }
type pages = { source : page_identity; current : page_identity; transitions : transition list }
(** Canonical native inventory identities. A raw popup event handle can expose
    only Space and label; its target and origin come from the unique same-Space
    inventory row. These observations do not grant input or close authority. *)

type outcome =
  | Completed of { reply : Yojson.Safe.t; input : Browser_ego_release.settled; pages : pages option }
  | Stopped of { receipt : Yojson.Safe.t; message : string;
      effect_started : bool; completed_effect : bool; input : Browser_ego_release.t;
      native_error : native_error option; pages : pages option;
      refused_before_press : Browser_ego_release.resolution option }
      (** [refused_before_press]: the failed step was a click, double click,
          drag or popup trigger the SDK refused before its press, with the
          SDK's kind. The receipt's failure then carries [refusedBeforePress]. *)

(** Validates step indices/methods, native observation receipt types,
    saving-Fetch provenance/download ID/filename and native Download cancel
    return receipts against the exact request,
    progress/effect flags and final snapshot
    fields against the exact request, including the SDK's optional
    [failure.nativeError] evaluation/navigation timeout code, nonnegative finite
    timeout, boolean observations and declared navigation lifecycle. Native
    dialog errors require the SDK method, session ID and recognized dialog
    type/message. Optional dialog [defaultPrompt], URL, frame ID and browser
    handler observations are validated when present; absence is not an inferred
    value. Optional navigation URL/readiness observations remain absent when
    omitted. The public receipt retains the SDK field names. A dialog error
    preserves failed progress and never establishes execution completion or
    input release.
    A malformed post-execution reply is
    unknown, never a proof that no effect started.

    Input completion is derived by the one [Browser_ego_release.judge] from
    declared SDK receipts or independently verified native windows, never the
    script's [inputReleased]. Every entered holding step needs its exact
    receipt or verified SDK-tail evidence. A step that never returned or whose
    native window contains interruption remains unconfirmed. [Settled
    No_hold] means no holding step was entered. A failed reply that reports a
    held input is [Stopped] with the reason in [Unconfirmed]; a successful reply
    cannot report one. *)
val decode : windows:Browser_ego_raw_type.context option ->
  Browser_lane.Native_workflow.t -> Yojson.Safe.t -> (outcome, string) result
(** [windows] is Host-owned Pending/step data. Raw progress without it refuses;
    returned receipts are rebuilt public projections, never private captures. *)
