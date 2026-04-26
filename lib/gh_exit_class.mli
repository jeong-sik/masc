(** GitHub CLI exit-code classifier.

    RFC-0007 rev.3 PR-2. Turns the [(exit_code, stderr)] pair from a
    [gh] subprocess completion into a small variant that callers
    (keeper prompt, metrics, retry policy) can [match] on instead of
    regex-scanning stdout.

    Classification is **table-driven**. A compile-time default table
    lives in this module; an operator-managed override table may be
    layered on top later from [config/tool_policy.toml] via
    {!install_overrides}. Unknown [(exit_code, stderr)] combinations
    always bucket to [Unknown] — we never misclassify.

    Design notes (RFC §PR-2):
    - No regex over stdout. Stdout is LLM-consumed payload; scanning it
      for classification creates a feedback loop we do not want.
    - Classification works on [exit_code] first, then a tiny set of
      [String.contains] probes on [stderr].
    - [Unknown] is a first-class bucket, not a bug. It fires the
      [Unknown] metric so operators can see emerging patterns without
      the classifier lying about them.

    Backward compatibility: callers migrating to {!gh_result} may keep
    their [(string, string) result] API via {!to_legacy_result} for
    one release cycle. *)

(** Classification bucket. Order matches RFC-0007 §PR-2 table. *)
type t =
  | Ok_0
  (** [exit_code = 0]. The [gh] call succeeded at the CLI layer.
          Business success still depends on [stdout]. *)
  | Policy_blocked
  (** masc-mcp internal block surfaced through a reserved exit
          code (R1/R2 destructive-mutation guards). *)
  | Type_mismatch
  (** Argparse / schema failure shape. Retry with a corrected
          argv shape, not a different intent. *)
  | Auth_failed (** [gh auth] error surface — missing/expired token, 401, 403. *)
  | Network (** curl/TLS/DNS failure. Transient, retry after backoff. *)
  | Unknown (** Fail-safe bucket. Never claim a class we cannot prove. *)

val to_string : t -> string

(** [classify ~exit_code ~stderr] is pure. *)
val classify : exit_code:int -> stderr:string -> t

(** Structured result for a [gh] subprocess invocation. New callers
    return this directly; legacy callers use {!to_legacy_result}. *)
type gh_result = private
  { stdout : string
  ; stderr : string
  ; exit_code : int
  ; class_ : t
  ; interpretation : string option
  }

(** [make ~stdout ~stderr ~exit_code] classifies and constructs the
    result. [interpretation] is a short, ready-to-show hint derived
    from [class_]; [None] for [Ok_0] and [Unknown]. *)
val make : stdout:string -> stderr:string -> exit_code:int -> gh_result

(** Convert to the legacy [(string, string) result]. [Ok_0 →
    Ok stdout]; everything else → [Error] with a one-line summary
    prefixed by the class name. *)
val to_legacy_result : gh_result -> (string, string) result

(** A single classification rule: [(predicate, class)]. The classifier
    walks the rule list head-to-tail and returns the class of the
    first matching rule, falling through to [Unknown]. *)
type rule =
  { exit_code : int
  ; stderr_contains : string option (** [None] = match any stderr. *)
  ; class_ : t
  }

(** Default rule table baked into this module. Exposed so that tests
    can assert against it and config loaders can layer overrides. *)
val default_rules : rule list

(** [install_overrides rules] prepends [rules] to the active rule
    table for the remainder of the process. Intended to be called
    once at startup after reading [config/tool_policy.toml]. *)
val install_overrides : rule list -> unit
