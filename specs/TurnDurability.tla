---- MODULE TurnDurability ----
\* Models OAS' generic turn-boundary checkpoint contract.
\*
\* Concrete code:
\*   - Agent_types.checkpoint_sink
\*   - Pipeline.persist_turn_checkpoint
\*   - stage_collect / stage_execute / required-tool retry feedback append
\*
\* The key safety rule is that once an in-memory mutation that changes
\* recoverable turn state has happened, the matching checkpoint for that
\* turn and stage must exist in the caller-owned sink before the action
\* is considered complete.
\*
\* Bug model: BugCollectAssistantNoCheckpoint and
\* BugAppendToolFeedbackNoCheckpoint model regressions where the state
\* mutation completes but the checkpoint sink is skipped.

EXTENDS Naturals

\* Finite model-checking scope only. This is not an OAS runtime turn limit;
\* production turns remain unbounded.
CONSTANTS ModelTurnCount

ASSUME ModelTurnCount \in Nat /\ ModelTurnCount >= 1

Stages ==
    {"after_assistant_collected",
     "after_tool_results_appended",
     "after_retry_feedback_appended"}

Checkpoint(stage, turn_id) == [stage |-> stage, turn |-> turn_id]

CheckpointUniverse == { Checkpoint(stage, turn_id) :
    stage \in Stages, turn_id \in 1..ModelTurnCount }

VARIABLES
    turn,
    assistant_collected,
    tool_feedback_appended,
    retry_feedback_appended,
    checkpoints

vars == <<turn, assistant_collected, tool_feedback_appended,
          retry_feedback_appended, checkpoints>>

TypeOK ==
    /\ turn \in 0..ModelTurnCount
    /\ assistant_collected \subseteq 1..ModelTurnCount
    /\ tool_feedback_appended \subseteq assistant_collected
    /\ retry_feedback_appended \subseteq assistant_collected
    /\ checkpoints \subseteq CheckpointUniverse

Init ==
    /\ turn = 0
    /\ assistant_collected = {}
    /\ tool_feedback_appended = {}
    /\ retry_feedback_appended = {}
    /\ checkpoints = {}

CollectAssistant ==
    /\ turn < ModelTurnCount
    /\ turn' = turn + 1
    /\ assistant_collected' = assistant_collected \cup {turn + 1}
    /\ UNCHANGED <<tool_feedback_appended, retry_feedback_appended>>
    /\ checkpoints' =
        checkpoints \cup {Checkpoint("after_assistant_collected", turn + 1)}

AppendToolFeedback ==
    /\ \E t \in assistant_collected \ tool_feedback_appended :
        /\ tool_feedback_appended' = tool_feedback_appended \cup {t}
        /\ checkpoints' =
            checkpoints \cup {Checkpoint("after_tool_results_appended", t)}
    /\ UNCHANGED <<turn, assistant_collected, retry_feedback_appended>>

AppendRetryFeedback ==
    /\ \E t \in assistant_collected \ retry_feedback_appended :
        /\ retry_feedback_appended' = retry_feedback_appended \cup {t}
        /\ checkpoints' =
            checkpoints \cup {Checkpoint("after_retry_feedback_appended", t)}
    /\ UNCHANGED <<turn, assistant_collected, tool_feedback_appended>>

StutterDone ==
    /\ turn = ModelTurnCount
    /\ UNCHANGED vars

Next ==
    \/ CollectAssistant
    \/ AppendToolFeedback
    \/ AppendRetryFeedback
    \/ StutterDone

Spec == Init /\ [][Next]_vars

AssistantCollectedDurable ==
    \A t \in assistant_collected :
        Checkpoint("after_assistant_collected", t) \in checkpoints

ToolFeedbackDurable ==
    \A t \in tool_feedback_appended :
        Checkpoint("after_tool_results_appended", t) \in checkpoints

RetryFeedbackDurable ==
    \A t \in retry_feedback_appended :
        Checkpoint("after_retry_feedback_appended", t) \in checkpoints

BugCollectAssistantNoCheckpoint ==
    /\ turn < ModelTurnCount
    /\ turn' = turn + 1
    /\ assistant_collected' = assistant_collected \cup {turn + 1}
    /\ UNCHANGED <<tool_feedback_appended, retry_feedback_appended, checkpoints>>

BugAppendToolFeedbackNoCheckpoint ==
    /\ \E t \in assistant_collected \ tool_feedback_appended :
        /\ tool_feedback_appended' = tool_feedback_appended \cup {t}
    /\ UNCHANGED <<turn, assistant_collected, retry_feedback_appended, checkpoints>>

NextBuggy ==
    \/ Next
    \/ BugCollectAssistantNoCheckpoint
    \/ BugAppendToolFeedbackNoCheckpoint

SpecBuggy == Init /\ [][NextBuggy]_vars

====
