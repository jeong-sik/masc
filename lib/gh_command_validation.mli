(** Gh_command_validation — security gate for [gh] CLI invocations.

    Validates that a candidate [gh <subcommand>] string passes:

    1. No shell metacharacters / chaining / redirects.
    2. Subcommand is in the curated allowlist.
    3. The (cmd, sub) pair is not in the blocked-operations table.
    4. Optional [allowed_orgs] gate against [--repo OWNER/REPO].

    Plus an out-of-band reversibility classifier ({!classify_gh_reversibility})
    that grades a command as R0 (read-only), R1 (reversible mutation),
    or R2 (irreversible) for the operator-approval flow.

    Internal helpers ([forbidden_shell_chars],
    [contains_forbidden_shell_chars], [gh_allowed_commands],
    [gh_irreversible_ops], [gh_reversible_mutations],
    [gh_graphql_r2_mutations], [gh_blocked_operations],
    [gh_api_destructive_patterns], [gh_graphql_destructive_mutations],
    [extract_gh_api_method], [gh_api_graphql_is_destructive],
    [extract_gh_command_pair], [has_implicit_post_flags],
    [has_mutating_http_method], [positional_tokens], [gh_op_parts],
    [has_positional_subcmd], [gh_raw_parts], [gh_option_takes_value])
    are hidden — callers consume the 4 typed validators + reversibility
    classifier only.

    Re-exposed via [include Gh_command_validation] in
    {!Worker_dev_tools}; the test suite exercises that surface
    through [Worker_dev_tools.<symbol>]. *)

(** {1 Reversibility} *)

type gh_reversibility =
  | R0_Read
      (** Read-only command; no mutation possible. *)
  | R1_Reversible
      (** Mutating command whose effect can be undone (PR/issue
          merge or close, comment edit, label apply). *)
  | R2_Irreversible
      (** Mutating command that destroys state [gh] cannot
          restore (repo / release / secret / ssh-key / auth /
          gist / ruleset deletes; api DELETE; graphql
          delete*/remove*/transfer* mutations). *)

val string_of_gh_reversibility : gh_reversibility -> string
(** Stable ["R0"] / ["R1"] / ["R2"] strings used in dashboard
    payloads and gate decisions. *)

val classify_gh_reversibility : string -> gh_reversibility
(** Apply the table-based classifier to [cmd] (the portion after
    ["gh "]). Defaults to {!R0_Read} when nothing matches. *)

(** {1 Validators} *)

val validate_gh_command :
  ?allowed_orgs:string list -> string -> (unit, string) result
(** Top-level safety gate. [Ok ()] when [cmd] passes all four checks
    above; [Error msg] otherwise. The error message includes the
    allowed alternatives (#10561 — LLM-readable error pattern).

    [allowed_orgs] is consulted only when the command carries an
    explicit [--repo OWNER/REPO]; [[]] disables that check. *)

val extract_gh_repo_owner : string -> string option
(** Returns the [OWNER] portion of an explicit [--repo OWNER/REPO]
    flag, or [None] when the command does not target a specific
    repository. *)

val gh_pr_merge_target : string -> string option
(** Returns the explicit positional target of a [gh pr merge ...]
    command — supports numeric PR ids, branch names, and PR URLs.
    Returns [None] when the merge command has no positional target
    (i.e. relies on the current branch's PR). *)

val structured_tool_hint_for_r2 : string -> string option
(** Suggested next-action hint for a rejected R2 command. Returns
    [Some hint] when the (cmd, sub) maps to a known operator-only
    path; [None] otherwise (caller falls back to a generic message).
    Inserted into the gate response so smaller LLMs can self-recover
    without a second operator turn. *)

(** {1 Operation classifiers} *)

val is_gh_dangerous_operation : string -> bool
(** [true] iff the command is an always-gated irreversible
    operation (delete / archive / transfer / rename across repo /
    release / secret / ssh-key / workflow / api delete / graphql
    delete-or-transfer mutations). *)

val is_gh_workflow_operation : string -> bool
(** [true] iff the command is a normal workflow mutation
    (pr merge / pr close / issue close / project close / api
    /merge or state=closed). Legitimate for coding-preset keepers
    but still gated for lower-privilege presets. *)

val is_gh_pr_merge : string -> bool
(** [true] iff the command is specifically [gh pr merge ...]. *)

val is_gh_destructive_operation : string -> bool
(** Combined check: [is_gh_workflow_operation] OR
    [is_gh_dangerous_operation]. *)
