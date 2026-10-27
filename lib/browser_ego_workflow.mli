(** Fixed SDK call loop used only with a decoded native workflow. Caller Page
    source is data for Ego's browser expression channel; the Node/host process
    never executes it. Ego owns locator/actionability/waits. *)
val script : string

(** What a workflow knows about the button or key it held. [Released]: it was
    released, or never held. [Cut_by_dialog]: the SDK reported that a JavaScript
    dialog cut the input short, so the page may have missed the release, but no
    reply was lost. [Unconfirmed]: nothing reported why the release is unknown. *)
type input_after_stop = Released | Cut_by_dialog | Unconfirmed

type outcome = Completed of Yojson.Safe.t
  | Stopped of { receipt : Yojson.Safe.t; message : string;
      effect_started : bool; completed_effect : bool; input : input_after_stop }

(** Validates step indices/methods, native observation receipt types,
    saving-Fetch provenance/download ID/filename against the exact request,
    progress/effect flags and final snapshot
    fields against the exact request. A malformed post-execution reply is
    unknown, never a proof that no effect started. *)
val decode : Browser_lane.Native_workflow.t -> Yojson.Safe.t -> (outcome, string) result
