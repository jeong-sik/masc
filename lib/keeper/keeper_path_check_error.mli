(** Closed sum type for keeper path-check errors emitted by
    [worker_dev_tools] path validators.

    Before this module, the same set of errors was rendered as ad-hoc
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
  | Path_syntax_blocked of
      { token : string
      ; hint : string option
      }
      (** Argv-role aware syntax rejection (quotes / globs / brace /
          backslash on path-bearing argument). Emitted by
          [validate_command_paths] when [token_has_unsafe_rewrite_syntax]
          fires. *)
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

val to_message : t -> string
(** Render the user-facing error message — keeps the prior wording
    so downstream tools that match on these messages keep their
    contract. *)

val message_prefix : t -> string
(** Stable lowercase prefix token used by downstream classifiers
    (e.g. dashboard tool-quality). Always a strict prefix of the
    lowercase form of [to_message]. *)

val parse_prefix : string -> t option
(** Inverse of [to_message] for the variant tag only — payload fields
    are left empty / [None] since the typed module is intended for
    classification, not full message reconstruction. *)
