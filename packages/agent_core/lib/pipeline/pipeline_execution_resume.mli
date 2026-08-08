(** Private restart recovery and turn dispatch for one durable provider turn. *)

(** Dispatch one pipeline turn against the restored durable-execution scope.
    Consumes the one-shot resume flag, then routes on what the scope found at the
    durable turn frontier: an in-progress turn/provider is resumed, an
    already-settled turn boundary is replayed ([tools_settled] for a completed
    tool turn, [terminal] receiving the exact persisted response), and no
    resume runs [fresh]. [tools_settled_before_checkpoint] repairs only the
    crash window where invocation results settled before the Agent checkpoint;
    its invocation and result authority comes exclusively from the journal.
    [all_pre_tool_use_blocked] continues an exact checkpoint whose ToolUse and
    ToolResult identities match while the journal contains zero invocation
    nodes; that typed path never enters terminal recovery. [execute] receives
    the durable turn identity ([turn]), owned by the journal rather than
    reconstructed from mutable agent state. Fails closed on inconsistent
    restored topology. *)
val dispatch
  :  Agent_types.t
  -> execute:
       (turn:int
        -> response:Types.api_response
        -> Types.content_block Nonempty.t
        -> ('a, Error.sdk_error) result)
  -> tools_settled_before_checkpoint:
       (response:Types.api_response
        -> turn:int
        -> invocations:Execution_agent_scope.invocation_authority list
        -> tool_results:Types.content_block list
        -> Types.content_block Nonempty.t
        -> ('a, Error.sdk_error) result)
  -> tools_settled:
       (response:Types.api_response
        -> turn:int
        -> invocations:Execution_agent_scope.invocation_authority list
        -> tool_results:Types.content_block list
        -> Types.content_block Nonempty.t
        -> ('a, Error.sdk_error) result)
  -> all_pre_tool_use_blocked:'a
  -> terminal:(Types.api_response -> 'a)
  -> fresh:(unit -> ('a, Error.sdk_error) result)
  -> ('a, Error.sdk_error) result
