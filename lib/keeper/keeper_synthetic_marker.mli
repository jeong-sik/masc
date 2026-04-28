(** [SYNTHETIC] marker — single source of truth.

    Producer ([keeper_memory_policy]) tags synthetic generation outputs
    with this marker so consumers ([keeper_memory_bank] for filtering,
    [keeper_exec_memory] for ranking) can identify and de-prioritise
    them.

    Pre-fix: the literal ["[SYNTHETIC]"] was hardcoded in three files.
    A divergence (typo, case variant, prefix change) on the producer
    side could silently break the consumer-side detection — exactly the
    "Scattered Hardcoded Defaults" anti-pattern from the user's hard
    rules.  This module is the SSOT. *)

val marker_prefix : string
(** [marker_prefix] is the exact byte sequence emitted by producers and
    looked up by consumers.  Currently ["[SYNTHETIC]"]. *)

val tag : string -> string
(** [tag text] returns ["[SYNTHETIC] <text>"].  Producer-side helper.
    Use instead of inline [Printf.sprintf] so a future marker change
    flows through one site. *)

val contains_marker : string -> bool
(** [contains_marker s] is [true] iff [s] contains [marker_prefix] as a
    substring.  Consumer-side helper. *)
