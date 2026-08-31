(** Name a tool schema's repeated object shapes once, under [$defs].

    A schema that spells the same nested object several times pays for it in
    every turn of every Keeper. [Execute] is the one that does: the exec-stage
    shape appears at the top level, inside [pipeline], inside [then], and
    inside [then]'s [pipeline], which is 4,233 of its 9,049 bytes and every
    repeated byte on the whole 74,616-byte surface — measured 2026-08-30, no
    other tool repeats a shape at all.

    This is a wire projection and not a rewrite of the descriptor.
    [Tool_input_validation] does not resolve [$ref], so the schema arguments
    are checked against stays expanded; only the copy the model reads is
    collapsed. {!Agent_core.Types.tool_schema_of_input_schema} keeps that copy
    verbatim as the authoritative schema, which is what carries it to a
    provider unchanged.

    Every lane was probed before this was turned on (2026-08-30): ollama-cloud
    minimax-m3, zai glm-4.6, codex app-server and antigravity agy 1.1.22 all
    resolve [$defs]/[$ref] and produce the same arguments they produce for the
    expanded form. *)

val collapse : Yojson.Safe.t -> Yojson.Safe.t
(** Replace each repeated object shape with a [$ref] and collect the bodies
    under [$defs] at the root.

    Meaning-preserving: the result describes the same instances, and expanding
    every reference returns the input up to object key order. A shape is only
    named when the copies it removes outweigh the references replacing them, so
    a schema with nothing to gain is returned unchanged — as is one that
    already carries [$defs] or is itself a [$ref], which this does not rewrite.

    Names are derived in sorted order of the canonical bodies, so the same
    input collapses to the same bytes on every run. *)
