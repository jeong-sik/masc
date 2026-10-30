(** The instant a tool execution started.

    [started] is abstract and {!start} is its only constructor: it reads the
    clock at the call.  A caller therefore cannot hand {!Tool_result} a
    fabricated epoch such as [0.0], which used to record [duration_ms] as the
    whole Unix epoch (#27392).  Whoever begins the execution calls {!start};
    handlers only thread the value through. *)

type started

(** Read the clock now. *)
val start : unit -> started

(** Epoch seconds at {!start}, for callers that also use the dispatch
    instant as their own "now". *)
val started_at : started -> float

(** Milliseconds between {!start} and now. *)
val elapsed_ms : started -> float
