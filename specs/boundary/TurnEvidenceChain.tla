---- MODULE TurnEvidenceChain ----
\* Boundary spec for the MASC turn evidence chain.
\*
\* OAS remains generic: it may provide a turn checkpoint reference, but
\* it does not know about keeper receipts, runtime lenses, tool-call logs,
\* or MASC trust surfaces.  MASC owns the product/operator chain that
\* connects those generic OAS references to MASC evidence.
\*
\* Concrete MASC surfaces:
\*   - Keeper_agent_run execution receipt append
\*   - Keeper_tool_call_log rows
\*   - Raw_trace run refs
\*   - Runtime lens / runtime trust snapshot visibility
\*   - OAS generic checkpoint refs from the pinned SDK
\*
\* Safety rule:
\*   A terminal keeper turn may be shown as evidence-complete only after
\*   MASC has linked the OAS checkpoint ref, tool-call log ref, raw trace
\*   ref, execution receipt, and runtime lens visibility for that turn.
\*
\* Bug model:
\*   TerminalWithoutReceipt and TerminalWithoutCheckpoint model the exact
\*   operator-risk class this spec prevents: a terminal turn appears done
\*   while one durable evidence leg is missing.

EXTENDS Naturals

CONSTANTS MaxTurns

ASSUME MaxTurns \in Nat /\ MaxTurns >= 1

VARIABLES
    next_turn,
    started,
    oas_checkpoint_ref,
    tool_log_ref,
    raw_trace_ref,
    execution_receipt_ref,
    runtime_lens_visible,
    terminal

vars == <<next_turn, started, oas_checkpoint_ref, tool_log_ref, raw_trace_ref,
          execution_receipt_ref, runtime_lens_visible, terminal>>

TurnIds == 1..MaxTurns

TypeOK ==
    /\ next_turn \in 1..(MaxTurns + 1)
    /\ started \subseteq TurnIds
    /\ oas_checkpoint_ref \subseteq started
    /\ tool_log_ref \subseteq started
    /\ raw_trace_ref \subseteq started
    /\ execution_receipt_ref \subseteq started
    /\ runtime_lens_visible \subseteq started
    /\ terminal \subseteq started

Init ==
    /\ next_turn = 1
    /\ started = {}
    /\ oas_checkpoint_ref = {}
    /\ tool_log_ref = {}
    /\ raw_trace_ref = {}
    /\ execution_receipt_ref = {}
    /\ runtime_lens_visible = {}
    /\ terminal = {}

StartTurn ==
    /\ next_turn <= MaxTurns
    /\ started' = started \cup {next_turn}
    /\ next_turn' = next_turn + 1
    /\ UNCHANGED <<oas_checkpoint_ref, tool_log_ref, raw_trace_ref,
                  execution_receipt_ref, runtime_lens_visible, terminal>>

ObserveOasCheckpoint ==
    /\ \E t \in started \ oas_checkpoint_ref :
        oas_checkpoint_ref' = oas_checkpoint_ref \cup {t}
    /\ UNCHANGED <<next_turn, started, tool_log_ref, raw_trace_ref,
                  execution_receipt_ref, runtime_lens_visible, terminal>>

ObserveToolLog ==
    /\ \E t \in started \ tool_log_ref :
        tool_log_ref' = tool_log_ref \cup {t}
    /\ UNCHANGED <<next_turn, started, oas_checkpoint_ref, raw_trace_ref,
                  execution_receipt_ref, runtime_lens_visible, terminal>>

ObserveRawTrace ==
    /\ \E t \in started \ raw_trace_ref :
        raw_trace_ref' = raw_trace_ref \cup {t}
    /\ UNCHANGED <<next_turn, started, oas_checkpoint_ref, tool_log_ref,
                  execution_receipt_ref, runtime_lens_visible, terminal>>

AppendExecutionReceipt ==
    /\ \E t \in started \ execution_receipt_ref :
        execution_receipt_ref' = execution_receipt_ref \cup {t}
    /\ UNCHANGED <<next_turn, started, oas_checkpoint_ref, tool_log_ref,
                  raw_trace_ref, runtime_lens_visible, terminal>>

PublishRuntimeLens ==
    /\ \E t \in started \ runtime_lens_visible :
        runtime_lens_visible' = runtime_lens_visible \cup {t}
    /\ UNCHANGED <<next_turn, started, oas_checkpoint_ref, tool_log_ref,
                  raw_trace_ref, execution_receipt_ref, terminal>>

ChainComplete(t) ==
    /\ t \in oas_checkpoint_ref
    /\ t \in tool_log_ref
    /\ t \in raw_trace_ref
    /\ t \in execution_receipt_ref
    /\ t \in runtime_lens_visible

MarkTerminal ==
    /\ \E t \in started \ terminal :
        /\ ChainComplete(t)
        /\ terminal' = terminal \cup {t}
    /\ UNCHANGED <<next_turn, started, oas_checkpoint_ref, tool_log_ref,
                  raw_trace_ref, execution_receipt_ref, runtime_lens_visible>>

StutterDone ==
    /\ next_turn = MaxTurns + 1
    /\ terminal = started
    /\ UNCHANGED vars

Next ==
    \/ StartTurn
    \/ ObserveOasCheckpoint
    \/ ObserveToolLog
    \/ ObserveRawTrace
    \/ AppendExecutionReceipt
    \/ PublishRuntimeLens
    \/ MarkTerminal
    \/ StutterDone

Spec == Init /\ [][Next]_vars

TerminalHasFullEvidence ==
    \A t \in terminal : ChainComplete(t)

TerminalVisibleInRuntimeLens ==
    terminal \subseteq runtime_lens_visible

OasBoundaryGeneric ==
    oas_checkpoint_ref \subseteq started

TerminalWithoutReceipt ==
    /\ \E t \in started \ terminal :
        /\ t \in oas_checkpoint_ref
        /\ t \in tool_log_ref
        /\ t \in raw_trace_ref
        /\ t \in runtime_lens_visible
        /\ ~(t \in execution_receipt_ref)
        /\ terminal' = terminal \cup {t}
    /\ UNCHANGED <<next_turn, started, oas_checkpoint_ref, tool_log_ref,
                  raw_trace_ref, execution_receipt_ref, runtime_lens_visible>>

TerminalWithoutCheckpoint ==
    /\ \E t \in started \ terminal :
        /\ ~(t \in oas_checkpoint_ref)
        /\ t \in tool_log_ref
        /\ t \in raw_trace_ref
        /\ t \in execution_receipt_ref
        /\ t \in runtime_lens_visible
        /\ terminal' = terminal \cup {t}
    /\ UNCHANGED <<next_turn, started, oas_checkpoint_ref, tool_log_ref,
                  raw_trace_ref, execution_receipt_ref, runtime_lens_visible>>

NextBuggy ==
    \/ Next
    \/ TerminalWithoutReceipt
    \/ TerminalWithoutCheckpoint

SpecBuggy == Init /\ [][NextBuggy]_vars

====
