---- MODULE SampleInv_TTrace_1700000000 ----
EXTENDS Sequences, TLCExt, Naturals, TLC

_inv ==
    ~(
        TLCGet("level") = Len(_TETrace)
        /\
        tool_calls_made = (1)
        /\
        turn_phase = ("failed")
        /\
        provider_error = ("internal")
        /\
        mutating_committed = (1)
        /\
        retry_count = (0)
        /\
        retry_performed = (FALSE)
    )
====
