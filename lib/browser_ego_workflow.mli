(** Fixed SDK call loop used only with a decoded native workflow. Caller Page
    source is data for Ego's browser expression channel; the Node/host process
    never executes it. Ego owns locator/actionability/waits. *)
val script : string

type evaluation_timeout = {
  timeout_ms : float;
  execution_stopped : bool;
  may_have_late_effects : bool;
  page_responsive : bool;
}
type native_error = Evaluation_timed_out of evaluation_timeout
(** Native SDK evaluation diagnostics, preserved as observations. Stopped
    execution may still have late effects; these fields never authorize replay,
    release held input, or prove that an action did not start. *)

type outcome =
  | Completed of { reply : Yojson.Safe.t; input : Browser_ego_release.settled }
  | Stopped of { receipt : Yojson.Safe.t; message : string;
      effect_started : bool; completed_effect : bool; input : Browser_ego_release.t;
      native_error : native_error option }

(** Validates step indices/methods, native observation receipt types,
    saving-Fetch provenance/download ID/filename against the exact request,
    progress/effect flags and final snapshot
    fields against the exact request, including the SDK's optional
    [failure.nativeError] evaluation-timeout code, nonnegative finite timeout and
    boolean observations. The public receipt retains the SDK field names.
    A malformed post-execution reply is
    unknown, never a proof that no effect started.

    The release state is derived from the answers the SDK declared for the
    input-holding steps ([Browser_ego_release.judge]), never from the script's
    [inputReleased]. A reply that reports a released input is accepted only when
    every input-holding step that was entered is [Receipt_without_dialog]. A
    step that never returned or left a dialog open makes it an error. [Settled
    No_hold] means no holding step was entered. A failed reply that reports a
    held input is [Stopped] with the reason in [Unconfirmed]; a successful reply
    cannot report one. *)
val decode : Browser_lane.Native_workflow.t -> Yojson.Safe.t -> (outcome, string) result
