(** Gh_capability_policy — the capability axis for gh verbs (RFC-0309 §3.3, W2).

    RFC-0309 separates three axes that PR #23362 conflated:
    - risk ([Shell_ir_risk]) — is the operation factually reversible?
    - capability policy (THIS module) — may a keeper perform this verb family?
    - disposition wiring (W3) — run / ask a human asynchronously / refuse?

    This module owns the middle axis. It answers "may a keeper do this?" with a
    typed [disposition], distinct from (not overloaded onto) the risk class.
    The defining input of the axis — whether the verb touches a durable remote
    surface ([creates_durable_remote_surface]) — is risk-independent (G-4
    externality).

    W2/W3 scope: this is the policy SSOT for the gh capability axis.
    [Approval_policy.decide] consults it after the catastrophic floor and before
    the per-risk-band trust overlay. [Requires_approval] becomes [Verdict.Ask],
    and the keeper runtime routes gh capability asks to the non-blocking HITL
    queue. Reversible durable-remote mutations such as [gh repo create] and
    [gh discussion create] therefore request approval instead of auto-running or
    being disabled; irreversible operations remain [Denied]. *)

type disposition =
  | Allowed
      (** The keeper may run this autonomously (reads, local reversible
          mutations within an existing repo). *)
  | Requires_approval
      (** The keeper must route this to non-blocking human approval (W3).
          Reserved for reversible mutations that create/mutate a durable remote
          surface, and for unrecognized verbs a human should adjudicate. *)
  | Denied
      (** Never permitted for a keeper. These are also floored on the risk axis
          (R2/Destructive); the capability axis records the policy intent. *)

type repo_create_visibility =
  | Public
  | Private
  | Internal

type repo_create_lifecycle =
  { add_readme : bool
  ; clone : bool
  ; push : bool
  ; source : string option
  ; remote : string option
  ; template : string option
  }

type repo_create_contract =
  { owner : string
  ; name : string
  ; visibility : repo_create_visibility
  ; lifecycle : repo_create_lifecycle
  }
(** G-10 repo-create capability contract extracted from literal
    [gh repo create OWNER/NAME --public|--private|--internal ...] argv.
    The owner segment must be explicit so ambient authenticated-user defaults
    cannot decide ownership invisibly. [lifecycle] records the visible creation
    mode flags that shape post-create state; these values are metadata for the
    approval request and future lifecycle policy, not an execution grant. *)

val string_of_disposition : disposition -> string
(** Stable lowercase label for logs/metrics: "allowed" | "requires_approval" |
    "denied". *)

val repo_create_contract_of_simple :
  Shell_ir.simple -> (repo_create_contract, string list) result option
(** [Some (Ok contract)] for a literal [gh repo create] command that satisfies
    the G-10 contract, [Some (Error fields)] when the command is repo-create but
    lacks required metadata or has unverifiable args, and [None] for non
    repo-create commands. Required fields are:
    - explicit [OWNER/NAME] repo target;
    - exactly one visibility flag: [--public], [--private], or [--internal].

    Missing or opaque contract fields are policy failures, not approval asks:
    the keeper must provide the contract before a human can approve the remote
    repository creation. *)

val repo_create_contract_rule_of_simple : Shell_ir.simple -> string option
(** Render a stable [Verdict.Policy_deny] rule for a repo-create command that
    violates {!repo_create_contract_of_simple}. *)

val creates_durable_remote_surface : Gh_verb.t -> bool
(** G-4 externality axis (risk-independent): [true] when this gh verb creates or
    mutates a durable remote surface whose ownership, lifecycle, and moderation
    policy are not modeled in keeper tool contracts.

    Keyed on the whole verb (family + action), not the family alone (W3
    per-action refinement): a [Repo]/[Discussion] verb that is a local or
    read-only action ([repo clone] copies to the local disk, [repo view] /
    [repo list] read) does NOT touch a durable remote surface and is [false].
    Only the mutating actions on those families ([repo create]/[fork]/[edit]/
    [sync]/[set-default]/[rename]; every [discussion] mutation) are [true].
    [Pr]/[Issue]/[Release]/etc. act within an already-owned repo, so [false].
    A [None] action (bare [gh repo]) is a read, so [false]. *)

val disposition_of : Gh_verb.t -> disposition
(** The capability disposition for a gh verb. Reads
    [Shell_ir_risk.risk_of_gh_verb] as an input (a distinct axis may still
    consult risk):
    - [Gh_verb.Other] (unrecognized area) -> [Requires_approval] (a human
      decides; never silently allowed — the W3 fail-safe);
    - risk R2/Destructive -> [Denied];
    - risk R0 -> [Allowed];
    - risk R1 -> [Requires_approval] if [creates_durable_remote_surface],
      else [Allowed]. *)

val disposition_of_words : string list -> Gh_verb.t -> disposition
(** Body-aware disposition. Identical to [disposition_of] for every command
    except [gh api graphql ...]: the typed verb for [gh api] is [Gh_verb.Api],
    which is body-blind by design (RFC-0208), yet W4/G-9 demoted durable-remote
    graphql creates (createRepository/createDiscussion/addDiscussionComment) from
    the R2 deny floor to R1. Without body inspection the disposition would
    [Allow] them while the typed [gh repo create] form [Requires_approval] — an
    axis-asymmetry bypass. This variant consults
    [Shell_ir_risk.gh_api_graphql_creates_durable_remote words] and returns
    [Requires_approval] for such bodies. ADDITIVE: only ever upgrades [Allowed]
    to [Requires_approval], never the reverse. Callers with the raw argv words
    (e.g. [Approval_policy.decide]) should prefer this over [disposition_of]. *)

val disposition_of_simple : Shell_ir.simple -> disposition option
(** Capability disposition for a parsed Shell IR simple command. Returns [None]
    for non-[gh] commands.

    This is the approval-path entry point because it preserves argument opacity.
    Literal [gh api graphql -f query=...] bodies are classified through
    {!disposition_of_words}. If the GraphQL [query] field itself is non-literal
    (for example [query=$MUTATION] or an opaque field token), the body cannot be
    inspected for durable-remote mutations, so the capability axis fail-closes to
    [Requires_approval]. Opaque non-query GraphQL variables such as
    [owner=$OWNER] do not trigger this approval path. *)
