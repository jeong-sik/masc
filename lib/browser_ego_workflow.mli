(** Fixed SDK call loop used only with a decoded native workflow. Caller Page
    source is data for Ego's browser expression channel; the Node/host process
    never executes it. Ego owns locator/actionability/waits. *)
val script : string

type outcome = Completed of Yojson.Safe.t
  | Stopped of { receipt : Yojson.Safe.t; message : string;
      effect_started : bool; completed_effect : bool }
(** Validates step indices/methods, progress/effect flags and final snapshot
    fields against the exact request. A malformed post-execution reply is
    unknown, never a proof that no effect started. *)
val decode : Browser_lane.Native_workflow.t -> Yojson.Safe.t -> (outcome, string) result
