(** How large a start prompt the Muse Code host takes without rewriting it.

    Muse has no way to carry prior conversation into a new session: MASC
    renders the seeded history into the first turn's one text input. The host
    does not refuse an input that is too large. It compacts it and still
    completes the turn, and an input over the window reaches the model as a
    summary of about 4 KB. So the ceiling must be known before sending, and
    MASC derives it from the window the host reports ([max-context]) rather
    than asking the operator for a byte count.

    The host facts below were measured on Muse Code 1.4.0 on 2026-09-28
    against a synthetic local model endpoint (the host binary was the real
    one; only the model was synthetic):
    - the host estimates tokens as UTF-8 bytes / 4, identically for ASCII
      prose, Hangul, OCaml source, symbol-dense text and emoji;
    - before any input it counts 11,946 estimated tokens of its own
      instructions and input framing; tool schemas are not counted;
    - it compacts once its estimate passes 75% of the model's context limit
      (the percentage its own summary request states).

    A later host can change any of these. *)

type error =
  | No_window_declared  (** The model declares no [max-context]. *)
  | Window_below_host_overhead of { max_context : int }
      (** 75% of [max-context] does not cover the host's own overhead. *)

val error_to_string : error -> string

val start_prompt_bytes : max_context:int option -> (int, error) result
(** The ceiling is [4 × (⌊75% of max-context⌋ − 11,946)] bytes: a prompt no
    larger keeps the host's estimate under its compaction line. *)
