(** Mutation/destructive command classifiers -- IR-typed.

    RFC-0160 S4: [_of_string] wrappers removed. All callers must
    pass [Shell_ir.t] directly; the canonical string->IR entry point
    is {!Exec_policy.parse_string_to_ir}.

    {2 Scope}

    These three classifiers cover *structural* mutation intent:
    git write subcommands, package-manager state changes, filesystem
    mutators ([mv]/[cp]/[mkdir]/[rm -rf]), and force-pushes.
    They do not catch raw-string evasion patterns
    ([{!Eval_gate.detect_destructive}] handles that -- see RFC-0160
    S0 "Producer A").

    A [Shell_ir.Pipeline] is classified by flattening literal stage
    words; non-literal arguments ([Concat], [Var]) are skipped (the
    parser preserves them but they cannot be matched against the
    closed sub-command set). *)

val flat_stage_words : Masc_exec.Shell_ir.t -> string list
(** Flatten all literal stage words across pipeline segments.
    Non-literal-only stages contribute their literal prefix only.
    Replaces the historical string-era extractors. *)

val is_git_branch_switch : Masc_exec.Shell_ir.t -> bool
(** [true] for [git checkout]/[git switch]/[git branch <name>] that
    changes the working branch. Listing variants ([branch -l],
    [branch -a]) and deletion variants ([branch -d]) are excluded. *)

val is_write_operation : Masc_exec.Shell_ir.t -> bool
(** [true] for *structural* write patterns: [git push]/[commit]/[merge],
    [npm install]/[publish], [make deploy], [mv]/[cp]/[mkdir]/[rm].
    Complement to [is_destructive_bash_operation]: write ops mutate
    state but may be reversible; destructive ops risk unrecoverable loss.
    Both operate on typed IR -- no raw-string path. *)

val is_destructive_bash_operation : Masc_exec.Shell_ir.t -> bool
(** [true] for *structural* destructive patterns: [git push --force],
    [git reset --hard], [rm -rf].

    Protected-branch escalation is a product-level policy concern and
    lives in approval hooks, not this structural classifier.

    Does {b not} include raw-string evasion detection -- for that, run
    {!Eval_gate.detect_destructive} on the raw command string {i before}
    parsing. RFC-0160 SS1 separates these concerns: structural matching
    operates on typed argv where literal tokens defeat shell-level
    evasion by construction. *)

val stages_words_of_ir : Masc_exec.Shell_ir.t -> string list list
(** Multi-stage word extractor: per-stage word lists preserving pipeline
    structure. Replaces the legacy stage-extraction callers
    (e.g. [Exec_core.command_word_stages]). *)

type quoted_word = {
  value : string;
  quoted : bool;
}

val stages_quoted_words_of_ir : Masc_exec.Shell_ir.t -> quoted_word list list
(** Per-stage word extraction with quoting metadata.
    Replaces the legacy quoted-word extraction callers that depend on
    [word.quoted] (e.g. guard token extraction). Non-literal args
    ([Concat], [Var]) are skipped. *)
