(** Closed sum type for keeper path-check errors emitted by
    [worker_dev_tools] path validators.

    Before this module, path containment errors were rendered as ad-hoc
    [Printf.sprintf] strings at multiple emit sites and classified
    downstream via [String_util.contains_substring] grep — the
    classifier anti-pattern called out in #9521 and tracked as
    Workaround Rejection Bar signature #2 (string/substring classifier
    boosted instead of removed).

    Goal:
    - One typed variant per emit category (exhaustive [match] forces
      new variants to update all callers at compile time).
    - Stable lowercase [prefix_token] per variant — kept identical to
      the prior raw-string prefixes so downstream observers
      (dashboard tool-quality, log aggregators) keep working without
      a behaviour change in this PR.
    - [parse_prefix] is a typed lookup, not substring grep; a future
      PR can migrate [keeper_failure_circuit_breaker.classify_error]
      onto it without rewriting the spec mirror. *)

type t =
  | Path_outside_whitelist of
      { path : string
      ; for_keeper_command : bool
      }
      (** Spatial whitelist rejection — path resolved outside the
          union of [/tmp], [workdir]/[cwd], and [sandbox_workspace_root].
          [for_keeper_command]: argv-role context vs generic file
          read/write. *)
  | Cwd_not_directory of
      { path : string
      ; hint : string option
      }
      (** Path exists in syntax + whitelist but the directory is
          missing on disk (worktree lifecycle issue, see #15551). *)

val parse_prefix : string -> t option
(** Typed prefix lookup — reverse of [to_message].  Returns [Some]
    when the message starts with a known variant prefix (case-
    insensitive).  Used by [keeper_failure_circuit_breaker] to
    classify path-check errors without substring matching. *)

val to_message : t -> string
(** Render the user-facing error message — keeps the prior wording
    so downstream tools that match on these messages keep their
    contract. *)

val parse_prefix : string -> t option
(** Attempt to classify a raw error message by its prefix.
    Returns [Some t] if the message matches a known prefix pattern,
    [None] otherwise. Used by failure-circuit-breaker for typed
    error classification without substring grepping. *)

