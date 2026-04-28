(** Emit an OCaml regression test from a parsed TLC violating state.

    The generated test asserts that the system never reaches the recorded
    violating state. It is a *negative* test: if the runtime ever produces
    a state matching all bindings, the test fails. *)

val emit_let_test : Ttrace_parser.state -> string
(** [emit_let_test state] returns a [let%test "..." = ...] expression as a
    string. The test name encodes the originating spec module so that
    failures point back to the TLC trace. *)
