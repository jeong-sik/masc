(** Shell_ir_risk — phantom-typed risk envelope for Shell IR.

    RFC-0160 S3: type-level invariant that every IR reaching dispatch
    has been classified. [undecided t] values must pass through
    [classify] to obtain a [decided decided_ir] before dispatch. *)

type undecided
type decided

type risk_class =
  | R0_Read
  | R1_Reversible_mutation
  | R2_Irreversible
  | Destructive_protected

val string_of_risk_class : risk_class -> string
val pp_risk_class : Format.formatter -> risk_class -> unit

(** Phantom wrapper. Zero runtime overhead. *)
type _ t

val undecided : Shell_ir.t -> undecided t
val unwrap : 'phase t -> Shell_ir.t

type 'phase decided_ir = { ir : Shell_ir.t; risk : risk_class }

val risk_class : decided decided_ir -> risk_class
val is_r0 : decided decided_ir -> bool
val is_r1 : decided decided_ir -> bool
val is_r2 : decided decided_ir -> bool
val is_destructive : decided decided_ir -> bool

val classify : undecided t -> decided decided_ir
(** Run the unified risk classifier over the wrapped IR.
    Uses [Exec_policy_mutation_classifier] for bash operations,
    then repo-hosting CLI subcommand tables for ["gh"] command operations,
    defaulting to R0. Write/append redirects add an R1 syntax floor because
    redirects are not argv tokens and must not disappear from receipts.

    [Simple] commands are lowered to the [Shell_ir_typed] GADT and
    classified by [risk_of_typed]; the [Generic] escape hatch falls back
    to the word-list classifier [classify_words]. [Pipeline]s compose the
    per-stage decision with [max_risk] (RFC-0208 P0), so every stage
    contributes its typed and word-list verdict rather than the pipeline
    deferring wholesale to the head-anchored floor. *)

val typed_hit_of_ir : Shell_ir.t -> bool
(** [true] when the typed lowering classified every [Simple] node via a
    real [Shell_ir_typed] constructor rather than the [Generic] escape
    hatch. RFC-0208 P1 observability instrument: lets the dispatch log and
    the differential harness measure real typed coverage vs [Generic]
    fallback over live traffic. A [Pipeline] is a typed hit only when all
    of its stages are. *)

val risk_of_typed : Shell_ir_typed.wrapped -> risk_class
(** Risk opinion implied by the typed command shape alone (RFC-0160 §S1)
    — the first decision path that reads the [Shell_ir_typed] GADT.
    Exhaustive over [Shell_ir_typed_types.command]: a new constructor
    forces a compile error here. [classify] combines this with
    [classify_words] by taking the stricter of the two, so [Gh]/[Generic]
    may return a lower opinion here than the word-list floor supplies. *)

val classify_words : string list -> risk_class
(** Word-list risk classifier — the pre-GADT decision path, retained as
    the safety floor in [classify] for [Generic]/[Pipeline] and for
    risk-bearing tokens the typed model does not yet capture (gh
    -X METHOD / graphql body).

    Also owns the action-flag danger of read-shaped tools whose
    typed GADT does not model the dangerous flag: [find -delete/-exec]
    (Destructive_protected), [find -fprintf/-fls], [sed -i], [sort -o]
    (R1). The command identity stays read-shaped; the flag carries the
    risk, so it is string-borne like gh. Shell interpreters and shell-capable
    executable surfaces ([python], [python3], [node], [pip], [npx]) are
    classified as [Destructive_protected], and network primitives as [R1],
    here rather than in product-level executable-name gates. *)

val is_write_operation : string list -> bool
(** [true] when the flattened word list indicates a write-level operation:
    git push/commit/merge/rebase/reset/checkout, branch create/delete/rename,
    or non-git commands that touch state. Read-only branch inspection
    ([git branch], [git branch -a --list PATTERN], [git branch --show-current])
    remains R0.

    Used by [Exec_policy_mutation_classifier.is_write_operation] for
    the IR-typed entry point. *)

