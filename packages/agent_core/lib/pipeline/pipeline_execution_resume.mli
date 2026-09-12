(** Private restart recovery and turn dispatch for one durable provider turn. *)

(** The identity of the provider turn about to run: what the durable turn
    frontier held, plus the one zero-based ordinal every producer for that turn
    reads (stage spans, hooks, events, tool invocations, the turn log line and
    the caller's [agent_turn] span). *)
type frontier

(** Resolve the next turn's identity. Consumes the one-shot resume flag, then
    classifies the durable turn frontier: a fresh turn takes the ordinal of the
    turn about to run from agent state, a resumed in-progress turn takes the
    durable turn's ordinal, and an already-settled boundary names the turn the
    collect stage already closed. Called exactly once per turn, before any span
    or record names the turn. Fails closed on inconsistent restored topology. *)
val resolve : Agent_types.t -> (frontier, Error.t) result

val frontier_ordinal : frontier -> int

(** Dispatch one pipeline turn against the restored durable-execution scope under
    the identity {!resolve} produced: an in-progress turn/provider is resumed, an
    already-settled turn boundary is replayed ([tools_settled] for a completed
    tool turn, [terminal] receiving the exact persisted response), and no
    resume runs [fresh]. [tools_settled_before_checkpoint] repairs only the
    crash window where invocation results settled before the Agent checkpoint;
    its invocation and result authority comes exclusively from the journal.
    [all_pre_tool_use_blocked] continues an exact checkpoint whose ToolUse and
    ToolResult identities match while the journal contains zero invocation
    nodes; that typed path never enters terminal recovery. [execute] and
    [fresh] receive the resolved turn identity ([turn]); no continuation
    re-derives it from mutable agent state. Fails closed on inconsistent
    restored topology. *)
val dispatch
  :  Agent_types.t
  -> frontier
  -> execute:
       (turn:int
        -> response:Types.api_response
        -> Types.content_block Nonempty.t
        -> ('a, Error.t) result)
  -> tools_settled_before_checkpoint:
       (response:Types.api_response
        -> turn:int
        -> invocations:Execution_agent_scope.invocation_authority list
        -> tool_results:Types.content_block list
        -> Types.content_block Nonempty.t
        -> ('a, Error.t) result)
  -> tools_settled:
       (response:Types.api_response
        -> turn:int
        -> invocations:Execution_agent_scope.invocation_authority list
        -> tool_results:Types.content_block list
        -> Types.content_block Nonempty.t
        -> ('a, Error.t) result)
  -> all_pre_tool_use_blocked:'a
  -> terminal:(Types.api_response -> 'a)
  -> fresh:(turn:int -> ('a, Error.t) result)
  -> ('a, Error.t) result
