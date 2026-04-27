(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

val exact_direct_mention_present : targets:string list -> string -> bool

val keeper_constitution : unit -> string

val build_keeper_system_prompt :
  goal:string ->
  short_goal:string ->
  mid_goal:string ->
  long_goal:string ->
  will:string ->
  needs:string ->
  desires:string ->
  instructions:string ->
  ?persona_extended:string ->
  ?keeper_name:string ->
  ?allowed_orgs:string list ->
  ?denied_repos:string list ->
  ?active_goals:(string * string * string) list ->
  unit ->
  string
(** [allowed_orgs] / [denied_repos] are surfaced in the <world> block so
    the keeper sees the live git_clone allow/deny lists without having
    to query [tool_policy.toml].  Callers should pass the values from
    [Keeper_tool_policy.git_clone_allowed_orgs] /
    [git_clone_denied_repos].

    Empty-list semantics differ between the two:
    - Empty [allowed_orgs] = "gate OFF, any account-accessible repo is
      permitted" (matches [validate_gh_command]'s skip-check behaviour).
    - Empty [denied_repos] = "no repos blocked" (renders as "(none)").

    Earlier revisions collapsed both to "(none)", which led the LLM to
    read an empty allowlist as "no orgs allowed" — the inverse of intent. *)

val append_direct_reply_mode_prompt :
  base_prompt:string ->
  string

val append_trait_clause : base:string -> clause:string -> string

(** {1 Text Processing}

    Re-exported from [Keeper_text_processing]. *)

include module type of Keeper_text_processing
