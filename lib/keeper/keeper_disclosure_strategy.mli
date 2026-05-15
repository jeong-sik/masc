(** RFC-0084 §1.6 + §3.5 — Typed keeper disclosure strategy.

    Activates the [Tool.disclosure_level] infrastructure that OAS PR
    #1508 + #1511 wired into [lib/pipeline/stage_parse.ml:42-46] and
    [lib/pipeline/pipeline_stage_prepare.ml:109-115] but which sits
    dormant in masc-mcp (RFC-0084 §1.6: [worker_oas.ml] caller count
    for `with_disclosure_level` / `with_disclosure_resolver` /
    `imseonghan` = 0).

    RFC-OAS-013 §2.1 v2 proposed a [meta.name = "imseonghan"]
    hardcoded keeper-name gate. This PR rejects that pattern and
    introduces a config-driven typed strategy so any keeper TOML
    can opt-in to Hybrid disclosure without code-level keeper-name
    hardcodes (CLAUDE.md anti-pattern #1 "Scattered hardcoded
    default": 1 keeper name in code).

    PR-13 introduces the typed surface only. Wiring into
    [worker_oas.ml] + [keeper_meta.ml] TOML round-trip is scoped to
    follow-up activation PR(s) per the
    delegation-not-absorption pattern used in PR-6/8/9/10/11/12. *)

(** Disclosure strategy variants. *)
type t =
  | Full
      (** Pass every tool schema in full to the LLM.  Today's default;
          maximum prefix-cache stability + maximum tokens consumed. *)
  | Hybrid of
      { full_names : string list
            (** Tool names whose schemas are sent in full
                (typically the keeper's [always_include] core
                tools — RFC-OAS-013 §2.1 v2 [core_tool_names]). *)
      ; demote_on_error : bool
            (** When [true] and the previous turn contained any tool
                error, demote the next turn to [Full] for one turn
                (RFC-OAS-013 §2.3 [demote_on_error]).  Lets the LLM
                see complete schemas after a parameter-shape error. *)
      }
      (** Hybrid: only [full_names] tools get full schemas; the rest
          get minimal index (name + description only). *)
  | Minimal_index
      (** Every tool sent as name + description only.  Maximum
          schema-token savings, highest tool-call error rate.
          Reserved for advanced canary keepers; not the default. *)

(** [default] is [Full] — the safest strategy that today's masc-mcp
    keepers behave as.  PR-13 introduces the typed alternative;
    follow-up activation PR(s) flip keepers to [Hybrid] one at a time. *)
val default : t

(** [to_string t] returns the canonical TOML label
    (["full"] / ["hybrid"] / ["minimal_index"]). *)
val to_string : t -> string

(** [of_toml ~strategy ~full_names ~demote_on_error] constructs a [t]
    from raw TOML fields.  Returns [Error msg] when [strategy] is
    unknown or when [Hybrid] is requested without [full_names].
    Used by [keeper_runtime_toml] (follow-up activation PR) when
    parsing the [[disclosure]] section. *)
val of_toml
  :  strategy:string
  -> full_names:string list
  -> demote_on_error:bool
  -> (t, string) result

(** [is_full t = true] iff [t = Full].  Used by callers that need to
    short-circuit telemetry/measurement when no disclosure narrowing
    is in play. *)
val is_full : t -> bool

(** Pretty-print for diagnostic logging. *)
val pp : Format.formatter -> t -> unit
