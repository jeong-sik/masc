(** Mutation/destructive command classifiers — IR-typed.

    RFC-0160 (Shell IR 1급 승격) S1: classifier signatures take
    [Masc_exec.Shell_ir.t] instead of [string]. The single-source
    parser (Producer A / B in RFC-0160 §2) lowers [string] to IR
    once; classifiers consume the typed envelope without re-parsing.

    {2 Scope}

    These three classifiers cover *structural* mutation intent:
    git write subcommands, package-manager state changes, filesystem
    mutators ([mv]/[cp]/[mkdir]/[rm -rf]), and protected-branch
    pushes. They do not catch raw-string evasion patterns
    ([{!Eval_gate.detect_destructive}] handles that — see RFC-0160
    §0 "Producer A").

    A [Shell_ir.Pipeline] is classified by flattening literal stage
    words; non-literal arguments ([Concat], [Var]) are skipped (the
    parser preserves them but they cannot be matched against the
    closed sub-command set).

    For backward compatibility, [_of_string] wrappers remain — they
    lower internally via [Bash.parse_string]. New callers should pass
    [Shell_ir.t] directly. *)

val is_write_operation : Masc_exec.Shell_ir.t -> bool
(** [true] for commands that write filesystem or VCS state in the
    closed sub-command set (git push/commit/merge/..., npm install/...,
    dune clean, mv/cp/mkdir/touch/chmod). *)

val is_git_branch_switch : Masc_exec.Shell_ir.t -> bool
(** [true] for [git checkout]/[git switch]/[git branch <name>] that
    changes the working branch. Listing variants ([branch -l],
    [branch -a]) and deletion variants ([branch -d]) are excluded. *)

val is_destructive_bash_operation : Masc_exec.Shell_ir.t -> bool
(** [true] for *structural* destructive patterns: [git push --force],
    [git push <protected_branch>], [git reset --hard], [rm -rf].

    Does {b not} include raw-string evasion detection — for that, run
    {!Eval_gate.detect_destructive} on the raw command string {i before}
    parsing. RFC-0160 §S1 separates these concerns: structural matching
    operates on typed argv where literal tokens defeat shell-level
    evasion by construction. *)

(* ── backward-compat string wrappers (DEPRECATED, removed in S4) ── *)

val is_write_operation_of_string : string -> bool
val is_git_branch_switch_of_string : string -> bool
val is_destructive_bash_operation_of_string : string -> bool

(** RFC-0160 S6: shared shell-word extractor, single source of truth
    for what used to be 3 duplicated [shell_word_values] copies in
    [exec_policy_log_sanitize], [gh_command_validation], and
    [keeper_tool_registry]. Returns the flattened literal stage words
    across all pipeline segments ([[]] on parse failure or
    non-literal-only stages).

    Transitional surface: prefer {!Masc_exec.Shell_ir.t}-typed callers
    once their upstream entry points migrate (S4). *)
val stage_words_of_string : string -> string list
