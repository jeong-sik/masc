(** Oas — MASC-side facade over the OAS (Open Agent SDK) library.

    The .ml is 49 module aliases (one line each), one per
    [Agent_sdk.X] sub-module re-exported under the [Oas]
    namespace.  Every MASC consumer reaches the SDK through this
    facade ([Oas.Builder.t], [Oas.Tool.t], [Oas.Hooks.hooks],
    [Oas.Provider.config], etc.), so the .mli is the SSOT for
    "what counts as part of the OAS surface from MASC's
    viewpoint".

    Implementation strategy: each entry is a module alias
    ([module M = Agent_sdk.M]).  Aliases preserve type identity
    perfectly — callers can interleave [Oas.X.t] and
    [Agent_sdk.X.t] freely and pass values through code that
    references either form.  No [module type of] is needed
    because [Agent_sdk] already pins each sub-module via its
    own .mli upstream.

    Adding a new alias: bump both the .ml and this .mli in the
    same commit so the facade and the contract stay in sync —
    drift here would either expose a new SDK module without
    review or hide one that downstream code already imports. *)

module Agent = Agent_sdk.Agent
module Agent_checkpoint = Agent_sdk.Agent_checkpoint
module Agent_turn = Agent_sdk.Agent_turn
module Agent_turn_budget = Agent_sdk.Agent_turn_budget
module Agent_types = Agent_sdk.Agent_types
module Api = Agent_sdk.Api
module Approval = Agent_sdk.Approval
module Autonomy_diff_guard = Agent_sdk.Autonomy_diff_guard
module Budget_strategy = Agent_sdk.Budget_strategy
module Builder = Agent_sdk.Builder
module Cdal_proof = Agent_sdk.Cdal_proof
module Checkpoint = Agent_sdk.Checkpoint
module Checkpoint_store = Agent_sdk.Checkpoint_store
module Completion_contract = Agent_sdk.Completion_contract
module Completion_contract_id = Agent_sdk.Completion_contract_id
module Context = Agent_sdk.Context
module Context_reducer = Agent_sdk.Context_reducer
module Contract_runner = Agent_sdk.Contract_runner
module Direct_evidence = Agent_sdk.Direct_evidence
module Error = Agent_sdk.Error
module Event_bus = Agent_sdk.Event_bus
module Execution_mode = Agent_sdk.Execution_mode
module Guardrails = Agent_sdk.Guardrails
module Harness = Agent_sdk.Harness
module Hooks = Agent_sdk.Hooks
module Lesson_memory = Agent_sdk.Lesson_memory
module Log = Agent_sdk.Log
module Mcp = Agent_sdk.Mcp
module Memory = Agent_sdk.Memory
module Mode_enforcer = Agent_sdk.Mode_enforcer
module Orchestrator = Agent_sdk.Orchestrator
module Proof_store = Agent_sdk.Proof_store
module Provider = Agent_sdk.Provider
module Raw_trace = Agent_sdk.Raw_trace
module Raw_trace_query = Agent_sdk.Raw_trace_query
module Retry = Agent_sdk.Retry
module Risk_class = Agent_sdk.Risk_class
module Risk_contract = Agent_sdk.Risk_contract
module Structured = Agent_sdk.Structured
module Tool = Agent_sdk.Tool
module Tool_index = Agent_sdk.Tool_index
module Tool_input_validation = Agent_sdk.Tool_input_validation
module Tool_middleware = Agent_sdk.Tool_middleware
module Tool_op = Agent_sdk.Tool_op
module Tool_retry_policy = Agent_sdk.Tool_retry_policy
module Tool_schema_gen = Agent_sdk.Tool_schema_gen
module Tool_selector = Agent_sdk.Tool_selector
module Typed_tool = Agent_sdk.Typed_tool
module Types = Agent_sdk.Types
