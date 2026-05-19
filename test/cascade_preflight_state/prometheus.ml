(** Stub Prometheus module used only by the standalone test build.

    The real [Prometheus] module pulls in [prometheus_store], [eio], and
    a large dependency closure. For unit tests of
    [Cascade_preflight_state] we only need [inc_counter] to be callable
    without raising — the test asserts on [record_outcome], not on
    counter values.

    This stub mirrors the API surface used by
    [cascade_preflight_state.ml] (single function, named-arg form). *)

type label = string * string

let inc_counter (_metric : string) ?(labels : label list = []) ?(delta : float = 1.0) () =
  ignore labels;
  ignore delta;
  ()
;;
