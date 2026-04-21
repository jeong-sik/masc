---- MODULE ToolCallContract ----
(***************************************************************************)
(* ToolCallContract — boundary contract for keeper/tool telemetry writes.  *)
(*                                                                         *)
(* Scope: one turn-level observation after tool planning/execution is      *)
(* materialized into decision telemetry. This is intentionally narrower    *)
(* than provider transport or full keeper lifecycle state.                 *)
(*                                                                         *)
(* Runtime projection covered by this contract:                            *)
(*   - decision records keep tool_call_count and tools_used                *)
(*   - gh_repo_context errors are allowed only outside Docker sandbox      *)
(*   - tool-use outcomes require a tool-capable provider declaration       *)
(*   - requested tool use must not disappear into a plain text outcome     *)
(*                                                                         *)
(* This spec is the minimal Axis 5 contract slice. It does not model       *)
(* replay harness details, retries, or provider-specific argument schemas. *)
(***************************************************************************)

EXTENDS Naturals

ToolRegistry == {"keeper_shell", "keeper_memory_search", "masc_add_task"}

ToolUniverse == ToolRegistry \cup {"unknown_tool"}

VARIABLES
    phase,
    sandbox_profile,
    provider_declares_supports_tools,
    request_seen,
    outcome,
    error_category,
    tool_call_count,
    tools_used

vars ==
    << phase,
       sandbox_profile,
       provider_declares_supports_tools,
       request_seen,
       outcome,
       error_category,
       tool_call_count,
       tools_used >>

PhaseSet == {"unstarted", "started", "requested", "finished"}
SandboxSet == {"local", "docker"}
OutcomeSet == {"none", "text", "tool_use", "error"}
ErrorCategorySet == {"none", "gh_repo_context", "unsupported_tools", "other"}
ActionSet == {
    "StartToolCapableLocal",
    "StartToolCapableDocker",
    "StartTextOnlyLocal",
    "StartTextOnlyDocker",
    "ReplyTextNoTool",
    "RequestTool",
    "EmitToolCall",
    "EmitUnsupportedToolsError",
    "EmitGhRepoContextError"
}
InvariantSet == {
    "NonNegativeToolCallCount",
    "ToolsUsedAreRegistered",
    "GhRepoContextNeverInDocker",
    "ToolUseRequiresDeclaredSupport",
    "ToolUseCarriesToolNames",
    "NoCallsOutsideToolUse",
    "NeverDropSilently"
}

TypeOK ==
    /\ phase \in PhaseSet
    /\ sandbox_profile \in SandboxSet
    /\ provider_declares_supports_tools \in BOOLEAN
    /\ request_seen \in BOOLEAN
    /\ outcome \in OutcomeSet
    /\ error_category \in ErrorCategorySet
    /\ tool_call_count \in Nat
    /\ tools_used \subseteq ToolUniverse

Init ==
    /\ phase = "unstarted"
    /\ sandbox_profile = "local"
    /\ provider_declares_supports_tools = FALSE
    /\ request_seen = FALSE
    /\ outcome = "none"
    /\ error_category = "none"
    /\ tool_call_count = 0
    /\ tools_used = {}

StartToolCapableLocal ==
    /\ phase = "unstarted"
    /\ phase' = "started"
    /\ sandbox_profile' = "local"
    /\ provider_declares_supports_tools' = TRUE
    /\ request_seen' = FALSE
    /\ outcome' = "none"
    /\ error_category' = "none"
    /\ tool_call_count' = 0
    /\ tools_used' = {}

StartToolCapableDocker ==
    /\ phase = "unstarted"
    /\ phase' = "started"
    /\ sandbox_profile' = "docker"
    /\ provider_declares_supports_tools' = TRUE
    /\ request_seen' = FALSE
    /\ outcome' = "none"
    /\ error_category' = "none"
    /\ tool_call_count' = 0
    /\ tools_used' = {}

StartTextOnlyLocal ==
    /\ phase = "unstarted"
    /\ phase' = "started"
    /\ sandbox_profile' = "local"
    /\ provider_declares_supports_tools' = FALSE
    /\ request_seen' = FALSE
    /\ outcome' = "none"
    /\ error_category' = "none"
    /\ tool_call_count' = 0
    /\ tools_used' = {}

StartTextOnlyDocker ==
    /\ phase = "unstarted"
    /\ phase' = "started"
    /\ sandbox_profile' = "docker"
    /\ provider_declares_supports_tools' = FALSE
    /\ request_seen' = FALSE
    /\ outcome' = "none"
    /\ error_category' = "none"
    /\ tool_call_count' = 0
    /\ tools_used' = {}

