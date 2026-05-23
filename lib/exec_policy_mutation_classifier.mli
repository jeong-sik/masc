(** Mutation/destructive command classifiers — IR-typed.

    RFC-0160 S4: [_of_string] wrappers removed. All callers must
    pass [Shell_ir.t] directly; the canonical string→IR entry point
    is {!Shell_command_gate}.

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
    closed sub-command set). *)

val flat_stage_words : Masc_exec.Shell_ir.t -> string list
(** Flatten all literal stage words across pipeline segments.
    Non-literal-only stages contribute their literal prefix only.
    Replaces the historical [shell_word_values] / [Bash_words.stages]
    string-era extractors. *)

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

(** Shared shell-word extractor for callers that only have a raw string.
    Returns [[]] on parse failure. Callers with [Shell_ir.t] should
    use {!flat_stage_words} directly instead. *)
val stage_words_of_string : string -> string list

(** RFC-0160 S6b: Result-shaped variant for callers that route on parse
    failure (e.g. log sanitizer's sensitive-marker fallback). The plain
    [stage_words_of_string] collapses parse failure to [[]] (fail-closed
    = false suits structural classifiers); this variant preserves
    [Error ()] so the failure path can branch separately.

    Single IR producer ([Bash.parse_string]) for both shapes — replaces
    the legacy [Bash_words.stages]-based [shell_word_values] copy in
    [exec_policy_log_sanitize]. *)
val stage_words_of_string_result : string -> (string list, unit) result

(** Parse a string as a single simple command and extract its argv words.
    Returns [None] for pipelines, parse errors, or non-literal args.
    Replaces the duplicate [Bash.parse_string] in
    [Exec_policy_command_syntax.argv_words_of_split_string]. *)
val argv_words_of_string : string -> string list option

(** Expose the raw [Bash.parse_string] result for callers that need
    [Shell_ir.t Parsed.t] directly (e.g. gh command validation).
    This is the SSOT entry point for string→IR parsing — all production
    callers should route through this instead of calling
    [Masc_exec_bash_parser.Bash.parse_string] directly. *)
val parsed_of_string : string -> Masc_exec.Shell_ir.t Masc_exec.Parsed.t

(** Per-stage word extraction: each pipeline segment produces its own
    word list, preserving stage boundaries. Returns [[]] on parse
    failure or non-literal args. Replaces [Bash_words.stages] for
    callers that need per-stage inspection. *)
val stage_words_per_stage : string -> string list list