val classify_repo_hosting_cli : string list -> risk_class
(** Direct repo-hosting CLI word-list classification without IR construction.
    The current command literal is ["gh"], but the API is named for the
    Shell-IR capability boundary rather than a product-level GH helper family. *)

val repo_hosting_cli_floor_risk : string list -> Shell_ir.simple -> risk_class
(** Enforcement-floor risk for a gh command, robust to leading global flags
    (issue #23390). [max] of [classify_repo_hosting_cli words] (string-borne
    risk: [gh api -X DELETE], graphql bodies), an enforcement-only [simple]
    arg view that consumes known gh global value flags even when their values
    are dynamic, and the typed lowering of [simple] (whose gh parser consumes
    literal value-flags like gh, so the subcommand is located correctly even
    after [gh --repo o/r pr merge]). Keeps the
    historical floor semantics — unrecognized gh subcommand / [Api] / bare
    family stay [R0_Read]; fail-closing unknown gh is RFC-0309 W3, not here.
    Used by [Approval_policy.repo_hosting_cli_is_floored]. *)

type gh_verb_class =
  | Gh_read
  | Gh_reversible_mutation
  | Gh_irreversible_mutation
  | Gh_unrecognized_action
  | Gh_string_borne
  | Gh_unrecognized_family
      (** Typed classification of a gh verb, the single source both the risk
          axis ([risk_of_gh_verb]) and the capability axis
          ([Gh_capability_policy.disposition_of]) read.
          - [Gh_read]: a known read action ([view]/[list]/[status]/...) or a
            bare family invocation ([gh repo]).
          - [Gh_reversible_mutation] / [Gh_irreversible_mutation]: the action is
            in the reversible / irreversible subcommand table.
          - [Gh_unrecognized_action]: a known mutating-capable family with an
            action that is neither a table mutation nor a known read
            (e.g. [gh repo upsert-magic]). The capability axis routes this to
            approval; the risk axis keeps it [R0_Read] because its reversibility
            is genuinely unknown.
          - [Gh_string_borne]: [gh api] — risk is the -X method / graphql body,
            owned by the word-list floor (RFC-0208).
          - [Gh_unrecognized_family]: [Gh_verb.Other]. *)

val classify_gh_verb : Gh_verb.t -> gh_verb_class
(** Classify a gh verb. See {!gh_verb_class}. *)

val risk_of_gh_verb : Gh_verb.t -> risk_class
(** RFC-0309 §3.1 (W1): the typed-family risk opinion for a gh command,
    projected from [classify_gh_verb]. Reads the same subcommand tables as
    [classify_repo_hosting_cli] for known families (so the two agree for every
    recognized [family/action] pair). [Gh_verb.Other] is fail-closed to
    [R2_Irreversible]; [Gh_verb.Api] returns [R0_Read] (string-borne, floor);
    a known read and an unrecognized action both stay [R0_Read] on the RISK
    axis (an unrecognized action's reversibility is genuinely unknown — the
    capability axis, not risk, gates it). Never returns [Destructive_protected]. *)

val gh_api_graphql_creates_durable_remote : string list -> bool
(** True when [words] is a [gh api graphql ...] invocation whose (comment-
    stripped) body contains a durable-remote repository/discussion create/mutate
    fragment that W4/G-9 demoted from the R2 deny floor to R1 (createRepository,
    createDiscussion, addDiscussionComment, …). The capability axis
    ([Gh_capability_policy.disposition_of_words]) consults this to escalate the
    string-borne graphql form to [Requires_approval], matching the typed
    [gh repo create] path — the typed verb for [gh api] is [Gh_verb.Api], which
    is body-blind by design (RFC-0208), so the disposition would otherwise
    [Allow] it. Guarded on the [graphql] endpoint token; a REST [gh api] path
    that merely contains a mutation name returns [false]. Irreversible graphql
    mutations stay R2-floored and are not reported here. *)

val literal_words_of_simple : Shell_ir.simple -> string list option
(** Extract literal words from a single [Shell_ir.simple] stage:
    [[bin; arg0; arg1; ...]]. Non-literal args ([Concat], [Var])
    abort the extraction by returning [None]. *)
