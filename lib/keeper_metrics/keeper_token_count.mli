(** Phantom-typed pre/post token counts for compaction accounting.

    RFC-0149 §3.2 root-fix.  The legacy
    [let saved_tokens = max 0 (tok_count - new_tok_count)] in
    [keeper_compact_policy.ml] silently floored the negative-delta case
    to zero and routed the divergence detection through the
    [metric_keeper_compaction_negative_savings] counter — a §1
    telemetry-as-fix.  The two operands originate from the same
    estimator ([token_count]) applied to two different contexts, so an
    *estimate divergence* (post > pre) cannot be statically prevented;
    it must instead become *representable* in the type system, so
    callers cannot ignore it.

    Phantom tags discriminate the two roles ([pre] / [post]).  The
    compiler enforces that pre/post arguments cannot be swapped, and
    the [saved] result variant ([`Saved of int] vs [`Divergent of int])
    makes the floor non-bypassable: there is no path that silently
    coerces a negative delta to zero. *)

(** Phantom tag for pre-compaction estimates. *)
type pre

(** Phantom tag for post-compaction recounts. *)
type post

(** A count witnessed under a specific phase tag.  [private int] so the
    only ways to construct one are the smart constructors below; the
    representation stays a single boxed int with zero runtime cost. *)
type 'phase t = private int

(** Construct a pre-compaction estimate.  Negative inputs are clamped
    to zero (token counts are non-negative by domain). *)
val pre_estimate : int -> pre t

(** Construct a post-compaction recount.  Negative inputs are clamped
    to zero (token counts are non-negative by domain). *)
val post_recount : int -> post t

(** Extract the underlying int.  Kept narrow so renderers and metrics
    emitters can still read the value, but constructing a new count
    from an arbitrary int is impossible. *)
val to_int : _ t -> int

(** The saving computation: [pre - post] when [post <= pre], or
    [`Divergent (post - pre)] when the post-recount exceeded the
    pre-estimate.  The variant forces the caller to pattern-match,
    eliminating the silent floor.  The [`Divergent] payload carries
    the positive magnitude of the divergence so it can drive metrics
    or operator alerts. *)
val saved : pre:pre t -> post:post t -> [ `Saved of int | `Divergent of int ]
