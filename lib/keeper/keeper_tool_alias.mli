(** Keeper_tool_alias — bidirectional map between LLM-facing tool names
    (Anthropic Code built-ins like [Bash], [Read]) and the internal
    keeper surface names ([keeper_bash], [keeper_fs_read], ...).

    Phase A of RFC-0006. This module is data-only; no runtime path
    consults it yet. Subsequent PRs will:

    - register the public names with OAS so the LLM can call [Bash]
      successfully (Phase A.2);
    - canonicalize via [to_internal] before the disclosure check in
      [keeper_agent_run.ml:1875] so [Bash] resolves to [keeper_bash]
      and is not flagged unexpected (Phase A.3).

    The internal name remains the SSOT for metrics, decisions.jsonl,
    audit logs and dashboards. *)

(** [to_internal public_name] returns the internal [keeper_*] name when
    [public_name] is a known alias. Returns [None] otherwise.

    Examples: [to_internal "Bash" = Some "keeper_bash"],
    [to_internal "Skill" = None] (no cognate; surface should emit a
    teaching error per RFC-0006 §3.1). *)
val to_internal : string -> string option

(** [to_public internal_name] returns the LLM-facing alias for an
    internal [keeper_*] tool. Falls back to [internal_name] verbatim
    when the tool has no Anthropic Code cognate (board/task/etc.). *)
val to_public : string -> string

(** [canonicalize_observed names] maps every recognized public alias
    to its internal name and leaves all other names untouched. Used
    by the disclosure check to treat [Bash] as [keeper_bash] when
    counting unexpected tools. *)
val canonicalize_observed : string list -> string list

(** [hallucinated_builtins] lists the public names from the Anthropic
    Code surface that have **no** cognate in the keeper surface
    (e.g. [Skill], [Agent], [WebSearch]). These should be flagged with
    a teaching message rather than nuking the turn. *)
val hallucinated_builtins : string list

(** [is_hallucinated_builtin name] is [true] iff [name] appears in
    [hallucinated_builtins]. *)
val is_hallucinated_builtin : string -> bool

(** [all_aliases ()] returns the full alias table as
    [(public, internal)] pairs. Stable order; suitable for tests and
    documentation generation. *)
val all_aliases : unit -> (string * string) list
