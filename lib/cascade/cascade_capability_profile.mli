(** Cascade_capability_profile — declarative capability requirement
    for cascade profiles.  RFC-0027.

    Each cascade in [cascade.toml] may declare a
    [required_capability_profile = "<name>"] field (added in PR #2).
    This module owns the closed enumeration of supported profile
    names, the capability-requirement table that defines each profile,
    and the predicate used by the validator to decide whether a
    given provider satisfies a profile.

    See: docs/rfc/RFC-0027-capability-typed-cascade.md *)

(** Closed enumeration of named capability profiles.  New variants
    require an explicit PR (deliberate — avoids silent string-typed
    drift between cascade.toml and code). *)
type profile =
  | Tool_strict
      (** Keeper-bound runtime MCP requires per-request HTTP headers.
          Only providers with [supports_runtime_mcp_http_headers]
          (claude_code / kimi_cli / HTTP-based) qualify.  Used by
          keepers that must dispatch keeper-scoped MCP tools (e.g.
          [keeper_bash], [masc_worktree_create]). *)
  | Inline_tools
      (** Direct-API path: provider must support [supports_inline_tools]
          and [supports_inline_tool_choice].  CLI runtimes
          (claude_code / codex_cli / gemini_cli / kimi_cli) all fail
          this — they expose tools through runtime MCP, not inline. *)
  | Lite
      (** Runtime-MCP-capable but does not require HTTP headers.
          Suitable for [gemini_cli] (static MCP via
          [~/.gemini/settings.json]) and other CLI runtimes that
          carry tools through stdio MCP. *)
  | Local
      (** No capability requirements — accepts any provider including
          ollama-only profiles.  Used by [local_recovery]-like lanes
          that exist purely for liveness fallback. *)

val profile_to_string : profile -> string
(** Stable lowercase snake_case label.
    [Tool_strict] -> ["tool_strict"], etc.  Used as the cascade.toml
    field value and the Prometheus label. *)

val profile_of_string : string -> profile option
(** Inverse of {!profile_to_string}.  Returns [None] for unknown
    strings — caller must treat that as a hard configuration error
    (no silent fallback). *)

val all_profiles : profile list
(** Every variant of {!profile} in declaration order.  Used by tests
    and by the validator to enumerate the catalog. *)

(** Per-capability requirement.  Mirrors the field set of
    {!Provider_tool_support.capabilities} but lifts each [bool] to
    a tri-state [requirement] so a profile can declare "I require
    this" vs. "I do not care". *)
type requirement =
  | Required
      (** Provider must have the capability set to [true]. *)
  | Optional
      (** Profile does not constrain this capability — provider may
          or may not have it. *)

type required_capabilities = {
  inline_tools : requirement;
  inline_tool_choice : requirement;
  runtime_mcp_tools : requirement;
  runtime_tool_events : requirement;
  runtime_mcp_http_headers : requirement;
}
(** The capability-requirement matrix for one profile.  Field names
    match {!Provider_tool_support.capabilities} (with the [supports_]
    prefix stripped) so satisfaction can be checked field-by-field. *)

val required_capabilities_of : profile -> required_capabilities
(** [required_capabilities_of p] returns the capability matrix that
    defines profile [p].  Pure function — see RFC-0027 §3.1 for the
    matrix definition. *)

val provider_satisfies_profile :
  profile -> Provider_tool_support.capabilities -> bool
(** [provider_satisfies_profile p caps] is [true] iff every
    [Required] field of {!required_capabilities_of}[ p] is [true]
    in [caps].  [Optional] fields are unconstrained. *)

val safe_lane_cascade_name : string
(** RFC-0027 PR-4 system-only cascade name, ["__safe_lane"].  This
    cascade is shipped in the seed [config/cascade.toml] and contains
    only providers that satisfy {!Tool_strict}.  Used as the absolute
    last-resort fallback target by the cross-cascade resolver.
    Operators must not assign this cascade to keepers — the [__]
    prefix marks it as system-internal and the seed sets
    [keeper_assignable = false]. *)

val is_system_cascade_name : string -> bool
(** [is_system_cascade_name name] is [true] iff [name] is a
    system-reserved cascade name (currently: anything starting with
    ["__"]).  Operator-authored cascades must not collide with this
    namespace. *)
