(** RFC-0297 Phase 1 (P0-1): closed-variant keeper lifecycle gate.

    A lifecycle activity runs only when BOTH the global kill-switch
    (from [runtime.toml] [reactive]/[proactive]/[autonomous]/[bootstrap]
    [enabled]) AND the per-keeper flag (projected from [keeper_meta]) are
    enabled. Every flag defaults to [true] so the historical "keeper alive
    = always on" behaviour is preserved; operators opt in to a kill-switch
    by setting a flag to [false].

    This closes RFC-0297 §P0-1: the global kill-switches did not exist in
    code, so [\[proactive\] enabled = false] in runtime.toml was silently
    dropped. The closed [gate] sum + exhaustive [gate_enabled] make a
    missing gate a compile error rather than a silent always-on path
    (CLAUDE.md §FSM sparse match). *)

type gate =
  | Reactive
  | Proactive
  | Autonomous
  | Bootstrap

(** One boolean per gate. Used for both the global (config) and the
    per-keeper (meta) view. [gate_enabled] ANDs the two, so the two views
    are interchangeable at the call site. *)
type flags =
  { reactive : bool
  ; proactive : bool
  ; autonomous : bool
  ; bootstrap : bool
  }

(** All gates enabled — the default when neither config nor meta pins a
    kill-switch to [false]. *)
val all_enabled : flags

(** [gate_enabled g ~global ~meta] is [true] iff both the global and the
    per-keeper flag for [g] are [true]. Exhaustive over [gate]: adding a
    variant fails compilation until it is wired here. *)
val gate_enabled : gate -> global:flags -> meta:flags -> bool

(** Canonical lowercase label (["reactive"], …). Used in WARN/metric
    labels so operators can attribute a suppressed activity to its gate. *)
val gate_to_string : gate -> string
