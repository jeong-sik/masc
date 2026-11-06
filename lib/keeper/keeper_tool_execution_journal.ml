(* One append authority for an immutable prepared source, its async owners and
   node occurrences. Kept below the existing durable async consumer tree so the
   full typed results retain their artifact roots independently of transcripts. *)

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
module Plan = Keeper_tool_plan
module Async = Keeper_msg_async
module Dependency = Keeper_composition_dependency
module Nodes = Map.Make (String)

open Result.Syntax

