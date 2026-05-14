(** Tool scope classification — orchestrator MCP surface vs keeper-internal.

    The masc-mcp tool catalog mixes two audiences:
    - [Surface]: tools exposed to external MCP clients (supervisor agents,
      humans via dashboard). These are the goal/board/task/broadcast +
      admin lifecycle/observability primitives.
    - [Keeper_internal]: tools that a keeper persona invokes during its
      own work loop (code/web/worktree/autoresearch/plan/run/coord/inline
      helpers). These should not be reachable from the external MCP
      surface — only via the keeper dispatch table.

    This module supplies the classification *without* requiring every
    tool record (codegen [tool_spec] + manual [Masc_domain.tool_schema])
    to grow a new field. Classification is a name-keyed lookup; the
    initial keeper-internal list is empty so all tools default to
    [Surface] until subsequent PRs (PR-N1+) move them.

    Plan: ~/me/planning/claude-plans/polished-juggling-galaxy.md §2 Stage 2. *)

type scope =
  | Surface
  | Keeper_internal

val classify : name:string -> scope
(** [classify ~name] returns the scope for the named tool. Default
    [Surface] unless [name] appears in the keeper-internal list. *)

val keeper_internal_names : unit -> string list
(** [keeper_internal_names ()] is the explicit list of tool names whose
    scope is [Keeper_internal]. Returned as a fresh list each call. *)

val scope_to_string : scope -> string
(** [scope_to_string s] returns ["surface"] or ["keeper_internal"]. *)
