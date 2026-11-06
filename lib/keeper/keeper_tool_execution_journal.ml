(* One append authority for an immutable prepared source, its async owners and
   node occurrences. Kept below the existing durable async consumer tree so the
   full typed results retain their artifact roots independently of transcripts.

   The items live in the Keeper_tool_execution_journal_* modules, included in
   the order below. Each module reads only the ones above it: the source and
   result types, the JSON readers, the journal's own values, the state decoder,
   the journal file, the continuation marker and the operator resolution, the
   named and owner binding, the waiting continuation, the completion
   observation, the pending continuation discovery, and the worker's node and
   child submission operations. *)

include Keeper_tool_execution_journal_types
include Keeper_tool_execution_journal_json
include Keeper_tool_execution_journal_model
include Keeper_tool_execution_journal_state_decode
include Keeper_tool_execution_journal_store
include Keeper_tool_execution_journal_resolution
include Keeper_tool_execution_journal_binding
include Keeper_tool_execution_journal_continuation
include Keeper_tool_execution_journal_completion
include Keeper_tool_execution_journal_discovery
include Keeper_tool_execution_journal_attempt
