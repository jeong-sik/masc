(** Emit OCaml regression test artefacts from a parsed TLC violating state.

    The generated tests are *negative*: they encode the trace TLC produced
    when an invariant was violated, and the runtime is required not to
    reproduce that trajectory. Every artefact qualifies values via
    [Tlc_test_gen.Ttrace_parser.V_*] constructors so the generated module
    only needs that one library opened to typecheck. *)

val emit_let_test : Ttrace_parser.state -> string
(** [emit_let_test state] returns a [let%test "spec_violation_<module>"]
    expression as a string. The body is a typed assoc list of the terminal
    violating bindings followed by a TODO marker for the spec-specific
    reachability check. The test name encodes the originating spec module
    so failures point back to the TLC trace. *)

val emit_trace : Ttrace_parser.state -> string
(** [emit_trace state] returns a [let trace_<module> : Tlc_test_gen.\
    Ttrace_parser.step list = [ ... ]] binding as a string. Every step is
    emitted as a typed assoc list of [(field, V_int|V_string|V_bool|V_raw)].

    When [state.steps] is empty (e.g. the input file lacked the
    [<Spec>_TETrace] inner module) the binding is still emitted as the
    empty list so generated callers compile uniformly. *)

val emit_let_test_reachability : Ttrace_parser.state -> string
(** [emit_let_test_reachability state] returns a
    [let%test "spec_violation_<module>_reaches_terminal" = ...] expression
    that consumes the [trace_<module>] binding produced by [emit_trace] and
    asserts the last step matches the terminal violating bindings.

    The test passes (returns [true]) only when the recorded trace ends in
    the violating state. A runtime that diverges from the spec — fewer
    steps, different final field values — flips the assertion to [false],
    surfacing the divergence as a unit-test failure. *)
