---- MODULE NestedSample_TTrace_1700000001 ----
EXTENDS Sequences, TLCExt, Naturals, TLC

_inv ==
    ~(
        TLCGet("level") = Len(_TETrace)
        /\
        active = (TRUE)
        /\
        retries = (3)
    )
====

---- MODULE NestedSample_TTrace_1700000001_TETrace ----
EXTENDS NestedSample_TTrace_1700000001, TLC

trace ==
    <<
    ([active |-> FALSE, retries |-> 0, config |-> [host |-> "init", port |-> 0]]),
    ([active |-> TRUE, retries |-> 1, config |-> [host |-> "localhost", port |-> 8080]]),
    ([active |-> TRUE, retries |-> 3, config |-> [host |-> "localhost", port |-> 8080]])
    >>
----

====
