---- MODULE CheckpointTrim_TTrace_1776221874 ----
EXTENDS Sequences, TLCExt, Toolbox, Naturals, TLC, CheckpointTrim

_expression ==
    LET CheckpointTrim_TEExpression == INSTANCE CheckpointTrim_TEExpression
    IN CheckpointTrim_TEExpression!expression
----

_trace ==
    LET CheckpointTrim_TETrace == INSTANCE CheckpointTrim_TETrace
    IN CheckpointTrim_TETrace!trace
----

_inv ==
    ~(
        TLCGet("level") = Len(_TETrace)
        /\
        result = (<<"ToolResult", "Text", "Text">>)
        /\
        msgs = (<<"ToolUse", "ToolResult", "Text", "Text">>)
        /\
        pc = ("done")
    )
----

_init ==
    /\ result = _TETrace[1].result
    /\ msgs = _TETrace[1].msgs
    /\ pc = _TETrace[1].pc
----

_next ==
    /\ \E i,j \in DOMAIN _TETrace:
        /\ \/ /\ j = i + 1
              /\ i = TLCGet("level")
        /\ result  = _TETrace[i].result
        /\ result' = _TETrace[j].result
        /\ msgs  = _TETrace[i].msgs
        /\ msgs' = _TETrace[j].msgs
        /\ pc  = _TETrace[i].pc
        /\ pc' = _TETrace[j].pc

\* Uncomment the ASSUME below to write the states of the error trace
\* to the given file in Json format. Note that you can pass any tuple
\* to `JsonSerialize`. For example, a sub-sequence of _TETrace.
    \* ASSUME
    \*     LET J == INSTANCE Json
    \*         IN J!JsonSerialize("CheckpointTrim_TTrace_1776221874.json", _TETrace)

=============================================================================

 Note that you can extract this module `CheckpointTrim_TEExpression`
  to a dedicated file to reuse `expression` (the module in the 
  dedicated `CheckpointTrim_TEExpression.tla` file takes precedence 
  over the module `CheckpointTrim_TEExpression` below).

---- MODULE CheckpointTrim_TEExpression ----
EXTENDS Sequences, TLCExt, Toolbox, Naturals, TLC, CheckpointTrim

expression == 
    [
        \* To hide variables of the `CheckpointTrim` spec from the error trace,
        \* remove the variables below.  The trace will be written in the order
        \* of the fields of this record.
        result |-> result
        ,msgs |-> msgs
        ,pc |-> pc
        
        \* Put additional constant-, state-, and action-level expressions here:
        \* ,_stateNumber |-> _TEPosition
        \* ,_resultUnchanged |-> result = result'
        
        \* Format the `result` variable as Json value.
        \* ,_resultJson |->
        \*     LET J == INSTANCE Json
        \*     IN J!ToJson(result)
        
        \* Lastly, you may build expressions over arbitrary sets of states by
        \* leveraging the _TETrace operator.  For example, this is how to
        \* count the number of times a spec variable changed up to the current
        \* state in the trace.
        \* ,_resultModCount |->
        \*     LET F[s \in DOMAIN _TETrace] ==
        \*         IF s = 1 THEN 0
        \*         ELSE IF _TETrace[s].result # _TETrace[s-1].result
        \*             THEN 1 + F[s-1] ELSE F[s-1]
        \*     IN F[_TEPosition - 1]
    ]

=============================================================================



Parsing and semantic processing can take forever if the trace below is long.
 In this case, it is advised to uncomment the module below to deserialize the
 trace from a generated binary file.

\*
\*---- MODULE CheckpointTrim_TETrace ----
\*EXTENDS IOUtils, TLC, CheckpointTrim
\*
\*trace == IODeserialize("CheckpointTrim_TTrace_1776221874.bin", TRUE)
\*
\*=============================================================================
\*

---- MODULE CheckpointTrim_TETrace ----
EXTENDS TLC, CheckpointTrim

trace == 
    <<
    ([result |-> <<>>,msgs |-> <<"ToolUse", "ToolResult", "Text", "Text">>,pc |-> "trim"]),
    ([result |-> <<"ToolResult", "Text", "Text">>,msgs |-> <<"ToolUse", "ToolResult", "Text", "Text">>,pc |-> "done"])
    >>
----


=============================================================================

---- CONFIG CheckpointTrim_TTrace_1776221874 ----
CONSTANTS
    MaxLen = 5
    MaxCount = 3

INVARIANT
    _inv

CHECK_DEADLOCK
    \* CHECK_DEADLOCK off because of PROPERTY or INVARIANT above.
    FALSE

INIT
    _init

NEXT
    _next

CONSTANT
    _TETrace <- _trace

ALIAS
    _expression
=============================================================================
\* Generated on Wed Apr 15 11:57:54 KST 2026