ReplyTextNoTool ==
    /\ phase = "started"
    /\ phase' = "finished"
    /\ outcome' = "text"
    /\ error_category' = "none"
    /\ tool_call_count' = 0
    /\ tools_used' = {}
    /\ UNCHANGED <<sandbox_profile, provider_declares_supports_tools, request_seen>>

RequestTool ==
    /\ phase = "started"
    /\ phase' = "requested"
    /\ request_seen' = TRUE
    /\ outcome' = "none"
    /\ error_category' = "none"
    /\ tool_call_count' = 0
    /\ tools_used' = {}
    /\ UNCHANGED <<sandbox_profile, provider_declares_supports_tools>>

EmitToolCall ==
    /\ phase = "requested"
    /\ provider_declares_supports_tools
    /\ phase' = "finished"
    /\ request_seen' = TRUE
    /\ outcome' = "tool_use"
    /\ error_category' = "none"
    /\ tool_call_count' = 1
    /\ tools_used' = {"keeper_shell"}
    /\ UNCHANGED <<sandbox_profile, provider_declares_supports_tools>>

EmitUnsupportedToolsError ==
    /\ phase = "requested"
    /\ ~provider_declares_supports_tools
    /\ phase' = "finished"
    /\ request_seen' = TRUE
    /\ outcome' = "error"
    /\ error_category' = "unsupported_tools"
    /\ tool_call_count' = 0
    /\ tools_used' = {}
    /\ UNCHANGED <<sandbox_profile, provider_declares_supports_tools>>

EmitGhRepoContextError ==
    /\ phase = "requested"
    /\ sandbox_profile = "local"
    /\ phase' = "finished"
    /\ request_seen' = TRUE
    /\ outcome' = "error"
    /\ error_category' = "gh_repo_context"
    /\ tool_call_count' = 0
    /\ tools_used' = {}
    /\ UNCHANGED <<sandbox_profile, provider_declares_supports_tools>>

Next ==
    \/ StartToolCapableLocal
    \/ StartToolCapableDocker
    \/ StartTextOnlyLocal
    \/ StartTextOnlyDocker
    \/ ReplyTextNoTool
    \/ RequestTool
    \/ EmitToolCall
    \/ EmitUnsupportedToolsError
    \/ EmitGhRepoContextError

Spec ==
    Init /\ [][Next]_vars

NonNegativeToolCallCount ==
    tool_call_count >= 0

ToolsUsedAreRegistered ==
    tools_used \subseteq ToolRegistry

GhRepoContextNeverInDocker ==
    error_category = "gh_repo_context" =>
        sandbox_profile # "docker"

ToolUseRequiresDeclaredSupport ==
    tool_call_count > 0 =>
        provider_declares_supports_tools

ToolUseCarriesToolNames ==
    tool_call_count > 0 =>
        /\ outcome = "tool_use"
        /\ tools_used # {}

NoCallsOutsideToolUse ==
    outcome # "tool_use" =>
        /\ tool_call_count = 0
        /\ tools_used = {}

NeverDropSilently ==
    /\ phase = "finished"
    /\ request_seen
    =>
        outcome \in {"tool_use", "error"}

Safety ==
    /\ TypeOK
    /\ NonNegativeToolCallCount
    /\ ToolsUsedAreRegistered
    /\ GhRepoContextNeverInDocker
    /\ ToolUseRequiresDeclaredSupport
    /\ ToolUseCarriesToolNames
    /\ NoCallsOutsideToolUse
    /\ NeverDropSilently

\* Bug model: the runtime requested a tool, finished the turn, but recorded a
\* plain text outcome with zero tool evidence and no error.
ToolCallDroppedSilently ==
    /\ phase = "requested"
    /\ provider_declares_supports_tools
    /\ phase' = "finished"
    /\ request_seen' = TRUE
    /\ outcome' = "text"
    /\ error_category' = "none"
    /\ tool_call_count' = 0
    /\ tools_used' = {}
    /\ UNCHANGED <<sandbox_profile, provider_declares_supports_tools>>

NextBuggy ==
    \/ StartToolCapableLocal
    \/ StartToolCapableDocker
    \/ StartTextOnlyLocal
    \/ StartTextOnlyDocker
    \/ ReplyTextNoTool
    \/ RequestTool
    \/ ToolCallDroppedSilently
    \/ EmitUnsupportedToolsError
    \/ EmitGhRepoContextError

SpecBuggy ==
    Init /\ [][NextBuggy]_vars

====
