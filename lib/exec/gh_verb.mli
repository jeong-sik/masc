(** Gh_verb — typed capability identity for [gh] commands (RFC-0309 §3.1, W1).

    The Shell IR [Gh] constructor carries [subcommand]/[action] as strings
    because gh's surface is large and evolving (RFC-0208: gh risk is
    string-borne). This module adds a {e closed} typed lens over the
    top-level command area — the [gh_family] — so downstream layers can
    pattern-match on capability identity exhaustively:

    - risk ([Shell_ir_risk.risk_of_gh_verb]) — W1;
    - capability policy (per-keeper-class allow/approval) — W2;
    - non-blocking approval routing — W3.

    The [action] stays a string: gh subcommand actions are open-ended and
    their risk-bearing detail (the HTTP method for [api], the graphql
    mutation body) lives in argv strings, which the word-list floor
    ([Shell_ir_risk.classify_repo_hosting_cli]) owns by design. This module
    does not re-classify that string-borne detail; it only names the family
    so an {e unrecognized} gh area is representable as [Other] rather than
    silently collapsing to a known-read shape.

    This module has no risk dependency (breaks the [Shell_ir_risk] cycle):
    risk is assigned by [Shell_ir_risk.risk_of_gh_verb]. *)

type gh_family =
  | Pr
  | Issue
  | Repo
  | Discussion
  | Release
  | Secret
  | Ssh_key
  | Workflow
  | Auth
  | Gist
  | Ruleset
  | Label
  | Run
  | Cache
  | Project
  | Api
  | Other of string
      (** A top-level gh area not recognized by this closed set. Carries the
          raw token so callers can report it. Adding a new known family is a
          one-line change here that forces a compile error in every
          exhaustive consumer ([Shell_ir_risk.risk_of_gh_verb]). *)

type t =
  { family : gh_family
  ; action : string option
      (** First non-flag token after the family (e.g. ["create"] in
          [gh repo create]). [None] when the command is bare
          ([gh repo]). Kept as a string: see the module note. *)
  }

val of_fields : subcommand:string -> action:string option -> t
(** Build a verb from the {e already-parsed} Shell IR [Gh] constructor fields.
    This is the primary constructor for the real pipeline ([risk_of_typed] and
    W2/W3), which hold a [Gh] value whose [subcommand]/[action] were extracted
    by the value-aware gh lowering (so global value-flags like [--repo VALUE]
    have already been consumed correctly). No re-tokenization, no flag
    guessing. *)

val classify : string list -> t
(** [classify words] parses raw [gh]-style argv (["gh" :: subcommand :: rest]
    or [subcommand :: rest]) into a typed family plus its first non-flag
    action. Flags ([-x], [--long]) are skipped with a value-less (boolean)
    default, mirroring [Shell_ir_risk.classify_repo_hosting_cli]'s extraction
    so the two agree on which token is the subcommand — including agreeing on
    the known limitation that a leading {e value-taking} global flag
    ([gh --repo o/r pr merge]) mis-locates the subcommand. Callers that hold a
    parsed [Gh] value should use {!of_fields} instead. A leading ["gh"] head
    is tolerated and ignored; an empty or flags-only argv yields
    [{ family = Other ""; action = None }]. *)

val family_token : gh_family -> string
(** The lowercase argv token for a family ([Repo -> "repo"],
    [Ssh_key -> "ssh-key"], [Api -> "api"], [Other s -> s]). Exhaustive —
    the inverse of the [classify] family mapping for known families. *)

val string_of_family : gh_family -> string
(** Stable label for logs/metrics ([Other s] renders as ["other:" ^ s]). *)

val pp : Format.formatter -> t -> unit
