(** Wirein_helpers — pure helpers for the Tier A5 keeper post-turn
    autonomous wire-in.

    Cycle 22 / Tier A5.

    These helpers live in [lib/autonomous/] (rather than directly
    inside [lib/keeper/keeper_post_turn]) so they can be unit-tested
    without pulling the entire [masc] library into the test
    closure. The keeper post-turn lifecycle dispatches to
    {!masc_autonomous_enabled} and {!upsert_autonomous_meta} from here. *)

val masc_autonomous_enabled : unit -> bool
(** [true] iff the [MASC_AUTONOMOUS] environment variable is set
    to one of ["1"], ["true"], ["yes"], or ["on"] (case-sensitive).
    The default ([false]) keeps the autonomous wire-in inert. *)

val upsert_autonomous_meta :
  Yojson.Safe.t option -> Yojson.Safe.t -> Yojson.Safe.t option
(** [upsert_autonomous_meta wc meta] returns a JSON [`Assoc]-shaped
    working_context with the ["autonomous_meta"] key set to [meta].

    - [wc = None] → fresh [`Assoc] with one entry.
    - [wc = Some (`Assoc kv)] → preserves all keys other than
      ["autonomous_meta"] and replaces (or adds) that single entry.
    - [wc = Some other] (non-[`Assoc] payload) → wraps [other] away
      under a new [`Assoc] holding only ["autonomous_meta"]. The
      caller is expected to use [`Assoc] working_contexts; this
      branch exists for graceful fallback. *)
